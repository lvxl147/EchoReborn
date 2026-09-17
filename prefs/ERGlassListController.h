#import <Preferences/PSListController.h>

// 液态玻璃设置页（0.4.0，LiquidAss 移植）。页面优先由 Glass.plist 驱动；若
// plist 解析不到（例如控制器被手工 push、bundle 未由框架赋值），则在代码里
// 构建同样的一份，避免出现无标题内容的空白面板。无自定义控件：开关与滑块
// 直接读写共享偏好域 com.strive.echoreborn.preferences，并通过 Darwin 通知
// com.strive.echoreborn/ReloadPrefs 让 GlassKit（SpringBoard 侧）与
// EchoRebornBackboardd（渲染服务侧）实时重载参数。
@interface ERGlassListController : PSListController
@end
