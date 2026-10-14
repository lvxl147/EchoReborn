#import "ERShortcutScanner.h"
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <stdarg.h>

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

static NSString *ERWriteShortcutIconFile(NSString *uuid, NSData *data) {
    if (!uuid.length || !data.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = ERShortcutIconDirectory();
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [uuid stringByAppendingPathExtension:@"png"];
    NSString *path = [dir stringByAppendingPathComponent:name];
    // 统一转成 PNG，设置页直接 imageWithContentsOfFile:。
    UIImage *image = [UIImage imageWithData:data];
    NSData *png = image ? UIImagePNGRepresentation(image) : data;
    if ([png writeToFile:path atomically:YES]) return name;
    return nil;
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
                    NSDictionary *icon = ERReadIconRow(database, iconPK);
                    if (icon[@"glyph"]) record[@"glyph"] = icon[@"glyph"];
                    if (icon[@"color"]) record[@"color"] = icon[@"color"];
                    if (icon[@"symbolName"]) record[@"symbolName"] = icon[@"symbolName"];
                    if (icon[@"emoji"]) record[@"emoji"] = icon[@"emoji"];
                    if (icon[@"imageData"]) {
                        record[@"imageData"] = icon[@"imageData"];
                        NSString *file = ERWriteShortcutIconFile(uuid, icon[@"imageData"]);
                        if (file) record[@"iconFile"] = file;
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
    NSUInteger withSymbol = 0, withEmoji = 0, withImage = 0, glyphOnly = 0, noIcon = 0;
    for (NSDictionary *record in records) {
        if (record[@"iconFile"]) withImage++;
        else if (record[@"symbolName"]) withSymbol++;
        else if (record[@"emoji"]) withEmoji++;
        else if ([record[@"glyph"] longLongValue] > 0 &&
                 [record[@"glyph"] longLongValue] != 0xF000) glyphOnly++;
        else noIcon++;
    }
    ERShortcutLog(@"scan: 图标来源 symbol=%lu emoji=%lu image=%lu glyph=%lu none=%lu",
                  (unsigned long)withSymbol, (unsigned long)withEmoji, (unsigned long)withImage,
                  (unsigned long)glyphOnly, (unsigned long)noIcon);
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
