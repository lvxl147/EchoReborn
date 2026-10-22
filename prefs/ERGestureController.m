#import "ERGestureController.h"
#import "ERUIHelpers.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <execinfo.h>
#import <signal.h>

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

void ERGPrefsLog(NSString *format, ...);
void ERGCrashWrite(NSString *header);
void ERGUncaughtHandler(NSException *exception);

// 1.2.0-10 · 浅色模式适配：深/浅色双态动态色（iOS 13+ dynamicProvider）。
static UIColor *ERGDynamic(UIColor *darkColor, UIColor *lightColor) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return (traits.userInterfaceStyle == UIUserInterfaceStyleDark) ? darkColor : lightColor;
    }];
}

static NSInteger ERGesturePageCount(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    Boolean ok = NO;
    CFIndex v = CFPreferencesGetAppIntegerValue(CFSTR("HomeScreen.PageCount"),
                                                (__bridge CFStringRef)kERGestureSuite, &ok);
    if (ok && v >= 1) return (NSInteger)v;
    return 10;   // SpringBoard 还没写过（respring 后首开）时的兜底
}

// 1.2.0-59 · 值升级为原始串：数字（CFNumber，旧版兼容）或 "folder:<id>"（CFString）
static NSString *ERGestureReadValue(NSString *key) {
    @try {
        CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
        CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                (__bridge CFStringRef)kERGestureSuite);
        if (!v) return @"0";
        id obj = (__bridge_transfer id)v;
        if ([obj isKindOfClass:[NSString class]]) return obj;
        if ([obj isKindOfClass:[NSNumber class]]) return [obj stringValue];
    } @catch (__unused NSException *e) {}
    return @"0";
}

static void ERGestureWriteValue(NSString *key, NSString *val) {
    if (![val hasPrefix:@"folder:"]) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFNumberRef)@([val integerValue]),
                                 (__bridge CFStringRef)kERGestureSuite);
    } else {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)val,
                                 (__bridge CFStringRef)kERGestureSuite);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    notify_post(kERGestureReload.UTF8String);
}

// 1.2.0-59 · 文件夹显示名：读 Tweak 落盘的 er_folders.plist（ctor 后 20s 生成）
static NSString *ERGestureFolderName(NSString *fid) {
    @try {
        NSArray<NSDictionary *> *arr = [NSArray arrayWithContentsOfFile:
            @"/var/mobile/Documents/er_folders.plist"];
        for (NSDictionary *d in arr)
            if ([d[@"id"] isKindOfClass:[NSString class]] && [d[@"id"] isEqualToString:fid])
                return d[@"name"] ?: @"文件夹";
    } @catch (__unused NSException *e) {}
    return @"文件夹";
}

// 1.2.0-40 · 最后一页是资源库：显示"资源库"而非"第N页"
// 1.2.0-56 · -1 = 负一屏（今天视图）
static NSString *ERGesturePageText(NSInteger value, NSInteger pageCount) {
    if (value == -1) return @"负一屏";
    if (value >= 1 && pageCount >= 1 && value == pageCount) return @"资源库";
    return value >= 1 ? [NSString stringWithFormat:@"第%ld页", (long)value] : @"无动作";
}

// 1.2.0-59 · 值文本：folder: 前缀显示文件夹名，其余走页码文本
static NSString *ERGestureValueText(NSString *raw) {
    if ([raw hasPrefix:@"folder:"]) return ERGestureFolderName([raw substringFromIndex:7]);
    return ERGesturePageText(raw.integerValue, ERGesturePageCount());
}

// 1.2.0-18 · 行标题取值修正：标题存在 specifier.name，propertyForKey:@"label"
// 返回 nil —— 自绘标题一直是空串（之前显示的文字是原生 textLabel 画的，
// 被我们 1.2.0-17 隐藏后就成了空白）。
static NSString *ERSpecLabel(PSSpecifier *spec) {
    if (!spec) return @"";
    NSString *n = [spec propertyForKey:@"label"];
    if (![n isKindOfClass:[NSString class]] || !n.length) n = spec.name;
    return n ?: @"";
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
    // 1.2.0-16 · 用户实锤浮层左侧一截多余空白：默认 cell 文字跟 layoutMargins 缩进
    // （约 16pt+）+ 分隔线 inset —— 全部归零，文字紧贴左缘只留固定 14pt。
    cell.layoutMargins = UIEdgeInsetsMake(0, 14.0, 0, 8.0);
    cell.preservesSuperviewLayoutMargins = NO;
    cell.separatorInset = UIEdgeInsetsMake(0, 14.0, 0, 0);
    cell.indentationLevel = 0;
    cell.indentationWidth = 0.0;
    if (@available(iOS 11.0, *)) cell.textLabel.insetsLayoutMarginsFromSafeArea = NO;
    NSString *opt = _options[(NSUInteger)indexPath.row];
    ERGPrefsLog(@"dropdown-64 row %ld text=%@ optionsCount=%lu",
                (long)indexPath.row, opt, (unsigned long)_options.count);
    cell.textLabel.text = opt;
    cell.textLabel.textColor = [opt isEqualToString:_current]
        ? [UIColor colorWithRed:0.30 green:0.80 blue:1.00 alpha:1.0]   // 当前值高亮青色
        : ERGDynamic([UIColor colorWithWhite:1.0 alpha:0.92],
                     [UIColor colorWithWhite:0.0 alpha:0.85]);
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (_pick) _pick(indexPath.row);
}
@end

#pragma mark - 下拉浮层

