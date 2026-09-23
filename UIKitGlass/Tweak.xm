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

// Swift 侧导出的类（module = EchoRebornUIKit，因此类名为 EchoRebornUIKit.LiquidGlassView 等）
// 用 NSClassFromString 运行时取，避免编译期依赖 Swift 生成的 ObjC 头。
static Class ERGlassViewClass(void) {
    static Class c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // -----------------------------------------------------------------
        // 1.0.9-82 · **只认我们自己的类**（不要把 fallback 交给别人）。
        //
        // 1.0.9-81 的崩溃正是这里引起的：原来的写法还会去查
        //   NSClassFromString(@"LiquidGlassKit.LiquidGlassView")
        //   NSClassFromString(@"LiquidGlassView")
        // 而设备上同时装着另一个液态玻璃插件（liquidass），它的渲染器也注入 UIKit，
        // 于是这两个 fallback 会命中**它的**同名类 —— 那个实现依赖它自己的资源，
        // 拿不到就直接 Swift trap（EXC_BREAKPOINT），把我们这条链路一起带走。
        // 现在只查我们自己的 module 前缀，找不到就彻底不做。
        // -----------------------------------------------------------------
        Class cls = NSClassFromString(@"EchoRebornUIKit.LiquidGlassView");
        if (cls && [cls isSubclassOfClass:[UIView class]]) c = cls;
        else NSLog(@"[EchoRebornUIKit] 未找到自己的 LiquidGlassView（不做玻璃，避免误用他人实现）");
    });
    return c;
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
static UIView *ERMakeGlass(CGRect frame, CGFloat cornerRadius) __attribute__((unused));
static UIView *ERMakeGlass(CGRect frame, CGFloat cornerRadius) {
    Class cls = ERGlassViewClass();
    if (!cls) return nil;
    UIView *v = nil;
    @try {
        v = [[cls alloc] initWithFrame:frame];
        if (!v) return nil;
        v.userInteractionEnabled = NO;          // 绝不吃触摸
        v.autoresizingMask = UIViewAutoresizingNone;
        v.layer.cornerRadius = cornerRadius;
        v.layer.cornerCurve = kCACornerCurveContinuous;
        v.layer.masksToBounds = YES;
        v.alpha = 0.85;
    } @catch (__unused NSException *e) { v = nil; }
    return v;
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

    // ---------------------------------------------------------------------
    // 1.0.9-82 · **暂时停用玻璃创建**。
    //
    // 1.0.9-81 打开开关后 Preferences 闪退，崩溃栈是 Swift 的 EXC_BREAKPOINT(SIGTRAP)
    // —— 那是 Swift 运行时的 trap，**无法用 @try/@catch 捕获**，只能避免触发。
    // 崩溃链：UIKit → liquidass.dylib → EchoRebornUIKit（三层）→ trap。
    // 在查明 LiquidGlassKit 内部究竟哪一步 trap 之前，这里只记录"命中情况"，
    // 绝不创建任何视图，保证不崩。
    // ---------------------------------------------------------------------
    static CFTimeInterval lastLog = 0.0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastLog > 5.0) {
        lastLog = now;
        NSLog(@"[EchoRebornUIKit] SWITCH-HOOK 命中 cls=%@ bounds=%@（玻璃创建已停用，待修复）",
              NSStringFromClass(self.class), NSStringFromCGRect(b));
    }
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
    // 1.0.9-82 · 同上：滑条也暂时只记录命中，不创建视图
    static CFTimeInterval lastLog2 = 0.0;
    CFTimeInterval now2 = CACurrentMediaTime();
    if (now2 - lastLog2 > 5.0) {
        lastLog2 = now2;
        NSLog(@"[EchoRebornUIKit] SLIDER-HOOK 命中 cls=%@ bounds=%@（玻璃创建已停用，待修复）",
              NSStringFromClass(self.class), NSStringFromCGRect(b));
    }
}

%end

%ctor {
    NSLog(@"[EchoRebornUIKit] 已加载 proc=%@ glassClass=%@",
          NSProcessInfo.processInfo.processName ?: @"?", ERGlassViewClass() ? @"有" : @"无");
}
