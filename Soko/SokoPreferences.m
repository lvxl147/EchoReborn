#import "SokoPreferences.h"
#import <Foundation/Foundation.h>
#import <notify.h>

// 1.2.1-73 · 默认值改为上游 1.1.0 的语义：偏移 0 = 底部基准位。
// 旧 rc.3 移植用的是 -18 / +60（那是 Swift 版的补偿量），新模型下 0 才是"贴着
// 手电筒/相机中线"的正确位置，重置后必须回到 0。
static BOOL gERSokoWidgetsEnabled = YES;
static CGFloat gERSokoWidgetOffset = 0.0;
static BOOL gERSokoNotificationsEnabled = YES;
static CGFloat gERSokoNotificationOffset = 0.0;
static BOOL gERSokoQuickActionsEnabled = YES;
static CGFloat gERSokoQuickActionsIndent = 0.0;
static NSInteger gERSokoLoaded = 0;
static BOOL gERSokoWidgetOffsetIsSet = NO;

// 1.2.1-73 · 设置变更后的重排回调（SpringBoard 侧注册，用来立即重算组件行）。
static void (^gERSokoChangeHandler)(void) = nil;

static void SokoPreferencesReload(void) {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.strive.echoreborn.preferences"];

	// 1.2.1-73 · 关键修正：键不存在时必须**回落到默认值**，而不是保留上一次的缓存。
	// 旧实现是"键存在才覆盖"，于是设置页点重置（只删 key）后：
	//   设置页读不到值 → 显示回落默认（0），画面却仍是旧缓存（-120）→ 要拖一下滑块才变。
	id widgetOffset = [defaults objectForKey:@"soko_widgetOffset"];
	gERSokoWidgetOffsetIsSet = (widgetOffset != nil);
	gERSokoWidgetOffset = widgetOffset ? [defaults doubleForKey:@"soko_widgetOffset"] : 0.0;

	id notificationOffset = [defaults objectForKey:@"soko_notificationOffset"];
	gERSokoNotificationOffset = notificationOffset ? [defaults doubleForKey:@"soko_notificationOffset"] : 0.0;

	id widgetsEnabled = [defaults objectForKey:@"soko_widgetsEnabled"];
	gERSokoWidgetsEnabled = widgetsEnabled ? [defaults boolForKey:@"soko_widgetsEnabled"] : YES;

	id notificationsEnabled = [defaults objectForKey:@"soko_notificationsEnabled"];
	gERSokoNotificationsEnabled = notificationsEnabled ? [defaults boolForKey:@"soko_notificationsEnabled"] : YES;

	id quickEnabled = [defaults objectForKey:@"soko_quickActionsEnabled"];
	gERSokoQuickActionsEnabled = quickEnabled ? [defaults boolForKey:@"soko_quickActionsEnabled"] : YES;

	id quickIndent = [defaults objectForKey:@"soko_quickActionsIndent"];
	gERSokoQuickActionsIndent = quickIndent ? [defaults doubleForKey:@"soko_quickActionsIndent"] : 0.0;

	gERSokoLoaded = 1;
}

void SokoPreferencesSetChangeHandler(void (^handler)(void)) {
	gERSokoChangeHandler = [handler copy];

	// 设置页首次进入时可能是"改完之后进程才起"，注册即触发一次重排。
	if (gERSokoChangeHandler) {
		void (^run)(void) = gERSokoChangeHandler;
		dispatch_async(dispatch_get_main_queue(), ^{ if (run) run(); });
	}
}

__attribute__((constructor)) static void SokoPreferencesCtor(void) {
	SokoPreferencesReload();
	// 设置页改动实时生效（ERSokoController 发 com.strive.echoreborn/ReloadPrefs）
	int token = NOTIFY_TOKEN_INVALID;
	notify_register_dispatch("com.strive.echoreborn/ReloadPrefs", &token,
	                         dispatch_get_main_queue(), ^(int t) {
		SokoPreferencesReload();
		if (gERSokoChangeHandler) gERSokoChangeHandler();
	});
}

static void SokoPreferencesLoadIfNeeded(void) {
	if (!gERSokoLoaded) SokoPreferencesReload();
}

CGFloat SokoPrefWidgetOffset(void) {
	SokoPreferencesLoadIfNeeded();
	return gERSokoWidgetsEnabled ? gERSokoWidgetOffset : 0.0;
}
BOOL SokoPrefWidgetOffsetIsSet(void) {
	SokoPreferencesLoadIfNeeded();
	return gERSokoWidgetOffsetIsSet;
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