// 1.2.0-63 · 独立悬浮 UIWindow 方案：面板不再 addSubview 进设置 window
//（用户截图实锤：面板被表格内容压底，"文件夹 ›" 行被描述文字遮挡）。
// 每次弹出一个独立 UIWindow（同 windowScene、windowLevel 拉高），保证盖在一切之上。
@interface ERGestureOverlayCloser : NSObject
@property (nonatomic, strong) UIWindow *overlay;
- (void)dismiss;
@end
@implementation ERGestureOverlayCloser
- (void)dismiss {
    UIWindow *w = _overlay;
    if (!w || w.hidden) return;
    [UIView animateWithDuration:0.15 animations:^{ w.alpha = 0.0; }
                     completion:^(BOOL finished) {
        w.hidden = YES;
        w.rootViewController = nil;
    }];
    // 从静态持有表移除（释放窗口本身）
    static NSMutableArray<UIWindow *> *sERGestureOverlays;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sERGestureOverlays = [NSMutableArray new]; });
    [sERGestureOverlays removeObject:w];
}
@end

static void ERGestureShowDropdown(UIButton *anchor,
                                  NSArray<NSString *> *options,
                                  NSString *current,
                                  void (^onPick)(NSInteger idx)) {
    UIWindow *anchorWindow = anchor.window;
    if (!anchorWindow) return;

    static NSMutableArray<UIWindow *> *sERGestureOverlays;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sERGestureOverlays = [NSMutableArray new]; });
    // 先收掉上一个还开着的浮层（幂等）
    for (UIWindow *old in [sERGestureOverlays copy]) {
        old.hidden = YES; old.rootViewController = nil;
    }
    [sERGestureOverlays removeAllObjects];

    // 锚点在设置 window 内的坐标；overlay 与 anchorWindow 同尺寸，坐标系一致
    CGRect anchorRect = [anchor convertRect:anchor.bounds toView:anchorWindow];

    UIWindow *overlay = nil;
    UIWindowScene *scene = anchorWindow.windowScene;
    if (scene) overlay = [[UIWindow alloc] initWithWindowScene:scene];
    if (!overlay) overlay = [[UIWindow alloc] initWithFrame:anchorWindow.bounds];
    overlay.frame = anchorWindow.bounds;
    overlay.windowLevel = anchorWindow.windowLevel + 2000.0;   // 压过一切常规层级
    overlay.backgroundColor = UIColor.clearColor;

    UIViewController *rootVC = [[UIViewController alloc] initWithNibName:nil bundle:nil];
    rootVC.view.backgroundColor = UIColor.clearColor;
    overlay.rootViewController = rootVC;

    UIView *container = rootVC.view;
    container.frame = overlay.bounds;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.alpha = 0.0;

    ERGestureOverlayCloser *closer = [ERGestureOverlayCloser new];
    closer.overlay = overlay;

    // 透明遮罩：接住"点外面收起"。
    UIControl *backdrop = [[UIControl alloc] initWithFrame:container.bounds];
    backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.001];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [backdrop addTarget:closer action:@selector(dismiss)
       forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:backdrop];

    CGFloat rowH = 40.0;
    // 1.2.0-16 · 用户反馈还是有点宽、且左侧有一截多余空白：150 → 132（"第10页"
    // 15pt 字体约 55pt 宽，132 足够完整显示）；同时 cell 内边距归零（见下方 cellForRow）。
    CGFloat width = 132.0;
    CGFloat tableH = MIN((CGFloat)options.count, 8.0) * rowH;   // 最多 8 行，超出滚动
    CGFloat x = MIN(MAX(anchorRect.origin.x + anchorRect.size.width - width, 8.0),
                    overlay.bounds.size.width - width - 8.0);
    CGFloat y = anchorRect.origin.y + anchorRect.size.height + 6.0;
    if (y + tableH > overlay.bounds.size.height - 12.0) {
        y = MAX(anchorRect.origin.y - tableH - 6.0, 12.0);      // 放不下就往上弹
    }

    // 1.2.0-15 · 颜色恢复深浅自适应（用户：问题在宽度不在颜色）。
    UIVisualEffectView *panel = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.frame = CGRectMake(x, y, width, tableH);
    panel.layer.cornerRadius = 12.0;
    panel.layer.masksToBounds = YES;
    [container addSubview:panel];

    // 1.2.0-64 · 显式 frame（不再依赖 contentView.bounds 时序）+ 禁 safe-area
    // 内容Inset调整 + 显式行高 —— 独立 UIWindow 下 UITableView 布局行为实测异常
    //（-63 截图：3 项面板只渲染 ~98pt/2 行，像素实测行距 40pt 正常、宽度 132 正常）。
    UITableView *menu = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, width, tableH)
                                                     style:UITableViewStylePlain];
    if (@available(iOS 11.0, *)) {
        menu.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    menu.rowHeight = rowH;
    menu.estimatedRowHeight = rowH;
    menu.backgroundColor = ERGDynamic([UIColor colorWithWhite:0.10 alpha:0.88],
                                      [UIColor colorWithWhite:1.0 alpha:0.96]);
    menu.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    menu.separatorColor = ERGDynamic([UIColor colorWithWhite:1.0 alpha:0.10],
                                     [UIColor colorWithWhite:0.0 alpha:0.10]);
    menu.scrollEnabled = (options.count > 8);
    menu.alwaysBounceVertical = NO;

    ERGestureDropdownBridge *bridge = [[ERGestureDropdownBridge alloc] initWithOptions:options
                                                                               current:current
                                                                                  pick:^(NSInteger idx) {
        onPick(idx);
        [closer dismiss];
    }];
    menu.dataSource = bridge;
    menu.delegate = bridge;
    objc_setAssociatedObject(container, @selector(erGestureMenuBridge), bridge, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(container, @selector(erGestureOverlayCloser), closer, OBJC_ASSOCIATION_RETAIN);
    [panel.contentView addSubview:menu];

    // 1.2.0-63 · 静态持有 window（UIWindow 不会被系统自动持有），显示之
    [sERGestureOverlays addObject:overlay];
    overlay.hidden = NO;
    [UIView animateWithDuration:0.15 animations:^{ container.alpha = 1.0; }];

    // 1.2.0-64 · 诊断：布局完成后把关键几何落盘，定位"3 项只渲染 2 行"
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableString *vis = [NSMutableString string];
        for (UITableViewCell *c in menu.visibleCells) {
            [vis appendFormat:@"[%@]", c.textLabel.text ?: @""];
        }
        ERGPrefsLog(@"dropdown-64 cnt=%lu anchor=%@ overlay=%@ panel=%@ menu=%@ rows=%ld content=%@ vis=%@",
                    (unsigned long)options.count,
                    NSStringFromCGRect(anchorRect),
                    NSStringFromCGRect(overlay.frame),
                    NSStringFromCGRect(panel.frame),
                    NSStringFromCGRect(menu.frame),
                    (long)[menu numberOfRowsInSection:0],
                    NSStringFromCGSize(menu.contentSize),
                    vis);
    });
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
    UIImageView *_chevron;
}

