#import <Preferences/PSListController.h>

NS_ASSUME_NONNULL_BEGIN

/// 1.0.7 · 子页 C · 系统增强。
///
/// 目前只有一张卡「相机增强」，卡里一行「相机双摄」开关，写 EchoReborn 自己的
/// 偏好域 com.strive.echoreborn.preferences 的 DualCamEnabled 键，并广播
/// com.strive.echoreborn/ReloadPrefs。
///
/// 这一版本页只负责「画这一页」与落盘；相机侧的双摄组件（单独的
/// EchoRebornDualCam.dylib，只注入 com.apple.camera）在下一轮读取同一个键。
/// 所以本页上线后即使相机组件还没做，开关也不会「点了没反应」—— 它的完整语义
/// 就是把这个偏好值写下去。
///
/// readPreferenceValue: / setPreferenceValue:specifier: 自己实现的原因与
/// ERSiriController / ERSokoController 完全相同：框架默认实现解析不到域时返回
/// nil，plist 里的 `default` 会被忽略，于是开关显示「关」而 tweak 侧回落自己的
/// 默认值照常生效，两边劈叉。这里统一走 CFPreferences，并在键未写入时显式回落
/// specifier 的 default。
@interface ERSystemEnhanceController : PSListController
@end

NS_ASSUME_NONNULL_END
