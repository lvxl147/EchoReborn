// ============================================================================
// EchoRebornSource · 1.0.9-194 · 方案 B 源头拦截 · 诊断阶段
//
// 背景（v183-v193 十一个版本的终局定性）：
//   岛的黑底/外扩来自 CallAssist 渲染进程通过 CAPortalLayer 跨进程直绘屏幕。
//   SpringBoard 侧一切层属性（滤镜/裁剪/hidden/摘除）物理上作用不到它的像素
//   （v191 混合 97 次挂稳无效），连 removeFromSuperlayer 都会炸 SpringBoard
//   （v192 SIGSEGV 安全模式循环）。本地消费者侧路线终结。
//
//   生产者侧（源进程）从未动过刀。本 dylib 注入所有 UIKit 进程
//   （EchoRebornSource.plist: Filter = com.apple.UIKit，与上游 Liquidify 同款
//   宽匹配），只做两件事，全程被动、零 hook：
//
//   1. ERSRC-LOAD：每个进程加载时输出 进程名/bundle ID/pid —— 锁定到底是谁
//      在渲染岛内容（CallAssist 的 widget 扩展？app 本体？独立 daemon？）。
//   2. ERSRC-PROBE：非系统进程内每 10s 扫一遍窗口树，输出：
//      · 近黑不透明背景层（backgroundColor 直接命中 → v195 清背景色即可治本）
//      · 进程内与岛相关的类（类名含 CallAssist/SAUI/Island/LiveActivity）
//      → 用户触发岛（充电/来电）时，哪个进程冒出黑底层，源头就是谁。
//
// 为什么是第四支独立 dylib（照抄 DualCam 的隔离理由）：
//   主 EchoReborn.dylib 里是 1.18MB 的 Tweak.xm + Soko + LiquidSiri + GlassKit，
//   一整套只对 SpringBoard/控制中心成立的 hook。注入第三方渲染进程等于让陌生
//   进程承担无关的崩溃面。这里只带纯诊断代码，崩溃风险为零（无 hook、无 swizzle，
//   唯一动作是只读遍历 + 追加日志）。
//
// 日志为什么另开文件（/var/mobile/Documents/EchoReborn-src.log）：
//   主日志目录 /var/mobile/Library/Logs/EchoReborn 由主 dylib 在 SpringBoard
//   使用；第三方进程的沙盒/容器对它不保证可写。Documents 对 mobile 组可写，
//   用户用 Filza 也能直接取文件，诊断期先用它。
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// 日志：追加式单文件，512KB 上限砍半，与主日志同一节流哲学但独立实现
//（不能复用主 dylib 的 ERLogMessage —— 本 dylib 与主 dylib 在 SpringBoard
// 里共存，符号冲突风险为零（static），但代码必须自含）
// ---------------------------------------------------------------------------
static NSString *const kERSrcLogPath = @"/var/mobile/Documents/EchoReborn-src.log";
static NSInteger const kERSrcLogMaxBytes = 512 * 1024;

// v196 · 每行日志带进程标签：v195 真机日志多进程交错写同一文件，
// 没有 [进程] 标签无法归因（心跳行到底是 Spotlight 还是 Batteries？）
static NSString *gERSrcProcTag = @"";

