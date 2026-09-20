#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <math.h>

// 三段式（轻 / 中 / 重）控件，绑定到 TapHapticStrength（0/1/2）。
//
// 0.5.20 的闪退根因：本文件原先用 `self.controller` 取所属列表控制器。
// PSTableCell 在 iOS 16/17 上**没有**这个访问器（某些头文件里那条声明与运行时不符），
// 于是
//     -[ERSegmentedCell controller]: unrecognized selector sent to instance
// 在 PSListController -tableView:cellForRowAtIndexPath: 调回
// -refreshCellContentsWithSpecifier: 的过程中抛出，一点「增强设置」即 SIGABRT。
//
// 0.5.21 先用 specifier 的 target 取控制器绕开它；**0.5.22 彻底去掉对 Preferences
// 私有结构的全部依赖**：读、写都走 CFPreferences + specifier 自己声明的
// defaults / key / PostNotification。这条路径与 Tweak.xm 的
//     CFPreferencesCopyAppValue(CFSTR("TapHapticStrength"),
//                               CFSTR("com.strive.echoreborn.preferences"))
// 是**同一个存储**，所以显示值与实际生效值必然一致；0.5.21 遗留的降级分支
// （「PSSpecifier 既没有 -target 也没有 _target ivar → 退回 plist default →
// 显示值不准且不报错」）也随之消失。本文件现在不触碰任何私有 API。

// 兜底值：specifier 缺 defaults / PostNotification 时用，与 Tweak.xm 的常量一致。
static NSString *const kERSegmentFallbackDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERSegmentFallbackNotification = @"com.strive.echoreborn/ReloadPrefs";

static NSString *ERSpecifierString(PSSpecifier *specifier, NSString *key) {
    id value = [specifier propertyForKey:key];
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static NSString *ERSegmentDomain(PSSpecifier *specifier) {
    NSString *domain = ERSpecifierString(specifier, @"defaults");
    return [domain length] ? domain : kERSegmentFallbackDomain;
}

// 1.0.7-20：段数不再写死 3。相机双摄的「小窗位置」是四段（左上/右上/左下/右下），
// 老实现把读到的值一律钳在 0..2 —— 选「右下」（3）会显示成「左下」（2），
// 而写进去的却是 3，设置页与实际行为对不上。现在按 erSegmentTitles 的实际段数钳。
static NSInteger ERSegmentMaxIndex(PSSpecifier *specifier) {
    NSArray *titles = [specifier propertyForKey:@"erSegmentTitles"];
    if ([titles isKindOfClass:[NSArray class]] && titles.count >= 2) {
        return (NSInteger)titles.count - 1;
    }
    return 2;   // 没有声明段名时的历史默认（轻 / 中 / 重）
}

// 读：先查偏好域，查不到（用户从未改过）才回落到 plist 的 default。
// 绝不经过控制器 —— 这正是 0.5.20 崩溃与 0.5.21 显示值不确定的共同源头。
static NSInteger ERSegmentReadValue(PSSpecifier *specifier) {
    NSString *key = ERSpecifierString(specifier, @"key");
    NSString *domain = ERSegmentDomain(specifier);
    NSInteger value = 0;
    BOOL stored = NO;

    if ([key length]) {
        CFPropertyListRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                          (__bridge CFStringRef)domain);
        if (raw) {
            CFTypeID type = CFGetTypeID(raw);
            if (type == CFNumberGetTypeID()) {
                value = [(__bridge NSNumber *)raw integerValue];
                stored = YES;
            } else if (type == CFStringGetTypeID()) {
                value = [(__bridge NSString *)raw integerValue];
                stored = YES;
            }
            CFRelease(raw);
        }
    }

    if (!stored) {
        id fallback = [specifier propertyForKey:@"default"];
        if ([fallback isKindOfClass:[NSNumber class]]) {
            value = [(NSNumber *)fallback integerValue];
        }
    }

    NSInteger maxIndex = ERSegmentMaxIndex(specifier);
    if (value < 0) value = 0;
    if (value > maxIndex) value = maxIndex;
    return value;
}

