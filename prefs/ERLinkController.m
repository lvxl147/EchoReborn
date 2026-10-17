#import "ERLinkController.h"
#import <UIKit/UIKit.h>
#import <stdarg.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <PhotosUI/PhotosUI.h>

// 与 Tweak.xm / 其余子页保持一致。
static NSString *const kERLinkPrefsDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERLinkCatalogKey = @"LinkCatalog";
static NSString *const kERLinkReloadNotification = @"com.strive.echoreborn/ReloadLinks";
static NSString *const kERLinkSnapshotDirectory = @"/var/mobile/Library/Logs/EchoReborn";
static NSString *const kERLinkSnapshotFileName = @"links.plist";
// 1.1.9-5：App 快捷方式（主屏 Quick Actions）目录由 Tweak.xm 在 SpringBoard 发布。
static NSString *const kERAppShortcutCatalogKey = @"AppShortcutCatalog";
static NSString *const kERAppShortcutRequestNotification = @"com.strive.echoreborn/RequestAppShortcuts";
// 1.1.9-8：桌面上显示的 App 集合（SpringBoard 发布），用来过滤系统隐藏组件。
static NSString *const kERHomeScreenAppsKey = @"HomeScreenApps";

// ---------------------------------------------------------------------------
// 日志。句柄复用：一次扫描/一次保存要写几十条，别每条都开合一次文件。
// ---------------------------------------------------------------------------
static void ERLinkLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [PREFS-LINK] %@\n", [NSDate date].description, message];
    [[NSFileManager defaultManager] createDirectoryAtPath:kERLinkSnapshotDirectory
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [kERLinkSnapshotDirectory stringByAppendingPathComponent:@"echoreborn.log"];
    static NSFileHandle *handle = nil;
    if (!handle) handle = [NSFileHandle fileHandleForWritingAtPath:path];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *exception) {
        @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            @try {
                [handle seekToEndOfFile];
                [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            } @catch (__unused NSException *alsoIgnored) {}
        }
    }
}

// 数据库颜色是 0xRRGGBBAA 的无符号 32 位，读成 long long 后高位为负。
// 与快捷指令同一套解码（1.1.8-9 修过的）。
static UIColor *ERLinkColorFromValue(long long value) {
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

static NSString *ERLinkIconDirectory(void) {
    return [kERLinkSnapshotDirectory stringByAppendingPathComponent:@"link-icons"];
}

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
        size_t centerIndex = ((height / 2) * width + (width / 2)) * 4 + 3;
        BOOL centerOpaque = buffer[centerIndex] > 32;
        size_t edgeSamples[4] = {
            (inset * width + (width / 2)) * 4 + 3,
            ((height - 1 - inset) * width + (width / 2)) * 4 + 3,
            ((height / 2) * width + inset) * 4 + 3,
            ((height / 2) * width + (width - 1 - inset)) * 4 + 3
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

// ---------------------------------------------------------------------------
// 目录读写
// ---------------------------------------------------------------------------
static NSString *ERLinkSnapshotPath(void) {
    return [kERLinkSnapshotDirectory stringByAppendingPathComponent:kERLinkSnapshotFileName];
}

static NSArray<NSDictionary *> *ERLinkStoredCatalog(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)kERLinkCatalogKey,
                                                        (__bridge CFStringRef)kERLinkPrefsDomain);
    NSArray *result = nil;
    if (value) {
        if (CFGetTypeID(value) == CFArrayGetTypeID()) result = [(__bridge NSArray *)value copy];
        CFRelease(value);
    }
    return result ?: @[];
}

static void ERLinkPersistCatalog(NSArray<NSDictionary *> *catalog) {
    CFPreferencesSetAppValue((__bridge CFStringRef)kERLinkCatalogKey,
                             (__bridge CFPropertyListRef)[catalog copy],
                             (__bridge CFStringRef)kERLinkPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERLinkPrefsDomain);
    // 同时落一份快照，供本页自己读（和快捷指令的分工一样）。
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"writtenAt"] = [NSDate date];
    payload[@"links"] = catalog;
    [payload writeToFile:ERLinkSnapshotPath() atomically:YES];
    // 唤醒 SpringBoard 重建目录。
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kERLinkReloadNotification,
                                         NULL, NULL, YES);
    // 1.1.9-62：槽位磁贴 bundle 只监听 ReloadPrefs —— 改名/改图标后让它立即重绘。
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.strive.echoreborn/ReloadPrefs"),
                                         NULL, NULL, YES);
    ERLinkLog(@"catalog: 保存 %lu 条快捷方式", (unsigned long)catalog.count);
}

static NSArray<NSDictionary *> *ERLinkCatalogForDisplay(void) {
    NSDictionary *payload = [NSDictionary dictionaryWithContentsOfFile:ERLinkSnapshotPath()];
    NSArray *links = payload[@"links"];
    if ([links isKindOfClass:[NSArray class]] && links.count) return links;
    return ERLinkStoredCatalog();
}

// ---------------------------------------------------------------------------
// 图标解析（设置页用；磁贴那张 120×120 的 PNG 也在这里一并渲染落盘，
// 控制中心直接读文件，不用再解析一遍）
// ---------------------------------------------------------------------------
static UIImage *ERLinkAppIconImage(NSString *bundleId) {
    if (!bundleId.length) return nil;
    SEL iconSelector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![[UIImage class] respondsToSelector:iconSelector]) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    for (int format = 0; format <= 12; format++) {
        UIImage *candidate = nil;
        @try {
            candidate = ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)(
                [UIImage class], iconSelector, bundleId, format, scale);
        } @catch (__unused NSException *exception) {}
        if (candidate && ERIconImageIsFullTile(candidate)) return candidate;
    }
    return nil;
}

static NSString *ERLinkLocalImagePath(NSString *fileName) {
    if (!fileName.length) return nil;
    return [ERLinkIconDirectory() stringByAppendingPathComponent:fileName];
}

// 返回 @{@"image": UIImage, @"full": @(BOOL)}；full=YES 表示本身就是完整圆角图标。
static NSDictionary *ERLinkResolveIcon(NSDictionary *entry) {
    NSString *kind = entry[@"iconKind"];
    NSString *value = entry[@"iconValue"];
    UIImage *image = nil;
    BOOL full = NO;

    // 1.1.9-62：自定义页设置的图标覆盖（symbolOverride）优先 —— 子页面与磁贴两处同步。
    NSString *overrideSymbol = [entry[@"symbolOverride"] isKindOfClass:[NSString class]] ? entry[@"symbolOverride"] : @"";
    if (overrideSymbol.length) image = [UIImage systemImageNamed:overrideSymbol];

    if (!image && [kind isEqualToString:@"app"]) {
        image = ERLinkAppIconImage(value);
        if (image) full = YES;
    } else if ([kind isEqualToString:@"image"]) {
        if ([value hasPrefix:@"http://"] || [value hasPrefix:@"https://"]) {
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:value]];
            image = data.length ? [UIImage imageWithData:data] : nil;
        } else {
            image = [UIImage imageWithContentsOfFile:ERLinkLocalImagePath(value)];
        }
        if (image) full = YES;
    } else if ([kind isEqualToString:@"symbol"]) {
        image = [UIImage systemImageNamed:value.length ? value : @"link"];
    }
    if (!image) {
        // 兜底：link 符号（前景，透明底）
        image = [UIImage systemImageNamed:@"link"] ?: [UIImage systemImageNamed:@"sparkles"];
    }
    if (!image) return nil;
    if (!full) {
        // 前景符号画成白色，和快捷指令磁贴同一套观感。
        image = [image imageWithTintColor:UIColor.whiteColor
                            renderingMode:UIImageRenderingModeAlwaysOriginal] ?: image;
    }
    return @{@"image": image, @"full": @(full)};
}

// 渲染 120×120 的成品图并落盘，返回文件名（供 Tweak.xm 与设置页共用）。
static NSString *ERLinkWriteRenderedIcon(NSDictionary *entry) {
    NSDictionary *resolved = ERLinkResolveIcon(entry);
    UIImage *image = resolved[@"image"];
    if (!image) return nil;
    BOOL full = [resolved[@"full"] boolValue];
    CGSize size = CGSizeMake(120.0, 120.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        if (full) {
            [image drawInRect:CGRectInset(CGRectMake(0.0, 0.0, size.width, size.height), 0.0, 0.0)];
        } else {
            // 前景符号按墨迹放到 69%/76%，和设置页一致。
            CGRect ink = ERInkBoundsOfImage(image);
            if (CGRectIsNull(ink)) ink = CGRectMake(0.0, 0.0, 1.0, 1.0);
            CGFloat inkW = MAX(ink.size.width * image.size.width, 0.001);
            CGFloat inkH = MAX(ink.size.height * image.size.height, 0.001);
            CGFloat factor = MIN((size.width * 0.69) / inkW, (size.height * 0.76) / inkH);
            CGSize drawn = CGSizeMake(image.size.width * factor, image.size.height * factor);
            [image drawInRect:CGRectMake((size.width - drawn.width) * 0.5,
                                         (size.height - drawn.height) * 0.5,
                                         drawn.width, drawn.height)];
        }
    }];
    NSString *uuid = entry[@"uuid"];
    if (!uuid.length || !rendered) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:ERLinkIconDirectory() withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [uuid stringByAppendingPathExtension:@"png"];
    NSData *png = UIImagePNGRepresentation(rendered);
    if (png.length && [png writeToFile:ERLinkLocalImagePath(name) atomically:YES]) return name;
    return nil;
}

// 设置页行图标（40×40）。
static UIImage *ERLinkCellIcon(NSDictionary *entry) {
    UIColor *background = ERLinkColorFromValue([entry[@"color"] longLongValue]);
    NSString *iconFile = entry[@"iconFile"];
    UIImage *rendered = iconFile.length ? [UIImage imageWithContentsOfFile:ERLinkLocalImagePath(iconFile)] : nil;
    BOOL full = [entry[@"iconFull"] isKindOfClass:[NSNumber class]] ? [entry[@"iconFull"] boolValue] : NO;
    if (!rendered) {
        NSDictionary *resolved = ERLinkResolveIcon(entry);
        rendered = resolved[@"image"];
        full = [resolved[@"full"] boolValue];
    }
    CGSize size = CGSizeMake(40.0, 40.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0.0, 0.0, size.width, size.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 1.0, 1.0) cornerRadius:9.0];
        [(background ?: [UIColor colorWithRed:0.11 green:0.60 blue:0.97 alpha:1.0]) setFill];
        [path fill];
        if (rendered) {
            if (full) {
                [path addClip];
                [rendered drawInRect:CGRectInset(rect, 1.0, 1.0)];
            } else {
                CGRect inner = CGRectInset(rect, 1.0, 1.0);
                CGRect ink = ERInkBoundsForKey(iconFile.length ? iconFile : @"fg", rendered);
                CGFloat inkW = MAX(ink.size.width * rendered.size.width, 0.001);
                CGFloat inkH = MAX(ink.size.height * rendered.size.height, 0.001);
                CGFloat factor = MIN((inner.size.width * 0.69) / inkW,
                                     (inner.size.height * 0.76) / inkH);
                CGSize drawn = CGSizeMake(rendered.size.width * factor, rendered.size.height * factor);
                [rendered drawInRect:CGRectMake(CGRectGetMidX(inner) - drawn.width / 2.0,
                                                CGRectGetMidY(inner) - drawn.height / 2.0,
                                                drawn.width, drawn.height)];
            }
        }
    }];
}

