#import "ERShortcutController.h"
#import "ERShortcutScanner.h"
#import <UIKit/UIKit.h>
#import <stdarg.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Must match Tweak.xm.
static NSString *const kERShortcutPrefsDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERShortcutVisibleKey = @"ShortcutVisibleIdentifiers";
static NSString *const kERShortcutReloadNotification = @"com.strive.echoreborn/ReloadPrefs";
static NSString *const kERShortcutRescanNotification = @"com.strive.echoreborn/RescanShortcuts";
// 1.1.9-70 · 每条快捷指令的显示覆盖（改名/改图标），键是快捷指令 uuid：
// { "<uuid>": { "name": "显示名", "symbolOverride": "sf.symbol.name" } }。
static NSString *const kERShortcutOverridesKey = @"ShortcutOverrides";

// Where SpringBoard publishes what it fetched. Same directory as the
// diagnostics log, chosen because SpringBoard and this bundle run as `mobile`
// and both can reach it — including under roothide, whose jbroot() is
// randomised per install, which is why the path is absolute and outside the
// jailbreak root.
static NSString *const kERShortcutSnapshotDirectory = @"/var/mobile/Library/Logs/EchoReborn";
static NSString *const kERShortcutSnapshotFileName = @"shortcuts.plist";

// 1.0.7-17：子页行图标 —— 与控制中心里快捷指令磁贴**同一套画法**。
@class ERShortcutInfoController;   // 1.1.9-70 · 信息页（文件尾部实现）
// 颜色解码与 glyph→SF Symbol 映射与 Tweak.xm 的 ERShortcutColorFromValue /
// ERShortcutSymbolNameForGlyph 完全一致（后者来自 WorkflowKit 的私有函数，
// 用 dlopen 取；Settings 进程同样能加载）。
static UIColor *ERShortcutCellColorFromValue(long long value) {
    // 1.1.8-9 · 数据库里颜色是 0xRRGGBBAA 的无符号 32 位，高位会被读成负数
    // （例如 0xA9A9A9FF = -1448498689）。旧判断 value <= 0 把这些行判成「无颜色」，
    // 于是一律退回默认蓝 —— 用户截图里「车门解锁/开灯」显示蓝色就是这个原因。
    if (value == 0) return nil;
    uint32_t rgba = (uint32_t)((unsigned long long)value & 0xFFFFFFFFULL);
    if (rgba == 0) return nil;
    CGFloat red = ((rgba >> 24) & 0xFF) / 255.0;
    CGFloat green = ((rgba >> 16) & 0xFF) / 255.0;
    CGFloat blue = ((rgba >> 8) & 0xFF) / 255.0;
    CGFloat alpha = (rgba & 0xFF) / 255.0;
    if (alpha < 0.01) alpha = 1.0;
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}


// 1.1.8-8 · 扫描器把自定义图片图标写成文件放在这里。
static NSString *ERShortcutIconDirectory(void) {
    return [kERShortcutSnapshotDirectory stringByAppendingPathComponent:@"shortcut-icons"];
}

static void ERShortcutLog(NSString *format, ...);

// 1.1.9-70 · 显示覆盖的读写（共享偏好域；写完广播 ReloadPrefs 让磁贴同步刷新）。
static NSDictionary *ERShortcutOverridesRead(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERShortcutPrefsDomain);
    id value = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)kERShortcutOverridesKey,
                                                               (__bridge CFStringRef)kERShortcutPrefsDomain);
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

static void ERShortcutOverridesWrite(NSDictionary *overrides) {
    CFPreferencesSetAppValue((__bridge CFStringRef)kERShortcutOverridesKey,
                             (__bridge CFPropertyListRef)(overrides.count ? overrides : nil),
                             (__bridge CFStringRef)kERShortcutPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERShortcutPrefsDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kERShortcutReloadNotification,
                                         NULL, NULL, YES);
    ERShortcutLog(@"shortcutPane: persisted %lu override(s)", (unsigned long)overrides.count);
}

