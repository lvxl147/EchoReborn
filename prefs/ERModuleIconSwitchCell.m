#import "ERModuleIconSwitchCell.h"
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// 「模块管理」七行的外观：图标在左，标题居中，开关在右（基类默认位置）
// ---------------------------------------------------------------------------
// 1.1.8-7 · 修复「模块管理左侧图标不显示」：iOS 17.2 原生 PSSwitchCell 不渲染
// iconImage。本类在 refreshCellContentsWithSpecifier 里显式把 specifier 的
// iconImage 写进 cell.imageView，并在布局时给图标留出左侧位置、标题居中。
//
// 结构与 ERUtilitySwitchCell.m 逐字同构（运行期建类、缓存基类 IMP、+load 自注册、
// 失败降级回原生 PSSwitchCell）——详见该文件的完整说明，此处不再重复。
//
// 布局：图标 29pt 方块贴左（16pt 缩进），标题跟在图标后，开关保持在基类放好的
// 最右侧；基类没放好开关时按系统默认 51x31 贴右。

NSString *const ERModuleIconSwitchCellClassName = @"ERModuleIconSwitchCell";

static NSString *const kERMICSCellName = @"ERModuleIconSwitchCell";

static IMP gERMICSuperLayout = NULL;
static IMP gERMICSuperRefresh = NULL;

static const CGFloat kERMICLeadingInset = 16.0;
static const CGFloat kERMICIconGap = 8.0;
static const CGFloat kERMICTrailingInset = 16.0;

static UISwitch *ERMICFindSwitch(UIView *root) {
    if (!root) return nil;
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:[UISwitch class]]) return (UISwitch *)subview;
        UISwitch *deeper = ERMICFindSwitch(subview);
        if (deeper) return deeper;
    }
    return nil;
}

static void ERMICApplyLayout(UITableViewCell *cell) {
    if (!cell) return;

    UISwitch *toggle = ERMICFindSwitch(cell.contentView) ?: ERMICFindSwitch(cell);
    if (!toggle) {
        // 1.2.0-9 · 一次性诊断：开关压根没建出来还是被挪走了
        static BOOL sERMICDiagOnce = NO;
        if (!sERMICDiagOnce) {
            sERMICDiagOnce = YES;
            NSLog(@"[ERMICS] DIAG no UISwitch found cls=%@ subviews=%lu",
                  NSStringFromClass(cell.class), (unsigned long)cell.subviews.count);
        }
        return;
    }

    CGRect bounds = cell.contentView.bounds;
    if (CGRectIsEmpty(bounds)) bounds = cell.bounds;
    if (CGRectIsEmpty(bounds)) return;

    CGFloat width = CGRectGetWidth(bounds);
    CGFloat available = width - kERMICLeadingInset - kERMICTrailingInset;
    if (available <= 80.0) return;

    // ---- 开关保持在最右（基类通常已放好；没放好就按系统默认尺寸贴右）----
    // 1.2.0-9 · 修「开关消失」：frame 是相对 toggle.superview 的坐标，而 bounds
    // 用的是 contentView —— superview 不是 contentView/cell 时（iOS 17.2 可能嵌
    // 中间容器）必须 convertRect 换算，否则开关会被挪出屏幕外。
    CGSize switchSize = toggle.bounds.size;
    if (switchSize.width < 1.0) switchSize = toggle.intrinsicContentSize;
    if (switchSize.width < 1.0) switchSize = CGSizeMake(51.0, 31.0);
    CGRect toggleTarget = CGRectMake(width - kERMICTrailingInset - switchSize.width,
                                     CGRectGetMidY(bounds) - switchSize.height * 0.5,
                                     switchSize.width,
                                     switchSize.height);
    if (toggle.superview && toggle.superview != cell.contentView && toggle.superview != cell) {
        toggle.frame = [cell.contentView convertRect:toggleTarget toView:toggle.superview];
    } else {
        toggle.frame = toggleTarget;
    }

    // ---- 图标贴左（iconImage 由 refresh 显式写入）----
    UIImageView *icon = cell.imageView;
    CGFloat cursor = kERMICLeadingInset;
    if (icon.image) {
        CGSize iconSize = icon.bounds.size;
        if (iconSize.width < 1.0) iconSize = CGSizeMake(29.0, 29.0);
        icon.frame = CGRectMake(cursor,
                                CGRectGetMidY(bounds) - iconSize.height * 0.5,
                                iconSize.width,
                                iconSize.height);
        cursor = CGRectGetMaxX(icon.frame) + kERMICIconGap;
    }

    // ---- 标题吃掉图标与开关之间的宽度 ----
    UILabel *label = cell.textLabel;
    if (label) {
        label.textAlignment = NSTextAlignmentLeft;
        CGRect labelFrame = label.frame;
        CGFloat labelHeight = labelFrame.size.height > 1.0 ? labelFrame.size.height : ceil(label.font.lineHeight);
        CGFloat labelWidth = CGRectGetMinX(toggle.frame) - kERMICTrailingInset - cursor;
        label.frame = CGRectMake(cursor,
                                 CGRectGetMidY(bounds) - labelHeight * 0.5,
                                 MAX(0.0, labelWidth),
                                 labelHeight);
    }
}

