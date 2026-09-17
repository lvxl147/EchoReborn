#import "ERSliderCell.h"
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <math.h>

// 滑杆行（0.5.23 引入，1.0.0 重写）
// ===========================================================================
// 用户诉求（1.0.0）：
//   ① 「Siri 外观」分区下的滑块和数值完全不显示 —— 排查并修复；
//   ② 该分区右侧所有滑杆的宽度统一为一致值，对齐美观；
//   ③ 数值要清晰可见。
//
// 0.5.23~0.5.27 的做法及它为什么不可靠（本次的问题根因）：
//   那一版在 +load 里用 objc_allocateClassPair 造一个 PSSliderCell 的**运行期**
//   子类，再把 plist 的 `cellClass` 指到它，期望「继承基类画好的滑杆 + 覆写几何」。
//   但 `PSSliderCell` 这个名字在运行期并不存在（Theos 的
//   Preferences/PSTableCell.h 把它声明成了 PSCellType 枚举成员，真正的 cell 类
//   由框架按 `cell` 名映射得到）。于是那一版实际退化成「PSTableCell 子类」：
//   refreshCellContentsWithSpecifier: 走普通 cell 分支 —— **只有标题文字、
//   没有滑杆、没有读数**，行高也回落成默认 44pt。真机截图证实：Soko 页与
//   iOS27 Siri 页的滑杆行全部只剩下标题。
//   （那一版 layoutSubviews 里的 convertRect 坐标系换算，也只是在给一个并不存在
//     的滑杆算位置。）
//
// 现在的做法：**不再依赖任何私有滑杆类**，自己画。
//   · 编译期 `@interface ERSliderTrackCell : PSTableCell`。PSTableCell 是
//     Preferences 里确定存在的类（ERSegmentedCell 用的就是它，0.5.22 起在生产
//     验证过），`cellClass` 按名字解析必然命中。
//   · 标题、滑杆（UISlider）、读数（UILabel）自己创建、**手动布局**，全部只用
//     contentView.bounds 一个坐标系算，不做任何 convertRect 换算 —— 几何确定。
//   · 读 / 写走 CFPreferences + specifier 自带的 defaults / key /
//     PostNotification，与 ERSegmentedCell 完全同一套路径（不碰私有 API，落盘域
//     与通知与 PSListController -setPreferenceValue:specifier: 完全一致）。
//
// 版式（1.0.3 起：标题在左、滑轨在中、读数在右，滑轨两侧各一枚步进按钮，同一行）：
//
//     ┌─ contentView ────────────────────────────────────────────────────┐
//     │ 16  [图标 29]  [标题列 88]  8  (−)  5  [———滑轨———]  5  (+)  [读数 52]  16 │
//     └──────────────────────────────────────────────────────────────────┘
//
//   标题列宽是**固定值**，每行都用同一个值算，所以滑杆的左边界与右边界逐行相同
//   —— 宽度天然统一，这就是「把该分区右侧所有滑杆宽度统一为一致值」。窄屏（横屏
//   分屏）下标题列等比收窄，滑杆宽度依旧逐行一致。
//
// ---------------------------------------------------------------------------
// 1.0.3 三处交互调整（用户逐项提出）
// ---------------------------------------------------------------------------
//   ① 滑轨左右两侧各加一枚 26pt 的 − / + 按钮，点一下按步长增减（左减右加，
//      版式参考用户给的图片）。UISlider 本体、轨道外观、圆点尺寸全部保持不变，
//      只是把列宽重新分配、给按钮腾出位置。
//      步长：整数读数的行按 1，小数读数的行按 0.1 —— 判据与读数的取整条件一致
//      （见 -erStepSize），保证「点一下」正好等于读数会变化的那一位。
//   ② 双击读数 → 原地换成输入框，直接键入精确数值（避免拖滑轨「拖过头 / 拖不到」）。
//      回车或失焦提交，超范围自动钳制，非数字输入一律当作取消。
//   ③ 读数由「贴右边缘右对齐」改为「以上方开关的横向中心为中心居中」
//      （见 ERValueColumnCenter）：UISwitch 宽 51pt、贴内容区右侧 16pt，中心在
//      W-41.5；52pt 的读数格就摆在这个中心上，于是每行数字都落在其上方开关的正下方。
//
// 行高由 plist 的 `height` 指定（54pt）；即使框架忽略该键回落到 44pt，所有元素
// 都是**纵向居中**的，照样完整可见 —— 不会像「标题在上、滑杆在下」的双行版式
// 那样被行高裁掉半截。