// ---------------------------------------------------------------------------
// 已安装 App 列表（参考 Actra：LSApplicationWorkspace + allInstalledApplications）
// ---------------------------------------------------------------------------
static NSArray<NSDictionary *> *ERLinkInstalledApps(void) {
    static NSArray<NSDictionary *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
        @try {
            dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            if (!workspaceClass) { ERLinkLog(@"apps: LSApplicationWorkspace 不可用"); return; }
            id workspace = nil;
            SEL defaultSelector = @selector(defaultWorkspace);
            if ([workspaceClass respondsToSelector:defaultSelector]) {
                workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector);
            }
            if (!workspace) workspace = workspaceClass;
            NSArray *apps = nil;
            // 不同 iOS 上方法名有差异，逐个试，命中哪个用哪个。
            for (NSString *name in @[@"allInstalledApplications", @"allApplications", @"installedApplications"]) {
                SEL selector = NSSelectorFromString(name);
                if (![workspace respondsToSelector:selector]) continue;
                id candidate = ((id (*)(id, SEL))objc_msgSend)(workspace, selector);
                if ([candidate isKindOfClass:[NSArray class]] && [(NSArray *)candidate count] > 0) {
                    apps = (NSArray *)candidate;
                    ERLinkLog(@"apps: 用 +%@ 取到 %lu 个", name, (unsigned long)apps.count);
                    break;
                }
            }
            if (!apps) { ERLinkLog(@"apps: 取不到已安装应用列表"); return; }
            for (id proxy in apps) {
                NSString *bundleId = nil;
                NSString *name = nil;
                @try {
                    id identifier = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(applicationIdentifier));
                    if ([identifier isKindOfClass:[NSString class]]) bundleId = (NSString *)identifier;
                } @catch (__unused NSException *exception) {}
                @try {
                    id localized = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName));
                    if ([localized isKindOfClass:[NSString class]]) name = (NSString *)localized;
                } @catch (__unused NSException *exception) {}
                if (!bundleId.length) continue;
                if (!name.length) name = bundleId;
                [result addObject:@{@"bundleId": bundleId, @"name": name}];
            }
        } @catch (NSException *exception) {
            ERLinkLog(@"apps: 异常 %@", exception.reason);
        }
        [result sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
        }];
        cache = result;
    });
    return cache;
}

// 把 UIImage 存成 PNG 落进 link-icons/，返回文件名。
static NSString *ERLinkImportImageFromImage(UIImage *image) {
    if (![image isKindOfClass:[UIImage class]]) return nil;
    NSData *png = UIImagePNGRepresentation(image);
    if (!png.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:ERLinkIconDirectory() withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [[[NSUUID UUID] UUIDString] stringByAppendingPathExtension:@"png"];
    if ([png writeToFile:ERLinkLocalImagePath(name) atomically:YES]) {
        ERLinkLog(@"icon: 导入本地图片 %@", name);
        return name;
    }
    return nil;
}
// 把外部 URL 的图片拷进 link-icons/（带 security-scope 处理），返回文件名。
static NSString *ERLinkImportImageFromURL(NSURL *url) {
    if (!url) return nil;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
    return ERLinkImportImageFromImage(image);
}


// 画一个「彩色圆角底 + 白色符号」的 40×40 小磁贴（创建链接行、取不到 App 图标时的兜底）。
static UIImage *ERLinkGlyphTile(NSString *symbolName, long long colorValue) {
    CGSize size = CGSizeMake(40.0, 40.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0.0, 0.0, size.width, size.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 1.0, 1.0) cornerRadius:9.0];
        UIColor *background = ERLinkColorFromValue(colorValue) ?: [UIColor colorWithRed:0.11 green:0.60 blue:0.97 alpha:1.0];
        [background setFill];
        [path fill];
        UIImage *symbol = [UIImage systemImageNamed:symbolName
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24.0
                                                                                                weight:UIImageSymbolWeightMedium]];
        if (symbol) {
            UIImage *white = [symbol imageWithTintColor:UIColor.whiteColor
                                          renderingMode:UIImageRenderingModeAlwaysOriginal] ?: symbol;
            [white drawInRect:CGRectInset(rect, 10.0, 10.0)];
        }
    }];
}

// App 图标画进 size×size 圆角（添加页 40，详情页按需缩小）。
static UIImage *ERLinkAppCellIcon(NSString *bundleId, CGFloat side) {
    UIImage *appIcon = ERLinkAppIconImage(bundleId);
    if (!appIcon) return ERLinkGlyphTile(@"app.fill", 0xFF3B82F6LL);
    CGSize size = CGSizeMake(side, side);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.0, 0.0, size.width, size.height)
                                                        cornerRadius:side * 0.225];
        [path addClip];
        [appIcon drawInRect:CGRectMake(0.0, 0.0, size.width, size.height)];
    }];
}

// 以一条 App 快捷方式（主屏 Quick Action）造目录条目。
static NSDictionary *ERLinkMakeAppShortcutEntry(NSString *bundleId, NSString *appName,
                                                NSString *shortcutType, NSString *title) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"uuid"] = [[NSUUID UUID] UUIDString];
    entry[@"name"] = title.length ? title : shortcutType;
    entry[@"type"] = @"appShortcut";
    entry[@"bundleId"] = bundleId ?: @"";
    entry[@"appBundleName"] = appName ?: @"";
    entry[@"shortcutType"] = shortcutType ?: @"";
    entry[@"iconKind"] = @"app";
    entry[@"iconValue"] = bundleId ?: @"";
    entry[@"color"] = @(0xFF3B82F6LL);
    NSString *file = ERLinkWriteRenderedIcon(entry);
    if (file) {
        entry[@"iconFile"] = file;
        entry[@"iconFull"] = @YES;
    }
    return entry;
}

// 请求 SpringBoard 刷新 App 快捷方式目录（发完 Darwin 通知即可，结果下次读到）。
static void ERLinkRequestAppShortcutCatalog(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kERAppShortcutRequestNotification,
                                         NULL, NULL, YES);
}

// 桌面上显示的 App 集合（SpringBoard 发布；取不到就返回空 → 设置页不过滤）。
static NSSet<NSString *> *ERLinkHomeScreenApps(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERLinkPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)kERHomeScreenAppsKey,
                                                        (__bridge CFStringRef)kERLinkPrefsDomain);
    if (!value) return [NSSet set];
    NSMutableSet<NSString *> *result = [NSMutableSet set];
    if (CFGetTypeID(value) == CFArrayGetTypeID()) {
        for (NSString *bid in (__bridge NSArray *)value) {
            if ([bid isKindOfClass:[NSString class]] && bid.length) [result addObject:bid];
        }
    }
    CFRelease(value);
    return result;
}

// 快照里带快捷方式的应用集合（用来把添加页拆成两张卡片）。
static NSSet<NSString *> *ERLinkAppsWithShortcuts(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERLinkPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)kERAppShortcutCatalogKey,
                                                        (__bridge CFStringRef)kERLinkPrefsDomain);
    if (!value) return [NSSet set];
    NSMutableSet<NSString *> *result = [NSMutableSet set];
    if (CFGetTypeID(value) == CFDictionaryGetTypeID()) {
        for (NSString *bid in (__bridge NSDictionary *)value) {
            if ([bid isKindOfClass:[NSString class]] && bid.length) [result addObject:bid];
        }
    }
    CFRelease(value);
    return result;
}

// 以 App 维度造一条「打开 App」的快捷方式条目（详情页头部点击时用）。
static NSDictionary *ERLinkMakeAppEntry(NSString *bundleId, NSString *name) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"uuid"] = [[NSUUID UUID] UUIDString];
    entry[@"name"] = name.length ? name : bundleId;
    entry[@"type"] = @"app";
    entry[@"bundleId"] = bundleId ?: @"";
    entry[@"iconKind"] = @"app";
    entry[@"iconValue"] = bundleId ?: @"";
    entry[@"color"] = @(0xFF3B82F6LL);
    NSString *file = ERLinkWriteRenderedIcon(entry);
    if (file) {
        entry[@"iconFile"] = file;
        entry[@"iconFull"] = @YES;
    }
    return entry;
}

// 1.1.9-62：条目类型的中文名（自定义页「类型」行只读显示）。
static NSString *ERLinkTypeDisplay(NSDictionary *entry) {
    NSString *type = [entry[@"type"] isKindOfClass:[NSString class]] ? entry[@"type"] : @"";
    if ([type isEqualToString:@"app"]) return @"打开应用";
    if ([type isEqualToString:@"appShortcut"]) return @"App 快捷方式";
    if ([type isEqualToString:@"link"]) return @"链接";
    return type.length ? type : @"未知";
}

// 1.1.9-62：用新条目的目标字段替换旧条目。保留旧条目的 uuid（槽位绑定不变，
// 控制中心磁贴原位换目标）、用户改过的名称与图标覆盖（symbolOverride）。
// freshEntry 来自添加流程的 ERLinkMakeApp* 工厂（带新 uuid，丢弃即可）。
static BOOL ERLinkReplaceEntry(NSString *uuid, NSDictionary *freshEntry) {
    if (![uuid isKindOfClass:[NSString class]] || !uuid.length) return NO;
    if (![freshEntry isKindOfClass:[NSDictionary class]]) return NO;
    NSMutableArray<NSDictionary *> *catalog = [ERLinkStoredCatalog() mutableCopy] ?: [NSMutableArray array];
    BOOL found = NO;
    for (NSUInteger index = 0; index < catalog.count; index++) {
        NSDictionary *entry = catalog[index];
        if (![entry[@"uuid"] isKindOfClass:[NSString class]] ||
            ![entry[@"uuid"] isEqualToString:uuid]) continue;
        found = YES;
        NSMutableDictionary *updated = [freshEntry mutableCopy] ?: [NSMutableDictionary dictionary];
        updated[@"uuid"] = uuid;                                   // 槽位绑定保持
        NSString *oldName = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"";
        if (oldName.length) updated[@"name"] = oldName;            // 名称保留用户改过的
        NSString *oldOverride = [entry[@"symbolOverride"] isKindOfClass:[NSString class]] ? entry[@"symbolOverride"] : @"";
        if (oldOverride.length) updated[@"symbolOverride"] = oldOverride;  // 图标覆盖保留
        // 重渲染图标（目标变了，App 图标剪影要跟着换）。
        updated[@"iconKind"] = freshEntry[@"iconKind"] ?: @"app";
        updated[@"iconValue"] = freshEntry[@"iconValue"] ?: @"";
        NSString *file = ERLinkWriteRenderedIcon(updated);
        if (file) {
            updated[@"iconFile"] = file;
            updated[@"iconFull"] = @([ERLinkResolveIcon(updated)[@"full"] boolValue]);
        }
        catalog[index] = updated;
        break;
    }
    if (found) ERLinkPersistCatalog(catalog);
    return found;
}

// 1.1.9-62：替换完成后优先弹回自定义页（导航栈里有就回到那里）。
static void ERLinkPopBackToCustomize(UIViewController *from) {
    NSArray<UIViewController *> *stack = from.navigationController.viewControllers;
    for (UIViewController *controller in stack) {
        if ([controller isKindOfClass:NSClassFromString(@"ERLinkCustomizeController")]) {
            [from.navigationController popToViewController:controller animated:YES];
            return;
        }
    }
    [from.navigationController popToRootViewControllerAnimated:YES];
}
// 取一个 App 的快捷方式列表（@{type,title}）：
// ① SpringBoard 发布的快照（静态+动态，最全）；② 兜底读 App Info.plist 的静态项。
static NSArray<NSDictionary *> *ERLinkAppShortcutsForBundle(NSString *bundleId) {
    if (!bundleId.length) return @[];
    // ① SpringBoard 快照（先强刷一次，别读到 cfprefsd 的旧缓存）
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERLinkPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)kERAppShortcutCatalogKey,
                                                        (__bridge CFStringRef)kERLinkPrefsDomain);
    if (value) {
        if (CFGetTypeID(value) == CFDictionaryGetTypeID()) {
            NSDictionary *catalog = (__bridge NSDictionary *)value;
            NSDictionary *record = catalog[bundleId];
            NSArray *items = [record isKindOfClass:[NSDictionary class]] ? record[@"items"] : nil;
            if ([items isKindOfClass:[NSArray class]] && items.count) {
                NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
                for (NSDictionary *item in items) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : nil;
                    NSString *title = [item[@"title"] isKindOfClass:[NSString class]] ? item[@"title"] : nil;
                    if (!type.length) continue;
                    [result addObject:@{@"type": type,
                                        @"title": title.length ? title : type}];
                }
                if (result.count) {
                    ERLinkLog(@"appShortcuts: %@ 快照命中 %lu 条", bundleId, (unsigned long)result.count);
                    CFRelease(value);
                    return result;
                }
            }
        }
        CFRelease(value);
        ERLinkLog(@"appShortcuts: %@ 快照无记录，走静态兜底", bundleId);
    } else {
        ERLinkLog(@"appShortcuts: %@ 快照缺失（SpringBoard 尚未发布？），走静态兜底", bundleId);
    }
    // ② 静态兜底：LSApplicationProxy → Info.plist UIApplicationShortcutItems
    @try {
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (!proxyClass || ![(id)proxyClass respondsToSelector:proxySel]) return @[];
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, proxySel, bundleId);
        if (!proxy) return @[];
        SEL infoSel = NSSelectorFromString(@"infoDictionary");
        if (![proxy respondsToSelector:infoSel]) return @[];
        NSDictionary *info = ((id (*)(id, SEL))objc_msgSend)(proxy, infoSel);
        NSArray *raw = info[@"UIApplicationShortcutItems"];
        if (![raw isKindOfClass:[NSArray class]]) {
            ERLinkLog(@"appShortcuts: %@ Info.plist 无静态 Quick Actions", bundleId);
            return @[];
        }
        NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
        for (NSDictionary *item in raw) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *type = [item[@"UIApplicationShortcutItemType"] isKindOfClass:[NSString class]]
                ? item[@"UIApplicationShortcutItemType"] : nil;
            if (!type.length) continue;
            NSString *title = [item[@"UIApplicationShortcutItemTitle"] isKindOfClass:[NSString class]]
                ? item[@"UIApplicationShortcutItemTitle"] : nil;
            [result addObject:@{@"type": type, @"title": title.length ? title : type}];
        }
        ERLinkLog(@"appShortcuts: %@ 静态兜底 %lu 条", bundleId, (unsigned long)result.count);
        return result;
    } @catch (__unused NSException *exception) {
        ERLinkLog(@"appShortcuts: 静态兜底异常 %@", exception.reason);
        return @[];
    }
}

