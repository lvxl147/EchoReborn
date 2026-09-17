#import "ERSiriController.h"
#import "ERUIHelpers.h"
#import <Preferences/PSSpecifier.h>
#import <notify.h>

// v7 子页 B · iOS27 Siri（LiquidSiri）。
//
// 本页只负责「画」这一页：它直接写 LiquidSiri 原版的偏好域
// com.yourcompany.liquidsiri.prefs，键名也不加前缀，和上游 Root.plist 完全
// 一致（enabled / yOffset / orbScale / customWidth / customHeight /
// customCorner / customRefraction）。Tweak 侧的读取代码因此一个字都不用改。
//
// 之所以不并入 com.strive.echoreborn.preferences：上游的总开关键就叫
// enabled，而 EchoReborn 自己也有同名开关，两者在同一域里会互相覆盖。分域后
// 两边互不干扰，Soko 那页仍然走 EchoReborn 域（soko_ 前缀）。
//
// readPreferenceValue: / setPreferenceValue:specifier: 为什么自己实现：
// 同 ERSokoController 的说明 —— 框架默认实现解析不到域就返回 nil，
// `default` 被忽略，于是开关显示「关」、滑杆显示 0，而 Tweak 侧回落自己的
// 默认值照常生效，两边劈叉。这里统一走 CFPreferences，并在 key 未写入时
// 显式回落 specifier 的 default。
static NSString *const kSiriSuite  = @"com.yourcompany.liquidsiri.prefs";
static NSString *const kSiriReload = @"com.strive.echoreborn/ReloadPrefs";

@implementation ERSiriController

- (NSBundle *)bundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Siri" target:self];
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"iOS27 Siri";
    [self erActivateIconRefresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self erApplyIcons];
}

#pragma mark - 读 / 写（域取自 specifier 的 defaults，缺省回落本页域）

- (NSString *)erDomainForSpecifier:(PSSpecifier *)specifier {
    NSString *domain = [specifier propertyForKey:@"defaults"];
    return [domain length] ? domain : kSiriSuite;
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

- (void)resetSliders {
    // 六个外观项全部回到默认值：删掉 key 后由读取处回落
    // （yOffset=0，orbScale/customWidth/customHeight/customCorner=1.0，customRefraction=1.4）
    [self erRemoveKeys:@[@"yOffset",
                          @"orbScale",
                          @"customWidth",
                          @"customHeight",
                          @"customCorner",
                          @"customRefraction"]];
}

- (void)erRemoveKeys:(NSArray<NSString *> *)keys {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSiriSuite];
    for (NSString *key in keys) {
        [defaults removeObjectForKey:key];
    }
    [defaults synchronize];
    notify_post(kSiriReload.UTF8String);
    [self reloadSpecifiers];
}

@end
