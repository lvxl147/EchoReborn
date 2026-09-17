// ---------------------------------------------------------------------------
// Shared declarations for the 实用工具 / 天气 Control Center module
// (ERWeatherModule.bundle, identifier com.strive.echoreborn.weather).
//
// What this module is
// -------------------
// A 满宽 × 一个标准行 (4×2) Control Center tile that shows the current
// conditions, temperature, high/low, precipitation chance and an hourly strip —
// the same feature set as the reference plugin
// com.simon.ccweathermodule 1.0.4 (WCCModule / WCCContentViewController), whose
// implementation this bundle mirrors: structure (one .bundle under
// /Library/ControlCenter/Bundles), registration (a principal class plus a
// content view controller, protocol-based rather than a CCUI base class) and
// data source (Apple's private Weather framework, read through runtime-resolved
// classes rather than linked symbols).
//
// What this module deliberately is NOT
// ------------------------------------
// Like the connectivity bundles, its only job is to EXIST under the right
// identifier and draw a sane tile:
//   * EchoReborn's gallery builds its catalog by scanning the Control Center
//     bundle directories on disk, so without a bundle the identifier is never
//     offered in 「添加控制项」 at all. The 「实用工具」 switch in the module pane
//     gates that catalog entry (ModuleEnabled_<identifier> in Tweak.xm).
//   * It drives no hardware and touches no system state. The only private
//     surface it reads is the Weather framework's own already-cached forecast,
//     and every step of that read is optional — see ERWeatherBridge.h.
//
// Hard rule carried over from v0.3.2 / v0.3.3 (see ERConnectivityModule.h): do
// not call runtime introspection functions such as class_getSuperclass from
// inside SpringBoard — an installed third-party tweak interposes them and doing
// so cost two consecutive respring loops. NSClassFromString is not one of
// those (it is a plain runtime lookup that does not walk the class hierarchy),
// and ERWeatherBridge.m is the only place that uses it, behind @try and a nil
// check at every step.
// ---------------------------------------------------------------------------

#import <UIKit/UIKit.h>

// ControlCenterUIKit is a private framework and Theos SDKs do not all ship its
// headers. The declaration below is the exact surface this bundle compiles
// against; each property is @optional-equivalent for us because Control Center
// only ever reads what it needs. Linking still happens through
// PRIVATE_FRAMEWORKS in the Makefile.
//
// The reference plugin conforms to these same two protocols — it does not
// subclass any CCUI class (its principal class is an NSObject, and ControlCenter
// instantiates it and asks for a contentViewController).
#if __has_include(<ControlCenterUIKit/CCUIContentModule.h>)
#import <ControlCenterUIKit/CCUIContentModule.h>
#else

// These fallback declarations sit above this file's own NS_ASSUME_NONNULL region
// (the one next to the diagnostics further down), so they get a region of their
// own.  A header that uses nullability annotations anywhere in it must annotate
// every pointer in it: clang's -Wnullability-completeness fires on any
// unannotated one, and this project builds with -Werror, so a missing specifier
// is a build failure rather than a note.
//
// `nonnull` is the honest contract here -- Control Center always asks for a
// content view controller and this bundle always supplies one -- and it is also
// what Apple's own CCUIContentModule declares.
NS_ASSUME_NONNULL_BEGIN

@protocol CCUIContentModuleContentViewController;

@protocol CCUIContentModule <NSObject>
/// Control Center hosts this controller and sizes it from the bundle's
/// CCSModuleSize (see Resources/Info.plist).
@property (nonatomic, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@end

@protocol CCUIContentModuleContentViewController <NSObject>
@optional
/// Self-sizing hint, consulted only when CCSGetModuleSizeAtRuntime is true.
@property (nonatomic, readonly) CGFloat preferredExpandedContentHeight;
/// YES hands the module its own background instead of the stock platter.
/// This module leaves it at the default (NO), so Control Center draws the
/// standard platter and the tile keeps the system's corner radius, material
/// and shadow — the same visual language as every neighbouring CC module.
@property (nonatomic, readonly) BOOL providesOwnPlatter;
@end

NS_ASSUME_NONNULL_END

#endif

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------
// The tile runs inside the ControlCenter process, not SpringBoard, so it cannot
// use the tweak's ERLogInfo (that lives in EchoReborn.dylib). It appends to the
// same log file instead, tagged [WEATHER], so a single exported log still covers
// both sides.
//
// These lines exist because the private Weather framework can only be resolved
// at runtime and cannot be tested off-device: every step of the bridge reports
// what it found, so a log pinpoints exactly which class or selector a given iOS
// version failed to provide.
void ERWeatherLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Best-effort JPEG-sized description of the resolved state, for the log.
NSString *_Nullable ERWeatherDebugSummary(void);

NS_ASSUME_NONNULL_END