// MARK: - 主页

@interface ERLinkAddController : PSViewController <UITableViewDataSource,
                                                    UITableViewDelegate,
                                                    UISearchBarDelegate,
                                                    UIDocumentPickerDelegate,
                                                    PHPickerViewControllerDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *existing;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *apps;
// 1.1.9-8：有快捷方式的 / 没有快捷方式的，两张卡片分开显示。
@property (nonatomic, strong) NSArray<NSDictionary *> *withShortcuts;
@property (nonatomic, strong) NSArray<NSDictionary *> *withoutShortcuts;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *addTableView;
// 「添加链接」弹窗里正在编辑的那一份（从文件/相册导入图标时要用）
@property (nonatomic, strong) UIAlertController *pendingAlert;
@property (nonatomic, copy) NSString *pendingIconFile;
// 1.1.9-62：替换模式 —— 非空时选中目标不新增条目，而是原位替换该 uuid 的条目。
@property (nonatomic, copy) NSString *replaceUUID;
- (instancetype)initWithExisting:(NSArray<NSDictionary *> *)existing;
@end

// App 详情页：顶部第一行是 App 卡片（左图标 + 右名称），
// 与该 App 的真实快捷方式（主屏 Quick Actions）共用一张卡片；
// 条目可点击打对号/取消对号。
@interface ERLinkAppDetailController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *appBundleId;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, strong) NSArray<NSDictionary *> *shortcutItems;
// 1.1.9-62：替换模式（由添加页透传）—— 点条目不新增，而是替换该 uuid 的条目。
@property (nonatomic, copy) NSString *replaceUUID;
- (instancetype)initWithAppBundleId:(NSString *)bundleId name:(NSString *)name;
@end

// 1.1.9-62：自定义快捷方式页（点主列表某行进入；实现在本文件末尾）。
// 卡片1：第1行 类型（只读）｜第2行 名称（改名，两处同步）｜
//        第3行 图标（输入框 + 选择按钮，symbolOverride 两处同步）｜
//        第4行 选择快捷方式（替换按钮 → 复用添加流程原位换目标）。
// 卡片2：删除快捷方式（红色，确认后连子页面与控制中心一起清）。
@protocol ERLinkIconPickerDelegate;
// 1.1.9-65：keyboardX 风格 —— 根页面=分类列表（图标库），点分类进入网格；顶部导航栏搜索。
@interface ERLinkIconPickerController : PSViewController <UITableViewDataSource, UITableViewDelegate, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, UISearchResultsUpdating>
@property (nonatomic, weak) id<ERLinkIconPickerDelegate> pickerDelegate;
@property (nonatomic, copy) NSString *selectedSymbol; // 进入时高亮当前图标
@property (nonatomic, copy) NSArray *categoryNames; // 非空 = 网格模式（该分类的符号名）
@property (nonatomic, copy) NSString *categoryTitle;                // 网格模式标题
@end
@protocol ERLinkIconPickerDelegate <NSObject>
- (void)iconPickerDidPickSymbol:(NSString *)symbolName;
@end
@interface ERLinkCustomizeController : PSViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, ERLinkIconPickerDelegate>
- (instancetype)initWithUUID:(NSString *)uuid;
@end

@interface ERLinkController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *linkTableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *links;
@end

@implementation ERLinkController

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 480.0)];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    [self.view addSubview:table];
    self.linkTableView = table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"快捷动作";
    [self reloadLinks];

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithTitle:@"添加"
                                                            style:UIBarButtonItemStylePlain
                                                           target:self
                                                           action:@selector(addLink:)];
    self.navigationItem.rightBarButtonItem = add;
    ERLinkLog(@"linkPane: viewDidLoad done");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLinks];
}

- (void)reloadLinks {
    self.links = ERLinkCatalogForDisplay();
    [self.linkTableView reloadData];
}

- (void)addLink:(__unused UIBarButtonItem *)sender {
    ERLinkAddController *controller = [[ERLinkAddController alloc] initWithExisting:self.links];
    controller.title = @"添加";
    [self.navigationController pushViewController:controller animated:YES];
}

// MARK: - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return self.links.count ? (NSInteger)self.links.count : 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return [NSString stringWithFormat:@"快捷方式（%lu）", (unsigned long)self.links.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ERLinkCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    if (self.links.count == 0) {
        // 空状态：引导去点右上角的「添加」——那个按钮在主页上，所以这句话也只能放主页。
        cell.textLabel.text = @"点击右上角添加快捷方式";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = YES;
        return cell;
    }
    cell.userInteractionEnabled = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    NSDictionary *entry = self.links[indexPath.row];
    cell.textLabel.text = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"快捷方式";
    cell.textLabel.textColor = UIColor.labelColor;
    cell.imageView.image = ERLinkCellIcon(entry);
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.clipsToBounds = YES;
    NSString *detail = [entry[@"type"] isEqualToString:@"app"] || [entry[@"type"] isEqualToString:@"appShortcut"]
        ? entry[@"bundleId"] : entry[@"url"];
    if (![detail isKindOfClass:[NSString class]] || !detail.length) detail = @"";
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = UIColor.labelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

// 左滑删除（快捷指令那边是「移出显示列表」，这边直接删掉条目本身）。
- (BOOL)tableView:(__unused UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.links.count > 0 && indexPath.row < (NSInteger)self.links.count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row >= (NSInteger)self.links.count) return;
    NSMutableArray<NSDictionary *> *remaining = [self.links mutableCopy];
    NSString *uuid = self.links[indexPath.row][@"uuid"];
    [remaining removeObjectAtIndex:indexPath.row];
    ERLinkPersistCatalog(remaining);
    self.links = remaining;
    [tableView reloadData];
    // 顺手把渲染好的图标文件删掉，别在日志目录里堆垃圾。
    if ([uuid isKindOfClass:[NSString class]] && uuid.length) {
        [[NSFileManager defaultManager] removeItemAtPath:ERLinkLocalImagePath([uuid stringByAppendingPathExtension:@"png"])
                                                   error:nil];
    }
    ERLinkLog(@"linkPane: 删除 %@", uuid ?: @"-");
}

- (void)tableView:(__unused UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // 1.1.9-62：点击某条快捷方式 → 进入自定义页。
    if (indexPath.row >= (NSInteger)self.links.count) return;
    NSDictionary *entry = self.links[indexPath.row];
    NSString *uuid = [entry[@"uuid"] isKindOfClass:[NSString class]] ? entry[@"uuid"] : @"";
    if (!uuid.length) return;
    ERLinkCustomizeController *controller = [[ERLinkCustomizeController alloc] initWithUUID:uuid];
    NSString *name = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"";
    controller.title = name.length ? name : @"自定义快捷方式";
    [self.navigationController pushViewController:controller animated:YES];
}

@end

// MARK: - 添加子页面


@implementation ERLinkAddController

- (instancetype)initWithExisting:(NSArray<NSDictionary *> *)existing {
    self = [super init];
    if (!self) return nil;
    _existing = existing ?: @[];
    _searchText = @"";
    _apps = [NSMutableArray array];
    return self;
}

- (void)loadView {
    CGRect frame = CGRectMake(0.0, 0.0, 320.0, 480.0);
    self.view = [[UIView alloc] initWithFrame:frame];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 搜索框作为表格的 tableHeaderView：表格自己的内容 inset 系统已经算好
    // （主页正是这么正常显示的），表头视图天然落在导航栏下面。
    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;

    UISearchBar *bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0.0, 0.0, frame.size.width, 56.0)];
    bar.delegate = self;
    bar.placeholder = @"搜索 App";
    bar.searchBarStyle = UISearchBarStyleMinimal;
    bar.translucent = YES;
    bar.backgroundImage = [UIImage new];
    [bar setSearchFieldBackgroundImage:[UIImage new] forState:UIControlStateNormal];
    bar.showsCancelButton = NO;
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
    self.searchBar.showsCancelButton = NO;
    [self refilter];

    // App 列表可能有一两百个，异步取，避免打开页面卡一下。
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = ERLinkInstalledApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.apps = [apps mutableCopy] ?: [NSMutableArray array];
            [strongSelf refilter];
            [strongSelf.addTableView reloadData];
        });
    });
}

