#import "ERWeatherContentViewController.h"
#import "ERWeatherBridge.h"

// ---------------------------------------------------------------------------
// 天气磁贴：4×1 单行 与 4×2 双行，同一个 identifier 自适应
// ---------------------------------------------------------------------------
// 1.0.6-12：参考插件（com.simon.ccweathermodule 1.0.4）声明的 CCSModuleSize 是
// 满宽 × 一行，也就是 4×1。本次把声明改成 Height 1 与参考插件对齐，同时保留
// 4×2：用户把磁贴拖大之后由 EchoReborn 的 gERCustomSizes 记录，控制器按
// **实测高度**在两套版式之间切换 —— 控制项里始终只有一个「天气」条目。
//
//   4×1（高度 ≤ 92pt，参考插件同款）
//   ┌──────────────────────────────────────────────────────┐
//   │ ☀️  深圳    23°        晴天   最高 26° 最低 18°       │
//   └──────────────────────────────────────────────────────┘
//
//   4×2（高度 > 92pt）
//   ┌──────────────────────────────────────────────────────┐
//   │ 城市名                                    ☀️          │
//   │ 23°                                                  │
//   │ 晴天-白天   最高 26°  最低 18°   降水 10%             │
//   │ ────────────────────────────────────────────────────  │
//   │ 现在   14时   15时   16时   17时 …                    │
//   │ 23°    24°    24°    23°    22°                       │
//   └──────────────────────────────────────────────────────┘
//
// 为什么按实测高度而不是按声明尺寸判断：磁贴的真实点数由 Control Center 决定，
// 横竖屏与机型都不同，读 bounds 是唯一可靠的输入；声明值只在「还没布局过」的
// 那一刻有用，不能当真值源。
//
// 布局一律用 Auto Layout 并挂在 content view 上，不假设任何具体点数。
// 所有颜色都用动态色（labelColor / secondaryLabelColor），深浅色模式自动跟随。

static const CGFloat kERWeatherInset = 14.0;
static const CGFloat kERWeatherGlyphSize = 40.0;
static const CGFloat kERWeatherCompactGlyphSize = 30.0;
static const CGFloat kERWeatherHourItemWidth = 42.0;
// 一行 ≈70pt、两行 ≈146pt，取中间值做分界。
static const CGFloat kERWeatherCompactHeightLimit = 92.0;

typedef NS_ENUM(NSInteger, ERWeatherLayoutMode) {
    ERWeatherLayoutModeUnknown = 0,
    ERWeatherLayoutModeCompact,
    ERWeatherLayoutModeRegular,
};

@interface ERWeatherContentViewController ()
@property (nonatomic, strong) UILabel *cityLabel;
@property (nonatomic, strong) UILabel *temperatureLabel;
@property (nonatomic, strong) UILabel *conditionLabel;
@property (nonatomic, strong) UILabel *highLowLabel;
@property (nonatomic, strong) UILabel *precipLabel;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UIView *dividerLine;
@property (nonatomic, strong) UIScrollView *hourlyScrollView;
@property (nonatomic, strong) UIStackView *hourlyContainer;
@property (nonatomic) BOOL built;
@property (nonatomic) BOOL observing;
@property (nonatomic, strong) UIStackView *detailRow;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *compactConstraints;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *regularConstraints;
@property (nonatomic) ERWeatherLayoutMode layoutMode;
@end

@implementation ERWeatherContentViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    // 1.0.6-13（第 2 条）：这一行是「天气模块到底有没有被控制中心装起来」的判据。
    //
    // 它出现 ⇒ bundle 已被加载、控制器已建、视图已进入层级；
    // 它不出现 ⇒ 问题在加载/注册那一侧（bundle 没被实例化），与天气数据无关。
    // 以前整条链路只有 ERWeatherModule 的 +load 一行，而 +load 只在镜像第一次被
    // dlopen 时跑一次，日志滚动之后就看不到了，无法区分上述两种情况。
    ERWeatherLog(@"content viewDidLoad bounds=%.0fx%.0f",
                 CGRectGetWidth(self.view.bounds), CGRectGetHeight(self.view.bounds));
    [self buildSubviewsIfNeeded];
    // 桥接器在首次 start 时才会去 dlopen 私有框架；放在这里而不是 +load，
    // 是为了让「用户从没添加过天气磁贴」的设备完全不付这份代价。
    [ERWeatherBridge.sharedBridge start];
    [self applySnapshot];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self startObservingIfNeeded];
    [ERWeatherBridge.sharedBridge refreshIfNeeded];
    [self applySnapshot];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // 磁贴离开屏幕就断开回调，避免桥接器持有一个已经不在层级里的控制器。
    [self stopObserving];
}

