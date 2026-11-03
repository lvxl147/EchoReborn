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
    } @catch (__unused NSException *e) {}
}

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
        ERSPLog(@"probe installed");
    } @catch (__unused NSException *e) {}
}