- (void)refilter {
    NSString *needle = self.searchText.lowercaseString;
    // 桌面上没有的（电视提供商、用户认证等系统组件）不显示；集合为空则不过滤。
    NSSet<NSString *> *homeApps = ERLinkHomeScreenApps();
    // 目录里有快捷方式的拆到第一张卡。
    NSSet<NSString *> *hasShortcuts = ERLinkAppsWithShortcuts();
    NSMutableArray<NSDictionary *> *withList = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *withoutList = [NSMutableArray array];
    for (NSDictionary *app in self.apps) {
        NSString *bundleId = app[@"bundleId"];
        NSString *name = app[@"name"];
        if (![bundleId isKindOfClass:[NSString class]] || !bundleId.length) continue;
        if (homeApps.count && ![homeApps containsObject:bundleId]) continue;
        if (needle.length) {
            BOOL matched = ([name isKindOfClass:[NSString class]] && [name.lowercaseString containsString:needle]);
            if (!matched && [bundleId.lowercaseString containsString:needle]) matched = YES;
            if (!matched) continue;
        }
        if ([hasShortcuts containsObject:bundleId]) {
            [withList addObject:app];
        } else {
            [withoutList addObject:app];
        }
    }
    // 卡片内按名称 A→Z。
    [withList sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
    [withoutList sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
    self.withShortcuts = withList;
    self.withoutShortcuts = withoutList;
}

// MARK: - 保存一条快捷方式

- (void)saveEntry:(NSDictionary *)entry {
    if (self.replaceUUID.length) {
        // 1.1.9-62：替换模式 —— 原位换目标（uuid/name/symbolOverride 保留），回到发起替换的页面。
        ERLinkReplaceEntry(self.replaceUUID, entry);
        ERLinkPopBackToCustomize(self);
        return;
    }
    NSMutableArray<NSDictionary *> *catalog = [ERLinkStoredCatalog() mutableCopy];
    if (!catalog) catalog = [NSMutableArray array];
    [catalog addObject:entry];
    ERLinkPersistCatalog(catalog);
    [self.navigationController popViewControllerAnimated:YES];
}

// MARK: - 「创建链接」弹窗

- (void)presentCreateLink {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加链接"
                                                                   message:@"链接支持网址和 URL Scheme (格式如 app://path)。图标支持 SF 符号、应用标识符、图片链接或本地导入。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"名称";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"图标（选填）";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"网址或 URL Scheme";
        field.keyboardType = UIKeyboardTypeURL;
    }];
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"保存"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        UITextField *nameField = alert.textFields.firstObject;
        UITextField *iconField = alert.textFields[1];
        UITextField *urlField = alert.textFields.lastObject;
        NSString *name = nameField.text.length ? nameField.text : urlField.text;
        NSString *url = urlField.text;
        if (!url.length) {
            ERLinkLog(@"createLink: 网址为空，忽略");
            return;
        }
        NSString *iconText = iconField.text.length ? iconField.text : @"";
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"uuid"] = [[NSUUID UUID] UUIDString];
        entry[@"name"] = name.length ? name : url;
        entry[@"type"] = @"link";
        entry[@"url"] = url;
        entry[@"color"] = @(0xFF3B82F6LL);
        if (strongSelf.pendingIconFile.length) {
            // 从文件/相册导入的本地图片优先
            entry[@"iconKind"] = @"image";
            entry[@"iconValue"] = strongSelf.pendingIconFile;
            strongSelf.pendingIconFile = nil;
        } else if (iconText.length) {
            if ([iconText.pathExtension.lowercaseString isEqualToString:@"png"] ||
                [iconText.pathExtension.lowercaseString isEqualToString:@"jpg"] ||
                [iconText.pathExtension.lowercaseString isEqualToString:@"jpeg"]) {
                entry[@"iconKind"] = @"image";
                entry[@"iconValue"] = iconText;
            } else if ([iconText containsString:@"."] && ![[iconText lowercaseString] hasPrefix:@"http"]) {
                // 形如 com.apple.mobilesafari → 应用标识符
                entry[@"iconKind"] = @"app";
                entry[@"iconValue"] = iconText;
            } else if ([iconText hasPrefix:@"http://"] || [iconText hasPrefix:@"https://"]) {
                entry[@"iconKind"] = @"image";
                entry[@"iconValue"] = iconText;
            } else {
                entry[@"iconKind"] = @"symbol";
                entry[@"iconValue"] = iconText;
            }
        } else {
            entry[@"iconKind"] = @"symbol";
            entry[@"iconValue"] = @"link";
        }
        NSString *file = ERLinkWriteRenderedIcon(entry);
        if (file) {
            entry[@"iconFile"] = file;
            entry[@"iconFull"] = @([ERLinkResolveIcon(entry)[@"full"] boolValue]);
        }
        [strongSelf saveEntry:entry];
    }];
    UIAlertAction *fromFile = [UIAlertAction actionWithTitle:@"从文件导入图标"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.pendingAlert = alert;
        UIDocumentPickerViewController *picker = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // iOS 14 起推荐 forOpeningContentTypes:，但那需要 UniformTypeIdentifiers；
        // 旧的 documentTypes:inMode: 在这两个系统版本上都还在，只是标了废弃，
        // 而本工程开了 -Werror，所以局部把这条警告按掉。
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.image"]
                                                                       inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
        picker.delegate = strongSelf;
        [strongSelf presentViewController:picker animated:YES completion:nil];
    }];
    UIAlertAction *fromAlbum = [UIAlertAction actionWithTitle:@"从相册导入图标"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.pendingAlert = alert;
        PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] initWithPhotoLibrary:PHPhotoLibrary.sharedPhotoLibrary];
        configuration.selectionLimit = 1;
        configuration.filter = [PHPickerFilter imagesFilter];
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
        picker.delegate = strongSelf;
        [strongSelf presentViewController:picker animated:YES completion:nil];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:save];
    [alert addAction:fromFile];
    [alert addAction:fromAlbum];
    [alert addAction:cancel];
    [self presentViewController:alert animated:YES completion:nil];
}

// MARK: - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSString *fileName = ERLinkImportImageFromURL(url);
    if (!fileName.length) return;
    self.pendingIconFile = fileName;
    // 回填到弹窗的图标输入框，让用户看见已经选好了。
    UITextField *iconField = self.pendingAlert.textFields.count > 1 ? self.pendingAlert.textFields[1] : nil;
    iconField.text = fileName;
}

// MARK: - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *result = results.firstObject;
    if (!result) return;
    NSItemProvider *provider = result.itemProvider;
    if (![provider canLoadObjectOfClass:UIImage.class]) return;
    [provider loadObjectOfClass:UIImage.class completionHandler:^(UIImage *image, NSError *error) {
        if (error || ![image isKindOfClass:UIImage.class]) return;
        NSString *fileName = ERLinkImportImageFromImage(image);
        if (!fileName.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.pendingIconFile = fileName;
            UITextField *iconField = self.pendingAlert.textFields.count > 1 ? self.pendingAlert.textFields[1] : nil;
            iconField.text = fileName;
        });
    }];
}

// MARK: - UISearchBarDelegate

// 「取消」只在点击输入框、开始编辑时出现；不点就不显示。
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
    // 1.1.9-17：三张卡片 —— ① 创建链接（独立卡）② 有快捷方式 ③ 其他应用。
    return 3;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;   // 「创建链接」独占一张卡
    if (section == 1) return (NSInteger)self.withShortcuts.count;
    return (NSInteger)self.withoutShortcuts.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"创建链接";
    if (section == 1) return [NSString stringWithFormat:@"有快捷方式（%lu）", (unsigned long)self.withShortcuts.count];
    return [NSString stringWithFormat:@"其他应用（%lu）", (unsigned long)self.withoutShortcuts.count];
}

- (NSDictionary *)appForIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSDictionary *> *list = (indexPath.section == 1) ? self.withShortcuts : self.withoutShortcuts;
    NSUInteger index = (NSUInteger)indexPath.row;
    if (index >= list.count) return nil;
    return list[index];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ERLinkAddCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    if (indexPath.section == 0) {
        // 「创建链接」单独一张卡。
        cell.textLabel.text = @"创建链接";
        cell.textLabel.textColor = UIColor.labelColor;
        cell.detailTextLabel.text = @"自定义网址或 URL Scheme";
        cell.detailTextLabel.textColor = UIColor.labelColor;
        cell.imageView.image = ERLinkGlyphTile(@"plus.circle.fill", 0xFF3B82F6LL);
        cell.imageView.layer.cornerRadius = 9.0;
        cell.imageView.clipsToBounds = YES;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.userInteractionEnabled = YES;
        return cell;
    }
    NSDictionary *app = [self appForIndexPath:indexPath];
    if (!app) {
        // 空卡片不显示任何占位文字（用户要求：不要「没有可添加的应用」这类行）。
        cell.textLabel.text = nil;
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = NO;
        return cell;
    }
    cell.userInteractionEnabled = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    cell.textLabel.text = app[@"name"];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.text = app[@"bundleId"];
    cell.detailTextLabel.textColor = UIColor.labelColor;
    // 图标统一 40×40，和「创建链接」一致。
    cell.imageView.image = ERLinkAppCellIcon(app[@"bundleId"], 40.0);
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.clipsToBounds = YES;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self presentCreateLink];
        return;
    }
    NSDictionary *app = [self appForIndexPath:indexPath];
    if (!app) return;
    // 点击 App → 进入该 App 的详情页，在详情页里打对号添加/取消。
    ERLinkAppDetailController *detail =
        [[ERLinkAppDetailController alloc] initWithAppBundleId:app[@"bundleId"]
                                                          name:app[@"name"]];
    detail.replaceUUID = self.replaceUUID;   // 1.1.9-62：替换模式透传
    [self.navigationController pushViewController:detail animated:YES];
}

@end

// MARK: - App 详情页（该 App 的真实快捷方式：主屏 Quick Actions）

@implementation ERLinkAppDetailController
{
    UITableView *_detailTable;
}

- (instancetype)initWithAppBundleId:(NSString *)bundleId name:(NSString *)name {
    self = [super init];
    if (!self) return nil;
    _appBundleId = [bundleId isKindOfClass:[NSString class]] ? bundleId : @"";
    _appName = name.length ? name : _appBundleId;
    _shortcutItems = @[];
    return self;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 480.0)];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 单个 section = 一张卡片：第一行 App 头部（图标左 + 名称右），
    // 下面是该 App 的快捷方式条目（SpringBoard 目录优先，Info.plist 静态兜底）。
    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    [self.view addSubview:table];
    _detailTable = table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.appName;
    // viewWillAppear 在个别导航场景可能晚到/不触发，这里先拉一次。
    [self reloadShortcuts];
    ERLinkRequestAppShortcutCatalog();
    if (self.shortcutItems.count == 0) [self scheduleShortcutRetry:1];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadShortcuts];
    // 让 SpringBoard 顺手把目录刷一遍（静态+动态），下次进来更全。
    ERLinkRequestAppShortcutCatalog();
    // 快照可能要等 SpringBoard 扫完才落地：没拿到就自动补拉两次。
    if (self.shortcutItems.count == 0) [self scheduleShortcutRetry:1];
}

// 首次进入时 SpringBoard 可能还没发布快照：发布是异步的，这里 3s/7s 各补拉一次。
- (void)scheduleShortcutRetry:(NSInteger)attempt {
    if (attempt > 2) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((attempt == 1 ? 3.0 : 7.0) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.view.window) return;   // 已离开页面就不再刷
        if (strongSelf.shortcutItems.count > 0) return;       // 已经拿到了
        ERLinkLog(@"appShortcuts: 第 %ld 次补拉目录", (long)attempt);
        ERLinkRequestAppShortcutCatalog();
        [strongSelf reloadShortcuts];
        [strongSelf scheduleShortcutRetry:attempt + 1];
    });
}

- (void)reloadShortcuts {
    self.shortcutItems = ERLinkAppShortcutsForBundle(self.appBundleId);
    [_detailTable reloadData];
}

// 某条快捷方式（按 bundleId + shortcutType 定位）是否已添加进目录。
- (BOOL)shortcutIsAddedForType:(NSString *)type {
    for (NSDictionary *entry in ERLinkStoredCatalog()) {
        if ([entry[@"type"] isEqualToString:@"appShortcut"] &&
            [entry[@"bundleId"] isKindOfClass:[NSString class]] &&
            [entry[@"bundleId"] isEqualToString:self.appBundleId] &&
            [entry[@"shortcutType"] isKindOfClass:[NSString class]] &&
            [entry[@"shortcutType"] isEqualToString:type]) return YES;
    }
    return NO;
}

// 「打开 App」条目是否已添加（type = app，按 bundleId 定位）。
- (BOOL)appEntryIsAdded {
    for (NSDictionary *entry in ERLinkStoredCatalog()) {
        if ([entry[@"type"] isEqualToString:@"app"] &&
            [entry[@"bundleId"] isKindOfClass:[NSString class]] &&
            [entry[@"bundleId"] isEqualToString:self.appBundleId]) return YES;
    }
    return NO;
}

// 移除该 App 的某类条目（kind = @"app" 或 @"appShortcut"；appShortcut 再按 type 过滤），
// 返回移除条目的 uuid 数组（用于清理图标文件）。
- (NSArray<NSString *> *)removeCatalogEntriesOfKind:(NSString *)kind shortcutType:(NSString *)type {
    NSMutableArray<NSDictionary *> *remaining = [NSMutableArray array];
    NSMutableArray<NSString *> *removedUUIDs = [NSMutableArray array];
    for (NSDictionary *entry in ERLinkStoredCatalog()) {
        BOOL match = [entry[@"type"] isEqualToString:kind] &&
                     [entry[@"bundleId"] isKindOfClass:[NSString class]] &&
                     [entry[@"bundleId"] isEqualToString:self.appBundleId];
        if (match && [kind isEqualToString:@"appShortcut"]) {
            match = [entry[@"shortcutType"] isKindOfClass:[NSString class]] &&
                    [entry[@"shortcutType"] isEqualToString:type];
        }
        if (match) {
            NSString *uuid = entry[@"uuid"];
            if ([uuid isKindOfClass:[NSString class]] && uuid.length) [removedUUIDs addObject:uuid];
        } else {
            [remaining addObject:entry];
        }
    }
    if (removedUUIDs.count) ERLinkPersistCatalog(remaining);
    return removedUUIDs;
}