NSString *const ERSliderCellClassName = @"ERSliderTrackCell";

// 版式常量（要微调只改这里）
//
// 1.0.3：行内多了一对「减 / 加」步进按钮，列宽随之重新分配 ——
//   图标 29 · 标题 88 · [−] 26 · 滑轨 · [+] 26 · 读数 52
// 标题列 108 → 88（6 个汉字靠 adjustsFontSizeToFitWidth 缩到 13.6pt 仍放得下），
// 读数列 56 → 52，列间距 12 → 8，腾出来的宽度正好给两个 26pt 的按钮。
static CGFloat const kERLeading       = 16.0;   // 内容区左内边距
static CGFloat const kERTrailing      = 16.0;   // 内容区右内边距
static CGFloat const kERTitleColumn   = 88.0;   // 标题列宽（6 个汉字缩排后刚好放下）
static CGFloat const kERTitleMinWidth = 52.0;   // 窄屏下的标题列下限
static CGFloat const kERValueColumn   = 52.0;   // 读数列宽
static CGFloat const kERColumnGap     = 8.0;    // 列间距
static CGFloat const kERMinTrackWidth = 70.0;   // 滑杆最短长度
static CGFloat const kERSliderHeight  = 40.0;   // UISlider 自身高度（轨道在其中居中）
static CGFloat const kERRowHeight     = 54.0;   // 与 plist 的 height 保持一致

// 1.0.3：滑轨两侧的步进按钮（左减右加）。
// 直径 26pt —— 与图标行里最小的一档控件同宽，点击热区用 44pt 的最小可点尺寸
// 由 UIControl 自身的 hitTest 之外的扩展不参与（这里只保证视觉直径一致）。
static CGFloat const kERStepButtonSide = 26.0;
static CGFloat const kERStepButtonGap  = 5.0;

// 1.0.3：读数「与上方开关居中对齐」。
// 开关行（PSSwitchCell）里 UISwitch 宽 51pt、贴内容区右侧 16pt：
//     switch = [W-16-51, W-16]，中心 = W-41.5
// 读数不再是「贴右边缘右对齐」，而是让 52pt 的读数列以这个中心为中心 ——
// 于是每一行滑杆的数字都端正地落在它上方那个开关的正下方。
static CGFloat const kERSwitchWidth = 51.0;

static CGFloat ERValueColumnCenter(CGFloat width) {
    return width - kERTrailing - kERSwitchWidth * 0.5;
}

// 1.0.2：图标与标题的对齐基准。
// 实测（增强设置页，597px 宽截图 / 1.375 px-per-pt）：开关行（PSSwitchCell）图标
// 左边缘 20.4pt、文字左边缘 65.5pt；而滑杆行此前图标在 16pt、文字在 53pt ——
// 两列都偏左，这正是用户箭头指出的「图标与文字要和下方图标的文字对齐」。
// 下面三个常量按开关行的实测值取：20 + 29 + 16 = 65，与开关行的文字左边缘对齐。
static CGFloat const kERIconLeading = 20.0;  // 图标左内边距（与 PSSwitchCell 一致）
static CGFloat const kERIconSide    = 29.0;  // 图标边长（ERMakeIcon 画的就是 29pt）
static CGFloat const kERIconTextGap = 16.0;  // 图标右边缘与标题之间的间距

// 1.0.2：滑块圆点缩小到原来的 2/3。
// 系统默认 UISlider 圆点的可视直径实测约 26pt，这里按 2/3 画一枚约 17pt 的白色圆点
// （带一层柔和投影，观感与系统圆点同款）。四个页面（增强设置 / 液态玻璃 /
// 锁屏控制项 / iOS27 Siri）共 12 个滑杆行现在全部走本类，圆点都取自同一张图，
// 所以四处大小完全一致 —— 不再需要 hook Preferences 自带的原生滑杆 cell
// （原因见 ERUIHelpers.m 文件尾的说明）。
static CGFloat const ERSystemSliderThumbDiameter = 26.0;
static CGFloat const ERSliderThumbScale = 2.0 / 3.0;

