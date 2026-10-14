#import <Foundation/Foundation.h>

// 「模块管理」七行用的自定义 cell：图标在左，标题居中，开关在右（系统默认位置）。
//
// 为什么需要它（1.1.8-7）：iOS 17.2 的原生 PSSwitchCell 不渲染 iconImage ——
// 模块管理七行挂了 erIconSymbols 但左侧始终空白。本类在 refresh 时显式把
// specifier 的 iconImage 写进 cell.imageView，并在布局时给图标留出左侧位置。
//
// 与 ERUtilitySwitchCell 完全相同的成因与做法：编译期没有任何 @interface 与
// 这个名字同名，类在运行期用 objc_allocateClassPair(NSClassFromString(@"PSSwitchCell"),
// 名字, 0) 建出来（Theos 的 vendor 头文件把 PSSwitchCell 声明为枚举成员，
// 编译期继承会报 redefinition）。注册由 +load 自动完成。
//
// 失败降级：本类没注册成功时，specifier 的 cellClass 落回 PSSwitchCell 原生布局，
// 读写偏好与 PostNotification 完全不受影响（图标只是不显示，回到旧行为）。
FOUNDATION_EXPORT NSString *const ERModuleIconSwitchCellClassName;

/// 幂等注册。已注册过就直接返回，可安全重复调用。
void EREnsureModuleIconSwitchCellClassInstalled(void);