// MARK: Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    // 第一行：App 头部；之后是快捷方式条目（无条目时不显示任何占位行）。
    return 1 + (NSInteger)self.shortcutItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 0) {
        static NSString *headerId = @"ERLinkAppHeaderCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:headerId];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:headerId];
        // 页内图标统一 30×30（用户指定与条目一致）。
        cell.imageView.image = ERLinkAppCellIcon(self.appBundleId, 30.0);
        cell.imageView.layer.cornerRadius = 7.0;
        cell.imageView.clipsToBounds = YES;
        cell.textLabel.text = self.appName;
        cell.textLabel.textColor = UIColor.labelColor;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0];
        // 点击头部 = 添加/取消「打开 App」快捷方式。
        cell.accessoryType = [self appEntryIsAdded] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.tintColor = [UIColor colorWithRed:0.11 green:0.60 blue:0.97 alpha:1.0];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.userInteractionEnabled = YES;
        return cell;
    }
    static NSString *itemId = @"ERLinkAppItemCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:itemId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:itemId];
    cell.userInteractionEnabled = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    NSDictionary *item = self.shortcutItems[(NSUInteger)(indexPath.row - 1)];
    cell.imageView.image = ERLinkAppCellIcon(self.appBundleId, 30.0);
    cell.imageView.layer.cornerRadius = 7.0;
    cell.imageView.clipsToBounds = YES;
    NSString *rawTitle = item[@"title"];
    NSString *title = [rawTitle isKindOfClass:[NSString class]] && rawTitle.length
        ? rawTitle : item[@"type"];
    cell.textLabel.text = title;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.accessoryType = [self shortcutIsAddedForType:item[@"type"]]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor colorWithRed:0.11 green:0.60 blue:0.97 alpha:1.0];
    return cell;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return self.shortcutItems.count
        ? @"点击一条即可添加为快捷方式，再次点击取消对号。"
        : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // 1.1.9-62：替换模式 —— 头部行换成「打开 App」目标，条目行换成对应快捷方式，
    // 原位替换后直接弹回自定义页，不走对号增删逻辑。
    if (self.replaceUUID.length) {
        NSDictionary *fresh = nil;
        if (indexPath.row == 0) {
            fresh = ERLinkMakeAppEntry(self.appBundleId, self.appName);
        } else if (indexPath.row <= (NSInteger)self.shortcutItems.count) {
            NSDictionary *item = self.shortcutItems[(NSUInteger)(indexPath.row - 1)];
            NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"";
            if (!type.length) return;
            fresh = ERLinkMakeAppShortcutEntry(self.appBundleId, self.appName, type, item[@"title"]);
        } else {
            return;
        }
        ERLinkReplaceEntry(self.replaceUUID, fresh);
        ERLinkPopBackToCustomize(self);
        return;
    }
    if (indexPath.row == 0) {
        // 头部行：添加/取消「打开 App」。
        NSMutableArray<NSDictionary *> *catalog = [ERLinkStoredCatalog() mutableCopy] ?: [NSMutableArray array];
        if ([self appEntryIsAdded]) {
            for (NSString *uuid in [self removeCatalogEntriesOfKind:@"app" shortcutType:nil]) {
                [[NSFileManager defaultManager]
                    removeItemAtPath:ERLinkLocalImagePath([uuid stringByAppendingPathExtension:@"png"])
                               error:nil];
            }
            ERLinkLog(@"appDetail: 取消打开App %@", self.appBundleId);
        } else {
            [catalog addObject:ERLinkMakeAppEntry(self.appBundleId, self.appName)];
            ERLinkPersistCatalog(catalog);
            ERLinkLog(@"appDetail: 添加打开App %@", self.appBundleId);
        }
        [tableView reloadData];
        return;
    }
    if (indexPath.row > (NSInteger)self.shortcutItems.count) return;
    NSDictionary *item = self.shortcutItems[(NSUInteger)(indexPath.row - 1)];
    NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"";
    if (!type.length) return;
    NSMutableArray<NSDictionary *> *catalog = [ERLinkStoredCatalog() mutableCopy] ?: [NSMutableArray array];
    if ([self shortcutIsAddedForType:type]) {
        for (NSString *uuid in [self removeCatalogEntriesOfKind:@"appShortcut" shortcutType:type]) {
            [[NSFileManager defaultManager]
                removeItemAtPath:ERLinkLocalImagePath([uuid stringByAppendingPathExtension:@"png"])
                           error:nil];
        }
        ERLinkLog(@"appDetail: 取消 %@ / %@", self.appBundleId, type);
    } else {
        [catalog addObject:ERLinkMakeAppShortcutEntry(self.appBundleId, self.appName, type, item[@"title"])];
        ERLinkPersistCatalog(catalog);
        ERLinkLog(@"appDetail: 添加 %@ / %@", self.appBundleId, type);
    }
    [tableView reloadData];
}

@end

// MARK: - 图标选择页（1.1.9-62 · keyboardX 风格：搜索 + SF 符号网格）

// 内置符号池：常用 SF Symbols（可搜索；系统不存在的符号会被自动过滤掉）。
static NSArray<NSString *> *ERLinkSymbolCatalog(void) {
    static NSArray<NSString *> *catalog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        catalog = @[
            // 通用 / 方向
            @"link", @"globe", @"house", @"house.fill", @"magnifyingglass", @"gear", @"gearshape.fill",
            @"star", @"star.fill", @"heart", @"heart.fill", @"bookmark", @"bookmark.fill",
            @"flag", @"flag.fill", @"pin", @"pin.fill", @"mappin", @"mappin.circle.fill",
            // 通信 / 社交
            @"message", @"message.fill", @"phone", @"phone.fill", @"envelope", @"envelope.fill",
            @"bubble.left", @"bubble.left.fill", @"bubble.right.fill", @"person", @"person.fill",
            @"person.2", @"person.2.fill", @"person.crop.circle", @"person.crop.circle.fill",
            @"at", @"mic", @"mic.fill", @"video", @"video.fill", @"phone.arrow.up.right.fill",
            // 工具 / 系统
            @"bolt", @"bolt.fill", @"wand.and.stars", @"sparkles", @"timer", @"timer.circle.fill",
            @"alarm", @"stopwatch", @"calendar", @"clock", @"clock.fill", @"bell", @"bell.fill",
            @"tray", @"tray.fill", @"archivebox", @"archivebox.fill", @"doc", @"doc.fill",
            @"doc.text", @"doc.text.fill", @"note.text", @"folder", @"folder.fill",
            @"clipboard", @"paperplane", @"paperplane.fill", @"square.and.pencil",
            @"pencil", @"pencil.tip", @"eraser", @"scissors", @"ruler", @"wrench",
            @"wrench.and.screwdriver", @"hammer", @"paintbrush", @"paintbrush.fill",
            // 媒体
            @"play", @"play.fill", @"pause.fill", @"stop.fill", @"forward.fill", @"backward.fill",
            @"music.note", @"music.note.list", @"headphones", @"speaker.wave.2.fill",
            @"waveform", @"waveform.circle.fill", @"tv", @"tv.fill", @"video.circle.fill",
            @"camera", @"camera.fill", @"photo", @"photo.fill", @"photo.on.rectangle",
            @"movieclapper", @"movieclapper.fill", @"radio", @"podcast", @"gamecontroller",
            @"gamecontroller.fill",
            // 网络 / 存储
            @"wifi", @"wifi.circle.fill", @"antenna.radiowaves.left.and.right",
            @"antenna.radiowaves.left.and.right.circle.fill", @"arrow.up.arrow.down",
            @"arrow.triangle.2.circlepath", @"arrow.triangle.swap", @"cloud", @"cloud.fill",
            @"externaldrive", @"externaldrive.fill", @"internaldrive.fill", @"tray.full.fill",
            @"externaldrive.badge.icloud", @"icloud", @"icloud.fill",
            // 安全 / 系统
            @"lock", @"lock.fill", @"lock.open.fill", @"key", @"key.fill", @"shield",
            @"shield.fill", @"checkmark.shield.fill", @"exclamationmark.shield.fill",
            @"checkmark.circle", @"checkmark.circle.fill", @"xmark.circle.fill",
            @"exclamationmark.triangle.fill", @"info.circle", @"questionmark.circle",
            @"power", @"power.circle.fill", @"moon", @"moon.fill", @"sun.max", @"sun.max.fill",
            @"eye", @"eye.fill", @"eye.slash.fill", @"hand.raised.fill", @"faceid",
            // 金融 / 数据
            @"creditcard", @"creditcard.fill", @"banknote", @"banknote.fill", @"yensign.circle.fill",
            @"chart.bar", @"chart.bar.fill", @"chart.line.uptrend.xyaxis", @"chart.pie.fill",
            @"list.bullet", @"list.number", @"tablecells", @"square.grid.2x2.fill",
            @"square.grid.3x3.fill", @"rectangle.grid.1x2.fill", @"text.justify",
            // 生活方式
            @"cart", @"cart.fill", @"bag", @"bag.fill", @"tag", @"tag.fill", @"gift", @"gift.fill",
            @"cup.and.saucer", @"cup.and.saucer.fill", @"fork.knife", @"fork.knife.circle.fill",
            @"car", @"car.fill", @"bus.fill", @"airplane", @"airplane.circle.fill", @"bicycle",
            @"figure.walk", @"figure.run", @"sportscourt.fill", @"dumbbell.fill",
            @"leaf", @"leaf.fill", @"tree.fill", @"drop", @"drop.fill", @"flame", @"flame.fill",
            @"snowflake", @"wind", @"thermometer.sun.fill", @"smiley", @"smiley.fill",
            @"plus.circle.fill", @"minus.circle.fill", @"xmark.circle", @"arrow.up.circle.fill",
            @"arrow.down.circle.fill", @"arrow.right.circle.fill", @"arrow.left.circle.fill",
            @"bolt.circle.fill", @"wifi.router.fill", @"app.fill", @"app.badge.fill",
            @"square.stack.3d.up.fill", @"rectangle.stack.fill", @"circle.grid.3x3.fill",
            @"battery.100.bolt", @"lightbulb.fill", @"flashlight.on.fill", @"printer.fill",
            @"touchid", @"text.bubble.fill", @"globe.asia.australia.fill", @"build.2.fill",
        ];
    });
    return catalog;
}

static NSString *const kERLinkSymbolGridCell = @"ERLinkSymbolGridCell";

#pragma mark - 系统符号目录（移植 keyboardX DXPSFSymbolCatalog 的读取逻辑）

static NSArray<NSString *> *ERLinkSymbolResourceDirectories(void) {
    NSMutableOrderedSet<NSString *> *directories = [NSMutableOrderedSet orderedSet];
    for (NSString *root in @[
        @"/System/Library/CoreServices/CoreGlyphs.bundle",
        @"/System/Library/PrivateFrameworks/CoreGlyphs.framework/CoreGlyphs.bundle",
        @"/System/Library/PrivateFrameworks/SFSymbols.framework",
    ]) {
        [directories addObject:root];
        [directories addObject:[root stringByAppendingPathComponent:@"Resources"]];
        NSString *resolved = [NSBundle bundleWithPath:root].resourcePath;
        if (resolved.length) [directories addObject:resolved];
    }
    return directories.array;
}

static id ERLinkReadCatalogPlist(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data.length ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:NULL] : nil;
}

static void ERLinkAppendName(id value, NSMutableOrderedSet<NSString *> *names) {
    if (![value isKindOfClass:[NSString class]]) return;
    NSString *name = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length) [names addObject:name];
}

static void ERLinkCollectSymbolNames(id object, NSMutableOrderedSet<NSString *> *names, NSUInteger depth) {
    if (depth > 8) return;
    if ([object isKindOfClass:[NSArray class]]) {
        for (id entry in object) {
            if ([entry isKindOfClass:[NSString class]]) {
                ERLinkAppendName(entry, names);
            } else if ([entry isKindOfClass:[NSDictionary class]]) {
                for (NSString *key in @[@"name", @"symbol", @"Name"]) {
                    id value = entry[key];
                    if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length) {
                        ERLinkAppendName(value, names);
                        break;
                    }
                }
            }
        }
    } else if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = object;
        if (dict[@"names"] || dict[@"symbols"]) {
            for (NSString *key in @[@"names", @"symbols"]) {
                id value = dict[key];
                if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
                    ERLinkCollectSymbolNames(value, names, depth + 1);
                }
            }
            return;
        }
        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        for (NSString *key in dict) {
            if ([key isKindOfClass:[NSString class]] && ![key hasPrefix:@"CF"] &&
                ![key isEqualToString:@"version"] && ![key isEqualToString:@"year_to_release"]) {
                [keys addObject:key];
            }
        }
        [keys sortUsingSelector:@selector(compare:)];
        for (NSString *key in keys) ERLinkAppendName(key, names);
    }
}

