#import "ERShortcutScanner.h"
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <stdarg.h>
#import <objc/message.h>
#import <stdlib.h>

// Must match Tweak.xm's kERPrefsDomain and the prefs pane's constants.
static NSString *const kERShortcutPrefsDomain = @"com.strive.echoreborn.preferences";
// Key SpringBoard reads the catalog from (via ERPreferenceArray in Tweak.xm).
static NSString *const kERShortcutCatalogKey = @"ShortcutCatalog";
// Darwin notification SpringBoard already observes to force a catalog rebuild.
static NSString *const kERShortcutRescanNotification = @"com.strive.echoreborn/RescanShortcuts";
static NSString *const kERShortcutSnapshotDirectory = @"/var/mobile/Library/Logs/EchoReborn";
static NSString *const kERShortcutSnapshotFileName = @"shortcuts.plist";

static void ERShortcutLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [PREFS-SCAN] %@\n", [NSDate date].description, message];
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

// ---------------------------------------------------------------------------
// libsqlite3 via dlopen (same pattern Tweak.xm uses, so there is no SDK header
// or link dependency to get wrong).
// ---------------------------------------------------------------------------
typedef struct sqlite3 ER_sqlite3;
typedef struct sqlite3_stmt ER_sqlite3_stmt;
static int (*EROpenV2)(const char *, ER_sqlite3 **, int, const char *);
static int (*ERPrepareV2)(ER_sqlite3 *, const char *, int, ER_sqlite3_stmt **, const char **);
static int (*ERStep)(ER_sqlite3_stmt *);
static int (*ERColumnCount)(ER_sqlite3_stmt *);
static const char *(*ERColumnName)(ER_sqlite3_stmt *, int);
static int (*ERColumnType)(ER_sqlite3_stmt *, int);
static const unsigned char *(*ERColumnText)(ER_sqlite3_stmt *, int);
static long long (*ERColumnInt64)(ER_sqlite3_stmt *, int);
static const void *(*ERColumnBlob)(ER_sqlite3_stmt *, int);
static int (*ERColumnBytes)(ER_sqlite3_stmt *, int);
static int (*ERFinalize)(ER_sqlite3_stmt *);
static int (*ERClose)(ER_sqlite3 *);

static BOOL ERSQLiteResolve(void) {
    static BOOL resolved = NO;
    static BOOL ready = NO;
    if (resolved) return ready;
    resolved = YES;
    void *handle = dlopen("/usr/lib/libsqlite3.dylib", RTLD_LAZY);
    if (!handle) handle = RTLD_DEFAULT;
    EROpenV2      = (int (*)(const char *, ER_sqlite3 **, int, const char *))dlsym(handle, "sqlite3_open_v2");
    ERPrepareV2   = (int (*)(ER_sqlite3 *, const char *, int, ER_sqlite3_stmt **, const char **))dlsym(handle, "sqlite3_prepare_v2");
    ERStep        = (int (*)(ER_sqlite3_stmt *))dlsym(handle, "sqlite3_step");
    ERColumnCount = (int (*)(ER_sqlite3_stmt *))dlsym(handle, "sqlite3_column_count");
    ERColumnName  = (const char *(*)(ER_sqlite3_stmt *, int))dlsym(handle, "sqlite3_column_name");
    ERColumnType  = (int (*)(ER_sqlite3_stmt *, int))dlsym(handle, "sqlite3_column_type");
    ERColumnText  = (const unsigned char *(*)(ER_sqlite3_stmt *, int))dlsym(handle, "sqlite3_column_text");
    ERColumnInt64 = (long long (*)(ER_sqlite3_stmt *, int))dlsym(handle, "sqlite3_column_int64");
    ERColumnBlob  = (const void *(*)(ER_sqlite3_stmt *, int))dlsym(handle, "sqlite3_column_blob");
    ERColumnBytes = (int (*)(ER_sqlite3_stmt *, int))dlsym(handle, "sqlite3_column_bytes");
    ERFinalize    = (int (*)(ER_sqlite3_stmt *))dlsym(handle, "sqlite3_finalize");
    ERClose       = (int (*)(ER_sqlite3 *))dlsym(handle, "sqlite3_close");
    ready = EROpenV2 && ERPrepareV2 && ERStep && ERColumnCount && ERColumnName &&
            ERColumnType && ERColumnText && ERColumnInt64 && ERColumnBlob &&
            ERColumnBytes && ERFinalize && ERClose;
    return ready;
}

