#import "Soko.h"
#import "SokoPreferences.h"
#import "SokoLog.h"
#import "SokoFileLog.h"
#import <notify.h>

// 1.2.1-73 · 海报进程（PosterBoard / PosterKit / MercuryPoster）写不进宿主偏好域，
// 也没有可写的日志目录，所以用一条 Darwin 通知"报到"，由 SpringBoard 侧落盘 ——
// 这是判断"我们的 dylib 到底有没有注入到编辑器进程"的唯一可靠信号。
static NSString *SokoHelloNameForBundleIdentifier(NSString *bundleIdentifier) {
	if ([bundleIdentifier isEqualToString:@"com.apple.PosterBoard"]) return @"com.strive.echoreborn.soko.hello.posterboard";
	if ([bundleIdentifier isEqualToString:@"com.apple.PosterKit"]) return @"com.strive.echoreborn.soko.hello.posterkit";
	return @"com.strive.echoreborn.soko.hello.mercuryposter";
}

// 1.2.1-94 · 每张壁纸独立保存：
//   键取 PRSPosterConfiguration 的 _path 末段（无则退回 provider 描述），
//   值存在 prefs 的 soko_offsets_by_poster 字典里，切壁纸时读该壁纸自己的值。
static NSString *gActivePosterKey = nil;

// 1.2.1-115 · 前向声明（容器 viewDidLoad 在定义之前就要调它）
static void SokoInitEditorRoot(void);
// 1.2.1-104 · 编辑会话基线（进编辑器那一刻的生效偏移），取消时回滚到它
static NSNumber *gEditBaselineOffset;
// 1.2.1-105 · 刚提交的待定值 + 是否在等"存没存"的判定
// 1.2.1-105 · 上一次读到的归档值。只有它变化才说明"系统刚保存了一份新 layout"。
static NSNumber *gLastArchiveValue;



// 1.2.1-103 · 去掉键尾的版本号（_98-0 / /98-0）。
//   实测 `stablePersistenceIdentifier` 是
//   `…_CreateAFacePhotos(EEAE4B4F-…)_PRPosterRoleLockScreen_98-0`，
//   **每次保存壁纸版本号都会 +1**（日志里 95-0 → 96-0 → … → 99-0；换成
//   identityPathComponent 后又变成 .../versions/99 → 100 → 101），
//   于是同一张壁纸每编辑一次就换一个新键 → POSTER-SEED 而不是 POSTER-RESTORE
//   → 表现就是"改完再进，值丢了"。这才是"每壁纸保存不正常"的最后一环。
static NSString *SokoCanonicalPosterKey(NSString *key) {
	static NSRegularExpression *expression;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		expression = [NSRegularExpression regularExpressionWithPattern:@"(_[0-9]+-[0-9]+|/versions/[0-9]+|/[0-9]+-[0-9]+)$" options:0 error:nil];
	});
	if (![key isKindOfClass:[NSString class]] || !key.length || !expression) return key;
	return [expression stringByReplacingMatchesInString:key options:0 range:NSMakeRange(0, key.length) withTemplate:@""];
}

// 1.2.1-101 · **这就是"每壁纸保存从不生效"的真凶**（1.2.1-100 的 POSTER-PROBE 实锤）：
//   `_path=<PRSServerPosterPath:0x2829e8380 com.apple.PhotosUIPrivate.P…`
//   —— _path 根本不是 NSString，而是 PRSServerPosterPath **对象**，
//   于是 `isKindOfClass:[NSString class]` 恒为 NO，退回 provider（N/A），最终返回 nil。
//   gActivePosterKey 一整轮都是 nil → soko_offsets_by_poster 永远写不进去。
// 现在：用 _path 对象的 description，剔除 0x 内存地址后当键（同一张壁纸稳定）。
static NSString *SokoStripAddresses(NSString *text) {
	static NSRegularExpression *expression;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		expression = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-fA-F]+" options:0 error:nil];
	});
	if (!text.length || !expression) return text;
	return [expression stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
}

// 1.2.1-101 · 类结构探针：把对象自身（含父类）的属性逐个读一遍并落盘。
// 用来给"壁纸身份"找一个真正稳定且唯一的键（PRSServerPosterPath 上大概率有 UUID）。
static void SokoDumpObjectShape(id object, NSString *label, NSUInteger limit) {
	if (!object) return;

	NSMutableString *log = [NSMutableString stringWithFormat:@"%@ cls=%@",
	                        label, NSStringFromClass([object class])];
	NSUInteger emitted = 0;
	for (Class cls = [object class]; cls && cls != [NSObject class] && emitted < 30; cls = [cls superclass]) {
		unsigned int count = 0;
		objc_property_t *properties = class_copyPropertyList(cls, &count);
		for (unsigned int i = 0; i < count && emitted < 30; i++) {
			const char *rawName = property_getName(properties[i]);
			if (!rawName) continue;
			NSString *name = @(rawName);
			if (![object respondsToSelector:NSSelectorFromString(name)]) continue;

			id value = nil;
			@try { value = [object valueForKey:name]; } @catch (__unused NSException *e) {}
			NSString *described = [value description] ?: @"(nil)";
			if (described.length > limit) described = [[described substringToIndex:limit] stringByAppendingString:@"…"];
			[log appendFormat:@" | %@=%@", name, described];
			emitted++;
		}
		if (properties) free(properties);
	}
	SokoFileLog(@"%@", log);
}

static NSString *SokoPosterKeyForConfiguration(id configuration) {
	if (!configuration) return nil;

	static BOOL probed = NO;
	if (!probed) {
		probed = YES;
		SokoDumpObjectShape(configuration, @"POSTER-SHAPE", 24);
		id pathObject = nil;
		@try { pathObject = [configuration valueForKey:@"_path"]; } @catch (__unused NSException *e) {}
		SokoDumpObjectShape(pathObject, @"POSTER-PATH-SHAPE", 80);
	}

	NSString *key = nil;
	id pathObject = nil;
	@try { pathObject = [configuration valueForKey:@"_path"]; } @catch (__unused NSException *e) {}

	// 1.2.1-102 · POSTER-PATH-SHAPE 给出的正解：PRSServerPosterPath 上有
	//   `stablePersistenceIdentifier`（名字就是"稳定持久标识"，不含版本号后缀），
	//   其次是 `identityPathComponent`。两者都比 description 干净且跨编辑稳定。
	// identityPathComponent = <provider>/configurations/<UUID>，本身不带版本号，优先用
	for (NSString *keyName in @[@"identityPathComponent", @"stablePersistenceIdentifier", @"serverIdentity"]) {
		if (![pathObject respondsToSelector:NSSelectorFromString(keyName)]) continue;
		id value = nil;
		@try { value = [pathObject valueForKey:keyName]; } @catch (__unused NSException *e) {}
		if ([value isKindOfClass:[NSString class]] && [value length]) { key = value; break; }
		if ([value isKindOfClass:[NSURL class]]) { key = [(NSURL *)value path]; break; }
	}

	if (key.length) return SokoCanonicalPosterKey(key);

	if ([pathObject isKindOfClass:[NSString class]]) {
		key = [pathObject lastPathComponent];
	} else if ([pathObject isKindOfClass:[NSURL class]]) {
		key = [[(NSURL *)pathObject path] lastPathComponent];
	} else if (pathObject) {
		key = SokoStripAddresses([pathObject description] ?: @"");
	} else {
		id provider = nil;
		@try { provider = [configuration valueForKey:@"provider"]; } @catch (__unused NSException *e) {}
		key = SokoStripAddresses([provider description] ?: @"");
	}

	if (![key isKindOfClass:[NSString class]] || !key.length) return nil;
	return SokoCanonicalPosterKey(key);
}