// 写：CFPreferences 落盘 + 补发 specifier 声明的 Darwin 通知，与
// PSListController -setPreferenceValue:specifier: 落到的域和通知完全一致。
// 不做静默失败：域或 key 缺失时不会发生半截写入。
static void ERSegmentWriteValue(PSSpecifier *specifier, NSInteger value) {
    NSString *key = ERSpecifierString(specifier, @"key");
    if (![key length]) return;
    NSString *domain = ERSegmentDomain(specifier);

    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)@(value),
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);

    NSString *notification = ERSpecifierString(specifier, @"PostNotification");
    if (![notification length]) notification = kERSegmentFallbackNotification;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)notification, NULL, NULL, true);
}

@interface ERSegmentedCell : PSTableCell
@end

// ---------------------------------------------------------------------------
// 1.0.8-29 · 自定义背景色小窗
//
// 需求：「背景色」那一行的第 8 段「自定义」点开后，用一个小窗调 R/G/B；
//       透明度不在小窗里，统一由上方「背景色值」滑块控制。
// 样式照 Tweak 侧的改名对话框：圆角 24 · 描边白 0.22 · 阴影黑 0.30/28 · 深色玻璃底。
//
// 用 presentViewController 而不是自建 UIWindow —— Preferences 进程里自己造窗口
// 还要处理 windowScene，容易和这个项目以前踩过的"窗口不显示"坑同源。
// 通过响应链拿到宿主控制器（就是那个 PSListController）present，最稳。
// ---------------------------------------------------------------------------

static UIViewController *ERHostViewController(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = [responder nextResponder];
    }
    return nil;
}

// 把 "38,45,58" 解析成三个 0–255 的整数；解析不出就用兜底值。
static void ERParseRGBString(NSString *text, CGFloat out[3]) {
    out[0] = 38.0; out[1] = 45.0; out[2] = 58.0;
    if (![text isKindOfClass:[NSString class]]) return;
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@","];
    if (parts.count < 3) return;
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat v = [parts[i] doubleValue];
        out[i] = MIN(MAX(v, 0.0), 255.0);
    }
}

static NSString *ERRGBString(CGFloat rgb[3]) {
    return [NSString stringWithFormat:@"%d,%d,%d",
            (int)lround(rgb[0]), (int)lround(rgb[1]), (int)lround(rgb[2])];
}

@interface ERColorPickerController : UIViewController
@property (nonatomic, copy) NSString *rgb;
@property (nonatomic, copy) NSString *alphaText;   // 只用于预览说明，例如 "88"
@property (nonatomic, copy) void (^onCommit)(NSString *rgb);
@end

