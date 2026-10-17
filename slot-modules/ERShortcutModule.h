// ---------------------------------------------------------------------------
// Shared body for EchoReborn's 快捷指令 (Shortcut) slot modules.
//
// 32 Control Center bundles, com.strive.echoreborn.shortcut.1 … .32. Each is
// a REAL Control Center module. Control Center places it, sizes it, pages it
// and gives it the system module chrome — exactly like the seven 连接 bundles,
// and exactly like EvoCenter16's 64 CCFShortcutNModule bundles. Because the
// tile is a real module, none of its position is EchoReborn's arithmetic: there
// is no page origin to measure, no space to guess, no page offset to apply
// once. That arithmetic is where every earlier "wrong on page 2 / wrong in
// edit mode / briefly wrong when it opens" report came from.
//
// Which shortcut a slot runs is DATA, not code. The Settings/prefs side binds
// shortcut -> slot in the shared com.strive.echoreborn.preferences domain
// (ShortcutSlotAssignments = { "3" : "<uuid>" }), and this bundle resolves
// that binding at runtime to draw the shortcut's glyph and to report which
// workflow to run. The running itself is delegated to EchoReborn's SpringBoard
// half (it posts a Darwin notification carrying the uuid; EchoReborn calls
// WorkflowKit's WFSpringBoardWorkflowRunnerClient, which runs the workflow by
// identifier without ever foregrounding the Shortcuts app — EvoCenter16's
// mechanism, which is what makes "tap a tile, shortcut just runs" work).
//
// Rendering rules (0.5.6.0 — the "grey plate + doubled icons" fixes):
//
//   * The system module background IS the tile background. The content view
//     draws NO backdrop of its own — the old white-12% rounded plate sat on
//     top of Control Center's own module material and read as a stale grey
//     rectangle. Nothing self-drawn may claim background real estate anymore.
//   * The glyph is the bound shortcut's SF Symbol, white-tinted, template
//     art with no colour plate behind it. Shortcuts' custom icon images
//     (catalog imageData) are deliberately NOT used: they are app-style
//     rounded squares carrying their own opaque background colour — exactly
//     the 方块背景色 this tile must not show.
//   * The stock CCUIToggleModule chrome is silenced. The module overrides
//     iconGlyph / selectedIconGlyph to nil and the content view hides any
//     stock CCUIButtonModuleView sibling, so Control Center's default glyph
//     can never stack over the tile's own glyph (the doubled-icon report).
//   * The content adapts to the size Control Center actually gives the tile
//     (its resize engine offers 1x1, 2x1 and 2x2 for every 1x1 module):
//       1x1 — the white glyph only, centred; no name, no run hint.
//       2x1 — glyph on the left; right half stacks the name on top and the
//             点击运行 hint below.
//       2x2 — glyph in the top-left corner; name and 点击运行 underneath.
//
// This file is compiled into all 32 bundles through the #define ER_SHORTCUT_CLASS
// set by each slot's .m. It deliberately uses only UIKit + a couple of private
// framework dlopen's that fail safe, so a missing symbol never breaks the tile.
// ---------------------------------------------------------------------------

#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>

// ControlCenterUIKit is a private framework and not every Theos SDK ships its
// headers, so fall back to a minimal local declaration of exactly the surface
// used here. Linking happens through PRIVATE_FRAMEWORKS in each module's
// Makefile; this is only about compiling.
#if __has_include(<ControlCenterUIKit/CCUIToggleModule.h>)
#import <ControlCenterUIKit/CCUIToggleModule.h>
#else

@interface CCUIToggleModule : NSObject
@property (nonatomic, strong) UIViewController *contentViewController;
- (UIImage *)iconGlyph;
- (UIImage *)selectedIconGlyph;
- (UIColor *)selectedColor;
- (NSString *)glyphState;
- (BOOL)isSelected;
- (void)setSelected:(BOOL)selected;
@end

#endif

#ifndef ER_SHORTCUT_CLASS
#error "ER_SHORTCUT_CLASS must name this module's principal class"
#endif

static NSString *const kERShortcutPrefsDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERShortcutSlotAssignmentsKey = @"ShortcutSlotAssignments";
static NSString *const kERShortcutCatalogKey = @"ShortcutCatalog";
static NSString *const kERShortcutRunRequestKey = @"ShortcutRunRequest";
static NSString *const kERShortcutReloadNotification = @"com.strive.echoreborn/ReloadPrefs";
static NSString *const kERShortcutRunNotification = @"com.strive.echoreborn/RunShortcut";