static void ERMICLayoutSubviews(id self, SEL _cmd) {
    if (gERMICSuperLayout) ((void (*)(id, SEL))gERMICSuperLayout)(self, _cmd);
    ERMICApplyLayout((UITableViewCell *)self);
}

static void ERMICRefreshCell(id self, SEL _cmd, PSSpecifier *specifier) {
    if (gERMICSuperRefresh) ((void (*)(id, SEL, id))gERMICSuperRefresh)(self, _cmd, specifier);
    // 1.1.8-7 · 原生 PSSwitchCell 不读 iconImage —— 显式写入 imageView
    @try {
        UIImage *icon = [specifier propertyForKey:@"iconImage"];
        if (icon) ((UITableViewCell *)self).imageView.image = icon;
    } @catch (__unused NSException *e) {}
    ERMICApplyLayout((UITableViewCell *)self);
    [(UITableViewCell *)self setNeedsLayout];
}

void EREnsureModuleIconSwitchCellClassInstalled(void) {
    if (NSClassFromString(kERMICSCellName)) return;

    Class base = NSClassFromString(@"PSSwitchCell");
    if (!base) base = [PSTableCell class];
    if (!base) return;

    Method layoutMethod = class_getInstanceMethod(base, @selector(layoutSubviews));
    Method refreshMethod = class_getInstanceMethod(base, @selector(refreshCellContentsWithSpecifier:));
    if (!layoutMethod && !refreshMethod) return;

    Class cellClass = objc_allocateClassPair(base, kERMICSCellName.UTF8String, 0);
    if (!cellClass) return;

    if (layoutMethod) {
        gERMICSuperLayout = method_getImplementation(layoutMethod);
        class_addMethod(cellClass, @selector(layoutSubviews), (IMP)ERMICLayoutSubviews, "v@:");
    }
    if (refreshMethod) {
        gERMICSuperRefresh = method_getImplementation(refreshMethod);
        class_addMethod(cellClass, @selector(refreshCellContentsWithSpecifier:),
                        (IMP)ERMICRefreshCell, "v@:@");
    }
    objc_registerClassPair(cellClass);
}

@interface ERModuleIconSwitchCellInstaller : NSObject
@end

@implementation ERModuleIconSwitchCellInstaller

// +load 在本 bundle 被 dlopen 的过程中执行，早于 Preferences 解析 specifier。
// 与 ERUtilitySwitchCellInstaller 同因：ERModuleSettingsController 只按名字引用
// cellClass，注册必须自启动。
+ (void)load {
    EREnsureModuleIconSwitchCellClassInstalled();
}

@end
