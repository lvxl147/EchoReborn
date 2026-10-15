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

    if ([kind isEqualToString:@"app"]) {
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

// App 图标统一画进 40×40 圆角（与「创建链接」图标同尺寸，设置页所有行一致）。
static UIImage *ERLinkAppCellIcon(NSString *bundleId) {
    UIImage *appIcon = ERLinkAppIconImage(bundleId);
    if (!appIcon) return ERLinkGlyphTile(@"app.fill", 0xFF3B82F6LL);
    CGSize size = CGSizeMake(40.0, 40.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.0, 0.0, size.width, size.height)
                                                        cornerRadius:9.0];
        [path addClip];
        [appIcon drawInRect:CGRectMake(0.0, 0.0, size.width, size.height)];
    }];
}

// 以 App 维度造一条「打开 App」的快捷方式条目（详情页对号添加时用）。
static NSDictionary *ERLinkMakeAppEntry(NSString *bundleId, NSString *name) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"uuid"] = [[NSUUID UUID] UUIDString];
    entry[@"name"] = name.length ? name : bundleId;
    entry[@"type"] = @"app";
    entry[@"bundleId"] = bundleId ?: @"";
    entry[@"iconKind"] = @"app";
    entry[@"iconValue"] = bundleId ?: @"";
    // 底色：和快捷指令一样由条目自己带，这里给一个默认强调色。
    entry[@"color"] = @(0xFF3B82F6LL);
    NSString *file = ERLinkWriteRenderedIcon(entry);
    if (file) {
        entry[@"iconFile"] = file;
        entry[@"iconFull"] = @YES;
    }
    return entry;
}

// MARK: - 主页

@interface ERLinkAddController : PSViewController <UITableViewDataSource,
                                                    UITableViewDelegate,
                                                    UISearchBarDelegate,
                                                    UIDocumentPickerDelegate,
                                                    PHPickerViewControllerDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *existing;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSArray<NSDictionary *> *filtered;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *addTableView;
// 「添加链接」弹窗里正在编辑的那一份（从文件/相册导入图标时要用）
@property (nonatomic, strong) UIAlertController *pendingAlert;
@property (nonatomic, copy) NSString *pendingIconFile;
- (instancetype)initWithExisting:(NSArray<NSDictionary *> *)existing;
@end

// App 详情页：顶部第一行是 App 卡片（左图标 + 右名称），
// 与该 App 的快捷方式条目共用一张卡片；条目可点击打对号/取消对号。
@interface ERLinkAppDetailController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *appBundleId;
@property (nonatomic, copy) NSString *appName;
- (instancetype)initWithAppBundleId:(NSString *)bundleId name:(NSString *)name;
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
    self.title = @"快捷方式";
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
    NSString *detail = [entry[@"type"] isEqualToString:@"app"] ? entry[@"bundleId"] : entry[@"url"];
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

- (void)tableView:(__unused UITableView *)tableView didSelectRowAtIndexPath:(__unused NSIndexPath *)indexPath {
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
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *app in self.apps) {
        NSString *bundleId = app[@"bundleId"];
        NSString *name = app[@"name"];
        if (![bundleId isKindOfClass:[NSString class]] || !bundleId.length) continue;
        if (needle.length) {
            BOOL matched = ([name isKindOfClass:[NSString class]] && [name.lowercaseString containsString:needle]);
            if (!matched && [bundleId.lowercaseString containsString:needle]) matched = YES;
            if (!matched) continue;
        }
        [result addObject:app];
    }
    self.filtered = result;
}

// MARK: - 保存一条快捷方式