// 1.1.9-19 · 快捷方式（LinkCatalog）与快捷指令共用同一批槽位：绑定先查
// ShortcutSlotAssignments，未命中再查 LinkSlotAssignments。点击 link 磁贴把
// uuid 写进 LinkRunRequest 并广播 RunLink，由 SpringBoard 侧按条目类型执行。
static NSString *const kERLinkSlotAssignmentsKey = @"LinkSlotAssignments";
static NSString *const kERLinkCatalogKey = @"LinkCatalog";
static NSString *const kERLinkRunRequestKey = @"LinkRunRequest";
static NSString *const kERLinkRunNotification = @"com.strive.echoreborn/RunLink";

// 槽位绑定的快捷方式条目（LinkCatalog 数组里按 uuid 查找）。
static inline NSDictionary *ERLinkBindingForSlot(NSInteger slot, NSString **uuidOut) {
    if (uuidOut) *uuidOut = nil;
    if (slot <= 0) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERShortcutPrefsDomain);
    id assignments = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)kERLinkSlotAssignmentsKey, (__bridge CFStringRef)kERShortcutPrefsDomain);
    if (![assignments isKindOfClass:[NSDictionary class]]) return nil;
    NSString *uuid = assignments[[NSString stringWithFormat:@"%ld", (long)slot]];
    if (![uuid isKindOfClass:[NSString class]] || !uuid.length) return nil;
    if (uuidOut) *uuidOut = uuid;
    id catalog = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)kERLinkCatalogKey, (__bridge CFStringRef)kERShortcutPrefsDomain);
    if (![catalog isKindOfClass:[NSArray class]]) return nil;
    for (NSDictionary *candidate in catalog) {
        if ([candidate isKindOfClass:[NSDictionary class]] &&
            [candidate[@"uuid"] isKindOfClass:[NSString class]] &&
            [candidate[@"uuid"] isEqualToString:uuid]) return candidate;
    }
    return nil;
}

// 1.1.9-19 · App 图标的白色单色剪影：从 App 安装目录读 Info.plist 的
// CFBundleIconFiles，找到 PNG 后用 imageWithTintColor 变成纯白剪影 —— 磁贴上
// 不出现彩色方块（与快捷指令磁贴的「白色字形、无底板」规则一致）。
static inline UIImage *ERLinkWhiteAppIcon(NSString *bundleId) {
    if (![bundleId isKindOfClass:[NSString class]] || !bundleId.length) return nil;
    @try {
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!proxyClass) return nil;
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, @selector(applicationProxyForIdentifier:), bundleId);
        if (!proxy) return nil;
        NSURL *bundleURL = [proxy valueForKey:@"bundleURL"];
        if (![bundleURL isKindOfClass:[NSURL class]] || !bundleURL.path.length) return nil;
        CFDictionaryRef infoRef = CFBundleCopyInfoDictionaryForURL((__bridge CFURLRef)bundleURL);
        if (!infoRef) return nil;
        NSDictionary *info = (__bridge_transfer NSDictionary *)infoRef;
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        id iconFiles = info[@"CFBundleIconFiles"];
        if ([iconFiles isKindOfClass:[NSArray class]]) {
            for (id name in iconFiles) if ([name isKindOfClass:[NSString class]] && ((NSString *)name).length) [names addObject:name];
        } else if ([iconFiles isKindOfClass:[NSString class]] && ((NSString *)iconFiles).length) {
            [names addObject:iconFiles];
        }
        id iconNames = info[@"CFBundleIconName"];
        if ([iconNames isKindOfClass:[NSArray class]]) {
            for (id name in iconNames) if ([name isKindOfClass:[NSString class]] && ((NSString *)name).length) [names addObject:name];
        }
        NSString *directory = bundleURL.path;
        for (NSString *name in names) {
            for (NSString *candidate in @[name, [name stringByAppendingString:@".png"],
                                          [NSString stringWithFormat:@"%@@2x.png", name],
                                          [NSString stringWithFormat:@"%@@3x.png", name]]) {
                NSString *path = [directory stringByAppendingPathComponent:candidate];
                UIImage *image = [UIImage imageWithContentsOfFile:path];
                if (image) return [image imageWithTintColor:UIColor.whiteColor] ?: image;
            }
        }
    } @catch (__unused NSException *exception) {}
    return nil;
}