UIImage *ERSliderThumbImage(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGFloat visible = round(ERSystemSliderThumbDiameter * ERSliderThumbScale);
        CGFloat margin = 4.0;
        CGFloat side = visible + margin * 2.0;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0.0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (context) {
            CGContextSetShadowWithColor(context, CGSizeMake(0.0, 1.0), 3.0,
                                        [UIColor colorWithWhite:0.0 alpha:0.20].CGColor);
            [[UIColor whiteColor] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(margin, margin, visible, visible)] fill];
        }
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return image;
}

#pragma mark - 偏好读写（与 ERSegmentedCell 同一套：直接 CFPreferences）

static NSString *const kERFallbackDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERFallbackNotification = @"com.strive.echoreborn/ReloadPrefs";

static NSString *ERSpecString(PSSpecifier *specifier, NSString *key) {
    id value = [specifier propertyForKey:key];
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static NSString *ERSpecDomain(PSSpecifier *specifier) {
    NSString *domain = ERSpecString(specifier, @"defaults");
    return [domain length] ? domain : kERFallbackDomain;
}

static BOOL ERSpecBool(PSSpecifier *specifier, NSString *key, BOOL fallback) {
    id value = [specifier propertyForKey:key];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static double ERSpecDouble(PSSpecifier *specifier, NSString *key, double fallback) {
    id value = [specifier propertyForKey:key];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

// 读：先查偏好域，查不到（用户从未改过）才回落到 plist 的 default。
static double ERSpecReadValue(PSSpecifier *specifier) {
    double fallback = ERSpecDouble(specifier, @"default", 0.0);
    NSString *key = ERSpecString(specifier, @"key");
    if (![key length]) return fallback;

    double value = fallback;
    NSString *domain = ERSpecDomain(specifier);
    CFPropertyListRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                     (__bridge CFStringRef)domain);
    if (raw) {
        CFTypeID type = CFGetTypeID(raw);
        if (type == CFNumberGetTypeID()) {
            value = [(__bridge NSNumber *)raw doubleValue];
        } else if (type == CFStringGetTypeID()) {
            value = [(__bridge NSString *)raw doubleValue];
        }
        CFRelease(raw);
    }
    return value;
}

// 写：CFPreferences 落盘 + 补发 specifier 声明的 Darwin 通知。
// 域或 key 缺失时直接返回，不做半截写入。
static void ERSpecWriteValue(PSSpecifier *specifier, double value) {
    NSString *key = ERSpecString(specifier, @"key");
    if (![key length]) return;
    NSString *domain = ERSpecDomain(specifier);

    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)@(value),
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);

    NSString *notification = ERSpecString(specifier, @"PostNotification");
    if (![notification length]) notification = kERFallbackNotification;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)notification, NULL, NULL, true);
}

// 读数格式：范围是「整数且跨度 >= 10」的行用整数读数（位置偏移 -120~120 这类），
// 其余用一位小数（0.5~2.5、0~5 这类缩放 / 强度）。与 v7 设计稿的读数一致。
static NSString *ERSpecFormatValue(PSSpecifier *specifier, double value) {
    BOOL hasMin = [specifier propertyForKey:@"min"] != nil;
    BOOL hasMax = [specifier propertyForKey:@"max"] != nil;
    double minimum = ERSpecDouble(specifier, @"min", 0.0);
    double maximum = ERSpecDouble(specifier, @"max", 0.0);
    double fallback = ERSpecDouble(specifier, @"default", 0.0);

    BOOL integral = hasMin && hasMax &&
                    minimum == floor(minimum) && maximum == floor(maximum) &&
                    fallback == floor(fallback) && (maximum - minimum) >= 10.0;
    NSString *text = [NSString stringWithFormat:(integral ? @"%.0f" : @"%.1f"), value];

    NSString *suffix = ERSpecString(specifier, @"erValueSuffix");
    return [suffix length] ? [text stringByAppendingString:suffix] : text;
}

#pragma mark - cell

// 1.0.3：本类同时充当读数输入框的 delegate —— 双击读数即可原地键入精确数值，
// 不必再靠拖滑轨「拖到位」。
@interface ERSliderTrackCell : PSTableCell <UITextFieldDelegate>
@end

@implementation ERSliderTrackCell {
    UISlider *_erSlider;
    UILabel *_erTitleLabel;
    UILabel *_erValueLabel;
    // 1.0.3：双击读数后出现的原地输入框，以及滑轨左右两侧的减 / 加步进按钮。
    UITextField *_erValueField;
    UIButton *_erStepMinus;
    UIButton *_erStepPlus;
    PSSpecifier *_erSpecifier;
    BOOL _erShowValue;
    BOOL _erLiveUpdate;
}

