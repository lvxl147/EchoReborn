#import <Preferences/PSListController.h>

NS_ASSUME_NONNULL_BEGIN

/// iOS27 Siri（LiquidSiri）子页：直接读写 liquid patch 的偏好域，
/// 写值域与通知名都指向 liquid patch 项目，本页只是「画这一页」的地方。
@interface ERSiriController : PSListController
@end

NS_ASSUME_NONNULL_END
