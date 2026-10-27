#import "SokoDockCoordinator.h"
#import "../SokoPreferences.h"
#import "../SokoLog.h"
#import "../SokoFileLog.h"

NSString *const SokoProminentDisplayVibrancyDidChangeNotification = @"SokoProminentDisplayVibrancyDidChangeNotification";
NSString *const SokoProminentDisplayContentAlphaDidChangeNotification = @"SokoProminentDisplayContentAlphaDidChangeNotification";

static const CGFloat kSokoDockBottomInsetWithoutButtons = 71.0;

static const void *kSokoDockCoordinatorKey = &kSokoDockCoordinatorKey;
static __weak SokoDockCoordinator *gActiveCoordinator;
// 1.2.1-79 · 当前壁纸归档里的行偏移（nil = 未设置 → 顶部）
static NSNumber *gActiveRowOffset;

@interface SokoDockCoordinator ()
@property (nonatomic, weak) CSCoverSheetViewController *coverSheetViewController;
@property (nonatomic, strong) SokoNotificationList *notificationList;
@property (nonatomic, strong) CSProminentLayoutController *layoutController;
@property (nonatomic, strong) BSUIVibrancyEffectView *hostView;
@property (nonatomic) BOOL enabled;
@property (nonatomic) BOOL attached;
@property (nonatomic) CGFloat dockTopY;
@property (nonatomic) CGFloat dockBottomY;
@end

@implementation SokoDockCoordinator

+ (BOOL)isSupported {
	Class coverSheetClass = NSClassFromString(@"CSCoverSheetViewController");
	if ([coverSheetClass instancesRespondToSelector:NSSelectorFromString(@"setComplicationContainerUsesBottomPosition:")]) return NO;

	Class dateClass = NSClassFromString(@"SBFLockScreenDateViewController");
	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	Class listClass = NSClassFromString(@"NCNotificationListView");
	Class structuredClass = NSClassFromString(@"NCNotificationStructuredListViewController");
	Class containerClass = NSClassFromString(@"NCNotificationStructuredListView");

	BOOL listFooter = [listClass instancesRespondToSelector:@selector(setOverlayFooterViewEdgeInsets:)];
	BOOL containerFooter = [structuredClass instancesRespondToSelector:@selector(_updateListEdgeInsetsForSize:)] &&
		[containerClass instancesRespondToSelector:@selector(footerInsets)];

	BOOL coverSheet = [coverSheetClass instancesRespondToSelector:@selector(complicationContainerViewController)] &&
		[coverSheetClass instancesRespondToSelector:@selector(dateViewController)] &&
		[coverSheetClass instancesRespondToSelector:@selector(mainPageContentViewController)] &&
		[NSClassFromString(@"CSCoverSheetView") instancesRespondToSelector:@selector(slideableContentView)] &&
		[dateClass instancesRespondToSelector:@selector(setComplicationContainerViewController:)];

	BOOL layout = [layoutClass instancesRespondToSelector:@selector(initWithTraitEnvironment:)] &&
		[layoutClass instancesRespondToSelector:@selector(frameForElements:withBoundingRect:)];

	BOOL hosting = [UIViewController instancesRespondToSelector:@selector(bs_addChildViewController:withSuperview:)] &&
		[UIViewController instancesRespondToSelector:@selector(bs_removeChildViewController:)];

	return coverSheet && layout && hosting && (listFooter || containerFooter);
}

+ (void)setActiveRowOffset:(NSNumber *)offset {
	gActiveRowOffset = offset;
}

