#import "ERRootListController.h"
#import "ERCategoryOrderController.h"
#import "ERShortcutController.h"
#import "ERGlassListController.h"
#import "ERModuleSettingsController.h"
#import "EREnhancedSettingsController.h"
#import "ERSokoController.h"
#import "ERBottomComponentsController.h"
#import "ERSiriController.h"
#import "ERSystemEnhanceController.h"
#import "ERUIHelpers.h"
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import <spawn.h>
#import <unistd.h>

// roothide resolves package-relative paths through jbroot(); it is a real
// function there, so __has_include is the only reliable probe.  Under
// rootless/rootful the header is absent and the stub below keeps the same
// call sites compiling and behaving as plain pass-throughs.
#if __has_include(<roothide.h>)
#import <roothide.h>
#else
static inline NSString *ER_jbrootPath(NSString *path) { return path; }
#define jbroot(p) ER_jbrootPath(p)
#endif

extern char **environ;

// Must match the tweak's log constants in Tweak.xm. The log lives outside the
// jailbreak root so both SpringBoard and this bundle reach the same file,
// including under roothide, whose jbroot() is randomised per install.
static NSString *const kERLogDirectory = @"/var/mobile/Library/Logs/EchoReborn";
static NSString *const kERLogFileName = @"echoreborn.log";
static NSString *const kERLogExportedPrefix = @"EchoReborn-log-";
static NSString *const kERLogExportedDirectory = @"/var/mobile/Documents";

// 1.0.7-1：与 ERModuleSettingsController 的 ERModuleLog 同一份实现（各自持有
// 一份 static，避免为了一个函数把两个控制器耦起来）。设置侧的一切关键决策都
// 落 [PREFS] 日志 —— 本轮「系统增强点了没反应」正是因为入口链路上一行日志
// 都没有，坏了也不知道坏在哪一环。
static void ERPrefsLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [PREFS] %@\n", [NSDate date].description, message];
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

@interface ERRootListController ()
- (NSString *)erLogPath;
- (unsigned long long)erLogSize;
- (void)erRefreshLogStatus;
- (void)erPresentAlertWithTitle:(NSString *)title message:(NSString *)message;
@end