// Maps a Shortcuts glyph number to an SF Symbol name via WorkflowKit's own
// helper (the same one the tweak uses). Returns nil when WorkflowKit is absent
// or the glyph is unknown, so the caller can fall back to "sparkles".
static inline NSString *ERShortcutSymbolNameForGlyph(unsigned short glyph) {
    static NSString *(*mapper)(unsigned short) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_LAZY);
        if (handle) mapper = (NSString *(*)(unsigned short))dlsym(handle, "WFSystemImageNameForGlyphCharacter");
    });
    if (!mapper) return nil;
    @try { NSString *name = mapper(glyph); return name.length ? name : nil; }
    @catch (__unused NSException *exception) { return nil; }
}

// Reads the slot's binding from the shared prefs domain. Returns the catalog
// record for the shortcut bound to the slot (nil when the slot is unassigned
// or its record is missing from the catalog) and, when uuidOut is non-NULL,
// the assigned uuid itself — a slot can be assigned while its record is not
// (yet) in the catalog, and the run path must still know the uuid.
static inline NSDictionary *ERShortcutBindingForSlot(NSInteger slot, NSString **uuidOut) {
    if (uuidOut) *uuidOut = nil;
    if (slot <= 0) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERShortcutPrefsDomain);
    id assignments = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)kERShortcutSlotAssignmentsKey, (__bridge CFStringRef)kERShortcutPrefsDomain);
    if (![assignments isKindOfClass:[NSDictionary class]]) return nil;
    NSString *uuid = assignments[[NSString stringWithFormat:@"%ld", (long)slot]];
    if (![uuid isKindOfClass:[NSString class]] || !uuid.length) return nil;
    if (uuidOut) *uuidOut = uuid;
    id catalog = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)kERShortcutCatalogKey, (__bridge CFStringRef)kERShortcutPrefsDomain);
    if (![catalog isKindOfClass:[NSArray class]]) return nil;
    for (NSDictionary *candidate in catalog) {
        if ([candidate isKindOfClass:[NSDictionary class]] &&
            [candidate[@"uuid"] isKindOfClass:[NSString class]] &&
            [candidate[@"uuid"] isEqualToString:uuid]) return candidate;
    }
    return nil;
}

// Resolves the bound shortcut's glyph as a WHITE SF Symbol image with no
// colour plate of its own: the symbol is template art, tinted white, so it
// sits directly on the system module background. Falls back to "sparkles"
// whenever the symbol name is unknown or the OS cannot render it.
static inline UIImage *ERShortcutGlyphImage(NSString *symbolName, CGFloat pointSize) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightMedium];
    UIImage *image = [UIImage systemImageNamed:symbolName withConfiguration:configuration] ?: [UIImage systemImageNamed:@"sparkles"];
    return [image imageWithTintColor:UIColor.whiteColor] ?: image;
}

static inline NSString *ERShortcutSymbolForRecord(NSDictionary *record) {
    NSString *symbol = record ? ERShortcutSymbolNameForGlyph((unsigned short)[record[@"glyph"] unsignedShortValue]) : nil;
    return symbol.length ? symbol : @"sparkles";
}

// Layout geometry shared with the 蓝牙 connectivity tile so the two line up
// (matches kERGridCellSize / kERSquareContentInset in Tweak.xm).
static const CGFloat kERShortcutGridCellSize = 67.0;
static const CGFloat kERShortcutSquareInset  = 16.0;
static const CGFloat kERShortcutLineHeight   = 14.3333;

@interface ERShortcutTileViewController : UIViewController
- (void)reloadBinding;
@end

static inline NSInteger ERShortcutSlotNumber(void) {
    // [NSBundle mainBundle] is SpringBoard here: Control Center loads the slot
    // bundles INTO SpringBoard's process, so mainBundle.bundleIdentifier is
    // com.apple.springboard and the slot number always parsed to 0. Every
    // binding lookup then returned nil — no shortcut name on the tile (glyph
    // fell back to sparkles) while the tweak-side tap proxy kept the tile
    // functional. Resolve the slot from the bundle that actually contains this
    // class instead. (Declared after the @interface so the class is known.)
    NSBundle *bundle = [NSBundle bundleForClass:[ERShortcutTileViewController class]];
    NSString *suffix = [bundle.bundleIdentifier componentsSeparatedByString:@"."].lastObject;
    return suffix.length ? suffix.integerValue : 0;
}