#pragma mark 构造

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) [self erSetupSubviews];
    return self;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) [self erSetupSubviews];
    return self;
}

- (void)erSetupSubviews {
    if (_erSlider) return;

    // 框架自己的两个 label 一律隐藏：文字改由 _erTitleLabel 画，位置才完全可控。
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _erTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _erTitleLabel.font = [UIFont systemFontOfSize:17.0];
    _erTitleLabel.textColor = [UIColor labelColor];
    _erTitleLabel.adjustsFontSizeToFitWidth = YES;
    _erTitleLabel.minimumScaleFactor = 0.8;
    _erTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_erTitleLabel];

    _erSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _erSlider.continuous = NO;
    // 1.0.2：圆点缩小到原来的 2/3（原来用的是系统默认圆点）。
    UIImage *thumb = ERSliderThumbImage();
    if (thumb) {
        [_erSlider setThumbImage:thumb forState:UIControlStateNormal];
        [_erSlider setThumbImage:thumb forState:UIControlStateHighlighted];
    }
    [_erSlider addTarget:self
                  action:@selector(erSliderChanged:)
        forControlEvents:UIControlEventValueChanged];
    [_erSlider addTarget:self
                  action:@selector(erSliderCommitted:)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.contentView addSubview:_erSlider];

    _erValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _erValueLabel.font = [UIFont systemFontOfSize:15.0];
    _erValueLabel.textColor = [UIColor secondaryLabelColor];
    // 1.0.3：读数由「贴右边缘右对齐」改为「在读数格里居中」——读数格本身以
    // 上方开关的中心为中心，于是每行数字都端正地落在开关正下方。
    _erValueLabel.textAlignment = NSTextAlignmentCenter;
    _erValueLabel.adjustsFontSizeToFitWidth = YES;
    _erValueLabel.minimumScaleFactor = 0.75;
    // 1.0.3：双击读数 → 原地键入精确数值。需要 label 自己接收触摸。
    _erValueLabel.userInteractionEnabled = YES;
    _erValueLabel.accessibilityHint = @"双击可输入精确数值";
    UITapGestureRecognizer *doubleTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(erValueLabelDoubleTapped:)];
    doubleTap.numberOfTapsRequired = 2;
    [_erValueLabel addGestureRecognizer:doubleTap];
    [self.contentView addSubview:_erValueLabel];

    // 1.0.3：滑轨左右两侧的减 / 加按钮（左减右加，参考用户给的图片版式）。
    // 只加按钮，不动 UISlider 本体与它的轨道外观；点击按步长±1（小数读数的行
    // 按 0.1，见 -erStepSize）。
    _erStepMinus = [self erMakeStepButtonWithSymbol:@"minus" action:@selector(erStepDownTapped:)];
    _erStepMinus.accessibilityLabel = @"减小";
    [self.contentView addSubview:_erStepMinus];
    _erStepPlus = [self erMakeStepButtonWithSymbol:@"plus" action:@selector(erStepUpTapped:)];
    _erStepPlus.accessibilityLabel = @"增大";
    [self.contentView addSubview:_erStepPlus];

    // 构建标记：产物校验脚本用它确认本版确实编入了自绘滑杆的实现。
    self.accessibilityIdentifier = @"ER-slider-1000-selfdrawn";
    self.accessibilityValue = @"ER-slider-1003-stepbuttons";
}

