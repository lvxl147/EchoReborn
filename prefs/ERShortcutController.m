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

// Where SpringBoard publishes what it fetched. Same directory as the
// diagnostics log, chosen because SpringBoard and this bundle run as `mobile`
// and both can reach it — including under roothide, whose jbroot() is
// randomised per install, which is why the path is absolute and outside the
// jailbreak root.
static NSString *const kERShortcutSnapshotDirectory = @"/var/mobile/Library/Logs/EchoReborn";
static NSString *const kERShortcutSnapshotFileName = @"shortcuts.plist";

static NSInteger const kERSectionVisible = 0;

// 1.0.7-17：子页行图标 —— 与控制中心里快捷指令磁贴**同一套画法**。
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

// 把一段文本（emoji / 字符）画成白色前景图。
static UIImage *ERShortcutTextGlyph(NSString *text) {
    if (!text.length) return nil;
    CGSize canvas = CGSizeMake(28.0, 28.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:22.0 weight:UIFontWeightMedium],
                                NSForegroundColorAttributeName: [UIColor whiteColor]};
        CGSize ts = [text sizeWithAttributes:attrs];
        [text drawAtPoint:CGPointMake((canvas.width - ts.width) * 0.5,
                                      (canvas.height - ts.height) * 0.5)
           withAttributes:attrs];
    }];
}

// 1.1.8-8 · WFKit 图标 API 探测（一次性）：对照 Actra（它用 WorkflowKit 的
// WFDatabase + attributionIconWithSize:scale:rounded:/symbolName），把
// WorkflowKit 里所有 Icon 相关类的方法面列出来，确认符号名的官方来源。
static void ERShortcutLog(NSString *format, ...);