// How the tile arranges its content, derived from the size Control Center
// actually gives the module:
//   Compact (1x1) — the white glyph only, centred; no name, no run hint.
//   Wide    (2x1) — glyph on the left; right half stacks the name on top and
//                   the 点击运行 hint below.
//   Large   (2x2) — glyph in the top-left corner; name and 点击运行 underneath.
typedef NS_ENUM(NSInteger, ERShortcutTileLayout) {
    ERShortcutTileLayoutCompact = 0,
    ERShortcutTileLayoutWide    = 1,
    ERShortcutTileLayoutLarge   = 2,
};

@interface ERShortcutTileViewController ()
// 1.1.9-19：槽位绑定到 LinkCatalog（快捷方式）条目时的标记与白色剪影图。
@property (nonatomic, assign) BOOL isLinkEntry;
@property (nonatomic, strong) UIImage *linkImage;
@property (nonatomic, strong) UIImageView *glyphView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *runLabel;
@property (nonatomic, strong) UIControl *tapTarget;
@property (nonatomic, copy) NSString *ccaUUID;
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, assign) CGFloat glyphPointSize;
@end

static void ERShortcutHideStockButtonViews(UIView *root, UIView *skipBranch) {
    for (UIView *subview in root.subviews) {
        if (subview == skipBranch) continue;
        if ([NSStringFromClass(subview.class) isEqualToString:@"CCUIButtonModuleView"]) {
            subview.hidden = YES;
            continue;
        }
        ERShortcutHideStockButtonViews(subview, nil);
    }
}

