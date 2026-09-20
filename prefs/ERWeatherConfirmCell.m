#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

// 1.0.8-60 · 「天气模块城市选择」的确认行：点击后把「天气城市」输入框里的待生效
// 城市（Weather.CityPending）写入真正的生效键（Weather.CityOverride），并发
// ReloadPrefs 让磁贴立刻重取。不点确认就保持原城市 —— 输入错了也不会误生效。
@interface ERWeatherConfirmCell : PSTableCell
@end

@implementation ERWeatherConfirmCell {
    UIButton *_tapButton;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.textLabel.text = @"确认生效";
        if ([UIColor respondsToSelector:@selector(systemGreenColor)]) {
            self.textLabel.textColor = [UIColor systemGreenColor];
        }
        self.textLabel.font = [UIFont systemFontOfSize:16.0];
        self.textLabel.textAlignment = NSTextAlignmentCenter;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        _tapButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _tapButton.backgroundColor = UIColor.clearColor;
        _tapButton.accessibilityLabel = @"确认生效";
        [_tapButton addTarget:self action:@selector(erConfirmTapped)
             forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_tapButton];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _tapButton.frame = self.contentView.bounds;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    UIImage *icon = [specifier propertyForKey:@"iconImage"];
    if ([icon isKindOfClass:[UIImage class]]) self.imageView.image = icon;
}

- (void)erConfirmTapped {
    NSString *domain = @"com.strive.echoreborn.preferences";
    NSString *pending = (__bridge NSString *)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)@"Weather.CityPending", (__bridge CFStringRef)domain);
    NSString *city = [pending stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!city.length) city = @"";
    CFPreferencesSetAppValue((__bridge CFStringRef)@"Weather.CityOverride",
                             (__bridge CFStringRef)city, (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.strive.echoreborn/ReloadPrefs"),
                                         NULL, NULL, YES);
}

@end
