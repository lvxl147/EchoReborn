#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

// 1.0.8-60 · 「天气城市」单行：左侧图标 + 中间输入框 + 右侧「确认」按钮。
// 输入只暂存在输入框里；点「确认」才写入生效键（Weather.CityOverride）并发
// ReloadPrefs —— 不点确认就用原来的城市。留空确认 = 跟随天气定位城市。
@interface ERWeatherCityCell : PSTableCell
@end

@implementation ERWeatherCityCell {
    UITextField *_field;
    UIButton *_confirm;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        NSString *domain = @"com.strive.echoreborn.preferences";
        NSString *current = (__bridge NSString *)CFPreferencesCopyAppValue(
            (__bridge CFStringRef)@"Weather.CityOverride", (__bridge CFStringRef)domain);

        _field = [[UITextField alloc] initWithFrame:CGRectZero];
        _field.placeholder = @"留空=天气定位城市";
        _field.text = current ?: @"";
        _field.font = [UIFont systemFontOfSize:16.0];
        _field.textAlignment = NSTextAlignmentLeft;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        [_field addTarget:self action:@selector(erEditingChanged)
         forControlEvents:UIControlEventEditingChanged];
        [self.contentView addSubview:_field];

        _confirm = [UIButton buttonWithType:UIButtonTypeCustom];
        [_confirm setTitle:@"确认" forState:UIControlStateNormal];
        _confirm.titleLabel.font = [UIFont systemFontOfSize:15.0];
        if ([UIColor respondsToSelector:@selector(systemGreenColor)]) {
            [_confirm setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
        }
        _confirm.layer.cornerRadius = 6.0;
        _confirm.layer.borderWidth = 1.0;
        _confirm.layer.borderColor = [UIColor systemGreenColor].CGColor;
        [_confirm addTarget:self action:@selector(erConfirmTapped)
         forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_confirm];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat buttonWidth = 56.0;
    CGFloat left = 92.0;                    // 给左侧图标与「天气城市」标题留位
    _field.frame = CGRectMake(left, 6.0, width - left - buttonWidth - 20.0, 30.0);
    _confirm.frame = CGRectMake(width - buttonWidth - 12.0, 6.0, buttonWidth, 30.0);
}

- (void)erEditingChanged {
    // 输入过程不写偏好 —— 只有确认才生效
}

- (void)erConfirmTapped {
    NSString *city = [_field.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *domain = @"com.strive.echoreborn.preferences";
    CFPreferencesSetAppValue((__bridge CFStringRef)@"Weather.CityOverride",
                             (__bridge CFStringRef)city, (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.strive.echoreborn/ReloadPrefs"),
                                         NULL, NULL, YES);
}

@end