// Candidate store paths, in priority order. The first is the canonical global
// store EvoCenter16 opens directly; the rest cover iCloud/roothide layouts.
static NSArray<NSString *> *ERShortcutDatabaseCandidates(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *p) {
        if (p.length && ![candidates containsObject:p]) [candidates addObject:p];
    };
    add(@"/var/mobile/Library/Shortcuts/Shortcuts.sqlite");
    add(@"/var/mobile/Library/Mobile Documents/com~apple~Shortcuts/Shortcuts.sqlite");
    NSString *home = NSHomeDirectory();
    if (home.length) {
        add([home stringByAppendingPathComponent:@"Library/Shortcuts/Shortcuts.sqlite"]);
        add([home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~Shortcuts/Shortcuts.sqlite"]);
    }
    return candidates;
}

static BOOL ERSQLiteStoreHasShortcutTable(ER_sqlite3 *database) {
    if (!database) return NO;
    ER_sqlite3_stmt *stmt = NULL;
    BOOL found = NO;
    if (ERPrepareV2(database, "SELECT 1 FROM ZSHORTCUT LIMIT 1", -1, &stmt, NULL) == 0 && stmt) {
        found = (ERStep(stmt) == 100 /* SQLITE_ROW */);
        ERFinalize(stmt);
    }
    return found;
}

// Opens `path`, copying the WAL store into a temp dir so we never race the
// Shortcuts app's own writer, and returns a read-write handle (or NULL).
static ER_sqlite3 *EROpenStoreCopy(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return NULL;
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"echoreborn-shortcuts-%f", CFAbsoluteTimeGetCurrent()]];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *copy = [tmp stringByAppendingPathComponent:@"Shortcuts.sqlite"];
    [fm copyItemAtPath:path toPath:copy error:nil];
    for (NSString *suffix in @[@"-wal", @"-shm"]) {
        NSString *sidecar = [path stringByAppendingString:suffix];
        if ([fm fileExistsAtPath:sidecar]) {
            [fm copyItemAtPath:sidecar toPath:[copy stringByAppendingString:suffix] error:nil];
        }
    }
    ER_sqlite3 *db = NULL;
    // SQLITE_OPEN_READWRITE == 0x00000002; the copy exists, so no CREATE.
    if (EROpenV2(copy.fileSystemRepresentation, &db, 0x00000002, NULL) != 0 || !db) {
        if (db) { ERClose(db); db = NULL; }
        // Fall back to the live store read-only (same fallback Tweak.xm used).
        if (EROpenV2(path.fileSystemRepresentation, &db, 0x00000001, NULL) != 0 || !db) {
            if (db) { ERClose(db); db = NULL; }
        }
    }
    return db;
}

// 1.1.8-8 · 诊断：把 ZSHORTCUTICON 的真实列结构写进日志。1.1.8-7 的现象是
// 「glyph = 0xF000 的行只有素色方块」，怀疑这些行的图标其实存在 ZSYMBOLNAME
// / ZEMOJI 一类的列里（iOS 17 的图标选择器改成「符号名 + 颜色」为主）。
static void ERDumpIconSchema(ER_sqlite3 *database) {
    if (!database) return;
    ER_sqlite3_stmt *stmt = NULL;
    NSMutableArray<NSString *> *tables = [NSMutableArray array];
    if (ERPrepareV2(database, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%ICON%'",
                    -1, &stmt, NULL) == 0 && stmt) {
        while (ERStep(stmt) == 100) {
            const unsigned char *t = ERColumnText(stmt, 0);
            if (t) [tables addObject:[NSString stringWithUTF8String:(const char *)t]];
        }
        ERFinalize(stmt);
    }
    ERShortcutLog(@"schema: ICON tables=%@", tables);

    stmt = NULL;
    if (ERPrepareV2(database, "PRAGMA table_info(ZSHORTCUTICON)", -1, &stmt, NULL) == 0 && stmt) {
        NSMutableArray<NSString *> *cols = [NSMutableArray array];
        while (ERStep(stmt) == 100) {
            const unsigned char *n = ERColumnText(stmt, 1);
            const unsigned char *ty = ERColumnText(stmt, 2);
            if (n) {
                [cols addObject:[NSString stringWithFormat:@"%s:%s",
                                 (const char *)n, ty ? (const char *)ty : "?"]];
            }
        }
        ERFinalize(stmt);
        ERShortcutLog(@"schema: ZSHORTCUTICON 列=%@", cols);
    }

    stmt = NULL;
    if (ERPrepareV2(database, "SELECT * FROM ZSHORTCUTICON LIMIT 3", -1, &stmt, NULL) == 0 && stmt) {
        int row = 0;
        while (ERStep(stmt) == 100 && row < 3) {
            NSMutableArray<NSString *> *vals = [NSMutableArray array];
            int columns = ERColumnCount(stmt);
            for (int index = 0; index < columns; index++) {
                const char *rawName = ERColumnName(stmt, index);
                if (!rawName) continue;
                NSString *name = [NSString stringWithUTF8String:rawName];
                int type = ERColumnType(stmt, index);
                if (type == 1) {
                    [vals addObject:[NSString stringWithFormat:@"%@=%lld", name, ERColumnInt64(stmt, index)]];
                } else if (type == 3) {
                    const unsigned char *t = ERColumnText(stmt, index);
                    [vals addObject:[NSString stringWithFormat:@"%@=\"%s\"", name, t ? (const char *)t : ""]];
                } else if (type == 4) {
                    [vals addObject:[NSString stringWithFormat:@"%@=<blob %d>", name, ERColumnBytes(stmt, index)]];
                } else {
                    [vals addObject:[NSString stringWithFormat:@"%@=<type %d>", name, type]];
                }
            }
            ERShortcutLog(@"schema: ZSHORTCUTICON row%d %@", row, [vals componentsJoinedByString:@" "]);
            row++;
        }
        ERFinalize(stmt);
    }
}