@implementation ERColorPickerController {
    CGFloat _rgbValue[3];   // 命名避开 property `rgb` 自动合成的 _rgb
    UIView *_preview;
    UISlider *_sliders[3];
    UILabel *_values[3];
    UIView *_card;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    ERParseRGBString(self.rgb, _rgbValue);

    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                           action:@selector(_erBackdropTapped:)]];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = [UIColor colorWithRed:38.0 / 255.0 green:41.0 / 255.0
                                             blue:50.0 / 255.0 alpha:0.97];
    _card.layer.cornerRadius = 24.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.borderWidth = 0.6;
    _card.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.22].CGColor;
    _card.layer.shadowColor = UIColor.blackColor.CGColor;
    _card.layer.shadowOpacity = 0.30;
    _card.layer.shadowRadius = 28.0;
    _card.layer.shadowOffset = CGSizeMake(0.0, 10.0);
    [self.view addSubview:_card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"自定义背景色";
    title.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.tag = 100;
    [_card addSubview:title];

    // 预览：把当前色按「背景色值」的透明度糊在一块深灰上，近似卡内玻璃底的样子
    _preview = [[UIView alloc] initWithFrame:CGRectZero];
    _preview.layer.cornerRadius = 12.0;
    _preview.layer.cornerCurve = kCACornerCurveContinuous;
    _preview.layer.borderWidth = 0.6;
    _preview.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.16].CGColor;
    _preview.tag = 101;
    [_card addSubview:_preview];

    NSArray<NSString *> *names = @[@"R", @"G", @"B"];
    for (NSInteger i = 0; i < 3; i++) {
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
        name.text = names[i];
        name.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        name.textColor = UIColor.whiteColor;
        name.textAlignment = NSTextAlignmentCenter;
        name.tag = 200 + i;
        [_card addSubview:name];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
        slider.minimumValue = 0.0;
        slider.maximumValue = 255.0;
        slider.value = _rgbValue[i];
        slider.continuous = YES;
        slider.tag = 300 + i;
        [slider addTarget:self action:@selector(_erSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [_card addSubview:slider];
        _sliders[i] = slider;

        UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];
        value.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightRegular];
        value.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];
        value.textAlignment = NSTextAlignmentRight;
        value.tag = 400 + i;
        [_card addSubview:value];
        _values[i] = value;
    }

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.text = [NSString stringWithFormat:@"透明度不在这里调 —— 由上方「背景色值」统一控制（当前 %@）",
                 self.alphaText.length ? self.alphaText : @"88"];
    hint.font = [UIFont systemFontOfSize:10.5];
    hint.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.62];
    hint.numberOfLines = 2;
    hint.tag = 500;
    [_card addSubview:hint];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:16.0];
    [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancel.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.14];
    cancel.layer.cornerRadius = 22.0;
    cancel.layer.cornerCurve = kCACornerCurveContinuous;
    cancel.tag = 600;
    [cancel addTarget:self action:@selector(_erCancel) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:cancel];

    UIButton *confirm = [UIButton buttonWithType:UIButtonTypeCustom];
    [confirm setTitle:@"确定" forState:UIControlStateNormal];
    confirm.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
    [confirm setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    confirm.backgroundColor = [UIColor colorWithRed:46.0 / 255.0 green:107.0 / 255.0 blue:1.0 alpha:1.0];
    confirm.layer.cornerRadius = 22.0;
    confirm.layer.cornerCurve = kCACornerCurveContinuous;
    confirm.tag = 601;
    [confirm addTarget:self action:@selector(_erConfirm) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:confirm];

    [self _erRefreshPreview];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize screen = self.view.bounds.size;
    CGFloat w = MIN(300.0, screen.width - 48.0);
    CGFloat h = 360.0;   // 18 + 标题 22 + 14 + 预览 78 + 16 + 3×40 + 提示 30 + 按钮 44 + 下留白 18
    _card.frame = CGRectMake(round((screen.width - w) * 0.5), round((screen.height - h) * 0.5), w, h);

    CGFloat pad = 16.0;
    CGFloat inner = w - pad * 2.0;
    CGFloat y = 18.0;
    [(UILabel *)[_card viewWithTag:100] setFrame:CGRectMake(pad, y, inner, 22.0)];
    y += 22.0 + 14.0;
    _preview.frame = CGRectMake(round((w - 120.0) * 0.5), y, 120.0, 78.0);
    y += 78.0 + 16.0;

    for (NSInteger i = 0; i < 3; i++) {
        [(UILabel *)[_card viewWithTag:200 + i] setFrame:CGRectMake(pad, y, 16.0, 40.0)];
        _sliders[i].frame = CGRectMake(pad + 24.0, y, inner - 24.0 - 44.0, 40.0);
        _values[i].frame = CGRectMake(CGRectGetMaxX(_sliders[i].frame) + 4.0, y, 40.0, 40.0);
        y += 40.0;
    }
    [(UILabel *)[_card viewWithTag:500] setFrame:CGRectMake(pad, y, inner, 30.0)];
    y += 30.0;

    CGFloat bw = (inner - 10.0) * 0.5;
    [(UIButton *)[_card viewWithTag:600] setFrame:CGRectMake(pad, y, bw, 44.0)];
    [(UIButton *)[_card viewWithTag:601] setFrame:CGRectMake(pad + bw + 10.0, y, bw, 44.0)];
}

- (void)_erRefreshPreview {
    CGFloat alpha = 0.88;
    if (self.alphaText.length) alpha = MIN(MAX([self.alphaText doubleValue] / 100.0, 0.0), 1.0);
    UIColor *color = [UIColor colorWithRed:_rgbValue[0] / 255.0 green:_rgbValue[1] / 255.0
                                     blue:_rgbValue[2] / 255.0 alpha:1.0];
    _preview.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    // 把 color@alpha 叠在深灰上 —— 就是卡内玻璃底的近似值
    UIView *film = [_preview viewWithTag:900];
    if (!film) {
        film = [[UIView alloc] initWithFrame:_preview.bounds];
        film.tag = 900;
        film.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_preview addSubview:film];
    }
    film.backgroundColor = [color colorWithAlphaComponent:alpha];

    for (NSInteger i = 0; i < 3; i++) {
        _values[i].text = [NSString stringWithFormat:@"%d", (int)lround(_rgbValue[i])];
    }
}

