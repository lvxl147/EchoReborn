#import "ERModuleSettingsController.h"
#import "ERUIHelpers.h"
#import "ERUtilitySwitchCell.h"
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>

// Must match kERPrefsDomain in Tweak.xm and the other panes.
static NSString *const kERModulePrefsDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERModuleReloadNotification = @"com.strive.echoreborn/ReloadPrefs";

static void ERModuleLog(NSString *format, ...) {
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

// The seven standalone connectivity modules, in the same order Control Center's
// "连接" category shows them. identifier is the bundle identifier namespace
// EchoReborn claims; name is the Chinese label; symbol is the SF Symbol used when
// no live glyph is available.
//
// 1.0.3：新增 `color` —— 子页每一行左侧的彩色圆角方块图标用它取色。
// 1.0.4：新增 `symbols` / `assets` —— 候选字形列表。
//
// 为什么需要「候选列表」：蓝牙和隔空投送**没有**对应的 SF Symbol。
//   · AirDrop 的真字形是 ConnectivityModule.bundle 资源目录里的 `AirDropGlyph`
//     （Tweak.xm 自己也得为它单独开一条资源目录分支）；
//   · 蓝牙用的更是一个 CAPackage，没有符号图。
// 只写一个 `symbol` 时这两行会解析失败，ERMakeIcon 便只画彩色底、不画字形 ——
// 这就是用户看到的「蓝牙 / 隔空投送只显示背景」。其余五个模块的名字都是合法
// SF Symbol，所以恰好只有这两行出问题。
// 现在每行都带一串候选（SF Symbol → 系统资源名 → 首字），由
// ERImageIconWithFallbacks 逐个尝试，取到即用。
static NSArray<NSDictionary *> *ERModuleList(void) {
    return @[
        @{@"id": @"com.strive.echoreborn.connectivity.airplane",  @"name": @"飞行模式",   @"symbol": @"airplane", @"color": @"orange",
          @"symbols": @[@"airplane"]},
        @{@"id": @"com.strive.echoreborn.connectivity.wifi",      @"name": @"无线局域网", @"symbol": @"wifi",     @"color": @"blue",
          @"symbols": @[@"wifi"]},
        @{@"id": @"com.strive.echoreborn.connectivity.airdrop",   @"name": @"隔空投送",   @"symbol": @"airdrop",  @"color": @"indigo",
          @"symbols": @[@"airdrop", @"dot.radiowaves.left.and.right", @"antenna.radiowaves.left.and.right"],
          @"assets":  @[@"AirDropGlyph", @"airdrop", @"AirDrop"]},
        @{@"id": @"com.strive.echoreborn.connectivity.cellular",  @"name": @"蜂窝数据",   @"symbol": @"antenna.radiowaves.left.and.right", @"color": @"green",
          @"symbols": @[@"antenna.radiowaves.left.and.right"]},
        @{@"id": @"com.strive.echoreborn.connectivity.bluetooth", @"name": @"蓝牙",       @"symbol": @"bluetooth", @"color": @"blue",
          @"symbols": @[@"bluetooth", @"bolt.horizontal.circle.fill", @"dot.radiowaves.left.and.right"],
          @"assets":  @[@"BluetoothGlyph", @"bluetooth", @"Bluetooth"]},
        @{@"id": @"com.strive.echoreborn.connectivity.hotspot",   @"name": @"个人热点",   @"symbol": @"personalhotspot", @"color": @"teal",
          @"symbols": @[@"personalhotspot"]},
        @{@"id": @"com.strive.echoreborn.connectivity.vpn",       @"name": @"VPN",        @"symbol": @"network", @"color": @"purple",
          @"symbols": @[@"network"]},
    ];
}

// 1.0.6-2：新增「实用工具」卡片。
//
// 与上面七个连接模块同构的一行，只有两点不同：
//   · cellClass = ERUtilitySwitchCell —— 开关在**左**（见 ERUtilitySwitchCell.h），
//     这是需求明确要求的排布；
//   · 该标识符对应的是一块 4×2 的自绘天气磁贴（ERWeatherModule.bundle），
//     不是 CCUIToggleModule。
//
// 开关语义与连接模块完全一致：写入共享偏好域 com.strive.echoreborn.preferences
// 下的 ModuleEnabled_<identifier>，并发布 ReloadPrefs。Tweak.xm 重建「添加控制项」
// 目录时据此过滤，所以关闭后这一项立刻从添加面板消失，重新打开就回来。
static NSArray<NSDictionary *> *ERUtilityFeatureList(void) {
    return @[
        // 1.0.7-2：不再声明 cellClass。此前天气行走 ERUtilitySwitchCell（开关在
        // **左**），而其余七行走原生 PSSwitchCell（开关在**右**）。需求是「天气模块
        // 右边加入开关」，也就是与七个连接行同款：去掉这行声明后自然落到
        // `cell:PSSwitchCell` 的原生布局，读写、通知、图标链路一字不变。
        @{@"id": @"com.strive.echoreborn.weather",
          @"name": @"天气",
          @"symbol": @"cloud.sun.fill",
          @"color": @"blue",
          @"symbols": @[@"cloud.sun.fill", @"sun.max.fill", @"cloud.fill"]},
    ];
}

@interface ERModuleSettingsController ()
- (PSSpecifier *)erSwitchForModule:(NSDictionary *)module;
@end

@implementation ERModuleSettingsController

// A controller pushed by hand never receives a bundle from the Preferences
// framework, so -loadSpecifiersFromPlistName: would fall through to the Settings
// app's own bundle and return nothing. Returning this bundle makes the lookup
// deterministic (see ERGlassListController for the same guard).
- (NSBundle *)bundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specifiers = [NSMutableArray array];
        // 1.0.4：这一页顶部那行独立文案由「模块管理」改为「连接」；
        // 导航栏标题改为「独立模块」（见 -viewDidLoad）。只动文案，行与功能不变。
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"连接"];
        [group setProperty:@"七个自研连接性模块（飞行模式／无线局域网／隔空投送／蜂窝数据／蓝牙／个人热点／VPN）。每一行控制该模块是否出现在控制中心的「添加控制项」里。关闭后该模块不会出现在添加面板中，但已经从面板添加进控制中心的实例不受影响。"
                      forKey:@"footerText"];
        [specifiers addObject:group];
        for (NSDictionary *module in ERModuleList()) {
            [specifiers addObject:[self erSwitchForModule:module]];
        }
        // 1.0.6-2：接在「连接」下方新增「实用工具」卡片。
        // 与「连接」同一套行构造器（-erSwitchForModule:），所以开关的读写、
        // 通知发布、图标解析全部走同一条已验证过的代码路径，没有第二份实现。
        // 1.0.6-14（第 4 条）：这一组的标题原本是「实用功能」，与「添加控制项」里
        // 的分类名不是同一个词。用户要求两边统一叫「实用工具」，所以这里改名，
        // 天气条目在设置页与添加面板里都归「实用工具」。
        PSSpecifier *utilityGroup = [PSSpecifier groupSpecifierWithName:@"实用工具"];
        [utilityGroup setProperty:@"自研的独立功能模块。开关控制该功能是否出现在控制中心的「添加控制项」里。关闭后该功能不会出现在添加面板中，但已经从面板添加进控制中心的实例不受影响。"
                          forKey:@"footerText"];
        [specifiers addObject:utilityGroup];
        for (NSDictionary *feature in ERUtilityFeatureList()) {
            [specifiers addObject:[self erSwitchForModule:feature]];
        }
        _specifiers = specifiers;
        ERModuleLog(@"modulePane: built %lu connectivity + %lu utility row(s)",
                    (unsigned long)ERModuleList().count, (unsigned long)ERUtilityFeatureList().count);
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 1.0.4：子页标题由「连接」改回「独立模块」——与入口行「模块管理」的层级关系
    // 保持「入口 = 模块管理、子页 = 独立模块」的读法；页内顶部那行文案则改为
    // 「连接」，因为下面这七项正是控制中心「连接」分类下的模块。仅改文案。
    self.title = @"独立模块";
    // 1.0.3：给七个模块行挂上左侧图标（erIcon/erIconColor → iconImage）。
    [self erActivateIconRefresh];
}

