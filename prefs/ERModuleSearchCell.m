#import "ERModuleSearchCell.h"
#import <objc/message.h>

@implementation ERModuleSearchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = UIColor.clearColor;
        _searchField = [[UITextField alloc] init];
        _searchField.placeholder = @"搜索模块";
        _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
        _searchField.returnKeyType = UIReturnKeySearch;
        _searchField.font = [UIFont systemFontOfSize:17.0];
        _searchField.delegate = self;
        _searchField.translatesAutoresizingMaskIntoConstraints = NO;
        [_searchField addTarget:self action:@selector(erTextChanged:) forControlEvents:UIControlEventEditingChanged];
        [self.contentView addSubview:_searchField];
        [NSLayoutConstraint activateConstraints:@[
            [_searchField.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [_searchField.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [_searchField.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6.0],
            [_searchField.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6.0],
        ]];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    NSString *text = [specifier propertyForKey:@"erSearchText"];
    if ([text isKindOfClass:[NSString class]] && ![text isEqualToString:self.searchField.text]) {
        self.searchField.text = text;
    }
    self.searchField.placeholder = [specifier propertyForKey:@"erSearchPlaceholder"] ?: @"搜索模块";
}

- (void)erTextChanged:(UITextField *)field {
    id target = [self.specifier propertyForKey:@"erSearchTarget"];
    NSString *actionName = [self.specifier propertyForKey:@"erSearchAction"];
    SEL selector = actionName.length ? NSSelectorFromString(actionName) : NULL;
    if (target && selector && [target respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, selector, field.text ?: @"");
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
