// 1.2.2-175 · ERSlotProvider —— CCSupport Provider（完整 17 方法，精确复刻上游 EVOConference*）
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define K_ER_PREFS CFSTR("com.strive.echoreborn.preferences")

typedef struct { NSUInteger width, height; } ERSPSize2;

// ---------- 偏好读取 ----------
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
static NSString *ERSPKeyLog(NSString *key, NSString *line) {
    NSMutableArray *l = [(__bridge_transfer NSMutableArray *)CFPreferencesCopyAppValue((__bridge CFStringRef)key, K_ER_PREFS) mutableCopy] ?: [NSMutableArray array];
    [l addObject:line];
    while (l.count > 60) [l removeObjectAtIndex:0];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)l, K_ER_PREFS);
    CFPreferencesAppSynchronize(K_ER_PREFS);
    return line;
}

// ---------- 模块类（NSObject 基类 + 17 方法全实现，复刻 EVOConferenceModule）----------
@interface ERSPModule : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) id nativeModule;
@property (nonatomic, strong) id contentModuleContext;
@property (nonatomic, strong) id presentationContext;
@property (nonatomic, strong) UIViewController *controller;
- (instancetype)initWithIdentifier:(NSString *)identifier;
@end

@implementation ERSPModule {
    UIViewController *_tileVC;
    UILabel *_tileLabel;
    NSString *_identifier;
    id _nativeModule;
    id _contentModuleContext;
    id _presentationContext;
    UIViewController *_controller;
}
- (instancetype)initWithIdentifier:(NSString *)identifier {
    self = [super init];
    if (self) _identifier = [identifier copy];
    return self;
}
- (NSString *)slotKey {
    NSString *prefix = @"com.strive.echoreborn.shortcut.";
    return [self.identifier hasPrefix:prefix] ? [self.identifier substringFromIndex:prefix.length] : nil;
}
- (NSString *)bindingName {
    NSString *uuid = ERSPAssignments()[self.slotKey];
    return ERSPNameForUUID(uuid) ?: [NSString stringWithFormat:@"模块占位 %@", self.slotKey ?: @""];
}
- (UIViewController *)makeTileVC {
    UIViewController *vc = [[UIViewController alloc] init];
    UILabel *l = [[UILabel alloc] init];
    l.textColor = UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:13];
    l.numberOfLines = 2;
    [vc.view addSubview:l];
    _tileLabel = l;
    UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(runShortcut)];
    [vc.view addGestureRecognizer:t];
    return vc;
}
- (UIViewController *)contentViewController {
    if (!_tileVC) _tileVC = [self makeTileVC];
    _tileLabel.frame = _tileVC.view.bounds;
    _tileLabel.text = [self bindingName];
    return _tileVC;
}
- (UIViewController *)contentViewControllerForContext:(id)context { return [self contentViewController]; }
- (UIViewController *)backgroundViewController { return nil; }
- (UIViewController *)backgroundViewControllerForContext:(id)context { return nil; }
- (ERSPSize2)moduleSizeForOrientation:(NSInteger)orientation {
    ERSPSize2 s; s.width = 1; s.height = 1; return s;
}
- (NSString *)identifier { return _identifier; }
- (void)setIdentifier:(NSString *)v { _identifier = [v copy]; }
- (id)nativeModule { return _nativeModule; }
- (void)setNativeModule:(id)v { _nativeModule = v; }
- (id)contentModuleContext { return _contentModuleContext; }
- (void)setContentModuleContext:(id)v { _contentModuleContext = v; }
- (id)presentationContext { return _presentationContext; }
- (void)setPresentationContext:(id)v { _presentationContext = v; }
- (UIViewController *)controller { return _controller; }
- (void)setController:(UIViewController *)v { _controller = v; }
- (void)runShortcut {
    NSString *uuid = ERSPAssignments()[self.slotKey];
    if (!uuid.length) return;
    CFPreferencesSetAppValue(CFSTR("ShortcutRunRequest"), (__bridge CFPropertyListRef)uuid, K_ER_PREFS);
    CFPreferencesAppSynchronize(K_ER_PREFS);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)@"com.strive.echoreborn/RunShortcut", nil, nil, YES);
}
@end

// ---------- Provider 主类 ----------
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
    NSDictionary *assign = ERSPAssignments();
    NSArray *visible = ERSPVisibleOrder();
    NSMutableDictionary *uuidToKey = [NSMutableDictionary dictionary];
    for (NSString *k in assign) uuidToKey[assign[k]] = k;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *uuid in visible) { NSString *k = uuidToKey[uuid]; if (k) [out addObject:k]; }
    for (NSString *k in assign) if (![out containsObject:k]) [out addObject:k];
    return out;
}
- (NSUInteger)numberOfProvidedModules {
    NSUInteger n = self.orderedSlotKeys.count;
    ERSPKeyLog(@"ERDlopenDump", [NSString stringWithFormat:@"numberOfProvidedModules=%lu", (unsigned long)n]);
    return n;
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
            return ERSPNameForUUID(assign[k]) ?: [NSString stringWithFormat:@"模块占位 %@", k];
    return @"快捷指令";
}
- (id)moduleInstanceForModuleIdentifier:(NSString *)identifier {
    ERSPModule *m = self.moduleCache[identifier];
    if (!m) {
        m = [[ERSPModule alloc] initWithIdentifier:identifier];
        self.moduleCache[identifier] = m;
    }
    return m;
}
- (ERSPSize2)moduleLayoutSizeForOrientation:(NSInteger)orientation {
    ERSPSize2 s; s.width = 1; s.height = 1; return s;
}
- (ERSPSize2)moduleSizeForOrientation:(NSInteger)orientation {
    ERSPSize2 s; s.width = 1; s.height = 1; return s;
}
- (UIViewController *)listControllerForModuleIdentifier:(NSString *)identifier { return nil; }
@end