@implementation ERShortcutTileViewController

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
    // The system module background IS the tile background. Nothing self-drawn
    // may claim background real estate: the old white-12% plate was the grey
    // residue sitting on top of Control Center's own module material.
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = YES;
    self.view.contentMode = UIViewContentModeRedraw;

    _glyphView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _glyphView.contentMode = UIViewContentModeScaleAspectFit;
    _glyphView.tintColor = UIColor.whiteColor;
    _glyphView.backgroundColor = UIColor.clearColor;
    _glyphView.userInteractionEnabled = NO;
    [self.view addSubview:_glyphView];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.textColor = UIColor.whiteColor;
    _nameLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    _nameLabel.textAlignment = NSTextAlignmentLeft;
    _nameLabel.numberOfLines = 2;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.backgroundColor = UIColor.clearColor;
    _nameLabel.userInteractionEnabled = NO;
    [self.view addSubview:_nameLabel];

    _runLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _runLabel.text = @"点击运行";
    _runLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    _runLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    _runLabel.textAlignment = NSTextAlignmentLeft;
    _runLabel.numberOfLines = 1;
    _runLabel.backgroundColor = UIColor.clearColor;
    _runLabel.userInteractionEnabled = NO;
    [self.view addSubview:_runLabel];

    _tapTarget = [[UIControl alloc] initWithFrame:CGRectZero];
    [_tapTarget addTarget:self action:@selector(tileTouchDown) forControlEvents:UIControlEventTouchDown];
    [_tapTarget addTarget:self action:@selector(tileTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [_tapTarget addTarget:self action:@selector(tileTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_tapTarget];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadBinding];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    ERShortcutTileDidReload,
                                    (__bridge CFStringRef)kERShortcutReloadNotification,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void ERShortcutTileDidReload(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ERShortcutTileViewController *self = (__bridge ERShortcutTileViewController *)observer;
    if ([self isKindOfClass:[ERShortcutTileViewController class]]) [self reloadBinding];
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        (__bridge CFStringRef)kERShortcutReloadNotification, NULL);
}

// The slot module subclasses CCUIToggleModule, so Control Center also builds
// its stock circular button — material plus glyph — inside the module
// container, next to or under our content view. With a transparent content
// view that stock chrome shows through as a second icon / an extra plate on
// the tile. Hide every stock button view around our content, but only inside
// this module's own container (the first ancestor whose class stops carrying
// "Module" ends the walk), and never into our own branch.
- (void)ccaHideHostButtonChrome {
    UIView *child = self.view;
    for (UIView *ancestor = child.superview; ancestor; child = ancestor, ancestor = ancestor.superview) {
        if (![NSStringFromClass(ancestor.class) containsString:@"Module"]) break;
        ERShortcutHideStockButtonViews(ancestor, child);
    }
}

// Reads the slot's shortcut binding and repaints the tile. Called on load and
// whenever the prefs reload notification fires (assignment changed in Settings
// or by EchoReborn's 添加控制项 sheet).
- (void)reloadBinding {
    @try {
        [self reloadBindingGuarded];
    } @catch (NSException *exception) {
        // 任何异常都不能把磁贴画成空白：退回「link」字形。
        self.isLinkEntry = NO;
        self.linkImage = nil;
        self.symbolName = @"link";
        self.glyphPointSize = 0.0;
        [self.view setNeedsLayout];
    }
}

- (void)reloadBindingGuarded {
    NSInteger slotNumber = ERShortcutSlotNumber();
    NSString *uuid = nil;
    NSDictionary *record = ERShortcutBindingForSlot(slotNumber, &uuid);
    // 1.1.9-19：快捷指令未命中时查快捷方式（LinkCatalog）。槽位绘制规则一致 ——
    // 白色单色剪影、无自绘底板；App/appShortcut 条目用 App 图标的白色剪影，
    // 其它用条目自带 SF 符号，最后退回「链接」符号。
    self.isLinkEntry = NO;
    self.linkImage = nil;
    if (!record) {
        NSDictionary *link = ERLinkBindingForSlot(slotNumber, &uuid);
        if (link) {
            record = link;
            self.isLinkEntry = YES;
            NSString *kind = [link[@"iconKind"] isKindOfClass:[NSString class]] ? link[@"iconKind"] : @"";
            if ([kind isEqualToString:@"app"]) {
                UIImage *icon = ERLinkWhiteAppIcon([link[@"iconValue"] isKindOfClass:[NSString class]] ? link[@"iconValue"] : link[@"bundleId"]);
                if (icon) self.linkImage = icon;
            }
        }
    }
    self.ccaUUID = uuid;
    if (self.isLinkEntry) {
        // 1.1.9-33：按条目类型区分磁贴呈现（仅显示层，设置页不变）。
        // 副标题：link=一键直达 / appShortcut=快捷跳转 / app=打开应用；
        // 图标：link 保持现有逻辑（symbol 条目用自带 SF 符号、兜底 link），
        // appShortcut 固定 bolt.fill、app 固定 square.grid.2x2.fill（尺寸/位置不变）。
        NSString *entryType = [record[@"type"] isKindOfClass:[NSString class]] ? record[@"type"] : @"";
        NSString *kind = [record[@"iconKind"] isKindOfClass:[NSString class]] ? record[@"iconKind"] : @"";
        NSString *preferred = [record[@"iconValue"] isKindOfClass:[NSString class]] ? record[@"iconValue"] : @"";
        NSString *symbol = ([kind isEqualToString:@"symbol"] && preferred.length && [UIImage systemImageNamed:preferred]) ? preferred : @"link";
        // 1.1.9-62：自定义页设置的图标覆盖（symbolOverride）优先于类型固定符号 ——
        // 设置页改图标，磁贴与子页面两处同步生效。
        NSString *overrideSymbol = [record[@"symbolOverride"] isKindOfClass:[NSString class]] ? record[@"symbolOverride"] : @"";
        if (overrideSymbol.length && [UIImage systemImageNamed:overrideSymbol]) {
            symbol = overrideSymbol;
        } else if ([entryType isEqualToString:@"appShortcut"]) {
            symbol = @"bolt.fill";
            self.linkImage = nil;
        } else if ([entryType isEqualToString:@"app"]) {
            symbol = @"square.grid.2x2.fill";
            self.linkImage = nil;
        }
        self.symbolName = symbol;
        _runLabel.text = [entryType isEqualToString:@"link"] ? @"一键直达"
                       : [entryType isEqualToString:@"appShortcut"] ? @"快捷跳转"
                       : [entryType isEqualToString:@"app"] ? @"打开应用"
                       : @"点击运行";
    } else {
        self.symbolName = ERShortcutSymbolForRecord(record);
        _runLabel.text = @"点击运行";
    }
    NSString *name = [record[@"name"] isKindOfClass:[NSString class]] ? record[@"name"] : nil;
    self.nameLabel.text = name;
    // 1.1.9-20：渲染状态远程诊断（SpringBoard 进程写自有偏好域）。
    @try {
        NSString *diagKey = [NSString stringWithFormat:@"Diag.Slot.%ld", (long)slotNumber];
        NSString *diagValue = [NSString stringWithFormat:@"uuid=%@ link=%d sym=%@ img=%@ name=%@ t=%@",
                               uuid ?: @"-", _isLinkEntry ? 1 : 0, _symbolName ?: @"-",
                               _linkImage ? @"YES" : @"NO", name ?: @"-", [NSDate date]];
        CFPreferencesSetAppValue((__bridge CFStringRef)diagKey, (__bridge CFPropertyListRef)diagValue,
                                 (__bridge CFStringRef)kERShortcutPrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kERShortcutPrefsDomain);
    } @catch (__unused NSException *exception) {}
    // Force the next layout pass to re-render the glyph at its layout size.
    self.glyphPointSize = 0.0;
    [self.view setNeedsLayout];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) return;
    _tapTarget.frame = bounds;
    [self ccaHideHostButtonChrome];

    CGFloat width = bounds.size.width, height = bounds.size.height;
    ERShortcutTileLayout layout;
    if (width / MAX(height, 1.0) > 1.4)          layout = ERShortcutTileLayoutWide;    // 2x1
    else if (MIN(width, height) >= 90.0)         layout = ERShortcutTileLayoutLarge;   // 2x2
    else                                         layout = ERShortcutTileLayoutCompact; // 1x1

    CGFloat pointSize = (layout == ERShortcutTileLayoutLarge) ? 28.0
                      : (layout == ERShortcutTileLayoutWide)  ? 24.0
                      :                                              26.0;
    if (pointSize != _glyphPointSize || !_glyphView.image) {
        _glyphPointSize = pointSize;
        _glyphView.image = _linkImage ?: ERShortcutGlyphImage(_symbolName, pointSize);
    }

    BOOL showsText = (layout != ERShortcutTileLayoutCompact);
    _nameLabel.hidden = !(showsText && _nameLabel.text.length > 0);
    _runLabel.hidden = !showsText;

    if (layout == ERShortcutTileLayoutCompact) {
        // 1x1: the white glyph only, centred — no name, no run hint, no colour.
        CGFloat side = MIN(width, height) * 0.55;
        _glyphView.frame = CGRectMake((width - side) * 0.5, (height - side) * 0.5, side, side);
        _nameLabel.frame = CGRectZero;
        _runLabel.frame = CGRectZero;
        return;
    }
    if (layout == ERShortcutTileLayoutWide) {
        // 2x1: glyph in the leading cell-sized square on the left; the name and
        // 点击运行 sit to its right, vertically centred, using the same leading
        // margin the 蓝牙 connectivity tile uses (reference layout).
        CGFloat side = MIN(kERShortcutGridCellSize, height);
        _glyphView.contentMode = UIViewContentModeCenter;
        _glyphView.frame = CGRectMake(0.0, (height - side) * 0.5, side, side);
        CGFloat refWidth = ceil([@"蓝牙" sizeWithAttributes:@{NSFontAttributeName: _nameLabel.font}].width);
        CGFloat textX = round((width - refWidth) * 0.5);
        if (textX < 0.0) textX = 0.0;
        CGFloat textWidth = MAX(0.0, width - textX - 10.0);
        CGRect measuredTitle = [_nameLabel.text boundingRectWithSize:CGSizeMake(textWidth, kERShortcutLineHeight * 2.0)
                                                            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                         attributes:@{NSFontAttributeName: _nameLabel.font} context:nil];
        CGFloat titleHeight = measuredTitle.size.height > kERShortcutLineHeight + 1.0 ? kERShortcutLineHeight * 2.0 : kERShortcutLineHeight;
        CGFloat groupHeight = titleHeight + (_runLabel.hidden ? 0.0 : kERShortcutLineHeight);
        CGFloat top = round((height - groupHeight) * 0.5);
        _nameLabel.frame = CGRectMake(textX, top, textWidth, titleHeight);
        _runLabel.frame = CGRectMake(textX, top + titleHeight, textWidth, kERShortcutLineHeight);
        return;
    }
    // 2x2: glyph in the top-left corner; name and 点击运行 pinned to the bottom.
    CGFloat side = kERShortcutGridCellSize;
    _glyphView.contentMode = UIViewContentModeLeft;
    _glyphView.frame = CGRectMake(kERShortcutSquareInset, 4.0, side, side);
    CGFloat textX = kERShortcutSquareInset;
    CGFloat textWidth = MAX(0.0, width - textX * 2.0);
    CGRect measuredTitle = [_nameLabel.text boundingRectWithSize:CGSizeMake(textWidth, kERShortcutLineHeight * 2.0)
                                                        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                     attributes:@{NSFontAttributeName: _nameLabel.font} context:nil];
    CGFloat titleHeight = measuredTitle.size.height > kERShortcutLineHeight + 1.0 ? kERShortcutLineHeight * 2.0 : kERShortcutLineHeight;
    CGFloat groupHeight = titleHeight + (_runLabel.hidden ? 0.0 : kERShortcutLineHeight);
    CGFloat bottomInset = 12.0;
    CGFloat top = height - bottomInset - groupHeight;
    if (top < kERShortcutGridCellSize + 8.0) top = kERShortcutGridCellSize + 8.0;
    _nameLabel.frame = CGRectMake(textX, top, textWidth, titleHeight);
    _runLabel.frame = CGRectMake(textX, top + titleHeight, textWidth, kERShortcutLineHeight);
}

