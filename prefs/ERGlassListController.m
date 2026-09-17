#import "ERGlassListController.h"
#import <Preferences/PSSpecifier.h>

// Must match kERPrefsDomain in Tweak.xm, and the Darwin notification that
// GlassKit (SpringBoard) and EchoRebornBackboardd (render server) both observe.
static NSString *const kERGlassPrefsDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERGlassReloadNotification = @"com.strive.echoreborn/ReloadPrefs";

// Same logging sink the rest of the bundle uses (see ERCategoryOrderController).
// Which path built the pane (plist vs. code) is the one fact that cannot be
// observed from the UI, so it is written out here.
static void ERGlassLog(NSString *message) {
    NSString *directory = @"/var/mobile/Library/Logs/EchoReborn";
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"echoreborn.log"];
    NSString *line = [NSString stringWithFormat:@"%@ [PREFS] %@\n",
                      [NSDate date].description, message];
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

@interface ERGlassListController ()
- (NSMutableArray *)erBuiltInSpecifiers;
- (PSSpecifier *)erGroupWithHeader:(NSString *)header footer:(NSString *)footer;
- (PSSpecifier *)erSwitchNamed:(NSString *)name key:(NSString *)key defaultValue:(NSNumber *)value;
- (PSSpecifier *)erSliderNamed:(NSString *)name
                            key:(NSString *)key
                   defaultValue:(NSNumber *)value
                        minimum:(NSNumber *)minimum
                        maximum:(NSNumber *)maximum;
@end

@implementation ERGlassListController

// -------------------------------------------------------------------------
// A controller that is pushed by hand never receives a bundle from the
// Preferences framework. Only controllers the framework instantiates itself --
// from a PSLinkCell's detail/isController pair, or from the PreferenceLoader
// entry -- get one assigned. -loadSpecifiersFromPlistName: resolves Glass.plist
// through that bundle, so with a nil bundle the lookup falls through to the
// Settings app's own bundle, finds no Glass.plist and returns nothing: the pane
// then renders as an empty shell with a correct title and zero rows. Returning
// the bundle this controller is compiled into makes the lookup deterministic
// instead of depending on how the controller happened to be created.
// -------------------------------------------------------------------------
- (NSBundle *)bundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Glass" target:self];
        ERGlassLog([NSString stringWithFormat:@"glassPane: plist path -> %lu specifier(s)",
                     (unsigned long)[_specifiers count]]);
    }
    // Safety net. If the plist cannot be resolved for any reason, build the same
    // pane in code so the page is never a blank sheet with no explanation --
    // the failure mode this pane shipped with once already.
    if ([_specifiers count] == 0) {
        _specifiers = [self erBuiltInSpecifiers];
        ERGlassLog([NSString stringWithFormat:@"glassPane: fell back to built-in specifiers (%lu)",
                     (unsigned long)[_specifiers count]]);
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"液态玻璃";
}

#pragma mark - built-in pane (fallback)

- (PSSpecifier *)erGroupWithHeader:(NSString *)header footer:(NSString *)footer {
    PSSpecifier *group = header.length ? [PSSpecifier groupSpecifierWithName:header]
                                       : [PSSpecifier emptyGroupSpecifier];
    if (footer.length) [group setProperty:footer forKey:@"footerText"];
    return group;
}

- (PSSpecifier *)erSwitchNamed:(NSString *)name
                            key:(NSString *)key
                   defaultValue:(NSNumber *)value {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                      target:self
                                                         set:@selector(setPreferenceValue:specifier:)
                                                         get:@selector(readPreferenceValue:)
                                                      detail:Nil
                                                        cell:PSSwitchCell
                                                        edit:Nil];
    [spec setProperty:kERGlassPrefsDomain forKey:@"defaults"];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:value forKey:@"default"];
    [spec setProperty:kERGlassReloadNotification forKey:@"PostNotification"];
    return spec;
}

- (PSSpecifier *)erSliderNamed:(NSString *)name
                            key:(NSString *)key
                   defaultValue:(NSNumber *)value
                        minimum:(NSNumber *)minimum
                        maximum:(NSNumber *)maximum {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                      target:self
                                                         set:@selector(setPreferenceValue:specifier:)
                                                         get:@selector(readPreferenceValue:)
                                                      detail:Nil
                                                        cell:PSSliderCell
                                                        edit:Nil];
    [spec setProperty:kERGlassPrefsDomain forKey:@"defaults"];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:value forKey:@"default"];
    [spec setProperty:minimum forKey:@"min"];
    [spec setProperty:maximum forKey:@"max"];
    [spec setProperty:@YES forKey:@"showValue"];
    [spec setProperty:@NO forKey:@"isContinuous"];
    [spec setProperty:kERGlassReloadNotification forKey:@"PostNotification"];
    return spec;
}

// Mirrors Glass.plist exactly. Keep the two in sync if the plist changes.
// PSListController declares _specifiers as NSMutableArray, so this returns the
// mutable array itself rather than an immutable copy.
- (NSMutableArray *)erBuiltInSpecifiers {
    NSMutableArray *specifiers = [NSMutableArray array];
    [specifiers addObject:[self erGroupWithHeader:nil
        footer:@"从 LiquidAss 移植的液态玻璃渲染管线，为控制中心模块提供折射玻璃效果，不再需要安装 LiquidAss。总开关关闭时会实时移除已生效的玻璃效果。"]];
    [specifiers addObject:[self erSwitchNamed:@"启用液态玻璃"
                                          key:@"Global.Enabled"
                                 defaultValue:@YES]];
    [specifiers addObject:[self erGroupWithHeader:@"控制中心模块"
        footer:@"为控制中心中的模块与滑块注入液态玻璃。首次启用或彻底关闭后，建议注销一次以获得最佳效果；日常开关实时生效。"]];
    [specifiers addObject:[self erSwitchNamed:@"模块液态效果"
                                          key:@"ControlCenter.Enabled"
                                 defaultValue:@YES]];
    [specifiers addObject:[self erGroupWithHeader:@"高光"
        footer:@"玻璃边缘的高光描边，以及随设备倾斜角度变化的高光视差。"]];
    [specifiers addObject:[self erSwitchNamed:@"边缘高光"
                                          key:@"ControlCenter.SpecularEnabled"
                                 defaultValue:@YES]];
    [specifiers addObject:[self erSwitchNamed:@"动态高光（视差）"
                                          key:@"Specular.Motion.Enabled"
                                 defaultValue:@YES]];
    [specifiers addObject:[self erSliderNamed:@"视差灵敏度"
                                          key:@"Specular.Motion.Sensitivity"
                                 defaultValue:@2
                                      minimum:@0.5
                                      maximum:@5]];
    [specifiers addObject:[self erGroupWithHeader:nil
        footer:@"渲染由系统渲染服务（backboardd）内的 EchoRebornBackboardd 组件完成，与控制中心样式（EchoReborn 主开关）相互独立。若出现花屏或性能问题，可先关闭「模块液态效果」验证。"]];
    return specifiers;
}

@end
