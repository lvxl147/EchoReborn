#import "SokoPreferences.h"
#import <Foundation/Foundation.h>
#import <notify.h>

// rc.3 移植版默认值（与旧版 Preferences.swift 完全一致）
static BOOL gERSokoWidgetsEnabled = YES;
static CGFloat gERSokoWidgetOffset = -18.0;
static BOOL gERSokoNotificationsEnabled = YES;
static CGFloat gERSokoNotificationOffset = 60.0;
static BOOL gERSokoQuickActionsEnabled = YES;
static CGFloat gERSokoQuickActionsIndent = 0.0;
static NSInteger gERSokoLoaded = 0;

static void SokoPreferencesReload(void) {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.strive.echoreborn.preferences"];
	// 与旧版相同的「键存在才覆盖」语义：新键加入不重置用户已调的值
	if ([defaults objectForKey:@"soko_widgetsEnabled"] != nil) gERSokoWidgetsEnabled = [defaults boolForKey:@"soko_widgetsEnabled"];
	if ([defaults objectForKey:@"soko_widgetOffset"] != nil) gERSokoWidgetOffset = [defaults doubleForKey:@"soko_widgetOffset"];
	if ([defaults objectForKey:@"soko_notificationsEnabled"] != nil) gERSokoNotificationsEnabled = [defaults boolForKey:@"soko_notificationsEnabled"];
	if ([defaults objectForKey:@"soko_notificationOffset"] != nil) gERSokoNotificationOffset = [defaults doubleForKey:@"soko_notificationOffset"];
	if ([defaults objectForKey:@"soko_quickActionsEnabled"] != nil) gERSokoQuickActionsEnabled = [defaults boolForKey:@"soko_quickActionsEnabled"];
	if ([defaults objectForKey:@"soko_quickActionsIndent"] != nil) gERSokoQuickActionsIndent = [defaults doubleForKey:@"soko_quickActionsIndent"];
	gERSokoLoaded = 1;
}

__attribute__((constructor)) static void SokoPreferencesCtor(void) {
	SokoPreferencesReload();
	// 设置页改动实时生效（ERSokoController 发 com.strive.echoreborn/ReloadPrefs）
	int token = NOTIFY_TOKEN_INVALID;
	notify_register_dispatch("com.strive.echoreborn/ReloadPrefs", &token,
	                         dispatch_get_main_queue(), ^(int t) { SokoPreferencesReload(); });
}

static void SokoPreferencesLoadIfNeeded(void) {
	if (!gERSokoLoaded) SokoPreferencesReload();
}

CGFloat SokoPrefWidgetOffset(void) {
	SokoPreferencesLoadIfNeeded();
	return gERSokoWidgetsEnabled ? gERSokoWidgetOffset : 0.0;
}
CGFloat SokoPrefNotificationOffset(void) {
	SokoPreferencesLoadIfNeeded();
	return gERSokoNotificationsEnabled ? gERSokoNotificationOffset : 0.0;
}
BOOL SokoPrefQuickActionsEnabled(void) {
	SokoPreferencesLoadIfNeeded();
	return gERSokoQuickActionsEnabled;
}
CGFloat SokoPrefQuickActionsIndent(void) {
	SokoPreferencesLoadIfNeeded();
	return gERSokoQuickActionsEnabled ? gERSokoQuickActionsIndent : 0.0;
}
