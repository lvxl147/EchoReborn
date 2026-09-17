#import <Foundation/Foundation.h>

// 「实用工具」卡片那行用的自定义 cell：**开关在左**，标题在右。
//
// 与 EREntryCell 完全相同的成因与做法：编译期**没有**任何 @interface 与下面这个
// 名字同名，这个类是在运行期用
//     objc_allocateClassPair(NSClassFromString(@"PSSwitchCell"), 名字, 0)
// 建出来的 PSSwitchCell 子类，注册由 +load 自动完成（见 .m 的详细说明）。
//
// 为什么必须运行期建类（0.5.21 曾因此回退过一整版）：Theos 的 vendor 头文件
// （Preferences/PSTableCell.h）把 PSSwitchCell 声明为 `PSCellType` 枚举成员，
// 于是 `@interface XXX : PSSwitchCell` 会报
//     redefinition of 'PSSwitchCell' as different kind of symbol
//     reference to 'PSSwitchCell' is ambiguous
// 而 `__has_include(<Preferences/PSSwitchCell.h>)` 为假 —— vendor 头文件集里没有
// 该类的接口。所以只能运行期建。
//
// Root.plist / PSSpecifier 的 `cellClass` 按名字解析，所以两处必须字面一致：
//     ERModuleSettingsController.m -> kERUtilitySwitchCellName
//     ERUtilitySwitchCell.m        -> kERUtilitySwitchCellName
FOUNDATION_EXPORT NSString *const ERUtilitySwitchCellClassName;

/// 幂等注册。已经注册过就直接返回，可安全重复调用。
void EREnsureUtilitySwitchCellClassInstalled(void);