@implementation ERRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specifiers = [NSMutableArray arrayWithArray:[self loadSpecifiersFromPlistName:@"Root" target:self]];

        // 1.0.7-2：「系统增强」入口行改为 **PSLinkCell + detail 类对象**。
        //
        // 1.0.7 与 1.0.7-1 两次都卡在「action 派发」这一环（plist 装载版与代码重建版
        // 都点了没反应）。action 派发是框架内部行为，设置进程又写不进我们的日志
        // （[PREFS] 从未在任何一份导出日志里出现过，连模块管理页的历史日志也没有），
        // 既观测不到也无法保证。所以这一版直接换掉机制：改用 Preferences 自身的
        // detail 推入 —— 系统设置里每一个二级页都是这么进的，它不依赖我们写的任何
        // 方法，也就不存在「派发没派发」这个问题。
        //
        // 关键点：detail 必须传**类对象**。传字符串会走 NSClassFromString 的跨 bundle
        // 查找 —— 本文件上方注释明确记过那条路会「There was an error loading the
        // preference bundle」；传类对象则完全没有查找，类已经在内存里。
        //
        // 行的位置仍由 plist 占位决定（按 label 找，label 是 cell 真正用来渲染的
        // 属性，框架一定保留）；找不到就插到 Siri 行之后，再找不到才追加到末尾。
        NSUInteger systemIndex = NSNotFound;
        for (NSUInteger index = 0; index < specifiers.count; index++) {
            PSSpecifier *spec = specifiers[index];
            if (![spec respondsToSelector:@selector(propertyForKey:)]) continue;
            if ([[spec propertyForKey:@"label"] isEqualToString:@"系统增强"]) {
                systemIndex = index;
                break;
            }
        }
        PSSpecifier *systemEntry = [self erSystemEnhanceEntrySpecifier];
        if (systemIndex != NSNotFound) {
            [specifiers replaceObjectAtIndex:systemIndex withObject:systemEntry];
        } else {
            NSUInteger siriIndex = NSNotFound;
            for (NSUInteger index = 0; index < specifiers.count; index++) {
                PSSpecifier *spec = specifiers[index];
                if (![spec respondsToSelector:@selector(propertyForKey:)]) continue;
                if ([[spec propertyForKey:@"label"] isEqualToString:@"Siri"]) {
                    siriIndex = index;
                    break;
                }
            }
            NSUInteger insertAt = (siriIndex != NSNotFound) ? siriIndex + 1 : specifiers.count;
            [specifiers insertObject:[PSSpecifier groupSpecifierWithName:nil] atIndex:insertAt++];
            [specifiers insertObject:systemEntry atIndex:insertAt];
        }

        // 1.0.4：页面底部居中的版本号页脚。
        //
        // 版本号**不写死**：ERVersionFooterText() 在运行期读本 bundle Info.plist 的
        // CFBundleShortVersionString，因此每次构建发布只需把版本号改在
        // control / Info.plist 这两处（本来就是必须改的），页面显示自动同步 ——
        // 需求里「每次构建发布新版本时同步更新该版本号」由构造方式保证，不靠人记。
        //
        // 之前没有任何版本号显示，且 assets/depiction.json 里还留着一个写死的
        // "Version: 1.0.0"（Sileo 详情页用的就是它）—— 这正是「版本号对不上」的来源。
        [specifiers addObject:[PSSpecifier groupSpecifierWithName:nil]];
        PSSpecifier *footer = [PSSpecifier preferenceSpecifierNamed:@""
                                                             target:nil
                                                                set:nil
                                                                get:nil
                                                             detail:nil
                                                               cell:PSStaticTextCell
                                                               edit:nil];
        Class footerCell = NSClassFromString(ERVersionFooterCellClassName);
        if (footerCell) [footer setProperty:footerCell forKey:@"cellClass"];
        [footer setProperty:ERVersionFooterText() forKey:ERVersionFooterTextKey];
        [specifiers addObject:footer];
        _specifiers = specifiers;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Enabled 的 specifier 已挪到「界面优化」子页；初值捕获是幂等的，这里照常调用
    //（本页没有该 specifier 时是空操作）。
    [self erStoreInitialMasterEnabled];
    self.navigationItem.rightBarButtonItem = nil;
    // 为带 erIcon/erIconColor 的 specifier 注入彩色圆角图标，并注册「回到前台重挂」
    // 的兜底（Preferences 回到前台会重建 specifier，iconImage 会丢）。
    [self erActivateIconRefresh];
    // 1.0.7-21（用户第 2 条）：根页「插件作者」距页顶空白过大 → 减半。
    // iOS 15 起分组表的 section header 上方默认多垫一段 sectionHeaderTopPadding
    // （首段之上尤其明显）。置 0 收掉这层，让首段贴向导航栏；只作用于本页表视图。
    if (@available(iOS 15.0, *)) {
        @try {
            UITableView *table = [self valueForKey:@"table"];
            if ([table isKindOfClass:[UITableView class]]) {
                table.sectionHeaderTopPadding = 0.0;
            }
        } @catch (__unused NSException *exception) {}
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 每次出现都重挂一次图标：push/pop 回到本页时 specifier 可能已被重建。
    [self erApplyIcons];
    [self erRefreshLogStatus];
}

// Pushed by hand rather than declared as a PSLinkCell in Root.plist. A link
// cell naming a controller that lives in this bundle has to survive the
// Preferences framework's cross-bundle class lookup, which is what produced
// both "There was an error loading the preference bundle" and a silently blank
// pane across several releases. This controller is already loaded and its
// navigation stack already exists, so pushing the editor directly removes that
// lookup from the path entirely.
- (void)openCategoryOrder:(__unused PSSpecifier *)specifier {
    ERCategoryOrderController *controller = [[ERCategoryOrderController alloc] init];
    if (!controller) return;
    [self.navigationController pushViewController:controller animated:YES];
}

// Same hand-push pattern as openCategoryOrder: — a link cell naming a
// controller in this bundle trips the Preferences cross-bundle class lookup,
// so the glass page is pushed directly instead (0.4.0, LiquidAss port).
- (void)openGlass:(__unused PSSpecifier *)specifier {
    ERGlassListController *controller = [[ERGlassListController alloc] init];
    if (!controller) return;
    controller.title = @"液态玻璃";
    [self.navigationController pushViewController:controller animated:YES];
}

// Shortcut manager. Pushed the same way, for the same reason as the other two:
// the pane reads the snapshot SpringBoard publishes, so it has to exist even
// when Control Center shows nothing at all.
- (void)openShortcuts:(__unused PSSpecifier *)specifier {
    ERShortcutController *controller = [[ERShortcutController alloc] init];
    if (!controller) return;
    // Set the title here as well as in -viewDidLoad. Both work, but the other
    // two panes set it at the push site, and doing it here means the
    // navigation bar is correct even if the pane's own -viewDidLoad is
    // deferred (the Preferences framework can push before the view loads).
    controller.title = @"快捷指令";
    [self.navigationController pushViewController:controller animated:YES];
}

