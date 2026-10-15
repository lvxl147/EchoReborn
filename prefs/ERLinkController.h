#import <Preferences/PSViewController.h>

// 「快捷方式」管理器 —— 与「快捷指令」并排的第二个用户自定义控制项分类。
//
// 一条快捷方式要么是「打开某个 App」，要么是「打开一个链接（网址或 URL
// Scheme）」。图标可以是 SF 符号、App 标识符、图片链接或本地导入的图片。
//
// 数据放在共享偏好域的 LinkCatalog 里，由本 bundle（Preferences 进程）写入、
// 由 Tweak.xm（SpringBoard）读出来画控制中心磁贴 —— 与快捷指令那套
// 「设置进程读库、SpringBoard 只消费」的分工完全一致。
//
// 同 ERShortcutController：刻意不用 PSListController、不经 PSLinkCell，
// 由 ERRootListController 直接 push，绕开 Preferences 的跨 bundle 类查找。
@interface ERLinkController : PSViewController
@end
