#import "ERUIHelpers.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>
#import <unistd.h>

// 与 ERRootListController.m 同款：roothide 的 jbroot() 是真实函数，
// rootless/rootful 下用直通 stub 兜底（respring 找 sbreload 路径要用）。
#if __has_include(<roothide.h>)
#import <roothide.h>
#else
static inline NSString *ER_jbrootPath(NSString *path) { return path; }
#define jbroot(p) ER_jbrootPath(p)
#endif

extern char **environ;

static UIColor *ERColorForName(NSString *name) {
    NSDictionary<NSString *, UIColor *> *map = @{
        @"blue":   [UIColor colorWithRed:0.216f green:0.541f blue:0.863f alpha:1.0f],
        @"purple": [UIColor colorWithRed:0.498f green:0.467f blue:0.871f alpha:1.0f],
        @"teal":   [UIColor colorWithRed:0.114f green:0.620f blue:0.461f alpha:1.0f],
        @"orange": [UIColor colorWithRed:0.937f green:0.624f blue:0.153f alpha:1.0f],
        @"amber":  [UIColor colorWithRed:0.729f green:0.459f blue:0.090f alpha:1.0f],
        @"red":    [UIColor colorWithRed:0.851f green:0.290f blue:0.188f alpha:1.0f],
        @"indigo": [UIColor colorWithRed:0.357f green:0.337f blue:0.847f alpha:1.0f],
        @"pink":   [UIColor colorWithRed:0.835f green:0.325f blue:0.494f alpha:1.0f],
        @"green":  [UIColor colorWithRed:0.388f green:0.600f blue:0.133f alpha:1.0f],
        @"gray":   [UIColor colorWithRed:0.533f green:0.527f blue:0.502f alpha:1.0f],
    };
    UIColor *color = map[name.lowercaseString];
    return color ?: map[@"gray"];
}

// ---------------------------------------------------------------------------
// 1.0.4：字形回落链 —— 为什么蓝牙 / 隔空投送只显示背景
// ---------------------------------------------------------------------------
// `ERMakeIcon` 原来只试一个 SF Symbol 名，取不到就静默跳过字形绘制：彩色圆角底
// 照画，白色字形不画。用户看到的就是「只有一块色块，没有图标」。
//
// 而蓝牙与隔空投送恰好都**没有**对应的 SF Symbol：
//   · AirDrop —— 控制中心的真字形是 ConnectivityModule.bundle 资源目录里的
//     `AirDropGlyph`。Tweak.xm 自己就得为它单独开一条资源目录分支
//     （ERConnectivityBundleGlyphImage，见 Tweak.xm 的 AirDrop 注释）。
//   · Bluetooth —— 控制中心用的是 ConnectivityModule.bundle 里的一个
//     **CAPackage**（包名 `Bluetooth`），根本没有符号图。
// 其余五个模块（airplane / wifi / antenna.radiowaves.left.and.right /
// personalhotspot / network）都是合法 SF Symbol，所以恰好只有这两行缺字形。
//
// 现在改成三级回落，并把「首字」当最后一道保险：宁可画一个通用字形，也绝不
// 再交付「有底无字」的半截图标。

// 系统 ConnectivityModule.bundle：AirDrop / 蓝牙等连接性字形的真实来源。
static UIImage *ERSystemConnectivityAsset(NSString *assetName) {
    if (!assetName.length) return nil;
    static NSBundle *connectivityBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        connectivityBundle = [NSBundle bundleWithPath:@"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle"];
    });
    if (connectivityBundle) {
        UIImage *asset = [UIImage imageNamed:assetName inBundle:connectivityBundle compatibleWithTraitCollection:nil];
        if (asset) return asset;
    }
    // 部分系统版本把字形放在 ControlCenter 的其它子 bundle / 全局资源里。
    return [UIImage imageNamed:assetName];
}

static UIImage *ERGlyphFromSymbols(NSArray<NSString *> *symbols) {
    if (!symbols.count) return nil;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
        for (NSString *name in symbols) {
            if (![name isKindOfClass:[NSString class]] || !name.length) continue;
            UIImage *symbol = [UIImage systemImageNamed:name withConfiguration:cfg];
            if (!symbol) continue;
            UIImage *white = [symbol imageWithTintColor:[UIColor whiteColor]
                                          renderingMode:UIImageRenderingModeAlwaysOriginal];
            if (white) return white;
        }
    }
    return nil;
}

