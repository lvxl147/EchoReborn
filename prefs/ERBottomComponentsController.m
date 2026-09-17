#import "ERBottomComponentsController.h"
#import "ERUIHelpers.h"
#import <Preferences/PSSpecifier.h>
#import <notify.h>

// 1.0.7-29 · 子页「底部组件」（LSMusicCapsule 移植）。
//
// 页面结构：先「音乐胶囊」一节（启用 + 布局三条滑杆），后续新增的底部组件
// 就往下继续加。滑杆样式与「操作按钮」页一致（ERSliderTrackCell / 高 54 /
// 显示数值 / 非连续）。
//
// 读 / 写与 ERSokoController 同一套写法：全部走 CFPreferences + specifier 自带的
// defaults / key / PostNotification，读不到 key 时显式回落 specifier 的 default ——
// 这样本页显示什么、SpringBoard 里就是什么（详见 ERSokoController.m 顶部的长注释）。
static NSString *const kERBottomSuite  = @"com.strive.echoreborn.preferences";
static NSString *const kERBottomReload = @"com.strive.echoreborn/ReloadPrefs";

@implementation ERBottomComponentsController

- (NSBundle *)bundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"BottomComponents" target:self];
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"底部组件";
    [self erActivateIconRefresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self erApplyIcons];
}

#pragma mark - 读 / 写（域取自 specifier 的 defaults，缺省回落本页域）

- (NSString *)erDomainForSpecifier:(PSSpecifier *)specifier {
    NSString *domain = [specifier propertyForKey:@"defaults"];
    return [domain length] ? domain : kERBottomSuite;
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

    // 1.0.7-29：本页不带「注销」按钮 —— 改动通过 ReloadPrefs 通知实时生效。
    NSString *note = [specifier propertyForKey:@"PostNotification"];
    if ([note length]) notify_post(note.UTF8String);
    else notify_post(kERBottomReload.UTF8String);
}

@end