static void ERWFKitProbeOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_LAZY);
        ERShortcutLog(@"WFPROBE dlopen=%d", handle ? 1 : 0);
        if (!handle) return;

        // 1) WorkflowKit 镜像里所有跟 Icon / Workflow 有关的类
        unsigned int total = 0;
        Class *all = objc_copyClassList(&total);
        NSMutableArray<NSString *> *wfClasses = [NSMutableArray array];
        if (all) {
            for (unsigned int index = 0; index < total; index++) {
                const char *image = class_getImageName(all[index]);
                if (!image) continue;
                NSString *imagePath = [NSString stringWithUTF8String:image];
                if ([imagePath rangeOfString:@"WorkflowKit"].location == NSNotFound) continue;
                NSString *className = NSStringFromClass(all[index]);
                if (!className.length) continue;
                if (([className rangeOfString:@"Icon"].location != NSNotFound ||
                     [className rangeOfString:@"Workflow"].location != NSNotFound) &&
                    wfClasses.count < 160) {
                    [wfClasses addObject:className];
                }
            }
            free(all);
        }
        ERShortcutLog(@"WFPROBE WorkflowKit 类(%lu)=%@", (unsigned long)wfClasses.count, wfClasses);

        // 2) 逐个 Icon 类列出方法面（类方法 + 实例方法各前 25 条）
        for (NSString *className in wfClasses) {
            if ([className rangeOfString:@"Icon"].location == NSNotFound) continue;
            Class cls = NSClassFromString(className);
            if (!cls) continue;
            unsigned int classCount = 0;
            Method *classMethods = class_copyMethodList(object_getClass(cls), &classCount);
            NSMutableArray<NSString *> *classNames = [NSMutableArray array];
            for (unsigned int index = 0; index < classCount && index < 25; index++) {
                [classNames addObject:NSStringFromSelector(method_getName(classMethods[index]))];
            }
            if (classMethods) free(classMethods);
            unsigned int instCount = 0;
            Method *instMethods = class_copyMethodList(cls, &instCount);
            NSMutableArray<NSString *> *instNames = [NSMutableArray array];
            for (unsigned int index = 0; index < instCount && index < 25; index++) {
                [instNames addObject:NSStringFromSelector(method_getName(instMethods[index]))];
            }
            if (instMethods) free(instMethods);
            ERShortcutLog(@"WFPROBE [%@] +(%u)=%@ -(%u)=%@",
                          className, classCount, classNames, instCount, instNames);
        }

        // 3) WFDatabase 的方法面（Actra 就是从这里取 workflow 的）
        Class dbClass = NSClassFromString(@"WFDatabase");
        if (dbClass) {
            unsigned int classCount = 0;
            Method *classMethods = class_copyMethodList(object_getClass(dbClass), &classCount);
            NSMutableArray<NSString *> *classNames = [NSMutableArray array];
            for (unsigned int index = 0; index < classCount && index < 40; index++) {
                [classNames addObject:NSStringFromSelector(method_getName(classMethods[index]))];
            }
            if (classMethods) free(classMethods);
            ERShortcutLog(@"WFPROBE WFDatabase +(%u)=%@", classCount, classNames);

            unsigned int instCount = 0;
            Method *instMethods = class_copyMethodList(dbClass, &instCount);
            NSMutableArray<NSString *> *instNames = [NSMutableArray array];
            for (unsigned int index = 0; index < instCount && index < 60; index++) {
                [instNames addObject:NSStringFromSelector(method_getName(instMethods[index]))];
            }
            if (instMethods) free(instMethods);
            ERShortcutLog(@"WFPROBE WFDatabase -(%u)前60=%@", instCount, instNames);
        }

        // 4) 直接验证 glyph → 符号名映射（0xF000 就是那条画不出来的默认值）
        NSString *(*mapper)(unsigned short) =
            (NSString *(*)(unsigned short))dlsym(handle, "WFSystemImageNameForGlyphCharacter");
        ERShortcutLog(@"WFPROBE mapper=%d", mapper ? 1 : 0);
        if (mapper) {
            for (NSNumber *glyph in @[@(0xF000), @(0xE82D), @(0xE877), @(0xF086), @(0xE80D)]) {
                unsigned short code = (unsigned short)glyph.unsignedShortValue;
                NSString *name = mapper(code);
                ERShortcutLog(@"WFPROBE glyph 0x%04X -> %@ (image=%d)", (unsigned)code,
                              name ?: @"nil", name.length ? ([UIImage systemImageNamed:name] ? 1 : 0) : -1);
            }
        }
    });
}
static UIImage *ERShortcutCellIcon(NSDictionary *shortcut) {
    if (![shortcut isKindOfClass:[NSDictionary class]]) return nil;
    UIColor *background = ERShortcutCellColorFromValue([shortcut[@"color"] longLongValue]);

    // 1.1.8-8 · 图标来源优先级（对齐「快捷指令」App 自己的画法）：
    //   自定义图片 > 符号名(ZSYMBOLNAME) > emoji > glyph 字符映射 > 兜底。
    //   1.1.8-7 的素色方块：这些行的 glyph 恒为 0xF000，映射不出来，
    //   而旧的兜底会去「画 glyph 字符本身」——0xE000~0xF8FF 是私有区，
    //   画出来是一张全透明图，于是盖掉了最后的 sparkles 兜底。
    UIImage *customImage = nil;
    UIImage *glyph = nil;

    NSString *iconFile = [shortcut[@"iconFile"] isKindOfClass:[NSString class]] ? shortcut[@"iconFile"] : nil;
    if (iconFile.length) {
        customImage = [UIImage imageWithContentsOfFile:
                       [ERShortcutIconDirectory() stringByAppendingPathComponent:iconFile]];
    }

    if (!customImage) {
        static NSString *(*mapper)(unsigned short);
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            void *handle = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_LAZY);
            if (!handle) {
                handle = dlopen("/System/Library/Frameworks/WorkflowKit.framework/WorkflowKit", RTLD_LAZY);
            }
            if (handle) mapper = (NSString *(*)(unsigned short))dlsym(handle, "WFSystemImageNameForGlyphCharacter");
        });

        NSString *symbolName = [shortcut[@"symbolName"] isKindOfClass:[NSString class]] ? shortcut[@"symbolName"] : nil;
        if (!symbolName.length) {
            unsigned short ch = (unsigned short)[shortcut[@"glyph"] unsignedShortValue];
            if (mapper && ch) {
                NSString *mapped = mapper(ch);
                if ([mapped isKindOfClass:[NSString class]] && mapped.length) symbolName = mapped;
            }
        }
        if (symbolName.length) glyph = [UIImage systemImageNamed:symbolName];

        if (!glyph) {
            NSString *emoji = [shortcut[@"emoji"] isKindOfClass:[NSString class]] ? shortcut[@"emoji"] : nil;
            if (!emoji.length) {
                unsigned short ch = (unsigned short)[shortcut[@"glyph"] unsignedShortValue];
                // 只对普通可读字符做文本兜底；私有区字符画出来是全透明的。
                if (ch >= 0x20 && ch < 0xE000) emoji = [NSString stringWithFormat:@"%C", (unichar)ch];
            }
            if (emoji.length) glyph = ERShortcutTextGlyph(emoji);
        }
        if (!glyph) glyph = [UIImage systemImageNamed:@"sparkles"];
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
            CGFloat side = MIN(CGRectGetWidth(path.bounds), CGRectGetHeight(path.bounds)) * 0.55;
            CGFloat scale = glyph.size.width > 1.0 ? MIN(side / glyph.size.width, side / glyph.size.height) : 1.0;
            CGSize drawn = CGSizeMake(glyph.size.width * scale, glyph.size.height * scale);
            [glyph drawInRect:CGRectMake(CGRectGetMidX(rect) - drawn.width / 2.0,
                                         CGRectGetMidY(rect) - drawn.height / 2.0,
                                         drawn.width, drawn.height)];
        }
    }];
}