static UIImage *ERGlyphFromAssets(NSArray<NSString *> *assetNames) {
    if (!assetNames.count) return nil;
    for (NSString *name in assetNames) {
        if (![name isKindOfClass:[NSString class]] || !name.length) continue;
        UIImage *asset = ERSystemConnectivityAsset(name);
        if (!asset) continue;
        // 资源目录里的字形是模板图；再补一次白色着色，保证在任何底色上都看得见。
        UIImage *white = [asset imageWithTintColor:[UIColor whiteColor]
                                     renderingMode:UIImageRenderingModeAlwaysOriginal];
        return white ?: asset;
    }
    return nil;
}

// 最后一道保险：把文案的首字符当字形画出来。它不是漂亮图标，但它**一定存在**，
// 因此「有底无字」这个失效形态从根上消失。
static void ERDrawFallbackText(NSString *text, CGRect box) {
    if (!text.length) return;
    NSString *initial = [text substringToIndex:1];
    UIFont *font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor whiteColor],
    };
    CGSize textSize = [initial sizeWithAttributes:attributes];
    CGPoint origin = CGPointMake(box.origin.x + (box.size.width - textSize.width) * 0.5,
                                 box.origin.y + (box.size.height - textSize.height) * 0.5);
    [initial drawAtPoint:origin withAttributes:attributes];
}

UIImage *ERImageIconWithFallbacks(NSArray<NSString *> *symbols,
                                  NSArray<NSString *> *assetNames,
                                  NSString *fallbackText,
                                  NSString *colorName) {
    const CGFloat size = 29.0;
    CGRect rect = CGRectMake(0, 0, size, size);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0.0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:7.0];
    [ERColorForName(colorName) setFill];
    [path fill];

    UIImage *glyph = ERGlyphFromSymbols(symbols);
    if (!glyph) glyph = ERGlyphFromAssets(assetNames);
    if (glyph) {
        // 等比放进 16x16 的方框再居中。系统资源目录里的字形宽高比并不都是 1:1
        // （AirDrop 那种「三条弧」尤其偏宽），直接 drawInRect 成一个正方形会拉伸。
        const CGFloat box = 16.0;
        CGSize glyphSize = glyph.size;
        if (glyphSize.width < 0.5 || glyphSize.height < 0.5) glyphSize = CGSizeMake(box, box);
        CGFloat scale = MIN(box / glyphSize.width, box / glyphSize.height);
        CGFloat drawWidth = MAX(1.0, glyphSize.width * scale);
        CGFloat drawHeight = MAX(1.0, glyphSize.height * scale);
        [glyph drawInRect:CGRectMake((size - drawWidth) * 0.5,
                                     (size - drawHeight) * 0.5,
                                     drawWidth, drawHeight)];
    } else {
        ERDrawFallbackText(fallbackText, rect);
    }

    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: [[UIImage alloc] init];
}

UIImage *ERImageIcon(NSString *sfSymbol, NSString *colorName) {
    return ERImageIconWithFallbacks(([sfSymbol length] ? @[sfSymbol] : @[]), nil, sfSymbol, colorName);
}

// ---------------------------------------------------------------------------
// 1.0.4：版本号页脚
// ---------------------------------------------------------------------------
// 版本号**只从本 bundle 的 Info.plist 读**（CFBundleShortVersionString），不写死。
// 这样「构建发布新版本时要同步更新页面上的版本号」这件事从「记得改」变成了
// 「不可能忘」：把 Version 改到 control / Info.plist 上，页面自动跟着变。
//
// 用这个空类做锚点取 bundle：prefs bundle 里 [NSBundle mainBundle] 拿到的是
// Preferences.app，不是我们自己的 bundle。
@interface ERUIHelpersBundleAnchor : NSObject
@end
@implementation ERUIHelpersBundleAnchor
@end

static NSBundle *ERUIHelpersBundle(void) {
    return [NSBundle bundleForClass:[ERUIHelpersBundleAnchor class]];
}

NSString *ERVersionFooterText(void) {
    NSString *version = [ERUIHelpersBundle() objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![version isKindOfClass:[NSString class]] || !version.length) version = @"?";
    return [NSString stringWithFormat:@"Echo Reborn %@", version];
}