// 「独立模块」子页（入口行仍叫「模块管理」）。Pushed the same way as the other
// three panes: a hand-push avoids the Preferences cross-bundle class lookup that
// made settings entries fail silently (0.5.6.21 "设置入口点不动"). The pane
// reads/writes the shared preference domain directly, so it never depends on that
// lookup either.
// 1.0.4：入口行文案是「模块管理」，子页标题回到「独立模块」；子页内顶部那行
// 分组文案改为「连接」（与这七项所属的控制中心分类同名）。
- (void)openModuleSettings:(__unused PSSpecifier *)specifier {
    ERModuleSettingsController *controller = [[ERModuleSettingsController alloc] init];
    if (!controller) return;
    controller.title = @"独立模块";
    [self.navigationController pushViewController:controller animated:YES];
}

// 增强设置子页：四个分区（控制中心分页 / 操作按钮 / 调节控件 / 震动反馈）
// 全部内联在该子页内，不各自再进入子页。同 hand-push 模式，绕开 Preferences
// 的跨 bundle 类查找失败。
- (void)openEnhancedSettings:(__unused PSSpecifier *)specifier {
    EREnhancedSettingsController *controller = [[EREnhancedSettingsController alloc] init];
    if (!controller) return;
    controller.title = @"增强设置";
    [self.navigationController pushViewController:controller animated:YES];
}

// 锁屏控制项（Soko）子页。同 hand-push 模式，绕开 Preferences 的跨 bundle
// 类查找失败；本页直接读写 SokoLayout 的偏好域，不依赖它自己的设置 bundle。
- (void)openSokoSettings:(__unused PSSpecifier *)specifier {
    ERSokoController *controller = [[ERSokoController alloc] init];
    if (!controller) return;
    controller.title = @"锁屏控制项";
    [self.navigationController pushViewController:controller animated:YES];
}

// 1.0.7-29：底部组件子页（音乐胶囊 + 后续新增的锁屏底部组件都在这页里）。
- (void)openBottomComponents:(__unused PSSpecifier *)specifier {
    ERBottomComponentsController *controller = [[ERBottomComponentsController alloc] init];
    if (!controller) return;
    controller.title = @"底部组件";
    [self.navigationController pushViewController:controller animated:YES];
}

// iOS27 Siri（LiquidSiri）子页。同上，直接读写 liquid patch 的偏好域。
- (void)openSiriSettings:(__unused PSSpecifier *)specifier {
    ERSiriController *controller = [[ERSiriController alloc] init];
    if (!controller) return;
    controller.title = @"iOS27 Siri";
    [self.navigationController pushViewController:controller animated:YES];
}

// 1.0.7-2：系统增强入口行的代码构造（见 -specifiers 里的说明）。
//
// 机制换成 detail 推入之后，这一行不再有 action —— 点一下由 Preferences 自己
// 实例化 detail 类并推入，是系统设置的原生路径。
- (PSSpecifier *)erSystemEnhanceEntrySpecifier {
    PSSpecifier *entry = [PSSpecifier preferenceSpecifierNamed:@"系统增强"
                                                        target:self
                                                           set:NULL
                                                           get:NULL
                                                        detail:ERSystemEnhanceController.class
                                                          cell:PSLinkCell
                                                        edit:Nil];
    [entry setProperty:ERImageIconWithFallbacks(@[@"gearshape.fill", @"gearshape", @"gear"],
                                                nil,
                                                @"系统",
                                                @"green")
                forKey:@"iconImage"];
    return entry;
}

// 1.0.7 · 子页 C · 系统增强。
//
// 1.0.7-2 起入口行走 **detail 推入**（Preferences 原生机制），框架自己实例化本类
// 并推入，不再经由本控制器的 action。为兼容框架可能使用的多种初始化入口，
// 这里把已知的两个都实现成转到 -init —— 本类是自包含的（bundle / plist / 标题
// 都自己解决），不依赖框架在那两个入口里做的任何额外装配。
- (instancetype)initForSpecifier:(__unused PSSpecifier *)specifier {
    return [self init];
}

- (instancetype)initWithSpecifier:(__unused PSSpecifier *)specifier {
    return [self init];
}