- (void)saveEntry:(NSDictionary *)entry {
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
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    // +1：第一行是「创建链接」
    return (NSInteger)self.filtered.count + 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return [NSString stringWithFormat:@"未添加（%lu）", (unsigned long)self.filtered.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ERLinkAddCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    if (indexPath.row == 0) {
        // 「创建链接」固定在搜索框下面第一行。
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
    NSUInteger index = (NSUInteger)indexPath.row - 1;
    if (index >= self.filtered.count) {
        cell.textLabel.text = @"没有可添加的 App";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = YES;
        return cell;
    }
    cell.userInteractionEnabled = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSDictionary *app = self.filtered[index];
    cell.textLabel.text = app[@"name"];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.text = app[@"bundleId"];
    cell.detailTextLabel.textColor = UIColor.labelColor;
    // 图标统一 40×40，和「创建链接」一致。
    cell.imageView.image = ERLinkAppCellIcon(app[@"bundleId"]);
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.clipsToBounds = YES;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        [self presentCreateLink];
        return;
    }
    NSUInteger index = (NSUInteger)indexPath.row - 1;
    if (index >= self.filtered.count) return;
    NSDictionary *app = self.filtered[index];
    // 点击 App → 进入该 App 的详情页，在详情页里打对号添加/取消。
    ERLinkAppDetailController *detail =
        [[ERLinkAppDetailController alloc] initWithAppBundleId:app[@"bundleId"]
                                                          name:app[@"name"]];
    [self.navigationController pushViewController:detail animated:YES];
}

@end

// MARK: - App 详情页

@implementation ERLinkAppDetailController
{
    UITableView *_detailTable;
}

- (instancetype)initWithAppBundleId:(NSString *)bundleId name:(NSString *)name {
    self = [super init];
    if (!self) return nil;
    _appBundleId = [bundleId isKindOfClass:[NSString class]] ? bundleId : @"";
    _appName = name.length ? name : _appBundleId;
    return self;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 480.0)];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 单个 section = 一张卡片：第一行 App 头部（图标左 + 名称右），
    // 第二行起是该 App 的快捷方式条目，可点击打对号。
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
}

// 该 App 当前是否已在目录里（决定对号显示）。
- (BOOL)appIsAdded {
    for (NSDictionary *entry in ERLinkStoredCatalog()) {
        if ([entry[@"type"] isEqualToString:@"app"] &&
            [entry[@"bundleId"] isKindOfClass:[NSString class]] &&
            [entry[@"bundleId"] isEqualToString:self.appBundleId]) return YES;
    }
    return NO;
}

// MARK: Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    // 第一行：App 头部；第二行：「打开 App」快捷方式。
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 0) {
        static NSString *headerId = @"ERLinkAppHeaderCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:headerId];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:headerId];
        cell.imageView.image = ERLinkAppCellIcon(self.appBundleId);
        cell.imageView.layer.cornerRadius = 9.0;
        cell.imageView.clipsToBounds = YES;
        cell.textLabel.text = self.appName;
        cell.textLabel.textColor = UIColor.labelColor;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = YES;
        return cell;
    }
    static NSString *toggleId = @"ERLinkAppToggleCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:toggleId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:toggleId];
    cell.textLabel.text = [NSString stringWithFormat:@"打开 %@", self.appName];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.accessoryType = [self appIsAdded] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor colorWithRed:0.11 green:0.60 blue:0.97 alpha:1.0];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.userInteractionEnabled = YES;
    return cell;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"点击「打开」即可添加为快捷方式，再次点击取消对号。";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row != 1) return;
    NSMutableArray<NSDictionary *> *catalog = [ERLinkStoredCatalog() mutableCopy] ?: [NSMutableArray array];
    if ([self appIsAdded]) {
        // 取消：移除该 App 的全部条目，顺手删渲染好的图标文件。
        NSMutableArray<NSDictionary *> *remaining = [NSMutableArray array];
        for (NSDictionary *entry in catalog) {
            BOOL match = [entry[@"type"] isEqualToString:@"app"] &&
                         [entry[@"bundleId"] isKindOfClass:[NSString class]] &&
                         [entry[@"bundleId"] isEqualToString:self.appBundleId];
            if (match) {
                NSString *uuid = entry[@"uuid"];
                if ([uuid isKindOfClass:[NSString class]] && uuid.length) {
                    [[NSFileManager defaultManager]
                        removeItemAtPath:ERLinkLocalImagePath([uuid stringByAppendingPathExtension:@"png"])
                                   error:nil];
                }
            } else {
                [remaining addObject:entry];
            }
        }
        ERLinkPersistCatalog(remaining);
        ERLinkLog(@"appDetail: 取消 %@", self.appBundleId);
    } else {
        [catalog addObject:ERLinkMakeAppEntry(self.appBundleId, self.appName)];
        ERLinkPersistCatalog(catalog);
        ERLinkLog(@"appDetail: 添加 %@", self.appBundleId);
    }
    [tableView reloadData];
}

@end
