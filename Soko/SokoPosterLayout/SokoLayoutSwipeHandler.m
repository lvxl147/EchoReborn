#import "SokoLayoutSwipeHandler.h"
#import "../SokoLog.h"
#import "../SokoFileLog.h"

static const CGFloat kSokoLayoutSwipeDistance = 30.0;
static const CGFloat kSokoLayoutSwipeVelocity = 300.0;
static const CGFloat kSokoLayoutSwipeSlop = 24.0;
static const NSTimeInterval kSokoLayoutSwipeMaximumHold = 0.3;

@interface SokoLayoutSwipeHandler ()
@property (nonatomic, weak) PREditingSceneViewController *editingSceneViewController;
@property (nonatomic, weak) UIViewController *complicationContainerViewController;
@property (nonatomic) NSTimeInterval touchTimestamp;
@end

static CGPoint SokoScreenPoint(UIView *view, CGPoint point) {
	UIScreen *screen = view.window.screen;
	return screen ? [view convertPoint:point toCoordinateSpace:screen.coordinateSpace] : point;
}

@implementation SokoLayoutSwipeHandler

+ (void)installOnEditingSceneViewController:(PREditingSceneViewController *)controller {
	SokoLayoutSwipeHandler *handler = [self new];
	handler.editingSceneViewController = controller;
	[handler installOnView:controller.view];
	SokoTrace(5, 1);
}

+ (void)installOnComplicationContainerViewController:(UIViewController *)controller {
	if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.PosterBoard"]) {
		SokoFileLog(@"SWIPE-SKIP container: bid=%@", NSBundle.mainBundle.bundleIdentifier);
		return;
	}

	SokoLayoutSwipeHandler *handler = [self new];
	handler.complicationContainerViewController = controller;
	[handler installOnView:controller.view];
	SokoTrace(6, 1);
}

- (void)installOnView:(UIView *)view {
	UIPanGestureRecognizer *swipe = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipe:)];
	swipe.delegate = self;
	swipe.maximumNumberOfTouches = 1;

	objc_setAssociatedObject(swipe, @selector(handleSwipe:), self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[view addGestureRecognizer:swipe];

	// 1.2.1-69 · 手势装在哪一层，装了没有
	SokoFileLog(@"SWIPE-INSTALL view=%@ proc=%@",
	            NSStringFromClass([view class]), NSProcessInfo.processInfo.processName);
}