// 1.1.8-18 · 量一张图的「墨迹」包围盒（返回值是相对整图的比例）。
// SF Symbol 的画布自带大量内边距，不同符号差得很远（同一个 0.62 的绘制系数，
// 有的符号只占磁贴 35%、有的能占 60%）。所以放大必须按**真实墨迹**算，
// 否则又会变成「某个符号太大、某个太小」的一条条补救。
static CGRect ERInkBoundsOfImage(UIImage *image) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return CGRectNull;
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width < 4 || height < 4) return CGRectNull;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return CGRectNull;
    unsigned char *buffer = (unsigned char *)calloc(width * height * 4, 1);
    if (!buffer) { CGColorSpaceRelease(space); return CGRectNull; }
    CGContextRef context = CGBitmapContextCreate(buffer, width, height, 8, width * 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGRect result = CGRectNull;
    if (context) {
        CGContextDrawImage(context, CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height), cgImage);
        size_t minX = width, minY = height, maxX = 0, maxY = 0;
        for (size_t y = 0; y < height; y++) {
            for (size_t x = 0; x < width; x++) {
                if (buffer[(y * width + x) * 4 + 3] > 24) {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }
        if (maxX >= minX && maxY >= minY) {
            result = CGRectMake((CGFloat)minX / (CGFloat)width, (CGFloat)minY / (CGFloat)height,
                                (CGFloat)(maxX - minX + 1) / (CGFloat)width,
                                (CGFloat)(maxY - minY + 1) / (CGFloat)height);
        }
        CGContextRelease(context);
    }
    free(buffer);
    CGColorSpaceRelease(space);
    return result;
}

// 墨迹比例按 iconFile 缓存 —— 单元格会反复重画，不该每次都扫一遍像素。
static CGRect ERInkBoundsForKey(NSString *key, UIImage *image) {
    static NSMutableDictionary<NSString *, NSValue *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    NSValue *cached = cache[key];
    if (cached) return cached.CGRectValue;
    CGRect ink = ERInkBoundsOfImage(image);
    if (CGRectIsNull(ink)) ink = CGRectMake(0.0, 0.0, 1.0, 1.0);
    cache[key] = [NSValue valueWithCGRect:ink];
    return ink;
}

// 1.1.8-15 · 图标解析已经全部收拢到扫描器（那边能读库、能问 WorkflowKit）。
// 这个界面只负责把结果画出来，所以不再需要任何符号名/字形/App 图标的取图逻辑。
static UIImage *ERShortcutCellIcon(NSDictionary *shortcut);

static UIImage *ERShortcutCellIcon(NSDictionary *shortcut) {
    if (![shortcut isKindOfClass:[NSDictionary class]]) return nil;
    UIColor *background = ERShortcutCellColorFromValue([shortcut[@"color"] longLongValue]);

    // 1.1.8-15 · 这里只画不解析。扫描器已经把图标渲染好并落盘：
    //   iconFull=YES → 它本身就是完整圆角图标，直接满铺
    //   iconFull=NO  → 白色前景符号（透明底），叠在快捷指令自己的底色上
    UIImage *customImage = nil;
    UIImage *glyph = nil;
    NSString *iconSource = nil;
    NSString *iconFile = [shortcut[@"iconFile"] isKindOfClass:[NSString class]] ? shortcut[@"iconFile"] : nil;
    BOOL iconFull = [shortcut[@"iconFull"] isKindOfClass:[NSNumber class]]
                    ? [shortcut[@"iconFull"] boolValue] : YES;
    if (iconFile.length) {
        UIImage *rendered = [UIImage imageWithContentsOfFile:
                             [ERShortcutIconDirectory() stringByAppendingPathComponent:iconFile]];
        if (rendered) {
            if (iconFull) {
                customImage = rendered;
                iconSource = @"icon-full";
            } else {
                glyph = rendered;
                iconSource = @"icon-fg";
            }
        }
    }
    if (!customImage && !glyph) {
        // 1.1.9-70 · 信息页设置的图标覆盖（symbolOverride）优先于兜底字形。
        NSString *overrideSymbol = [shortcut[@"symbolOverride"] isKindOfClass:[NSString class]]
                                   ? shortcut[@"symbolOverride"] : nil;
        if (overrideSymbol.length) {
            UIImage *symbol = [UIImage systemImageNamed:overrideSymbol];
            if (symbol) {
                glyph = [symbol imageWithTintColor:UIColor.whiteColor
                                      renderingMode:UIImageRenderingModeAlwaysOriginal] ?: symbol;
                iconSource = @"override";
            }
        }
    }
    if (!customImage && !glyph) {
        // 扫描器没给出图时才走这里，同样不猜符号名。
        glyph = [UIImage systemImageNamed:@"wand.and.stars"] ?: [UIImage systemImageNamed:@"sparkles"];
        iconSource = @"fallback";
    }

    // 逐条记录解析结果（每个 uuid 只记一次），用来确认还有哪些没落地。
    static NSMutableSet<NSString *> *loggedKeys;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{ loggedKeys = [NSMutableSet set]; });
    NSString *logKey = [shortcut[@"uuid"] isKindOfClass:[NSString class]] ? shortcut[@"uuid"] : @"";
    if (logKey.length && ![loggedKeys containsObject:logKey]) {
        [loggedKeys addObject:logKey];
        ERShortcutLog(@"iconrow: %@ | glyph=0x%04X | bundle=%@ | src=%@ | file=%@",
                      [shortcut[@"name"] description],
                      (unsigned)[shortcut[@"glyph"] unsignedShortValue],
                      [shortcut[@"bundleId"] description] ?: @"-",
                      iconSource ?: @"-",
                      iconFile ?: @"-");
    }

    CGSize size = CGSizeMake(40.0, 40.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 1.0, 1.0) cornerRadius:9.0];
        [(background ?: [UIColor colorWithRed:0.11 green:0.60 blue:0.97 alpha:1.0]) setFill];
        [path fill];
        if (customImage) {
            [path addClip];
            [customImage drawInRect:CGRectInset(rect, 1.0, 1.0)];
        } else if (glyph) {
            // 1.1.8-18 · 磁贴大小不变（40×40pt），只把里面的符号按真实墨迹放大到
            // 宽 86% / 高 95% 并居中。等比缩放，不拉伸。
            CGRect inner = CGRectInset(rect, 1.0, 1.0);
            CGRect ink = ERInkBoundsForKey(iconFile.length ? iconFile : @"fallback", glyph);
            CGFloat inkWidth = MAX(ink.size.width * glyph.size.width, 0.001);
            CGFloat inkHeight = MAX(ink.size.height * glyph.size.height, 0.001);
            // 1.1.8-19 · 用户反馈过于大了，缩小 1/5：0.86/0.95 → 0.69/0.76。
            CGFloat factor = MIN((inner.size.width * 0.69) / inkWidth,
                                 (inner.size.height * 0.76) / inkHeight);
            CGSize drawn = CGSizeMake(glyph.size.width * factor, glyph.size.height * factor);
            [glyph drawInRect:CGRectMake(CGRectGetMidX(inner) - drawn.width / 2.0,
                                         CGRectGetMidY(inner) - drawn.height / 2.0,
                                         drawn.width, drawn.height)];
        }
    }];
}