// 1.2.0-1 · 闪退根因：PSListController 实例化 cellClass 用的入口是**三参版**
//   initWithStyle:reuseIdentifier:specifier:（ERSegmentedCell 同款），只实现两参版
//   会落到基类构造 —— 自绘控件全没建、refresh 链路崩。specifier 在这里就挂上。
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    ERGPrefsLog(@"value cell init spec=%@ key=%@",
                NSStringFromClass(specifier.class) ?: @"?",
                [specifier propertyForKey:@"erGestureKey"] ?: @"?");
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) return nil;
    if (specifier) {
        objc_setAssociatedObject(self, @selector(_erGestureKey), specifier, OBJC_ASSOCIATION_RETAIN);
    }
    [self _erBuildUI];
    return self;
}

- (void)_erBuildUI {
    if (_valueButton) return;   // 幂等
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    // 1.2.0-16 · 用户实锤「上下左右图标底下/上面好像还有一个图标、左边边缘多一点」：
    // 基类 refresh 会把同一张 iconImage 塞进原生 self.imageView（系统槽位位置与
    // 自建 _icon 差一点 → 双层叠加）。与开关行 1.2.0-15 同款修法：隐藏原生槽位。
    self.imageView.hidden = YES;
    self.imageView.image = nil;
    // 1.2.0-17 · 用户实锤「选完值后标题被图标盖住（上滑胶囊→囊）」：原生
    // textLabel 在 x≈16 渲染，压在自建图标下 —— 一并隐藏，只留自建 _title。
    self.textLabel.hidden = YES;
    self.textLabel.text = nil;
    self.detailTextLabel.hidden = YES;
    self.detailTextLabel.text = nil;

    _icon = [[UIImageView alloc] initWithFrame:CGRectMake(16, 0, 27, 27)];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentView addSubview:_icon];

    _title = [[UILabel alloc] initWithFrame:CGRectZero];
    _title.font = [UIFont systemFontOfSize:16.0];
    _title.textColor = ERGDynamic([UIColor colorWithWhite:1.0 alpha:0.95],
                                  [UIColor colorWithWhite:0.0 alpha:0.87]);
    [self.contentView addSubview:_title];

    _valueButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _valueButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    _valueButton.layer.cornerRadius = 8.0;
    _valueButton.layer.borderWidth = 1.0;
    _valueButton.layer.borderColor = ERGDynamic([UIColor colorWithWhite:1.0 alpha:0.25],
                                                [UIColor colorWithWhite:0.0 alpha:0.22]).CGColor;
    _valueButton.backgroundColor = ERGDynamic([UIColor colorWithWhite:1.0 alpha:0.06],
                                              [UIColor colorWithWhite:0.0 alpha:0.045]);
    // -Werror 下压制 iOS15 弃用告警：UIButtonConfiguration 不适用（自绘描边样式），
    // 这里就是要用老式 contentEdgeInsets 做内边距。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // 1.2.0-56 · 左内边距 10→3（用户拍板"就差一点点"）：文本可用宽度 +7pt，
    // 「第10/12/13页」完整显示；右侧与箭头槽不动。
    _valueButton.contentEdgeInsets = UIEdgeInsetsMake(5, 3, 5, 10);