// 全量候选符号名（symbol_order.plist + name_availability.plist；未验证）。
static NSArray<NSString *> *ERLinkSystemSymbolCandidates(NSArray<NSString *> *directories) {
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (NSString *fileName in @[@"symbol_order.plist", @"name_availability.plist"]) {
        for (NSString *directory in directories) {
            if (![directory isKindOfClass:[NSString class]] || !directory.length) continue;
            NSString *path = [[directory stringByAppendingPathComponent:fileName] stringByStandardizingPath];
            if ([visited containsObject:path]) continue;
            [visited addObject:path];
            id object = ERLinkReadCatalogPlist(path);
            NSMutableOrderedSet<NSString *> *fileNames = [NSMutableOrderedSet orderedSet];
            ERLinkCollectSymbolNames(object, fileNames, 0);
            if (!fileNames.count) continue;
            [names addObjectsFromArray:fileNames.array];
        }
    }
    return names.array;
}

static void ERLinkCollectCategoryDefs(id object, NSMutableOrderedSet<NSString *> *order,
                                      NSMutableDictionary<NSString *, NSDictionary *> *defs) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        id categories = object[@"categories"];
        if ([categories isKindOfClass:[NSArray class]]) object = categories;
    }
    if (![object isKindOfClass:[NSArray class]]) return;
    for (id entry in object) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        id key = entry[@"key"];
        if (![key isKindOfClass:[NSString class]]) continue;
        NSString *identifier = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!identifier.length) continue;
        [order addObject:identifier];
        if (!defs[identifier]) defs[identifier] = entry;
    }
}

// 分类列表：@{key, title, icon, names}。顺序：全部 → 多色 → Variable Color → 系统分类。
static NSArray<NSDictionary *> *ERLinkSymbolCategories(NSArray<NSString *> *directories,
                                                       NSOrderedSet<NSString *> *validNames) {
    NSMutableOrderedSet<NSString *> *order = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSString *, NSDictionary *> *defs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableOrderedSet<NSString *> *> *membership = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (NSString *directory in directories) {
        if (![directory isKindOfClass:[NSString class]] || !directory.length) continue;
        for (NSString *fileName in @[@"categories.plist", @"symbol_categories.plist"]) {
            NSString *path = [[directory stringByAppendingPathComponent:fileName] stringByStandardizingPath];
            if ([visited containsObject:path]) continue;
            [visited addObject:path];
            id object = ERLinkReadCatalogPlist(path);
            if ([fileName isEqualToString:@"categories.plist"]) {
                ERLinkCollectCategoryDefs(object, order, defs);
                continue;
            }
            if (![object isKindOfClass:[NSDictionary class]]) continue;
            if ([object[@"symbols"] isKindOfClass:[NSDictionary class]]) object = object[@"symbols"];
            for (NSString *name in validNames) {
                id cats = object[name];
                if ([cats isKindOfClass:[NSDictionary class]]) cats = cats[@"categories"];
                if (![cats isKindOfClass:[NSArray class]]) continue;
                NSMutableOrderedSet<NSString *> *ids = membership[name];
                if (!ids) ids = [NSMutableOrderedSet orderedSet];
                for (id identifier in cats) ERLinkAppendName(identifier, ids);
                if (ids.count) membership[name] = ids;
            }
        }
    }
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *groups = [NSMutableDictionary dictionary];
    for (NSString *name in validNames) {
        for (NSString *identifier in membership[name]) {
            if (!groups[identifier]) groups[identifier] = [NSMutableArray array];
            [groups[identifier] addObject:name];
        }
    }
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    [result addObject:@{@"key": @"all", @"title": @"全部", @"icon": @"square.grid.2x2", @"names": validNames.array}];
    // 分类标题做一次中文映射（系统 plist 里多为英文标识符）。
    NSDictionary *titles = @{
        @"multicolor": @"多色", @"variable": @"Variablecolor",
        @"communication": @"通信", @"weather": @"天气",
        @"object_and_tools": @"物品与工具", @"objects_and_tools": @"物品与工具",
        @"devices": @"设备", @"camera_and_photos": @"相机与照片",
        @"games": @"游戏", @"connectivity": @"连接",
        @"transportation": @"交通", @"automotive": @"汽车",
        @"accessibility": @"辅助功能", @"privacy_and_security": @"隐私与安全",
        @"health": @"健康", @"fitness": @"健身", @"editing": @"编辑",
        @"keyboard": @"键盘", @"maps": @"地图", @"media": @"媒体",
        @"mess_and_symbols": @"信息与符号", @"math": @"数学",
        @"money": @"金钱", @"nature": @"自然", @"dates_and_times": @"日期与时间",
        @"home": @"家庭", @"sound": @"声音", @"sports": @"运动",
        @"time": @"时间", @"text_formatting": @"文本格式",
    };
    NSMutableOrderedSet<NSString *> *displayOrder = [NSMutableOrderedSet orderedSetWithArray:@[@"multicolor", @"variable"]];
    for (NSString *identifier in order) {
        if (![identifier isEqualToString:@"whatsnew"] && ![identifier isEqualToString:@"all"]) [displayOrder addObject:identifier];
    }
    for (NSString *identifier in [[groups allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![identifier isEqualToString:@"whatsnew"] && ![identifier isEqualToString:@"all"]) [displayOrder addObject:identifier];
    }
    for (NSString *identifier in displayOrder) {
        NSArray *names = groups[identifier];
        if (!names.count) continue;
        NSDictionary *meta = defs[identifier];
        NSString *title = nil;
        for (NSString *key in @[@"title", @"name", @"label"]) {
            id value = meta[key];
            if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length) { title = value; break; }
        }
        if (!title.length) title = titles[identifier] ?: identifier;
        NSString *icon = nil;
        id iconValue = meta[@"icon"];
        if ([iconValue isKindOfClass:[NSString class]]) icon = iconValue;
        if (!icon.length) icon = @"tag";
        [result addObject:@{@"key": identifier, @"title": title, @"icon": icon, @"names": names}];
    }
    return result;
}

#pragma mark - 网格磁贴 cell

// 1.1.9-64：keyboardX 风格网格磁贴 —— 圆角 12 底块 + 32pt 符号 + 底部小字名称 + 选中蓝对勾。
@interface ERSymbolTileCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIImageView *symbolView;
@property (nonatomic, strong) UIImageView *checkView;
@end

@implementation ERSymbolTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    UIView *tile = [[UIView alloc] initWithFrame:CGRectZero];
    tile.tag = 80;
    tile.backgroundColor = [UIColor tertiarySystemFillColor];
    tile.layer.cornerRadius = 12.0;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:tile];

    UIImageView *symbol = [[UIImageView alloc] initWithFrame:CGRectZero];
    symbol.tag = 81;
    symbol.contentMode = UIViewContentModeScaleAspectFit;
    symbol.tintColor = UIColor.labelColor;
    symbol.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:symbol];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.tag = 82;
    name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.7;
    name.textAlignment = NSTextAlignmentCenter;
    name.textColor = UIColor.secondaryLabelColor;
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:name];

    UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
    check.tag = 83;
    check.tintColor = UIColor.systemBlueColor;
    check.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:check];

    [NSLayoutConstraint activateConstraints:@[
        [tile.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4.0],
        [tile.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4.0],
        [tile.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4.0],
        [tile.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4.0],
        [symbol.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [symbol.topAnchor constraintEqualToAnchor:tile.topAnchor constant:12.0],
        [symbol.widthAnchor constraintEqualToConstant:32.0],
        [symbol.heightAnchor constraintEqualToConstant:32.0],
        [name.topAnchor constraintEqualToAnchor:symbol.bottomAnchor constant:6.0],
        [name.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:3.0],
        [name.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-3.0],
        [check.topAnchor constraintEqualToAnchor:tile.topAnchor constant:4.0],
        [check.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-4.0],
        [check.widthAnchor constraintEqualToConstant:19.0],
        [check.heightAnchor constraintEqualToConstant:19.0],
    ]];
    _nameLabel = name;
    _symbolView = symbol;
    _checkView = check;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 底块高度不足时收窄间距，保证 4 列窄磁贴也能放下。
    UIView *tile = [self.contentView viewWithTag:80];
    UIImageView *symbol = [self.contentView viewWithTag:81];
    UILabel *name = [self.contentView viewWithTag:82];
    CGFloat h = CGRectGetHeight(tile.frame);
    if (h < 64.0) {
        symbol.transform = CGAffineTransformMakeScale(0.8, 0.8);
        name.font = [UIFont systemFontOfSize:9.0];
    } else {
        symbol.transform = CGAffineTransformIdentity;
        name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    }
}

@end

@implementation ERLinkIconPickerController {
    UITableView *_table;                    // 根模式：分类列表
    UICollectionView *_grid;
    UISegmentedControl *_columns;           // 网格模式：1~4 列
    UISearchController *_search;
    NSArray<NSDictionary *> *_categories;   // 根模式：分类数组（key/title/icon/names）
    NSArray<NSString *> *_allNames;         // 全部可用符号（已逐一验证）
    NSArray<NSString *> *_scopeNames;       // 当前网格范围（网格模式=分类内，根模式=全部）
    NSArray<NSString *> *_filtered;
    NSInteger _columnCount;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 480.0)];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    BOOL gridMode = self.categoryNames.count > 0;

    // 分类列表（根模式；keyboardX：首页 = 分类表，搜索时整个目录出网格）。
    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    table.hidden = gridMode;
    [self.view addSubview:table];
    _table = table;

    // 列数记忆。
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"ERLinkPreferredSymbolColumns"];
    _columnCount = saved.integerValue >= 1 && saved.integerValue <= 4 ? saved.integerValue : 3;

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 6.0;
    layout.minimumLineSpacing = 10.0;
    UICollectionView *grid = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    grid.backgroundColor = UIColor.systemBackgroundColor;
    grid.dataSource = self;
    grid.delegate = self;
    grid.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    grid.hidden = !gridMode;
    [grid registerClass:ERSymbolTileCell.class forCellWithReuseIdentifier:kERLinkSymbolGridCell];
    [self.view addSubview:grid];
    _grid = grid;

    if (gridMode) {
        UISegmentedControl *columns = [[UISegmentedControl alloc] initWithItems:@[@"1列", @"2列", @"3列", @"4列"]];
        columns.selectedSegmentIndex = (NSInteger)_columnCount - 1;
        [columns addTarget:self action:@selector(columnsChanged:) forControlEvents:UIControlEventValueChanged];
        columns.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:columns];
        [NSLayoutConstraint activateConstraints:@[
            [columns.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
            [columns.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
            [columns.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-10.0],
            [columns.heightAnchor constraintEqualToConstant:32.0],
        ]];
        _columns = columns;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.title = self.categoryTitle.length ? self.categoryTitle : @"图标库";
    // keyboardX：搜索挂在 navigationItem（裸 UISearchBar 在 Settings 进程里不响应）。
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.hidesNavigationBarDuringPresentation = NO;
    search.obscuresBackgroundDuringPresentation = NO;
    search.definesPresentationContext = YES;
    search.searchBar.placeholder = @"搜索图标名";
    self.navigationItem.searchController = search;
    _search = search;
    [self loadCatalogInBackground];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = CGRectGetMaxY(self.navigationController.navigationBar.frame);
    if (top < 60.0) top = 60.0;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    _table.frame = CGRectMake(0.0, 0.0, width, height);
    CGFloat bottom = _columns ? (CGRectGetMinY(_columns.frame) - 10.0) : height;
    _grid.frame = CGRectMake(0.0, top, width, bottom - top);
}

// 读取系统符号目录（CoreGlyphs / SFSymbols 资源）。1.1.9-66：不再全量逐一验证
// （5000+ 次 systemImageNamed 是 1~2 秒延迟的来源），无效符号由保存时校验兜底。
- (void)loadCatalogInBackground {
    BOOL gridMode = self.categoryNames.count > 0;
    NSArray *gridCategory = self.categoryNames;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *dirs = ERLinkSymbolResourceDirectories();
        NSArray<NSString *> *candidates = ERLinkSystemSymbolCandidates(dirs);
        NSArray<NSString *> *all = candidates;
        if (!candidates.count) {
            // 目录读取失败时退回内置小池（逐个验证，量小无感）。
            NSMutableArray<NSString *> *checked = [NSMutableArray array];
            for (NSString *name in ERLinkSymbolCatalog()) {
                if ([UIImage systemImageNamed:name]) [checked addObject:name];
            }
            all = checked;
        }
        NSArray<NSDictionary *> *cats = gridMode ? @[] : ERLinkSymbolCategories(dirs, [NSOrderedSet orderedSetWithArray:all]);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_allNames = all;
            self->_categories = cats;
            if (gridMode) {
                // 网格模式：范围 = 传入的分类名单（原样使用，不再过滤）。
                NSMutableOrderedSet<NSString *> *scope = [NSMutableOrderedSet orderedSet];
                for (id item in gridCategory) {
                    NSString *name = nil;
                    if ([item isKindOfClass:[NSString class]]) name = item;
                    else if ([item isKindOfClass:[NSDictionary class]]) name = item[@"name"];
                    if ([name isKindOfClass:[NSString class]]) [scope addObject:name];
                }
                self->_scopeNames = scope.array;
            } else {
                self->_scopeNames = all;
            }
            self->_filtered = self->_scopeNames;
            [self->_table reloadData];
            [self->_grid reloadData];
        });
    });
}