// 1.1.8-15 · 一次性可视化自检：把每一行最终画出来的图标落盘（_rowNN.png），
// 这样「哪一条还没对」直接看图确认，不用靠猜。日志里有编号 → 名字的对照。
static void ERShortcutIconDumpOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *dir = ERShortcutIconDirectory();
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *payload =
            [NSDictionary dictionaryWithContentsOfFile:
             [kERShortcutSnapshotDirectory stringByAppendingPathComponent:kERShortcutSnapshotFileName]];
        NSArray *shortcuts = [payload isKindOfClass:[NSDictionary class]] ? payload[@"shortcuts"] : nil;
        if (![shortcuts isKindOfClass:[NSArray class]]) return;
        NSUInteger row = 0;
        for (NSDictionary *shortcut in shortcuts) {
            if (![shortcut isKindOfClass:[NSDictionary class]]) continue;
            UIImage *icon = ERShortcutCellIcon(shortcut);
            if (!icon) continue;
            NSString *file = [NSString stringWithFormat:@"_row%02lu.png", (unsigned long)row];
            [UIImagePNGRepresentation(icon)
                writeToFile:[dir stringByAppendingPathComponent:file] atomically:NO];
            ERShortcutLog(@"rowshot: %@ -> %@ | glyph=0x%04X | bundle=%@ | full=%@",
                          file, [shortcut[@"name"] description],
                          (unsigned)[shortcut[@"glyph"] unsignedShortValue],
                          [shortcut[@"bundleId"] description] ?: @"-",
                          shortcut[@"iconFull"] ?: @"-");
            row++;
        }
        ERShortcutLog(@"rowshot: 共 %lu 张", (unsigned long)row);
    });
}

// 1.1.8-18 · 句柄复用：原来每条日志都 fileHandleForWritingAtPath + closeFile 一遍，
// 一次扫描要写近百条，光开合文件就占掉不少时间。现在只开一次，之后直接追加。
static void ERShortcutLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [PREFS] %@\n", [NSDate date].description, message];
    [[NSFileManager defaultManager] createDirectoryAtPath:kERShortcutSnapshotDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [kERShortcutSnapshotDirectory stringByAppendingPathComponent:@"echoreborn.log"];
    static NSFileHandle *handle = nil;
    if (!handle) handle = [NSFileHandle fileHandleForWritingAtPath:path];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *exception) {
        // 句柄失效（日志被外部轮转/删掉）时重开一次，不再退回「每次开关」。
        @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            @try {
                [handle seekToEndOfFile];
                [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            } @catch (__unused NSException *alsoIgnored) {}
        } else {
            [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

// MARK: - 添加子页面
//
// 1.1.8-18 · 未显示的那批快捷指令单独拆到这里：顶部搜索框 + 未显示控制项列表，
// 点一条就加入显示列表并弹回主页。加入/移除的逻辑都在，只是主页先不挂交互
// （用户后面还有别的需求），所以这里也只做「加入」这一个方向。
@interface ERShortcutAddController : PSViewController <UITableViewDataSource,
                                                       UITableViewDelegate,
                                                       UISearchBarDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *allShortcuts;
@property (nonatomic, strong) NSMutableSet<NSString *> *visibleUUIDs;
@property (nonatomic, strong) NSArray<NSDictionary *> *filtered;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *addTableView;
- (instancetype)initWithShortcuts:(NSArray<NSDictionary *> *)shortcuts
                    visibleUUIDs:(NSSet<NSString *> *)visibleUUIDs;
@end

@interface ERShortcutController () <UITableViewDataSource, UITableViewDelegate>
// NOT `tableView`. PSViewController already declares a READONLY
// `tableView` property of its own, so `self.tableView = ...` is a compile
// error ("assignment to readonly property") that takes the whole preference
// bundle down with it — and an installer that keeps the previous package makes
// that look exactly like "tapping the row does nothing". A distinct name
// sidesteps the inherited property entirely.
@property (nonatomic, strong) UITableView *shortcutTableView;
// Everything SpringBoard reported having fetched, already sorted by name.
@property (nonatomic, strong) NSArray<NSDictionary *> *fetched;
// The diagnostic half of the snapshot: status, store path, counts.
@property (nonatomic, strong) NSDictionary *diagnostics;
@property (nonatomic, strong) NSMutableSet<NSString *> *visibleUUIDs;
@end

// 1.1.8-18 · 抽成 C 函数：主页与「添加」子页面都要写这份集合，
// 而添加页是另一个类，拿不到主页的 -persist。
static void ERShortcutPersistVisible(NSSet<NSString *> *visible, NSUInteger fetchedCount) {
    CFPreferencesSetAppValue((__bridge CFStringRef)kERShortcutVisibleKey,
                             (__bridge CFPropertyListRef)[visible.allObjects copy],
                             (__bridge CFStringRef)kERShortcutPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERShortcutPrefsDomain);
    // SpringBoard re-reads the gate every time the gallery is rebuilt, so this
    // only has to wake it — no respring.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kERShortcutReloadNotification,
                                         NULL, NULL, YES);
    ERShortcutLog(@"shortcutPane: persisted %lu visible of %lu fetched",
                   (unsigned long)visible.count, (unsigned long)fetchedCount);
}

@implementation ERShortcutController

// MARK: - Preference access

// Read through CFPreferences rather than NSUserDefaults: a PreferenceBundle
// does not necessarily run with this domain as its own bundle identifier, so
// -arrayForKey: can return nil while the value is genuinely present. CF is what
// Tweak.xm writes, so CF is what this pane reads.
- (NSArray *)storedArrayForKey:(NSString *)key {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kERShortcutPrefsDomain);
    NSArray *result = nil;
    if (value) {
        if (CFGetTypeID(value) == CFArrayGetTypeID()) result = [(__bridge NSArray *)value copy];
        CFRelease(value);
    }
    return result;
}

- (void)persist {
    ERShortcutPersistVisible(self.visibleUUIDs, self.fetched.count);
}

// MARK: - Snapshot

- (void)loadSnapshot {
    NSString *path = [kERShortcutSnapshotDirectory stringByAppendingPathComponent:kERShortcutSnapshotFileName];
    NSDictionary *payload = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![payload isKindOfClass:[NSDictionary class]]) payload = nil;

    NSArray *shortcuts = payload[@"shortcuts"];
    self.fetched = [shortcuts isKindOfClass:[NSArray class]] ? shortcuts : @[];
    self.diagnostics = payload ?: @{};

    self.visibleUUIDs = [NSMutableSet set];
    for (id entry in [self storedArrayForKey:kERShortcutVisibleKey]) {
        if ([entry isKindOfClass:[NSString class]] && [entry length]) [self.visibleUUIDs addObject:entry];
    }
    ERShortcutLog(@"shortcutPane: snapshot %@, %lu fetched, %lu marked visible",
                   payload ? @"read" : @"missing",
                   (unsigned long)self.fetched.count,
                   (unsigned long)self.visibleUUIDs.count);
}