- (void)dealloc {
    [self stopObserving];
}

- (void)startObservingIfNeeded {
    if (self.observing) return;
    self.observing = YES;

    __weak typeof(self) weakSelf = self;
    ERWeatherBridge.sharedBridge.onUpdate = ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf applySnapshot];
    };

    // 桥接器只在拉取完成时回调一次；系统在后台把模型刷新掉时没有回调可用，
    // 所以额外挂一个「回到前台」通知，回前台时重新读一遍缓存。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(erApplicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)stopObserving {
    if (!self.observing) return;
    self.observing = NO;
    ERWeatherBridge.sharedBridge.onUpdate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidBecomeActiveNotification
                                                  object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 1.0.6-13（第 2 条）：真正「看得见」的那一刻再记一行，附带宿主链与窗口状态。
    //
    // window == nil 说明视图虽然在层级里，却被挂在一个离屏/未展示的宿主上 ——
    // 那正是「磁贴占着位置但什么都看不见」最直接的解释，也能一次性排除掉
    // 「是数据没拿到」这一类猜测。
    // 1.0.6-15（第 2 条）：加上**窗口坐标系里的真实位置**。
    //
    // 1.0.6-14 的日志里这一行是
    //   bounds=339x75 window=yes super=CCUIContentModuleContentContainerView
    //   alpha=1.00 hidden=0 —— 视图确实在层级里、可见、尺寸也对。
    // 既然「明明可见」而用户仍然说看不到，剩下的可能只有两个：内容被别的东西盖住，
    // 或者整块磁贴被排到了屏幕外（EchoReborn 自有的快捷指令磁贴在日志里就落在
    // cell={0,25} 这种网格之外的位置）。窗口坐标一打印就能二选一。
    CGRect windowFrame = self.view.window
        ? [self.view convertRect:self.view.bounds toView:self.view.window]
        : CGRectNull;
    ERWeatherLog(@"content viewDidAppear bounds=%.0fx%.0f windowFrame=%@ screen=%@ super=%@ alpha=%.2f hidden=%d live=%d %@",
                 CGRectGetWidth(self.view.bounds), CGRectGetHeight(self.view.bounds),
                 CGRectIsNull(windowFrame) ? @"(no window)" : NSStringFromCGRect(windowFrame),
                 NSStringFromCGRect(UIScreen.mainScreen.bounds),
                 NSStringFromClass(self.view.superview.class),
                 self.view.alpha, self.view.hidden,
                 ERWeatherBridge.sharedBridge.snapshot.hasLiveData,
                 ERWeatherDebugSummary());
}

- (void)erApplicationDidBecomeActive:(__unused NSNotification *)notification {
    [ERWeatherBridge.sharedBridge refreshIfNeeded];
    [self applySnapshot];
}

#pragma mark - 构建