static void ERSrcLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ERSrcLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"%@ [SRC][%@] %@",
                      [fmt stringFromDate:[NSDate date]], gERSrcProcTag, msg];

    // 追加一行；失败静默（诊断代码绝不拖垮宿主进程）
    @try {
        NSFileManager *files = [NSFileManager defaultManager];
        NSDictionary *attr = [files attributesOfItemAtPath:kERSrcLogPath error:nil];
        NSUInteger size = attr ? [attr fileSize] : 0;
        if (size > (NSUInteger)kERSrcLogMaxBytes) {
            NSString *old = [NSString stringWithContentsOfFile:kERSrcLogPath encoding:NSUTF8StringEncoding error:nil];
            if (old.length) {
                NSArray<NSString *> *lines = [old componentsSeparatedByString:@"\n"];
                if (lines.count > 2) {
                    NSString *kept = [[lines subarrayWithRange:NSMakeRange(lines.count / 2, lines.count - lines.count / 2)]
                                      componentsJoinedByString:@"\n"];
                    [kept writeToFile:kERSrcLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }
        }
        line = [line stringByAppendingString:@"\n"];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kERSrcLogPath];
        if (!h) {
            [line writeToFile:kERSrcLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (__unused NSException *e) {
        // 诊断日志失败不影响宿主
    }
}

// ---------------------------------------------------------------------------
// 进程身份：进程名 + bundle ID + pid
// ---------------------------------------------------------------------------
static NSString *ERSrcBundleID(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length) return bid;
    return @"(无bundle)";
}

// 系统进程白名单：这些是主 dylib 的地盘或纯系统 UI，不跑探针（避免噪音）
static BOOL ERSrcIsKnownSystemProcess(NSString *name) {
    NSArray<NSString *> *known = @[
        @"SpringBoard", @"backboardd", @"Camera", @"Camara",
        @"SiriInference", @"SiriViewService", @"NanoPrefs",
        @"Preferences", @"Sileo", @"Filza", @"Zebra",
    ];
    for (NSString *k in known) {
        if ([name isEqualToString:k]) return YES;
    }
    return NO;
}

// ---------------------------------------------------------------------------
// 探针 1：进程内与岛相关的类（一次扫描，加载时输出）
// 类名含 CallAssist / SAUI / Island / LiveActivity / ActivityKit 关键字
// ---------------------------------------------------------------------------
static void ERSrcScanClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    NSArray<NSString *> *keys = @[@"CallAssist", @"SAUI", @"Island", @"LiveActivity",
                                  @"LiveActivityKit", @"Portal", @"Widget"];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < count && hits.count < 24; i++) {
        NSString *cn = NSStringFromClass(classes[i]);
        for (NSString *k in keys) {
            if ([cn containsString:k]) { [hits addObject:cn]; break; }
        }
    }
    free(classes);
    if (hits.count) {
        ERSrcLog(@"ERSRC-CLASSES 命中 %ld: %@", (long)hits.count, [hits componentsJoinedByString:@", "]);
    } else {
        ERSrcLog(@"ERSRC-CLASSES 无岛相关类");
    }
}

// ---------------------------------------------------------------------------
// 探针 2：近黑不透明背景层扫描（每 10s，限 12 行/轮）
// 判定：backgroundColor 存在、alpha ≥ 0.9、RGB 全 ≤ 0.06（近似纯黑底）
// 这是 v195 的靶子：源进程里清掉它，穿透层直绘的内容就天生没有黑
// ---------------------------------------------------------------------------
static NSInteger ERSrcNearBlackLayer(CGColorRef c) {
    if (!c) return 0;
    size_t n = CGColorGetNumberOfComponents(c);
    if (n < 2) return 0;
    const CGFloat *comp = CGColorGetComponents(c);
    CGFloat a = comp[n - 1];
    if (a < 0.9) return 0;
    CGFloat r = comp[0], g = (n >= 3 ? comp[1] : r), b = (n >= 3 ? comp[2] : r);
    return (r <= 0.06 && g <= 0.06 && b <= 0.06) ? 1 : 0;
}

