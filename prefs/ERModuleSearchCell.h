#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>

/// 1.2.2-117 · 模块管理页的搜索行：作为列表首行存在（而不是 tableHeaderView /
/// navigationItem）—— Preferences 在入场后会重置前两者，但不会重置 specifier 行。
@interface ERModuleSearchCell : PSTableCell <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *searchField;
@end