static NSMutableDictionary *SokoPosterOffsetMap(void) {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.strive.echoreborn.preferences"];
	NSDictionary *stored = [defaults dictionaryForKey:@"soko_offsets_by_poster"];
	NSMutableDictionary *map = [NSMutableDictionary dictionary];
	// 读的时候就把旧键（含版本号的历史条目）归一化合并，顺手清理脏数据
	for (id rawKey in stored) {
		if (![rawKey isKindOfClass:[NSString class]]) continue;
		map[SokoCanonicalPosterKey(rawKey)] = stored[rawKey];
	}
	return map;
}


static BOOL gActivePosterUsesBottomLayout;
static __weak CSCoverSheetViewController *gCoverSheetViewController;

static SokoDockCoordinator *SokoCoordinator(void) {
	CSCoverSheetViewController *coverSheet = gCoverSheetViewController;
	return coverSheet.isViewLoaded ? [SokoDockCoordinator coordinatorForCoverSheetViewController:coverSheet] : nil;
}

static void SokoSetActivePosterUsesBottomLayout(BOOL usesBottomLayout) {
	SokoDockPublishActiveUsesBottomLayout(usesBottomLayout);
	if (usesBottomLayout == gActivePosterUsesBottomLayout) return;

	gActivePosterUsesBottomLayout = usesBottomLayout;
	[SokoCoordinator() setEnabled:usesBottomLayout];
}

static void SokoRefreshDockSoon(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		[SokoCoordinator() refresh];
	});
}

static void SokoPost(NSString *name, id object) {
	[[NSNotificationCenter defaultCenter] postNotificationName:name object:object];
}

static BOOL SokoMoveFooter(UIView *footer, UIView *listView, CGFloat *movedCenterY) {
	SokoNotificationList *notificationList = [SokoDockCoordinator activeCoordinator].notificationList;
	CGFloat centerY;
	if (!footer || ![notificationList getFooterCenterY:&centerY forListView:listView]) return NO;

	CGFloat scale = listView.traitCollection.displayScale ?: 1.0;
	CGFloat height = CGRectGetHeight(footer.bounds);
	CGFloat minY = round((centerY - height / 2.0) * scale) / scale;

	[UIView performWithoutAnimation:^{
		footer.center = CGPointMake(footer.center.x, minY + height / 2.0);
	}];

	if (movedCenterY) *movedCenterY = minY + height / 2.0;
	return YES;
}

static UIEdgeInsets SokoAdjustedFooterInsets(UIEdgeInsets insets, CSCombinedListViewController *combinedListViewController) {
	SokoNotificationList *notificationList = [SokoDockCoordinator activeCoordinator].notificationList;
	if (!notificationList) return insets;

	return [notificationList footerInsetsByAdjustingInsets:insets forCombinedListViewController:combinedListViewController];
}

static BOOL SokoAllowsAddGestureOverRow(BOOL (^orig)(void)) {
	[SokoPosterLayout setIgnoringGraphicComplications:YES];
	BOOL allowed = orig();
	[SokoPosterLayout setIgnoringGraphicComplications:NO];

	return allowed;
}

// 1.2.1-105 · 统一写偏好（soko_widgetOffset + 当前壁纸的独立记录）并立即生效
static void SokoWriteOffsetToPrefs(CGFloat value, NSString *why) {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.strive.echoreborn.preferences"];
	[defaults setDouble:value forKey:@"soko_widgetOffset"];
	if (gActivePosterKey) {
		NSMutableDictionary *map = SokoPosterOffsetMap();
		map[gActivePosterKey] = @(value);
		[defaults setObject:map forKey:@"soko_offsets_by_poster"];
	}
	[defaults synchronize];
	[SokoDockCoordinator setActiveRowOffset:@(value)];
	SokoDockCoordinator *coordinator = SokoCoordinator();
	[coordinator setEnabled:YES];
	[coordinator refresh];
	notify_post("com.strive.echoreborn/ReloadPrefs");
	if (why) SokoFileLog(@"%@ %.1f", why, value);
}

%group SokoDock

%hook CSCoverSheetViewController

- (void)viewDidLoad {
	%orig;

	gCoverSheetViewController = self;
	[[SokoDockCoordinator coordinatorForCoverSheetViewController:self] setEnabled:gActivePosterUsesBottomLayout];
}

- (void)_updateComplicationsContainerView {
	%orig;

	[[SokoDockCoordinator coordinatorForCoverSheetView:self.viewIfLoaded].notificationList updateLayout];
}

- (double)listMinY {
	double listMinY = %orig;

	SokoNotificationList *notificationList = [SokoDockCoordinator coordinatorForCoverSheetView:self.viewIfLoaded].notificationList;
	return notificationList ? [notificationList listMinYByAdjustingListMinY:listMinY] : listMinY;
}

%end

%hook CSCoverSheetView

- (void)layoutSubviews {
	%orig;

	[[SokoDockCoordinator coordinatorForCoverSheetView:self] coverSheetViewDidLayout];

	// 1.2.1-68 · 这里原本还有一段 qa.transform = translate(indent, 0) 的横向缩进。
	// 它和 Tweak.xm 的 ERQuickActionsApplyButton（改 center，1.0.9-170/172/173 三轮
	// 现场日志实证 transform 会被 CSQuickActionsView 的布局吞掉）叠加 = 双倍位移。
	// 横向缩进唯一实现放在 Tweak.xm，本文件不再插手。
}

- (void)_layoutDateView {
	%orig;

	[[SokoDockCoordinator coordinatorForCoverSheetView:self] coverSheetViewDidLayout];
}

%end

%hook CSComplicationManager