// 1.1.8-18 · 主页只显示「显示控制项」，未显示的那批搬到「添加」子页面，
// 所以这里按 visible / hidden 各给一个取值器，不再用 section 号区分。
- (NSArray<NSDictionary *> *)visibleShortcuts {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *shortcut in self.fetched) {
        NSString *uuid = shortcut[@"uuid"];
        if (![uuid isKindOfClass:[NSString class]]) continue;
        if ([self.visibleUUIDs containsObject:uuid]) [result addObject:shortcut];
    }
    return result;
}

- (NSString *)displayNameForShortcut:(NSDictionary *)shortcut {
    // 1.1.9-70 · 信息页改过的显示名优先。
    NSString *uuid = [shortcut[@"uuid"] isKindOfClass:[NSString class]] ? shortcut[@"uuid"] : nil;
    if (uuid.length) {
        NSDictionary *overrides = ERShortcutOverridesRead();
        NSDictionary *override = [overrides[uuid] isKindOfClass:[NSDictionary class]] ? overrides[uuid] : nil;
        NSString *renamed = [override[@"name"] isKindOfClass:[NSString class]] ? override[@"name"] : nil;
        if (renamed.length) return renamed;
    }
    NSString *name = shortcut[@"name"];
    if ([name isKindOfClass:[NSString class]] && name.length) return name;
    return [uuid isKindOfClass:[NSString class]] ? uuid : @"快捷指令";
}