#pragma clang diagnostic pop
    [_valueButton addTarget:self action:@selector(_erValueTapped)
           forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_valueButton];

    // 1.2.0-7 · 下拉框箭头：独立 SF Symbol（chevron.down），尺寸放大到原字符 ⌄ 的
    // 约 1.5 倍，且在按钮内垂直水平居中于右侧固定槽位（不再跟文字基线走）。
    // 1.2.0-9 · 用户反馈箭头再缩小（"10 改 8"的比例）：15pt → 12pt。
    UIImageSymbolConfiguration *chevCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12.0 weight:UIImageSymbolWeightSemibold];
    UIImage *chev = [UIImage systemImageNamed:@"chevron.down" withConfiguration:chevCfg];
    _chevron = [[UIImageView alloc] initWithImage:chev];
    // 1.2.0-11 · 箭头颜色也随深浅色（浅色下深灰，跟文字一致）。
    _chevron.tintColor = ERGDynamic([UIColor colorWithRed:0.30 green:0.80 blue:1.00 alpha:1.0],
                                    [UIColor colorWithWhite:0.15 alpha:1.0]);
    _chevron.contentMode = UIViewContentModeCenter;
    [_valueButton addSubview:_chevron];

    // specifier 若不是从 init 进来（某些版本走 refresh 才给），refresh 时已兜底关联。
    NSString *key = [self _erGestureKey];
    if (key.length) [self _erRefreshValue];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 1.2.0-10 · CGColor 不随深浅色自动切换，每帧重设（dynamic 色 取当前 trait 解析）。
    _valueButton.layer.borderColor =
        ERGDynamic([UIColor colorWithWhite:1.0 alpha:0.25],
                   [UIColor colorWithWhite:0.0 alpha:0.22]).CGColor;
    CGFloat h = self.contentView.bounds.size.height;
    // 1.2.0-7 · 图标与标题的左边距跟系统 layoutMargins 走（绝对定位 16 在不同机型
    // 上会比系统行"多出来一点"），标题起点 = 图标右缘 + 12。
    CGFloat left = self.contentView.layoutMargins.left;
    if (left < 1.0) left = 16.0;
    _icon.frame = CGRectMake(left, (h - 27) / 2.0, 27, 27);
    // 1.2.0-16 · 原生槽位每帧隐藏（super refresh 可能反复填回 image）。
    self.imageView.hidden = YES;
    self.imageView.image = nil;
    // 1.2.0-17 · 原生 textLabel 每帧隐藏。
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    CGFloat chevW = 14.0;
    // 1.2.0-17 · 用户再反馈按钮宽一点都显多（截图标红左段空白）：内边距 10→6、
    // 右侧留位 12→6，整按钮约收窄 14pt，仍完整容纳「第10页/无动作」。
    CGFloat pad = 6.0;
    // 1.2.0-13 · 统一宽度：所有下拉框按最宽值文本（"第10页"/"无动作"）定宽，
    // 不再随各自值伸缩（用户反馈宽度不一致 + 整体偏大）。
    static CGFloat sERMaxTSW = 0.0;
    if (sERMaxTSW < 1.0) {
        UIFont *f = _valueButton.titleLabel.font;
        CGSize t1 = [@"第10页" sizeWithAttributes:@{NSFontAttributeName: f}];
        CGSize t2 = [@"无动作" sizeWithAttributes:@{NSFontAttributeName: f}];
        sERMaxTSW = MAX(t1.width, t2.width);
    }
    CGFloat btnW = MIN(MAX(sERMaxTSW + pad * 2 + chevW + 6.0, 72.0), 216.0);
    CGFloat btnH = 30.0;
    CGFloat btnX = self.contentView.bounds.size.width - btnW - self.contentView.layoutMargins.right;
    _valueButton.frame = CGRectMake(btnX, (h - btnH) / 2.0, btnW, btnH);

    // 按钮内部：文字居左（pad 起，titleEdgeInsets 右侧给箭头让位），箭头独立居中于右侧槽位。
    // custom 按钮不走 UIButtonConfiguration，弃用告警在 -Werror 下需压制（contentEdgeInsets 同款）。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [_valueButton setTitleEdgeInsets:UIEdgeInsetsMake(0, 0, 0, chevW)];
#pragma clang diagnostic pop
    _chevron.center = CGPointMake(btnW - pad - chevW / 2.0 + 1.0, btnH / 2.0);
    CGFloat textX = left + 27 + 12;
    CGFloat textW = _valueButton.frame.origin.x - textX - 8;
    _title.frame = CGRectMake(textX, 0, MAX(textW, 40), h);
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    // 1.0.8-29 教训：基类 refresh 在自定义 cell 上可能抛 NSException（setTitle 收到
    // 非字符串 → SIGABRT）—— 本 cell 内容全部自绘，super 调用必须 @try 兜住。
    @try {
        [super refreshCellContentsWithSpecifier:specifier];
    } @catch (NSException *exception) {
        NSLog(@"[EchoReborn] ERGesture refresh threw: %@ -- %@", exception.name, exception.reason);
    }
    if (specifier) {
        objc_setAssociatedObject(self, @selector(_erGestureKey), specifier, OBJC_ASSOCIATION_RETAIN);
    }
    [self _erBuildUI];   // 兜底：init 链没走到时在这里补建
    NSString *name = ERSpecLabel(specifier);
    if (name.length) _title.text = name;

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
    // 1.2.0-7 · 箭头不再拼进标题字符串（字符 ⌄ 小且随基线偏移），独立 _chevron 渲染。
    [_valueButton setTitle:text forState:UIControlStateNormal];
    // 1.2.0-11 · 浅色模式文字改黑（深色保持青色高亮）。
    [_valueButton setTitleColor:ERGDynamic([UIColor colorWithRed:0.30 green:0.80 blue:1.00 alpha:1.0],
                                            [UIColor colorWithWhite:0.05 alpha:1.0])
                       forState:UIControlStateNormal];
    [self setNeedsLayout];
}

