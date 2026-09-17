// ---------------------------------------------------------------------------
// Shared body for EchoReborn's standalone 连接 (Connectivity) Control Center
// modules: 飞行模式 / 蜂窝数据 / 隔空投送 / 个人热点 / 蓝牙 / 无线局域网 / VPN.
//
// Each module is its own .bundle because Control Center loads exactly one
// NSPrincipalClass per bundle, and every bundle needs a distinct class name
// (seven bundles sharing one class name would collide at runtime).  The class
// bodies would otherwise be identical, so they live here and each module's
// .m sets three macros and includes this file.
//
// What this class is, and — more importantly — what it deliberately is NOT:
//
// EchoReborn already implements the whole tile for these identifiers in Tweak.xm:
// real on/off state (SBWiFiManager, BluetoothManager, CoreTelephony), the
// glyph, the title, the status line, the selected highlight, the long-press
// expanded menu, and the 1x1 / 1x2 / 2x2 resize engine.  The tweak keys all of
// that off the module identifier matching "echoreborn.connectivity".
//
// So the only job of this bundle is to EXIST under the right identifier:
//   * EchoReborn's gallery builds its catalog by scanning the Control Center
//     bundle directories on disk, so without a bundle the identifier is never
//     offered in 「添加控制项」 at all.
//   * When something else (a gallery preview, or a future code path) does
//     instantiate the principal class, it must not crash and should show a
//     sane tile with the right icon.
//
// It therefore drives no hardware, reads no private state, and calls no
// runtime introspection functions.  That last point is a hard rule after
// v0.3.2 / v0.3.3: an installed third-party tweak (liquidass.dylib) interposes
// class_getSuperclass, and calling any public runtime function from inside
// SpringBoard cost us two consecutive respring loops.  There is nothing here
// for another tweak to interpose.
// ---------------------------------------------------------------------------

#import <UIKit/UIKit.h>

// ControlCenterUIKit is a private framework. Theos SDKs do not all ship its
// headers, so fall back to a minimal local declaration of exactly the surface
// this file uses. Linking still happens through PRIVATE_FRAMEWORKS in each
// module's Makefile; this is only about compiling.
#if __has_include(<ControlCenterUIKit/CCUIToggleModule.h>)
#import <ControlCenterUIKit/CCUIToggleModule.h>
#else

@interface CCUIToggleModule : NSObject
// A CC module exposes its content as a view controller; Control Center hosts
// it and sizes it from the bundle's CCSModuleSize.
@property (nonatomic, strong) UIViewController *contentViewController;
- (UIImage *)iconGlyph;
- (UIImage *)selectedIconGlyph;
- (UIColor *)selectedColor;
- (NSString *)glyphState;
- (BOOL)isSelected;
- (void)setSelected:(BOOL)selected;
@end

#endif

#ifndef ER_CONNECTIVITY_CLASS
#error "ER_CONNECTIVITY_CLASS must name this module's principal class"
#endif
#ifndef ER_CONNECTIVITY_SYMBOL
#error "ER_CONNECTIVITY_SYMBOL must name this module's SF Symbol"
#endif
// Accent used when the tile is on. Defaults to blue (Wi-Fi / Bluetooth /
// AirDrop / VPN); the cellular and hotspot modules override it to green and
// airplane mode to orange.
#ifndef ER_CONNECTIVITY_ACCENT
#define ER_CONNECTIVITY_ACCENT systemBlueColor
#endif

@interface ER_CONNECTIVITY_CLASS : CCUIToggleModule
@end

@implementation ER_CONNECTIVITY_CLASS

// The glyph shown when nothing else is drawing the tile. SF Symbols are
// resolved by name at runtime, so a missing symbol on an older OS degrades to
// the generic switch instead of returning nil (a nil glyph renders a blank
// tile, which reads as a bug).
- (UIImage *)iconGlyph {
    UIImage *image = [UIImage systemImageNamed:ER_CONNECTIVITY_SYMBOL];
    if (image) return image;
    return [UIImage systemImageNamed:@"switch.2"];
}

- (UIColor *)selectedColor {
    return [UIColor ER_CONNECTIVITY_ACCENT];
}

// EchoReborn tracks the real state and drives the visuals through its own
// presentation layer, so this module never claims to be selected on its own.
// Returning a constant keeps the stock toggle plumbing inert rather than
// letting it fight the tweak for control of the tile.
- (BOOL)isSelected {
    return NO;
}

// A no-op on purpose. Control Center routes a tap through EchoReborn's proxy
// control, which performs the real action; letting the stock setter run as
// well would toggle state twice.
- (void)setSelected:(__unused BOOL)selected {
}

@end