// 1.1.9-70 · 把该 uuid 的显示覆盖并进记录副本（列表行图标用）。
- (NSDictionary *)displayRecordForShortcut:(NSDictionary *)shortcut {
    NSString *uuid = [shortcut[@"uuid"] isKindOfClass:[NSString class]] ? shortcut[@"uuid"] : nil;
    if (!uuid.length) return shortcut;
    NSDictionary *overrides = ERShortcutOverridesRead();
    NSDictionary *override = [overrides[uuid] isKindOfClass:[NSDictionary class]] ? overrides[uuid] : nil;
    if (![override isKindOfClass:[NSDictionary class]] || !override.count) return shortcut;
    NSMutableDictionary *merged = [shortcut mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *renamed = [override[@"name"] isKindOfClass:[NSString class]] ? override[@"name"] : nil;
    if (renamed.length) merged[@"name"] = renamed;
    NSString *symbol = [override[@"symbolOverride"] isKindOfClass:[NSString class]] ? override[@"symbolOverride"] : nil;
    if (symbol.length && [UIImage systemImageNamed:symbol]) merged[@"symbolOverride"] = symbol;
    else [merged removeObjectForKey:@"symbolOverride"];
    return merged;
}

// 1.1.8-18 · 诊断文案抽成 C 函数：主页不再显示诊断，改由「添加」子页面的
// footer 展示，而那是另一个类，拿不到主页的实例方法。内容与原来完全一致，
// 只是把「重新扫描」那类已不存在的入口从措辞里去掉。
static NSString *ERShortcutDiagnosticSummary(NSDictionary *diagnostics) {
    NSString *status = diagnostics[@"status"];
    NSUInteger containers = [diagnostics[@"containerCount"] unsignedIntegerValue];
    NSUInteger probed = [diagnostics[@"sqliteProbed"] unsignedIntegerValue];
    NSUInteger rowsSeen = [diagnostics[@"rowsSeen"] unsignedIntegerValue];

    if (![status isKindOfClass:[NSString class]]) {
        return @"尚未取得扫描结果。打开本页面时会自动扫描一次。";
    }
    if ([status isEqualToString:@"no-sqlite3"]) {
        return @"插件无法加载系统 SQLite（dlopen 失败），因此读不到快捷指令数据。请把这份日志反馈给我。";
    }
    if ([status isEqualToString:@"no-database"]) {
        // The count of paths that EXIST is the discriminator, and it is what
        // was missing from the 0.4.2 wording: "found 22 containers, checked 28
        // files, none was the database" is equally consistent with "the
        // database is somewhere else" and "the database is right there but
        // unreadable", and those need opposite responses. Asking how many of
        // the candidate paths are actually present separates them.
        NSArray *listed = diagnostics[@"triedPaths"];
        NSUInteger present = [diagnostics[@"candidatePresent"] unsignedIntegerValue];
        NSUInteger listedCount = [listed isKindOfClass:[NSArray class]] ? listed.count : 0;
        if (listedCount && present == 0) {
            return [NSString stringWithFormat:@"插件没拿到数据：列出的 %lu 个候选路径一个都不存在（容器本身可能是读不到的）。请在日志页导出日志并把文件发我，这份日志现在包含文件系统的可读性探测结果，能直接定位是路径不对还是读不到。",
                    (unsigned long)listedCount];
        }
        if (present > 0) {
            return [NSString stringWithFormat:@"插件没拿到数据：已找到 %lu 个候选容器、%lu 个候选路径存在，但没有一个能被读成快捷指令数据库。这更像读取权限问题而不是路径问题，请把日志发我。",
                    (unsigned long)containers, (unsigned long)present];
        }
        return [NSString stringWithFormat:@"插件没拿到数据：已找到 %lu 个候选容器、检查了 %lu 个 sqlite 文件，但没有一个是快捷指令数据库。这是数据源定位问题，不是显示问题。",
                (unsigned long)containers, (unsigned long)probed];
    }
    if ([status isEqualToString:@"query-failed"]) {
        return @"插件找到了数据库但读取失败。请把这份日志反馈给我。";
    }
    if ([status isEqualToString:@"empty-store"]) {
        return [NSString stringWithFormat:@"插件读到了快捷指令数据库（ZSHORTCUT 共 %lu 行），但其中没有可用的快捷指令。",
                (unsigned long)rowsSeen];
    }
    if ([status isEqualToString:@"ok"]) {
        NSUInteger kept = [diagnostics[@"kept"] unsignedIntegerValue];
        return [NSString stringWithFormat:@"插件已成功获取到 %lu 条快捷指令。在「添加」里点某条即可加入「显示控制项」，它随后就会出现在「添加控制项」面板中。",
                (unsigned long)kept];
    }
    return @"扫描状态未知。退出本页面再进来会重新扫描一次。";
}

static NSString *ERShortcutStorePathLine(NSDictionary *diagnostics) {
    NSString *path = diagnostics[@"databasePath"];
    if (![path isKindOfClass:[NSString class]] || !path.length) return @"未定位到数据库文件";
    return path;
}

// The container list and the paths actually probed, rendered so a failure can
// be read off the phone instead of off a log file.
static NSString *ERShortcutDiscoveryDetail(NSDictionary *diagnostics) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSArray *containers = diagnostics[@"containerPaths"];
    if ([containers isKindOfClass:[NSArray class]] && containers.count) {
        [lines addObject:[NSString stringWithFormat:@"找到 %lu 个候选容器：", (unsigned long)containers.count]];
        for (NSString *container in containers) {
            if ([container isKindOfClass:[NSString class]]) [lines addObject:[NSString stringWithFormat:@"  %@", container]];
        }
    } else {
        [lines addObject:@"没有找到任何快捷指令数据容器。"];
    }
    // Shown before the probed list because it is the more decisive number: a
    // candidate that does not exist and a candidate that cannot be read are
    // different faults, and this line is what tells them apart on the phone.
    NSArray *tried = diagnostics[@"triedPaths"];
    if ([tried isKindOfClass:[NSArray class]] && tried.count) {
        NSUInteger present = [diagnostics[@"candidatePresent"] unsignedIntegerValue];
        [lines addObject:[NSString stringWithFormat:@"候选路径 %lu 条，其中存在 %lu 条。",
                          (unsigned long)tried.count, (unsigned long)present]];
    }
    NSArray *probed = diagnostics[@"probedPaths"];
    if ([probed isKindOfClass:[NSArray class]] && probed.count) {
        [lines addObject:[NSString stringWithFormat:@"检查过的文件（%lu）：", (unsigned long)probed.count]];
        for (NSString *path in probed) {
            if ([path isKindOfClass:[NSString class]]) [lines addObject:[NSString stringWithFormat:@"  %@", path]];
        }
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"";
}

static NSString *ERShortcutTimestampLine(NSDictionary *diagnostics) {
    NSDate *writtenAt = diagnostics[@"writtenAt"];
    if (![writtenAt isKindOfClass:[NSDate class]]) return @"";
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"MM-dd HH:mm:ss";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [NSString stringWithFormat:@"扫描时间 %@", [formatter stringFromDate:writtenAt]];
}

// MARK: - Lifecycle

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 480.0)];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    [self.view addSubview:table];
    self.shortcutTableView = table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"快捷指令";

    // 1.1.8-18 · 先用上次的缓存把列表画出来（秒开），扫描推到下一个 runloop
    // 回合再跑 —— 画面已经出现了才去读数据库，打开不再「慢一拍」。
    [self loadSnapshot];
    [self.shortcutTableView reloadData];

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithTitle:@"添加"
                                                           style:UIBarButtonItemStylePlain
                                                          target:self
                                                          action:@selector(addShortcuts:)];
    self.navigationItem.rightBarButtonItem = add;
    ERShortcutLog(@"shortcutPane: viewDidLoad done（扫描延后到下一回合）");

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        // 0.4.7: the scan runs in this process (Preferences), which can read the
        // Shortcuts store that SpringBoard is sandboxed away from.
        ERShortcutScanAndPublish();
        [strongSelf loadSnapshot];
        [strongSelf.shortcutTableView reloadData];
        // 1.1.8-12 · 快照读完之后再做图标自检（它要用到每一行的数据）。
        ERShortcutIconDumpOnce();
    });
}

// 从「添加」子页面返回时刷新一遍，把新加入的那几条显示出来。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadSnapshot];
    [self.shortcutTableView reloadData];
}

// MARK: - Actions

// 1.1.8-18 · 「添加」：把未显示的那批单独拆到一个子页面，主页只留展示列表。
- (void)addShortcuts:(__unused UIBarButtonItem *)sender {
    ERShortcutAddController *controller =
        [[ERShortcutAddController alloc] initWithShortcuts:self.fetched
                                             visibleUUIDs:self.visibleUUIDs];
    controller.title = @"添加";
    [self.navigationController pushViewController:controller animated:YES];
}