static NSInteger const kERSectionHidden = 1;

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
    CFPreferencesSetAppValue((__bridge CFStringRef)kERShortcutVisibleKey,
                             (__bridge CFPropertyListRef)[self.visibleUUIDs.allObjects copy],
                             (__bridge CFStringRef)kERShortcutPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERShortcutPrefsDomain);
    // SpringBoard re-reads the gate every time the gallery is rebuilt, so this
    // only has to wake it — no respring.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kERShortcutReloadNotification,
                                         NULL, NULL, YES);
    ERShortcutLog(@"shortcutPane: persisted %lu visible of %lu fetched",
                   (unsigned long)self.visibleUUIDs.count, (unsigned long)self.fetched.count);
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

- (NSArray<NSDictionary *> *)shortcutsInSection:(NSInteger)section {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *shortcut in self.fetched) {
        NSString *uuid = shortcut[@"uuid"];
        if (![uuid isKindOfClass:[NSString class]]) continue;
        BOOL visible = [self.visibleUUIDs containsObject:uuid];
        if ((section == kERSectionVisible) == visible) [result addObject:shortcut];
    }
    return result;
}

- (NSString *)displayNameForShortcut:(NSDictionary *)shortcut {
    NSString *name = shortcut[@"name"];
    if ([name isKindOfClass:[NSString class]] && name.length) return name;
    NSString *uuid = shortcut[@"uuid"];
    return [uuid isKindOfClass:[NSString class]] ? uuid : @"快捷指令";
}

// One sentence that answers "did the tweak get the data, and if not, why not".
- (NSString *)diagnosticSummary {
    NSString *status = self.diagnostics[@"status"];
    NSUInteger containers = [self.diagnostics[@"containerCount"] unsignedIntegerValue];
    NSUInteger probed = [self.diagnostics[@"sqliteProbed"] unsignedIntegerValue];
    NSUInteger rowsSeen = [self.diagnostics[@"rowsSeen"] unsignedIntegerValue];

    if (![status isKindOfClass:[NSString class]]) {
        return @"尚未取得扫描结果。插件在打开控制中心或点击右上角「重新扫描」后才会写入数据。";
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
        NSArray *listed = self.diagnostics[@"triedPaths"];
        NSUInteger present = [self.diagnostics[@"candidatePresent"] unsignedIntegerValue];
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
        NSUInteger kept = [self.diagnostics[@"kept"] unsignedIntegerValue];
        return [NSString stringWithFormat:@"插件已成功获取到 %lu 条快捷指令。下方把某条移入「显示控制项」后，它才会出现在「添加控制项」面板里。",
                (unsigned long)kept];
    }
    return @"扫描状态未知。请点击右上角「重新扫描」。";
}

- (NSString *)storePathLine {
    NSString *path = self.diagnostics[@"databasePath"];
    if (![path isKindOfClass:[NSString class]] || !path.length) return @"未定位到数据库文件";
    return path;
}

