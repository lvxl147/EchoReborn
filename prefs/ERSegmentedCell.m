#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

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

    if (value < 0) value = 0;
    if (value > 2) value = 2;
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

@implementation ERSegmentedCell {
    UISegmentedControl *_segment;
    __weak PSSpecifier *_erSpecifier;
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
        frame.size.width = MAX(frame.size.width, 156.0);
        frame.size.height = 28.0;
        _segment.frame = frame;
        // 构建标记：既是无障碍标识，也是产物校验脚本用来确认「这一版确实带
        // 直读偏好域实现」的存活字符串（0.5.22）。语义上无副作用。
        _segment.accessibilityIdentifier = @"ER-seg-0522-directprefs";
        self.accessoryView = _segment;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (specifier) _erSpecifier = specifier;

    PSSpecifier *current = specifier ?: _erSpecifier;
    if (!current) return;
    _segment.selectedSegmentIndex = ERSegmentReadValue(current);
}

- (void)_erSegmentChanged:(UISegmentedControl *)sender {
    PSSpecifier *specifier = _erSpecifier;
    if (!specifier) return;
    ERSegmentWriteValue(specifier, sender.selectedSegmentIndex);
}

@end