NSString *const ERVersionFooterCellClassName = @"ERVersionFooterCell";
NSString *const ERVersionFooterTextKey = @"erVersionText";

static IMP gERVFSuperRefresh = NULL;
static IMP gERVFSuperLayout = NULL;

static void ERVersionFooterRefresh(id self, SEL _cmd, PSSpecifier *specifier) {
    if (gERVFSuperRefresh) ((void (*)(id, SEL, id))gERVFSuperRefresh)(self, _cmd, specifier);
    UITableViewCell *cell = (UITableViewCell *)self;
    if (![cell isKindOfClass:[UITableViewCell class]]) return;

    id text = [specifier propertyForKey:ERVersionFooterTextKey];
    if (![text isKindOfClass:[NSString class]]) text = ERVersionFooterText();

    cell.textLabel.text = text;
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.textLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    cell.textLabel.textColor = [UIColor secondaryLabelColor];
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = NO;
    // 页脚不该有分隔线与卡片底色。
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.separatorInset = UIEdgeInsetsMake(0.0, 0.0, 0.0, CGFLOAT_MAX);
}

static void ERVersionFooterLayout(id self, SEL _cmd) {
    if (gERVFSuperLayout) ((void (*)(id, SEL))gERVFSuperLayout)(self, _cmd);
    UITableViewCell *cell = (UITableViewCell *)self;
    if (![cell isKindOfClass:[UITableViewCell class]]) return;
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    // textLabel 在 PSTableCell 里是左对齐布局的：把它的 frame 撑满整行，
    // 居中对齐才会在视觉上真的居中。
    CGRect bounds = cell.contentView.bounds;
    if (CGRectGetWidth(bounds) > 1.0) {
        cell.textLabel.frame = CGRectInset(bounds, 16.0, 0.0);
    }
}

void EREnsureVersionFooterCellClassInstalled(void) {
    if (NSClassFromString(ERVersionFooterCellClassName)) return;
    Class base = [PSTableCell class];
    if (!base) return;

    Method refreshMethod = class_getInstanceMethod(base, @selector(refreshCellContentsWithSpecifier:));
    Method layoutMethod = class_getInstanceMethod(base, @selector(layoutSubviews));
    if (!refreshMethod && !layoutMethod) return;

    Class cellClass = objc_allocateClassPair(base, ERVersionFooterCellClassName.UTF8String, 0);
    if (!cellClass) return;

    if (refreshMethod) {
        gERVFSuperRefresh = method_getImplementation(refreshMethod);
        class_addMethod(cellClass, @selector(refreshCellContentsWithSpecifier:),
                        (IMP)ERVersionFooterRefresh, "v@:@");
    }
    if (layoutMethod) {
        gERVFSuperLayout = method_getImplementation(layoutMethod);
        class_addMethod(cellClass, @selector(layoutSubviews), (IMP)ERVersionFooterLayout, "v@:");
    }
    objc_registerClassPair(cellClass);
}

@interface ERVersionFooterCellInstaller : NSObject
@end

@implementation ERVersionFooterCellInstaller

// +load 在本 bundle 被 dlopen 时执行，早于 Preferences 按名字解析 cellClass。
+ (void)load {
    EREnsureVersionFooterCellClassInstalled();
}

@end

