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
        [byCategory[cat] addObject:entry];
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

- (UIImage *)erIconForEntry:(NSDictionary *)entry {
    NSString *path = entry[@"path"];
    if (![path isKindOfClass:[NSString class]] || !path.length) return [UIImage systemImageNamed:@"puzzlepiece.extension.fill"];
    for (NSString *name in @[@"SettingsIcon@3x.png", @"SettingsIcon@2x.png", @"SettingsIcon.png",
                             @"icon@3x.png", @"icon@2x.png", @"icon.png",
                             @"Icon@2x.png", @"Icon.png"]) {
        NSString *file = [path stringByAppendingPathComponent:name];
        UIImage *image = [UIImage imageWithContentsOfFile:file];
        if (image) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];   // 1.2.2-123 · 不渲染成主题蓝
    }
    return [UIImage systemImageNamed:@"puzzlepiece.extension.fill"];
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
