#import "ERModuleManagerController.h"
#import <Preferences/PSSpecifier.h>

static NSString *const kERMMDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERMMReloadNotification = @"com.strive.echoreborn/ReloadPrefs";

@interface ERModuleManagerController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, copy) NSString *filterText;
@property (nonatomic, strong) NSArray<NSDictionary *> *sections;   // @{@"title": NSString, @"rows": NSArray}
@end

@implementation ERModuleManagerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"\u72ec\u7acb\u6a21\u5757";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 52)];
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = @"\u641c\u7d22\u6a21\u5757";
    self.searchBar.delegate = self;
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;
    [self.view addSubview:self.tableView];

    // 1.2.2-123 · 补回右上角「编辑」（分类管理入口），与旧版一致。
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"编辑"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(erOpenCategoryOrder:)];

    [self erReloadSections];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self erReloadSections];
}

// ---------------------------------------------------------------------------
// \u6570\u636e\uff1a\u8bfb tweak \u53d1\u5e03\u7684\u6e05\u5355\uff0c\u6309 CategoryOrder \u6392\u5e8f\uff0c\u6309\u5206\u7c7b\u5206\u7ec4
// ---------------------------------------------------------------------------
- (void)erReloadSections {
    NSArray *cache = (__bridge_transfer NSArray *)CFPreferencesCopyAppValue(CFSTR("ERModuleCatalogCache"), (__bridge CFStringRef)kERMMDomain);
    if (![cache isKindOfClass:[NSArray class]]) cache = @[];
    NSArray *order = (__bridge_transfer NSArray *)CFPreferencesCopyAppValue(CFSTR("CategoryOrder"), (__bridge CFStringRef)kERMMDomain);
    if (![order isKindOfClass:[NSArray class]]) order = @[];

    NSMutableArray<NSString *> *categoryOrder = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray *> *byCategory = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in cache) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *cat = entry[@"cat"] ?: @"\u5176\u4ed6";
        NSString *name = entry[@"name"] ?: entry[@"id"] ?: @"";
        NSLog(@"[ERMM] module %@", name);
        if (!byCategory[cat]) { byCategory[cat] = [NSMutableArray array]; [categoryOrder addObject:cat]; }
        // 1.2.2-145 · 指定改名：正在播放 → 播放控制
        NSDictionary *rowEntry = entry;
        if ([[entry[@"id"] lowercaseString] containsString:@"nowplaying"]) {
            NSMutableDictionary *renamed = [entry mutableCopy];
            renamed[@"name"] = @"播放控制";
            rowEntry = renamed;
        }
        [byCategory[cat] addObject:rowEntry];
    }
    NSMutableArray<NSString *> *sortedOrder = [NSMutableArray array];
    for (NSString *cat in order) {
        if (byCategory[cat] && ![sortedOrder containsObject:cat]) [sortedOrder addObject:cat];
    }
    for (NSString *cat in categoryOrder) {
        if (![sortedOrder containsObject:cat]) [sortedOrder addObject:cat];
    }

    NSString *filter = self.filterText.length ? self.filterText.lowercaseString : nil;
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    for (NSString *cat in sortedOrder) {
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *entry in byCategory[cat]) {
            NSString *name = entry[@"name"] ?: @"";
            NSString *identifier = entry[@"id"] ?: @"";
            if (filter.length) {
                NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@", name, identifier, cat].lowercaseString;
                if (![haystack containsString:filter]) continue;
            }
            [rows addObject:entry];
        }
        if (rows.count) [sections addObject:@{@"title": cat, @"rows": rows}];
    }
    self.sections = sections;
    [self.tableView reloadData];
}