- (void)_updateComplicationsForActivePosterConfiguration {
	%orig;

	PRSWallpaperObserverState *state = SokoIvarObject(self, "_wallpaperState");
	PRSPosterConfiguration *configuration = [state respondsToSelector:@selector(activeLock)] ? state.activeLock : nil;
	[SokoPosterModel applyPendingDefaultLayoutToConfiguration:configuration];

	// 1.2.1-99 · 每壁纸独立保存（这次是真的落盘了）。
	//   之前 soko_offsets_by_poster 恒为 None：唯一写它的地方是 EDITOR-SETOFFSET
	//   （依赖 SokoEditorRequestRowOffset），而调用点被 SokoTrace 的 32 码上限挡住，
	//   一次都没跑过。现在：
	//     · 有记录 → 读出来写进 soko_widgetOffset（设置页滑块跟到这张壁纸的值）
	//     · 无记录 → 用当前滑块值做种子（之后这张壁纸就独立记自己的）
	NSString *posterKey = SokoPosterKeyForConfiguration(configuration);
	if (posterKey && ![posterKey isEqualToString:gActivePosterKey]) {
		SokoFileLog(@"POSTER-KEY %@ -> %@", gActivePosterKey ?: @"(nil)", posterKey);
	}
	if (posterKey) {
		gActivePosterKey = posterKey;
		NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.strive.echoreborn.preferences"];
		NSMutableDictionary *map = SokoPosterOffsetMap();
		NSNumber *stored = map[posterKey];
		double current = [defaults doubleForKey:@"soko_widgetOffset"];
		if (stored) {
			if (fabs(current - stored.doubleValue) > 0.5) {
				[defaults setDouble:stored.doubleValue forKey:@"soko_widgetOffset"];
				[defaults synchronize];
				notify_post("com.strive.echoreborn/ReloadPrefs");
				SokoFileLog(@"POSTER-RESTORE %@ = %.1f (was %.1f)", posterKey, stored.doubleValue, current);
			}
		} else {
			map[posterKey] = @(current);
			[defaults setObject:map forKey:@"soko_offsets_by_poster"];
			[defaults synchronize];
			SokoFileLog(@"POSTER-SEED %@ = %.1f", posterKey, current);
		}
	}

	BOOL usesBottomLayout;
	NSDictionary *liquidAssInfo = SokoLiquidAssUserInfoForConfiguration(configuration);
	NSNumber *archiveOffset = nil;
	if (SokoLiquidAssClockEnabled() && SokoLiquidAssUserInfoIsActive(liquidAssInfo)) {
		usesBottomLayout = SokoLiquidAssUserInfoUsesBottomLayout(liquidAssInfo);
	} else {
		id layout = nil;
		if ([configuration respondsToSelector:@selector(pr_loadComplicationLayoutWithError:)]) {
			layout = [configuration pr_loadComplicationLayoutWithError:nil];
		}

		// 1.2.1-99 · 归档值只留作证据，**不再回流到滑块**。
		//   这条回流（ARCHIVE-MIRROR）就是"时好时坏"的元凶：归档里残留着上一次
		//   编辑会话的 -507 / 0，每次锁屏布局都把滑块顶掉，于是 eff 在
		//   -431.7 → 0 → -507 → 0 之间跳。真源现在是 soko_offsets_by_poster。
		archiveOffset = [SokoPosterModel rowOffsetForComplicationLayout:layout];
		usesBottomLayout = [SokoPosterModel complicationLayoutUsesBottomLayout:layout];
	}

	// 1.2.1-105 · **回到原版 Soko 的机制**：归档变化 = 系统真的保存了 = "完成"。
	//
	//   上游 Soko 里根本没有"完成/取消"这两个概念 —— 它只是把值写进 layout 归档
	//   （encodeComplicationLayout 里 encode 一个 BOOL），靠"系统保存才落盘、
	//   取消就丢弃"由系统自己保证语义。我们之前为了"编辑器里能看见移动"而
	//   在滑动时立刻写偏好，等于绕过了这套机制 → 取消也保存。
	//
	//   现在：滑动只改会话值（编辑器内可见），落盘完全交给系统；
	//   SpringBoard 只在"读到的归档值发生了变化"时才写偏好 + 每壁纸记录。
	//   取消 → 归档不变 → 偏好不动 ✅
	//   完成 → 归档变 → 写偏好 ✅
	//   只拖滑块 → 归档不变 → 不会被归档顶回去 ✅（这正是 1.2.1-83 那个 bug）
	if (archiveOffset) {
		double archived = archiveOffset.doubleValue;
		if (gLastArchiveValue == nil) {
			gLastArchiveValue = @(archived);   // 首次只记基线，不写偏好
			SokoFileLog(@"ARCHIVE-BASELINE v=%.1f", archived);
		} else if (fabs(gLastArchiveValue.doubleValue - archived) > 0.5) {
			gLastArchiveValue = @(archived);
			SokoWriteOffsetToPrefs(archived, @"ARCHIVE-COMMIT");
			SokoTrace(25, 1);
		} else {
			SokoFileLog(@"ARCHIVE-READ v=%.1f (未变化，不写偏好)", archived);
		}
	}

	// 1.2.1-83 · 滑块是唯一渲染来源；"调整组件位置"关闭则整段不接管。
	if (!SokoPrefWidgetsEnabled()) usesBottomLayout = NO;
	if (SokoPrefWidgetOffsetIsSet() && SokoPrefWidgetsEnabled()) usesBottomLayout = YES;
	dispatch_async(dispatch_get_main_queue(), ^{
		SokoSetActivePosterUsesBottomLayout(usesBottomLayout);
	});
}

%end

%hook CSProminentDisplayViewController

- (void)_updateViewColors {
	%orig;

	SokoPost(SokoProminentDisplayVibrancyDidChangeNotification, self);
}

- (void)setVibrancyContentType:(long long)contentType {
	%orig;

	SokoPost(SokoProminentDisplayVibrancyDidChangeNotification, self);
}

- (void)interactiveTransition:(id)transition didUpdate:(double)progress {
	%orig;

	SokoPost(SokoProminentDisplayVibrancyDidChangeNotification, self);
}

- (void)setContentAlpha:(double)alpha forElements:(unsigned long long)elements {
	%orig;

	if (elements & kSokoComplicationRowElement) SokoPost(SokoProminentDisplayContentAlphaDidChangeNotification, self);
}

%end

%end

%group SokoDockListFooter

%hook NCNotificationListView

- (void)_layoutOverlayFooterViewIfNecessary {
	%orig;

	SokoMoveFooter(self.overlayFooterView, self, NULL);
}

%end

%end

%group SokoDockContainerFooter

%hook NCNotificationStructuredListView

- (void)layoutSubviews {
	%orig;

	CGFloat centerY;
	if (!SokoMoveFooter(self.footerView, self, &centerY)) return;

	id<NCNotificationStructuredListViewDelegate> delegate = self.delegate;
	if ([delegate respondsToSelector:@selector(notificationStructuredListView:didChangeFooterCenterY:)]) {
		[delegate notificationStructuredListView:self didChangeFooterCenterY:centerY];
	}
}

%end

%end

%group SokoDockWidgetDescriptors

%hook CSComplicationContainerViewController

- (void)setWidgetDescriptors:(NSArray *)widgetDescriptors {
	%orig;

	SokoRefreshDockSoon();
}

%end

%end

%group SokoDockWidgetGrid

%hook CSWidgetGridViewController

- (void)setComplicationDescriptors:(NSArray *)complicationDescriptors iconLayout:(id)iconLayout {
	%orig;

	SokoRefreshDockSoon();
}

%end

%end

%group SokoDockFooterInsets

%hook CSCombinedListViewController

- (UIEdgeInsets)notificationStructuredListViewControllerRequestsEdgeInsetsForOverlayFooterView:(id)structuredListViewController {
	UIEdgeInsets insets = %orig;

	return SokoAdjustedFooterInsets(insets, self);
}

%end

%end

%group SokoDockFooterInsetsForOrientation

%hook CSCombinedListViewController

- (UIEdgeInsets)notificationStructuredListViewControllerRequestsEdgeInsetsForOverlayFooterView:(id)structuredListViewController forOrientation:(long long)orientation {
	UIEdgeInsets insets = %orig;

	return SokoAdjustedFooterInsets(insets, self);
}

%end

%end

%group SokoPoster

%hook CSProminentLayoutController

