#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

// 1.0.7-23：「一键恢复横屏布局」。
//
// 为什么不用 PSButtonCell + plist 里的 action：本项目此前两次卡在「action 派发」
// 这一环（plist 装载版与代码重建版都是点了没反应，见 ERRootListController.m 的说明）。
// 这里自绘一行，内部 UIButton 直连 addTarget，完全不依赖框架的 action 派发路径。
//
// 点一下不会立刻执行：先弹二次确认（避免误触），确认后才做两件事 ——
//   ① 从偏好域里删掉 COSMICLandscapeOrigins（横屏账本）；
//   ② 发 ReloadPrefs 通知，让 SpringBoard 侧重读账本并回到「按竖屏布局折行」。
// 竖屏账本 ModuleGridOrigins 一个字节都不动，所以竖屏布局不受影响。
@interface ERLandscapeResetCell : PSTableCell
@end

@implementation ERLandscapeResetCell {
    UIButton *_tapButton;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.textLabel.text = @"恢复横屏布局";
        if ([UIColor respondsToSelector:@selector(systemRedColor)]) {
            self.textLabel.textColor = [UIColor systemRedColor];
        } else {
            self.textLabel.textColor = [UIColor redColor];
        }
        self.textLabel.font = [UIFont systemFontOfSize:16.0];
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        _tapButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _tapButton.backgroundColor = UIColor.clearColor;
        _tapButton.accessibilityLabel = @"恢复横屏布局";
        [_tapButton addTarget:self action:@selector(erResetTapped) forControlEvents:UIControlEventTouchUpInside];
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
    // 图标由 ERUIHelpers 的 erApplyIcons 挂到 specifier 的 iconImage 上；自定义 cell
    // 自己取一次，不依赖 PSListController 的默认装配。
    UIImage *icon = [specifier propertyForKey:@"iconImage"];
    if ([icon isKindOfClass:[UIImage class]]) self.imageView.image = icon;
    NSString *label = [specifier propertyForKey:@"label"];
    if ([label isKindOfClass:[NSString class]] && label.length) self.textLabel.text = label;
}

- (UIViewController *)erPresenter {
    UIResponder *responder = self;
    while ((responder = [responder nextResponder])) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
    }
    return nil;
}

- (void)erResetTapped {
    UIViewController *presenter = [self erPresenter];
    if (!presenter) {
        // 1.0.8-62 · 兜底：拿不到控制器（部分自定义表格的 cell 层级里
        // nextResponder 链上没有 UIViewController）时**直接执行恢复**，
        // 不再静默返回 —— 这就是「恢复横屏布局点不了」的原因。
        [self erPerformResetFromPresenter:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复横屏布局？"
                                                                  message:@"将清除横屏下的所有摆放，横屏恢复为按竖屏布局一分为二展示（左 1–4 行 / 右 5–8 行）。\n竖屏布局不受影响。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self erPerformResetFromPresenter:presenter];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)erPerformResetFromPresenter:(UIViewController *)presenter {
    if (!presenter) {
        // 无弹窗兜底：直接恢复 + 发刷新通知
        CFPreferencesSetAppValue(CFSTR("COSMICLandscapeOrigins"), NULL, CFSTR("com.strive.echoreborn.preferences"));
        CFPreferencesAppSynchronize(CFSTR("com.strive.echoreborn.preferences"));
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.strive.echoreborn/ReloadPrefs"),
                                             NULL, NULL, YES);
        return;
    }
    CFStringRef domain = CFSTR("com.strive.echoreborn.preferences");
    CFPreferencesSetAppValue(CFSTR("COSMICLandscapeOrigins"), NULL, domain);   // NULL = 删除该键
    CFPreferencesAppSynchronize(domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.strive.echoreborn/ReloadPrefs"),
                                         NULL, NULL, YES);
    UIAlertController *done = [UIAlertController alertControllerWithTitle:@"已恢复"
                                                                 message:@"横屏将按竖屏布局显示（重新下拉控制中心即可看到）；之前摆放的横屏位置已清空。"
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:done animated:YES completion:nil];
}

@end
