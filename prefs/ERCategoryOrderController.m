#import "ERCategoryOrderController.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <stdarg.h>

// Must match kERPrefsDomain in Tweak.xm.
static NSString *const kERCategoryPrefsDomain = @"com.strive.echoreborn.preferences";
static NSString *const kERCategoryOrderKey = @"CategoryOrder";
static NSString *const kERCategoryDisabledKey = @"DisabledCategories";

// Diagnostics. The pane used to fail in ways that could not be observed from
// the outside (a bare empty shell, with no crash and no alert), so every step
// of this controller's own setup writes a marker to the same log the tweak
// uses. `[PREFS] categoryPane:` in echoreborn.log now answers "did the controller
// get built, how many rows, did a toggle persist" without guesswork.
static void ERPrefsLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [PREFS] %@\n",
                      [NSDate date].description, message];
    NSString *directory = @"/var/mobile/Library/Logs/EchoReborn";
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"echoreborn.log"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *exception) {
    } @finally {
        @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
    }
}

// The stock order. Keep in sync with ERDefaultCategoryOrder() in Tweak.xm: it
// seeds the list the first time the pane opens, and absorbs any category a
// newer tweak build introduces that the saved order does not mention yet.
static NSArray<NSString *> *ERDefaultCategories(void) {
    return @[@"辅助功能", @"拍摄", @"时钟", @"连接", @"显示", @"专注", @"家庭",
             @"媒体", @"备忘录", @"语音备忘录", @"钱包", @"实用工具",
             @"快捷指令", @"第三方插件"];
}

static NSString *const kERCategoryCellIdentifier = @"ERCategoryCell";

// Gap between the switch and the table's own reorder handle, in points. The
// switch is padded away from the trailing edge by exactly this much so the two
// controls read as one trailing cluster, "[开关] ☰", instead of touching.
static CGFloat const kERCategorySwitchToHandleGap = 12.0;

@interface ERCategoryOrderController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSString *> *categories;
@property (nonatomic, strong) NSMutableSet<NSString *> *disabled;
@end

@implementation ERCategoryOrderController

// Read straight from the preference domain rather than through
// NSUserDefaults. A PreferenceBundle does not necessarily run with the tweak's
// domain as its own bundle identifier, so -arrayForKey: can silently return nil
// while the value is genuinely present. CFPreferences is what Tweak.xm writes,
// so it is what this pane reads.
- (NSArray *)storedArrayForKey:(NSString *)key {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kERCategoryPrefsDomain);
    NSArray *result = nil;
    if (value) {
        if (CFGetTypeID(value) == CFArrayGetTypeID()) result = [(__bridge NSArray *)value copy];
        CFRelease(value);
    }
    return result;
}

// MARK: - Lifecycle

- (void)loadView {
    ERPrefsLog(@"categoryPane: loadView entered");
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 480.0)];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITableView *tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.editing = YES;
    tableView.allowsSelectionDuringEditing = NO;
    // The row content is inset a little less than the stock margin so the
    // trailing cluster — the switch and the reorder handle to its right — is
    // not pushed too far in. The name keeps the leading side to itself.
    tableView.layoutMargins = UIEdgeInsetsMake(0.0, 16.0, 0.0, 8.0);
    tableView.separatorInset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 0.0);
    [tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kERCategoryCellIdentifier];
    [self.view addSubview:tableView];
    self.tableView = tableView;
    ERPrefsLog(@"categoryPane: loadView done");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Seeded before the table's first data-source pass below, so there is no
    // window in which the pane can render zero rows.
    [self loadState];
    self.title = @"分类管理";
    self.navigationItem.rightBarButtonItem = nil;
    [self.tableView reloadData];
    ERPrefsLog(@"categoryPane: viewDidLoad done, %lu categor(ies), %lu disabled",
                (unsigned long)self.categories.count, (unsigned long)self.disabled.count);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The table is permanently in edit mode so every row keeps its reorder
    // handle; doing this here (rather than only once in viewDidLoad) survives
    // the navigation controller's own layout pass resetting the flag.
    self.tableView.editing = YES;
    self.navigationItem.rightBarButtonItem = nil;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Row reordering only mutates the in-memory array, so persist on the way
    // out. Switch toggles persist immediately in their own handler.
    [self persist];
}

// MARK: - State

- (void)loadState {
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id entry in [self storedArrayForKey:kERCategoryOrderKey]) {
        if (![entry isKindOfClass:[NSString class]] || ![entry length]) continue;
        if ([order containsObject:entry]) continue;
        [order addObject:entry];
    }
    for (NSString *category in ERDefaultCategories()) {
        if (![order containsObject:category]) [order addObject:category];
    }
    self.categories = order;

    self.disabled = [NSMutableSet set];
    for (id entry in [self storedArrayForKey:kERCategoryDisabledKey]) {
        if ([entry isKindOfClass:[NSString class]] && [entry length]) [self.disabled addObject:entry];
    }
}

- (void)persist {
    CFPreferencesSetAppValue((__bridge CFStringRef)kERCategoryOrderKey,
                             (__bridge CFPropertyListRef)[self.categories copy],
                             (__bridge CFStringRef)kERCategoryPrefsDomain);
    CFPreferencesSetAppValue((__bridge CFStringRef)kERCategoryDisabledKey,
                             (__bridge CFPropertyListRef)[self.disabled.allObjects copy],
                             (__bridge CFStringRef)kERCategoryPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kERCategoryPrefsDomain);
    ERPrefsLog(@"categoryPane: persisted %lu categor(ies), %lu disabled",
                (unsigned long)self.categories.count, (unsigned long)self.disabled.count);
}

