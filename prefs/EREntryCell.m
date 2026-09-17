#import "EREntryCell.h"
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 入口行要的是系统设置那种「左图标 + 深色文字 + 右侧箭头」。PSButtonCell 给的是
// 系统蓝文字、且没有箭头。
//
// 为什么不在编译期写 `@interface XXX : PSButtonCell` —— 见 VERSIONING.md 迭代 34
// 的踩坑记录（0.5.21 曾因此回退过一整版）：
//   · Theos vendor 头文件把 `PSButtonCell` 声明为 `PSCellType` 枚举成员
//     （`Preferences/PSTableCell.h:19`），同名标识符已是枚举常量，于是
//     `@interface PSButtonCell : PSTableCell` 报
//         redefinition of 'PSButtonCell' as different kind of symbol
//         reference to 'PSButtonCell' is ambiguous
//   · `__has_include(<Preferences/PSButtonCell.h>)` 为假 —— vendor 头文件集不含
//     该类的接口。
//
// 所以只能在**运行期**建子类。三个刻意的选择：
//   · 类名不叫 EREntryCell（或任何有编译期 @interface 的名字）——
//     objc_allocateClassPair 对已存在的名字会返回 NULL，重名就静默不注册。
//   · 基类优先取 PSButtonCell 而不是 PSTableCell：PSListController 仍按「按钮 cell」
//     分发 action，入口的 push 行为一字不变；只有取不到时才退到 PSTableCell。
//   · 覆写方法里**不**用 `struct objc_super` + `objc_msgSendSuper`，而是在注册时
//     用 method_getImplementation 缓存基类 IMP、之后直接调用。省掉 objc_super
//     的字段布局假设、也省掉 arm64e 上 super 派发函数的可用性分歧，
//     少两个可能引入崩溃的环节。基类没实现该方法时干脆不注册覆写（不做半截替换）。
//
// 只改外观、不动行为：先调用基类实现，再覆盖 label 颜色与右侧箭头。
// layoutSubviews 里再补一次，是因为 PSButtonCell 有可能在自己的布局阶段回写文字颜色。
//
// 失败降级：若本类因任何原因没注册成功，Root.plist 的 `cell` 仍是 PSButtonCell，
// 框架会落到它 —— 入口照样能点开，只是文字是系统蓝、没有箭头，**不会**变成
// 「点了没反应」。这是刻意保留的双保险。

NSString *const EREntryCellClassName = @"EREntryButtonCell";

static NSString *const kEREntryCellName = @"EREntryButtonCell";

static IMP gERSuperRefresh = NULL;
static IMP gERSuperLayout = NULL;

static void EREntryApplyAppearance(UITableViewCell *cell) {
    if (!cell) return;
    UIColor *label = [UIColor labelColor];
    cell.textLabel.textColor = label;
    cell.detailTextLabel.textColor = label;
    if (cell.accessoryType != UITableViewCellAccessoryDisclosureIndicator) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
}

static void EREntryRefresh(id self, SEL _cmd, PSSpecifier *specifier) {
    if (gERSuperRefresh) ((void (*)(id, SEL, id))gERSuperRefresh)(self, _cmd, specifier);
    EREntryApplyAppearance(self);
}

static void EREntryLayout(id self, SEL _cmd) {
    if (gERSuperLayout) ((void (*)(id, SEL))gERSuperLayout)(self, _cmd);
    EREntryApplyAppearance(self);
}

void EREnsureEntryCellClassInstalled(void) {
    if (NSClassFromString(kEREntryCellName)) return;

    Class base = NSClassFromString(@"PSButtonCell");
    if (!base) base = [PSTableCell class];
    if (!base) return;

    Method refreshMethod = class_getInstanceMethod(base, @selector(refreshCellContentsWithSpecifier:));
    Method layoutMethod = class_getInstanceMethod(base, @selector(layoutSubviews));
    if (!refreshMethod && !layoutMethod) return;

    Class cellClass = objc_allocateClassPair(base, kEREntryCellName.UTF8String, 0);
    if (!cellClass) return;

    if (refreshMethod) {
        gERSuperRefresh = method_getImplementation(refreshMethod);
        class_addMethod(cellClass, @selector(refreshCellContentsWithSpecifier:),
                        (IMP)EREntryRefresh, "v@:@");
    }
    if (layoutMethod) {
        gERSuperLayout = method_getImplementation(layoutMethod);
        class_addMethod(cellClass, @selector(layoutSubviews), (IMP)EREntryLayout, "v@:");
    }
    objc_registerClassPair(cellClass);
}

@interface EREntryCellInstaller : NSObject
@end

@implementation EREntryCellInstaller

// +load 在本 bundle 被 dlopen 的过程中执行，早于 Preferences 解析 Root.plist
// （`cellClass` 是按名字 NSClassFromString 解析的，类必须已经注册）。
+ (void)load {
    EREnsureEntryCellClassInstalled();
}

@end
