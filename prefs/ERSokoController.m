#import "ERSokoController.h"
#import "ERUIHelpers.h"
#import <Preferences/PSSpecifier.h>
#import <notify.h>

// v7 子页 A · 锁屏控制项（Soko）。
//
// 本页只负责「画这一页」：它直接读写 Soko 移植版所用的偏好域
// com.strive.echoreborn.preferences，键名沿用上游的 `soko_` 前缀
// （soko_widgetsEnabled / soko_widgetOffset / soko_notificationsEnabled /
//  soko_notificationOffset），与 Soko/Shared/Preferences/Preferences.swift
// 的读取键逐字一致。
//
// 为什么要自己实现 readPreferenceValue: / setPreferenceValue:specifier:——
// ---------------------------------------------------------------------------
// 这是 0.5.26 实机上「开关显示关、滑杆显示 0，但两个效果都生效」的根因。
//
// PSListController 默认的 readPreferenceValue: 依赖能从 specifier 解析出偏好
// 域（specifier 自带的 `defaults`）。解析不到域时它返回 nil，于是：
//   · 开关读成 nil  → 显示「关」；
//   · 滑杆读成 nil  → 0，再被 min 夹住，看上去就是滑杆停在最左端；
//   · plist 里的 `default` 被整体忽略。
// 而 Tweak 侧读到 key 不存在会回落自己的默认值（true / -18 / 60），两边就劈叉了。
//
// 这里按 0.5.22 `ERSegmentedCell` 已经验证过的做法重写读、写：
// 全部走 CFPreferences + specifier 自带的 `defaults` / `key` /
// `PostNotification`，读不到 key 时**显式回落 specifier 的 default**。
// 这样本页显示什么，SpringBoard 里就是什么，两边同源。
static NSString *const kSokoSuite  = @"com.strive.echoreborn.preferences";
static NSString *const kSokoReload = @"com.strive.echoreborn/ReloadPrefs";

@implementation ERSokoController

// 与 EREnhancedSettingsController 一致：明确回到本包，避免 Preferences
// 用宿主（设置 App）的 bundle 去找 Soko.plist。
- (NSBundle *)bundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Soko" target:self];
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"锁屏控制项";
    [self erActivateIconRefresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self erApplyIcons];
}

#pragma mark - 读 / 写（域取自 specifier 的 defaults，缺省回落本页域）

- (NSString *)erDomainForSpecifier:(PSSpecifier *)specifier {
    NSString *domain = [specifier propertyForKey:@"defaults"];
    return [domain length] ? domain : kSokoSuite;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id fallback = [specifier propertyForKey:@"default"];
    if (![key length]) return fallback;

    CFStringRef domain = (__bridge CFStringRef)[self erDomainForSpecifier:specifier];
    CFPreferencesAppSynchronize(domain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, domain);
    if (!value) return fallback;              // 未写入过 → 用 plist 的 default
    return CFBridgingRelease(value);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key length]) return;

    CFStringRef domain = (__bridge CFStringRef)[self erDomainForSpecifier:specifier];
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             domain);
    CFPreferencesAppSynchronize(domain);

    NSString *note = [specifier propertyForKey:@"PostNotification"];
    if ([note length]) notify_post(note.UTF8String);
}

#pragma mark - 重置动作（删 key 回落默认，并广播重载）

- (void)resetWidgetOffset {
    [self erRemoveKeys:@[@"soko_widgetOffset"]];
}

- (void)resetNotificationOffset {
    [self erRemoveKeys:@[@"soko_notificationOffset"]];
}

- (void)erRemoveKeys:(NSArray<NSString *> *)keys {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSokoSuite];
    for (NSString *key in keys) {
        [defaults removeObjectForKey:key];
    }
    [defaults synchronize];
    notify_post(kSokoReload.UTF8String);
    [self reloadSpecifiers];
}

@end
