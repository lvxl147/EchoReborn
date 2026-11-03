#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 1.2.2-147 · 独立设置进程探针（只读，无任何业务 hook）：
// 记录「设置 → 控制中心」页的列表控制器类名，为隐藏快捷指令 1-32 定位。
static void ERSPLog(NSString *line) {
    @try {
        NSString *domain = @"com.strive.echoreborn.preferences";
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        NSMutableArray *lines = [(__bridge_transfer NSArray *)CFPreferencesCopyAppValue(CFSTR("ERSettingsProbe"), (__bridge CFStringRef)domain) mutableCopy] ?: [NSMutableArray array];
        [lines addObject:[NSString stringWithFormat:@"%@ | %@", [NSDate date].description, line]];
        while (lines.count > 60) [lines removeObjectAtIndex:0];
        CFPreferencesSetAppValue(CFSTR("ERSettingsProbe"), (__bridge CFPropertyListRef)lines, (__bridge CFStringRef)domain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    } @catch (__unused NSException *e) {}
}

static IMP erSPOrigViewDidAppear = NULL;
static void erSPViewDidAppear(id self, SEL cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))erSPOrigViewDidAppear)(self, cmd, animated);
    @try {
        NSString *cls = NSStringFromClass([self class]);
        if ([cls containsString:@"ControlCenter"] || [cls containsString:@"CCUI"]) {
            ERSPLog([NSString stringWithFormat:@"VC-appear %@", cls]);
        }
        // 1.2.2-149 · 深挖：CCUISettingsListController 的结构与数据机制
        if ([cls isEqualToString:@"CCUISettingsListController"]) {
            @try {
                NSMutableString *chain = [NSMutableString string];
                Class walker = [self class];
                for (int depth = 0; depth < 5 && walker; depth++) {
                    [chain appendFormat:@"%@ <- ", NSStringFromClass(walker)];
                    walker = class_getSuperclass(walker);
                }
                ERSPLog([NSString stringWithFormat:@"chain %@", chain]);
                ERSPLog([NSString stringWithFormat:@"responds specifiers=%d tableViewDS=%d",
                        (int)[self respondsToSelector:@selector(specifiers)],
                        (int)[self conformsToProtocol:@protocol(UITableViewDataSource)]]);
                if ([self respondsToSelector:@selector(specifiers)]) {
                    NSArray *specs = [self performSelector:@selector(specifiers)];
                    ERSPLog([NSString stringWithFormat:@"specifier count %lu",
                             (unsigned long)(specs ? specs.count : 0)]);
                    if (specs.count) {
                        for (NSUInteger i = 0; i < 3 && i < specs.count; i++) {
                            id spec = specs[i];
                            NSString *name = [spec respondsToSelector:@selector(name)]
                                ? [NSString stringWithFormat:@"%@", [spec performSelector:@selector(name)]] : @"-";
                            ERSPLog([NSString stringWithFormat:@"spec %lu name=%@ cls=%@",
                                     (unsigned long)i, name, NSStringFromClass(object_getClass(spec))]);
                        }
                    }
                }
                id tableView = nil;
                if ([self isKindOfClass:[UIViewController class]]) {
                    for (UIView *sub in ((UIViewController *)self).view.subviews) {
                        if ([sub isKindOfClass:[UITableView class]]) { tableView = sub; break; }
                    }
                }
                ERSPLog([NSString stringWithFormat:@"table=%@ sections=%ld",
                        tableView ? NSStringFromClass(object_getClass(tableView)) : @"nil",
                        tableView ? (long)[(UITableView *)tableView numberOfSections] : -1]);
            } @catch (__unused NSException *e) {
                ERSPLog(@"deep probe exception");
            }
        }
    } @catch (__unused NSException *e) {}
}

static void ERSPInstallShortcutFilter(void);

__attribute__((constructor))
static void ERSettingsProbeEntry(void) {
    @try {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"Preferences"]) return;
        Class vcClass = objc_getClass("UIViewController");
        if (vcClass) {
            Method m = class_getInstanceMethod(vcClass, @selector(viewDidAppear:));
            if (m) erSPOrigViewDidAppear = method_setImplementation(m, (IMP)erSPViewDidAppear);
        }
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        NSMutableString *found = [NSMutableString string];
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if ([name containsString:@"ControlCenter"] &&
                ([name containsString:@"List"] || [name containsString:@"Settings"] || [name containsString:@"Pane"])) {
                [found appendFormat:@"%@ ", name];
            }
        }
        if (classes) free(classes);
        ERSPLog([NSString stringWithFormat:@"classes: %@", found]);
        ERSPInstallShortcutFilter();
        ERSPLog(@"probe installed");
    } @catch (__unused NSException *e) {}
}