- (void)tileTouchDown {
    self.view.alpha = 0.55;
}

- (void)tileTouchUp {
    self.view.alpha = 1.0;
}

// Tells EchoReborn (same process: SpringBoard) which workflow to run. The uuid is
// stashed in a shared prefs key because Darwin notify carries no reliable
// userInfo across observers; EchoReborn's listener reads ShortcutRunRequest and
// calls WorkflowKit's WFSpringBoardWorkflowRunnerClient for it.
- (void)tileTapped {
    self.view.alpha = 1.0;
    NSString *uuid = self.ccaUUID;
    if (!uuid.length) return;
    NSString *requestKey = _isLinkEntry ? kERLinkRunRequestKey : kERShortcutRunRequestKey;
    NSString *notifyName = _isLinkEntry ? kERLinkRunNotification : kERShortcutRunNotification;
    CFPreferencesSetAppValue((__bridge CFStringRef)requestKey, (__bridge CFPropertyListRef)uuid, (__bridge CFStringRef)kERShortcutPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERShortcutPrefsDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)notifyName, NULL, NULL, TRUE);
}

// A shortcut slot is a momentary action, not an expandable module. Declare no
// expanded content so Control Center's long-press presentation never queries
// preferredExpandedContentHeight on this plain view controller (which crashed
// SpringBoard). The Tweak also blocks the long-press interaction entirely, so a
// long press is a true no-op.
- (double)preferredExpandedContentHeight { return 0.0; }
- (double)preferredExpandedContentWidth  { return 0.0; }