- (void)_erSliderChanged:(UISlider *)sender {
    NSInteger i = sender.tag - 300;
    if (i < 0 || i > 2) return;
    _rgbValue[i] = sender.value;
    [self _erRefreshPreview];
}

- (void)_erBackdropTapped:(UITapGestureRecognizer *)gesture {
    // 只有点在卡片**外面**才算"点背景取消" —— 否则这个手势会把卡片上的
    // 按钮/滑块的点击一并吃掉（父视图的手势优先于子视图的 UIControl）。
    CGPoint point = [gesture locationInView:self.view];
    if (_card && CGRectContainsPoint(_card.frame, point)) return;
    [self _erCancel];
}

- (void)_erCancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)_erConfirm {
    if (self.onCommit) self.onCommit(ERRGBString(_rgbValue));
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

@implementation ERSegmentedCell {
    UISegmentedControl *_segment;
    __weak PSSpecifier *_erSpecifier;
    BOOL _erValueMode;      // 1.0.8-29：声明了 erSegmentValues → 段值是字符串（色值），不是下标
    NSInteger _erLastIndex; // 上一次确认过的段（点「自定义」取消时要回滚到这里）
}

// 1.0.8-29：色值模式的两个可选声明。没声明 → 完全走原路（小窗位置 / 轻中重）。
static NSArray<NSString *> *ERPresetRGBList(PSSpecifier *specifier) {
    id value = [specifier propertyForKey:@"erPresetRGB"];
    if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count]) {
        return (NSArray<NSString *> *)value;
    }
    return nil;
}

static NSInteger ERPresetCustomIndex(PSSpecifier *specifier) {
    id value = [specifier propertyForKey:@"erPresetCustomIndex"];
    return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : NSNotFound;
}

static BOOL ERSegmentCompact(PSSpecifier *specifier) {
    id value = [specifier propertyForKey:@"erPresetCompact"];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

// 读：色值模式下直接把存着的那串 RGB 取出来（查表反推下标是调用方的事）。
static NSString *ERSegmentReadString(PSSpecifier *specifier) {
    NSString *key = ERSpecifierString(specifier, @"key");
    NSString *domain = ERSegmentDomain(specifier);
    NSString *value = nil;
    if ([key length]) {
        CFPropertyListRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                         (__bridge CFStringRef)domain);
        if (raw) {
            if (CFGetTypeID(raw) == CFStringGetTypeID()) {
                value = [(__bridge NSString *)raw copy];
            }
            CFRelease(raw);
        }
    }
    if (![value length]) {
        id fallback = [specifier propertyForKey:@"default"];
        if ([fallback isKindOfClass:[NSString class]]) value = fallback;
    }
    return value;
}

// 写：仍是同一个 key、同一串格式 —— Tweak 侧读法完全不变。
static void ERSegmentWriteString(PSSpecifier *specifier, NSString *value) {
    NSString *key = ERSpecifierString(specifier, @"key");
    if (![key length] || ![value isKindOfClass:[NSString class]]) return;
    NSString *domain = ERSegmentDomain(specifier);

    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);

    NSString *notification = ERSpecifierString(specifier, @"PostNotification");
    if (![notification length]) notification = kERSegmentFallbackNotification;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)notification, NULL, NULL, true);
}

