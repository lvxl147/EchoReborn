// ===========================================================================
// EchoRebornUIKit —— 注入 com.apple.UIKit 的玻璃子 dylib
//
// 为什么单独一支（而不是塞进主 dylib）：
//   主 dylib 的 Filter 只覆盖 SpringBoard / PosterBoard / Siri 系进程；而"开关/滑条"
//   出现在**任意 App**（设置、控制中心之外的界面等）。上游 Liquidify 的做法就是把
//   渲染器放进一个 Filter = com.apple.UIKit 的 dylib（= 所有加载 UIKit 的进程），
//   渲染层因此随处可用 —— 这里照抄这个结构。
//
// 渲染来自上游开源库 LiquidGlassKit（MIT，DnV1eX）：
//   LiquidGlassView（MTKView + Metal 折射着色器）/ LiquidGlassSwitch / LiquidGlassSlider
//
// 本版只做**最小接入**：把玻璃视图作为背景叠加到系统开关/滑条上，开关默认关闭
// （偏好键 LiquidifySwitch.Enabled / LiquidifySlider.Enabled，见设置页对应卡片）。
// 叠加而不是"替换控件"是刻意的低风险选择：不动系统控件的交互与状态。
// ===========================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import "GlassKit/LGGlassKit.h"
#import "GlassKit/LGLiveBackdropView.h"

// Swift 侧导出的类（module = EchoRebornUIKit，因此类名为 EchoRebornUIKit.LiquidGlassView 等）
// 用 NSClassFromString 运行时取，避免编译期依赖 Swift 生成的 ObjC 头。
// 1.0.9-83 · **不再使用上游的 LiquidGlassView**。
//
// 上一版（-81）闪退的根因：用 `?:` 去猜类名，命中了设备上另一个液态玻璃插件的同名类，
// 那个实现依赖它自己的资源包，拿不到就 Swift trap（EXC_BREAKPOINT，@try 抓不住）。
// 现在改用**本项目自己的 GlassKit 玻璃管线**（LGLiveBackdropView），它：
//   · 与 SpringBoard 侧的控制中心玻璃是同一套实现（已在设备上长期验证）
//   · 渲染由 backboardd 侧的 EchoRebornBackboardd.dylib 全局提供，任何进程都可用
//   · 完全不引用外部插件的任何类
// 1.0.9-84 · **首选上游 LiquidGlassView（它的源代码就在我们这支 dylib 里）**，
// GlassKit 仅作兜底。
//
// 与 1.0.9-81 的关键区别：那次崩溃是"用 `?:` 猜类名"命中了**别的插件**的同名类；
// 现在**只查我们自己的 module 前缀**（EchoRebornUIKit.*），并校验是 UIView 子类，
// 命中不了就退到 GlassKit —— 绝不再引用外部插件的实现。
// 1.0.9-86 · **上游组件的真实类名**（从它 dylib 的 __objc_classname 提取，已核对）：
//   LGLiquidGlassView      玻璃容器（灵动岛 / 锁屏时间用）
//   LGLiquidGlassSwitch    开关组件（滑块式，拇指收缩↔展开）
//   LGLiquidGlassSlider    滑条组件（边缘回弹 + 触感）
//   LGLiquidLensView       透镜组件
//   LGLiquidGlassRenderer  渲染器
//
// 这些类由**随本包一起安装**的 LiquidGlassKeyboard.dylib 提供（我们直接用了它编译好的
// 二进制 —— 同一份源码在我们环境重编会在运行期 Swift trap）。所以本项目**独立运行**：
// 不依赖设备上是否装了别的插件。
static Class ERUpstreamClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (c && [c isSubclassOfClass:[UIView class]]) return c;
    return nil;
}

static void ERProbeUpstreamComponents(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *names = @[@"LGLiquidGlassView", @"LGLiquidGlassSwitch",
                                       @"LGLiquidGlassSlider", @"LGLiquidLensView",
                                       @"LGLiquidGlassRenderer", @"LGLiquidGlassEffectView",
                                       @"LGBackdropView", @"LGShadowView", @"LGZeroCopyBridge"];
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        for (NSString *n in names) {
            Class c = NSClassFromString(n);
            [rows addObject:[NSString stringWithFormat:@"%@=%@", n, c ? @"有" : @"无"]];
        }
        LGLog(@"[EchoRebornUIKit] 上游组件类: %@", [rows componentsJoinedByString:@" "]);
    });
}

static BOOL ERGlassPrefBool(NSString *key) {
    if (!key.length) return NO;
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    CFSTR("com.strive.echoreborn.preferences"));
    BOOL on = NO;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID() || CFGetTypeID(v) == CFNumberGetTypeID())
            on = [(__bridge NSNumber *)v boolValue];
        CFRelease(v);
    }
    return on;
}