- (CGRect)_frameForElement:(unsigned long long)element withBoundingRect:(CGRect)rect variant:(unsigned long long)variant {
	CGRect frame = %orig;

	return [SokoPosterLayout frameByAdjustingFrame:frame forElement:element boundingRect:rect variant:variant layoutController:self];
}

- (CGRect)complicationRowElementEditingReticleFrameWithBoundingRect:(CGRect)rect {
	CGRect frame = %orig;

	return [SokoPosterLayout reticleFrameByAdjustingFrame:frame layoutController:self boundingRect:rect];
}

%end

%hook PRComplicationContainerViewController

- (void)viewDidLoad {
	%orig;

	// 1.2.1-69 · 编辑态拖动链路的第一个节点：容器 VC 有没有被登记
	SokoFileLog(@"CONTAINER viewDidLoad proc=%@", NSProcessInfo.processInfo.processName);
	// code 3：容器 VC 登记
	SokoTrace(3, 1);
	// 1.2.1-115 · 编辑器打开的必然时机，此刻 PREditorRootViewController 一定已加载
	SokoInitEditorRoot();
	[SokoPosterLayout registerComplicationContainerViewController:self];
	[SokoLayoutSwipeHandler installOnComplicationContainerViewController:self];
}

- (void)viewDidLayoutSubviews {
	%orig;

	// 1.2.1-110 · 系统每次布局都会把虚线框摆回原位，必须布局完立刻再平移一次
	[SokoEditorChrome reapplyReticleTransform];
}

%end

%hook PREditingSceneViewController

- (instancetype)initWithProvider:(id)provider contents:(id)contents configurableOptions:(id)configurableOptions configuredProperties:(PRPosterConfiguredProperties *)configuredProperties additionalInfo:(id)additionalInfo {
	self = %orig;

	if (self) {
		[SokoPosterLayout setInitialComplicationLayout:configuredProperties.complicationLayout forEditingSceneViewController:self];
		[SokoPosterLayout setInitialRowOffset:[SokoPosterModel rowOffsetForComplicationLayout:configuredProperties.complicationLayout] forEditingSceneViewController:self];
	}
	return self;
}

- (void)viewWillDisappear:(BOOL)animated {
	%orig;

	SokoTrace(29, (long)[SokoPosterLayout editingRowOffset]);   // 29 = 编辑场景消失时的会话值
}

- (void)viewDidDisappear:(BOOL)animated {
	%orig;

	// 1.2.1-105 · 编辑器关闭 → 通知 SpringBoard 做"到底存没存"的判定。
	//   这是取消回滚的触发点：滑动必须立即提交（否则编辑器里看不到移动），
	//   所以"取消"只能靠关闭后回退到基线。
	SokoEditorRequestClosed();
	SokoTrace(30, 1);
	// 1.2.1-99 · 会话收尾：编辑器完全消失 3 秒后清掉会话值，避免残留值被之后
	// 任何一次 setComplicationLayout:（与本次编辑无关的）当成"完成"提交出去。
	// 3 秒是因为"完成"路径的 setComplicationLayout: 可能在消失过程中稍晚才到。
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		if ([SokoPosterLayout editingRowOffsetDirty]) {
			SokoFileLog(@"EDITOR-SESSION-CLEAR");
			[SokoPosterLayout clearEditingSession];
		}
	});
}

- (void)viewDidLoad {
	%orig;

	BOOL registered = [SokoPosterLayout registerEditingSceneViewController:self];
	SokoFileLog(@"EDITOR viewDidLoad registered=%d role=%@",
	            (int)registered,
	            [self respondsToSelector:@selector(posterRole)] ? self.posterRole : @"(none)");
	// code 4：编辑器登记成功（1）/失败（0）；失败时 role 见 payload 无法携带，看 CAP 行
	SokoTrace(4, (long)registered);
	if (registered) [SokoLayoutSwipeHandler installOnEditingSceneViewController:self];
}

- (void)viewDidLayoutSubviews {
	%orig;

	// 1.2.1-110 · 同上：布局完立刻把虚线框再平移一次
	[SokoEditorChrome reapplyReticleTransform];
}

- (BOOL)_hasGraphicComplications {
	return [SokoPosterLayout isIgnoringGraphicComplications] ? NO : %orig;
}

- (void)setPresentedComplicationsGallery:(UINavigationController *)gallery {
	%orig;

	[SokoPosterLayout editingSceneViewControllerDidChangePresentation:self];
}

- (void)setPresentedInlineComplicationsGallery:(UINavigationController *)gallery {
	%orig;

	[SokoPosterLayout editingSceneViewControllerDidChangePresentation:self];
}

%end

%hook PREditor

- (void)setCoveredByHostModalPresentation:(BOOL)covered {
	%orig;

	[SokoPosterLayout setCoveredByHostModalPresentation:covered];
}

%end

%end

%group SokoPosterWidgetConfiguration

%hook PREditingSceneViewController

- (void)setPresentedWidgetConfigurationViewController:(UIViewController *)controller {
	%orig;

	[SokoPosterLayout editingSceneViewControllerDidChangePresentation:self];
}

%end

%end

%group SokoPosterComplicationWidgetConfiguration

%hook PREditingSceneViewController

- (void)setPresentedComplicationWidgetConfigurationViewController:(UIViewController *)controller {
	%orig;

	[SokoPosterLayout editingSceneViewControllerDidChangePresentation:self];
}

- (void)setPresentedControlsGallery:(UIViewController *)gallery {
	%orig;

	[SokoPosterLayout editingSceneViewControllerDidChangePresentation:self];
}

- (void)setPresentedControlWidgetConfigurationViewController:(UIViewController *)controller {
	%orig;

	[SokoPosterLayout editingSceneViewControllerDidChangePresentation:self];
}

%end

%end

%group SokoPosterAddGesture

%hook PREditingSceneViewController

- (BOOL)_shouldAllowAddComplicationsTapGesture {
	if (![SokoPosterLayout usesBottomEditingRow]) return %orig;

	return SokoAllowsAddGestureOverRow(^{
		return %orig;
	});
}

%end

%end

%group SokoPosterAddGestureForLocation

%hook PREditingSceneViewController

- (BOOL)_shouldAllowAddComplicationsTapGestureForLocation:(long long)location {
	if (location != 0 || ![SokoPosterLayout usesBottomEditingRow]) return %orig;

	return SokoAllowsAddGestureOverRow(^{
		return %orig;
	});
}

%end

%end

%group SokoPosterModel

%hook PRPosterComplicationLayout

- (void)encodeWithCoder:(NSCoder *)coder {
	%orig;

	[SokoPosterModel encodeComplicationLayout:self withCoder:coder];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
	self = %orig;

	[SokoPosterModel decodeComplicationLayout:self withCoder:coder];
	return self;
}

- (void)encodeWithBSXPCCoder:(id)coder {
	%orig;

	[SokoPosterModel encodeComplicationLayout:self withCoder:coder];
}

- (instancetype)initWithBSXPCCoder:(id)coder {
	self = %orig;

	[SokoPosterModel decodeComplicationLayout:self withCoder:coder];
	return self;
}

- (id)copyWithZone:(NSZone *)zone {
	id copy = %orig;

	[SokoPosterModel copyBottomLayoutFromComplicationLayout:self toComplicationLayout:copy];
	return copy;
}

