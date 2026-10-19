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

    // 1.2.0-10 · 浅色模式：SystemMaterial 随系统深浅色自适应（原 Dark 写死）。
    UIVisualEffectView *panel = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.frame = CGRectMake(x, y, width, tableH);
    panel.layer.cornerRadius = 12.0;
    panel.layer.masksToBounds = YES;
    [container addSubview:panel];

    UITableView *menu = [[UITableView alloc] initWithFrame:panel.contentView.bounds
                                                     style:UITableViewStylePlain];
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
    _valueButton.contentEdgeInsets = UIEdgeInsetsMake(5, 10, 5, 10);
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
    _chevron.tintColor = [UIColor colorWithRed:0.30 green:0.80 blue:1.00 alpha:1.0];
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
    _icon.frame = CGRectMake(left, (h - 27) / 2.0, 27, 27);

    CGFloat chevW = 14.0;
    CGSize ts = [_title.text sizeWithAttributes:@{NSFontAttributeName: _title.font}];
    CGFloat pad = 10.0;
    // 1.2.0-10 · 用户反馈仍差半个字：容差 14→24、上限 190→200。
    CGFloat btnW = MIN(MAX(ts.width + pad * 2 + chevW + 24.0, 76.0), 200.0);
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
    // 1.2.0-7 · 箭头不再拼进标题字符串（字符 ⌄ 小且随基线偏移），独立 _chevron 渲染。
    [_valueButton setTitle:text forState:UIControlStateNormal];
    [_valueButton setTitleColor:[UIColor colorWithRed:0.30 green:0.80 blue:1.00 alpha:1.0]
                       forState:UIControlStateNormal];
    [self setNeedsLayout];
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
        ERGEnsureSwitchCellClass();
        NSMutableArray *specs = [NSMutableArray array];

        // ---- 卡片1 · 搜索胶囊（1.2.0-7：与手势设置合并为一张卡片） ----
        PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:@"搜索胶囊"];
        [g1 setProperty:@"开启后，桌面搜索胶囊支持四向滑动快速跳页，单击搜索不受影响；「无动作」保持系统默认行为，选择某页后，触发对应滑动的瞬间直接跳到该页。"
                 forKey:@"footerText"];
        [specs addObject:g1];
        [specs addObject:[self erSwitchNamed:@"搜索胶囊手势"
                                          key:@"HomeScreen.SearchPill.Enabled"
                                      symbols:@[@"hand.tap", @"hand.point.up.left.fill", @"cursorarrow.click"]
                                       color:@"teal"
                                      defVal:NO]];
        [specs addObject:[self erGestureNamed:@"上滑胶囊" key:@"HomeScreen.SearchPill.GestureUp"   symbol:@"arrow.up"    color:@"blue"]];
        [specs addObject:[self erGestureNamed:@"下滑胶囊" key:@"HomeScreen.SearchPill.GestureDown" symbol:@"arrow.down"  color:@"indigo"]];
        [specs addObject:[self erGestureNamed:@"左滑胶囊" key:@"HomeScreen.SearchPill.GestureLeft" symbol:@"arrow.left"  color:@"teal"]];
        [specs addObject:[self erGestureNamed:@"右滑胶囊" key:@"HomeScreen.SearchPill.GestureRight" symbol:@"arrow.right" color:@"purple"]];

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

#pragma mark - 手势页开关 cell（1.2.0-10）

// 1.2.0-10 · 「开关消失」换方案：1.2.0-9 坐标换算后用户实测开关仍不显示——
// 放弃 ERModuleIconSwitchCell（它强制重摆 UISwitch，坐标/时机在本页不成立）。
// 本类**完全不碰 UISwitch**：基类 PSSwitchCell 自己放开关（其它页原生开关一直
// 正常），我们只做两件事——refresh 把 iconImage 写进 imageView；layoutSubviews
// 给图标定位 + 标题右移。
static Class ERGSwitchCellClass = NULL;
static IMP gERGSuperLayout = NULL;
static IMP gERGSuperRefresh = NULL;

static void ERGSwitchLayout(id self, SEL _cmd) {
    if (gERGSuperLayout) ((void (*)(id, SEL))gERGSuperLayout)(self, _cmd);
    @try {
        UITableViewCell *cell = (UITableViewCell *)self;
        if (!cell.imageView.image) return;
        CGFloat h = cell.contentView.bounds.size.height;
        CGFloat left = cell.contentView.layoutMargins.left;
        cell.imageView.frame = CGRectMake(left, (h - 27.0) / 2.0, 27.0, 27.0);
        UILabel *label = cell.textLabel;
        if (label) {
            CGFloat lx = left + 27.0 + 12.0;
            CGRect f = label.frame;
            f.origin.x = lx;
            f.size.width = MIN(f.size.width,
                               cell.contentView.bounds.size.width - lx - 90.0);
            label.frame = f;
        }
    } @catch (__unused NSException *e) {}
}

static void ERGSwitchRefresh(id self, SEL _cmd, PSSpecifier *spec) {
    if (gERGSuperRefresh) ((void (*)(id, SEL, id))gERGSuperRefresh)(self, _cmd, spec);
    @try {
        UIImage *icon = [spec propertyForKey:@"iconImage"];
        if (icon) ((UITableViewCell *)self).imageView.image = icon;
    } @catch (__unused NSException *e) {}
}

static void ERGEnsureSwitchCellClass(void) {
    if (ERGSwitchCellClass) return;
    Class base = NSClassFromString(@"PSSwitchCell");
    if (!base) return;
    Method lay = class_getInstanceMethod(base, @selector(layoutSubviews));
    Method ref = class_getInstanceMethod(base, @selector(refreshCellContentsWithSpecifier:));
    if (!lay || !ref) return;
    Class cls = objc_allocateClassPair(base, "ERGestureSwitchCell", 0);
    if (!cls) return;
    gERGSuperLayout = method_getImplementation(lay);
    gERGSuperRefresh = method_getImplementation(ref);
    class_addMethod(cls, @selector(layoutSubviews), (IMP)ERGSwitchLayout, "v@:");
    class_addMethod(cls, @selector(refreshCellContentsWithSpecifier:),
                    (IMP)ERGSwitchRefresh, "v@:@");
    objc_registerClassPair(cls);
    ERGSwitchCellClass = cls;
    ERGPrefsLog(@"ERGestureSwitchCell registered base=%@", NSStringFromClass(base));
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
    // 1.2.0-10 · 开关消失修复：改用本文件运行期注册的 ERGestureSwitchCell
    //（不碰开关，只注入图标）。注册失败兜底原生 PSSwitchCell（开关必有，图标无）。
    if (ERGSwitchCellClass) {
        [sw setProperty:ERGSwitchCellClass forKey:@"cellClass"];
    } // 未注册时保留 cell:PSSwitchCell 的默认 cellClass
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
