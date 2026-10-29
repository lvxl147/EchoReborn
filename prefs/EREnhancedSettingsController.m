#import "EREnhancedSettingsController.h"
#import "ERUIHelpers.h"
#import <Preferences/PSSpecifier.h>

// 增强设置子页：四个分区（控制中心分页 / 操作按钮 / 调节控件 / 震动反馈）
// 全部内联在本页，不再各自进入子页。手推方式加载，绕开 Preferences 的跨 bundle
// 类查找失败（与 Root 页的其它入口一致）。
@implementation EREnhancedSettingsController

- (NSBundle *)bundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Enhanced" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"增强设置";
    // 1.2.1-134 · 「启动」开关已搬进本页 —— 初值捕获必须在这里做一次（幂等）。
    // 此前只在根页调用，本页永远拿不到初值 → setMasterEnabled 的 needsRespring
    // 恒为 NO → 注销提醒弹窗与导航栏重启按钮都不出现（用户实锤"弹窗没有生效"）。
    [self erStoreInitialMasterEnabled];
    // 为本页带 erIcon/erIconColor 的 specifier 注入彩色圆角图标，并注册兜底重挂。
    [self erActivateIconRefresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self erApplyIcons];
}

@end