- (id)mutableCopyWithZone:(NSZone *)zone {
	id copy = %orig;

	[SokoPosterModel copyBottomLayoutFromComplicationLayout:self toComplicationLayout:copy];
	return copy;
}

- (BOOL)isEqualToComplicationLayout:(id)layout {
	return %orig && [SokoPosterModel complicationLayout:self hasSameBottomLayoutAsComplicationLayout:layout];
}

- (BOOL)isEqual:(id)object {
	return %orig && [SokoPosterModel complicationLayout:self hasSameBottomLayoutAsComplicationLayout:object];
}

%end

%hook PRMutablePosterConfiguration

- (BOOL)storeComplicationLayout:(id)layout error:(NSError **)error {
	// 1.2.1-103 · **真正的"完成"判据**。
	//   PRPosterConfiguredProperties setComplicationLayout: 在一次编辑会话里被调用
	//   上千次（code 18 计数到 1133），取消同样会走到 → 它不是完成/取消的分界线。
	//   而 PRMutablePosterConfiguration 的 storeComplicationLayout:error: 是把 layout
	//   **写回磁盘**的那一步，只有"完成"会调用；取消时系统丢弃这份 layout。
	NSNumber *offset = layout ? [SokoPosterModel rowOffsetForComplicationLayout:layout] : nil;
	if (offset) {
		SokoEditorRequestRowOffset(offset.doubleValue);
		// 21 = 真正的落盘提交（payload = 值）
		SokoTrace(21, (long)llround(offset.doubleValue));
	}
	return %orig;
}

%end

%hook PRPosterConfiguredProperties

- (void)setComplicationLayout:(id)layout {
	// 1.2.1-78 · 这里只在"完成"路径被调用（取消不会走）。把编辑会话里的偏移落盘：
	// 海报进程写不了偏好，发通知让 SpringBoard 写，并清空会话值回到发布值。
	// 1.2.1-79 · 写进"新 layout 归档"（不是偏好）：系统保存即落盘、取消即丢弃，
	// 天然满足原版语义，也实现"每张壁纸各自记忆"。
	CGFloat editingOffset = [SokoPosterLayout editingRowOffset];
	// 1.2.1-99 · 提交条件：本次会话真的滑动过。没滑动（含"什么都没改就点完成"）
	// 不写任何东西；取消时只要系统不调这个方法就天然不保存。
	if (layout && [SokoPosterLayout editingRowOffsetDirty] && !isnan(editingOffset)) {
		// 1.2.1-105 · **对齐原版 Soko**：这里只把值挂到 layout 上，交给系统落盘，
		//   **不写偏好**。
		//   （1.2.1-103 试过 PRMutablePosterConfiguration storeComplicationLayout:error:，
		//    trace 21 零命中 —— 该类只有 14 个方法，列表里没有它；
		//    1.2.1-104 试过在这里直接写偏好 → 取消也保存。）
		//   完成 → 系统保存这份 layout → SpringBoard 读到归档变化 → 写偏好；
		//   取消 → 系统丢弃 → 归档不变 → 偏好不动。
		[SokoPosterModel setRowOffset:@(editingOffset) forComplicationLayout:layout];
		// 17 = 命中并挂上值（payload = 值，仅作证据）
		static CFTimeInterval lastCommitLog = 0.0;
		CFTimeInterval nowCommit = CACurrentMediaTime();
		if (nowCommit - lastCommitLog > 2.0) {
			lastCommitLog = nowCommit;
			SokoTrace(17, (long)llround(editingOffset));
		}
		SokoFileLog(@"EDITOR-ATTACH %.1f", editingOffset);
	} else {
		// 18 = 命中但本会话没滑动（payload = 次数，仅作证据）。
		//   实测这个方法一次会话被调用上千次，30 秒才记一条，否则冲爆 500 行环
		//   （上一版就是被它把 60~63 的虚线框数据全冲掉了）。
		static long noSessionHits = 0;
		static CFTimeInterval lastHitLog = 0.0;
		noSessionHits++;
		CFTimeInterval nowHit = CACurrentMediaTime();
		if (nowHit - lastHitLog > 30.0) {
			lastHitLog = nowHit;
			SokoTrace(18, noSessionHits);
		}
	}

	if (layout) {
		NSNumber *editorValue = [SokoPosterLayout bottomLayoutValueForDismissingEditor];
		if (editorValue) {
			[SokoPosterModel setBottomLayoutValue:editorValue forComplicationLayout:layout];
		} else if (![SokoPosterModel bottomLayoutValueForComplicationLayout:layout]) {
			[SokoPosterModel copyBottomLayoutFromComplicationLayout:self.complicationLayout toComplicationLayout:layout];
		}
	}

	%orig;
}

%end

%end

%group SokoLiquidAssPoster

%hook CSProminentLayoutController

- (CGRect)_frameForElement:(unsigned long long)element withBoundingRect:(CGRect)rect variant:(unsigned long long)variant {
	CGRect frame = %orig;

	return [SokoPosterLayout frameByAdjustingFrame:frame forElement:element boundingRect:rect variant:variant layoutController:self];
}

%end

%hook PRComplicationContainerViewController

- (void)viewDidLoad {
	%orig;

	[SokoPosterLayout registerComplicationContainerViewController:self];
}

%end

%end

%group SokoPhotosEditor

%hook PUWallpaperPosterEditorController

- (BOOL)_createHintLabelIfNeeded {
	BOOL created = %orig;

	self.hintLabel.hidden = YES;
	return created;
}

- (void)_updateHintLabelAnimated:(BOOL)animated {
	%orig;

	self.hintLabel.hidden = YES;
}

%end

%end

// 1.2.1-114 · **这才是边框十几个版本不动的真凶**。
//   上游 Soko 的整条边框链路都压在 PREditorRootViewController 上：
//     registerEditorRootViewController → updateReticleForEditorRootViewController
//     → [controller updateReticleViewFrames]（系统自己重摆框）
//     → 内部调 complicationRowElementEditingReticleFrameWithBoundingRect:（我们 hook 的）
//   但 PREditorRootViewController 属于 PosterBoard 的 UI 层，**懒加载**——%ctor 里
//   %init(SokoPoster) 那一刻它还不存在，Logos 的 hook 静默落空（trace 24 从头到尾
//   都是 0 就是铁证）。于是 registerEditorRootViewController 一次都没被调过，
//   updateReticleViewFrames 也从来没人调，边框自然不动。
//   解法：单独成组，等类真正加载后再 %init（dyld 回调 + 主动探测双保险）。
%group SokoEditorRoot
%hook PREditorRootViewController

- (void)loadView {
	%orig;

	SokoTrace(24, 1);
	[SokoEditorChrome registerEditorRootViewController:self];
}

- (void)viewDidLoad {
	%orig;

	SokoTrace(24, 2);
	[SokoEditorChrome registerEditorRootViewController:self];
}

- (void)viewDidLayoutSubviews {
	%orig;

	// 1.2.1-110 · 系统每次布局都会把框摆回原位，布局完立刻再平移一次
	[SokoEditorChrome update];
}

%end
%end

