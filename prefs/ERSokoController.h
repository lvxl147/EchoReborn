#import <Preferences/PSListController.h>

NS_ASSUME_NONNULL_BEGIN

/// 锁屏控制项（Soko）子页：直接读写 SokoLayout 的偏好域，
/// 写值域与通知名都指向 SokoLayout 项目，本页只是「画这一页」的地方。
@interface ERSokoController : PSListController
@end

NS_ASSUME_NONNULL_END