// Reads one icon row (ZSHORTCUTICON) by primary key, mapping columns by name.
static NSDictionary *ERReadIconRow(ER_sqlite3 *database, long long iconPK) {
    if (!database || iconPK <= 0) return nil;
    NSString *query = [NSString stringWithFormat:@"SELECT * FROM ZSHORTCUTICON WHERE Z_PK = %lld", iconPK];
    ER_sqlite3_stmt *stmt = NULL;
    if (ERPrepareV2(database, query.UTF8String, -1, &stmt, NULL) != 0 || !stmt) return nil;
    NSMutableDictionary *icon = [NSMutableDictionary dictionary];
    if (ERStep(stmt) == 100 /* SQLITE_ROW */) {
        int columns = ERColumnCount(stmt);
        for (int index = 0; index < columns; index++) {
            const char *rawName = ERColumnName(stmt, index);
            if (!rawName) continue;
            NSString *name = [[NSString stringWithUTF8String:rawName] uppercaseString];
            int type = ERColumnType(stmt, index);
            BOOL isText = (type == 3 && ERColumnText(stmt, index) != NULL);
            if ([name containsString:@"GLYPH"] && type == 1 /* INTEGER */) {
                icon[@"glyph"] = @(ERColumnInt64(stmt, index));
            } else if ([name containsString:@"COLOR"] && type == 1) {
                if (!icon[@"color"]) icon[@"color"] = @(ERColumnInt64(stmt, index));
            } else if (([name containsString:@"IMAGE"] || [name containsString:@"DATA"]) && type == 4 /* BLOB */) {
                const void *blob = ERColumnBlob(stmt, index);
                int bytes = ERColumnBytes(stmt, index);
                if (blob && bytes > 0) icon[@"imageData"] = [NSData dataWithBytes:blob length:(NSUInteger)bytes];
            } else if (isText && [name containsString:@"SYMBOL"]) {
                // 1.1.8-8 · iOS 17 的图标选择器把「符号」存成 SF Symbol 名字，
                // 这种图标没有 glyph（glyph 恒为 0xF000），只有名字。
                NSString *value = [[NSString alloc] initWithUTF8String:(const char *)ERColumnText(stmt, index)];
                if (value.length) icon[@"symbolName"] = value;
            } else if (isText && [name containsString:@"EMOJI"]) {
                NSString *value = [[NSString alloc] initWithUTF8String:(const char *)ERColumnText(stmt, index)];
                if (value.length) icon[@"emoji"] = value;
            }
        }
    }
    ERFinalize(stmt);
    if (icon.count) ERShortcutLog(@"icon: pk=%lld -> symbol=%@ glyph=%@ color=%@ image=%lub",
                                  iconPK, icon[@"symbolName"] ?: @"-", icon[@"glyph"] ?: @"-",
                                  icon[@"color"] ?: @"-", (unsigned long)[icon[@"imageData"] length]);
    return icon.count ? icon : nil;
}

// 1.1.8-8 · 自定义图片图标落到磁盘：快照 plist 里放不下几 MB 的图片，所以
// 每条改成写一个文件，设置页按 uuid 去取。
static NSString *ERShortcutIconDirectory(void) {
    return [kERShortcutSnapshotDirectory stringByAppendingPathComponent:@"shortcut-icons"];
}

static NSString *ERWriteShortcutIconImage(NSString *uuid, UIImage *image) {
    if (!uuid.length || !image) return nil;
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = ERShortcutIconDirectory();
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [uuid stringByAppendingPathExtension:@"png"];
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSData *png = UIImagePNGRepresentation(image);
    if (png.length && [png writeToFile:path atomically:YES]) return name;
    return nil;
}

// ---------------------------------------------------------------------------
// 1.1.8-13 · 让 WorkflowKit 自己把图标画出来（与 Actra 同一条链路）
//
// 之前是靠读 sqlite 的 ZGLYPHNUMBER 再把它翻译成 SF Symbol 名字：
// 字形表给的名字（app.2.stack.3d）在这台设备的 CoreGlyphs 里根本不存在，
// 于是只能一条一条地打补丁 —— 0xF000 补一个、下一条又补一个，永远补不完。
//
// 正确的做法是**不猜**：直接问 WorkflowKit 要它自己渲染好的图。
//   WFDatabase -initWithStoreDescription:runMigrationsIfNecessary:useLockFile:error:
//             -sortedVisibleWorkflowsByName
//   每条 workflow：-attributionIcon / -symbolName / -bundleIdentifier
//   attributionIcon -attributionIconWithSize:scale:rounded:
// 「快捷指令」App 画什么，我们就拿到什么 —— 系统符号、关联 App 图标、
// 还是字形表里某个叫不出名字的符号，一律自动识别，不需要为任何一条适配。
// ---------------------------------------------------------------------------
static NSString *const kERWorkflowKitStorePath = @"/var/mobile/Library/Shortcuts/Shortcuts.sqlite";

static id ERWorkflowKitValue(id object, NSString *key) {
    if (!object) return nil;
    @try { return [object valueForKey:key]; } @catch (__unused NSException *exception) { return nil; }
}