@end

@interface ER_SHORTCUT_CLASS : CCUIToggleModule
@end

@implementation ER_SHORTCUT_CLASS {
    ERShortcutTileViewController *_ccaContentViewController;
}

// A shortcut slot is a real Control Center module: subclassing CCUIToggleModule
// makes Control Center accept it and lay it out natively. We override the
// content view controller to return our own tile (drawn from the slot's
// shortcut binding) instead of the toggle's circular button chrome.
- (UIViewController *)contentViewController {
    if (!_ccaContentViewController) _ccaContentViewController = [[ERShortcutTileViewController alloc] init];
    return _ccaContentViewController;
}

// The stock toggle chrome is exactly what must NOT appear on this tile: the
// default glyph would stack over the tile's own white glyph (the duplicated
// icons report), and any selected tint would read as a colour plate. Return
// nothing for every glyph/tint hook — the content view controller owns 100%
// of the tile. The 添加控制项 gallery does not consult these hooks; its
// shortcut section renders its rows from ShortcutCatalog records.
- (UIImage *)iconGlyph {
    return nil;
}

- (UIImage *)selectedIconGlyph {
    return nil;
}

- (UIColor *)selectedColor {
    return UIColor.clearColor;
}

// The tile never claims to be "on": a shortcut is a momentary action, not a
// toggle, and the stock selected plumbing must stay inert rather than fight
// the content view for control of the tile.
- (BOOL)isSelected {
    return NO;
}

- (void)setSelected:(__unused BOOL)selected {
}

@end