// ---------------------------------------------------------------------------
// \u8868\u683c
// ---------------------------------------------------------------------------
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.sections.count; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section][@"title"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ERMMCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.tag = 0xE001;
        [toggle addTarget:self action:@selector(erToggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    NSDictionary *entry = self.sections[indexPath.section][@"rows"][indexPath.row];
    NSString *moduleID = entry[@"id"] ?: @"";
    cell.textLabel.text = entry[@"name"] ?: moduleID;
    cell.imageView.image = [self erIconForEntry:entry];
    // 1.2.2-124 · 图标不再被染成主题蓝：回退用的 SF Symbol 是模板图，
    // 默认跟 tintColor（蓝）走；这里把行内图标 tint 改为二级文字色。
    cell.imageView.tintColor = [UIColor secondaryLabelColor];

    UISwitch *toggle = (UISwitch *)[cell.accessoryView viewWithTag:0xE001];
    if (!toggle) toggle = (UISwitch *)cell.accessoryView;
    toggle.on = [self erModuleEnabled:moduleID];
    toggle.accessibilityIdentifier = moduleID;
    return cell;
}

// ---------------------------------------------------------------------------
// \u5f00\u5173\u4e0e\u56fe\u6807
// ---------------------------------------------------------------------------
- (BOOL)erModuleEnabled:(NSString *)moduleID {
    NSString *key = [NSString stringWithFormat:@"ModuleEnabled_%@", moduleID];
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kERMMDomain);
    BOOL enabled = value ? CFBooleanGetValue((CFBooleanRef)value) : YES;
    if (value) CFRelease(value);
    return enabled;
}

- (void)erSetModule:(NSString *)moduleID enabled:(BOOL)enabled {
    NSString *key = [NSString stringWithFormat:@"ModuleEnabled_%@", moduleID];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)(enabled ? @YES : @NO), (__bridge CFStringRef)kERMMDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERMMDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kERMMReloadNotification, NULL, NULL, true);
}

- (void)erToggleChanged:(UISwitch *)toggle {
    [self erSetModule:toggle.accessibilityIdentifier enabled:toggle.on];
}

// 1.2.2-128 · 统一图标：任何来源都裁到 29pt 方框（与自研模块行一致），按比例适配居中，原色渲染。
- (UIImage *)erNormalizeIcon:(UIImage *)image {
    if (!image) return nil;
    CGFloat box = 29.0;
    // 1.2.2-129 · 关键修复：Assets.car 里的图常被标记为 template，直接画会变成
    // 黑色剪影（官方设置页是彩色的）—— 强制原色模式再画，并裁成圆角方框。
    UIImage *original = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(box, box)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGSize size = original.size;
        CGFloat scale = MIN(box / MAX(size.width, 1.0), box / MAX(size.height, 1.0));
        CGFloat width = size.width * scale, height = size.height * scale;
        CGFloat x = (box - width) * 0.5, y = (box - height) * 0.5;
        UIBezierPath *rounded = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, width, height)
                                                           cornerRadius:width * 0.2237];
        [rounded addClip];
        [original drawInRect:CGRectMake(x, y, width, height)];
    }];
}