// 预览要用的「背景色值」，和 Tweak 侧同一个域同一个默认值。
static CGFloat ERBackgroundAlphaValue(void) {
    CGFloat value = 88.0;
    CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("QuickAdd.BackgroundAlpha"),
                                                     (__bridge CFStringRef)kERSegmentFallbackDomain);
    if (raw) {
        if (CFGetTypeID(raw) == CFNumberGetTypeID()) value = [(__bridge NSNumber *)raw doubleValue];
        CFRelease(raw);
    }
    return MIN(MAX(value, 0.0), 100.0);
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        _erSpecifier = specifier;
        NSArray *titles = [specifier propertyForKey:@"erSegmentTitles"];
        if (![titles isKindOfClass:[NSArray class]] || titles.count == 0) {
            titles = @[@"轻", @"中", @"重"];
        }
        _segment = [[UISegmentedControl alloc] initWithItems:titles];
        [_segment addTarget:self
                     action:@selector(_erSegmentChanged:)
           forControlEvents:UIControlEventValueChanged];
        [_segment sizeToFit];
        CGRect frame = _segment.frame;
        // 1.0.7-20：四段（左上/右上/左下/右下）需要更宽；三段（轻/中/重）保持原值。
        CGFloat minWidth = titles.count >= 4 ? 188.0 : 156.0;
        frame.size.width = MAX(frame.size.width, minWidth);
        frame.size.height = 28.0;
        // 1.0.8-29：色板那行是 8 段、且要铺满整行 —— 段名都是 2~3 个汉字，
        // 13pt 会把「自定义」挤出格子，所以这一档改用 12pt，高度也放宽到 32。
        if (ERSegmentCompact(specifier)) {
            [_segment setTitleTextAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:12.0] }
                                    forState:UIControlStateNormal];
            frame.size.height = 32.0;
            // 1.0.8-30：**按内容分配段宽**。8 段等宽时每段只有 41pt，而「自定义」是
            // 三个汉字（12pt 约 36pt）加系统内边距 ≈ 46pt → 会被截成"自定…"。
            // 打开这个开关后各段按标题 intrinsic 宽度等比分配，三字段的到约 53pt，不再截断。
            _segment.apportionsSegmentWidthsByContent = YES;
        }
        _segment.frame = frame;
        // 构建标记：既是无障碍标识，也是产物校验脚本用来确认「这一版确实带
        // 直读偏好域实现」的存活字符串（0.5.22）。语义上无副作用。
        _segment.accessibilityIdentifier = @"ER-seg-0522-directprefs";
        if (ERSegmentCompact(specifier)) {
            // 铺满整行：不进 accessoryView（那会把控件按自身宽度靠右摆），
            // 直接挂到 contentView 上、由 layoutSubviews 定位。
            self.accessoryView = nil;
            [self.contentView addSubview:_segment];
        } else {
            self.accessoryView = _segment;
        }
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 1.0.8-60 · 分段模式（震动强度/小窗位置等）**显示左侧标签**，分段控件靠右；
    // 数值模式（RGB 颜色行）维持原样：隐藏标签、分段占满整行。
    if (!_segment || _segment.superview != self.contentView) return;
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    if (_erValueMode) {
        if (!self.textLabel.isHidden) { self.textLabel.hidden = YES; self.textLabel.text = @""; }
        if (!self.detailTextLabel.isHidden) { self.detailTextLabel.hidden = YES; self.detailTextLabel.text = @""; }
        CGRect frame = _segment.frame;
        frame.origin.x = 16.0;
        frame.size.width = MAX(width - 32.0, 120.0);
        frame.origin.y = round((CGRectGetHeight(self.contentView.bounds) - CGRectGetHeight(frame)) * 0.5);
        _segment.frame = frame;
    } else {
        NSString *title = [_erSpecifier propertyForKey:@"label"];
        self.textLabel.hidden = NO;
        self.textLabel.text = title.length ? title : @"";
        self.textLabel.font = [UIFont systemFontOfSize:16.0];
        self.detailTextLabel.hidden = YES;
        CGRect frame = _segment.frame;
        frame.origin.x = round(width * 0.46);
        frame.size.width = MAX(width - frame.origin.x - 12.0, 100.0);
        frame.origin.y = round((CGRectGetHeight(self.contentView.bounds) - CGRectGetHeight(frame)) * 0.5);
        _segment.frame = frame;
    }
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    // 1.0.8-30：POSTMORTEM —— 1.0.8-29 上 PSTableCell 的 refresh 抛了 NSException
    // （setTitle: 收到非字符串 → Preferences SIGABRT → 点「系统增强」直接闪退）。
    // 本 cell 的内容全部自己画，不依赖基类做了什么，所以这里兜住异常、只记一行日志，
    // 保证设置页无论如何都能打开。真要复现，设备日志里会有 [EchoReborn] ERSEG refresh。
    @try {
        [super refreshCellContentsWithSpecifier:specifier];
    } @catch (NSException *exception) {
        NSLog(@"[EchoReborn] ERSEG refresh threw: %@ -- %@", exception.name, exception.reason);
    }
    if (specifier) _erSpecifier = specifier;

    // 1.0.8-32：这一行**只有分段控件**一个内容。
    // 1.0.8-31 把 cell 换成 PSTableCell 后，灰红/灰橙上的数字从左边挪到了右边 ——
    // 因为 PSTableCell 的 refresh 一样会把 specifier 的当前值（那串 RGB）画进
    // detailTextLabel（右侧读数位），压住最后一段「自定义」。
    // 这里把两个系统标签都清空并隐藏，layoutSubviews 里再兜一次。
    PSSpecifier *current = specifier ?: _erSpecifier;
    if (!current) return;

    NSArray<NSString *> *valuesEarly = ERPresetRGBList(current);
    BOOL valueModeEarly = (valuesEarly != nil);
    if (valueModeEarly) {
        self.textLabel.text = @"";
        self.detailTextLabel.text = @"";
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;
    }

    NSArray<NSString *> *values = ERPresetRGBList(current);
    _erValueMode = (values != nil);

    NSInteger index = 0;
    if (_erValueMode) {
        // 色值模式：拿存着的那串 RGB 在表里反查下标；查不到（用户选过自定义）→ 落到「自定义」段。
        NSString *stored = ERSegmentReadString(current);
        NSInteger found = [values indexOfObject:stored ?: @""];
        if (found == NSNotFound) {
            NSInteger custom = ERPresetCustomIndex(current);
            found = (custom != NSNotFound) ? custom : 0;
        }
        index = found;
    } else {
        index = ERSegmentReadValue(current);
    }

    NSInteger segments = (NSInteger)_segment.numberOfSegments;
    if (segments > 0) {
        if (index < 0) index = 0;
        if (index > segments - 1) index = segments - 1;
    }
    _segment.selectedSegmentIndex = index;
    _erLastIndex = index;
}

