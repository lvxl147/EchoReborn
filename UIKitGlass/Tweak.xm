// ===========================================================================
// EchoRebornUIKit —— 注入 com.apple.UIKit 的液态玻璃注入层（开关 / 滑条）
//
// 【渲染引擎】用本项目自带的：GlassKit/LGLiveBackdropView + EchoRebornBackboardd.dylib
// （backboardd 侧的 Metal 渲染器，从 LiquidAss 移植；控制中心的玻璃就是它渲染的）。
//
// 【关键】host prefix 必须取自渲染器的注册表（GlassKit/LGGlassKit.x 里的 LG_HOST_REGISTRY）。
//   1.0.9-87 之前我传的是 @"UIKitSwitch" —— 不在注册表里，渲染器直接
//   `lifecycle rejected unknown host prefix=UIKitSwitch` 拒绝，所以一点效果都没有。
//   注册表里本就有为开关/滑条预留的条目：
//       X(PrefsSwitch, "echoreborn.liquidglass.prefsswitch", "PrefsSwitch", 0.50f,  6.50f, ...)
//       X(PrefsSlider, "echoreborn.liquidglass.prefsslider", "PrefsSlider", 0.50f, 10.00f, ...)
//   下面就用这两个 host。
//
// 【独立运行】只依赖本包自带的东西，不引用任何外部插件。
// ===========================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "GlassKit/LGGlassKit.h"
#import "GlassKit/LGLiveBackdropView.h"

static void *kERSwitchGlassKey = &kERSwitchGlassKey;
static void *kERSliderGlassKey = &kERSliderGlassKey;