- (UIImage *)erIconForEntry:(NSDictionary *)entry {
    // 1.2.2-141 · 8 个系统模块的官方样式适配（彩色圆角方块 + 白字形）。
    // 放在最前：这几个模块 bundle 里的图标是占位图（蓝色拼图/黑色方块），必须抢先。
    NSString *erIDString = entry[@"id"];
    if (![erIDString isKindOfClass:[NSString class]]) erIDString = @"";
    NSString *erLower = erIDString.lowercaseString;
    // 1.2.2-145 · 匹配通道加「名称」：有的模块 identifier 对不上但名称对得上
    NSString *erNameString = entry[@"name"];
    if (![erNameString isKindOfClass:[NSString class]]) erNameString = @"";
    NSString *erNameLower = erNameString.lowercaseString;
    NSDictionary<NSString *, NSArray *> *erCustom = @{
        @"flashlightmodule":   @[@"flashlight.on.fill", @"#3478F6"],
        @"textsize":           @[@"大小", @"#3478F6"],
        @"文字大小":            @[@"大小", @"#3478F6"],
        @"orientationlock":    @[@"lock.rotation", @"#8E8E93"],
        @"displaymodule":      @[@"sun.max.fill", @"#48484A"],
        @"focusui":            @[@"moon.fill", @"#5E5CE6"],
        @"airplaymirroring":   @[@"rectangle.on.rectangle", @"#8E8E93"],
        @"audiomodule":        @[@"speaker.wave.2.fill", @"#48484A"],
        @"音量":                @[@"speaker.wave.2.fill", @"#48484A"],
        @"connectivitymodule": @[@"antenna.radiowaves.left.and.right", @"#30D158"],
        @"连接":                @[@"antenna.radiowaves.left.and.right", @"#30D158"],
        @"nowplaying":         @[@"playpause.fill", @"#48484A"],
        @"播放控制":            @[@"playpause.fill", @"#48484A"],
    };
    for (NSString *erKey in erCustom) {
        if ([erLower containsString:erKey.lowercaseString] || [erNameLower containsString:erKey.lowercaseString]) {
            NSArray *erPair = erCustom[erKey];
            UIColor *erColor = [self erColorFromHex:erPair[1]];
            UIGraphicsImageRenderer *erRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(29, 29)];
            UIImage *erRendered = [erRenderer imageWithActions:^(UIGraphicsImageRendererContext *erCtx) {
                CGRect erBox = CGRectMake(0, 0, 29, 29);
                UIBezierPath *erRounded = [UIBezierPath bezierPathWithRoundedRect:erBox cornerRadius:29.0 * 0.2237];
                [erRounded addClip];
                [erColor setFill];
                UIRectFill(erBox);
                [UIColor.whiteColor setFill];
                if ([erPair[0] isEqualToString:@"大小"]) {
                    // 文字大小：官方就是白色「大小」两字
                    NSMutableAttributedString *erText = [[NSMutableAttributedString alloc]
                        initWithString:@"大小"
                            attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:10.5],
                                         NSForegroundColorAttributeName: UIColor.whiteColor}];
                    CGSize erTextSize = [erText size];
                    [erText drawAtPoint:CGPointMake((29 - erTextSize.width) * 0.5,
                                                    (29 - erTextSize.height) * 0.5)];
                } else {
                    UIImage *erSymbol = [[UIImage systemImageNamed:erPair[0]]
                                         imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
                    CGSize erSize = erSymbol.size;
                    CGFloat erScale = MIN(29.0 / MAX(erSize.width, 1.0), 29.0 / MAX(erSize.height, 1.0)) * 0.80;
                    CGFloat erWidth = erSize.width * erScale, erHeight = erSize.height * erScale;
                    [erSymbol drawInRect:CGRectMake((29 - erWidth) * 0.5, (29 - erHeight) * 0.5, erWidth, erHeight)];
                }
            }];
            return [erRendered imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        }
    }
    NSString *path = entry[@"path"];
    if ([path isKindOfClass:[NSString class]] && path.length) {
        // 1.2.2-128 · 部分模块的图标在 Assets.car 里（无 PNG 文件），文件读取拿不到 → 改用 NSBundle imageNamed 加载资产目录。
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (bundle) {
            // 1.2.2-130 · 官方设置页用的是 SettingsIcon（彩色圆角）；很多模块的
            // AppIcon 是黑色占位图，不能放在前面。
            for (NSString *name in @[@"SettingsIcon", @"AppIcon", @"ModuleIcon", @"icon", @"Icon"]) {
                UIImage *asset = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
                if (asset) return [self erNormalizeIcon:asset];
            }
        }
        for (NSString *name in @[@"SettingsIcon@3x.png", @"SettingsIcon@2x.png", @"SettingsIcon.png",
                                 @"icon@3x.png", @"icon@2x.png", @"icon.png",
                                 @"Icon@2x.png", @"Icon.png"]) {
            NSString *file = [path stringByAppendingPathComponent:name];
            UIImage *image = [UIImage imageWithContentsOfFile:file];
            if (image) return [self erNormalizeIcon:image];
        }
    }
    return [self erNormalizeIcon:[UIImage systemImageNamed:@"puzzlepiece.extension.fill"]];
}

// 1.2.2-140 · #RRGGBB → UIColor
- (UIColor *)erColorFromHex:(NSString *)hex {
    if (![hex isKindOfClass:[NSString class]] || hex.length != 7 || ![hex hasPrefix:@"#"]) return UIColor.grayColor;
    unsigned int erValue = 0;
    [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&erValue];
    return [UIColor colorWithRed:((erValue >> 16) & 0xFF) / 255.0
                           green:((erValue >> 8) & 0xFF) / 255.0
                            blue:(erValue & 0xFF) / 255.0
                           alpha:1.0];
}

// ---------------------------------------------------------------------------
// \u641c\u7d22
// ---------------------------------------------------------------------------
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.filterText = searchText ?: @"";
    [self erReloadSections];
    self.tableView.tableHeaderView = self.searchBar;   // \u81ea\u5e26\u8868\u683c\u4e0d\u4f1a\u88ab\u91cd\u7f6e\uff0c\u8fd9\u91cc\u4fdd\u9669\u518d\u6302\u4e00\u6b21
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:NO animated:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    // 1.2.2-124 · 取消：清空关键字、收键盘、恢复全部模块
    [searchBar setShowsCancelButton:NO animated:YES];
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    self.filterText = @"";
    [self erReloadSections];
}


// 1.2.2-123 · 右上角「编辑」→ 分类管理（分类顺序）
- (void)erOpenCategoryOrder:(id)sender {
    Class orderClass = NSClassFromString(@"ERCategoryOrderController");
    if (!orderClass) return;
    UIViewController *controller = [[orderClass alloc] init];
    if ([controller isKindOfClass:[UIViewController class]]) {
        [self.navigationController pushViewController:controller animated:YES];
    }
}

@end