static NSString *ERWorkflowKitText(id value) {
    if ([value isKindOfClass:[NSString class]] && [value length]) return (NSString *)value;
    if ([value respondsToSelector:@selector(UUIDString)]) {
        @try {
            id text = ((id (*)(id, SEL))objc_msgSend)(value, @selector(UUIDString));
            if ([text isKindOfClass:[NSString class]] && [text length]) return (NSString *)text;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

// rounded=YES → 裁成圆角方块的完整图标；rounded=NO → 只有前景符号（透明底）。
static UIImage *ERWorkflowKitAttributionIcon(id target, CGSize size, BOOL rounded) {
    if (!target) return nil;
    SEL selector = NSSelectorFromString(@"attributionIconWithSize:scale:rounded:");
    if (![target respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature) return nil;
    @try {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.selector = selector;
        invocation.target = target;
        CGFloat scale = [UIScreen mainScreen].scale;
        if (scale < 1.0) scale = 3.0;
        BOOL flag = rounded;
        [invocation setArgument:&size atIndex:2];
        [invocation setArgument:&scale atIndex:3];
        [invocation setArgument:&flag atIndex:4];
        [invocation invoke];
        __unsafe_unretained id result = nil;
        [invocation getReturnValue:&result];
        if ([result isKindOfClass:[UIImage class]]) return (UIImage *)result;
    } @catch (__unused NSException *exception) {}
    return nil;
}

// 分辨 WorkflowKit 给的是「完整圆角图标」还是「透明底的前景符号」：
// 四角透明 + 四条边中点不透明 + 中心不透明 = 圆角方块（完整图标）；
// 四角透明 + 边中点也透明 + 中心不透明   = 只画了符号（前景）。
static BOOL ERIconImageIsFullTile(UIImage *image) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return NO;
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width < 12 || height < 12) return NO;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return NO;
    unsigned char *buffer = (unsigned char *)calloc(width * height * 4, 1);
    if (!buffer) { CGColorSpaceRelease(space); return NO; }
    CGContextRef context = CGBitmapContextCreate(buffer, width, height, 8, width * 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    BOOL full = NO;
    if (context) {
        CGContextDrawImage(context, CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height), cgImage);
        size_t inset = 2;
        // 中心不透明才是一张有用的图
        size_t centerIndex = ((height / 2) * width + (width / 2)) * 4 + 3;
        BOOL centerOpaque = buffer[centerIndex] > 32;
        // 四条边的中点
        size_t edgeSamples[4] = {
            (inset * width + (width / 2)) * 4 + 3,               // 上
            ((height - 1 - inset) * width + (width / 2)) * 4 + 3, // 下
            ((height / 2) * width + inset) * 4 + 3,               // 左
            ((height / 2) * width + (width - 1 - inset)) * 4 + 3  // 右
        };
        NSUInteger opaqueEdges = 0;
        for (int index = 0; index < 4; index++) {
            if (buffer[edgeSamples[index]] > 32) opaqueEdges++;
        }
        full = centerOpaque && opaqueEdges >= 3;
        CGContextRelease(context);
    }
    free(buffer);
    CGColorSpaceRelease(space);
    return full;
}

// uuid → @{@"icon": UIImage, @"full": @(BOOL), @"symbolName": NSString, @"bundleId": NSString}
static NSDictionary<NSString *, NSDictionary *> *ERWorkflowKitIcons(void) {
    static NSDictionary *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *built = [NSMutableDictionary dictionary];
        table = built;

        // CoreData 提供 NSPersistentStoreDescription，WorkflowKit 提供 WFDatabase。
        dlopen("/System/Library/Frameworks/CoreData.framework/CoreData", RTLD_LAZY);
        void *handle = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_LAZY);
        if (!handle) { ERShortcutLog(@"wfkit: WorkflowKit unavailable"); return; }
        Class databaseClass = NSClassFromString(@"WFDatabase");
        if (!databaseClass) { ERShortcutLog(@"wfkit: WFDatabase unavailable"); return; }

        id database = nil;
        @try {
            id description = nil;
            Class descriptionClass = NSClassFromString(@"NSPersistentStoreDescription");
            if (descriptionClass) {
                NSURL *url = [NSURL fileURLWithPath:kERWorkflowKitStorePath];
                description = ((id (*)(id, SEL, id))objc_msgSend)(
                    [descriptionClass alloc], NSSelectorFromString(@"initWithURL:"), url);
            }
            SEL initSelector = NSSelectorFromString(@"initWithStoreDescription:runMigrationsIfNecessary:useLockFile:error:");
            if (description && [[databaseClass alloc] respondsToSelector:initSelector]) {
                NSError *error = nil;
                // runMigrations / useLockFile 一律 NO：只是读，绝不改动用户的数据库。
                database = ((id (*)(id, SEL, id, BOOL, BOOL, NSError **))objc_msgSend)(
                    [databaseClass alloc], initSelector, description, NO, NO, &error);
                if (!database && error) {
                    ERShortcutLog(@"wfkit: open error %@", error.localizedDescription);
                }
            }
        } @catch (NSException *exception) {
            ERShortcutLog(@"wfkit: open exception %@", exception.reason);
        }
        if (!database) {
            // 显式建库失败（比如没有权限创建 CoreData 栈）时退到类方法入口。
            for (NSString *selectorName in @[@"defaultDatabase", @"shortcutsDatabase",
                                             @"sharedDatabase", @"standardDatabase"]) {
                SEL selector = NSSelectorFromString(selectorName);
                if (![databaseClass respondsToSelector:selector]) continue;
                @try {
                    id candidate = ((id (*)(id, SEL))objc_msgSend)(databaseClass, selector);
                    if (candidate) {
                        database = candidate;
                        ERShortcutLog(@"wfkit: using +%@", selectorName);
                        break;
                    }
                } @catch (__unused NSException *exception) {}
            }
        }
        if (!database) { ERShortcutLog(@"wfkit: database API unavailable"); return; }

        NSArray *workflows = nil;
        @try {
            if ([database respondsToSelector:NSSelectorFromString(@"sortedVisibleWorkflowsByName")]) {
                workflows = ((NSArray *(*)(id, SEL))objc_msgSend)(
                    database, NSSelectorFromString(@"sortedVisibleWorkflowsByName"));
            }
        } @catch (NSException *exception) {
            ERShortcutLog(@"wfkit: list exception %@", exception.reason);
        }
        if (![workflows isKindOfClass:[NSArray class]]) {
            ERShortcutLog(@"wfkit: shortcut API unavailable");
            return;
        }
        ERShortcutLog(@"wfkit: %lu workflow(s)", (unsigned long)workflows.count);

        CGSize size = CGSizeMake(120.0, 120.0);
        NSUInteger withIcon = 0, withSymbol = 0, withBundle = 0, fullTiles = 0;
        NSUInteger index = 0;
        for (id workflow in workflows) {
            NSString *uuid = ERWorkflowKitText(ERWorkflowKitValue(workflow, @"workflowID"));
            if (!uuid.length) uuid = ERWorkflowKitText(ERWorkflowKitValue(workflow, @"identifier"));
            NSString *name = ERWorkflowKitText(ERWorkflowKitValue(workflow, @"name"));
            NSString *symbolName = ERWorkflowKitText(ERWorkflowKitValue(workflow, @"symbolName"));
            NSString *bundleId = ERWorkflowKitText(ERWorkflowKitValue(workflow, @"bundleIdentifier"));

            // attributionIcon 可能是一个 icon 对象，也可能 workflow 自己就实现这个方法。
            id iconObject = ERWorkflowKitValue(workflow, @"attributionIcon");
            UIImage *full = ERWorkflowKitAttributionIcon(workflow, size, YES);
            if (!full && iconObject && iconObject != workflow) {
                full = ERWorkflowKitAttributionIcon(iconObject, size, YES);
            }
            UIImage *foreground = ERWorkflowKitAttributionIcon(workflow, size, NO);
            if (!foreground && iconObject && iconObject != workflow) {
                foreground = ERWorkflowKitAttributionIcon(iconObject, size, NO);
            }
            if (!full && !foreground) {
                for (NSString *key in @[@"icon", @"workflowIcon"]) {
                    id candidate = ERWorkflowKitValue(workflow, key);
                    if (!candidate || candidate == workflow) continue;
                    if (!full) full = ERWorkflowKitAttributionIcon(candidate, size, YES);
                    if (!foreground) foreground = ERWorkflowKitAttributionIcon(candidate, size, NO);
                    if (full || foreground) break;
                }
            }

            NSMutableDictionary *item = [NSMutableDictionary dictionary];
            UIImage *icon = nil;
            BOOL isFull = NO;
            if (full && ERIconImageIsFullTile(full)) {
                icon = full;
                isFull = YES;
            } else if (foreground) {
                icon = foreground;
                isFull = ERIconImageIsFullTile(foreground);
            } else if (full) {
                icon = full;
                isFull = YES;
            }
            if (icon) {
                item[@"icon"] = icon;
                item[@"full"] = @(isFull);
                withIcon++;
                if (isFull) fullTiles++;
                // 落盘一份原图，方便拉回本地直接看 WorkflowKit 到底画了什么。
                ERWriteShortcutIconImage([NSString stringWithFormat:@"wf%lu", (unsigned long)index], icon);
            }
            if (symbolName.length) { item[@"symbolName"] = symbolName; withSymbol++; }
            if (bundleId.length) { item[@"bundleId"] = bundleId; withBundle++; }
            if (name.length) item[@"name"] = name;

            NSString *key = uuid.length ? uuid : (name.length ? name : @"");
            if (key.length) [built setObject:item forKey:key];
            if (index < 8) {
                ERShortcutLog(@"wfkit[%lu] %@ | uuid=%@ | symbol=%@ | bundle=%@ | icon=%d(full=%d)",
                              (unsigned long)index, name ?: @"-", uuid ?: @"-", symbolName ?: @"-",
                              bundleId ?: @"-", icon ? 1 : 0, isFull);
            }
            index++;
        }
        ERShortcutLog(@"wfkit: 图标 %lu/%lu（完整方块 %lu）| symbolName=%lu | bundleId=%lu",
                      (unsigned long)withIcon, (unsigned long)workflows.count,
                      (unsigned long)fullTiles, (unsigned long)withSymbol, (unsigned long)withBundle);
    });
    return table;
}