// 1.2.1-115 · **不能用 dispatch_once**：第一次调用时类多半还没加载，once 一旦
//   走完就永远不会再装了（1.2.1-114 的 trace 24 仍是 0 就是这个原因）。
//   改成 BOOL 门：类存在且未装 → 装；否则下次再试。
static BOOL gSokoEditorRootInstalled;
static void SokoInitEditorRoot(void) {
	if (gSokoEditorRootInstalled) return;
	if (!objc_getClass("PREditorRootViewController")) return;

	%init(SokoEditorRoot);
	gSokoEditorRootInstalled = YES;
	SokoTrace(24, 3);   // 3 = 钩子这次真的装上了
}

static void SokoImageAdded(const struct mach_header *header, intptr_t slide) {
	// 1.2.1-114 · PREditorRootViewController 晚加载时在这里补装
	SokoInitEditorRoot();

	if (!objc_getClass("PUWallpaperPosterEditorController")) return;

	static dispatch_once_t once;
	dispatch_once(&once, ^{
		%init(SokoPhotosEditor);
	});
}

static void SokoInitDock(void) {
	if (![SokoDockCoordinator isSupported]) return;

	%init(SokoDock);

	if ([objc_getClass("NCNotificationListView") instancesRespondToSelector:@selector(_layoutOverlayFooterViewIfNecessary)]) {
		%init(SokoDockListFooter);
	} else if ([objc_getClass("NCNotificationStructuredListView") instancesRespondToSelector:@selector(footerView)]) {
		%init(SokoDockContainerFooter);
	}

	if ([objc_getClass("CSComplicationContainerViewController") instancesRespondToSelector:@selector(setWidgetDescriptors:)]) {
		%init(SokoDockWidgetDescriptors);
	} else if ([objc_getClass("CSWidgetGridViewController") instancesRespondToSelector:@selector(setComplicationDescriptors:iconLayout:)]) {
		%init(SokoDockWidgetGrid);
	}

	Class combinedListClass = objc_getClass("CSCombinedListViewController");
	if ([combinedListClass instancesRespondToSelector:@selector(notificationStructuredListViewControllerRequestsEdgeInsetsForOverlayFooterView:forOrientation:)]) {
		%init(SokoDockFooterInsetsForOrientation);
	} else if ([combinedListClass instancesRespondToSelector:@selector(notificationStructuredListViewControllerRequestsEdgeInsetsForOverlayFooterView:)]) {
		%init(SokoDockFooterInsets);
	}
}

static void SokoInitLiquidAssPoster(void) {
	%init(SokoLiquidAssPoster);

	SokoDockGeometryObserve(^{
		// 1.2.1-77 · 几何通道更新（含编辑器滑动回写）立即重排，不再用 0.45s 动画
		[SokoPosterLayout relayoutAnimated:NO];
	});
}

static void SokoInitPoster(void) {
	if (![SokoPosterLayout isSupported]) {
		SokoFileLog(@"INITPOSTER abort: not supported");
		return;
	}
	// 1.2.1-75 · 删除"全局 LiquidAss 开关即整段跳过编辑器"的分支。
	// 该分支只装几何钩子，不装编辑态 reticle / 滑动 / 壁纸状态写入 —— 只要装了
	// LiquidAss，长按进自定义就既不在底部也拖不动。LiquidAss 的差异改为在
	// SokoPosterLayout 里按"这张壁纸是否真的配了 LiquidAss 时钟"逐张判定。

	SokoFileLog(@"INITPOSTER full (editor + model + swipe)");
	%init(SokoPoster);

	Class editingSceneClass = objc_getClass("PREditingSceneViewController");
	BOOL hasNewWidgetConfig = [editingSceneClass instancesRespondToSelector:@selector(setPresentedComplicationWidgetConfigurationViewController:)];
	BOOL hasOldWidgetConfig = [editingSceneClass instancesRespondToSelector:@selector(setPresentedWidgetConfigurationViewController:)];
	BOOL hasAddGestureLocation = [editingSceneClass instancesRespondToSelector:@selector(_shouldAllowAddComplicationsTapGestureForLocation:)];
	BOOL hasAddGesture = [editingSceneClass instancesRespondToSelector:@selector(_shouldAllowAddComplicationsTapGesture)];
	SokoFileLog(@"INITPOSTER editingScene=%@ newWidgetCfg=%d oldWidgetCfg=%d addGestureLoc=%d addGesture=%d",
	            NSStringFromClass(editingSceneClass), (int)hasNewWidgetConfig, (int)hasOldWidgetConfig,
	            (int)hasAddGestureLocation, (int)hasAddGesture);

	if (hasNewWidgetConfig) {
		%init(SokoPosterComplicationWidgetConfiguration);
	} else if (hasOldWidgetConfig) {
		%init(SokoPosterWidgetConfiguration);
	}

	if (hasAddGestureLocation) {
		%init(SokoPosterAddGestureForLocation);
	} else if (hasAddGesture) {
		%init(SokoPosterAddGesture);
	}

	SokoDockGeometryObserve(^{
		// 1.2.1-77 · 几何通道更新（含编辑器滑动回写）立即重排，不再用 0.45s 动画
		[SokoPosterLayout relayoutAnimated:NO];
	});

	// 1.2.1-114 · 边框钩子：类已加载就立刻装，没加载就等 dyld 回调
	SokoInitEditorRoot();
	_dyld_register_func_for_add_image(SokoImageAdded);
}


// 1.2.1-91 · 只读探针：找出编辑器里"完成/取消"到底调用哪个方法。
// 只给零参/单参方法装钩子（避免变参 IMP 崩溃），命中即发一个独立码（40 起），
// 然后再原样转调原实现，不改变任何行为。
// 1.2.1-102 · 把目标类的全部方法名落盘。
// 为什么需要：按关键字猜 done/cancel 猜了四版（40~51 一次都没命中），
// 说明方法名里根本没有这些词。直接把方法表打出来，一眼就能看到真正的收尾方法。
static void SokoDumpSelectors(Class cls) {
	if (!cls) return;

	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	NSMutableString *buffer = [NSMutableString stringWithFormat:@"METHODS %@ n=%u", NSStringFromClass(cls), count];
	for (unsigned int i = 0; i < count; i++) {
		[buffer appendFormat:@" %@", NSStringFromSelector(method_getName(methods[i]))];
		if (buffer.length > 220) {
			SokoFileLog(@"%@", buffer);
			buffer = [NSMutableString string];
		}
	}
	if (buffer.length) SokoFileLog(@"%@", buffer);
	if (methods) free(methods);
}

static void SokoProbeEditorButtons(void) {
	Class cls = NSClassFromString(@"PREditingSceneViewController");
	if (!cls) return;

	// 1.2.1-103 · 方法表改在 SpringBoard 侧落盘（见 %ctor）：
	//   PosterBoard 写不进任何偏好域，SokoFileLog 在海报进程里是静默失败的，
	//   上一版把 dump 放在这里，结果 METHODS 一条都没出来。

	NSArray<NSString *> *keywords = @[@"done", @"cancel", @"save", @"apply", @"discard", @"commit", @"finish"];
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	int code = 40;

	for (unsigned int i = 0; i < count && code < 52; i++) {
		SEL sel = method_getName(methods[i]);
		NSString *name = NSStringFromSelector(sel);
		NSString *lower = name.lowercaseString;
		BOOL match = NO;
		for (NSString *keyword in keywords) {
			if ([lower containsString:keyword]) { match = YES; break; }
		}
		if (!match) continue;

		unsigned int argCount = method_getNumberOfArguments(methods[i]);
		IMP original = method_getImplementation(methods[i]);
		int capturedCode = code++;

		if (argCount == 2) {
			IMP replacement = imp_implementationWithBlock(^(id receiver) {
				SokoTrace(capturedCode, 0);
				((void (*)(id, SEL))original)(receiver, sel);
			});
			method_setImplementation(methods[i], replacement);
		} else if (argCount == 3) {
			IMP replacement = imp_implementationWithBlock(^(id receiver, uintptr_t arg) {
				SokoTrace(capturedCode, 0);
				((void (*)(id, SEL, uintptr_t))original)(receiver, sel, arg);
			});
			method_setImplementation(methods[i], replacement);
		}
	}

	if (methods) free(methods);
}