- (void)columnsChanged:(UISegmentedControl *)sender {
    _columnCount = sender.selectedSegmentIndex + 1;
    [[NSUserDefaults standardUserDefaults] setObject:@(_columnCount) forKey:@"ERLinkPreferredSymbolColumns"];
    [(UICollectionViewFlowLayout *)_grid.collectionViewLayout invalidateLayout];
}

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController {
    NSString *needle = _search.searchBar.text.lowercaseString;
    if (!needle.length) {
        _filtered = _scopeNames;
        // 根模式：清空搜索回到分类列表。
        if (!self.categoryNames.count) {
            _table.hidden = NO;
            _grid.hidden = YES;
        }
    } else {
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        for (NSString *name in _scopeNames) {
            if ([name.lowercaseString containsString:needle]) [result addObject:name];
        }
        _filtered = result;
        // 根模式：搜索时整个目录以网格展示（keyboardX 行为）。
        if (!self.categoryNames.count) {
            _table.hidden = YES;
            _grid.hidden = NO;
        }
    }
    [_grid reloadData];
}

#pragma mark 分类列表（根模式）

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)_categories.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"ERLinkCategoryCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];
    NSDictionary *meta = _categories.count > (NSUInteger)indexPath.row ? _categories[(NSUInteger)indexPath.row] : @{};
    UIImage *icon = [UIImage systemImageNamed:meta[@"icon"]];
    if (!icon) icon = [UIImage systemImageNamed:@"tag"];
    cell.imageView.image = icon;
    cell.imageView.tintColor = UIColor.labelColor;
    cell.textLabel.text = meta[@"title"];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)[meta[@"names"] count]];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _categories.count) return;
    NSDictionary *meta = _categories[(NSUInteger)indexPath.row];
    ERLinkIconPickerController *grid = [[ERLinkIconPickerController alloc] init];
    grid.pickerDelegate = self.pickerDelegate;
    grid.selectedSymbol = self.selectedSymbol;
    grid.categoryNames = meta[@"names"];
    grid.categoryTitle = meta[@"title"];
    [self.navigationController pushViewController:grid animated:YES];
}

#pragma mark 网格

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView numberOfItemsInSection:(__unused NSInteger)section {
    return (NSInteger)_filtered.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ERSymbolTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kERLinkSymbolGridCell forIndexPath:indexPath];
    NSString *name = _filtered[(NSUInteger)indexPath.row];
    UIImageConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:32.0];
    cell.symbolView.image = [UIImage systemImageNamed:name withConfiguration:config];
    cell.nameLabel.text = name;
    BOOL selected = [name isEqualToString:self.selectedSymbol];
    cell.checkView.hidden = !selected;
    return cell;
}

- (CGSize)collectionView:(__unused UICollectionView *)collectionView layout:(UICollectionViewFlowLayout *)layout sizeForItemAtIndexPath:(__unused NSIndexPath *)indexPath {
    CGFloat width = CGRectGetWidth(_grid.frame);
    if (width <= 0.0) width = 320.0;
    CGFloat inset = 10.0;
    CGFloat spacing = 6.0;
    CGFloat itemW = (width - inset * 2.0 - spacing * (_columnCount - 1)) / _columnCount;
    CGFloat itemH = _columnCount == 1 ? 64.0 : 76.0;
    return CGSizeMake(itemW, itemH);
}

- (UIEdgeInsets)collectionView:(__unused UICollectionView *)collectionView layout:(__unused UICollectionViewFlowLayout *)layout insetForSectionAtIndex:(__unused NSInteger)section {
    return UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= _filtered.count) return;
    NSString *name = _filtered[(NSUInteger)indexPath.row];
    if ([self.pickerDelegate respondsToSelector:@selector(iconPickerDidPickSymbol:)]) {
        [self.pickerDelegate iconPickerDidPickSymbol:name];
    }
    // 1.1.9-66：选完直接回到「快捷动作信息」页（跳过图标库根页）。
    UINavigationController *nav = self.navigationController;
    for (NSInteger i = (NSInteger)nav.viewControllers.count - 1; i >= 0; i--) {
        UIViewController *vc = nav.viewControllers[(NSUInteger)i];
        if ([vc isKindOfClass:[ERLinkCustomizeController class]]) {
            [nav popToViewController:vc animated:YES];
            return;
        }
    }
    [nav popViewControllerAnimated:YES];
}

@end

// MARK: - 自定义快捷方式页（1.1.9-63：右上角保存制 + 版式调整）

@implementation ERLinkCustomizeController {
    UITableView *_table;
    NSString *_uuid;
    UITextField *_iconField;
    // 1.1.9-63：未保存的修改（点右上角「保存」才落盘生效）。
    NSString *_pendingName;
    NSString *_pendingSymbol;   // 与 _pendingSymbolSet 搭配：Set=YES 表示改过图标
    BOOL _pendingSymbolSet;
}

- (instancetype)initWithUUID:(NSString *)uuid {
    self = [super init];
    if (!self) return nil;
    _uuid = [uuid isKindOfClass:[NSString class]] ? uuid : @"";
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
    _table = table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    // 1.1.9-63：右上角「保存」—— 修改先暂存，点保存才写入生效。
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                             style:UIBarButtonItemStyleDone
                                                            target:self
                                                            action:@selector(saveTapped)];
    self.navigationItem.rightBarButtonItem = save;
    [self ensureDefaultSnapshot];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshTitle];
    [_table reloadData];
}

// 首次进入时把创建时的名称/图标存档（「恢复默认」用；只写一次）。
- (void)ensureDefaultSnapshot {
    NSDictionary *entry = [self entry];
    if (!entry) return;
    if ([entry[@"defaultName"] isKindOfClass:[NSString class]] &&
        ((NSString *)entry[@"defaultName"]).length) return;
    NSString *name = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"";
    NSString *kind = [entry[@"iconKind"] isKindOfClass:[NSString class]] ? entry[@"iconKind"] : @"";
    NSString *value = [entry[@"iconValue"] isKindOfClass:[NSString class]] ? entry[@"iconValue"] : @"";
    [self mutateEntryQuiet:^(NSMutableDictionary *updated) {
        updated[@"defaultName"] = name;
        updated[@"defaultIconKind"] = kind;
        updated[@"defaultIconValue"] = value;
    }];
}

- (void)refreshTitle {
    NSDictionary *entry = [self entry];
    NSString *name = [_pendingName length] ? _pendingName
                   : ([entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"");
    self.title = name.length ? name : @"自定义快捷方式";
}

- (NSDictionary *)entry {
    for (NSDictionary *entry in ERLinkStoredCatalog()) {
        if ([entry[@"uuid"] isKindOfClass:[NSString class]] &&
            [entry[@"uuid"] isEqualToString:_uuid]) return entry;
    }
    return nil;
}

// MARK: Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 4 : 1;
}

