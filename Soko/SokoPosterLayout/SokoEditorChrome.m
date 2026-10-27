#import "SokoEditorChrome.h"
#import "../SokoLog.h"

static const CGFloat kSokoLookNameToPageControlSpacing = 10.0;

static const void *kSokoReticleBaseMinYKey = &kSokoReticleBaseMinYKey;
static const void *kSokoStockPageControlConstraintKey = &kSokoStockPageControlConstraintKey;
static const void *kSokoDockPageControlConstraintKey = &kSokoDockPageControlConstraintKey;

static NSHashTable<PREditorRootViewController *> *gEditorRootViewControllers;

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
	// 1.2.1-78 · 先让系统按它自己的行位置重算（它会覆盖我们的 frame 修正），
	// 再用 transform 叠一次位移 —— 这是上游的兜底路径，系统重算也压不掉。
	if ([controller respondsToSelector:@selector(updateReticleViewFrames)]) {
		if (controller.isViewLoaded) [controller updateReticleViewFrames];
	}

	UIView *reticle = [controller respondsToSelector:@selector(graphicComplicationsReticleView)] ? controller.graphicComplicationsReticleView : nil;
	UIView *root = controller.viewIfLoaded;
	if (!reticle || !root) return;

	CGFloat stock = [SokoPosterLayout stockEditingRowMinY];
	CGFloat offset = [SokoPosterLayout effectiveRowOffset];
	CGFloat inset = SokoDockGeometryBottomInset();
	CGFloat height = CGRectGetHeight(reticle.bounds);
	if (isnan(stock) || isnan(offset) || isnan(inset) || height < 1.0) return;

	CGFloat target = CGRectGetMaxY(root.bounds) - inset - height + offset;
	reticle.transform = CGAffineTransformMakeTranslation(0.0, target - stock);

	// 1.2.1-79 · 诊断：17=位移(×10)、18=边框高、19=系统原位
	SokoTrace(17, (long)llround((target - stock) * 10.0));
	SokoTrace(18, (long)llround(height));
	SokoTrace(19, (long)llround(stock));
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


+ (NSInteger)forceReticlesInEditingSceneViewController:(PREditingSceneViewController *)controller {
	UIView *root = controller.viewIfLoaded;
	if (!root) return 0;

	CGFloat inset = SokoDockGeometryBottomInset();
	CGFloat offset = [SokoPosterLayout effectiveRowOffset];
	if (isnan(inset) || isnan(offset)) return 0;

	NSInteger hits = 0;
	NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
	while (stack.count) {
		UIView *view = stack.lastObject;
		[stack removeLastObject];

		NSString *name = NSStringFromClass([view class]);
		// 1.2.1-84 · 类名可能是 PREditingReticleView / PREditingReticleViewContainer 等，
		// 也可能叫 Outline/Selection/Dashed，放宽匹配；命中数由 TRACE 17 回报。
		BOOL looksLikeReticle = [name rangeOfString:@"eticle" options:NSCaseInsensitiveSearch].location != NSNotFound ||
		                        [name rangeOfString:@"Outline" options:NSCaseInsensitiveSearch].location != NSNotFound ||
		                        [name rangeOfString:@"Dashed" options:NSCaseInsensitiveSearch].location != NSNotFound;
		if (looksLikeReticle) {
			CGRect inRoot = [view.superview convertRect:view.bounds toView:root];
			CGFloat targetY = CGRectGetMaxY(root.bounds) - inset - CGRectGetHeight(inRoot) + offset;
			CGRect frame = view.frame;
			frame.origin.y += targetY - CGRectGetMinY(inRoot);
			view.frame = frame;
			hits++;
		}

		for (UIView *sub in view.subviews) [stack addObject:sub];
	}

	// 17=命中数、18=目标(×10)、19=行偏移
	SokoTrace(17, hits);
	SokoTrace(18, (long)llround((CGRectGetMaxY(root.bounds) - inset + offset) * 10.0));
	SokoTrace(19, (long)llround(offset));
	return hits;
}

@end