- (void)_erValueTapped {
    PSSpecifier *spec = objc_getAssociatedObject(self, @selector(_erGestureKey));
    NSString *key = [self _erGestureKey];
    if (!spec || !key.length) return;
    // 1.2.0-11 · 筛选：收集其余三个手势已占用的页码，页码子菜单不再提供。
    NSArray<NSString *> *allKeys = @[@"HomeScreen.SearchPill.GestureUp",
                                     @"HomeScreen.SearchPill.GestureDown",
                                     @"HomeScreen.SearchPill.GestureLeft",
                                     @"HomeScreen.SearchPill.GestureRight"];
    NSMutableArray<NSNumber *> *taken = [NSMutableArray array];
    for (NSString *k in allKeys) {
        if ([k isEqualToString:key]) continue;
        // 1.2.0-59 · 值是原始串，folder: 不占页码
        NSString *raw = ERGestureReadValue(k);
        if ([raw hasPrefix:@"folder:"]) continue;
        NSInteger v = raw.integerValue;
        if (v >= 1) [taken addObject:@(v)];
    }
    __weak typeof(self) wself = self;
    UIButton *btn = _valueButton;

    // 1.2.0-59 · 两级下拉（用户拍板）：一级=无动作/桌面页›/文件夹›（›=子菜单标识，
    // 必须再选一次才落到具体值）；二级=页码序列（负一屏+各页，末页资源库）或文件夹列表。
    void (^pick)(NSInteger) = ^(NSInteger idx) {
        if (idx == 0) {   // 无动作
            ERGestureWriteValue(key, @"0");
            [wself _erRefreshValue];
            return;
        }
        if (idx == 1) {   // 桌面页 ›
            NSInteger cnt = ERGesturePageCount();
            NSMutableArray<NSString *> *opts = [NSMutableArray arrayWithObject:@"负一屏"];
            NSMutableArray<NSNumber *> *avail = [NSMutableArray array];
            for (NSInteger p = 1; p <= cnt; p++) {
                if (![taken containsObject:@(p)]) {
                    [avail addObject:@(p)];
                    [opts addObject:ERGesturePageText(p, cnt)];
                }
            }
            ERGestureShowDropdown(btn, opts,
                                   ERGestureValueText(ERGestureReadValue(key)),
                                   ^(NSInteger i2) {
                NSString *val = (i2 == 0) ? @"-1"
                    : (i2 - 1 < (NSInteger)avail.count ? avail[i2 - 1].stringValue : @"0");
                ERGestureWriteValue(key, val);
                [wself _erRefreshValue];
            });
            return;
        }
        // 文件夹 ›：读 Tweak 落盘的列表
        NSArray<NSDictionary *> *folders = [NSArray arrayWithContentsOfFile:
            @"/var/mobile/Documents/er_folders.plist"];
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (NSDictionary *d in folders) {
            NSString *fid = d[@"id"];
            if (![fid isKindOfClass:[NSString class]] || !fid.length) continue;
            [ids addObject:fid];
            [names addObject:(d[@"name"] ?: fid)];
        }
        if (!ids.count) {
            [names removeAllObjects];
            [names addObject:@"未获取到（respring 后重试）"];
        }
        ERGestureShowDropdown(btn, names,
                               ERGestureValueText(ERGestureReadValue(key)),
                               ^(NSInteger i2) {
            if (i2 < (NSInteger)ids.count) {
                ERGestureWriteValue(key, [@"folder:" stringByAppendingString:ids[i2]]);
                [wself _erRefreshValue];
            }
        });
    };
    // 1.2.0-62 · 诊断：确认设置进程加载的是新代码（一级应为 3 项）
    ERGPrefsLog(@"gesture dropdown open key=%@ code=-64 level1=3", key);
    ERGestureShowDropdown(btn, @[@"无动作", @"桌面页 ›", @"文件夹 ›"],
                          ERGestureValueText(ERGestureReadValue(key)), pick);
}

@end

#pragma mark - 手势页开关 cell（1.2.0-13）

// 1.2.0-13 · 彻底换方案：Theos 头文件把 PSSwitchCell 声明为枚举成员（无法编译期
// 子类化），运行期注册类又因黑盒原因图标始终不显示（1.2.0-10~12 三版实测）。
// 改用**本页已验证可行的 ERGestureValueCell 同款自绘**：继承 PSTableCell（可
// 编译期子类化），彩色图标 + 标题 + 自放 UISwitch，读写走 CFPreferences（与
// 下拉框同一链路），PostNotification 实时生效。不再依赖 PSSwitchCell 任何布局。
static BOOL ERGSwitchRead(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    CFTypeRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                            (__bridge CFStringRef)kERGestureSuite);
    BOOL val = NO;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
            val = CFBooleanGetValue((CFBooleanRef)v);
        } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            val = [(__bridge NSNumber *)v boolValue];
        }
        CFRelease(v);
    }
    return val;
}

static void ERGSwitchWrite(NSString *key, BOOL val) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFBooleanRef)@(val),
                             (__bridge CFStringRef)kERGestureSuite);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    notify_post(kERGestureReload.UTF8String);
}

@interface ERGestureSwitchCell : PSTableCell
@end

@implementation ERGestureSwitchCell {
    UIImageView *_erIcon;
    UILabel     *_erTitle;
    UISwitch    *_erSwitch;
    PSSpecifier *_erSpec;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) return nil;
    _erSpec = specifier;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _erIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _erIcon.contentMode = UIViewContentModeScaleAspectFit;
    _erIcon.userInteractionEnabled = NO;
    _erIcon.image = [specifier propertyForKey:@"iconImage"];
    [self.contentView addSubview:_erIcon];

    _erTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _erTitle.font = [UIFont systemFontOfSize:16.0];
    _erTitle.text = ERSpecLabel(specifier);
    _erTitle.textColor = ERGDynamic([UIColor colorWithWhite:1.0 alpha:0.95],
                                    [UIColor colorWithWhite:0.0 alpha:0.87]);
    [self.contentView addSubview:_erTitle];

    _erSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    [_erSwitch addTarget:self action:@selector(_erToggled:)
        forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_erSwitch];
    [self _erSyncSwitch];
    return self;
}