// 1.1.9-63：删除/恢复卡片加高一点，别太细。
- (CGFloat)tableView:(__unused UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 ? 48.0 : 44.0;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return section == 0 ? @"快捷动作信息" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *entry = [self entry] ?: @{};
    static NSString *plainId = @"ERLinkCustomPlain";
    static NSString *iconId = @"ERLinkCustomIcon";
    static NSString *replaceId = @"ERLinkCustomReplace";
    static NSString *actionsId = @"ERLinkCustomActions";

    NSString *identifier = plainId;
    if (indexPath.section == 0 && indexPath.row == 2) identifier = iconId;
    if (indexPath.section == 0 && indexPath.row == 3) identifier = replaceId;
    if (indexPath.section == 1) identifier = actionsId;

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    BOOL iconRow = [identifier isEqualToString:iconId];
    BOOL actionsRow = [identifier isEqualToString:actionsId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];
        if (iconRow) {
            // 1.1.9-64 版式（参考天气模块城市选择 ERWeatherCityCell，绿色改蓝色）：
            // 顺序：图标（标签最左）→ 图标预览 → 输入框（无边框）→ 选择按钮。
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
            field.placeholder = @"SF 符号名";
            field.textAlignment = NSTextAlignmentLeft;
            field.font = [UIFont systemFontOfSize:16.0];
            field.borderStyle = UITextBorderStyleNone;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            field.returnKeyType = UIReturnKeyDone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.delegate = self;
            field.tag = 61;
            field.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:field];
            _iconField = field;
            UIButton *pick = [UIButton buttonWithType:UIButtonTypeCustom];
            pick.tag = 62;
            [pick setTitle:@"选择" forState:UIControlStateNormal];
            pick.titleLabel.font = [UIFont systemFontOfSize:15.0];
            [pick setTitleColor:UIColor.systemBlueColor forState:UIControlStateNormal];
            pick.layer.cornerRadius = 6.0;
            pick.layer.borderWidth = 1.0;
            pick.layer.borderColor = UIColor.systemBlueColor.CGColor;
            pick.clipsToBounds = YES;
            [pick addTarget:self action:@selector(pickIconTapped) forControlEvents:UIControlEventTouchUpInside];
            pick.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:pick];
            UIImageView *preview = [[UIImageView alloc] initWithFrame:CGRectZero];
            preview.tag = 63;
            preview.contentMode = UIViewContentModeScaleAspectFit;
            preview.layer.cornerRadius = 9.0;
            preview.clipsToBounds = YES;
            preview.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:preview];
            UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                // 顺序：标签(margins.leading) → 预览 → 输入框 → 选择按钮(margins.trailing)。
                // 预览锚定「图标」文字尾部，两侧间距恒等（都是 10pt）。
                [preview.leadingAnchor constraintEqualToAnchor:cell.textLabel.trailingAnchor constant:10.0],
                [preview.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [preview.widthAnchor constraintEqualToConstant:34.0],
                [preview.heightAnchor constraintEqualToConstant:34.0],
                [field.leadingAnchor constraintEqualToAnchor:preview.trailingAnchor constant:10.0],
                [field.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [field.heightAnchor constraintEqualToConstant:34.0],
                [pick.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
                [pick.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [pick.widthAnchor constraintEqualToConstant:45.0],
                [pick.heightAnchor constraintEqualToConstant:29.0],
                [field.trailingAnchor constraintEqualToAnchor:pick.leadingAnchor constant:-10.0],
            ]];
        } else if (actionsRow) {
            // 1.1.9-64：去掉卡片大背景（cell 透明），只留左右两个自带背景的按钮。
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = UIColor.clearColor;
            cell.contentView.backgroundColor = UIColor.clearColor;
            cell.backgroundView = [[UIView alloc] init];
            cell.backgroundView.backgroundColor = UIColor.clearColor;
            cell.selectedBackgroundView = [[UIView alloc] init];
            cell.selectedBackgroundView.backgroundColor = UIColor.clearColor;
            UIButton *restore = [UIButton buttonWithType:UIButtonTypeSystem];
            restore.tag = 64;
            [restore setTitle:@"恢复默认" forState:UIControlStateNormal];
            restore.titleLabel.font = [UIFont systemFontOfSize:15.0];
            restore.backgroundColor = [UIColor secondarySystemFillColor];
            restore.layer.cornerRadius = 10.0;
            [restore addTarget:self action:@selector(restoreTapped) forControlEvents:UIControlEventTouchUpInside];
            restore.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:restore];
            UIButton *delete = [UIButton buttonWithType:UIButtonTypeSystem];
            delete.tag = 65;
            [delete setTitle:@"删除快捷动作" forState:UIControlStateNormal];
            [delete setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
            delete.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
            delete.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:0.14];
            delete.layer.cornerRadius = 10.0;
            [delete addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
            delete.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:delete];
            UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                [restore.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                [restore.trailingAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor constant:-6.0],
                [restore.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4.0],
                [restore.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4.0],
                [delete.leadingAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor constant:6.0],
                [delete.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
                [delete.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4.0],
                [delete.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4.0],
            ]];
        }
    }
    if (actionsRow) return cell;

    UITextField *iconField = [cell.contentView viewWithTag:61];
    UIImageView *preview = [cell.contentView viewWithTag:63];

    switch (indexPath.section == 0 ? indexPath.row : 4) {
        case 0: {
            // 第1行：类型（只读）。
            cell.textLabel.text = @"类型";
            cell.detailTextLabel.text = ERLinkTypeDisplay(entry);
            cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.imageView.image = nil;
            cell.accessoryView = nil;
            break;
        }
        case 1: {
            // 第2行：名称（点击弹窗改名 → 暂存，保存生效）。
            cell.textLabel.text = @"名称";
            NSString *name = [_pendingName length] ? _pendingName
                            : ([entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"");
            cell.detailTextLabel.text = name.length ? name : @"未命名";
            cell.detailTextLabel.textColor = UIColor.labelColor;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.imageView.image = nil;
            cell.accessoryView = nil;
            break;
        }
        case 2: {
            // 第3行：图标（名称在左，输入框放大，预览在最右）。
            cell.textLabel.text = @"图标";
            NSString *override = entry[@"symbolOverride"];
            if (_pendingSymbolSet) override = _pendingSymbol;
            NSString *current = [override isKindOfClass:[NSString class]] ? override : @"";
            if (!current.length) {
                NSString *kind = [entry[@"iconKind"] isKindOfClass:[NSString class]] ? entry[@"iconKind"] : @"";
                if ([kind isEqualToString:@"symbol"]) {
                    current = [entry[@"iconValue"] isKindOfClass:[NSString class]] ? entry[@"iconValue"] : @"";
                }
            }
            iconField.text = current;
            // 1.1.9-67：预览实时反映未保存的图标（暂存值合成临时条目再渲染）。
            NSMutableDictionary *previewEntry = [entry mutableCopy] ?: [NSMutableDictionary dictionary];
            if (_pendingSymbolSet) {
                if (_pendingSymbol.length) previewEntry[@"symbolOverride"] = _pendingSymbol;
                else [previewEntry removeObjectForKey:@"symbolOverride"];
            }
            preview.image = ERLinkCellIcon(previewEntry);
            cell.detailTextLabel.text = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.accessoryView = nil;
            break;
        }
        case 3: {
            // 第4行：选择快捷方式（只留名称与替换按钮；目标 id 不再显示）。
            cell.textLabel.text = @"选择快捷方式";
            cell.detailTextLabel.text = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.imageView.image = nil;
            // 替换按钮挂 accessoryView（1.1.9-62 里被后面的 nil 覆盖导致不显示，这里修掉）。
            // 1.1.9-64：样式与第3行「选择」一致（天气城市选择风、蓝色边框）。
            UIButton *replace = [cell.contentView viewWithTag:66];
            if (!replace) {
                replace = [UIButton buttonWithType:UIButtonTypeCustom];
                replace.tag = 66;
                replace.frame = CGRectMake(0.0, 0.0, 45.0, 29.0);
                [replace setTitle:@"替换" forState:UIControlStateNormal];
                replace.titleLabel.font = [UIFont systemFontOfSize:15.0];
                [replace setTitleColor:UIColor.systemBlueColor forState:UIControlStateNormal];
                replace.layer.cornerRadius = 6.0;
                replace.layer.borderWidth = 1.0;
                replace.layer.borderColor = UIColor.systemBlueColor.CGColor;
                replace.clipsToBounds = YES;
                [replace addTarget:self action:@selector(replaceTapped) forControlEvents:UIControlEventTouchUpInside];
            }
            cell.accessoryView = replace;
            break;
        }
        default:
            break;
    }
    return cell;
}

- (void)tableView:(__unused UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0 || indexPath.row != 1) return;
    [self renameTapped];
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"修改需点右上角「保存」才会生效；替换会保留原槽位位置。";
    return nil;
}

// MARK: 动作

// 第2行：改名（暂存，保存生效）。
- (void)renameTapped {
    NSDictionary *entry = [self entry];
    if (!entry) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"修改名称"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [_pendingName length] ? _pendingName
                   : ([entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"");
        field.placeholder = @"名称";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        UITextField *field = alert.textFields.firstObject;
        strongSelf->_pendingName = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [strongSelf refreshTitle];
        [strongSelf->_table reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 第3行「选择」按钮：进图标选择页（选择后暂存，保存生效）。
- (void)pickIconTapped {
    ERLinkIconPickerController *picker = [[ERLinkIconPickerController alloc] init];
    picker.pickerDelegate = self;
    picker.selectedSymbol = _iconField.text ?: @"";
    [self.navigationController pushViewController:picker animated:YES];
}

// 第3行输入框：手输符号名（暂存，保存生效；清空 = 恢复默认图标）。
- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField.tag != 61) return;
    _pendingSymbol = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _pendingSymbolSet = YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

// 右上角「保存」：把暂存的修改一次写入（名称/图标两处同步）。
- (void)saveTapped {
    [self.view endEditing:YES];
    if (!_pendingName.length && !_pendingSymbolSet) return;
    NSString *newName = _pendingName;
    NSString *newSymbol = _pendingSymbol;
    BOOL symbolSet = _pendingSymbolSet;
    if (symbolSet && newSymbol.length && ![UIImage systemImageNamed:newSymbol]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"符号不可用"
                                                                       message:[NSString stringWithFormat:@"系统里没有名为 %@ 的 SF 符号。", newSymbol]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self mutateEntry:^(NSMutableDictionary *updated) {
        if (newName.length) updated[@"name"] = newName;
        if (symbolSet) {
            if (newSymbol.length) {
                updated[@"symbolOverride"] = newSymbol;
            } else {
                [updated removeObjectForKey:@"symbolOverride"];
            }
        }
    }];
    _pendingName = nil;
    _pendingSymbol = nil;
    _pendingSymbolSet = NO;
    [self refreshTitle];
    [_table reloadData];
    ERLinkLog(@"customize: 保存 %@ name=%@ symbol=%@", _uuid, newName, symbolSet ? newSymbol : @"(unchanged)");
}

// 左下「恢复默认」：名称与图标还原到创建时的样式（清掉图标覆盖）。
- (void)restoreTapped {
    NSDictionary *entry = [self entry];
    if (!entry) return;
    NSString *defaultName = [entry[@"defaultName"] isKindOfClass:[NSString class]] ? entry[@"defaultName"] : @"";
    NSString *defaultKind = [entry[@"defaultIconKind"] isKindOfClass:[NSString class]] ? entry[@"defaultIconKind"] : @"";
    NSString *defaultValue = [entry[@"defaultIconValue"] isKindOfClass:[NSString class]] ? entry[@"defaultIconValue"] : @"";
    if (!defaultName.length) {
        // 没有存档（老条目）：把当前值当存档，等效于只清掉图标覆盖。
        defaultName = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"";
        defaultKind = [entry[@"iconKind"] isKindOfClass:[NSString class]] ? entry[@"iconKind"] : @"";
        defaultValue = [entry[@"iconValue"] isKindOfClass:[NSString class]] ? entry[@"iconValue"] : @"";
    }
    NSString *name = defaultName;
    NSString *kind = defaultKind;
    NSString *value = defaultValue;
    [self mutateEntry:^(NSMutableDictionary *updated) {
        if (name.length) updated[@"name"] = name;
        if (kind.length) updated[@"iconKind"] = kind;
        if (value.length) updated[@"iconValue"] = value;
        [updated removeObjectForKey:@"symbolOverride"];
    }];
    _pendingName = nil;
    _pendingSymbol = nil;
    _pendingSymbolSet = NO;
    [self refreshTitle];
    [_table reloadData];
    ERLinkLog(@"customize: 恢复默认 %@", _uuid);
}

// 第4行「替换」按钮：复用添加流程（原位换目标，槽位不动）。
- (void)replaceTapped {
    ERLinkAddController *controller = [[ERLinkAddController alloc] initWithExisting:ERLinkStoredCatalog()];
    controller.replaceUUID = _uuid;
    controller.title = @"替换";
    [self.navigationController pushViewController:controller animated:YES];
}

// 右下「删除快捷动作」：确认后删除条目，控制中心磁贴由对账路径同步移除。
- (void)deleteTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除快捷动作"
                                                                   message:@"子页面与控制中心磁贴都会被删除。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf deleteEntry];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteEntry {
    NSMutableArray<NSDictionary *> *remaining = [NSMutableArray array];
    for (NSDictionary *entry in ERLinkStoredCatalog()) {
        if ([entry[@"uuid"] isKindOfClass:[NSString class]] &&
            [entry[@"uuid"] isEqualToString:_uuid]) {
            NSString *iconFile = [entry[@"iconFile"] isKindOfClass:[NSString class]] ? entry[@"iconFile"] : @"";
            if (iconFile.length) {
                [[NSFileManager defaultManager] removeItemAtPath:ERLinkLocalImagePath(iconFile) error:nil];
            }
            continue;
        }
        [remaining addObject:entry];
    }
    ERLinkPersistCatalog(remaining);
    ERLinkLog(@"customize: 删除 %@", _uuid);
    // 1.1.9-65：删除后回到「快捷方式」子页面（列表页），而不是插件根页面。
    UINavigationController *nav = self.navigationController;
    for (NSInteger i = (NSInteger)nav.viewControllers.count - 1; i >= 0; i--) {
        UIViewController *vc = nav.viewControllers[(NSUInteger)i];
        if ([vc isKindOfClass:[ERLinkController class]]) {
            [nav popToViewController:vc animated:YES];
            return;
        }
    }
    [nav popViewControllerAnimated:YES];
}

// MARK: 数据变更

// 原位修改当前条目并持久化（子页面与控制中心同步）。
- (void)mutateEntry:(void (^)(NSMutableDictionary *updated))mutate {
    [self mutateEntryQuiet:mutate];
}

// 同 mutateEntry，但静默版本供首次存档用（行为一致，留名区分意图）。
- (void)mutateEntryQuiet:(void (^)(NSMutableDictionary *updated))mutate {
    NSMutableArray<NSDictionary *> *catalog = [ERLinkStoredCatalog() mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger index = 0; index < catalog.count; index++) {
        NSDictionary *entry = catalog[index];
        if (![entry[@"uuid"] isKindOfClass:[NSString class]] ||
            ![entry[@"uuid"] isEqualToString:_uuid]) continue;
        NSMutableDictionary *updated = [entry mutableCopy] ?: [NSMutableDictionary dictionary];
        if (mutate) mutate(updated);
        // 图标相关字段变了就重渲染成品 PNG（文件名不变，磁贴直接读新图）。
        NSString *file = ERLinkWriteRenderedIcon(updated);
        if (file) {
            updated[@"iconFile"] = file;
            updated[@"iconFull"] = @([ERLinkResolveIcon(updated)[@"full"] boolValue]);
        }
        catalog[index] = updated;
        break;
    }
    ERLinkPersistCatalog(catalog);
}

// MARK: ERLinkIconPickerDelegate

- (void)iconPickerDidPickSymbol:(NSString *)symbolName {
    _pendingSymbol = [symbolName isKindOfClass:[NSString class]] ? symbolName : @"";
    _pendingSymbolSet = YES;
    _iconField.text = _pendingSymbol;
    [_table reloadData];
}

@end
