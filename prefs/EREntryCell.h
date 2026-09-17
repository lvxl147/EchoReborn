#import <Foundation/Foundation.h>

// 入口行（增强设置 / 液态玻璃 / 分类管理 / 快捷指令 / 模块管理）的自定义 cell。
//
// 编译期**没有**任何 @interface 与下面这个名字同名：这个类是在运行期用
// objc_allocateClassPair(NSClassFromString(@"PSButtonCell"), EREntryCellClassName, 0)
// 建出来的 PSButtonCell 子类，注册由 +load 自动完成（见 EREntryCell.m 的说明）。
//
// Root.plist 的 `cellClass` 按名字解析，所以两处必须字面一致：
//   prefs/Resources/Root.plist  ->  <string>EREntryButtonCell</string>
//   EREntryCell.m              ->  kEREntryCellName
FOUNDATION_EXPORT NSString *const EREntryCellClassName;

/// 幂等注册。已经注册过就直接返回，可安全重复调用。
void EREnsureEntryCellClassInstalled(void);