#pragma mark 内容

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (specifier) _erSpecifier = specifier;
    PSSpecifier *current = specifier ?: _erSpecifier;
    if (!current || !_erSlider) return;

    // 框架在 refresh 里会把 textLabel 设回可见并写入文字，这里再压一次。
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    // 标题只从 specifier 的 properties 里取：PSSpecifier 在不同 SDK 下对标题属性
    // 的声明不一致（有的是 name、有的没有），直接 `current.name` 会在缺声明的
    // SDK 上报编译错误，所以这里统一走 propertyForKey（取不到就是 nil，安全）。
    NSString *title = ERSpecString(current, @"label");
    if (![title length]) title = ERSpecString(current, @"name");
    _erTitleLabel.text = title;
    _erSlider.accessibilityLabel = title;

    double minimum = ERSpecDouble(current, @"min", 0.0);
    double maximum = ERSpecDouble(current, @"max", 1.0);
    if (maximum <= minimum) maximum = minimum + 1.0;
    _erSlider.minimumValue = (float)minimum;
    _erSlider.maximumValue = (float)maximum;

    _erShowValue = ERSpecBool(current, @"showValue", NO);
    _erValueLabel.hidden = !_erShowValue;
    // 1.0.3：cell 复用/重新刷新时输入框必须收起，否则上一行正在编辑的值会被
    // 带到新的一行上。
    if (_erValueField && !_erValueField.hidden) {
        [_erValueField resignFirstResponder];
        _erValueField.hidden = YES;
    }

    // isContinuous = NO（本项目的默认）时只在松手时落盘；拖动过程中读数仍然实时更新。
    _erLiveUpdate = ERSpecBool(current, @"isContinuous", NO);
    _erSlider.continuous = _erLiveUpdate;
    _erSlider.value = (float)ERSpecReadValue(current);
    _erValueLabel.text = ERSpecFormatValue(current, _erSlider.value);

    [self setNeedsLayout];
}

- (void)erSliderChanged:(UISlider *)sender {
    if (!_erSpecifier) return;
    _erValueLabel.text = ERSpecFormatValue(_erSpecifier, sender.value);
    if (_erLiveUpdate) ERSpecWriteValue(_erSpecifier, sender.value);
}

- (void)erSliderCommitted:(UISlider *)sender {
    if (!_erSpecifier) return;
    _erValueLabel.text = ERSpecFormatValue(_erSpecifier, sender.value);
    ERSpecWriteValue(_erSpecifier, sender.value);
}

#pragma mark - 1.0.3 步进按钮（滑轨左减右加）

// 1.0.5：− / + 步进按钮的震动反馈。
//
// 之前这里用的是**局部** UIImpactFeedbackGenerator：
//     UIImpactFeedbackGenerator *feedback =
//         [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
//     [feedback impactOccurred];
// 生成器在方法返回时就被释放，而 impactOccurred 是**异步派发**给 Taptic Engine 的 ——
// 派发还没走到对象就没了，于是「点了没震动」，且不报任何错。Tweak.xm 里
// gTapHapticGenerator 那段的注释记录过同一个坑（「自检点击后不震动」）。
//
// 现在改为一个**全程强引用**的静态生成器：样式变了就换一个，否则复用；
// 每次点击前 prepare 一次，让 Taptic Engine 处于待发状态，手感更干脆。
static UIImpactFeedbackGenerator *gERStepHapticGenerator = nil;
static UIImpactFeedbackStyle gERStepHapticStyle = (UIImpactFeedbackStyle)-1;

static void ERStepHapticFire(void) {
    // 只服务 − / + 两个按钮，其它控件（滑块拖动、开关、双击输入）一律不触发。
    UIImpactFeedbackStyle style = UIImpactFeedbackStyleLight;
    if (gERStepHapticStyle != style || !gERStepHapticGenerator) {
        gERStepHapticGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
        gERStepHapticStyle = style;
    }
    [gERStepHapticGenerator prepare];
    [gERStepHapticGenerator impactOccurred];
}

// 26pt 圆形按钮：淡填充 + SF Symbol，用 UIButtonTypeSystem 直接拿系统高亮态。
- (UIButton *)erMakeStepButtonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = [UIColor secondaryLabelColor];
    button.backgroundColor = [UIColor tertiarySystemFillColor];
    button.layer.cornerRadius = kERStepButtonSide * 0.5;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.exclusiveTouch = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// 步长：整数读数的行按 1 递增/递减（−40~40、−120~120、0~64 这类），
// 小数读数的行（0.5~2.5 这类缩放 / 强度）按 0.1。
// 判据与 ERSpecFormatValue 的取整条件保持一致，保证「点一下」正好是读数上会
// 变化的那一位；否则 0.5~2.5 的滑轨一次点击就会被整条走完。
- (double)erStepSize {
    PSSpecifier *specifier = _erSpecifier;
    if (!specifier) return 1.0;
    BOOL hasMin = [specifier propertyForKey:@"min"] != nil;
    BOOL hasMax = [specifier propertyForKey:@"max"] != nil;
    double minimum = ERSpecDouble(specifier, @"min", 0.0);
    double maximum = ERSpecDouble(specifier, @"max", 0.0);
    double fallback = ERSpecDouble(specifier, @"default", 0.0);
    BOOL integral = hasMin && hasMax &&
                    minimum == floor(minimum) && maximum == floor(maximum) &&
                    fallback == floor(fallback) && (maximum - minimum) >= 10.0;
    return integral ? 1.0 : 0.1;
}

