#import "SokoEditorChrome.h"
#import "SokoLayoutSwipeHandler.h"
#import "../SokoLog.h"
#import "../SokoFileLog.h"
#import "../SokoDockGeometry/SokoDockGeometry.h"

static const CGFloat kSokoLookNameToPageControlSpacing = 10.0;

static const void *kSokoReticleBaseMinYKey = &kSokoReticleBaseMinYKey;
static const void *kSokoStockPageControlConstraintKey = &kSokoStockPageControlConstraintKey;
static const void *kSokoDockPageControlConstraintKey = &kSokoDockPageControlConstraintKey;

static NSHashTable<PREditorRootViewController *> *gEditorRootViewControllers;

static const void *kSokoWatchedButtonKey = &kSokoWatchedButtonKey;

@interface SokoEditorButtonWatcher : NSObject
+ (instancetype)shared;
- (void)tapped:(UIButton *)button;
@end

@implementation SokoEditorButtonWatcher
+ (instancetype)shared {
	static SokoEditorButtonWatcher *shared = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [SokoEditorButtonWatcher new]; });
	return shared;
}

// 1.2.1-104 · 取消按钮：点了就通知 SpringBoard 回滚到"进编辑器之前的值"
- (void)cancelTapped:(id)sender {
	SokoTrace(26, 9999);
	SokoEditorRequestRevert();
}

- (void)tapped:(UIButton *)button {
	NSString *title = [button titleForState:UIControlStateNormal] ?: button.titleLabel.text ?: @"";
	CGFloat offset = [SokoPosterLayout editingRowOffset];

	BOOL isDone = [@[@"完成", @"Done", @"Save", @"保存"] containsObject:title];
	BOOL isCancel = [@[@"取消", @"Cancel"] containsObject:title];

	SokoTrace(50, isDone ? 1 : (isCancel ? 2 : 0));

	if (isDone && !isnan(offset)) {
		// 只有"完成"才把编辑值交给 SpringBoard 落盘（写入当前壁纸的独立配置）
		SokoEditorRequestRowOffset(offset);
		// 20 = 这条"完成"来自按标题找到的 UIButton（与 17 / 19 区分提交来源）
		SokoTrace(20, (long)llround(offset));
		SokoFileLog(@"EDITOR-DONE-OFFSET %.1f", offset);
	}
}
@end

@implementation SokoEditorChrome

// 1.2.1-104 · 边框：直接移动系统的虚线框视图。
//   为什么必须这么做：60~63 的实测数据显示
//     · complicationRowElementEditingReticleFrameWithBoundingRect: **确实被调用**；
//     · 我们返回的 frame（63=719）正确；
//     · 但视图树扫描（39/40 → 类名解出来是 **UIView**）在"系统原位"附近
//       仍有一个尺寸≈组件行的 UIView —— 也就是真正的虚线框**根本没被那个
//       返回值驱动**，它一直待在 221（系统原位）。
//   于是：找出尺寸≈组件行、且当前仍停在"系统原位"附近的视图，
//   用 transform 平移 (adjusted - stock)。已经跟着走的视图不动（避免二次位移）。
static NSHashTable<UIView *> *gReticleViews;