// MARK: - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    // 1.1.8-18 · 只有一个分区：未显示的那批搬到「添加」子页面了。
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    NSArray *rows = [self visibleShortcuts];
    // An empty state row: without it a section with nothing in it renders as a
    // bare header on top of nothing, which reads like a broken pane.
    return rows.count ? (NSInteger)rows.count : 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return [NSString stringWithFormat:@"显示控制项（%lu）",
            (unsigned long)[self visibleShortcuts].count];
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    // 1.1.8-18 · 诊断信息搬到「添加」子页面了，主页保持干净。
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ERShortcutCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    NSArray<NSDictionary *> *rows = [self visibleShortcuts];
    if (rows.count == 0) {
        // 1.1.8-18 · 空状态引导去点右上角的「添加」——那个按钮在主页上，
        // 所以这句话也只能放在主页说。
        cell.textLabel.text = @"点击右上角添加的快捷指令";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = YES;
        return cell;
    }
    // 1.1.8-20 · 主页是纯展示列表：不打钩（在列表里就等于已启用）、点了也没反应
    // （didSelect 是空实现）、选中不高亮。
    // 注意：**不能**再设 userInteractionEnabled = NO —— UIKit 会把禁用单元格里的
    // 文字整体调暗（实测 labelColor 被渲染成约 47% 的灰，不再是纯黑，就是 1.1.8-19
    // 被反馈"右边文字发白"的原因）。所以保持可交互，用空实现 + 无高亮来达到
    // "点了没反应"的效果。
    cell.userInteractionEnabled = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.alpha = 1.0;
    cell.detailTextLabel.alpha = 1.0;

    NSDictionary *shortcut = rows[indexPath.row];
    cell.textLabel.text = [self displayNameForShortcut:shortcut];
    cell.textLabel.textColor = UIColor.labelColor;
    // 1.1.9-70 · 图标也走覆盖（信息页改过的 symbolOverride 优先）。
    cell.imageView.image = ERShortcutCellIcon([self displayRecordForShortcut:shortcut]);
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.clipsToBounds = YES;
    // The uuid is shown because two shortcuts can legitimately share a name,
    // and because it is the one value that identifies a row across rescans.
    NSString *uuid = shortcut[@"uuid"];
    cell.detailTextLabel.text = ([uuid isKindOfClass:[NSString class]] && uuid.length > 8)
        ? [uuid substringToIndex:8]
        : (uuid ?: @"");
    // 1.1.8-19 · secondaryLabelColor 在白底下太发白（用户反馈），
    // 用 labelColor 靠字号区分主次，颜色上足够清楚。
    cell.detailTextLabel.textColor = UIColor.labelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

// 1.1.9-70 · 点击进入信息页（改名/改图标，右上角保存），对齐快捷方式子页的交互。
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSDictionary *> *rows = [self visibleShortcuts];
    if ((NSUInteger)indexPath.row >= rows.count) return;
    ERShortcutInfoController *info = [[ERShortcutInfoController alloc] initWithShortcut:rows[(NSUInteger)indexPath.row]];
    info.title = @"快捷指令信息";
    [self.navigationController pushViewController:info animated:YES];
}

// 1.1.9-70 · 左滑删除 = 移出「显示控制项」（快捷指令本体不受影响，可再从「添加」里加回来）。
- (BOOL)tableView:(__unused UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return (NSUInteger)indexPath.row < [self visibleShortcuts].count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSArray<NSDictionary *> *rows = [self visibleShortcuts];
    if ((NSUInteger)indexPath.row >= rows.count) return;
    NSString *uuid = rows[(NSUInteger)indexPath.row][@"uuid"];
    if (![uuid isKindOfClass:[NSString class]] || !uuid.length) return;
    [self.visibleUUIDs removeObject:uuid];
    [self persist];
    [tableView reloadData];
    ERShortcutLog(@"shortcutPane: 左滑移出显示列表 %@", uuid);
}

@end

// ---------------------------------------------------------------------------
// 1.1.9-70 · 快捷指令信息页：改名 / 改图标（右上角「保存」才落盘，与快捷方式
// 信息页同一套交互习惯）。覆盖按 uuid 存进 ShortcutOverrides，磁贴侧
// （ERShortcutModule.h）与列表同读这份键，保存后广播 ReloadPrefs 同步刷新。
// ---------------------------------------------------------------------------
@interface ERShortcutInfoController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *infoTableView;
@property (nonatomic, strong) NSDictionary *record;
@property (nonatomic, copy) NSString *shortcutUUID;
@property (nonatomic, copy) NSString *pendingName;      // nil = 未改
@property (nonatomic, copy) NSString *pendingSymbol;    // nil = 未改；@"" = 清除覆盖
@property (nonatomic, assign) BOOL pendingSymbolSet;
- (instancetype)initWithShortcut:(NSDictionary *)shortcut;
@end

@implementation ERShortcutInfoController

- (instancetype)initWithShortcut:(NSDictionary *)shortcut {
    if ((self = [super init])) {
        _record = [shortcut isKindOfClass:[NSDictionary class]] ? shortcut : @{};
        _shortcutUUID = [_record[@"uuid"] isKindOfClass:[NSString class]] ? _record[@"uuid"] : @"";
    }
    return self;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 480.0)];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    [self.view addSubview:table];
    self.infoTableView = table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.title.length) self.title = @"快捷指令信息";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(saveTapped)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.infoTableView reloadData];
}