static void ERSrcProbe(void) {
    // v195 · 1.0.9-195 修复：任何路径都必须出心跳行。v194 的实现里
    // "UIApplication 取不到 → windows 空 → 提前 return" 是静默的，异常也被
    // @catch 静默吞掉 —— 真机上 Spotlight 进程加载后一行心跳都没有，无法
    // 区分"没窗口"还是"探针没跑"。现在：心跳恒输出，异常带原因输出。
    @try {
        NSArray<UIWindow *> *windows = nil;
        UIApplication *app = [UIApplication sharedApplication];
        if (app) {
            NSMutableArray<UIWindow *> *ws = [NSMutableArray array];
            if (@available(iOS 13.0, *)) {
                for (UIScene *s in app.connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]]) {
                        [ws addObjectsFromArray:((UIWindowScene *)s).windows];
                    }
                }
            } else {
                [ws addObjectsFromArray:app.windows];
            }
            windows = ws;
        } else {
            windows = @[];
        }

        NSInteger black = 0, walked = 0, logged = 0;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:windows];
        while (stack.count && walked < 3000) {
            UIView *vv = stack.lastObject;
            [stack removeLastObject];
            if (!vv) continue;
            walked++;
            if (ERSrcNearBlackLayer(vv.layer.backgroundColor)) {
                black++;
                if (logged < 12) {
                    logged++;
                    ERSrcLog(@"ERSRC-PROBE 黑底层 类=%@ frame=%@ window=%@",
                             NSStringFromClass(vv.class), NSStringFromCGRect(vv.frame),
                             NSStringFromClass(vv.window.class));
                }
            }
            [stack addObjectsFromArray:vv.subviews];
        }
        // 无黑底也要报心跳（哪个进程在岛出现时始终干净，同样是排除证据）
        if (!app && walked == 0) {
            ERSrcLog(@"ERSRC-PROBE 无UIApplication 心跳 窗口0");
        } else {
            ERSrcLog(@"ERSRC-PROBE 心跳 窗口 %lu 遍历 %ld 黑底 %ld",
                     (unsigned long)windows.count, (long)walked, (long)black);
        }
    } @catch (NSException *e) {
        // v195 · 异常不再静默：带原因出日志，方便定位探针自身的环境问题
        ERSrcLog(@"ERSRC-PROBE 异常 %@ 原因=%@", e.name, e.reason ?: @"(空)");
    }
}

// NSTimer target 用类对象，避免持有实例循环
@interface ERSrcProbeTarget : NSObject
+ (void)tick;
@end

// ---------------------------------------------------------------------------
// v196 · CALayer 层级黑底捕获（武器升级）
//
// v195 真机日志定性：岛内容由 widget 扩展进程渲染（BatteriesAvocadoWidget-
// Extension 在每次岛触发时刻恰好加载），而组件扩展是 SwiftUI 渲染——没有
// UIApplication、没有 UIKit 窗口，UIView 窗口树探针在它体内永远打空
// （日志实锤"无UIApplication 心跳 窗口0"）。
//
// 换武器：hook CALayer 的 setBackgroundColor:/setContents:。这是所有渲染
// 路径（UIKit/SwiftUI/CoreAnimation）设置像素的必经点，层树里"黑底"无处
// 可逃。降噪三闸门：① 只报近黑不透明背景 / ≥100x40 位图内容；② 层 bounds
// ≥50x20（岛内容尺度）；③ 同一 (类名,尺寸) 键 30s 去重。
// ---------------------------------------------------------------------------
static BOOL ERSrcShouldLog(NSString *key) {
    static NSMutableDictionary<NSString *, NSDate *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableDictionary dictionary]; });
    @synchronized (seen) {
        NSDate *now = [NSDate date];
        NSDate *last = seen[key];
        if (last && [now timeIntervalSinceDate:last] < 30.0) return NO;
        seen[key] = now;
        return YES;
    }
}

%group ERSrcLayerHooks

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    %orig;
    @try {
        if (!ERSrcNearBlackLayer(color)) return;
        CGRect b = self.bounds;
        if (b.size.width < 50.0 || b.size.height < 20.0) return;
        NSString *cls = [self.delegate class] ? NSStringFromClass([self.delegate class]) : NSStringFromClass([self class]);
        NSString *key = [NSString stringWithFormat:@"BG|%@|%.0fx%.0f", cls, b.size.width, b.size.height];
        if (ERSrcShouldLog(key)) {
            ERSrcLog(@"ERSRC-LAYER 黑底 委托=%@ layer=%@ bounds=%@",
                     cls, NSStringFromClass([self class]), NSStringFromCGRect(b));
        }
    } @catch (__unused NSException *e) {
        // 诊断绝不拖垮宿主
    }
}

