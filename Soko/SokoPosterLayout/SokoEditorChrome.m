#import "SokoEditorChrome.h"
#import "SokoLayoutSwipeHandler.h"
#import "../SokoLog.h"
#import "../SokoFileLog.h"

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

+ (void)registerEditorRootViewController:(PREditorRootViewController *)controller {
	if (!gEditorRootViewControllers) gEditorRootViewControllers = [NSHashTable weakObjectsHashTable];
	[gEditorRootViewControllers addObject:controller];

	CGRect frame = [NSClassFromString(@"CSProminentLayoutController") frameForElements:kSokoComplicationRowElement variant:kSokoReticleVariant];
	if (!CGRectIsNull(frame)) {
		objc_setAssociatedObject(controller, kSokoReticleBaseMinYKey, @(CGRectGetMinY(frame)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	[self updateLookControlsForEditorRootViewController:controller];
}

+ (void)update {
	for (PREditorRootViewController *controller in gEditorRootViewControllers.allObjects) {
		[self updateReticleForEditorRootViewController:controller];
		[self updateLookControlsForEditorRootViewController:controller];
	}

	for (PREditingSceneViewController *controller in [SokoPosterLayout editingSceneViewControllers]) {
		[self updateAddGestureForEditingSceneViewController:controller];
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
	// 1.2.1-99 · 节流：这个方法在每次 relayoutAnimated 都被调用，放开 SokoTrace 上限后
	// 会按 50ms 一条连续发几十条，把 300 行环瞬间冲掉。3 秒一次足够定位虚线框。
	static CFTimeInterval lastDump = 0.0;
	CFTimeInterval nowD = CACurrentMediaTime();
	if (nowD - lastDump < 3.0) return;
	lastDump = nowD;

	UIView *root = controller.viewIfLoaded;
	if (!root || !root.window) return;

	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	CGRect stock = [layoutClass frameForElements:kSokoComplicationRowElement variant:kSokoReticleVariant];
	if (CGRectIsNull(stock)) { SokoTrace(39, -3); return; }

	CGFloat rowW = CGRectGetWidth(stock), rowH = CGRectGetHeight(stock), stockMid = CGRectGetMidY(stock);
	if (rowW < 1.0 || rowH < 1.0) { SokoTrace(39, -4); return; }

	NSMutableArray<NSString *> *names = [NSMutableArray array];
	NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
	NSInteger visited = 0;

	while (stack.count && visited < 800 && names.count < 6) {
		UIView *v = stack.lastObject;
		[stack removeLastObject];
		visited++;

		if (v != root && v.window) {
			CGRect r = [v convertRect:v.bounds toView:root.window];
			BOOL sizeOK = fabs(CGRectGetWidth(r) - rowW) < rowW * 0.45 &&
			              fabs(CGRectGetHeight(r) - rowH) < rowH * 0.7;
			BOOL posOK = fabs(CGRectGetMidY(r) - stockMid) < 16.0;
			if (sizeOK && posOK) [names addObject:NSStringFromClass([v class])];
		}

		for (UIView *sub in v.subviews) [stack addObject:sub];
	}

	// 39 = 候选数量（负数表示前置条件不满足）
	SokoTrace(39, (long)names.count);

	// 逐个类名按 50ms 间隔发送，避免连续通知被系统合并（之前共用一条名字只剩 -1）
	__block NSUInteger step = 0;
	for (NSString *name in names) {
		const char *utf8 = name.UTF8String ?: "";
		NSUInteger len = MIN([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding], (NSUInteger)21);
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

#pragma mark - 1.2.1-94 完成/取消按钮监听