// MARK: - Table（卡片：名称 / 图标）

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ERShortcutInfoCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];

    if (indexPath.row == 0) {
        cell.textLabel.text = @"名称";
        NSString *name = self.pendingName.length ? self.pendingName
                        : ([self.record[@"name"] isKindOfClass:[NSString class]] ? self.record[@"name"] : @"");
        cell.detailTextLabel.text = name.length ? name : @"未命名";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.textLabel.text = @"图标";
        NSString *symbol = self.pendingSymbolSet ? self.pendingSymbol : nil;
        if ([symbol isKindOfClass:[NSString class]] && symbol.length) {
            cell.detailTextLabel.text = symbol;
        } else if (self.pendingSymbolSet) {
            cell.detailTextLabel.text = @"默认";
        } else {
            NSDictionary *overrides = ERShortcutOverridesRead();
            NSDictionary *override = [overrides[self.shortcutUUID] isKindOfClass:[NSDictionary class]] ? overrides[self.shortcutUUID] : nil;
            NSString *saved = [override[@"symbolOverride"] isKindOfClass:[NSString class]] ? override[@"symbolOverride"] : nil;
            cell.detailTextLabel.text = saved.length ? saved : @"默认";
        }
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    return cell;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"修改需点右上角「保存」才会生效；只改这块磁贴的显示，快捷指令本体不受影响。";
}

- (void)tableView:(__unused UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self.infoTableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) [self renameTapped];
    else [self pickIconTapped];
}

// MARK: - 动作