// 1.2.1-95 · 编辑器按钮监听改为拦 UIApplication 的 sendAction：
// 编辑器的"完成"实际是 UIBarButtonItem，不是 UIButton，按标题找 UIButton 会全漏。
%group SokoEditorActions
%hook UIApplication
- (void)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
	// 1.2.1-96 · 不再依赖标题：直接看动作名。
	// 55=任意一次点击（证明钩子活着） 56=动作名含 done/save/commit/finish/apply
	// 57=动作名含 cancel/dismiss/discard 58=标题匹配（保留）
	SokoTrace(55, 1);

	NSString *selector = NSStringFromSelector(action) ?: @"";
	NSString *lower = selector.lowercaseString;

	BOOL selDone = [lower containsString:@"done"] || [lower containsString:@"save"] ||
	               [lower containsString:@"commit"] || [lower containsString:@"finish"] ||
	               [lower containsString:@"apply"];
	BOOL selCancel = [lower containsString:@"cancel"] || [lower containsString:@"dismiss"] ||
	                 [lower containsString:@"discard"];

	NSString *title = nil;
	if ([sender respondsToSelector:@selector(title)]) title = [sender title];
	if (![title isKindOfClass:[NSString class]] || !title.length) {
		if ([sender isKindOfClass:[UIButton class]]) title = [(UIButton *)sender titleForState:UIControlStateNormal];
	}
	BOOL titleDone = [title isKindOfClass:[NSString class]] && [@[@"完成", @"Done", @"保存", @"Save"] containsObject:title];
	BOOL titleCancel = [title isKindOfClass:[NSString class]] && [@[@"取消", @"Cancel"] containsObject:title];

	if (selDone || titleDone) {
		SokoTrace(56, 1);
		CGFloat offset = [SokoPosterLayout editingRowOffset];
		// 19 = 这条"完成"来自 UIApplication sendAction（与 17 区分提交来源）
		if (!isnan(offset)) SokoTrace(19, (long)llround(offset));
		if (!isnan(offset)) {
			SokoEditorRequestRowOffset(offset);
			SokoFileLog(@"EDITOR-DONE sel=%@ title=%@ off=%.1f", selector, title, offset);
		}
	} else if (selCancel || titleCancel) {
		SokoTrace(57, 1);
		SokoFileLog(@"EDITOR-CANCEL sel=%@ title=%@", selector, title);
	}

	%orig;
}
%end
%end