- (PREditingSceneViewController *)editor {
	if (self.editingSceneViewController) return self.editingSceneViewController;

	return [SokoPosterLayout editingSceneViewControllerForComplicationContainerViewController:self.complicationContainerViewController];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
	self.touchTimestamp = touch.timestamp;

	// 1.2.1-69 · 节流 1s：确认触摸到底有没有投递到这个 pan（没有 = 被别的视图/手势吃掉）
	static CFTimeInterval lastTouchLog = 0.0;
	CFTimeInterval now = CACurrentMediaTime();
	if (now - lastTouchLog > 1.0) {
		lastTouchLog = now;
		CGPoint point = [touch locationInView:gestureRecognizer.view];
		SokoFileLog(@"SWIPE-TOUCH view=%@ point=(%.1f,%.1f)", NSStringFromClass([gestureRecognizer.view class]), point.x, point.y);
		SokoTrace(7, (long)point.y);
	}
	return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
	PREditingSceneViewController *controller = [self editor];
	CGFloat inset = SokoDockGeometryBottomInset();
	UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
	UIView *view = pan.view;
	CGPoint velocity = [pan velocityInView:view];
	CGRect row = [SokoPosterLayout editingRowFrame];

	// 1.2.1-69 · 逐条记录拒绝原因：这轮就是要看清是哪一个门闩挡住了拖动。
	if (!controller) {
		SokoFileLog(@"SWIPE-BEGIN reject=no-editor inset=%.1f", inset);
		return NO;
	}
	if (![SokoPosterLayout canSwipeEditingSceneViewController:controller]) {
		long mask = (controller.presentedViewController ? 1 : 0) | (isnan(inset) ? 2 : 0) |
		            ([SokoPosterLayout isDodging] ? 4 : 0) | ([SokoPosterLayout editingSceneViewControllerIsDismissing:controller] ? 8 : 0) |
		            (SokoIsPortrait(controller.view.bounds) ? 0 : 16);
		SokoTrace(9, mask);
		SokoFileLog(@"SWIPE-BEGIN reject=canSwipe presented=%@ inset=%d(isnan) dodging=%d dismissing=%d portrait=%d",
		            NSStringFromClass([controller.presentedViewController class]),
		            (int)isnan(inset), (int)[SokoPosterLayout isDodging],
		            (int)[SokoPosterLayout editingSceneViewControllerIsDismissing:controller],
		            (int)SokoIsPortrait(controller.view.bounds));
		return NO;
	}

	NSTimeInterval hold = [NSProcessInfo processInfo].systemUptime - self.touchTimestamp;
	if (hold > kSokoLayoutSwipeMaximumHold) {
		SokoTrace(10, (long)(hold * 1000.0));
		SokoFileLog(@"SWIPE-BEGIN reject=hold %.3fs > %.2fs", hold, kSokoLayoutSwipeMaximumHold);
		return NO;
	}

	if (fabs(velocity.y) <= fabs(velocity.x)) {
		SokoTrace(11, (long)velocity.y);
		SokoFileLog(@"SWIPE-BEGIN reject=not-vertical vy=%.1f vx=%.1f", velocity.y, velocity.x);
		return NO;
	}

	BOOL bottom = [SokoPosterLayout editingSceneViewControllerUsesBottomLayout:controller];
	if (bottom ? velocity.y >= 0.0 : velocity.y <= 0.0) {
		SokoTrace(12, (long)velocity.y);
		SokoFileLog(@"SWIPE-BEGIN reject=direction bottom=%d vy=%.1f", (int)bottom, velocity.y);
		return NO;
	}

	if (CGRectIsNull(row)) {
		SokoTrace(13, 1);
		SokoFileLog(@"SWIPE-BEGIN reject=row-null inset=%.1f", inset);
		return NO;
	}

	CGPoint translation = [pan translationInView:view];
	CGPoint location = [pan locationInView:view];
	CGPoint start = SokoScreenPoint(view, CGPointMake(location.x - translation.x, location.y - translation.y));
	CGRect band = CGRectInset(row, 0.0, -kSokoLayoutSwipeSlop);
	if (!CGRectContainsPoint(band, start)) {
		SokoTrace(14, (long)start.y);
		SokoFileLog(@"SWIPE-BEGIN reject=outside-row start=(%.1f,%.1f) row=(%.1f,%.1f,%.1fx%.1f) band=(%.1f,%.1f,%.1fx%.1f)",
		            start.x, start.y, row.origin.x, row.origin.y, row.size.width, row.size.height,
		            band.origin.x, band.origin.y, band.size.width, band.size.height);
		return NO;
	}

	SokoTrace(8, (long)CGRectGetMinY(row));
	SokoFileLog(@"SWIPE-BEGIN accept bottom=%d start=(%.1f,%.1f) row=(%.1f,%.1f,%.1fx%.1f) inset=%.1f",
	            (int)bottom, start.x, start.y, row.origin.x, row.origin.y, row.size.width, row.size.height, inset);
	return YES;
}

- (void)handleSwipe:(UIPanGestureRecognizer *)pan {
	if (pan.state != UIGestureRecognizerStateEnded) return;

	PREditingSceneViewController *controller = [self editor];
	if (![SokoPosterLayout canSwipeEditingSceneViewController:controller]) {
		SokoFileLog(@"SWIPE-END reject=canSwipe");
		return;
	}

	BOOL bottom = [SokoPosterLayout editingSceneViewControllerUsesBottomLayout:controller];
	CGFloat direction = bottom ? -1.0 : 1.0;
	CGFloat distance = [pan translationInView:pan.view].y * direction;
	CGFloat velocity = [pan velocityInView:pan.view].y * direction;
	SokoFileLog(@"SWIPE-END bottom=%d distance=%.1f velocity=%.1f threshold=(%.0f/%.0f)",
	            (int)bottom, distance, velocity, kSokoLayoutSwipeDistance, kSokoLayoutSwipeVelocity);
	if (distance < kSokoLayoutSwipeDistance && velocity < kSokoLayoutSwipeVelocity) return;

	SokoTrace(15, (long)bottom);   // payload = 切换前的状态（1=原为底部）
	[SokoPosterLayout setUsesBottomLayout:!bottom forEditingSceneViewController:controller];

	// 1.2.1-68 · 判据 #5/#6：滑动是否被识别、最终状态是什么
	ERSokoLog(@"SOKO-SWIPE before=%d after=%d distance=%.1f velocity=%.1f proc=%@",
	          (int)bottom, (int)!bottom, distance, velocity,
	          NSProcessInfo.processInfo.processName);
}

@end
