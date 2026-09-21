#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

// 1.0.7-15 · 根页「插件作者」卡。
//
// 参照用户提供的截图样式：左侧方形圆角头像（= 插件图标，与主屏 App 图标同款式，
// 不做圆形），右侧两行左对齐文字——上行 Strive（粗体），下行副文本（灰色）。
// 静态卡：不可点击、无 accessory。
@interface ERAuthorCell : PSTableCell
@end

@implementation ERAuthorCell {
    UIImageView *_avatar;
    UILabel *_nameLabel;
    UILabel *_subtitleLabel;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.layoutMargins = UIEdgeInsetsZero;
        self.separatorInset = UIEdgeInsetsZero;

        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        UIImage *icon = [UIImage imageNamed:@"icon"
                                   inBundle:bundle
              compatibleWithTraitCollection:nil];
        if (!icon) {
            NSString *path = [bundle pathForResource:@"icon" ofType:@"png"];
            if (path) icon = [UIImage imageWithContentsOfFile:path];
        }
        _avatar = [[UIImageView alloc] initWithImage:icon];
        _avatar.contentMode = UIViewContentModeScaleAspectFill;
        _avatar.clipsToBounds = YES;
        _avatar.layer.cornerRadius = 9.0;        // 方底圆角：主屏图标同款式
        _avatar.layer.masksToBounds = YES;
        _avatar.layer.borderWidth = 0.5;
        _avatar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        _avatar.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_avatar];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.text = @"Strive";
        _nameLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        _nameLabel.textColor = [UIColor labelColor] ?: UIColor.whiteColor;
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_nameLabel];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.text = @"不要为了升级，放弃越狱的乐趣！";
        _subtitleLabel.font = [UIFont systemFontOfSize:13.0];
        _subtitleLabel.textColor = [UIColor secondaryLabelColor]
            ?: [UIColor colorWithWhite:1.0 alpha:0.55];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_subtitleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_avatar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
            [_avatar.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_avatar.widthAnchor constraintEqualToConstant:44.0],
            [_avatar.heightAnchor constraintEqualToConstant:44.0],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_avatar.trailingAnchor constant:12.0],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
            // 1.0.9-8 · 用户反馈：文字块（Strive + 签名）整体偏上、与 44pt 头像不齐 →
            // 下移 4pt 与头像垂直居中对齐（顶部留白 8 → 12），底部同步收紧（-12 → -8）保持卡片高度。
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12.0],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3.0],
            [_subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8.0],
        ]];
    }
    return self;
}

// 用户要求整卡内容左对齐：忽略 Preferences 默认的缩进/对齐处理。
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layoutMargins = UIEdgeInsetsZero;
}

@end