// 与其余几个子页同样的兜底：从桌面回到设置时 Preferences 会重新解析出一批新的
// PSSpecifier，运行时挂上去的 iconImage 会丢，所以在每次出现时重挂一遍。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self erApplyIcons];
}

- (PSSpecifier *)erSwitchForModule:(NSDictionary *)module {
    NSString *identifier = module[@"id"];
    NSString *name = module[@"name"];
    NSString *key = [NSString stringWithFormat:@"ModuleEnabled_%@", identifier];
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                      target:self
                                                         set:@selector(setPreferenceValue:specifier:)
                                                         get:@selector(readPreferenceValue:)
                                                      detail:Nil
                                                        cell:PSSwitchCell
                                                        edit:Nil];
    [spec setProperty:kERModulePrefsDomain forKey:@"defaults"];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:@YES forKey:@"default"];
    [spec setProperty:kERModuleReloadNotification forKey:@"PostNotification"];
    // 1.0.6-2：可选的自定义 cell。只有声明了 cellClass 的行才会换 cell（目前仅
    // 「实用工具」的天气行，用 ERUtilitySwitchCell 把开关放到左侧，见该文件）。
    // 其余七行不声明，因此继续走原生 PSSwitchCell，外观一字未改。
    //
    // 注意这**不是**降级开关：cellClass 由 Preferences 按名字 NSClassFromString
    // 解析，若那个运行期类没注册成功，框架会退回 `cell:PSSwitchCell` 并用原生布局
    // —— 开关跑到右边，这一行的读写与通知依旧完全正常。
    NSString *cellClassName = module[@"cellClass"];
    if ([cellClassName isKindOfClass:[NSString class]] && cellClassName.length) {
        // 1.0.6-13（第 1 条 · 闪退根因）：这里以前写的是
        //     [spec setProperty:cellClass forKey:@"cellClass"];   // 传的是 NSString
        // 走的是「字符串由框架 NSClassFromString 解析」这条**plist 才有的**约定。
        // 而 PSListController 在 -tableView:cellForRowAtIndexPath: 里拿到这个属性后
        // 是直接对它发 -isSubclassOfClass: 的，于是字符串收到这条消息，抛
        //     -[__NSCFConstantString isSubclassOfClass:]: unrecognized selector
        // → NSInvalidArgumentException → abort。实机日志（iOS 17.2.1）逐帧对得上：
        //   exceptionReason 就是这个选择器，栈顶是
        //   -[PSListController tableView:cellForRowAtIndexPath:]。
        // 这行只出现在「实用工具」的天气行（唯一声明了 cellClass 的行），所以表现
        // 才是「一点开模块管理就闪退」。
        //
        // 代码路径必须传**类对象**（plist 里的字符串才由框架解析）。类没注册成功时
        // 宁可不设这个键，让框架退回 `cell:PSSwitchCell` 的原生布局，也不能把一个
        // 字符串塞进去 —— 那是必崩。
        Class cellClass = NSClassFromString(cellClassName);
        if (cellClass) [spec setProperty:cellClass forKey:@"cellClass"];
        else ERModuleLog(@"modulePane: cellClass '%@' not registered, falling back to PSSwitchCell", cellClassName);
    }
    // 1.0.3：左侧图标。与其余子页共用 ERImageIcon 的 29pt 彩色圆角方块样式，
    // 由 -erApplyIcons 在每次出现时把它挂成 `iconImage` 属性（运行时挂图必须用
    // `iconImage`，写 `icon` 没有任何代码会读 —— 见 ERUIHelpers.m 的说明）。
    // 1.0.4：改挂候选列表（symbols / assets / fallback），蓝牙与隔空投送才有字形。
    NSString *symbol = module[@"symbol"];
    if ([symbol length]) {
        NSArray *symbols = module[@"symbols"];
        [spec setProperty:([symbols isKindOfClass:[NSArray class]] && symbols.count ? symbols : @[symbol])
                   forKey:@"erIconSymbols"];
        NSArray *assets = module[@"assets"];
        if ([assets isKindOfClass:[NSArray class]] && assets.count) {
            [spec setProperty:assets forKey:@"erIconAssets"];
        }
        [spec setProperty:(name ?: symbol) forKey:@"erIconFallback"];
        // erIcon 保留：其余子页与既有代码仍按它判断「这行要不要挂图标」。
        [spec setProperty:symbol forKey:@"erIcon"];
        [spec setProperty:(module[@"color"] ?: @"gray") forKey:@"erIconColor"];
    }
    return spec;
}

@end