// ---------------------------------------------------------------------------
// 图标刷新登记表
//
// 背景：从桌面回到「设置」时，Preferences 会重新解析 plist 得到一批**新的**
// PSSpecifier 对象，运行时才挂上去的 iconImage 随之丢失 —— 这就是「第一次进来
// 左侧有图标，回桌面再进来就没了，要退回系统设置再点一次才回来」的根因：
// 图标只在 viewDidLoad 挂了一次，而 viewDidLoad 一个生命周期只跑一次，
// 回到前台又不会重新触发 viewWillAppear。
//
// 修法：图标在 viewWillAppear（每次出现）重挂一遍，另加一个「App 变为活跃」的
// 通知兜底 —— 覆盖「后台恢复同一个 VC 实例」这条 viewWillAppear 不走的路径。
//
// ---------------------------------------------------------------------------
// 1.0.0 修复：反复进出设置时的 SIGABRT（用户 04:58 那份 Preferences 崩溃报告）
// ---------------------------------------------------------------------------
// 上一版每个控制器各调一次 `addObserver:self`，但从不 `removeObserver`。
// NSNotificationCenter **不持有**观察者（unsafe unretained），控制器被释放后，
// 观察者槽就成了一个悬垂指针；用户「进设置 → 回桌面 → 再进来」时
// UIApplicationDidBecomeActiveNotification 再次投递，消息就发到了那块已经被
// 释放、且内存已被别的对象复用的地址上：
//
//   NSInvalidArgumentException: -[? tableView]: unrecognized selector sent to instance 0x9f402b600
//     __CFNOTIFICATIONCENTER_IS_CALLING_OUT_TO_AN_OBSERVER__
//     -[UIApplication _stopDeactivatingForReason:]          ← 正是「回到前台」
//     abort() called                                        （崩溃帧落在 EchoRebornPrefs 内）
//
// 现在改成**一个随进程存活的长生命周期单例**做唯一观察者，控制器只登记进一张
// 弱引用表（NSHashTable weakObjectsHashTable）：控制器一释放，表项自动失效，
// 悬垂指针不复存在；单例本身活到进程结束，也就不需要 removeObserver。
// 顺带把刷新表格改成 KVC 取值 + 类型校验，彻底移除「向不认识该 selector 的对象
// 发 tableView」这条崩溃路径。
// ---------------------------------------------------------------------------
@interface ERIconRefreshRegistry : NSObject
@end

@implementation ERIconRefreshRegistry

+ (NSHashTable<PSListController *> *)hosts {
    static NSHashTable<PSListController *> *hosts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hosts = [NSHashTable weakObjectsHashTable];
        // 唯一的观察者在这里注册一次。观察者是类对象，随进程存活。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(erApplicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    });
    return hosts;
}

// 刷新表格：只认真正的 UITableView；取不到就什么都不做。
+ (void)erReloadTableOfHost:(PSListController *)host {
    UITableView *table = nil;
    for (NSString *key in @[@"tableView", @"table"]) {
        @try {
            id value = [host valueForKey:key];
            if ([value isKindOfClass:[UITableView class]]) {
                table = (UITableView *)value;
                break;
            }
        } @catch (__unused NSException *exception) {}
    }
    [table reloadData];
}

+ (void)erApplicationDidBecomeActive:(__unused NSNotification *)notification {
    for (PSListController *host in [self hosts].allObjects) {
        [host erApplyIcons];
        [self erReloadTableOfHost:host];
    }
}

@end

// ---------------------------------------------------------------------------
// 1.0.7-15 · 「启动插件」开关搬到「界面优化」子页顶部。
//
// 这里的关键不是 UI，而是**联动不能断**：`setMasterEnabled:specifier:` 原来实现在
// ERRootListController 上（`initialEnabledValue` 也是它的属性），开关一搬家就够不着了。
// 所以把整套逻辑下沉成 PSListController 的分类方法——两个 controller（根页 / 界面优化）
// 都从 PSListController 继承，谁挂这个 specifier 谁就能响应，联动行为与原来逐点相同：
//   · 首次进入页面时记住 Enabled 的初值（erStoreInitialMasterEnabled）；
//   · 每次拨动开关后：新值 ≠ 初值 → 导航栏出现「重启 SpringBoard」按钮；拨回初值 → 消失。
// respring 也一并下沉（原实现在 ERRootListController 上，同样只有根页够得着）。
// ---------------------------------------------------------------------------
static const void *kERInitialMasterEnabledKey = &kERInitialMasterEnabledKey;

@implementation PSListController (ERMasterToggle)

- (void)erStoreInitialMasterEnabled {
    for (PSSpecifier *specifier in self.specifiers) {
        if ([[specifier propertyForKey:@"key"] isEqualToString:@"Enabled"]) {
            BOOL value = [[self readPreferenceValue:specifier] boolValue];
            objc_setAssociatedObject(self, kERInitialMasterEnabledKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            break;
        }
    }
}

- (void)setMasterEnabled:(id)value specifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];
    NSNumber *initial = objc_getAssociatedObject(self, kERInitialMasterEnabledKey);
    BOOL needsRespring = initial ? ([value boolValue] != initial.boolValue) : NO;
    if (!needsRespring) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    if (self.navigationItem.rightBarButtonItem) return;

    UIImage *image = [UIImage systemImageNamed:@"arrow.clockwise"];
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithImage:image
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(respring)];
    button.accessibilityLabel = @"重启 SpringBoard";
    self.navigationItem.rightBarButtonItem = button;
}

