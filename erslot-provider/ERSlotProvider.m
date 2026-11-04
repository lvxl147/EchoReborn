// 1.2.2-173 · ERSlotProvider —— CCSupport Provider：运行时动态提供快捷指令槽位模块
// 协议逆向自上游 EVOConferenceProvider（numberOfProvidedModules /
// identifierForModuleAtIndex: / displayNameForModuleIdentifier: /
// moduleInstanceForModuleIdentifier: / moduleLayoutSizeForOrientation:）
// 绑定表 = ShortcutSlotAssignments（com.strive.echoreborn.preferences）
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#ifndef K_ER_PREFS
#define K_ER_PREFS CFSTR("com.strive.echoreborn.preferences")
#endif


// CCUI 开关模块基类（ControlCenterUIKit 私有类，槽位模块的宿主基类）
@interface CCUIToggleModule : NSObject
@property (nonatomic, strong) UIViewController *contentViewController;
- (UIViewController *)contentViewController;
@end

static NSDictionary *ERSPAssignments(void) {
    NSDictionary *d = (__bridge_transfer NSDictionary *)CFPreferencesCopyAppValue(CFSTR("ShortcutSlotAssignments"), K_ER_PREFS);
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}
static NSArray *ERSPVisibleOrder(void) {
    NSArray *a = (__bridge_transfer NSArray *)CFPreferencesCopyAppValue(CFSTR("ShortcutVisibleIdentifiers"), K_ER_PREFS);
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}
static NSArray *ERSPCatalog(void) {
    NSArray *a = (__bridge_transfer NSArray *)CFPreferencesCopyAppValue(CFSTR("ShortcutCatalog"), K_ER_PREFS);
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}
static NSString *ERSPNameForUUID(NSString *uuid) {
    for (NSDictionary *e in ERSPCatalog()) {
        if ([e isKindOfClass:[NSDictionary class]] && [e[@"uuid"] isKindOfClass:[NSString class]] &&
            [e[@"uuid"] isEqualToString:uuid] && [e[@"name"] isKindOfClass:[NSString class]])
            return e[@"name"];
    }
    return nil;
}

// CCSUILayoutSize 本地定义（与 CCUI 一致）
typedef struct { NSUInteger width, height; } ERSPSize;
typedef struct { NSUInteger x, y; } ERSPPoint;
typedef struct { ERSPPoint origin; ERSPSize size; } ERSPRect;



// 模块类：继承 CCUIToggleModule（CCUI 管线全由基类提供）
@interface ERSPModule : CCUIToggleModule
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *slotKey;
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, strong) UILabel *tileLabel;
@end
@implementation ERSPModule
- (instancetype)init {
    self = [super init];
    if (self) {
        UIViewController *vc = [[UIViewController alloc] init];
        UIView *v = [[UIView alloc] init];
        v.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        UILabel *l = [[UILabel alloc] init];
        l.textColor = UIColor.whiteColor;
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:13];
        l.numberOfLines = 2;
        [v addSubview:l];
        vc.view = v;
        self.contentViewController = vc;
        self.tileLabel = l;
    }
    return self;
}
- (void)refreshBinding {
    NSDictionary *assign = ERSPAssignments();
    self.uuid = assign[self.slotKey];
    NSString *name = ERSPNameForUUID(self.uuid) ?: [NSString stringWithFormat:@"模块占位 %@", self.slotKey];
    self.tileLabel.text = name;
    self.tileLabel.frame = self.contentViewController.view.bounds;
}
- (UIImage *)iconGlyph { return nil; }
- (UIImage *)selectedIconGlyph { return nil; }
- (UIColor *)selectedColor { return [UIColor systemBlueColor]; }
- (NSString *)glyphState { return @"switch"; }
- (BOOL)isSelected { return NO; }
- (void)setSelected {}
- (void)reloadBinding { [self refreshBinding]; }
- (void)touchDown {}
- (void)touchUp { [self runShortcut]; }
- (void)runShortcut {
    if (!self.uuid.length) return;
    CFPreferencesSetAppValue(CFSTR("ShortcutRunRequest"), (__bridge CFPropertyListRef)self.uuid, K_ER_PREFS);
    CFPreferencesAppSynchronize(K_ER_PREFS);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)@"com.strive.echoreborn/RunShortcut", nil, nil, YES);
}
@end

// Provider 主类
@interface ERSlotProvider : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, ERSPModule *> *moduleCache;
@end
@implementation ERSlotProvider
+ (instancetype)shared {
    static ERSlotProvider *p; static dispatch_once_t t;
    dispatch_once(&t, ^{ p = [self new]; p.moduleCache = [NSMutableDictionary dictionary]; });
    return p;
}
- (NSArray<NSString *> *)orderedSlotKeys {
    // 按显示清单顺序返回已绑定槽位键（数字升序）
    NSDictionary *assign = ERSPAssignments();
    NSArray *visible = ERSPVisibleOrder();
    NSMutableDictionary *uuidToKey = [NSMutableDictionary dictionary];
    for (NSString *k in assign) uuidToKey[assign[k]] = k;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *uuid in visible) {
        NSString *k = uuidToKey[uuid];
        if (k) [out addObject:k];
    }
    for (NSString *k in assign) if (![out containsObject:k]) [out addObject:k];
    return out;
}
- (NSUInteger)numberOfProvidedModules {
    return self.orderedSlotKeys.count;
}
- (NSString *)identifierForModuleAtIndex:(NSUInteger)index {
    NSArray *keys = self.orderedSlotKeys;
    if (index >= keys.count) return nil;
    return [NSString stringWithFormat:@"com.strive.echoreborn.shortcut.%@", keys[index]];
}
- (NSString *)displayNameForModuleIdentifier:(NSString *)identifier {
    NSDictionary *assign = ERSPAssignments();
    for (NSString *k in assign)
        if ([identifier isEqualToString:[NSString stringWithFormat:@"com.strive.echoreborn.shortcut.%@", k]])
            return [ERSPNameForUUID(assign[k]) ?: [NSString stringWithFormat:@"模块占位 %@", k] copy];
    return @"快捷指令";
}
- (id)moduleInstanceForModuleIdentifier:(NSString *)identifier {
    ERSPModule *m = self.moduleCache[identifier];
    if (!m) {
        m = [[ERSPModule alloc] init];
        m.identifier = identifier;
        NSString *prefix = @"com.strive.echoreborn.shortcut.";
        if ([identifier hasPrefix:prefix]) {
            m.slotKey = [identifier substringFromIndex:prefix.length];
            m.uuid = ERSPAssignments()[m.slotKey];
            [m refreshBinding];
        }
        self.moduleCache[identifier] = m;
    }
    return m;
}
- (ERSPRect)moduleLayoutSizeForOrientation:(NSInteger)orientation {
    ERSPRect r; r.origin.x = 0; r.origin.y = 0; r.size.width = 1; r.size.height = 1;
    return r;
}
- (ERSPRect)moduleSizeForOrientation:(NSInteger)orientation {
    return [self moduleLayoutSizeForOrientation:orientation];
}
- (UIViewController *)listControllerForModuleIdentifier:(NSString *)identifier { return nil; }
@end

__attribute__((constructor))
static void ERSPCtor(void) { /* Provider 由 CCSupport 在需要时实例化 */ }
