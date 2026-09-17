#import "ERUtilitySwitchCell.h"
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// 「实用工具」那行的外观：开关在左，标题在右
// ---------------------------------------------------------------------------
// 系统 PSSwitchCell 把开关放在最右。这一行要的是相反的顺序：
//
//     [ 开关 ]  [ 图标 ]  标题
//
// 只改外观、不动行为，做法与 EREntryCell 一致：先调用基类实现，再搬位置。
//
// 三个刻意的选择：
//   · 类名（ERUtilitySwitchCell）在编译期没有任何 @interface 与之同名 ——
//     objc_allocateClassPair 对已存在的名字返回 NULL，重名就静默不注册。
//   · 覆写方法里**不**用 `struct objc_super` + `objc_msgSendSuper`，而是在注册时用
//     method_getImplementation 缓存基类 IMP、之后直接调用。省掉 objc_super 的
//     字段布局假设，也省掉 arm64e 上 super 派发函数的可用性分歧。
//   · 基类没实现某个方法时干脆不注册那条覆写，不做半截替换。
//
// 失败降级：若本类因任何原因没注册成功，specifier 的 `cell` 仍是 PSSwitchCell，
// 框架会落到它 —— 开关跑到右边，**功能完全不受影响**（读写偏好、PostNotification
// 都由基类负责）。这是刻意保留的双保险：宁可开关位置不对，也不能让这一行点不动。
//
// 为什么用「布局后搬 frame」而不是给开关加约束：PSSwitchCell 的基类布局是
// frame 的，自己再加一套约束会和它自己的布局互相打架；搬 frame 只是覆盖结果，
// 拿不到开关（UISwitch）时直接放弃，没有中间态。

NSString *const ERUtilitySwitchCellClassName = @"ERUtilitySwitchCell";

static NSString *const kERUtilitySwitchCellName = @"ERUtilitySwitchCell";

static IMP gERUSSuperLayout = NULL;
static IMP gERUSSuperRefresh = NULL;

// 与相邻卡片（七个连接模块行）通用的间距：开关左缘、开关与图标之间、图标与标题之间。
static const CGFloat kERUSLeadingInset = 16.0;
static const CGFloat kERUSSwitchGap = 12.0;
static const CGFloat kERUSIconGap = 8.0;
static const CGFloat kERUSTrailingInset = 16.0;

static UISwitch *ERUSFindSwitch(UIView *root) {
    if (!root) return nil;
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:[UISwitch class]]) return (UISwitch *)subview;
        UISwitch *deeper = ERUSFindSwitch(subview);
        if (deeper) return deeper;
    }
    return nil;
}

static void ERUSApplyLayout(UITableViewCell *cell) {
    if (!cell) return;

    UISwitch *toggle = ERUSFindSwitch(cell.contentView) ?: ERUSFindSwitch(cell);
    // 拿不到开关就放手：保持基类布局（开关在右），这一行依旧完全可用。
    if (!toggle) return;

    CGRect bounds = cell.contentView.bounds;
    if (CGRectIsEmpty(bounds)) bounds = cell.bounds;
    if (CGRectIsEmpty(bounds)) return;

    CGFloat width = CGRectGetWidth(bounds);
    CGFloat available = width - kERUSLeadingInset - kERUSTrailingInset;
    if (available <= 60.0) return;      // 太窄（例如编辑态缩进）就别动，避免压扁

    // ---- 开关搬到最左，垂直居中 ----
    CGSize switchSize = toggle.bounds.size;
    if (switchSize.width < 1.0) switchSize = toggle.intrinsicContentSize;
    if (switchSize.width < 1.0) switchSize = CGSizeMake(51.0, 31.0);

    toggle.frame = CGRectMake(kERUSLeadingInset,
                              CGRectGetMidY(bounds) - switchSize.height * 0.5,
                              switchSize.width,
                              switchSize.height);

    CGFloat cursor = CGRectGetMaxX(toggle.frame) + kERUSSwitchGap;

    // ---- 图标（如果这一行挂了 iconImage）跟在开关右边 ----
    UIImageView *icon = cell.imageView;
    if (icon.image) {
        CGSize iconSize = icon.bounds.size;
        if (iconSize.width < 1.0) iconSize = CGSizeMake(29.0, 29.0);
        icon.frame = CGRectMake(cursor,
                                CGRectGetMidY(bounds) - iconSize.height * 0.5,
                                iconSize.width,
                                iconSize.height);
        cursor = CGRectGetMaxX(icon.frame) + kERUSIconGap;
    }

    // ---- 标题放在最后，吃掉剩余宽度 ----
    UILabel *label = cell.textLabel;
    if (label) {
        label.textAlignment = NSTextAlignmentLeft;
        CGRect labelFrame = label.frame;
        CGFloat labelHeight = labelFrame.size.height > 1.0 ? labelFrame.size.height : ceil(label.font.lineHeight);
        label.frame = CGRectMake(cursor,
                                 CGRectGetMidY(bounds) - labelHeight * 0.5,
                                 MAX(0.0, width - kERUSTrailingInset - cursor),
                                 labelHeight);
    }

    // 该行右侧不再有任何附件；PSSwitchCell 偶尔会挂一个 disclosure 之类的附件视图，
    // 有就一并移出可视区，避免和标题重叠。
    UIView *accessory = cell.accessoryView;
    if (accessory && accessory != toggle) accessory.hidden = YES;
}