- (void)renameTapped {
    NSString *current = self.pendingName.length ? self.pendingName
                       : ([self.record[@"name"] isKindOfClass:[NSString class]] ? self.record[@"name"] : @"");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"修改名称" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.placeholder = @"名称";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        UITextField *field = alert.textFields.firstObject;
        strongSelf.pendingName = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [strongSelf.infoTableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 图标：复用快捷方式那套图标库（ERLinkIconPickerController 在同一个
// PreferenceBundle 里，运行时取类，避免跨编译单元的头依赖）。
- (void)pickIconTapped {
    Class pickerClass = NSClassFromString(@"ERLinkIconPickerController");
    if (!pickerClass) {
        ERShortcutLog(@"shortcutInfo: ERLinkIconPickerController 不可用");
        return;
    }
    UIViewController *picker = [[pickerClass alloc] init];
    NSString *current = nil;
    if (self.pendingSymbolSet) current = self.pendingSymbol;
    if (!current) {
        NSDictionary *overrides = ERShortcutOverridesRead();
        NSDictionary *override = [overrides[self.shortcutUUID] isKindOfClass:[NSDictionary class]] ? overrides[self.shortcutUUID] : nil;
        current = [override[@"symbolOverride"] isKindOfClass:[NSString class]] ? override[@"symbolOverride"] : nil;
    }
    [picker setValue:current ?: @"" forKey:@"selectedSymbol"];
    [picker setValue:self forKey:@"pickerDelegate"];
    [self.navigationController pushViewController:picker animated:YES];
}

// 图标库回调（ERLinkIconPickerDelegate）。清空选择 = 恢复默认图标。
- (void)iconPickerDidPickSymbol:(NSString *)name {
    self.pendingSymbol = [name isKindOfClass:[NSString class]]
                         ? [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                         : @"";
    self.pendingSymbolSet = YES;
    [self.infoTableView reloadData];
}

// 右上角「保存」：把名称/图标覆盖写进 ShortcutOverrides 并广播刷新。
- (void)saveTapped {
    if (!self.pendingName.length && !self.pendingSymbolSet) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    if (self.pendingSymbolSet && self.pendingSymbol.length && ![UIImage systemImageNamed:self.pendingSymbol]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"符号不可用"
                                                                       message:[NSString stringWithFormat:@"系统里没有名为 %@ 的 SF 符号。", self.pendingSymbol]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSMutableDictionary *overrides = [ERShortcutOverridesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    id existingOverride = overrides[self.shortcutUUID];
    NSMutableDictionary *override = [existingOverride isKindOfClass:[NSDictionary class]]
                                    ? [existingOverride mutableCopy] : [NSMutableDictionary dictionary];
    if (![override isKindOfClass:[NSMutableDictionary class]]) override = [NSMutableDictionary dictionary];
    if (self.pendingName.length) override[@"name"] = self.pendingName;
    else [override removeObjectForKey:@"name"];
    if (self.pendingSymbolSet) {
        if (self.pendingSymbol.length) override[@"symbolOverride"] = self.pendingSymbol;
        else [override removeObjectForKey:@"symbolOverride"];   // 清空 = 恢复默认图标
    }
    if (override.count) overrides[self.shortcutUUID] = override;
    else [overrides removeObjectForKey:self.shortcutUUID];
    ERShortcutOverridesWrite(overrides);
    [self.navigationController popViewControllerAnimated:YES];
}

@end


@implementation ERShortcutAddController

- (instancetype)initWithShortcuts:(NSArray<NSDictionary *> *)shortcuts
                    visibleUUIDs:(NSSet<NSString *> *)visibleUUIDs {
    self = [super init];
    if (!self) return nil;
    _allShortcuts = shortcuts ?: @[];
    _visibleUUIDs = [visibleUUIDs isKindOfClass:[NSSet class]] ? [visibleUUIDs mutableCopy]
                                                              : [NSMutableSet set];
    _searchText = @"";
    return self;
}

- (void)loadView {
    CGRect frame = CGRectMake(0.0, 0.0, 320.0, 480.0);
    self.view = [[UIView alloc] initWithFrame:frame];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 1.1.8-19 · 搜索框改成表格的 tableHeaderView。
    // 之前用「addSubview + 手写 frame」放在 y=0，结果这个页面的 view 是整屏的
    // （会伸到导航栏底下），搜索框被导航栏压住一大半、点到状态栏上去。
    // 交给表格自己定位：表格的内容 inset 系统已经算好了（主页就是这么正常显示的），
    // 表头视图正好落在导航栏下面、也就是用户红框标出的位置。
    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds
                                                     style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;

    UISearchBar *bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0.0, 0.0, frame.size.width, 56.0)];
    bar.delegate = self;
    bar.placeholder = @"搜索快捷指令";
    // 1.1.8-20 · 参考视频里的效果：搜索框不要背景。
    //   Minimal 样式去掉整条灰底；再把搜索字段自己的背景也置空，
    //   只剩放大镜 + 占位文字，直接贴在分组背景上。
    bar.searchBarStyle = UISearchBarStyleMinimal;
    bar.translucent = YES;
    bar.backgroundImage = [UIImage new];
    [bar setSearchFieldBackgroundImage:[UIImage new] forState:UIControlStateNormal];
    // 取消按钮只在输入时出现（见 searchBarTextDidBeginEditing:）
    bar.showsCancelButton = NO;
    // tableHeaderView 的宽度要以表格当前宽度为准，否则横屏/分屏下会短一截。
    bar.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(table.bounds), 56.0);
    [bar layoutIfNeeded];
    table.tableHeaderView = bar;
    self.searchBar = bar;

    [self.view addSubview:table];
    self.addTableView = table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"添加";
    [self refilter];
}

// 只过滤「未显示」列表 —— 已显示的那批在主页上，这里不重复出现。
- (void)refilter {
    NSString *needle = self.searchText.lowercaseString;
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *shortcut in self.allShortcuts) {
        NSString *uuid = shortcut[@"uuid"];
        if (![uuid isKindOfClass:[NSString class]] || !uuid.length) continue;
        if ([self.visibleUUIDs containsObject:uuid]) continue;
        if (needle.length) {
            NSString *name = shortcut[@"name"];
            BOOL matched = ([name isKindOfClass:[NSString class]] &&
                            [name.lowercaseString containsString:needle]);
            if (!matched && [uuid.lowercaseString hasPrefix:needle]) matched = YES;
            if (!matched) continue;
        }
        [result addObject:shortcut];
    }
    self.filtered = result;
}

- (NSString *)displayNameForShortcut:(NSDictionary *)shortcut {
    NSString *name = shortcut[@"name"];
    if ([name isKindOfClass:[NSString class]] && name.length) return name;
    NSString *uuid = shortcut[@"uuid"];
    return [uuid isKindOfClass:[NSString class]] ? uuid : @"快捷指令";
}

// MARK: - UISearchBarDelegate

// 1.1.8-20 · 「取消」只在点击输入框、开始编辑时出现；不点就不显示。
- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:NO animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.searchText = searchText ?: @"";
    [self refilter];
    [self.addTableView reloadData];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    self.searchText = @"";
    [searchBar resignFirstResponder];
    [self refilter];
    [self.addTableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

// MARK: - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return self.filtered.count ? (NSInteger)self.filtered.count : 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return [NSString stringWithFormat:@"未显示控制项（%lu）", (unsigned long)self.filtered.count];
}

// 1.1.8-18 · 诊断信息放在「未显示控制项」下面（用户指定的位置）——
// 内容与原来主页 footer 完全一致，只是搬了位置。
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    NSDictionary *payload =
        [NSDictionary dictionaryWithContentsOfFile:
         [kERShortcutSnapshotDirectory stringByAppendingPathComponent:kERShortcutSnapshotFileName]];
    if (![payload isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *timestamp = ERShortcutTimestampLine(payload);
    if (timestamp.length) [lines addObject:timestamp];
    NSString *summary = ERShortcutDiagnosticSummary(payload);
    if (summary.length) [lines addObject:summary];
    NSString *store = ERShortcutStorePathLine(payload);
    if (store.length) [lines addObject:[NSString stringWithFormat:@"数据库：%@", store]];
    NSString *detail = ERShortcutDiscoveryDetail(payload);
    if (detail.length) [lines addObject:detail];
    [lines addObject:@"点一下某条即可加入「显示控制项」，修改立即生效。"];
    return [lines componentsJoinedByString:@"\n"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ERShortcutAddCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    if (self.filtered.count == 0) {
        cell.textLabel.text = @"没有可添加的快捷指令";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = YES;
        return cell;
    }
    cell.userInteractionEnabled = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSDictionary *shortcut = self.filtered[indexPath.row];
    cell.textLabel.text = [self displayNameForShortcut:shortcut];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.imageView.image = ERShortcutCellIcon(shortcut);
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.clipsToBounds = YES;
    NSString *uuid = shortcut[@"uuid"];
    cell.detailTextLabel.text = ([uuid isKindOfClass:[NSString class]] && uuid.length > 8)
        ? [uuid substringToIndex:8]
        : (uuid ?: @"");
    // 1.1.8-19 · secondaryLabelColor 在白底下太发白（用户反馈），
    // 用 labelColor 靠字号区分主次，颜色上足够清楚。
    cell.detailTextLabel.textColor = UIColor.labelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.filtered.count) return;
    NSString *uuid = self.filtered[indexPath.row][@"uuid"];
    if (![uuid isKindOfClass:[NSString class]] || !uuid.length) return;

    [self.visibleUUIDs addObject:uuid];
    // 立刻写库 + 唤醒 SpringBoard，控制中心的「添加控制项」面板马上就能看到。
    ERShortcutPersistVisible(self.visibleUUIDs, self.allShortcuts.count);
    [self refilter];
    [self.addTableView reloadData];
    // 加完就弹回主页，主页在 viewWillAppear 里刷新，这一条会立刻出现在列表里。
    [self.navigationController popViewControllerAnimated:YES];
}

@end