// MARK: - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    // One section only. The old second section held a "关闭全部显示" action row;
    // it was removed because every category now has its own switch, so there is
    // nothing at the bottom to scroll to and nothing for that row to do.
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.categories.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return @"每行右侧的开关单独控制一个分类：关闭后，「添加控制项」面板里不再显示该分类（连同它下面的全部模块）。已经添加到控制中心的模块完全不受影响，照常显示和点击。拖动开关右侧的手柄可调整分类顺序。两项修改都会立即保存，重新打开「添加控制项」面板即可生效，无需重启 SpringBoard。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kERCategoryCellIdentifier
                                                            forIndexPath:indexPath];

    // Rebuilt rather than reused. The switch carries its category as an
    // associated object, so a recycled cell must not keep the previous row's
    // switch: the subviews are torn down and recreated every time.
    for (UIView *subview in [cell.contentView.subviews copy]) [subview removeFromSuperview];
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    // The built-in labels are not used on these rows (the name is drawn by our
    // own label). They still participate in the cell's layout when non-empty,
    // so they are cleared and hidden explicitly.
    cell.textLabel.text = nil;
    cell.textLabel.hidden = YES;
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.hidden = YES;

    NSString *category = self.categories[indexPath.row];

    // ---------------------------------------------------------------------
    // Row layout: "名称 ............ [开关] ☰"
    //
    // The name is leading-aligned and the switch is padded in from the
    // trailing edge by kERCategorySwitchToHandleGap, which is exactly the
    // space the table's own reorder handle occupies in edit mode. The result
    // is that the switch and the handle sit together as one trailing cluster
    // and the name has the whole rest of the row to itself.
    //
    // The switch is constrained rather than frame-positioned: the cell's
    // content view width is not final when this method runs, and fix-up via
    // autoresizing would drift on rotation or when the handle appears.
    // ---------------------------------------------------------------------
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = category;
    label.textColor = UIColor.labelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    // Shrinking beats truncating a two-character category name at large text
    // sizes, and stops the label from ever pushing into the switch.
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    [cell.contentView addSubview:label];

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    toggle.on = ![self.disabled containsObject:category];
    toggle.onTintColor = UIColor.systemGreenColor;
    // The category travels with the switch, so a reorder followed by a tap
    // still toggles the category actually drawn on that row.
    objc_setAssociatedObject(toggle, @selector(setOn:), category, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [toggle addTarget:self action:@selector(categorySwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [cell.contentView addSubview:toggle];

    // Dim the name while the category is off, so the row's state is readable
    // without looking at the switch itself.
    label.alpha = toggle.isOn ? 1.0 : 0.45;

    [NSLayoutConstraint activateConstraints:@[
        // Name: from the leading edge all the way up to the switch.
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
        [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-8.0],
        // Switch: pinned to the trailing edge, offset by the handle's width so
        // the handle lands to its right rather than colliding with it.
        [toggle.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor
                                              constant:-kERCategorySwitchToHandleGap],
        [toggle.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
    ]];
    return cell;
}

- (void)categorySwitchChanged:(UISwitch *)toggle {
    NSString *category = objc_getAssociatedObject(toggle, @selector(setOn:));
    if (![category isKindOfClass:[NSString class]] || !category.length) return;
    if (toggle.isOn) [self.disabled removeObject:category];
    else [self.disabled addObject:category];
    // Reflect the on/off state on the row's own label immediately; a full
    // reload here would fight the switch's own animation. The walk up to the
    // cell can legitimately fail (a switch torn out of its cell mid-animation),
    // in which case only the dimming is skipped — the preference is still saved.
    UIView *view = toggle.superview;
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    if ([view isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)view;
        for (UIView *subview in cell.contentView.subviews) {
            if ([subview isKindOfClass:[UILabel class]]) subview.alpha = toggle.isOn ? 1.0 : 0.45;
        }
    }
    ERPrefsLog(@"categoryPane: %@ -> %@", category, toggle.isOn ? @"on" : @"off");
    [self persist];
}
// MARK: - Reordering

// The reorder handle has to come from the table's own edit mode. Every row is
// movable; there is no longer a non-movable action row at the bottom.
- (BOOL)tableView:(__unused UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.row < (NSInteger)self.categories.count;
}

- (void)tableView:(__unused UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSInteger from = sourceIndexPath.row;
    NSInteger to = destinationIndexPath.row;
    if (from < 0 || to < 0) return;
    if (from >= (NSInteger)self.categories.count || to >= (NSInteger)self.categories.count) return;
    if (from == to) return;
    NSString *moved = self.categories[from];
    [self.categories removeObjectAtIndex:from];
    [self.categories insertObject:moved atIndex:to];
    [self persist];
}

- (UITableViewCellEditingStyle)tableView:(__unused UITableView *)tableView editingStyleForRowAtIndexPath:(__unused NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(__unused UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(__unused NSIndexPath *)indexPath {
    return NO;
}

- (NSIndexPath *)tableView:(__unused UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(__unused NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    // There is no non-movable row any more, so the only clamp needed is the
    // bottom edge: the proposed row can be one past the last real row.
    NSInteger last = (NSInteger)self.categories.count - 1;
    if (last < 0) return proposedDestinationIndexPath;
    if (proposedDestinationIndexPath.row > last) {
        return [NSIndexPath indexPathForRow:last inSection:0];
    }
    return proposedDestinationIndexPath;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    self.tableView.editing = YES;
    self.navigationItem.rightBarButtonItem = nil;
}

@end
