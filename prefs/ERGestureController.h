#import <Preferences/PSListController.h>

// 1.2.0-1 · 子页「桌面胶囊手势」。
//
// 桌面搜索胶囊（home screen search pill）的四向滑动手势设置页：
//   · 卡片1 搜索胶囊总开关（HomeScreen.SearchPill.Enabled）
//   · 卡片2 上/下/左/右滑四行，每行右侧圆角下拉框选择「无动作 / 第1页…第N页」
//   · 卡片3 手势震动反馈（开关 + 轻/中/重三档）
// 偏好域与插件主域一致（com.strive.echoreborn.preferences），Tweak.xm 侧按同名键读取。
@interface ERGestureController : PSListController
@end