- (void)_erSyncSwitch {
    NSString *key = [_erSpec propertyForKey:@"key"];
    if (!key.length) return;
    // 无历史值时用 specifier 的 default（搜索胶囊手势=NO，震动反馈=YES）。
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERGestureSuite);
    CFTypeRef cur = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                              (__bridge CFStringRef)kERGestureSuite);
    if (cur) {
        CFRelease(cur);
        _erSwitch.on = ERGSwitchRead(key);
    } else {
        NSNumber *def = [_erSpec propertyForKey:@"default"];
        _erSwitch.on = def.boolValue;
    }
}

- (void)_erToggled:(UISwitch *)sw {
    NSString *key = [_erSpec propertyForKey:@"key"];
    if (!key.length) return;
    ERGSwitchWrite(key, sw.on);
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    // 1.0.8-29 教训：基类 refresh 在自定义 cell 上可能抛异常，@try 兜住。
    @try {
        [super refreshCellContentsWithSpecifier:specifier];
    } @catch (__unused NSException *e) {}
    if (specifier) _erSpec = specifier;
    // 1.2.0-17 · 用户实锤「文字被图标遮住开头（如 胶囊手势→囊手势）」：原生
    // textLabel/detailTextLabel 在 x≈16 处渲染 specifier label，压在我们 29pt
    // 图标底下 —— 与 imageView 一并隐藏，只留自建 _erTitle（与下拉框行同基准对齐）。
    self.textLabel.hidden = YES;
    self.textLabel.text = nil;
    self.detailTextLabel.hidden = YES;
    self.detailTextLabel.text = nil;
    // 1.2.0-15 · 用户实锤「有个图标遮在上面」：原生 imageView 也在渲染同一张
    // iconImage（白网格那层）——直接隐藏原生槽位，只留自建图标。
    self.imageView.hidden = YES;
    self.imageView.image = nil;
    _erIcon.image = [_erSpec propertyForKey:@"iconImage"];
    _erTitle.text = ERSpecLabel(_erSpec);
    [self _erSyncSwitch];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    @try {
        // 1.2.0-14 · 修「图标只显示一点/偏左」：布局时行高可能还是过渡值导致 y 为负
        // 被裁切 → 行高 <40 时按 44 兜底；左边距用绝对 16 与震动强度行对齐；
        // 图标用原生 29pt（与工厂图 29x29 一致，避免 AspectFit 缩进）。
        CGFloat h = self.contentView.bounds.size.height;
        if (h < 40.0) h = 44.0;
        // 1.2.0-16 · 用户实锤开关行图标与上下左右行没对齐：gesture 行用的是
        // layoutMargins.left 基准，开关行还是绝对 16 —— 统一改成同一基准。
        CGFloat left = self.contentView.layoutMargins.left;
        CGFloat right = self.contentView.layoutMargins.right;
        if (left < 1.0) left = 16.0;
        if (right < 1.0) right = 16.0;
        CGFloat w = self.contentView.bounds.size.width;
        if (w < 1.0) return;
        self.imageView.hidden = YES;   // 1.2.0-15 双图标修：原生槽位每帧隐藏
        // 1.2.0-17 · 原生 textLabel 每帧隐藏（super refresh 可能反复填回）。
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;
        _erIcon.frame = CGRectMake(left, (h - 29.0) / 2.0, 29.0, 29.0);
        CGSize swSize = _erSwitch.bounds.size;
        if (swSize.width < 1.0) swSize = CGSizeMake(51.0, 31.0);
        _erSwitch.frame = CGRectMake(w - right - swSize.width,
                                     (h - swSize.height) / 2.0,
                                     swSize.width, swSize.height);
        CGFloat lx = left + 29.0 + 12.0;
        _erTitle.frame = CGRectMake(lx, 0,
                                    _erSwitch.frame.origin.x - lx - 12.0, h);
    } @catch (__unused NSException *e) {}
}

@end

#pragma mark - 控制器

@implementation ERGestureController

// ---- 1.2.0-3 · 自带崩溃记录器 ----
// 设备上 CrashReporter 目录不存在（系统 .ips 一个都拿不到），"点手势管理闪退"
// 已经盲修了一版还崩。这里把命运掌握在自己手里：
//   · 关键步骤面包屑 → /var/mobile/Documents/EchoReborn-prefs.log（设置 App 以
//     mobile 身份可写，与主插件的日志导出目录同一出处）
//   · NSSetUncaughtExceptionHandler + SIGABRT/SIGSEGV/SIGBUS/SIGILL 信号处理器
//     → /var/mobile/Documents/EchoReborn-crash.txt（异常名/原因 + 符号化调用栈）
// 注意：不能加 static——ERRootListController.m 的面包屑要跨文件链接它（1.2.0-4 链接错误教训）。
// 1.2.0-5：写文件多路径兜底——实测 1.2.0-4 构造函数代码在设备 bundle 里存在、
// SSH mobile 可写 Documents，但 Preferences 进程一个字节都没写出来，判定为
// Preferences 进程沙盒拦截。改为逐路径尝试：Documents → /var/tmp → 进程沙盒 tmp，
// 全部失败时把 errno 记到控制台（NSLog 也在系统日志里可见）。
static NSArray *ERGLogPaths(void) {
    static NSArray *paths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *doc = @"/var/mobile/Documents/EchoReborn-prefs.log";
        NSString *vartmp = @"/var/tmp/EchoReborn-prefs.log";
        NSString *sandbox = [NSTemporaryDirectory() stringByAppendingPathComponent:@"EchoReborn-prefs.log"];
        paths = @[doc, vartmp, sandbox];
    });
    return paths;
}

