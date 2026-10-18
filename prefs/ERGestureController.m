#import "ERGestureController.h"
#import "ERUIHelpers.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>

// 1.2.0-1 · 桌面胶囊手势子页（设计定稿 2026-10-18）：
//   卡片1 搜索胶囊总开关；卡片2 上/下/左/右滑四行（下拉框选 无动作/第n页）；
//   卡片3 手势震动反馈（开关 + 轻/中/重三档，映射 UIImpactFeedbackStyle）。
// 全部值走 CFPreferences（域 com.strive.echoreborn.preferences），与 Tweak.xm 同存储；
// 下拉选择即写即生效（darwin 通知 ReloadPrefs），无保存按钮。
// 桌面页数从共享键 HomeScreen.PageCount 读（SpringBoard 侧运行时探测写入），
// 读不到（<1）时下拉列表兜底到第10页。

static NSString *const kERGestureSuite = @"com.strive.echoreborn.preferences";
static NSString *const kERGestureReload = @"com.strive.echoreborn/ReloadPrefs";
static NSString *const kERGestureValueCellClassName = @"ERGestureValueCell";

static NSInteger ERGesturePageCount(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    Boolean ok = NO;
    CFIndex v = CFPreferencesGetAppIntegerValue(CFSTR("HomeScreen.PageCount"),
                                                (__bridge CFStringRef)kERGestureSuite, &ok);
    if (ok && v >= 1) return (NSInteger)v;
    return 10;   // SpringBoard 还没写过（respring 后首开）时的兜底
}

static NSInteger ERGestureReadValue(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    Boolean ok = NO;
    CFIndex v = CFPreferencesGetAppIntegerValue((__bridge CFStringRef)key,
                                                (__bridge CFStringRef)kERGestureSuite, &ok);
    if (!ok) return 0;
    return (NSInteger)v;
}

static void ERGestureWriteValue(NSString *key, NSInteger value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFNumberRef)@(value),
                             (__bridge CFStringRef)kERGestureSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    notify_post(kERGestureReload.UTF8String);
}

static NSString *ERGestureValueText(NSInteger value) {
    return value >= 1 ? [NSString stringWithFormat:@"第%ld页", (long)value] : @"无动作";
}

#pragma mark - 下拉菜单数据源桥

// UITableView 的 dataSource/delegate 都是 weak 引用 —— 桥对象必须由浮层容器
// 强持有（associated），否则赋值即释放，点开菜单就是野指针崩溃。
@interface ERGestureDropdownBridge : NSObject <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithOptions:(NSArray<NSString *> *)options
                        current:(NSString *)current
                           pick:(void (^)(NSInteger idx))pick;
@end

@implementation ERGestureDropdownBridge {
    NSArray<NSString *> *_options;
    NSString *_current;
    void (^_pick)(NSInteger);
}
- (instancetype)initWithOptions:(NSArray<NSString *> *)options
                        current:(NSString *)current
                           pick:(void (^)(NSInteger idx))pick {
    self = [super init];
    if (self) { _options = [options copy]; _current = current; _pick = [pick copy]; }
    return self;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_options.count;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 40.0;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *ident = @"ERGestureMenuRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ident];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ident];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.font = [UIFont systemFontOfSize:15.0];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSString *opt = _options[(NSUInteger)indexPath.row];
    cell.textLabel.text = opt;
    cell.textLabel.textColor = [opt isEqualToString:_current]
        ? [UIColor colorWithRed:0.30 green:0.80 blue:1.00 alpha:1.0]   // 当前值高亮青色
        : [UIColor colorWithWhite:1.0 alpha:0.92];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (_pick) _pick(indexPath.row);
}
@end

#pragma mark - 下拉浮层