- (void)respring {
    // sbreload lives inside the jailbreak root, whose location differs per
    // jailbreak: roothide uses a randomised root, rootless uses /var/jb.
    // Resolve through jbroot() first and fall back to the fixed paths.
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray<NSString *> *candidates = @[
        jbroot(@"/usr/bin/sbreload"),
        jbroot(@"/var/jb/usr/bin/sbreload"),
        @"/var/jb/usr/bin/sbreload",
        @"/usr/bin/sbreload",
    ];
    NSString *resolved = nil;
    for (NSString *candidate in candidates) {
        if ([manager isExecutableFileAtPath:candidate]) {
            resolved = candidate;
            break;
        }
    }
    if (!resolved) return;

    const char *path = [resolved fileSystemRepresentation];
    const char *arguments[] = { path, NULL };
    pid_t pid = 0;
    posix_spawn(&pid, path, NULL, NULL, (char *const *)arguments, environ);
}

@end

@implementation PSListController (ERUIExtensions)

// 运行时给 specifier 挂图片必须用 `iconImage`（值为 UIImage），不能写 `icon`。
// plist 里的 `icon` 是「文件名」字符串，由 SpecifiersForPlist 载入时翻译成
// `iconImage` 属性；运行时直接 setProperty:forKey:@"icon" 没有任何代码会读它
// —— 这正是 0.5.20「左侧没有显示图标」的原因。
- (void)erApplyIcons {
    NSArray *specs = [self specifiers];
    for (PSSpecifier *spec in specs) {
        // specifiers 里可能混进非 PSSpecifier（分组占位等），取属性前先认一下，
        // 避免 -propertyForKey: 落到不认识它的对象上。
        if (![spec respondsToSelector:@selector(propertyForKey:)]) continue;
        NSString *icon = [spec propertyForKey:@"erIcon"];
        // 1.0.4：允许一行声明多个候选符号 + 系统资源名（见 erSwitchForModule:）。
        // 只声明了 erIcon 的行按「单一候选」处理，行为与之前一致。
        NSArray *symbols = [spec propertyForKey:@"erIconSymbols"];
        if (![symbols isKindOfClass:[NSArray class]] || !symbols.count) {
            symbols = [icon length] ? @[icon] : @[];
        }
        if (!symbols.count) continue;
        NSArray *assets = [spec propertyForKey:@"erIconAssets"];
        if (![assets isKindOfClass:[NSArray class]]) assets = nil;
        NSString *fallback = [spec propertyForKey:@"erIconFallback"];
        if (![fallback isKindOfClass:[NSString class]] || !fallback.length) fallback = icon;
        NSString *color = [spec propertyForKey:@"erIconColor"] ?: @"gray";
        [spec setProperty:ERImageIconWithFallbacks(symbols, assets, fallback, color) forKey:@"iconImage"];
    }
}

- (void)erActivateIconRefresh {
    [self erApplyIcons];
    // 弱引用登记：控制器释放后这一项自动失效，不会再有任何残留。
    [[ERIconRefreshRegistry hosts] addObject:self];
}

@end

// ---------------------------------------------------------------------------
// 1.0.2：滑杆圆点统一为 2/3 —— 为什么这里**没有**给原生 PSSliderCell 打补丁
// ---------------------------------------------------------------------------
// 四个页面的 12 个滑杆行现在**全部**显式指定 `cellClass = ERSliderTrackCell`
// （增强设置 3 / 液态玻璃 1 / Siri 6 / 锁屏控制项 2），圆点大小一律由
// ERSliderCell.m 里的 ERSliderThumbImage() 决定，因此不需要去 hook 任何
// Preferences 自带的滑杆 cell。
//
// 早先试过在 +load 里 swizzle `PSSliderCell` 的 -layoutSubviews 来换圆点，已弃用：
//   · `PSSliderCell` 这个名字在运行期能否解析到，本项目此前有过相反记录
//     （见 ERSliderCell.m 顶部 0.5.23~0.5.27 的结论），解析不到就是一段死代码；
//   · 它属于 Preferences.framework，swizzle 会波及同一进程里其它插件的设置页
//     滑杆 —— 那些滑杆不该被本插件改外观。
// 全部改用自绘 cell，这两个问题就都不存在了。