- (void)_erSegmentChanged:(UISegmentedControl *)sender {
    PSSpecifier *specifier = _erSpecifier;
    if (!specifier) return;

    if (!_erValueMode) {
        ERSegmentWriteValue(specifier, sender.selectedSegmentIndex);
        _erLastIndex = sender.selectedSegmentIndex;
        return;
    }

    NSArray<NSString *> *values = ERPresetRGBList(specifier);
    NSInteger index = sender.selectedSegmentIndex;
    NSInteger custom = ERPresetCustomIndex(specifier);

    if (custom != NSNotFound && index == custom) {
        // 1.0.8-29：第 8 段「自定义」不写值 —— 先把选中态滚回上一段，
        // 再弹 RGB 小窗；用户确定后才把新色写进同一个 key（于是下次进来会停在第 8 段）。
        sender.selectedSegmentIndex = _erLastIndex;
        [self _erPresentColorPicker];
        return;
    }

    if (index >= 0 && index < (NSInteger)values.count) {
        ERSegmentWriteString(specifier, values[index]);
        _erLastIndex = index;
        // 让设置页里其它依赖同一 key 的地方（如上面的「背景色值」行）也能立刻刷新
        [self setNeedsLayout];
    }
}

- (void)_erPresentColorPicker {
    PSSpecifier *specifier = _erSpecifier;
    if (!specifier) return;

    UIViewController *host = ERHostViewController(self);
    // 兜底不用 [UIApplication sharedApplication].windows —— 它自 iOS 15 起是 deprecated，
    // 本工程开了 -Werror，会直接编译失败。改从 cell 自己的 window 上去拿根控制器。
    if (!host) host = self.window.rootViewController;
    if (!host || host.presentedViewController) return;

    ERColorPickerController *picker = [[ERColorPickerController alloc] init];
    picker.rgb = ERSegmentReadString(specifier) ?: @"38,45,58";
    picker.alphaText = [NSString stringWithFormat:@"%d", (int)lround(ERBackgroundAlphaValue())];
    __weak typeof(self) weakSelf = self;
    __weak PSSpecifier *weakSpecifier = specifier;
    picker.onCommit = ^(NSString *rgb) {
        PSSpecifier *strongSpecifier = weakSpecifier;
        if (!strongSpecifier) return;
        ERSegmentWriteString(strongSpecifier, rgb);
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf refreshCellContentsWithSpecifier:strongSpecifier];
    };
    picker.modalPresentationStyle = UIModalPresentationOverFullScreen;
    picker.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [host presentViewController:picker animated:YES completion:nil];
}

@end