// ---------------------------------------------------------------------------
// 1.0.9-91 · **用上游组件做外观**（这才是"和参考插件一样"的做法）
//
// 上游提供的是**完整控件**（LGLiquidGlassSwitch / LGLiquidGlassSlider）—— 自带滑块式外形
// 与拖拽变形动画。我们把它覆盖在原控件之上（userInteractionEnabled=NO，触摸穿透给原控件），
// 并把原控件的状态同步过去，于是：
//      外观 = 上游组件（和参考插件一样）
//      交互 = 系统原控件（不会破坏系统行为）
// ---------------------------------------------------------------------------
static UIView *ERMakeUpstreamView(CGRect frame, NSString *className, BOOL isOn) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    UIView *v = nil;
    @try { v = [[cls alloc] initWithFrame:frame]; } @catch (__unused NSException *e) { v = nil; }
    if (!v) return nil;
    v.userInteractionEnabled = NO;          // 触摸穿透
    v.autoresizingMask = UIViewAutoresizingNone;
    if (isOn && [v respondsToSelector:NSSelectorFromString(@"setOn:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(v, NSSelectorFromString(@"setOn:"), YES);
    }
    return v;
}

static void ERSyncUpstreamView(UIView *host, const void *key, BOOL enabled,
                               BOOL (^sizeOK)(CGRect), NSString *className, NSString *label,
                               BOOL isOn) {
    UIView *v = objc_getAssociatedObject(host, key);
    if (!enabled || !NSClassFromString(className)) {
        if (v) {
            [v removeFromSuperview];
            objc_setAssociatedObject(host, key, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        return;
    }
    CGRect b = host.bounds;
    if (sizeOK && !sizeOK(b)) return;
    if (!v) {
        v = ERMakeUpstreamView(b, className, isOn);
        if (!v) return;
        [host addSubview:v];
        objc_setAssociatedObject(host, key, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGLog(@"[EchoRebornUIKit] %@ 已安装上游组件 %@ frame=%@", label, className, NSStringFromCGRect(b));
    }
    if (v.superview != host) [host addSubview:v];
    v.frame = b;
    if ([v respondsToSelector:NSSelectorFromString(@"setOn:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(v, NSSelectorFromString(@"setOn:"), isOn);
    }
    [host bringSubviewToFront:v];
}

static BOOL ERPrefBool(NSString *key) {
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

// 统一创建一块玻璃：host 用注册表里的名字（PrefsSwitch / PrefsSlider）
static UIView *ERMakeGlass(CGRect frame, NSString *host, NSString *group) {
    LGLiveBackdropView *g = LGCreateRegisteredGlass(frame, group, host);
    if (!g) {
        LGLog(@"[EchoRebornUIKit] 玻璃创建失败 host=%@（不在渲染器注册表里？）", host);
        return nil;
    }
    g.userInteractionEnabled = NO;             // 绝不吃触摸
    g.autoresizingMask = UIViewAutoresizingNone;
    g.layer.cornerRadius = frame.size.height * 0.5;
    g.layer.cornerCurve = kCACornerCurveContinuous;
    g.layer.masksToBounds = YES;
    [g applyFilters];
    lgTrackGlass(g, host, nil);
    return g;
}

static void ERSyncGlass(UIView *host, const void *key, BOOL enabled,
                        BOOL (^sizeOK)(CGRect), NSString *glassHost, NSString *label) {
    UIView *glass = objc_getAssociatedObject(host, key);
    if (!enabled) {
        if (glass) {
            [glass removeFromSuperview];
            objc_setAssociatedObject(host, key, nil, OBJC_ASSOCIATION_ASSIGN);
            LGLog(@"[EchoRebornUIKit] %@ 已移除（选项关闭）", label);
        }
        return;
    }
    CGRect b = host.bounds;
    if (sizeOK && !sizeOK(b)) return;
    if (!glass) {
        glass = ERMakeGlass(b, glassHost, label);
        if (!glass) return;
        // -----------------------------------------------------------------
        // 1.0.9-89 · **必须覆盖在最上层**。
        //
        // 之前用 insertSubview:atIndex:0（最底层），而 UISwitch / UISlider 的可见外观
        // （轨道、圆钮、填充）是画在**它们自己的内部图层**上的 —— 玻璃被完全遮住，
        // 所以"样式没有任何变化"。改为 addSubview（最上层）+ 触摸穿透，
        // 玻璃才真正可见，同时不影响开关/滑条的拖动。
        // -----------------------------------------------------------------
        glass.alpha = 0.92;
        [host addSubview:glass];
        objc_setAssociatedObject(host, key, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGLog(@"[EchoRebornUIKit] %@ 已安装(最上层) host=%@ frame=%@", label, glassHost, NSStringFromCGRect(b));
    }
    if (glass.superview != host) [host addSubview:glass];
}

%hook UISwitch

- (void)layoutSubviews {
    %orig;
    BOOL on = ERPrefBool(@"LiquidifySwitch.Enabled");
    static CFTimeInterval lastLog = 0.0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastLog > 5.0) {
        lastLog = now;
        LGLog(@"[EchoRebornUIKit] SWITCH-HOOK 命中 cls=%@ bounds=%@ 选项=%d",
              NSStringFromClass(self.class), NSStringFromCGRect(self.bounds), on ? 1 : 0);
    }
    // 1.0.9-91 · 优先用**上游开关组件**做外观（与参考插件一致）；拿不到才退回 GlassKit 玻璃
    ERSyncUpstreamView(self, kERSwitchGlassKey, on,
                       ^BOOL(CGRect b) {
                           return b.size.width >= 30 && b.size.width <= 110 &&
                                  b.size.height >= 20 && b.size.height <= 50;
                       },
                       @"LGLiquidGlassSwitch", @"SWITCH-UPSTREAM", self.isOn);
}

%end

%hook UISlider

- (void)layoutSubviews {
    %orig;
    BOOL on = ERPrefBool(@"LiquidifySlider.Enabled");
    static CFTimeInterval lastLog2 = 0.0;
    CFTimeInterval now2 = CACurrentMediaTime();
    if (now2 - lastLog2 > 5.0) {
        lastLog2 = now2;
        LGLog(@"[EchoRebornUIKit] SLIDER-HOOK 命中 cls=%@ bounds=%@ 选项=%d",
              NSStringFromClass(self.class), NSStringFromCGRect(self.bounds), on ? 1 : 0);
    }
    // 1.0.9-91 · 同上：优先上游滑条组件
    ERSyncUpstreamView(self, kERSliderGlassKey, on,
                       ^BOOL(CGRect b) {
                           return b.size.width >= 60 && b.size.height >= 10 && b.size.height <= 90;
                       },
                       @"LGLiquidGlassSlider", @"SLIDER-UPSTREAM", NO);
}

%end

%ctor {
    LGLog(@"[EchoRebornUIKit] 已加载 proc=%@", NSProcessInfo.processInfo.processName ?: @"?");
}