static void *kERSwitchGlassKey = &kERSwitchGlassKey;
static void *kERSliderGlassKey = &kERSliderGlassKey;

// 创建一块玻璃视图（失败返回 nil，绝不抛异常到系统）
static UIView *ERMakeGlass(CGRect frame, CGFloat cornerRadius, NSString *group) {
    // 优先：上游 LiquidGlassView（Metal 折射玻璃，着色器源码内嵌、运行时编译）
    Class up = ERUpstreamGlassClass();
    if (up) {
        UIView *v = nil;
        @try {
            v = [[up alloc] initWithFrame:frame];
        } @catch (__unused NSException *e) { v = nil; }
        if (v) {
            v.userInteractionEnabled = NO;
            v.autoresizingMask = UIViewAutoresizingNone;
            v.layer.cornerRadius = cornerRadius;
            v.layer.cornerCurve = kCACornerCurveContinuous;
            v.layer.masksToBounds = YES;
            return v;
        }
        LGLog(@"[EchoRebornUIKit] LiquidGlassView 创建失败，改用 GlassKit");
    }
    // 兜底：本项目 GlassKit 管线
    LGLiveBackdropView *glass = LGCreateRegisteredGlass(frame, nil, group);
    if (!glass) return nil;
    glass.userInteractionEnabled = NO;
    glass.autoresizingMask = UIViewAutoresizingNone;
    glass.layer.cornerRadius = cornerRadius;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];
    lgTrackGlass(glass, group, nil);
    return glass;
}

%hook UISwitch

- (void)layoutSubviews {
    %orig;
    if (!ERGlassPrefBool(@"LiquidifySwitch.Enabled")) {
        UIView *old = objc_getAssociatedObject(self, kERSwitchGlassKey);
        if (old) { [old removeFromSuperview]; objc_setAssociatedObject(self, kERSwitchGlassKey, nil, OBJC_ASSOCIATION_ASSIGN); }
        return;
    }
    CGRect b = self.bounds;
    // 只处理"看起来是正常开关"的实例（宽 40~90、高 20~45），避免误伤特殊场景
    if (b.size.width < 40 || b.size.width > 90 || b.size.height < 20 || b.size.height > 45) return;

    // 1.0.9-83 · 用本项目自己的 GlassKit 管线创建玻璃（不再触碰上游实现）
    // 1.0.9-86 · 上游渲染器已随本包安装（自带 shader）。本版先做**只读探针**：
    // 确认能拿到它的组件类，再在下一版把玻璃真正接上去（避免又一次闪退）。
    ERProbeUpstreamComponents();
    static CFTimeInterval lastLog = 0.0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastLog > 5.0) {
        lastLog = now;
        LGLog(@"[EchoRebornUIKit] SWITCH-HOOK 命中 cls=%@ bounds=%@ 上游开关组件=%@",
              NSStringFromClass(self.class), NSStringFromCGRect(b),
              ERUpstreamClass(@"LGLiquidGlassSwitch") ? @"有" : @"无");
    }
%end

%hook UISlider

- (void)layoutSubviews {
    %orig;
    if (!ERGlassPrefBool(@"LiquidifySlider.Enabled")) {
        UIView *old = objc_getAssociatedObject(self, kERSliderGlassKey);
        if (old) { [old removeFromSuperview]; objc_setAssociatedObject(self, kERSliderGlassKey, nil, OBJC_ASSOCIATION_ASSIGN); }
        return;
    }
    CGRect b = self.bounds;
    if (b.size.width < 80 || b.size.height < 10 || b.size.height > 90) return;  // 只处理"像滑条"的
    // 1.0.9-83 · 同上：滑条也用 GlassKit 玻璃
    // 1.0.9-86 · 同上：只读探针
    static CFTimeInterval lastLog2 = 0.0;
    CFTimeInterval now2 = CACurrentMediaTime();
    if (now2 - lastLog2 > 5.0) {
        lastLog2 = now2;
        LGLog(@"[EchoRebornUIKit] SLIDER-HOOK 命中 cls=%@ bounds=%@ 上游滑条组件=%@",
              NSStringFromClass(self.class), NSStringFromCGRect(b),
              ERUpstreamClass(@"LGLiquidGlassSlider") ? @"有" : @"无");
    }
%end

%ctor {
    LGLog(@"[EchoRebornUIKit] 已加载 proc=%@", NSProcessInfo.processInfo.processName ?: @"?");
    ERProbeUpstreamComponents();
}