- (void)openSystemEnhance:(__unused PSSpecifier *)specifier {
    // 1.0.7-2：detail 推入生效后这条 action 不再被调用；保留它只是为了
    // 万一某些 iOS 版本对 link 行仍派发 action 时也能进（不会二次推入：
    // 先看栈顶是不是已经在本页上）。
    @try {
        if ([self.navigationController.topViewController isKindOfClass:[ERSystemEnhanceController class]]) return;
        ERSystemEnhanceController *controller = [[ERSystemEnhanceController alloc] init];
        if (!controller) return;
        controller.title = @"系统增强";
        [self.navigationController pushViewController:controller animated:YES];
    } @catch (NSException *exception) {
        ERPrefsLog(@"root: openSystemEnhance EXCEPTION %@ -- %@", exception.name, exception.reason);
    }
}

- (NSString *)erLogPath {
    return [kERLogDirectory stringByAppendingPathComponent:kERLogFileName];
}

- (unsigned long long)erLogSize {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[self erLogPath] error:nil];
    return attributes ? [attributes fileSize] : 0;
}

// Located through a marker property rather than the specifier's identifier,
// which is not exposed consistently across Preferences versions.
- (PSSpecifier *)erLogStatusSpecifier {
    for (PSSpecifier *specifier in self.specifiers) {
        if ([[specifier propertyForKey:@"erLogStatus"] boolValue]) return specifier;
    }
    return nil;
}

- (void)erRefreshLogStatus {
    PSSpecifier *specifier = [self erLogStatusSpecifier];
    if (!specifier) return;
    unsigned long long size = [self erLogSize];
    NSString *text;
    if (size == 0) {
        text = @"暂无";
    } else if (size < 1024) {
        text = [NSString stringWithFormat:@"%llu B", size];
    } else if (size < 1024 * 1024) {
        text = [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
    } else {
        text = [NSString stringWithFormat:@"%.2f MB", size / (1024.0 * 1024.0)];
    }
    // reloadSpecifier:animated: is private and absent from some header sets,
    // so reach it dynamically and fall back to a plain table reload.
    SEL setProperty = NSSelectorFromString(@"setProperty:forKey:");
    if ([specifier respondsToSelector:setProperty]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(specifier, setProperty, text, @"value");
    }
    SEL reload = NSSelectorFromString(@"reloadSpecifier:animated:");
    if ([self respondsToSelector:reload]) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(self, reload, specifier, NO);
    } else {
        [self.tableView reloadData];
    }
}

- (void)erPresentAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setLoggingEnabled:(id)value specifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];
    // Preferences are re-read through the notification; a respring is not
    // required for logging because the flag is checked on every write.
    [self erRefreshLogStatus];
}

- (void)exportLog:(__unused PSSpecifier *)specifier {
    NSString *source = [self erLogPath];
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:source] || [self erLogSize] == 0) {
        [self erPresentAlertWithTitle:@"没有可导出的日志" message:@"请先在上方开启「启用日志记录」，然后打开控制中心并复现问题，再回来导出。"];
        return;
    }
    [files createDirectoryAtPath:kERLogExportedDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *name = [NSString stringWithFormat:@"%@%@.txt", kERLogExportedPrefix, [formatter stringFromDate:[NSDate date]]];
    NSString *destination = [kERLogExportedDirectory stringByAppendingPathComponent:name];
    NSError *error = nil;
    [files removeItemAtPath:destination error:nil];
    if (![files copyItemAtPath:source toPath:destination error:&error]) {
        [self erPresentAlertWithTitle:@"导出失败" message:error.localizedDescription ?: @"无法写入日志副本。"];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:destination];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"日志已导出"
                                                                   message:[NSString stringWithFormat:@"已保存到：\n%@\n\n可在「文件」App 的「我的 iPhone」中找到，或直接通过下面的分享发送。", destination]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        activity.popoverPresentationController.sourceView = self.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
        [self presentViewController:activity animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearLog:(__unused PSSpecifier *)specifier {
    NSString *source = [self erLogPath];
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:source]) {
        [self erPresentAlertWithTitle:@"日志已为空" message:@"当前没有日志文件。"];
        return;
    }
    NSError *error = nil;
    if (![@"" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:&error] || error) {
        [self erPresentAlertWithTitle:@"清空失败" message:error.localizedDescription ?: @"未知错误"];
        return;
    }
    [self erRefreshLogStatus];
    [self erPresentAlertWithTitle:@"已清空" message:@"日志文件已清空。"];
}

@end