- (double)erClampedValue:(double)value {
    double minimum = _erSlider.minimumValue;
    double maximum = _erSlider.maximumValue;
    if (maximum <= minimum) return value;
    return MIN(MAX(value, minimum), maximum);
}

- (void)erStepDownTapped:(__unused UIButton *)sender { [self erStepBy:-1.0]; }
- (void)erStepUpTapped:(__unused UIButton *)sender { [self erStepBy:1.0]; }

- (void)erStepBy:(double)direction {
    if (!_erSpecifier || !_erSlider) return;
    double step = [self erStepSize];
    // 先把当前值吸附到步长网格再走一步：拖滑轨得到的值常带 0.0001 级漂移，
    // 不吸附的话点十下也回不到整数。
    double snapped = round(_erSlider.value / step) * step;
    double value = [self erClampedValue:snapped + direction * step];
    value = round(value * 1000.0) / 1000.0;
    _erSlider.value = (float)value;
    _erValueLabel.text = ERSpecFormatValue(_erSpecifier, value);
    // 点一下即一次提交，与 isContinuous = NO 的语义一致。
    ERSpecWriteValue(_erSpecifier, value);
    // 1.0.5：震动由 ERStepHapticFire() 负责（静态强引用，见上面的说明）。
    // 只有走到这里才算「真的点到了 − / +」，滑块拖到边界、双击输入都不会经过本函数。
    ERStepHapticFire();
}

#pragma mark - 1.0.3 双击读数 → 原地输入精确数值

- (void)erValueLabelDoubleTapped:(__unused UITapGestureRecognizer *)sender {
    if (!_erSpecifier || !_erShowValue || !_erSlider) return;
    [self erBeginValueEditing];
}

- (void)erBeginValueEditing {
    if (!_erValueField) {
        UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
        field.textAlignment = NSTextAlignmentCenter;
        field.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        field.textColor = [UIColor labelColor];
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.returnKeyType = UIReturnKeyDone;
        field.delegate = self;
        field.backgroundColor = [UIColor tertiarySystemFillColor];
        field.layer.cornerRadius = 8.0;
        field.layer.cornerCurve = kCACornerCurveContinuous;
        field.hidden = YES;
        [self.contentView addSubview:field];
        _erValueField = field;
    }
    _erValueField.frame = _erValueLabel.frame;
    _erValueField.text = ERSpecFormatValue(_erSpecifier, _erSlider.value);
    _erValueField.hidden = NO;
    _erValueLabel.hidden = YES;
    [_erValueField becomeFirstResponder];
    [_erValueField selectAll:nil];
}