+ (instancetype)coordinatorForCoverSheetViewController:(CSCoverSheetViewController *)controller {
	if (!controller) return nil;

	SokoDockCoordinator *coordinator = objc_getAssociatedObject(controller, kSokoDockCoordinatorKey);
	if (!coordinator) {
		coordinator = [[SokoDockCoordinator alloc] initWithCoverSheetViewController:controller];
		objc_setAssociatedObject(controller, kSokoDockCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(controller.view, kSokoDockCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return coordinator;
}

+ (instancetype)coordinatorForCoverSheetView:(UIView *)view {
	return view ? objc_getAssociatedObject(view, kSokoDockCoordinatorKey) : nil;
}

+ (instancetype)activeCoordinator {
	return gActiveCoordinator;
}

- (instancetype)initWithCoverSheetViewController:(CSCoverSheetViewController *)controller {
	self = [super init];
	if (self) {
		_coverSheetViewController = controller;
		_notificationList = [[SokoNotificationList alloc] initWithCoverSheetViewController:controller dock:self];
		_dockTopY = NAN;
		_dockBottomY = NAN;

		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		[center addObserver:self selector:@selector(prominentDisplayVibrancyDidChange:) name:SokoProminentDisplayVibrancyDidChangeNotification object:nil];
		[center addObserver:self selector:@selector(prominentDisplayContentAlphaDidChange:) name:SokoProminentDisplayContentAlphaDidChangeNotification object:nil];
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setEnabled:(BOOL)enabled {
	_enabled = enabled;
	[self publishDockGeometry];
	[self refresh];
}

- (void)refresh {
	if ([self shouldHostDock]) {
		[self attachIfNeeded];
	} else {
		[self detach];
	}

	[self.coverSheetViewController.viewIfLoaded setNeedsLayout];
	[self.notificationList updateLayout];
}

- (void)coverSheetViewDidLayout {
	[self publishDockGeometry];

	if (![self shouldHostDock]) {
		if (self.attached) [self refresh];
		return;
	}

	[self attachIfNeeded];
	if (!self.attached) return;

	[self layoutDock];
	[self.notificationList updateLayout];
}

- (BOOL)shouldHostDock {
	if (!self.enabled) return NO;

	UIViewController *complications = self.coverSheetViewController.complicationContainerViewController;
	if ([complications respondsToSelector:@selector(widgetDescriptors)]) {
		NSArray *descriptors = ((CSComplicationContainerViewController *)complications).widgetDescriptors;
		return [descriptors isKindOfClass:[NSArray class]] && descriptors.count > 0;
	}

	return complications && self.complicationContainerHeight > 0.0;
}

- (BOOL)dockVisible {
	if (!self.attached || self.hostView.hidden || isnan(self.dockTopY)) return NO;

	UIView *complicationsView = self.coverSheetViewController.complicationContainerViewController.viewIfLoaded;
	return complicationsView && !complicationsView.hidden && complicationsView.alpha > 0.01;
}

- (UIView *)dockContainerView {
	return self.hostView.superview;
}

- (double)complicationContainerHeight {
	CSCoverSheetViewController *coverSheet = self.coverSheetViewController;
	if (class_getInstanceVariable(object_getClass(coverSheet), "_portraitComplicationContainerHeight")) {
		return SokoIvarDouble(coverSheet, "_portraitComplicationContainerHeight");
	}

	return SokoIvarDouble(coverSheet, "_complicationContainerHeight");
}

- (UIView *)contentView {
	if ([self.hostView respondsToSelector:@selector(contentView)]) return self.hostView.contentView;

	return self.hostView;
}

- (BSUIVibrancyEffectView *)makeHostView {
	Class vibrancyClass = NSClassFromString(@"BSUIVibrancyEffectView") ?: [UIView class];

	BSUIVibrancyEffectView *host = [[vibrancyClass alloc] initWithFrame:CGRectZero];
	host.userInteractionEnabled = NO;
	host.layer.name = @"Soko Widget Dock";
	return host;
}

- (void)insertHostViewIfNeeded {
	CSCoverSheetView *coverSheetView = (CSCoverSheetView *)self.coverSheetViewController.viewIfLoaded;
	UIView *slideableContentView = coverSheetView.slideableContentView;
	if (!self.hostView) self.hostView = [self makeHostView];
	if (self.hostView.superview == slideableContentView) return;

	UIView *dateContainer = SokoIvarObject(coverSheetView, "_dateTimeClippingView");
	if (dateContainer.superview == slideableContentView) {
		[slideableContentView insertSubview:self.hostView aboveSubview:dateContainer];
	} else {
		[slideableContentView insertSubview:self.hostView atIndex:0];
	}
}

- (void)attachIfNeeded {
	CSCoverSheetViewController *coverSheet = self.coverSheetViewController;
	UIViewController *complications = coverSheet.complicationContainerViewController;
	SBFLockScreenDateViewController *dateViewController = coverSheet.dateViewController;
	CSCoverSheetView *coverSheetView = (CSCoverSheetView *)coverSheet.viewIfLoaded;
	if (!complications || !dateViewController || !coverSheetView.slideableContentView) return;

	[self insertHostViewIfNeeded];

	UIView *content = [self contentView];
	BOOL hosted = complications.parentViewController == coverSheet && complications.viewIfLoaded.superview == content;
	if (!hosted) {
		if (dateViewController.complicationContainerViewController == complications) {
			dateViewController.complicationContainerViewController = nil;
		} else if (complications.parentViewController) {
			[complications.parentViewController bs_removeChildViewController:complications];
		}

		[coverSheet bs_addChildViewController:complications withSuperview:content];
		complications.view.frame = content.bounds;
		complications.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	}

	self.attached = YES;
	gActiveCoordinator = self;

	if (!hosted) {
		[self syncVibrancy];
		[self syncRowAlpha];
	}
}

- (void)detach {
	if (!self.attached) return;

	CSCoverSheetViewController *coverSheet = self.coverSheetViewController;
	UIViewController *complications = coverSheet.complicationContainerViewController;
	if (complications.parentViewController == coverSheet) [coverSheet bs_removeChildViewController:complications];
	[self.hostView removeFromSuperview];

	self.attached = NO;
	self.dockTopY = NAN;
	self.dockBottomY = NAN;
	if (gActiveCoordinator == self) gActiveCoordinator = nil;

	if (complications) coverSheet.dateViewController.complicationContainerViewController = complications;
}

- (CSProminentLayoutController *)layoutController {
	if (!_layoutController) {
		Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
		_layoutController = [[layoutClass alloc] initWithTraitEnvironment:(id<UITraitEnvironment>)self.coverSheetViewController.view];
	}
	return _layoutController;
}

- (CGFloat)dockBottomYInCoverSheetView:(CSCoverSheetView *)coverSheetView {
	CGFloat centerY;
	if (SokoQuickActionButtonCenterY(coverSheetView, &centerY)) return centerY - kSokoDockBottomToButtonCenter;

	return CGRectGetHeight(coverSheetView.bounds) - coverSheetView.safeAreaInsets.bottom - kSokoDockBottomInsetWithoutButtons;
}

- (void)publishRowOffsetsIfPossible {
	// 1.2.1-80 · 几何发布与"是否停靠"解耦。之前只在 layoutDock 里算/发，一旦组件
	// 不接管（默认顶部态）dock 不启用、layoutDock 不执行 → 顶部值一直是 NaN，
	// 编辑器里上/下滑判定直接 return（就是"滑动没反应"）。
	CSCoverSheetView *coverSheetView = (CSCoverSheetView *)self.coverSheetViewController.viewIfLoaded;
	if (!coverSheetView) return;

	[self publishRowOffsetsIfPossible];

	CGFloat bottomRowY = [self dockBottomYInCoverSheetView:coverSheetView] - CGRectGetHeight(row);
	BOOL offsetIsSet = (gActiveRowOffset != nil) || SokoPrefWidgetOffsetIsSet();
	CGFloat effectiveOffset = gActiveRowOffset ? gActiveRowOffset.doubleValue : SokoPrefWidgetOffset();
	if (!offsetIsSet) effectiveOffset = SokoTopOffsetValue();
	if (isnan(effectiveOffset)) effectiveOffset = 0.0;

	row.origin.y = bottomRowY + effectiveOffset;
	self.dockTopY = CGRectGetMinY(row);
	self.dockBottomY = CGRectGetMaxY(row);

	host.hidden = NO;
	host.transform = CGAffineTransformIdentity;
	host.frame = row;
	[self applyDateViewScale:coverSheetView];

	UIView *complicationsView = self.coverSheetViewController.complicationContainerViewController.viewIfLoaded;
	UIView *content = [self contentView];
	if (complicationsView.superview == content && !CGRectEqualToRect(complicationsView.frame, content.bounds)) {
		complicationsView.frame = content.bounds;
	}

	// 1.2.1-68 · 几何取证：值变化立即打印，否则 2s 一条。判据 #4 就是拿
	// botY 与 QA-APPLY 的按钮原始中心比（差应 ≈ kSokoDockBottomToButtonCenter 45）。
	{
		// CGRectNull 不是编译期常量，static 不能直接拿它初始化（CI 实锤：
		// error: initializer element is not a compile-time constant）。用脏标记代替。
		static CFTimeInterval lastLogTime = 0.0;
		static CGRect lastRow;
		static BOOL hasLastRow = NO;
		CFTimeInterval now = CACurrentMediaTime();
		if (now - lastLogTime > 2.0 || !hasLastRow || !CGRectEqualToRect(lastRow, row)) {
			lastLogTime = now;
			lastRow = row;
			hasLastRow = YES;
			CGFloat buttonCenterY = 0.0;
			BOOL buttonHit = SokoQuickActionButtonCenterY(coverSheetView, &buttonCenterY);
			ERSokoLog(@"SOKO-DOCK botY=%.1f topY=%.1f h=%.1f off=%.1f btnHit=%d btnCenterY=%.1f",
			          self.dockBottomY, self.dockTopY, CGRectGetHeight(row),
			          SokoPrefWidgetOffset(), (int)buttonHit, buttonCenterY);

			// 1.2.1-72 · 数值标定：同一个 layoutController 算出的"系统原位行"（= 组件
			// 在顶部时的行）与"底部态行"的差值，就是滑块要跨越的行程。
			// SpringBoard 里没有装 _frameForElement: 那个 hook（它只在海报进程），
			// 所以这里拿到的是未被我方改写的系统原值。
			CGRect stockRow = [self.layoutController frameForElements:kSokoComplicationRowElement withBoundingRect:bounds];
			CGFloat stockY = CGRectGetMinY(stockRow);
			CGFloat delta = stockY - CGRectGetMinY(row);          // 顶部相对底部的位移（负=在上方）
			CGRect screenFrame = coverSheetView.window ? coverSheetView.window.bounds : bounds;
			SokoFileLog(@"CALIB screen=%.0fx%.0f safeBottom=%.1f stockY=%.1f stockH=%.1f bottomY=%.1f bottomH=%.1f delta=%.1f off=%.1f",
			            screenFrame.size.width, screenFrame.size.height,
			            coverSheetView.safeAreaInsets.bottom,
			            stockY, CGRectGetHeight(stockRow),
			            CGRectGetMinY(row), CGRectGetHeight(row),
			            delta, SokoPrefWidgetOffset());
		}
	}
}

- (void)applyDateViewScale:(CSCoverSheetView *)coverSheetView {
	double scale = [coverSheetView respondsToSelector:@selector(dateViewScale)] ? coverSheetView.dateViewScale : 1.0;
	if (scale <= 0.0 || fabs(scale - 1.0) <= 0.0001) return;

	CGRect bounds = coverSheetView.bounds;
	CGPoint pivot = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
	CGPoint center = self.hostView.center;
	CGFloat tx = (pivot.x - center.x) * (1.0 - scale);
	CGFloat ty = (pivot.y - center.y) * (1.0 - scale);
	self.hostView.transform = CGAffineTransformMake(scale, 0.0, 0.0, scale, tx, ty);
}

- (CSProminentDisplayViewController *)prominentDisplayViewController {
	return SokoIvarObject(self.coverSheetViewController.dateViewController, "_prominentDisplayViewController");
}

- (void)syncVibrancy {
	CSProminentDisplayView *prominentView = (CSProminentDisplayView *)[self prominentDisplayViewController].viewIfLoaded;
	if (![prominentView respondsToSelector:@selector(vibrancyEffectView)]) return;

	BSUIVibrancyEffectView *source = (BSUIVibrancyEffectView *)prominentView.vibrancyEffectView;
	BSUIVibrancyEffectView *host = self.hostView;
	if (![source respondsToSelector:@selector(configuration)] || ![host respondsToSelector:@selector(setConfiguration:)]) return;

	if (source.configuration) host.configuration = source.configuration;
	if ([source respondsToSelector:@selector(contentType)] && [host respondsToSelector:@selector(setContentType:)]) {
		host.contentType = source.contentType;
	}
}

- (void)syncRowAlpha {
	CSProminentDisplayViewController *prominent = [self prominentDisplayViewController];
	if (!self.hostView || ![prominent respondsToSelector:@selector(complicationRowAlpha)]) return;

	self.hostView.alpha = prominent.complicationRowAlpha;
}

- (void)prominentDisplayContentAlphaDidChange:(NSNotification *)notification {
	if (self.attached && notification.object == [self prominentDisplayViewController]) [self syncRowAlpha];
}

- (void)prominentDisplayVibrancyDidChange:(NSNotification *)notification {
	if (self.attached && notification.object == [self prominentDisplayViewController]) [self syncVibrancy];
}

@end