- (void)setContents:(id)contents {
    %orig;
    @try {
        if (!contents) return;
        // v196b · CFGetTypeRef 在 Theos 16.5 SDK 的模块展开下不可见（CI 两次
        // 实锤），改用 runtime 类名判断 —— CGImage 的 ObjC 类名就是 "CGImage"
        if (strcmp(object_getClassName(contents), "CGImage") != 0) return;
        CGRect b = self.bounds;
        if (b.size.width < 50.0 || b.size.height < 20.0) return;
        CGImageRef img = (__bridge CGImageRef)contents;
        CGFloat iw = (CGFloat)CGImageGetWidth(img), ih = (CGFloat)CGImageGetHeight(img);
        if (iw < 100.0 || ih < 40.0) return;
        NSString *cls = [self.delegate class] ? NSStringFromClass([self.delegate class]) : NSStringFromClass([self class]);
        NSString *key = [NSString stringWithFormat:@"IMG|%@|%.0fx%.0f", cls, iw, ih];
        if (ERSrcShouldLog(key)) {
            ERSrcLog(@"ERSRC-LAYER 位图 委托=%@ layer=%@ bounds=%@ img=%.0fx%.0f",
                     cls, NSStringFromClass([self class]), NSStringFromCGRect(b), iw, ih);
        }
    } @catch (__unused NSException *e) {
        // 诊断绝不拖垮宿主
    }
}
%end

%end

// ---------------------------------------------------------------------------
%ctor {
    @autoreleasepool {
        NSString *name = [[NSProcessInfo processInfo] processName] ?: @"(unknown)";
        gERSrcProcTag = name;
        ERSrcLog(@"ERSRC-LOAD 进程=%@ bundle=%@ pid=%d",
                 name, ERSrcBundleID(), [[NSProcessInfo processInfo] processIdentifier]);
        ERSrcScanClasses();

        // v197 · 层捕获挂全量（含白名单进程）：v196 真机复盘——最可疑的
        // 渲染者 BatteriesAvocadoWidgetExtension 是 v195 时代启动的幸存进程，
        // 体内只有旧 UIView 探针（对 SwiftUI 盲），没等到 v196 的层 hook；
        // 白名单进程（SpringBoard/Sileo 等）也未挂。任何进程都可能漏网。
        // 层捕获有三闸门降噪（近黑不透明/≥100x40 位图/30s 去重），全量挂
        // 无性能之忧；探针/计时器仍只跑非白名单。
        %init(ERSrcLayerHooks);
        ERSrcLog(@"ERSRC-HOOKS CALayer 黑底/位图捕获已挂载");

        if (ERSrcIsKnownSystemProcess(name)) {
            ERSrcLog(@"ERSRC-LOAD 系统进程白名单，探针不启动");
            return;
        }

        // 每 10s 一轮探针；主线程串行，遍历有 3000 节点上限，最坏 ~1ms 量级
        dispatch_async(dispatch_get_main_queue(), ^{
            // v195 · 计时器落地确认：主 runloop 上是否真的跑起来，一眼可查
            ERSrcLog(@"ERSRC-TIMER 主队列块已执行，计时器启动");
            [NSTimer scheduledTimerWithTimeInterval:10.0
                                             target:[ERSrcProbeTarget class]
                                           selector:@selector(tick)
                                           userInfo:nil
                                            repeats:YES];
        });
    }
}

@implementation ERSrcProbeTarget
+ (void)tick {
    @autoreleasepool {
        @try {
            ERSrcProbe();
        } @catch (__unused NSException *e) {
            // 探针异常静默：诊断代码绝不拖垮宿主进程
        }
    }
}
@end