- (void)erCommitValueEditing {
    UITextField *field = _erValueField;
    if (!field || field.hidden) return;
    NSString *text = [field.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 空串 / 非数字一律当作取消，恢复原读数 —— 绝不把 NaN 写进偏好域。
    if ([text length] && _erSpecifier) {
        NSScanner *scanner = [NSScanner scannerWithString:text];
        double entered = 0.0;
        if ([scanner scanDouble:&entered] && scanner.isAtEnd) {
            double step = [self erStepSize];
            double value = [self erClampedValue:round(entered / step) * step];
            value = round(value * 1000.0) / 1000.0;
            _erSlider.value = (float)value;
            ERSpecWriteValue(_erSpecifier, value);
        }
    }
    if (_erSpecifier) _erValueLabel.text = ERSpecFormatValue(_erSpecifier, _erSlider.value);
    field.hidden = YES;
    _erValueLabel.hidden = !_erShowValue;
}

- (void)textFieldDidEndEditing:(__unused UITextField *)textField {
    [self erCommitValueEditing];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark 布局（只用 contentView 一个坐标系，不做任何坐标换算）

// specifier 上挂了 iconImage 时，框架会在 contentView 里放一个 UIImageView。
// 这里把它找出来：横向位置**沿用框架的**（PSSwitchCell 用的是同一套布局，沿用它
// 就等于和开关行的图标对齐），只把纵向居中；标题列摆在图标右边缘之后。
// 找不到就当作无图标 —— 其余滑杆行都走这条路径。
- (UIView *)erIconView {
    for (UIView *sub in self.contentView.subviews) {
        if (sub == _erTitleLabel || sub == _erSlider || sub == _erValueLabel) continue;
        // 1.0.3：读数输入框与两个步进按钮也是本类自己加的，别把它们当图标。
        if (sub == _erValueField || sub == _erStepMinus || sub == _erStepPlus) continue;
        if (![sub isKindOfClass:[UIImageView class]]) continue;
        if ([(UIImageView *)sub image]) return sub;
    }
    return nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect content = self.contentView.bounds;
    CGFloat width = CGRectGetWidth(content);
    CGFloat height = CGRectGetHeight(content);
    if (width < 1.0 || !_erSlider) return;

    // 1.0.2：图标不再由我们自己摆到 kERLeading，而是**沿用框架算好的位置** ——
    // PSSwitchCell / PSTitleValueCell 用的是同一套图标布局，沿用它就等于和开关行的
    // 图标逐像素对齐。只有框架没摆（frame 不合理）时才退回固定几何。
    CGFloat titleX = kERLeading;
    UIView *icon = [self erIconView];
    if (icon) {
        CGRect frame = icon.frame;
        BOOL usable = CGRectGetWidth(frame) >= 20.0 && CGRectGetWidth(frame) <= 40.0 &&
                      CGRectGetHeight(frame) >= 20.0 && CGRectGetHeight(frame) <= 40.0 &&
                      CGRectGetMaxX(frame) > 0.0 && CGRectGetMaxX(frame) < width * 0.5;
        if (!usable) frame = CGRectMake(kERIconLeading, 0.0, kERIconSide, kERIconSide);
        frame.origin.y = round((height - CGRectGetHeight(frame)) * 0.5);
        icon.frame = frame;
        titleX = CGRectGetMaxX(frame) + kERIconTextGap;
    }

    // 1.0.3：列宽重新分配 —— 标题列之后是 [减] [滑轨] [加]，最后是读数格。
    // 读数格以「上方开关的中心」为中心（ERValueColumnCenter），不再贴右边缘。
    CGFloat valueCenter = ERValueColumnCenter(width);
    CGFloat valueX = round(valueCenter - kERValueColumn * 0.5);
    CGFloat trackAreaRight = _erShowValue ? (valueX - kERColumnGap) : (width - kERTrailing);
    CGFloat buttonReserve = 2.0 * kERStepButtonSide + 2.0 * kERStepButtonGap;
    // 先按「最少给滑轨 kERMinTrackWidth」反推标题列能占多少，再夹到 [下限, 上限]。
    CGFloat availableForTitle = trackAreaRight - titleX - kERColumnGap - buttonReserve - kERMinTrackWidth;
    CGFloat titleWidth = MIN(kERTitleColumn, MAX(kERTitleMinWidth, availableForTitle));
    if (titleWidth < kERTitleMinWidth) titleWidth = kERTitleMinWidth;

    CGFloat minusX = titleX + titleWidth + kERColumnGap;
    CGFloat sliderX = minusX + kERStepButtonSide + kERStepButtonGap;
    CGFloat sliderWidth = trackAreaRight - sliderX - kERStepButtonSide - kERStepButtonGap;
    if (sliderWidth < kERMinTrackWidth) sliderWidth = kERMinTrackWidth;
    CGFloat plusX = sliderX + sliderWidth + kERStepButtonGap;

    CGFloat buttonY = round((height - kERStepButtonSide) * 0.5);
    _erTitleLabel.frame = CGRectMake(titleX, 0.0, titleWidth, height);
    _erValueLabel.frame = CGRectMake(valueX, 0.0, kERValueColumn, height);
    _erStepMinus.frame = CGRectMake(round(minusX), buttonY, kERStepButtonSide, kERStepButtonSide);
    _erStepPlus.frame = CGRectMake(round(plusX), buttonY, kERStepButtonSide, kERStepButtonSide);
    _erSlider.frame = CGRectMake(sliderX,
                                 (height - kERSliderHeight) / 2.0,
                                 sliderWidth,
                                 kERSliderHeight);
    if (_erValueField) _erValueField.frame = _erValueLabel.frame;
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(size.width, kERRowHeight);
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    return kERRowHeight;
}

@end