- (void)buildSubviewsIfNeeded {
    if (self.built) return;
    self.built = YES;

    UIView *content = self.view;

    // ---- 头部：城市 / 天气图标 ----
    _cityLabel = [self erLabelWithSize:15.0 weight:UIFontWeightSemibold color:UIColor.labelColor];
    _cityLabel.text = @"天气";
    _cityLabel.accessibilityIdentifier = @"erWeatherCity";
    [content addSubview:_cityLabel];

    _iconView = [[UIImageView alloc] init];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.tintColor = UIColor.labelColor;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_iconView];

    // ---- 大号温度 ----
    _temperatureLabel = [self erLabelWithSize:38.0 weight:UIFontWeightLight color:UIColor.labelColor];
    _temperatureLabel.text = @"--°";
    [content addSubview:_temperatureLabel];

    // ---- 明细行：天气 / 最高最低 / 降水 ----
    // 三项共用一个横向 stack，缺项（文本为空）时自动收起，不会留下空洞。
    _conditionLabel = [self erLabelWithSize:13.0 weight:UIFontWeightMedium color:UIColor.labelColor];
    _highLowLabel = [self erLabelWithSize:12.0 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    _precipLabel = [self erLabelWithSize:12.0 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];

    // 1.0.6-12：明细行由属性持有 —— 4×1 版式要把它放到右侧同一行上。
    _detailRow = [[UIStackView alloc] initWithArrangedSubviews:@[_conditionLabel, _highLowLabel, _precipLabel]];
    _detailRow.axis = UILayoutConstraintAxisHorizontal;
    _detailRow.alignment = UIStackViewAlignmentFirstBaseline;
    _detailRow.spacing = 10.0;
    _detailRow.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_detailRow];

    // ---- 分割线 ----
    _dividerLine = [[UIView alloc] init];
    _dividerLine.backgroundColor = UIColor.separatorColor;
    _dividerLine.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_dividerLine];

    // ---- 小时条 ----
    _hourlyScrollView = [[UIScrollView alloc] init];
    _hourlyScrollView.showsHorizontalScrollIndicator = NO;
    _hourlyScrollView.showsVerticalScrollIndicator = NO;
    _hourlyScrollView.alwaysBounceHorizontal = YES;
    _hourlyScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_hourlyScrollView];

    _hourlyContainer = [[UIStackView alloc] init];
    _hourlyContainer.axis = UILayoutConstraintAxisHorizontal;
    _hourlyContainer.alignment = UIStackViewAlignmentFill;
    _hourlyContainer.spacing = 4.0;
    _hourlyContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [_hourlyScrollView addSubview:_hourlyContainer];

    // ---- 约束 ----
    // 左右一律用显式常量，不用 content.layoutMarginsGuide：那是宿主（Control
    // Center）的属性，platter 未设边距时它是 0，标签会直接贴到圆角边缘上。
    // 上下也统一用同一个常量，四条边的内缩因此是确定的。
    const CGFloat inset = kERWeatherInset;

    // 小时条内部的约束两套版式共用，建好就激活。
    [NSLayoutConstraint activateConstraints:@[
        [_hourlyContainer.topAnchor constraintEqualToAnchor:_hourlyScrollView.contentLayoutGuide.topAnchor],
        [_hourlyContainer.leadingAnchor constraintEqualToAnchor:_hourlyScrollView.contentLayoutGuide.leadingAnchor],
        [_hourlyContainer.trailingAnchor constraintEqualToAnchor:_hourlyScrollView.contentLayoutGuide.trailingAnchor],
        [_hourlyContainer.bottomAnchor constraintEqualToAnchor:_hourlyScrollView.contentLayoutGuide.bottomAnchor],
        [_hourlyContainer.heightAnchor constraintEqualToAnchor:_hourlyScrollView.frameLayoutGuide.heightAnchor],
    ]];

    // 4×2 双行版式（高度 > 92pt）。两套都先建不激活，由
    // -applyLayoutModeForHeight: 按实测高度挑一套打开。
    _regularConstraints = @[
        [_cityLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:inset],
        [_cityLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:inset],
        [_cityLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_iconView.leadingAnchor constant:-8.0],

        [_iconView.centerYAnchor constraintEqualToAnchor:_cityLabel.centerYAnchor],
        [_iconView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-inset],
        [_iconView.widthAnchor constraintEqualToConstant:kERWeatherGlyphSize],
        [_iconView.heightAnchor constraintEqualToConstant:kERWeatherGlyphSize],
        [_iconView.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8.0],

        [_temperatureLabel.topAnchor constraintEqualToAnchor:_cityLabel.bottomAnchor constant:6.0],
        [_temperatureLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:inset],
        [_temperatureLabel.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-inset],

        [_detailRow.topAnchor constraintEqualToAnchor:_temperatureLabel.bottomAnchor constant:2.0],
        [_detailRow.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:inset],
        [_detailRow.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-inset],

        [_dividerLine.topAnchor constraintEqualToAnchor:_detailRow.bottomAnchor constant:8.0],
        [_dividerLine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:inset],
        [_dividerLine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-inset],
        [_dividerLine.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],

        [_hourlyScrollView.topAnchor constraintEqualToAnchor:_dividerLine.bottomAnchor constant:6.0],
        [_hourlyScrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:inset],
        [_hourlyScrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-inset],
        [_hourlyScrollView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-inset],
    ];

    // 4×1 单行版式（高度 ≤ 92pt，与参考插件同一形态）：图标移到最左，城市 /
    // 温度 / 明细同处一行、整体垂直居中；分割线与小时条由
    // -applyLayoutModeForHeight: 隐藏。
    _compactConstraints = @[
        [_iconView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:inset],
        [_iconView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:kERWeatherCompactGlyphSize],
        [_iconView.heightAnchor constraintEqualToConstant:kERWeatherCompactGlyphSize],

        [_cityLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:8.0],
        [_cityLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],

        [_temperatureLabel.leadingAnchor constraintEqualToAnchor:_cityLabel.trailingAnchor constant:12.0],
        [_temperatureLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],

        [_detailRow.leadingAnchor constraintGreaterThanOrEqualToAnchor:_temperatureLabel.trailingAnchor constant:12.0],
        [_detailRow.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-inset],
        [_detailRow.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
    ];

    // 城市名比较长时截断而不是把图标挤出去。整体高度不够时优先压缩小时条，
    // 而不是把大号温度压变形。
    [_cityLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow - 1
                                                forAxis:UILayoutConstraintAxisHorizontal];
    [_temperatureLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                       forAxis:UILayoutConstraintAxisVertical];
    [_hourlyScrollView setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                       forAxis:UILayoutConstraintAxisVertical];

    [self applyLayoutModeForHeight:CGRectGetHeight(content.bounds)];
}