void ERGPrefsLog(NSString *format, ...) {
    @try {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterNoStyle
                                                         timeStyle:NSDateFormatterMediumStyle],
                          message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        BOOL wrote = NO;
        NSString *errDesc = @"";
        for (NSString *path in ERGLogPaths()) {
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
            if (h) {
                @try {
                    [h seekToEndOfFile];
                    [h writeData:data];
                    [h closeFile];
                    wrote = YES;
                    break;
                } @catch (NSException *e) {
                    errDesc = [NSString stringWithFormat:@"%@: %@", path, e.reason];
                }
            } else {
                NSError *err = nil;
                if ([data writeToFile:path options:NSDataWritingAtomic error:&err]) {
                    wrote = YES;
                    break;
                }
                errDesc = [NSString stringWithFormat:@"%@: %@ (errno %d)", path, err.localizedDescription, errno];
            }
        }
        if (!wrote) {
            NSLog(@"[ERGPrefs] log write FAILED: %@", errDesc);
            NSLog(@"[ERGPrefs] %@", line);
        }
    } @catch (__unused NSException *e) {}
}

void ERGCrashWrite(NSString *header) {
    @try {
        void *frames[64];
        int n = backtrace(frames, 64);
        char **syms = backtrace_symbols(frames, n);
        NSMutableString *text = [NSMutableString stringWithFormat:
            @"==== %@ %@ ====\n", [NSDate date].description, header];
        for (int i = 0; i < n; i++) {
            [text appendFormat:@"%s\n", syms[i]];
        }
        if (syms) free(syms);
        // 与 ERGPrefsLog 同款多路径兜底（Documents → /var/tmp → 沙盒 tmp）
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *paths = @[@"/var/mobile/Documents/EchoReborn-crash.txt",
                           @"/var/tmp/EchoReborn-crash.txt",
                           [[NSTemporaryDirectory() stringByAppendingPathComponent:@"EchoReborn-crash.txt"] copy]];
        for (NSString *path in paths) {
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
            if (h) {
                @try {
                    [h seekToEndOfFile];
                    [h writeData:data];
                    [h closeFile];
                    return;
                } @catch (NSException *e) {}
            } else if ([data writeToFile:path options:NSDataWritingAtomic error:nil]) {
                return;
            }
        }
        NSLog(@"[ERGPrefs] crash write FAILED all paths:\n%@", text);
    } @catch (__unused NSException *e) {}
}

static void ERGSignalHandler(int sig) {
    ERGCrashWrite([NSString stringWithFormat:@"SIGNAL %d", sig]);
    // 恢复默认处置并重发，让系统照常终止（不拦死进程）。
    signal(sig, SIG_DFL);
    raise(sig);
}

static void ERGInstallCrashReporter(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSSetUncaughtExceptionHandler(&ERGUncaughtHandler);
        signal(SIGABRT, ERGSignalHandler);
        signal(SIGSEGV, ERGSignalHandler);
        signal(SIGBUS,  ERGSignalHandler);
        signal(SIGILL,  ERGSignalHandler);
        ERGPrefsLog(@"crash reporter installed");
    });
}

void ERGUncaughtHandler(NSException *exception) {
    ERGCrashWrite([NSString stringWithFormat:@"EXCEPTION %@ -- %@\n%@",
                   exception.name, exception.reason, exception.callStackSymbols]);
}

// 1.2.0-4：崩溃记录器挂到 bundle 构造函数——只要偏好 bundle 被加载就立即生效，
// 无论之后崩在 ERRootListController / ERGestureController / 任何 cell，都能拿到
// NSException 的 name + reason（系统 .ips 里没有 reason，这是我们唯一的实锤渠道）。
__attribute__((constructor)) static void ERGPrefsBundleBootstrap(void) {
    ERGInstallCrashReporter();
    ERGPrefsLog(@"prefs bundle loaded (constructor)");
}