static void ERGestureShowDropdown(UIButton *anchor, NSString *current, void (^onPick)(NSInteger idx)) {
    UIWindow *window = anchor.window;
    if (!window) return;

    CGRect anchorRect = [anchor convertRect:anchor.bounds toView:window];
    NSInteger pageCount = ERGesturePageCount();
    NSMutableArray<NSString *> *options = [NSMutableArray arrayWithObject:@"无动作"];
    for (NSInteger p = 1; p <= pageCount; p++) {
        [options addObject:[NSString stringWithFormat:@"第%ld页", (long)p]];
    }

    UIView *container = [[UIView alloc] initWithFrame:window.bounds];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.alpha = 0.0;

    // 透明遮罩：接住"点外面收起"。
    UIControl *backdrop = [[UIControl alloc] initWithFrame:container.bounds];
    backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.001];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [backdrop addTarget:container action:@selector(removeFromSuperview)
       forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:backdrop];

    CGFloat rowH = 40.0;
    CGFloat width = 170.0;
    CGFloat tableH = MIN((CGFloat)options.count, 8.0) * rowH;   // 最多 8 行，超出滚动
    CGFloat x = MIN(MAX(anchorRect.origin.x + anchorRect.size.width - width, 8.0),
                    window.bounds.size.width - width - 8.0);
    CGFloat y = anchorRect.origin.y + anchorRect.size.height + 6.0;
    if (y + tableH > window.bounds.size.height - 12.0) {
        y = MAX(anchorRect.origin.y - tableH - 6.0, 12.0);      // 放不下就往上弹
    }

    UIVisualEffectView *panel = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    panel.frame = CGRectMake(x, y, width, tableH);
    panel.layer.cornerRadius = 12.0;
    panel.layer.masksToBounds = YES;
    [container addSubview:panel];

    UITableView *menu = [[UITableView alloc] initWithFrame:panel.contentView.bounds
                                                     style:UITableViewStylePlain];
    menu.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.88];
    menu.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    menu.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    menu.scrollEnabled = (options.count > 8);
    menu.alwaysBounceVertical = NO;

    ERGestureDropdownBridge *bridge = [[ERGestureDropdownBridge alloc] initWithOptions:options
                                                                               current:current
                                                                                  pick:^(NSInteger idx) {
        onPick(idx);
        [UIView animateWithDuration:0.15 animations:^{ container.alpha = 0.0; }
                         completion:^(BOOL finished) { [container removeFromSuperview]; }];
    }];
    menu.dataSource = bridge;
    menu.delegate = bridge;
    objc_setAssociatedObject(container, @selector(erGestureMenuBridge), bridge, OBJC_ASSOCIATION_RETAIN);
    [panel.contentView addSubview:menu];

    [window addSubview:container];
    [UIView animateWithDuration:0.15 animations:^{ container.alpha = 1.0; }];
}

#pragma mark - 手势值 cell

// 行样式：左彩色圆角图标（iconImage 自带彩色底）+ 名称，右侧圆角描边下拉框
//（当前值 ⌄），点击弹出下拉浮层。cellClass 按名字解析（见 kERGestureValueCellClassName）。
@interface ERGestureValueCell : PSTableCell
@end

@implementation ERGestureValueCell {
    UILabel     *_title;
    UIImageView *_icon;
    UIButton    *_valueButton;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _icon = [[UIImageView alloc] initWithFrame:CGRectMake(16, 0, 27, 27)];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentView addSubview:_icon];

    _title = [[UILabel alloc] initWithFrame:CGRectZero];
    _title.font = [UIFont systemFontOfSize:16.0];
    _title.textColor = [UIColor colorWithWhite:1.0 alpha:0.95];
    [self.contentView addSubview:_title];

    _valueButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _valueButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    _valueButton.layer.cornerRadius = 8.0;
    _valueButton.layer.borderWidth = 1.0;
    _valueButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    _valueButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    // -Werror 下压制 iOS15 弃用告警：UIButtonConfiguration 不适用（自绘描边样式），
    // 这里就是要用老式 contentEdgeInsets 做内边距。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _valueButton.contentEdgeInsets = UIEdgeInsetsMake(5, 10, 5, 10);