// ---------------------------------------------------------------------------
// 1.2.2-148 · 第二步：在 CCUISettingsListController 上过滤「快捷指令 N」行。
// 只影响官方设置页的显示；模块注册、CC 添加流程（SpringBoard 侧）零改动。
// 用 class_addMethod 在子类上挂覆盖，避免改到父类 PSListController 的全局行为。
// ---------------------------------------------------------------------------
static NSArray *(*erSPOrigSpecifiers)(id, SEL) = NULL;

static BOOL ERSPIsShortcutSlotSpecifier(id specifier) {
    @try {
        NSString *label = nil;
        if ([specifier respondsToSelector:@selector(name)]) label = [specifier performSelector:@selector(name)];
        if (![label isKindOfClass:[NSString class]] || !label.length) {
            if ([specifier respondsToSelector:@selector(propertyForKey:)])
                label = [specifier performSelector:@selector(propertyForKey:) withObject:@"label"];
        }
        if ([label isKindOfClass:[NSString class]]) {
            NSString *trimmed = [label stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([trimmed hasPrefix:@"快捷指令"]) {
                NSString *suffix = [trimmed substringFromIndex:[trimmed rangeOfString:@"快捷指令"].location + @"快捷指令".length];
                suffix = [suffix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (suffix.length >= 1 && suffix.length <= 2) {
                    for (NSUInteger i = 0; i < suffix.length; i++) {
                        unichar ch = [suffix characterAtIndex:i];
                        if (ch < '0' || ch > '9') return NO;
                    }
                    return YES;
                }
            }
        }
        NSString *identifier = nil;
        if ([specifier respondsToSelector:@selector(identifier)])
            identifier = [specifier performSelector:@selector(identifier)];
        if ([identifier isKindOfClass:[NSString class]] &&
            [identifier.lowercaseString containsString:@"echoreborn.shortcut"]) return YES;
        return NO;
    } @catch (__unused NSException *e) { return NO; }
}

static NSArray *erSPNewSpecifiers(id self, SEL cmd) {
    NSArray *specifiers = ((NSArray *(*)(id, SEL))erSPOrigSpecifiers)(self, cmd);
    if (![specifiers isKindOfClass:[NSArray class]] || specifiers.count == 0) return specifiers;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:specifiers.count];
    NSUInteger removed = 0;
    for (id specifier in specifiers) {
        if (ERSPIsShortcutSlotSpecifier(specifier)) { removed++; continue; }
        [filtered addObject:specifier];
    }
    if (removed > 0) {
        static NSInteger loggedOnce = -1;
        if (loggedOnce != (NSInteger)removed) {
            loggedOnce = (NSInteger)removed;
            ERSPLog([NSString stringWithFormat:@"shortcut rows hidden: %lu of %lu",
                     (unsigned long)removed, (unsigned long)specifiers.count]);
        }
    }
    return filtered;
}

static void ERSPInstallShortcutFilter(void) {
    @try {
        Class listClass = objc_getClass("CCUISettingsListController");
        if (!listClass) { ERSPLog(@"shortcut filter: CCUISettingsListController missing"); return; }
        SEL sel = @selector(specifiers);
        Method superMethod = class_getInstanceMethod(listClass, sel);
        if (!superMethod) { ERSPLog(@"shortcut filter: specifiers method missing"); return; }
        erSPOrigSpecifiers = (NSArray *(*)(id, SEL))method_getImplementation(superMethod);
        if (!class_addMethod(listClass, sel, (IMP)erSPNewSpecifiers, method_getTypeEncoding(superMethod))) {
            // 已有同名实现（不应发生），直接替换
            method_setImplementation(superMethod, (IMP)erSPNewSpecifiers);
        }
        ERSPLog(@"shortcut filter installed");
    } @catch (__unused NSException *e) {}
}
