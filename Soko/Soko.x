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

	BOOL usesBottomLayout;
	if (SokoLiquidAssClockEnabled()) {
		usesBottomLayout = configuration && SokoLiquidAssUserInfoUsesBottomLayout(SokoLiquidAssUserInfoForConfiguration(configuration));
	} else {
		id layout = nil;
		if ([configuration respondsToSelector:@selector(pr_loadComplicationLayoutWithError:)]) {
			layout = [configuration pr_loadComplicationLayoutWithError:nil];
		}

		usesBottomLayout = [SokoPosterModel complicationLayoutUsesBottomLayout:layout];
	}
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
	[SokoPosterLayout registerComplicationContainerViewController:self];
	[SokoLayoutSwipeHandler installOnComplicationContainerViewController:self];
}

%end

%hook PREditorRootViewController

- (void)loadView {
	%orig;

	[SokoEditorChrome registerEditorRootViewController:self];
}

%end

%hook PREditingSceneViewController

- (instancetype)initWithProvider:(id)provider contents:(id)contents configurableOptions:(id)configurableOptions configuredProperties:(PRPosterConfiguredProperties *)configuredProperties additionalInfo:(id)additionalInfo {
	self = %orig;

	if (self) [SokoPosterLayout setInitialComplicationLayout:configuredProperties.complicationLayout forEditingSceneViewController:self];
	return self;
}

- (void)viewDidLoad {
	%orig;

	BOOL registered = [SokoPosterLayout registerEditingSceneViewController:self];
	SokoFileLog(@"EDITOR viewDidLoad registered=%d role=%@",
	            (int)registered,
	            [self respondsToSelector:@selector(posterRole)] ? self.posterRole : @"(none)");
	if (registered) [SokoLayoutSwipeHandler installOnEditingSceneViewController:self];
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

%hook PRPosterConfiguredProperties

- (void)setComplicationLayout:(id)layout {
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

static void SokoImageAdded(const struct mach_header *header, intptr_t slide) {
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
		[SokoPosterLayout relayoutAnimated:YES];
	});
}

static void SokoInitPoster(void) {
	if (![SokoPosterLayout isSupported]) {
		SokoFileLog(@"INITPOSTER abort: not supported");
		return;
	}
	if (SokoLiquidAssClockEnabled()) {
		SokoFileLog(@"INITPOSTER liquidAss branch (no editor hooks)");
		SokoInitLiquidAssPoster();
		return;
	}

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
		[SokoPosterLayout relayoutAnimated:YES];
	});

	_dyld_register_func_for_add_image(SokoImageAdded);
}

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

		if (dockSupported) SokoInitDock();

		// 1.2.1-73 · 设置页改值/重置后立即重排组件行（此前只重排通知列表，
		// 组件行要等锁屏重新布局才动，表现就是"数值变了画面没变"）。
		SokoPreferencesSetChangeHandler(^{
			SokoDockCoordinator *coordinator = SokoCoordinator();
			[coordinator refresh];
			UIView *coverSheetView = gCoverSheetViewController.viewIfLoaded;
			[coverSheetView setNeedsLayout];
		});
		return;
	}

	// 海报进程：报到 + 记录能力判定
	notify_post(SokoHelloNameForBundleIdentifier(bundleIdentifier).UTF8String);

	BOOL posterSupported = [SokoPosterLayout isSupported];
	BOOL liquidAss = SokoLiquidAssClockEnabled();
	ERSokoLog(@"SOKO-CAP proc=%@ model=%d dock=0 poster=%d",
	          bundleIdentifier, (int)modelSupported, (int)posterSupported);
	SokoFileLog(@"CAP poster model=%d posterSupported=%d liquidAss=%d",
	            (int)modelSupported, (int)posterSupported, (int)liquidAss);
	if (posterSupported) SokoInitPoster();
}
