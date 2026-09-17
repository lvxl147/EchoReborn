#import <Preferences/PSListController.h>

// 模块管理子页（「连接」七个 echoreborn.connectivity.* 模块 + 「实用工具」卡片）
// 的配置页。
// 1.0.4：导航栏标题为「独立模块」，页内第一个分组文案为「连接」。
//        （1.0.3 曾把两者对调，本次按需求改回并固定下来。）
// 1.0.6-2：在「连接」下方新增「实用工具」分组，内含天气磁贴（4×2 自绘内容模块，
//        com.strive.echoreborn.weather）一行。该行的开关位于**卡片左侧**，由运行期
//        注册的 ERUtilitySwitchCell 实现；其余行沿用原生 PSSwitchCell，未改外观。
//
// 与 分类管理 / 快捷指令管理 / 液态玻璃 三个页面完全一致的处理方式：
// 由 ERRootListController 用 hand-push 直接推出，不经过 PSLinkCell 的
// 跨 bundle 类查找——那套查找正是 0.5.6.21「设置入口点不动」的根因
// （action 选择器未被框架识别 → 静默失败、点了没反应）。本控制器由同
// 一 bundle 编译、同一导航栈推出，彻底绕开该查找。
//
// 每一个开关行都写入共享偏好域 com.strive.echoreborn.preferences 下的
// ModuleEnabled_<identifier>，并发布 com.strive.echoreborn/ReloadPrefs；Tweak.xm
// 在重建「添加控制项」目录时据此过滤（见 availableControlCatalog 里的门控）。
@interface ERModuleSettingsController : PSListController
@end
