#import "ERSystemEnhanceController.h"
#import "ERUIHelpers.h"
#import <Preferences/PSSpecifier.h>
#import <notify.h>

// 1.0.7 · 子页 C · 系统增强（见 ERSystemEnhanceController.h 的说明）。
//
// 为什么用 EchoReborn 自己的域：这一页的东西是 EchoReborn 自己实现的（相机侧
// 双摄也是随包发布的 dylib），不是移植上游项目，因此没有「上游同名键冲突」的
// 顾虑 —— 与 Soko 那页（soko_ 前缀、同域）保持同一套做法即可。
static NSString *const kERSystemSuite = @"com.strive.echoreborn.preferences";
static NSString *const kERSystemReload = @"com.strive.echoreborn/ReloadPrefs";

// 1.0.7-1：与 ERModuleSettingsController 的 ERModuleLog 同一份实现。本页此前一行
// 日志都没有，「点了没反应」时无法判断是没进来还是 plist 装载失败。
static void ERSystemLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [PREFS] %@\n", [NSDate date].description, message];
    NSString *directory = @"/var/mobile/Library/Logs/EchoReborn";
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"echoreborn.log"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *exception) {
    } @finally {
        @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
    }
}

@implementation ERSystemEnhanceController

// 与 ERModuleSettingsController 同一个坑：手动 push 出来的控制器拿不到框架注入
// 的 bundle，-loadSpecifiersFromPlistName: 会落到设置 App 自己的 bundle 上返回空。
- (NSBundle *)bundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *loaded = [self loadSpecifiersFromPlistName:@"SystemEnhance" target:self];
        ERSystemLog(@"system-enhance: plist loaded %lu specifier(s)", (unsigned long)loaded.count);
        if (loaded.count) {
            _specifiers = [loaded copy];
        } else {
            // 1.0.7-1：plist 装载失败时用代码兜底构造**同一张卡、同一个开关**，
            // 保证这一页永远不会是一页空白。键名、默认值、通知名与 plist 逐字一致。
            NSMutableArray *specs = [NSMutableArray array];
            PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"相机增强"];
            [group setProperty:@"开启后，相机 App 顶部「实况」图标左侧会出现一个双摄按钮，点击即可同时调用前后摄像头拍摄，前后两张照片分别存入相册。关闭时该按钮不会出现，相机进程也不会加载双摄组件。"
                        forKey:@"footerText"];
            [specs addObject:group];

            PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"相机双摄"
                                                             target:self
                                                                set:@selector(setPreferenceValue:specifier:)
                                                                get:@selector(readPreferenceValue:)
                                                             detail:Nil
                                                               cell:PSSwitchCell
                                                              edit:Nil];
            [sw setProperty:@"DualCamEnabled" forKey:@"key"];
            [sw setProperty:kERSystemSuite forKey:@"defaults"];
            [sw setProperty:@NO forKey:@"default"];
            [sw setProperty:@"com.strive.echoreborn/ReloadPrefs" forKey:@"PostNotification"];
            [sw setProperty:ERImageIconWithFallbacks(@[@"camera.on.rectangle",
                                                       @"rectangle.on.rectangle",
                                                       @"square.on.square",
                                                       @"camera.fill"],
                                                      nil,
                                                      @"摄",
                                                      @"green")
                     forKey:@"iconImage"];
            [specs addObject:sw];
            // 1.0.7-20：plist 装载失败时的代码兜底也要与 plist 逐项对齐，
            // 否则「小窗位置」会只在 plist 正常时才出现。
            PSSpecifier *corner = [PSSpecifier preferenceSpecifierNamed:@"小窗位置"
                                                                 target:self
                                                                    set:@selector(setPreferenceValue:specifier:)
                                                                    get:@selector(readPreferenceValue:)
                                                                 detail:Nil
                                                                   cell:PSTitleValueCell
                                                                  edit:Nil];
            [corner setProperty:@"ERSegmentedCell" forKey:@"cellClass"];
            [corner setProperty:@"DualCam.Corner" forKey:@"key"];
            [corner setProperty:kERSystemSuite forKey:@"defaults"];
            [corner setProperty:@1 forKey:@"default"];
            [corner setProperty:@[@"左上", @"右上", @"左下", @"右下"] forKey:@"erSegmentTitles"];
            [corner setProperty:@"com.strive.echoreborn/ReloadPrefs" forKey:@"PostNotification"];
            [specs addObject:corner];
            _specifiers = specs;
            ERSystemLog(@"system-enhance: plist EMPTY -> built %lu specifier(s) in code",
                       (unsigned long)specs.count);
        }
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"系统增强";
    [self erActivateIconRefresh];
    ERSystemLog(@"system-enhance: viewDidLoad title=%@ specifiers=%lu",
                self.title, (unsigned long)self.specifiers.count);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从桌面回到设置时 Preferences 会重新解析出一批新的 PSSpecifier，运行时挂
    // 上去的 iconImage 会丢，所以每次出现都重挂一遍。
    [self erApplyIcons];
}

#pragma mark - 读 / 写（域取自 specifier 的 defaults，缺省回落本页域）

- (NSString *)erDomainForSpecifier:(PSSpecifier *)specifier {
    NSString *domain = [specifier propertyForKey:@"defaults"];
    return [domain length] ? domain : kERSystemSuite;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id fallback = [specifier propertyForKey:@"default"];
    if (![key length]) return fallback;

    CFStringRef domain = (__bridge CFStringRef)[self erDomainForSpecifier:specifier];
    CFPreferencesAppSynchronize(domain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, domain);
    if (!value) return fallback;              // 未写入过 → 用 plist 里的 default
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
    ERSystemLog(@"system-enhance: set %@ = %@ (domain %@)", key, value, [self erDomainForSpecifier:specifier]);
}

@end
