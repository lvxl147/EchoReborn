#import <Preferences/PSViewController.h>

/// 1.2.2-122 · 「模块管理」重写为 PSViewController + 自带 UITableView（与「快捷指令」子页同一结构）。
/// 原因：PSListController 会在入场后重置 tableHeaderView 与 navigationItem.searchController，
/// 导致搜索栏「闪一下消失」；自带表格则不受影响。
@interface ERModuleManagerController : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end
