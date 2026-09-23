// ===========================================================================
// EchoRebornUIKit —— 注入 com.apple.UIKit 的液态玻璃注入层
//
// 【独立运行】本包**自带**上游编译好的渲染器（Prebuilt/LiquidGlassKeyboard.dylib，
// shader 已内嵌在其中），因此**不依赖设备上是否装了别的液态玻璃插件**。
//
// 为什么用它的二进制而不是重编源码：同一份源码在我们环境（Swift 5 / iOS 16.5）编译后，
// 运行期会 Swift trap（实测 Preferences 闪退）；而它的成品在 iOS 17 上验证可用。
//
// 上游组件类（从它 dylib 的 __objc_classname 提取）：
//   LGLiquidGlassView / LGLiquidGlassSwitch / LGLiquidGlassSlider / LGLiquidLensView
//   LGLiquidGlassRenderer / LGBackdropView / LGShadowView / LGZeroCopyBridge
//
// 本版（1.0.9-86）= **只读探针**：确认注入成功、并能拿到上述组件类。
// 下一版据此把各功能分别接上（开关用 Switch、滑条用 Slider、灵动岛/锁屏时间用 View）。
// ===========================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "GlassKit/LGGlassKit.h"
#import "GlassKit/LGLiveBackdropView.h"

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
                                       @"LGLiquidGlassRenderer", @"LGBackdropView",
                                       @"LGShadowView", @"LGZeroCopyBridge"];
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        for (NSString *n in names) {
            [rows addObject:[NSString stringWithFormat:@"%@=%@", n, NSClassFromString(n) ? @"有" : @"无"]];
        }
        LGLog(@"[EchoRebornUIKit] 上游组件类: %@", [rows componentsJoinedByString:@" "]);
    });
}

%hook UISwitch

- (void)layoutSubviews {
    %orig;
    ERProbeUpstreamComponents();
    static CFTimeInterval lastLog = 0.0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastLog > 5.0) {
        lastLog = now;
        LGLog(@"[EchoRebornUIKit] SWITCH-HOOK 命中 cls=%@ bounds=%@ 开关组件=%@ 开关选项=%d",
              NSStringFromClass(self.class), NSStringFromCGRect(self.bounds),
              ERUpstreamClass(@"LGLiquidGlassSwitch") ? @"有" : @"无",
              ERPrefBool(@"LiquidifySwitch.Enabled") ? 1 : 0);
    }
}

%end

%hook UISlider

- (void)layoutSubviews {
    %orig;
    static CFTimeInterval lastLog2 = 0.0;
    CFTimeInterval now2 = CACurrentMediaTime();
    if (now2 - lastLog2 > 5.0) {
        lastLog2 = now2;
        LGLog(@"[EchoRebornUIKit] SLIDER-HOOK 命中 cls=%@ bounds=%@ 滑条组件=%@ 滑条选项=%d",
              NSStringFromClass(self.class), NSStringFromCGRect(self.bounds),
              ERUpstreamClass(@"LGLiquidGlassSlider") ? @"有" : @"无",
              ERPrefBool(@"LiquidifySlider.Enabled") ? 1 : 0);
    }
}

%end

%ctor {
    LGLog(@"[EchoRebornUIKit] 已加载 proc=%@", NSProcessInfo.processInfo.processName ?: @"?");
    ERProbeUpstreamComponents();
}