#pragma clang diagnostic pop
    [_valueButton addTarget:self action:@selector(_erValueTapped)
           forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_valueButton];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.contentView.bounds.size.height;
    _icon.frame = CGRectMake(16, (h - 27) / 2.0, 27, 27);

    CGSize vs = [_valueButton sizeThatFits:CGSizeMake(160, 30)];
    CGFloat w = MIN(vs.width + 4, 160);
    _valueButton.frame = CGRectMake(self.contentView.bounds.size.width - w - 16,
                                    (h - 30) / 2.0, w, 30);
    CGFloat textX = 56;
    CGFloat textW = _valueButton.frame.origin.x - textX - 8;
    _title.frame = CGRectMake(textX, 0, MAX(textW, 40), h);
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (specifier) {
        objc_setAssociatedObject(self, @selector(_erGestureKey), specifier, OBJC_ASSOCIATION_RETAIN);
    }
    NSString *name = [specifier propertyForKey:@"label"];
    if ([name isKindOfClass:[NSString class]]) _title.text = name;

    UIImage *icon = [specifier propertyForKey:@"iconImage"];
    if (icon) _icon.image = icon;

    [self _erRefreshValue];
}

- (NSString *)_erGestureKey {
    PSSpecifier *spec = objc_getAssociatedObject(self, @selector(_erGestureKey));
    return spec ? [spec propertyForKey:@"erGestureKey"] : nil;
}

- (void)_erRefreshValue {
    NSString *key = [self _erGestureKey];
    if (!key.length) return;
    NSString *text = ERGestureValueText(ERGestureReadValue(key));
    [_valueButton setTitle:[text stringByAppendingString:@"  ⌄"] forState:UIControlStateNormal];
    [_valueButton setTitleColor:[UIColor colorWithRed:0.30 green:0.80 blue:1.00 alpha:1.0]
                       forState:UIControlStateNormal];
}

- (void)_erValueTapped {
    PSSpecifier *spec = objc_getAssociatedObject(self, @selector(_erGestureKey));
    NSString *key = [self _erGestureKey];
    if (!spec || !key.length) return;
    __weak typeof(self) wself = self;
    ERGestureShowDropdown(_valueButton, ERGestureValueText(ERGestureReadValue(key)), ^(NSInteger idx) {
        ERGestureWriteValue(key, idx);   // idx 0 = 无动作，1..N = 第n页
        [wself _erRefreshValue];
    });
}

@end

#pragma mark - 控制器

@implementation ERGestureController

- (NSBundle *)bundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        // ---- 卡片1 · 搜索胶囊 ----
        PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"搜索胶囊"];
        [g1 setProperty:@"开启后，桌面搜索胶囊支持四向滑动快速跳页；单击搜索不受影响。"
                 forKey:@"footerText"];
        [specs addObject:g1];
        [specs addObject:[self erSwitchNamed:@"搜索胶囊手势"
                                          key:@"HomeScreen.SearchPill.Enabled"
                                      symbols:@[@"hand.tap", @"hand.point.up.left.fill", @"cursorarrow.click"]
                                       color:@"teal"
                                      defVal:NO]];

        // ---- 卡片2 · 手势设置 ----
        PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:@"手势设置"];
        [g2 setProperty:@"「无动作」保持系统默认行为；选择某页后，触发对应滑动的瞬间直接跳到该页。"
                 forKey:@"footerText"];
        [specs addObject:g2];
        [specs addObject:[self erGestureNamed:@"上滑胶囊" key:@"HomeScreen.SearchPill.GestureUp"   symbol:@"arrow.up"    color:@"blue"]];
        [specs addObject:[self erGestureNamed:@"下滑胶囊" key:@"HomeScreen.SearchPill.GestureDown" symbol:@"arrow.down"  color:@"indigo"]];
        [specs addObject:[self erGestureNamed:@"左滑胶囊" key:@"HomeScreen.SearchPill.GestureLeft" symbol:@"arrow.left"  color:@"teal"]];
        [specs addObject:[self erGestureNamed:@"右滑胶囊" key:@"HomeScreen.SearchPill.GestureRight" symbol:@"arrow.right" color:@"purple"]];

        // ---- 卡片3 · 震动反馈 ----
        PSSpecifier *g3 = [PSSpecifier groupSpecifierWithName:@"震动反馈"];
        [g3 setProperty:@"手势触发成功时的触感反馈，强度分轻 / 中 / 重三档。"
                 forKey:@"footerText"];
        [specs addObject:g3];
        [specs addObject:[self erSwitchNamed:@"手势震动反馈"
                                          key:@"HomeScreen.SearchPill.HapticEnabled"
                                      symbols:@[@"iphone.radiowaves.left.and.right",
                                                @"dot.radiowaves.left.and.right",
                                                @"waveform"]
                                       color:@"orange"
                                      defVal:YES]];
        PSSpecifier *seg = [PSSpecifier preferenceSpecifierNamed:@"震动强度"
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:Nil
                                                            cell:PSTitleValueCell
                                                            edit:Nil];
        [seg setProperty:@"ERSegmentedCell" forKey:@"cellClass"];
        [seg setProperty:@"HomeScreen.SearchPill.HapticStrength" forKey:@"key"];
        [seg setProperty:kERGestureSuite forKey:@"defaults"];
        [seg setProperty:@1 forKey:@"default"];
        [seg setProperty:@[@"轻", @"中", @"重"] forKey:@"erSegmentTitles"];
        [seg setProperty:kERGestureReload forKey:@"PostNotification"];
        [seg setProperty:ERImageIconWithFallbacks(@[@"iphone.radiowaves.left.and.right",
                                                    @"dot.radiowaves.left.and.right",
                                                    @"waveform"],
                                                  nil, @"震", @"orange")
                  forKey:@"iconImage"];
        [specs addObject:seg];

        _specifiers = specs;
    }
    return _specifiers;
}