// The container list and the paths actually probed, rendered so a failure can
// be read off the phone instead of off a log file.
- (NSString *)discoveryDetail {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSArray *containers = self.diagnostics[@"containerPaths"];
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
    NSArray *tried = self.diagnostics[@"triedPaths"];
    if ([tried isKindOfClass:[NSArray class]] && tried.count) {
        NSUInteger present = [self.diagnostics[@"candidatePresent"] unsignedIntegerValue];
        [lines addObject:[NSString stringWithFormat:@"候选路径 %lu 条，其中存在 %lu 条。",
                          (unsigned long)tried.count, (unsigned long)present]];
    }
    NSArray *probed = self.diagnostics[@"probedPaths"];
    if ([probed isKindOfClass:[NSArray class]] && probed.count) {
        [lines addObject:[NSString stringWithFormat:@"检查过的文件（%lu）：", (unsigned long)probed.count]];
        for (NSString *path in probed) {
            if ([path isKindOfClass:[NSString class]]) [lines addObject:[NSString stringWithFormat:@"  %@", path]];
        }
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"";
}

- (NSString *)timestampLine {
    NSDate *writtenAt = self.diagnostics[@"writtenAt"];
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
    ERWFKitProbeOnce();
    [super viewDidLoad];
    self.title = @"快捷指令";
    // 0.4.7: the scan now runs here, inside Preferences, which can read the
    // Shortcuts store that SpringBoard is sandboxed away from. Previously this
    // pane only displayed a snapshot SpringBoard had written; now it produces
    // the data itself and shares it with SpringBoard via the prefs domain.
    ERShortcutScanAndPublish();
    // Seeded before the first data-source pass so the pane never renders in an
    // unloaded state.
    [self loadSnapshot];

    UIBarButtonItem *rescan = [[UIBarButtonItem alloc] initWithTitle:@"重新扫描"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(rescan:)];
    self.navigationItem.rightBarButtonItem = rescan;
    [self.shortcutTableView reloadData];
    ERShortcutLog(@"shortcutPane: viewDidLoad done");
}

// MARK: - Actions

- (void)rescan:(__unused UIBarButtonItem *)sender {
    // 0.4.7: the scan runs in this process (Preferences), which can read the
    // Shortcuts store. ERShortcutScanAndPublish() writes the catalog to the
    // shared prefs domain and posts kERShortcutRescanNotification itself to wake
    // SpringBoard, so there is no async wait and no round-trip to SpringBoard.
    ERShortcutLog(@"shortcutPane: rescan requested");
    ERShortcutScanAndPublish();
    [self loadSnapshot];
    [self.shortcutTableView reloadData];
}

// MARK: - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *rows = [self shortcutsInSection:section];
    // An empty state row: without it a section with nothing in it renders as a
    // bare header on top of nothing, which reads like a broken pane.
    return rows.count ? (NSInteger)rows.count : 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSUInteger count = [self shortcutsInSection:section].count;
    return section == kERSectionVisible
        ? [NSString stringWithFormat:@"显示控制项（%lu）", (unsigned long)count]
        : [NSString stringWithFormat:@"未显示控制项（%lu）", (unsigned long)count];
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == kERSectionHidden) {
        return [NSString stringWithFormat:@"%@\n\n数据库：%@\n%@\n\n%@\n\n点一下某条即可在两类之间移动，修改立即保存。只有「显示控制项」里的快捷指令才会出现在控制中心的「添加控制项」面板中。",
                [self diagnosticSummary],
                [self storePathLine],
                [self timestampLine],
                [self discoveryDetail]];
    }
    if (section == kERSectionVisible && self.visibleUUIDs.count == 0) {
        return @"目前没有已启用的快捷指令，因此控制中心里暂时看不到「快捷指令」分类——这是正常状态，不是故障。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ERShortcutCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    NSArray<NSDictionary *> *rows = [self shortcutsInSection:indexPath.section];
    if (rows.count == 0) {
        cell.textLabel.text = indexPath.section == kERSectionVisible ? @"暂无" : @"没有获取到快捷指令";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = NO;
        return cell;
    }
    cell.userInteractionEnabled = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSDictionary *shortcut = rows[indexPath.row];
    cell.textLabel.text = [self displayNameForShortcut:shortcut];
    cell.textLabel.textColor = UIColor.labelColor;
    // 1.0.7-17：行左侧图标 —— 与控制中心快捷指令磁贴同一套画法（颜色 + glyph）。
    cell.imageView.image = ERShortcutCellIcon(shortcut);
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.clipsToBounds = YES;
    // The uuid is shown because two shortcuts can legitimately share a name,
    // and because it is the one value that identifies a row across rescans.
    NSString *uuid = shortcut[@"uuid"];
    cell.detailTextLabel.text = ([uuid isKindOfClass:[NSString class]] && uuid.length > 8)
        ? [uuid substringToIndex:8]
        : (uuid ?: @"");
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    BOOL visible = (uuid.length && [self.visibleUUIDs containsObject:uuid]);
    cell.accessoryType = visible ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = UIColor.systemGreenColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSDictionary *> *rows = [self shortcutsInSection:indexPath.section];
    if (indexPath.row >= (NSInteger)rows.count) return;
    NSString *uuid = rows[indexPath.row][@"uuid"];
    if (![uuid isKindOfClass:[NSString class]] || !uuid.length) return;

    if ([self.visibleUUIDs containsObject:uuid]) [self.visibleUUIDs removeObject:uuid];
    else [self.visibleUUIDs addObject:uuid];
    [self persist];
    // A full reload, not a row update: the row has changed section, so the two
    // section counts and both footers change with it.
    [tableView reloadData];
}

@end