%ctor {
	NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
	BOOL isSpringBoard = [bundleIdentifier isEqualToString:@"com.apple.springboard"];

	// 1.2.1-68 · 显式进程白名单。上游是「不是 springboard 就当 poster」，于是
	// EchoReborn filter 里的 SiriViewService / siri.SystemUI / SiriUI 也会走
	// SokoInitPoster（那里会注册 dyld 回调、装编辑态钩子）。改成白名单后，
	// 无关进程连 SokoPosterModel 都不注入。
	BOOL isPosterHost = [bundleIdentifier isEqualToString:@"com.apple.PosterBoard"] ||
	                    [bundleIdentifier isEqualToString:@"com.apple.PosterKit"] ||
	                    [bundleIdentifier isEqualToString:@"com.apple.MercuryPoster"];
	// 1.2.1-69 · 进程归属只在文件日志里记一次，用来确认 PosterBoard 到底有没有注入。
	SokoFileLog(@"CTOR enter pid=%d bid=%@ springboard=%d posterHost=%d",
	            (int)getpid(), bundleIdentifier, (int)isSpringBoard, (int)isPosterHost);
	if (!isSpringBoard && !isPosterHost) return;

	BOOL modelSupported = [SokoPosterModel isSupported];
	if (modelSupported) %init(SokoPosterModel);

	// 1.2.1-97 · 点击钩子在所有进程统一初始化（Logos 不允许同一 group 初始化两次）
	%init(SokoEditorActions);

	if (isSpringBoard) {
		// 1.2.1-68 · 首装探针：dock=0 就是「本机不支持底部 dock」，别去猜布局算错。
		BOOL dockSupported = [SokoDockCoordinator isSupported];
		ERSokoLog(@"SOKO-CAP proc=%@ model=%d dock=%d poster=0",
		          bundleIdentifier, (int)modelSupported, (int)dockSupported);
		SokoFileLog(@"CAP springboard model=%d dock=%d", (int)modelSupported, (int)dockSupported);

		// 1.2.1-73 · 海报进程报到监听：收到即证明那个进程加载并执行了本 dylib。
		for (NSString *name in @[@"com.strive.echoreborn.soko.hello.posterboard",
		                         @"com.strive.echoreborn.soko.hello.posterkit",
		                         @"com.strive.echoreborn.soko.hello.mercuryposter"]) {
			int token = NOTIFY_TOKEN_INVALID;
			notify_register_dispatch(name.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
				SokoFileLog(@"POSTER-HELLO %@", name);
			});
		}

		// 1.2.1-75 · 海报进程判定码：每条 code 一条通知名，避免连续判定被系统合并。
		for (int code = 1; code < 64; code++) {
			NSString *traceName = [NSString stringWithFormat:@"com.strive.echoreborn.soko.tr.%d", code];
			int traceToken = NOTIFY_TOKEN_INVALID;
			notify_register_dispatch(traceName.UTF8String, &traceToken, dispatch_get_main_queue(), ^(int t) {
				int checkToken = NOTIFY_TOKEN_INVALID;
				uint64_t state = 0;
				notify_register_check(traceName.UTF8String, &checkToken);
				notify_get_state(checkToken, &state);
				notify_cancel(checkToken);
				SokoFileLog(@"TRACE code=%d payload=%ld", code, (long)state - kSokoTracePayloadOffset);
			});
		}

		// 1.2.1-71 · 在 SpringBoard 里预演 PosterBoard 的 SokoPosterLayout isSupported：
		// 用的是同一批私有类，哪一条不满足就直接点名（PosterBoard 侧写不进日志时，
		// 这一行就是唯一判据）。
		{
			Class containerCls = NSClassFromString(@"PRComplicationContainerViewController");
			Class layoutCls = NSClassFromString(@"CSProminentLayoutController");
			BOOL nativeBottom = [containerCls instancesRespondToSelector:NSSelectorFromString(@"setWidgetsUseBottomLayout:")];
			BOOL rowFrame = [layoutCls instancesRespondToSelector:NSSelectorFromString(@"_frameForElement:withBoundingRect:variant:")];
			BOOL reticle = [layoutCls instancesRespondToSelector:NSSelectorFromString(@"complicationRowElementEditingReticleFrameWithBoundingRect:")];
			BOOL frameRect = [layoutCls instancesRespondToSelector:NSSelectorFromString(@"frameForElements:variant:withBoundingRect:")];
			BOOL frameVariant = [layoutCls respondsToSelector:NSSelectorFromString(@"frameForElements:variant:")];
			SokoFileLog(@"CAP-SEL container=%@ layout=%@ nativeBottom=%d rowFrame=%d reticle=%d frameRect=%d frameVariant=%d",
			            NSStringFromClass(containerCls), NSStringFromClass(layoutCls),
			            (int)nativeBottom, (int)rowFrame, (int)reticle, (int)frameRect, (int)frameVariant);
		}

		SokoTrace(59, 1);   // 59=1：SpringBoard 侧已装点击钩子

		// 1.2.1-103 · 方法表落盘（必须在 SpringBoard 侧：海报进程写不进偏好域，
		// SokoFileLog 在那里静默失败）。用来从真实方法名里挑出"完成/取消"入口。
		SokoDumpSelectors(NSClassFromString(@"PREditingSceneViewController"));
		SokoDumpSelectors(NSClassFromString(@"PREditor"));
		SokoDumpSelectors(NSClassFromString(@"PREditorRootViewController"));
		SokoDumpSelectors(NSClassFromString(@"PRMutablePosterConfiguration"));

		if (dockSupported) SokoInitDock();

		// 1.2.1-73 · 设置页改值/重置后立即重排组件行（此前只重排通知列表，
		// 组件行要等锁屏重新布局才动，表现就是"数值变了画面没变"）。
	SokoPreferencesSetChangeHandler(^{
		SokoDockCoordinator *coordinator = SokoCoordinator();
		// 1.2.1-82 · 改值后重算"是否接管"（原来 enabled 只随壁纸切换更新）
		[coordinator setEnabled:SokoPrefWidgetsEnabled() && SokoPrefWidgetOffsetIsSet()];
		[coordinator refresh];
		UIView *coverSheetView = gCoverSheetViewController.viewIfLoaded;
		[coverSheetView setNeedsLayout];

		// 1.2.1-99 · 滑块改动也要按壁纸记一份，否则"每壁纸独立"只对编辑器滑动成立。
		//   只写 map 不写 pref，不会再触发一次 ReloadPrefs（无回环）。
		if (gActivePosterKey) {
			NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.strive.echoreborn.preferences"];
			double value = [defaults doubleForKey:@"soko_widgetOffset"];
			NSMutableDictionary *map = SokoPosterOffsetMap();
			NSNumber *old = map[gActivePosterKey];
			if (!old || fabs(old.doubleValue - value) > 0.5) {
				map[gActivePosterKey] = @(value);
				[defaults setObject:map forKey:@"soko_offsets_by_poster"];
				[defaults synchronize];
				SokoFileLog(@"POSTER-SLIDER %@ = %.1f", gActivePosterKey, value);
			}
		}
	});

		// 1.2.1-76 · 编辑器里上/下滑后，海报进程只能发通知（写不了偏好），
		// 由 SpringBoard 落盘到 soko_widgetOffset，设置页随即显示同一个数值。
		{
			int setOffsetToken = NOTIFY_TOKEN_INVALID;
			notify_register_dispatch(SokoSetRowOffsetRequestNotification.UTF8String, &setOffsetToken,
			                         dispatch_get_main_queue(), ^(int t) {
				CGFloat value = SokoRowOffsetRequestValue();
				if (isnan(value)) return;
				NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.strive.echoreborn.preferences"];
				[defaults setDouble:value forKey:@"soko_widgetOffset"];
				// 1.2.1-94 · 同时写入"当前壁纸"的独立记录
				if (gActivePosterKey) {
					NSMutableDictionary *map = SokoPosterOffsetMap();
					map[gActivePosterKey] = @(value);
					[defaults setObject:map forKey:@"soko_offsets_by_poster"];
					SokoFileLog(@"POSTER-OFFSET %@ = %.1f", gActivePosterKey, value);
				}
				[defaults synchronize];
				// 1.2.1-82 · 立即生效：把该值设为当前壁纸的生效偏移并接管
				[SokoDockCoordinator setActiveRowOffset:@(value)];
				SokoDockCoordinator *coordinator = SokoCoordinator();
				[coordinator setEnabled:YES];
				[coordinator refresh];
				notify_post("com.strive.echoreborn/ReloadPrefs");
				SokoFileLog(@"EDITOR-SETOFFSET %.1f", value);
			});
		}

		// 1.2.1-104 · 编辑会话基线：进编辑器时海报进程把"编辑前的值"发过来存着，
		//   点"取消"时用它回滚（滑动是立即提交的，回滚是唯一能还原的办法）。
		{
			int baselineToken = NOTIFY_TOKEN_INVALID;
			notify_register_dispatch(SokoEditorBaselineNotification.UTF8String, &baselineToken,
			                         dispatch_get_main_queue(), ^(int t) {
				CGFloat value = SokoRowOffsetBaselineValue();
				if (isnan(value)) return;
				gEditBaselineOffset = @(value);
				SokoFileLog(@"EDITOR-BASELINE %.1f", value);
			});
		}

		// 1.2.1-104 · 取消 → 回滚到基线
		{
			int revertToken = NOTIFY_TOKEN_INVALID;
			notify_register_dispatch(SokoEditorRevertNotification.UTF8String, &revertToken,
			                         dispatch_get_main_queue(), ^(int t) {
				CGFloat value = gEditBaselineOffset ? gEditBaselineOffset.doubleValue : 0.0;
				NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.strive.echoreborn.preferences"];
				[defaults setDouble:value forKey:@"soko_widgetOffset"];
				if (gActivePosterKey) {
					NSMutableDictionary *map = SokoPosterOffsetMap();
					map[gActivePosterKey] = @(value);
					[defaults setObject:map forKey:@"soko_offsets_by_poster"];
				}
				[defaults synchronize];
				[SokoDockCoordinator setActiveRowOffset:@(value)];
				SokoDockCoordinator *coordinator = SokoCoordinator();
				[coordinator setEnabled:YES];
				[coordinator refresh];
				notify_post("com.strive.echoreborn/ReloadPrefs");
				SokoFileLog(@"EDITOR-REVERT %.1f", value);
			});
		}
		return;
	}

	// 海报进程：报到 + 记录能力判定
	notify_post(SokoHelloNameForBundleIdentifier(bundleIdentifier).UTF8String);

	BOOL posterSupported = [SokoPosterLayout isSupported];
	BOOL liquidAss = SokoLiquidAssClockEnabled();
	// code 1：posterSupported（0/1）；code 2：liquidAss（0/1）
	SokoTrace(1, (long)posterSupported);
	SokoTrace(2, (long)liquidAss);
	ERSokoLog(@"SOKO-CAP proc=%@ model=%d dock=0 poster=%d",
	          bundleIdentifier, (int)modelSupported, (int)posterSupported);
	SokoFileLog(@"CAP poster model=%d posterSupported=%d liquidAss=%d",
	            (int)modelSupported, (int)posterSupported, (int)liquidAss);
	SokoTrace(59, 2);   // 59=2：海报进程侧已装点击钩子
	if (posterSupported) SokoInitPoster();
}