// 1.0.6-12：按实测高度在 4×1 / 4×2 两套版式之间切换。
//
// 阈值取 92pt：一行 ≈70pt、两行 ≈146pt，落在这个分界两侧都不含糊。只写真正
// 变化的东西（约束集、字号、隐藏项），所以稳态下重复调用是空操作，不会触发
// 额外的布局回合。
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self applyLayoutModeForHeight:CGRectGetHeight(self.view.bounds)];
}

- (void)applyLayoutModeForHeight:(CGFloat)height {
    if (!self.built || height <= 0.0) return;
    ERWeatherLayoutMode mode = (height <= kERWeatherCompactHeightLimit)
        ? ERWeatherLayoutModeCompact
        : ERWeatherLayoutModeRegular;
    if (mode == self.layoutMode) return;
    self.layoutMode = mode;
    BOOL compact = (mode == ERWeatherLayoutModeCompact);
    if (self.regularConstraints.count) {
        [NSLayoutConstraint deactivateConstraints:self.regularConstraints];
    }
    if (self.compactConstraints.count) {
        [NSLayoutConstraint deactivateConstraints:self.compactConstraints];
    }
    [NSLayoutConstraint activateConstraints:(compact ? self.compactConstraints : self.regularConstraints)];
    self.dividerLine.hidden = compact;
    self.hourlyScrollView.hidden = compact;
    self.cityLabel.font = [UIFont systemFontOfSize:compact ? 13.0 : 15.0 weight:UIFontWeightSemibold];
    self.temperatureLabel.font = [UIFont systemFontOfSize:compact ? 24.0 : 38.0 weight:UIFontWeightLight];
    ERWeatherLog(@"layout mode=%@ h=%.0f", compact ? @"4x1" : @"4x2", height);
}

- (UILabel *)erLabelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 1;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

#pragma mark - 应用数据