- (PSSpecifier *)erSwitchNamed:(NSString *)name
                            key:(NSString *)key
                        symbols:(NSArray<NSString *> *)symbols
                          color:(NSString *)color
                         defVal:(BOOL)defVal {
    PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:name
                                                     target:self
                                                        set:@selector(setPreferenceValue:specifier:)
                                                        get:@selector(readPreferenceValue:)
                                                     detail:Nil
                                                       cell:PSSwitchCell
                                                       edit:Nil];
    [sw setProperty:key forKey:@"key"];
    [sw setProperty:kERGestureSuite forKey:@"defaults"];
    [sw setProperty:@(defVal) forKey:@"default"];
    [sw setProperty:kERGestureReload forKey:@"PostNotification"];
    [sw setProperty:ERImageIconWithFallbacks(symbols, nil,
                                             [name substringToIndex:1], color)
             forKey:@"iconImage"];
    return sw;
}

- (PSSpecifier *)erGestureNamed:(NSString *)name
                            key:(NSString *)key
                         symbol:(NSString *)symbol
                          color:(NSString *)color {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name
                                                      target:self
                                                         set:NULL
                                                         get:NULL
                                                      detail:Nil
                                                        cell:PSTitleValueCell
                                                        edit:Nil];
    [row setProperty:kERGestureValueCellClassName forKey:@"cellClass"];
    [row setProperty:key forKey:@"erGestureKey"];
    [row setProperty:ERImageIconWithFallbacks(@[symbol], nil,
                                             [name substringToIndex:1], color)
              forKey:@"iconImage"];
    return row;
}

// PSSwitchCell 读写（CFPreferences 直读直写，与 ERSystemEnhanceController 同款）。
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    Boolean ok = NO;
    CFIndex v = CFPreferencesGetAppIntegerValue((__bridge CFStringRef)key,
                                                (__bridge CFStringRef)kERGestureSuite, &ok);
    if (ok) return @(v != 0);
    id def = [specifier propertyForKey:@"default"];
    return def ?: @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFNumberRef)@([value boolValue] ? 1 : 0),
                             (__bridge CFStringRef)kERGestureSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    notify_post(kERGestureReload.UTF8String);
}

- (instancetype)initForSpecifier:(__unused PSSpecifier *)specifier { return [self init]; }
- (instancetype)initWithSpecifier:(__unused PSSpecifier *)specifier { return [self init]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"桌面胶囊手势";
}

@end