- (NSBundle *)bundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        ERGPrefsLog(@"specifiers build start");
        NSMutableArray *specs = [NSMutableArray array];

        // ---- 卡片1 · 搜索胶囊（1.2.0-7：与手势设置合并为一张卡片） ----
        PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"搜索胶囊"];
        [g1 setProperty:@"开启后，桌面搜索胶囊支持四向滑动快速跳页，单击搜索不受影响。手放在胶囊中心附近朝一个方向滑，滑够「触发范围」距离会震动提示，松手后跳到对应页；「无动作」保持系统默认行为。"
                 forKey:@"footerText"];
        [specs addObject:g1];
        [specs addObject:[self erSwitchNamed:@"搜索胶囊手势"
                                          key:@"HomeScreen.SearchPill.Enabled"
                                      symbols:@[@"hand.tap", @"hand.point.up.left.fill", @"cursorarrow.click"]
                                       color:@"teal"
                                      defVal:NO]];
        [specs addObject:[self erGestureNamed:@"上滑胶囊" key:@"HomeScreen.SearchPill.GestureUp"   symbol:@"arrow.up"    color:@"blue"]];
        [specs addObject:[self erGestureNamed:@"下滑胶囊" key:@"HomeScreen.SearchPill.GestureDown" symbol:@"arrow.down"  color:@"blue"]];
        [specs addObject:[self erGestureNamed:@"左滑胶囊" key:@"HomeScreen.SearchPill.GestureLeft" symbol:@"arrow.left"  color:@"teal"]];
        [specs addObject:[self erGestureNamed:@"右滑胶囊" key:@"HomeScreen.SearchPill.GestureRight" symbol:@"arrow.right" color:@"teal"]];
        // 1.2.0-21 · 触发范围滑块行（用户需求）：右滑胶囊下面，左图标+文字、右滑块。
        [specs addObject:[self erSliderNamed:@"触发范围"
                                          key:@"HomeScreen.SearchPill.TriggerRange"
                                          min:10 max:80 def:20
                                       symbol:@"arrow.up.left.and.arrow.down.right"
                                        color:@"blue"]];

        // ---- 卡片2 · 震动反馈 ----
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
        Class segCellClass = NSClassFromString(@"ERSegmentedCell");
        if (!segCellClass) segCellClass = [PSTableCell class]; // 兜底：绝不给 PS 传字符串
        [seg setProperty:segCellClass forKey:@"cellClass"];
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
        ERGPrefsLog(@"specifiers build done count=%lu", (unsigned long)specs.count);
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
    // 1.2.0-13 · 编译期 ERGestureSwitchCell：开关交基类，图标自建 UIImageView。
    [sw setProperty:[ERGestureSwitchCell class] forKey:@"cellClass"];
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
    // 1.2.0-6 闪退实锤修复：cellClass 必须传**类对象**——PS 在 cellForRow 里对
    // [spec cellClass] 直接发 isSubclassOfClass:（崩溃日志
    // -[__NSCFConstantString isSubclassOfClass:] unrecognized selector）。
    // 其它页的字符串写法没崩只是因为那些代码行是 plist 装载失败时的兜底、从未执行；
    // plist 解析器会转换字符串，setProperty 不会。本页纯代码构建，必须传 Class。
    [row setProperty:[ERGestureValueCell class] forKey:@"cellClass"];
    [row setProperty:key forKey:@"erGestureKey"];
    [row setProperty:ERImageIconWithFallbacks(@[symbol], nil,
                                             [name substringToIndex:1], color)
              forKey:@"iconImage"];
    return row;
}

// 1.2.0-22 · 触发范围滑块行改用界面优化「操作按钮」同款 ERSliderTrackCell
// （ERSliderCell.m 已在本 bundle 编译清单内）：图标 · 标题 · [−] · 滑轨 · [+] ·
// 读数居中，双击读数可直接键入。构造与 ERSystemEnhanceController.erSliderNamed
// 逐项对齐（cellClass 字符串运行期解析 + CFPreferences 自读写 + height 54）。
- (PSSpecifier *)erSliderNamed:(NSString *)name
                            key:(NSString *)key
                            min:(NSInteger)minV
                            max:(NSInteger)maxV
                            def:(NSInteger)defV
                         symbol:(NSString *)symbol
                          color:(NSString *)color {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name
                                                      target:self
                                                         set:NULL
                                                         get:NULL
                                                      detail:Nil
                                                        cell:PSSliderCell
                                                        edit:Nil];
    // 1.2.0-23 · 崩溃实锤（Preferences .ips：cellForRow → doesNotRecognizeSelector）：
    // 代码构建的 specifier cellClass 不能传字符串（plist 装载会自动转类，setProperty
    // 不会）——必须 NSClassFromString 运行期解析成类对象；解析失败兜底 PSTableCell，
    // 绝不给 PS 传字符串。
    Class sliderCell = NSClassFromString(@"ERSliderTrackCell");
    if (!sliderCell) sliderCell = [PSTableCell class];
    [row setProperty:sliderCell forKey:@"cellClass"];
    [row setProperty:key forKey:@"key"];
    [row setProperty:kERGestureSuite forKey:@"defaults"];
    [row setProperty:@(defV) forKey:@"default"];
    [row setProperty:@(minV) forKey:@"min"];
    [row setProperty:@(maxV) forKey:@"max"];
    [row setProperty:@54.0 forKey:@"height"];
    [row setProperty:@YES forKey:@"showValue"];
    [row setProperty:@NO forKey:@"isContinuous"];
    [row setProperty:kERGestureReload forKey:@"PostNotification"];
    // 1.2.0-24 · 用户截图实锤标题空白：ERSliderTrackCell 标题读 label/name 属性，
    // 代码构建的 specifier 不会自动生成 label property —— 手动补上。
    [row setProperty:name forKey:@"label"];
    // symbol 换增强页已验证有效的候选组合（"arrow.up.left.and.arrow.down.right"
    // 在 iOS17.2 渲染成白块）。
    [row setProperty:ERImageIconWithFallbacks(@[@"arrow.up.and.down",
                                                @"arrow.left.and.right",
                                                @"plusminus"],
                                              nil,
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

- (instancetype)initForSpecifier:(__unused PSSpecifier *)specifier {
    ERGPrefsLog(@"controller initForSpecifier");
    ERGInstallCrashReporter();
    return [self init];
}
- (instancetype)initWithSpecifier:(__unused PSSpecifier *)specifier {
    ERGPrefsLog(@"controller initWithSpecifier");
    ERGInstallCrashReporter();
    return [self init];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    ERGPrefsLog(@"viewDidLoad title=%@ specifiers=%lu", self.title,
                (unsigned long)self.specifiers.count);
    // 1.2.0-7：页面标题与入口行文字统一为「手势管理」（只改显示文字）。
    self.title = @"手势管理";
}

@end