static void ERUSLayoutSubviews(id self, SEL _cmd) {
    if (gERUSSuperLayout) ((void (*)(id, SEL))gERUSSuperLayout)(self, _cmd);
    ERUSApplyLayout((UITableViewCell *)self);
}

static void ERUSRefreshCell(id self, SEL _cmd, PSSpecifier *specifier) {
    if (gERUSSuperRefresh) ((void (*)(id, SEL, id))gERUSSuperRefresh)(self, _cmd, specifier);
    ERUSApplyLayout((UITableViewCell *)self);
    // 基类可能在 refresh 里重建了开关，而布局可能已经跑过了 —— 再排一次布局，
    // 保证开关一定落在左边（否则会先以右侧位置闪现一次）。
    [(UITableViewCell *)self setNeedsLayout];
}

void EREnsureUtilitySwitchCellClassInstalled(void) {
    if (NSClassFromString(kERUtilitySwitchCellName)) return;

    Class base = NSClassFromString(@"PSSwitchCell");
    // 退到 PSTableCell 也能显示标题，只是没有开关 —— 但那种情况下框架自己也会
    // 退回 PSSwitchCell，所以这里只在两者都取不到时彻底放弃（不注册任何东西）。
    if (!base) base = [PSTableCell class];
    if (!base) return;

    Method layoutMethod = class_getInstanceMethod(base, @selector(layoutSubviews));
    Method refreshMethod = class_getInstanceMethod(base, @selector(refreshCellContentsWithSpecifier:));
    if (!layoutMethod && !refreshMethod) return;

    Class cellClass = objc_allocateClassPair(base, kERUtilitySwitchCellName.UTF8String, 0);
    if (!cellClass) return;

    if (layoutMethod) {
        gERUSSuperLayout = method_getImplementation(layoutMethod);
        class_addMethod(cellClass, @selector(layoutSubviews), (IMP)ERUSLayoutSubviews, "v@:");
    }
    if (refreshMethod) {
        gERUSSuperRefresh = method_getImplementation(refreshMethod);
        class_addMethod(cellClass, @selector(refreshCellContentsWithSpecifier:),
                        (IMP)ERUSRefreshCell, "v@:@");
    }
    objc_registerClassPair(cellClass);
}

@interface ERUtilitySwitchCellInstaller : NSObject
@end

@implementation ERUtilitySwitchCellInstaller

// +load 在本 bundle 被 dlopen 的过程中执行，早于 Preferences 解析 specifier
// （cellClass 是按名字 NSClassFromString 解析的，类必须已经注册）。
// 与 EREntryCell 的安装器同因：ERModuleSettingsController 只会按名字引用，
// 不会有人调用注册函数，所以必须自注册。
+ (void)load {
    EREnsureUtilitySwitchCellClassInstalled();
}

@end