- (void)applySnapshot {
    if (!self.built) [self buildSubviewsIfNeeded];

    ERWeatherSnapshot *snapshot = ERWeatherBridge.sharedBridge.snapshot;

    self.cityLabel.text = snapshot.cityText.length ? snapshot.cityText : @"天气";
    self.temperatureLabel.text = snapshot.temperatureText.length ? snapshot.temperatureText : @"--°";
    self.conditionLabel.text = snapshot.conditionText;
    self.highLowLabel.text = snapshot.highLowText;
    self.highLowLabel.hidden = !snapshot.highLowText.length;
    self.precipLabel.text = snapshot.precipText;
    self.precipLabel.hidden = !snapshot.precipText.length;

    // 图标：框架自带的字形优先（WASymbolGlyphFromConditionCode），取不到时用
    // 本地代码表。两者都失败才有 setImage:nil 的可能，所以这里再兜一层 ——
    // 空白图标比一个不太贴切的图标更像 bug。
    NSString *symbolName = [ERWeatherBridge symbolNameForConditionCode:snapshot.conditionCode
                                                                 isDay:snapshot.isDay];
    UIImage *image = [UIImage systemImageNamed:symbolName];
    if (!image) image = [UIImage systemImageNamed:@"cloud.fill"];
    if (!image) image = [UIImage systemImageNamed:@"sun.max.fill"];
    self.iconView.image = image;
    // 占位态把图标压暗，这样「没有数据」和「数据是晴天」在视觉上不会混淆。
    self.iconView.tintColor = snapshot.hasLiveData ? UIColor.labelColor : UIColor.tertiaryLabelColor;
    self.cityLabel.textColor = snapshot.hasLiveData ? UIColor.labelColor : UIColor.secondaryLabelColor;

    [self rebuildHourlyStripWithSnapshot:snapshot];
}

- (void)rebuildHourlyStripWithSnapshot:(ERWeatherSnapshot *)snapshot {
    for (UIView *view in self.hourlyContainer.arrangedSubviews) {
        [self.hourlyContainer removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSArray<ERWeatherHour *> *hours = snapshot.hours;
    if (!hours.count) {
        // 没有小时数据时不要留一个空槽：画一行说明，磁贴整体仍然成立。
        UILabel *placeholder = [self erLabelWithSize:12.0 weight:UIFontWeightRegular color:UIColor.tertiaryLabelColor];
        placeholder.text = snapshot.hasLiveData ? @"暂无逐小时预报" : @"天气数据暂不可用";
        [self.hourlyContainer addArrangedSubview:placeholder];
        return;
    }

    for (ERWeatherHour *hour in hours) {
        [self.hourlyContainer addArrangedSubview:[self erItemForHour:hour]];
    }
}

- (UIView *)erItemForHour:(ERWeatherHour *)hour {
    UILabel *time = [self erLabelWithSize:11.0
                                   weight:hour.isNow ? UIFontWeightSemibold : UIFontWeightMedium
                                    color:hour.isNow ? UIColor.labelColor : UIColor.secondaryLabelColor];
    time.text = hour.timeText;
    time.textAlignment = NSTextAlignmentCenter;

    UIImageView *glyph = [[UIImageView alloc] init];
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    glyph.tintColor = UIColor.labelColor;
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *symbolName = [ERWeatherBridge symbolNameForConditionCode:hour.conditionCode
                                                                 isDay:hour.isDay];
    glyph.image = [UIImage systemImageNamed:symbolName] ?: [UIImage systemImageNamed:@"cloud.fill"];
    [glyph.widthAnchor constraintEqualToConstant:18.0].active = YES;
    [glyph.heightAnchor constraintEqualToConstant:18.0].active = YES;

    UILabel *temperature = [self erLabelWithSize:13.0
                                          weight:hour.isNow ? UIFontWeightSemibold : UIFontWeightRegular
                                           color:UIColor.labelColor];
    temperature.text = hour.temperatureText;
    temperature.textAlignment = NSTextAlignmentCenter;

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[time, glyph, temperature]];
    column.axis = UILayoutConstraintAxisVertical;
    column.alignment = UIStackViewAlignmentCenter;
    column.spacing = 3.0;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [column.widthAnchor constraintGreaterThanOrEqualToConstant:kERWeatherHourItemWidth].active = YES;
    return column;
}

#pragma mark - 尺寸提示

// CCUIContentModuleContentViewController 上的两个 @optional 提示项都不实现：
//   · CCSGetModuleSizeAtRuntime 在 Info.plist 里是 false，Control Center 用声明的
//     4×2，不会读 preferredExpandedContentHeight；
//   · providesOwnPlatter 保持默认 NO，由 Control Center 画 platter（与参考插件一致）。

@end