// ---------------------------------------------------------------------------
// 1.1.8-15 · 图标解析（全插件唯一的一处）
//
// 之前的教训：把「glyph 是几」当成分支条件，就会变成一条快捷指令一个补丁 ——
// 0xF000 打一个、下一条再打一个。这里改成只按**数据本身**分情况，规则通用：
//   ① WorkflowKit 自己渲染的图（最准，它画什么就用什么）
//   ② 用户自定义图片（库里真有 blob 时）
//   ③ 绑定了 App 的快捷指令 → 那个 App 的图标（且必须是「完整圆角方块」，否则换下一个取法）
//   ④ 其余的 → 字形映射出的系统符号，走通用改名候选链
//   ⑤ 还不行 → wand.and.stars
// 解析结果落成一张 PNG（iconPNG 给控制中心、<uuid>.png 给设置页），
// 两个界面只负责画，不再各自解析。
// ---------------------------------------------------------------------------
static NSString *(*ERShortcutGlyphMapper)(unsigned short);

static NSString *ERShortcutSymbolNameForGlyph(unsigned short glyph) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_LAZY);
        if (handle) ERShortcutGlyphMapper = (NSString *(*)(unsigned short))dlsym(handle, "WFSystemImageNameForGlyphCharacter");
    });
    if (!ERShortcutGlyphMapper) return nil;
    @try { return ERShortcutGlyphMapper(glyph); } @catch (__unused NSException *exception) { return nil; }
}

// SF Symbols 会改名（设备 CoreGlyphs 的 name_aliases.strings 里就写着
// square.2.stack.3d -> square.2.layers.3d），而字形表可能还返回旧名字。
// 这里只做**命名规则**层面的候选，不针对任何具体的 glyph 取值。
static NSArray<NSString *> *ERShortcutSymbolCandidates(NSString *mapped) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *name) {
        if (name.length && ![candidates containsObject:name]) [candidates addObject:name];
    };
    if (!mapped.length) return candidates;
    add(mapped);
    if ([mapped rangeOfString:@".stack.3d"].location != NSNotFound) {
        add([mapped stringByReplacingOccurrencesOfString:@".stack.3d" withString:@".layers.3d"]);
    }
    if ([mapped hasPrefix:@"app."]) {
        NSString *tail = [mapped substringFromIndex:4];
        add([@"square." stringByAppendingString:tail]);
        if ([tail rangeOfString:@".stack.3d"].location != NSNotFound) {
            add([@"square." stringByAppendingString:
                 [tail stringByReplacingOccurrencesOfString:@".stack.3d" withString:@".layers.3d"]]);
        }
    }
    return candidates;
}