+ (void)installCancelButtonWatcher:(UIViewController *)controller {
	if (!controller || !controller.isViewLoaded) return;

	for (NSString *key in @[@"cancelButton", @"_cancelButton", @"cancelBarButtonItem"]) {
		if (![controller respondsToSelector:NSSelectorFromString(key)]) continue;

		id button = nil;
		@try { button = [controller valueForKey:key]; } @catch (__unused NSException *e) {}
		if (![button isKindOfClass:[UIButton class]]) continue;
		if (objc_getAssociatedObject(button, kSokoWatchedButtonKey)) continue;

		objc_setAssociatedObject(button, kSokoWatchedButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[button addTarget:[SokoEditorButtonWatcher shared]
		           action:@selector(cancelTapped:)
		 forControlEvents:UIControlEventTouchUpInside];
		SokoTrace(24, 1);
		return;
	}
	SokoTrace(24, 0);
}

// 1.2.1-108 · 用户截图确认：虚线框把「日期 + 大时钟 + 空槽」整个框住，高度远大于
//   组件行（94pt）—— 所以按"高度≈94"筛是**永远筛不到它的**（1.2.1-107 的 44=9/13、
//   45=1/3 抓到的都不是它）。
//   换成精准定位：虚线框就是一个 CAShapeLayer 的 lineDashPattern，全窗口只有它有。
static void SokoCollectDashedViews(UIView *view, NSMutableArray<UIView *> *out) {
	if (!view) return;

	CALayer *layer = view.layer;
	if ([layer isKindOfClass:[CAShapeLayer class]] && ((CAShapeLayer *)layer).lineDashPattern.count) [out addObject:view];
	for (CALayer *sub in layer.sublayers) {
		if ([sub isKindOfClass:[CAShapeLayer class]] && ((CAShapeLayer *)sub).lineDashPattern.count) { [out addObject:view]; break; }
	}

	for (UIView *subview in view.subviews) SokoCollectDashedViews(subview, out);
}

// 1.2.1-109 · 1.2.1-108 的 47=0 证明系统**不是**用 CAShapeLayer 虚线画的（多半是
//   拉伸的虚线贴图）。改走最正规的路：**直接拿系统自己的 reticle 视图**。
//   PREditorRootViewController 有 graphicComplicationsReticleView（SokoPrivate.h 有声明，
//   METHODS 表也确认这个类存在），只是一直没拿到它的实例 —— 它不在我们注册的那两个
//   VC 里。这里从 window 的 VC 树把它翻出来。
static void SokoCollectViewControllers(UIViewController *controller, NSMutableArray<UIViewController *> *out) {
	if (!controller) return;

	[out addObject:controller];
	for (UIViewController *child in controller.childViewControllers) SokoCollectViewControllers(child, out);
	if (controller.presentedViewController) SokoCollectViewControllers(controller.presentedViewController, out);
}

static NSArray<UIView *> *SokoSystemReticleViews(UIWindow *window) {
	Class editorRootClass = NSClassFromString(@"PREditorRootViewController");
	if (!editorRootClass || !window.rootViewController) return @[];

	NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
	SokoCollectViewControllers(window.rootViewController, controllers);

	NSMutableArray<UIView *> *views = [NSMutableArray array];
	for (UIViewController *controller in controllers) {
		if (![controller isKindOfClass:editorRootClass]) continue;
		if (![controller respondsToSelector:@selector(graphicComplicationsReticleView)]) continue;

		UIView *reticle = nil;
		@try { reticle = [controller valueForKey:@"graphicComplicationsReticleView"]; } @catch (__unused NSException *e) {}
		if (reticle) [views addObject:reticle];
	}
	return views;
}

+ (void)huntReticleViewsForHostViewController:(UIViewController *)controller {
	UIView *root = controller.viewIfLoaded;
	UIWindow *window = root.window;
	if (!root || !window) return;

	// 1.2.1-113 · **锚点必须用"系统原位"**。
	//   1.2.1-110 改成用"当前 reticle 矩形"当位置基准，这是个隐蔽的反向 bug：
	//   滑到底部时当前 reticle 也到了 728，于是只在 728 附近找 —— 找到的是
	//   **跟着组件走的内容视图**（-112 实锤 V:UIView|30,728,370x76），而真正的
	//   虚线框还停在顶部 212，永远不进搜索范围 → 永远平移不到它。
	//   1.2.1-107 用对了锚点（frameForElements:reticleVariant = 系统原位），
	//   但那时只扫了 8 个视图的子树；两个 bug 互补着把这条路堵死了十几个版本。
	//   现在：整窗口扫描 + 系统原位锚点。
	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	CGRect anchor = [layoutClass frameForElements:kSokoComplicationRowElement variant:kSokoReticleVariant];
	if (CGRectIsNull(anchor)) return;

	CGFloat w = CGRectGetWidth(anchor), h = CGRectGetHeight(anchor), mid = CGRectGetMidY(anchor);
	if (w < 1.0 || h < 1.0) return;

	NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
	NSInteger visited = 0;
	NSMutableArray<UIView *> *matches = [NSMutableArray array];

	while (stack.count && visited < 4000) {
		UIView *view = stack.lastObject;
		[stack removeLastObject];
		visited++;

		if (view != window) {
			CGRect rect = [view convertRect:view.bounds toView:window];
			BOOL sizeOK = fabs(CGRectGetWidth(rect) - w) < w * 0.25 &&
			              fabs(CGRectGetHeight(rect) - h) < h * 0.25;
			BOOL parkedAtStock = fabs(CGRectGetMidY(rect) - mid) < 40.0;
			if (sizeOK && parkedAtStock) [matches addObject:view];
		}

		for (UIView *subview in view.subviews) [stack addObject:subview];
	}

	// 叶子优先（贴图/自绘框都是叶子）
	NSMutableArray<UIView *> *leaves = [NSMutableArray array];
	for (UIView *view in matches) if (view.subviews.count == 0) [leaves addObject:view];
	NSArray<UIView *> *picked = leaves.count ? leaves : matches;

	if (!gReticleViews) gReticleViews = [NSHashTable weakObjectsHashTable];
	BOOL changed = NO;
	for (UIView *view in picked) {
		if (![gReticleViews containsObject:view]) { [gReticleViews addObject:view]; changed = YES; }
	}

	static CFTimeInterval lastHuntLog = 0.0;
	CFTimeInterval nowHunt = CACurrentMediaTime();
	if (nowHunt - lastHuntLog > 1.0) {
		lastHuntLog = nowHunt;
		SokoTrace(42, (long)visited);
		SokoTrace(43, (long)llround(h));
		SokoTrace(44, (long)matches.count);
		SokoTrace(45, (long)leaves.count);
		SokoTrace(46, (long)gReticleViews.allObjects.count);
	}
	if (changed) SokoTrace(28, 1);
}
+ (void)reapplyReticleTransform {
	CGFloat delta = [SokoPosterLayout editingRowDelta];
	if (isnan(delta) || !gReticleViews) return;

	for (UIView *view in gReticleViews.allObjects) {
		if (!view.window) continue;
		if (fabs(view.transform.ty - delta) < 0.5) continue;
		view.transform = CGAffineTransformMakeTranslation(0.0, delta);
	}
}

+ (void)updateReticleViewsForHostViewController:(UIViewController *)controller {
	[self huntReticleViewsForHostViewController:controller];

	CGFloat delta = [SokoPosterLayout editingRowDelta];
	if (isnan(delta)) return;

	static CFTimeInterval lastDeltaLog = 0.0;
	CFTimeInterval now = CACurrentMediaTime();
	if (now - lastDeltaLog > 1.0) {
		lastDeltaLog = now;
		SokoTrace(26, (long)llround(delta));
		SokoTrace(27, (long)gReticleViews.allObjects.count);
	}

	for (UIView *view in gReticleViews.allObjects) {
		if (fabs(view.transform.ty - delta) < 0.5) continue;
		view.transform = CGAffineTransformMakeTranslation(0.0, delta);
	}
}

+ (void)registerEditorRootViewController:(PREditorRootViewController *)controller {
	if (!gEditorRootViewControllers) gEditorRootViewControllers = [NSHashTable weakObjectsHashTable];
	[gEditorRootViewControllers addObject:controller];

	// 1.2.1-104 · 取消按钮：PREditorRootViewController 的方法表里有 setCancelButton:
	//   （METHODS 实锤），按 KVC 取出来；若是 UIButton 就挂 target，点了回滚。
	__weak PREditorRootViewController *weakController = controller;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[self installCancelButtonWatcher:weakController];
	});
	[self installCancelButtonWatcher:controller];

	CGRect frame = [NSClassFromString(@"CSProminentLayoutController") frameForElements:kSokoComplicationRowElement variant:kSokoReticleVariant];
	if (!CGRectIsNull(frame)) {
		objc_setAssociatedObject(controller, kSokoReticleBaseMinYKey, @(CGRectGetMinY(frame)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	[self updateLookControlsForEditorRootViewController:controller];
}

+ (void)update {
	for (PREditorRootViewController *controller in gEditorRootViewControllers.allObjects) {
		[self updateReticleForEditorRootViewController:controller];
		// 1.2.1-105 · 真正的"让虚线框跟着走"：平移那个停在原位的 UIView。
		//   注意 PREditorRootViewController loadView 钩子在 iOS 17.2.1 上**一次都没触发**
		//   （trace 24 全为零），所以这里必须再挂到已确认会注册的编辑场景 VC 上。
		[self updateReticleViewsForHostViewController:controller];
		[self updateLookControlsForEditorRootViewController:controller];
	}

	for (PREditingSceneViewController *controller in [SokoPosterLayout editingSceneViewControllers]) {
		[self updateAddGestureForEditingSceneViewController:controller];
		// 1.2.1-122 · 自绘虚线框方案已按用户要求撤回（-118 ~ -121）
		// 1.2.1-105 · 虚线框查找/平移挂在这里（编辑场景 VC 已证明必然注册，code 4）。
		//   上一版这行被误插进了上面那个永不执行的编辑器根循环，所以 26/27/28 全为零。
		[self updateReticleViewsForHostViewController:controller];
	}
}

+ (void)updateAddGestureForEditingSceneViewController:(PREditingSceneViewController *)controller {
	UIView *gestureView = [controller respondsToSelector:@selector(complicationsAddGestureView)] ? controller.complicationsAddGestureView : nil;
	CGRect frame = [SokoPosterLayout editingRowFrame];
	if (gestureView && !CGRectIsNull(frame)) gestureView.frame = frame;

	if ([controller respondsToSelector:@selector(_updateAddComplicationsTapGestureAllowed)]) {
		[controller _updateAddComplicationsTapGestureAllowed];
	}
}

+ (void)updateReticleForEditorRootViewController:(PREditorRootViewController *)controller {
	// 1.2.1-91 · 只读探针：边框到底是被隐藏还是被裁剪。
	// 31=alpha×100 32=hidden 33=reticle.y 34=reticle.h 35=父clips 36=父y 37=父h 38=裁剪祖先数
	// 1.2.1-103 · 加 1 秒节流（上一版它每次 relayout 都发 8 条，把 500 行环冲掉，
	//   60~63 的虚线框数据因此一条都没留下来）；并新增 22/23：
	//   22=虚线框在窗口坐标里的 y，23=组件行在窗口坐标里的 y —— 两者应当同步移动。
	{
		UIView *probe = [controller respondsToSelector:@selector(graphicComplicationsReticleView)] ? controller.graphicComplicationsReticleView : nil;
		if (probe) {
			static CFTimeInterval lastReticleLog = 0.0;
			CFTimeInterval nowReticle = CACurrentMediaTime();
			if (nowReticle - lastReticleLog > 1.0) {
				lastReticleLog = nowReticle;

				UIWindow *window = probe.window;
				CGRect inWindow = window ? [probe convertRect:probe.bounds toCoordinateSpace:window] : probe.frame;
				SokoTrace(22, (long)llround(CGRectGetMinY(inWindow)));

				CGRect rowRect = [NSClassFromString(@"CSProminentLayoutController") frameForElements:kSokoComplicationRowElement variant:kSokoEditingVariant];
				SokoTrace(23, CGRectIsNull(rowRect) ? -9999 : (long)llround(CGRectGetMinY(rowRect)));

				SokoTrace(31, (long)llround(probe.alpha * 100.0));
				SokoTrace(32, probe.hidden ? 1 : 0);
				SokoTrace(33, (long)llround(probe.frame.origin.y));
				SokoTrace(34, (long)llround(probe.frame.size.height));
				UIView *superview = probe.superview;
				SokoTrace(35, (superview.clipsToBounds ? 1 : 0));
				SokoTrace(36, (long)llround(superview.frame.origin.y));
				SokoTrace(37, (long)llround(superview.frame.size.height));
				NSInteger clippedAncestors = 0;
				for (UIView *v = superview; v; v = v.superview) {
					if (v.clipsToBounds) clippedAncestors++;
				}
				SokoTrace(38, clippedAncestors);
			}
		}
	}

	// 1.2.1-90 · 上游实现：先让系统按它自己的行框重算（它会调用我们 hook 的
	// complicationRowElementEditingReticleFrameWithBoundingRect:），有这个方法就直接返回；
	// 只有系统没有该方法时，才用 transform 兜底。
	if ([controller respondsToSelector:@selector(updateReticleViewFrames)]) {
		if (controller.isViewLoaded) [controller updateReticleViewFrames];
		return;
	}

	UIView *reticle = [controller respondsToSelector:@selector(graphicComplicationsReticleView)] ? controller.graphicComplicationsReticleView : nil;
	NSNumber *base = objc_getAssociatedObject(controller, kSokoReticleBaseMinYKey);
	if (!reticle || !base) return;

	CGRect target = [NSClassFromString(@"CSProminentLayoutController") frameForElements:kSokoComplicationRowElement variant:kSokoReticleVariant];
	if (CGRectIsNull(target)) return;

	reticle.transform = CGAffineTransformMakeTranslation(0.0, CGRectGetMinY(target) - base.doubleValue);
}

+ (NSLayoutConstraint *)stockPageControlConstraintForEditorRootViewController:(PREditorRootViewController *)controller {
	NSLayoutConstraint *stock = objc_getAssociatedObject(controller, kSokoStockPageControlConstraintKey);
	if (stock) return stock;

	UIView *pageControl = controller.pageControl;
	UIView *divider = controller.controlsDividerVibrancyView;
	UIView *root = controller.viewIfLoaded;

	for (UIView *view = pageControl.superview; view && !stock; view = view.superview) {
		for (NSLayoutConstraint *constraint in view.constraints) {
			BOOL pageControlBottom = constraint.firstItem == pageControl && constraint.firstAttribute == NSLayoutAttributeBottom;
			BOOL dividerTop = constraint.secondItem == divider && constraint.secondAttribute == NSLayoutAttributeTop;
			if (pageControlBottom && dividerTop) {
				stock = constraint;
				break;
			}
		}

		if (view == root) break;
	}

	if (stock) objc_setAssociatedObject(controller, kSokoStockPageControlConstraintKey, stock, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return stock;
}

+ (NSLayoutConstraint *)dockPageControlConstraintForEditorRootViewController:(PREditorRootViewController *)controller {
	NSLayoutConstraint *dock = objc_getAssociatedObject(controller, kSokoDockPageControlConstraintKey);
	if (dock) return dock;

	dock = [controller.pageControl.bottomAnchor constraintEqualToAnchor:controller.view.bottomAnchor];
	objc_setAssociatedObject(controller, kSokoDockPageControlConstraintKey, dock, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return dock;
}

+ (CGFloat)lookControlsHeightForEditorRootViewController:(PREditorRootViewController *)controller {
	UIView *lookName = controller.lookNameLabel;
	CGFloat lookNameHeight = lookName ? [lookName systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].height : 0.0;

	return lookNameHeight + kSokoLookNameToPageControlSpacing + controller.pageControl.intrinsicContentSize.height;
}

+ (void)updateLookControlsForEditorRootViewController:(PREditorRootViewController *)controller {
	BOOL hasControls = [controller respondsToSelector:@selector(controlsDividerVibrancyView)] &&
		[controller respondsToSelector:@selector(pageControl)] &&
		[controller respondsToSelector:@selector(lookNameLabel)];
	UIView *root = controller.viewIfLoaded;
	if (!hasControls || !root || !controller.pageControl || !controller.controlsDividerVibrancyView) return;

	NSLayoutConstraint *stock = [self stockPageControlConstraintForEditorRootViewController:controller];
	if (!stock) return;

	NSLayoutConstraint *dock = [self dockPageControlConstraintForEditorRootViewController:controller];
	CGRect bounds = CGRectIsEmpty(root.bounds) ? UIScreen.mainScreen.bounds : root.bounds;
	CGFloat inset = SokoDockGeometryBottomInset();
	BOOL docked = [SokoPosterLayout usesBottomEditingRow] && !isnan(inset) && SokoIsPortrait(bounds);

	if (docked) {
		CGFloat height = [self lookControlsHeightForEditorRootViewController:controller];
		dock.constant = round(kSokoDockBottomToButtonCenter - inset + height / 2.0);
	}

	if (stock.active == !docked && dock.active == docked) return;

	if (docked) {
		stock.active = NO;
		dock.active = YES;
	} else {
		dock.active = NO;
		stock.active = YES;
	}

	[root layoutIfNeeded];
}


+ (void)dumpCandidateViewsInEditingSceneViewController:(PREditingSceneViewController *)controller {
	// 1.2.1-120 · 锚定"系统原位"（系统的框一直停在那儿），把该位置的候选视图
	//   类名+坐标全部回传 —— 上次用"当前 reticle 矩形"锚定，滑走之后系统的框
	//   就不在搜索范围里了，所以一直定位不到它。
	static CFTimeInterval lastDump = 0.0;
	CFTimeInterval nowD = CACurrentMediaTime();
	if (nowD - lastDump < 5.0) return;
	lastDump = nowD;

	UIView *root = controller.viewIfLoaded;
	if (!root || !root.window) { SokoTrace(39, -1); return; }
	UIWindow *window = root.window;

	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	CGRect anchor = [layoutClass frameForElements:kSokoComplicationRowElement variant:kSokoReticleVariant];
	if (CGRectIsNull(anchor)) { SokoTrace(39, -2); return; }

	CGFloat w = CGRectGetWidth(anchor), h = CGRectGetHeight(anchor), mid = CGRectGetMidY(anchor);

	NSMutableArray<NSString *> *names = [NSMutableArray array];
	NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
	NSInteger visited = 0;

	while (stack.count && visited < 4000 && names.count < 8) {
		UIView *v = stack.lastObject;
		[stack removeLastObject];
		visited++;

		if (v != window) {
			CGRect r = [v convertRect:v.bounds toView:window];
			BOOL sizeOK = fabs(CGRectGetWidth(r) - w) < w * 0.30 && fabs(CGRectGetHeight(r) - h) < h * 0.45;
			BOOL posOK = fabs(CGRectGetMidY(r) - mid) < 45.0;
			if (sizeOK && posOK) {
				[names addObject:[NSString stringWithFormat:@"%@|%.0f,%.0f,%.0fx%.0f",
				                  NSStringFromClass([v class]), r.origin.x, r.origin.y, r.size.width, r.size.height]];
			}
		}

		for (UIView *sub in v.subviews) [stack addObject:sub];
	}

	SokoTrace(39, (long)names.count);

	__block NSUInteger step = 0;
	for (NSString *name in names) {
		const char *utf8 = name.UTF8String ?: "";
		NSUInteger len = MIN([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding], (NSUInteger)24);
		for (NSUInteger i = 0; i < len; i += 3) {
			long packed = 0;
			for (NSUInteger j = 0; j < 3; j++) {
				packed = (packed << 8) | (i + j < len ? (unsigned char)utf8[i + j] : 0);
			}
			NSUInteger delay = step++;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC * (delay + 1))),
			               dispatch_get_main_queue(), ^{ SokoTrace(40, packed); });
		}
		NSUInteger sepDelay = step++;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC * (sepDelay + 1))),
		               dispatch_get_main_queue(), ^{ SokoTrace(41, -1); });
	}
}

+ (void)installEditorButtonWatchers:(PREditingSceneViewController *)controller {
	UIView *root = controller.viewIfLoaded;
	if (!root) return;

	NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
	NSInteger visited = 0;
	while (stack.count && visited < 600) {
		UIView *view = stack.lastObject;
		[stack removeLastObject];
		visited++;

		if ([view isKindOfClass:[UIButton class]]) {
			UIButton *button = (UIButton *)view;
			NSString *title = [button titleForState:UIControlStateNormal] ?: button.titleLabel.text ?: @"";
			BOOL interesting = [@[@"完成", @"Done", @"Save", @"保存", @"取消", @"Cancel"] containsObject:title];
			if (interesting && !objc_getAssociatedObject(button, kSokoWatchedButtonKey)) {
				objc_setAssociatedObject(button, kSokoWatchedButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				[button addTarget:[SokoEditorButtonWatcher shared]
				           action:@selector(tapped:)
				 forControlEvents:UIControlEventTouchUpInside];
			}
		}

		for (UIView *sub in view.subviews) [stack addObject:sub];
	}
}


@end