static UIImage *ERShortcutSymbolImage(NSString *mapped, CGFloat pointSize) {
    for (NSString *name in ERShortcutSymbolCandidates(mapped)) {
        UIImage *image = [UIImage systemImageNamed:name
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                                weight:UIImageSymbolWeightMedium]];
        if (image) return image;
    }
    return nil;
}

// 把符号画成白色前景（透明底）—— 和「快捷指令」App 里符号叠在底色上的效果一致。
static UIImage *ERShortcutForegroundImage(UIImage *symbol, CGSize size) {
    if (!symbol) return nil;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        UIImage *white = [symbol imageWithTintColor:UIColor.whiteColor
                                      renderingMode:UIImageRenderingModeAlwaysOriginal] ?: symbol;
        CGSize original = white.size;
        CGFloat factor = MIN(size.width * 0.62 / MAX(original.width, 1.0),
                             size.height * 0.62 / MAX(original.height, 1.0));
        CGSize drawn = CGSizeMake(original.width * factor, original.height * factor);
        [white drawInRect:CGRectMake((size.width - drawn.width) * 0.5,
                                     (size.height - drawn.height) * 0.5,
                                     drawn.width, drawn.height)];
    }];
}

// 取关联 App 的图标。同一个 bundleId 有好几种取法（format/variant），
// 其中一部分返回的是单色符号版而不是真图标，所以用「完整圆角方块」校验挑出真的那张。
static UIImage *ERAppIconImage(NSString *bundleId) {
    if (!bundleId.length) return nil;
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    UIImage *cached = cache[bundleId];
    if (cached) return (cached == (UIImage *)[NSNull null]) ? nil : cached;

    UIImage *result = nil;
    SEL iconSelector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([[UIImage class] respondsToSelector:iconSelector]) {
        CGFloat scale = [UIScreen mainScreen].scale;
        for (int format = 0; format <= 12 && !result; format++) {
            UIImage *candidate = nil;
            @try {
                candidate = ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)(
                    [UIImage class], iconSelector, bundleId, format, scale);
            } @catch (__unused NSException *exception) {}
            if (candidate && ERIconImageIsFullTile(candidate)) {
                result = candidate;
                ERShortcutLog(@"appicon: %@ format=%d 命中完整图标", bundleId, format);
            }
        }
    }
    if (!result) {
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        SEL variantSelector = NSSelectorFromString(@"iconDataForVariant:");
        @try {
            id proxy = proxyClass
                ? ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, @selector(applicationProxyForIdentifier:), bundleId)
                : nil;
            for (int variant = 0; variant <= 4 && !result && proxy && [proxy respondsToSelector:variantSelector]; variant++) {
                NSData *data = ((NSData *(*)(id, SEL, int))objc_msgSend)(proxy, variantSelector, variant);
                UIImage *candidate = data.length ? [UIImage imageWithData:data] : nil;
                if (candidate && ERIconImageIsFullTile(candidate)) {
                    result = candidate;
                    ERShortcutLog(@"appicon: %@ variant=%d 命中完整图标", bundleId, variant);
                }
            }
        } @catch (__unused NSException *exception) {}
    }
    if (!result) ERShortcutLog(@"appicon: %@ 没有可用的完整图标", bundleId);
    cache[bundleId] = result ?: (UIImage *)[NSNull null];
    return result;
}

static UIImage *ERResolveShortcutIcon(NSString *uuid, NSString *bundleId, NSNumber *glyphNumber,
                                      NSString *symbolName, NSData *customData, BOOL *outFull) {
    CGSize size = CGSizeMake(120.0, 120.0);
    if (outFull) *outFull = YES;

    // ① WorkflowKit 自己渲染的结果（识别到就用它，这是最准的一条）
    NSDictionary *workflowKitIcon = ERWorkflowKitIcons()[uuid];
    UIImage *rendered = workflowKitIcon[@"icon"];
    if ([rendered isKindOfClass:[UIImage class]]) {
        if (outFull) *outFull = [workflowKitIcon[@"full"] boolValue];
        return rendered;
    }

    // ② 用户自己设的图片
    if (customData.length) {
        UIImage *image = [UIImage imageWithData:customData];
        if (image) return image;
    }

    // ③ 绑定了 App 的快捷指令 → 用那个 App 的图标
    UIImage *appIcon = ERAppIconImage(bundleId);
    if (appIcon) return appIcon;

    // ④ 字形 → 系统符号（有关联 App 的已经在 ③ 返回了）
    unsigned short glyphCode = (unsigned short)glyphNumber.unsignedShortValue;
    NSString *mapped = symbolName.length ? symbolName : ERShortcutSymbolNameForGlyph(glyphCode);
    UIImage *symbol = ERShortcutSymbolImage(mapped, 64.0);
    if (symbol) {
        if (outFull) *outFull = NO;
        return ERShortcutForegroundImage(symbol, size);
    }

    // ⑤ 兜底
    if (outFull) *outFull = NO;
    UIImage *fallback = ERShortcutSymbolImage(@"wand.and.stars", 64.0);
    return ERShortcutForegroundImage(fallback ?: [UIImage systemImageNamed:@"sparkles"], size);
}

// 1.1.8-8 · 把设备上这篇数据库复制到日志目录，方便拉回本地用 sqlite 直接看。
static void ERCopyStoreForDiagnostics(NSString *path) {
    if (!path.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *suffix in @[@"", @"-wal", @"-shm"]) {
        NSString *src = [path stringByAppendingString:suffix];
        if (![fm fileExistsAtPath:src]) continue;
        NSString *dst = [kERShortcutSnapshotDirectory
                         stringByAppendingPathComponent:[@"Shortcuts.sqlite" stringByAppendingString:suffix]];
        [fm removeItemAtPath:dst error:nil];
        NSError *error = nil;
        if ([fm copyItemAtPath:src toPath:dst error:&error]) {
            ERShortcutLog(@"dbcopy: ok %@", dst);
        } else {
            ERShortcutLog(@"dbcopy: fail %@ (%@)", suffix, error.localizedDescription);
        }
    }
}

void ERShortcutScanAndPublish(void) {
    if (!ERSQLiteResolve()) {
        ERShortcutLog(@"scan: libsqlite3 could not be resolved");
        return;
    }

    // Locate the store: open each candidate read-only just to test for the
    // ZSHORTCUT table. In the Preferences context these paths ARE reachable,
    // unlike in SpringBoard where the sandbox hid them.
    NSString *databasePath = nil;
    for (NSString *candidate in ERShortcutDatabaseCandidates()) {
        ER_sqlite3 *probe = NULL;
        if (EROpenV2(candidate.fileSystemRepresentation, &probe, 0x00000001, NULL) == 0 && probe) {
            BOOL hasTable = ERSQLiteStoreHasShortcutTable(probe);
            ERClose(probe);
            if (hasTable) { databasePath = candidate; break; }
        }
    }

    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    NSString *status = @"ok";
    NSUInteger rowsSeen = 0, kept = 0, droppedTomb = 0, droppedHidden = 0;
    NSUInteger droppedNoName = 0, droppedNoID = 0, usedFallback = 0;
    NSUInteger fullTiles = 0;

    if (!databasePath) {
        status = @"no-database";
        ERShortcutLog(@"scan: no Shortcuts.sqlite with a ZSHORTCUT table among candidates");
    } else {
        ERShortcutLog(@"scan: using store %@", databasePath);
        ER_sqlite3 *database = EROpenStoreCopy(databasePath);
        if (!database) {
            status = @"query-failed";
            ERShortcutLog(@"scan: failed to open store copy at %@", databasePath);
        } else {
            ERDumpIconSchema(database);
            ER_sqlite3_stmt *statement = NULL;
            if (ERPrepareV2(database, "SELECT * FROM ZSHORTCUT", -1, &statement, NULL) == 0 && statement) {
                while (ERStep(statement) == 100 /* SQLITE_ROW */) {
                    NSString *name = nil;
                    NSString *uuid = nil;
                    NSString *bundleId = nil;
                    long long iconPK = 0;
                    long long pk = 0;
                    BOOL tombstoned = NO;
                    BOOL hidden = NO;
                    int columns = ERColumnCount(statement);
                    for (int index = 0; index < columns; index++) {
                        const char *rawName = ERColumnName(statement, index);
                        if (!rawName) continue;
                        NSString *columnName = [NSString stringWithUTF8String:rawName];
                        NSString *upper = columnName.uppercaseString;
                        int type = ERColumnType(statement, index);
                        BOOL readableAsText = (type != 4 && type != 5);
                        if ([upper isEqualToString:@"ZNAME"] && readableAsText) {
                            const unsigned char *text = ERColumnText(statement, index);
                            if (text && !name.length) name = [NSString stringWithUTF8String:(const char *)text];
                        } else if (!uuid.length && readableAsText &&
                                   ([upper isEqualToString:@"ZWORKFLOWID"] ||
                                    [upper isEqualToString:@"ZIDENTIFIER"] ||
                                    [upper isEqualToString:@"ZUNIQUEIDENTIFIER"] ||
                                    [upper isEqualToString:@"ZUUID"])) {
                            const unsigned char *text = ERColumnText(statement, index);
                            if (text) uuid = [NSString stringWithUTF8String:(const char *)text];
                        } else if ([upper isEqualToString:@"Z_PK"] && type == 1) {
                            pk = ERColumnInt64(statement, index);
                        } else if ([upper isEqualToString:@"ZICON"] && type == 1) {
                            iconPK = ERColumnInt64(statement, index);
                        } else if ([upper isEqualToString:@"ZTOMBSTONED"] && type == 1) {
                            tombstoned = ERColumnInt64(statement, index) != 0;
                        } else if ([upper isEqualToString:@"ZHIDDENFROMLIBRARYANDSYNC"] && type == 1) {
                            hidden = ERColumnInt64(statement, index) != 0;
                        } else if ([upper isEqualToString:@"ZASSOCIATEDAPPBUNDLEIDENTIFIER"] && readableAsText) {
                            // 1.1.8-10 · 来自 App 的快捷指令：glyph 恒为 0xF000
                            // （映射出的 app.2.stack.3d 在 iOS 17.2 上取不到图），
                            // 真图标是关联 App 的图标 —— Actra 也是这么取的。
                            const unsigned char *text = ERColumnText(statement, index);
                            if (text) bundleId = [NSString stringWithUTF8String:(const char *)text];
                        }
                    }
                    rowsSeen++;
                    if (tombstoned) { droppedTomb++; continue; }
                    if (hidden) { droppedHidden++; continue; }
                    if (!name.length) { droppedNoName++; continue; }
                    if (!uuid.length) {
                        if (pk > 0) { uuid = [NSString stringWithFormat:@"pk-%lld", pk]; usedFallback++; }
                        else { droppedNoID++; continue; }
                    }
                    NSMutableDictionary *record = [NSMutableDictionary dictionary];
                    record[@"name"] = name;
                    record[@"uuid"] = uuid;
                    if (bundleId.length) record[@"bundleId"] = bundleId;
                    NSDictionary *icon = ERReadIconRow(database, iconPK);
                    if (icon[@"glyph"]) record[@"glyph"] = icon[@"glyph"];
                    if (icon[@"color"]) record[@"color"] = icon[@"color"];
                    if (icon[@"symbolName"]) record[@"symbolName"] = icon[@"symbolName"];
                    if (icon[@"emoji"]) record[@"emoji"] = icon[@"emoji"];
                    if (icon[@"imageData"]) record[@"imageData"] = icon[@"imageData"];
                    // 1.1.8-15 · 图标只在这里解析一次（全插件唯一的一处），
                    // 控制中心与设置页都只管把结果画出来。
                    BOOL iconFull = YES;
                    UIImage *resolved = ERResolveShortcutIcon(uuid, bundleId, icon[@"glyph"],
                                                              record[@"symbolName"], icon[@"imageData"],
                                                              &iconFull);
                    if (resolved) {
                        // 设置页读文件，控制中心（SpringBoard）读不到文件、只能读 plist，
                        // 所以两种载体都发布同一张图。
                        NSData *png = UIImagePNGRepresentation(resolved);
                        if (png.length) record[@"iconPNG"] = png;
                        record[@"iconFull"] = @(iconFull);
                        NSString *file = ERWriteShortcutIconImage(uuid, resolved);
                        if (file) record[@"iconFile"] = file;
                        if (iconFull) fullTiles++;
                    }
                    [records addObject:record];
                    kept++;
                }
                ERFinalize(statement);
            } else {
                status = @"query-failed";
                ERShortcutLog(@"scan: ZSHORTCUT query failed");
            }
            ERClose(database);
        }
        ERShortcutLog(@"scan: %lu ZSHORTCUT row(s) -> kept %lu (tomb %lu, hidden %lu, no-name %lu, no-id %lu, pk-fallback %lu)",
                       (unsigned long)rowsSeen, (unsigned long)kept, (unsigned long)droppedTomb, (unsigned long)droppedHidden,
                       (unsigned long)droppedNoName, (unsigned long)droppedNoID, (unsigned long)usedFallback);
    }

    [records sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];

    // 1.1.8-8 · 图标来源命中统计（诊断用）：符号名 / emoji / 图片 / 只剩 glyph。
    NSUInteger withSymbol = 0, withEmoji = 0, withImage = 0, glyphOnly = 0, noIcon = 0, withBundle = 0;
    for (NSDictionary *record in records) {
        if (record[@"bundleId"]) withBundle++;
        if (record[@"iconFile"]) withImage++;
        else if (record[@"symbolName"]) withSymbol++;
        else if (record[@"emoji"]) withEmoji++;
        else if ([record[@"glyph"] longLongValue] > 0 &&
                 [record[@"glyph"] longLongValue] != 0xF000) glyphOnly++;
        else noIcon++;
    }
    ERShortcutLog(@"scan: 图标来源 symbol=%lu emoji=%lu image=%lu glyph=%lu none=%lu bundleId=%lu 完整方块=%lu",
                  (unsigned long)withSymbol, (unsigned long)withEmoji, (unsigned long)withImage,
                  (unsigned long)glyphOnly, (unsigned long)noIcon, (unsigned long)withBundle,
                  (unsigned long)fullTiles);
    ERCopyStoreForDiagnostics(databasePath);

    // Publish the FULL catalog (including imageData) to the shared prefs domain
    // so SpringBoard can render native icons without touching the sandboxed store.
    CFPreferencesSetAppValue((__bridge CFStringRef)kERShortcutCatalogKey,
                             (__bridge CFPropertyListRef)[records copy],
                             (__bridge CFStringRef)kERShortcutPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERShortcutPrefsDomain);

    // Publish a names-only snapshot plist for this pane's own display.
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSDictionary *record in records) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"uuid"] = record[@"uuid"];
        entry[@"name"] = [record[@"name"] isKindOfClass:[NSString class]] ? record[@"name"] : record[@"uuid"];
        if ([record[@"color"] isKindOfClass:[NSNumber class]]) entry[@"color"] = record[@"color"];
        if ([record[@"glyph"] isKindOfClass:[NSNumber class]]) entry[@"glyph"] = record[@"glyph"];
        // 1.1.8-8 · 这三样才是 iOS 17 真正的图标来源，快照必须带上。
        if ([record[@"symbolName"] isKindOfClass:[NSString class]]) entry[@"symbolName"] = record[@"symbolName"];
        if ([record[@"emoji"] isKindOfClass:[NSString class]]) entry[@"emoji"] = record[@"emoji"];
        if ([record[@"iconFile"] isKindOfClass:[NSString class]]) entry[@"iconFile"] = record[@"iconFile"];
        // 1.1.8-13 · iconFull=YES 表示这张图本身就是完整的圆角图标（直接满铺），
        // NO 表示只有透明底的前景符号（要画在我们的底色上）。
        if ([record[@"iconFull"] isKindOfClass:[NSNumber class]]) entry[@"iconFull"] = record[@"iconFull"];
        if ([record[@"bundleId"] isKindOfClass:[NSString class]]) entry[@"bundleId"] = record[@"bundleId"];
        [entries addObject:entry];
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"writtenAt"] = [NSDate date];
    payload[@"shortcuts"] = entries;
    payload[@"status"] = status;
    payload[@"databasePath"] = databasePath ?: @"";
    payload[@"rowsSeen"] = @(rowsSeen);
    payload[@"kept"] = @(kept);
    [[NSFileManager defaultManager] createDirectoryAtPath:kERShortcutSnapshotDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [payload writeToFile:[kERShortcutSnapshotDirectory stringByAppendingPathComponent:kERShortcutSnapshotFileName]
               atomically:YES];

    // Wake SpringBoard so it re-reads the catalog from the prefs domain.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kERShortcutRescanNotification,
                                         NULL, NULL, YES);

    ERShortcutLog(@"scan: published %lu shortcut(s) to %@ (status=%@)", (unsigned long)records.count, kERShortcutCatalogKey, status);
}
