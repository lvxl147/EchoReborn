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

	// 1.2.1-87 · 改为"几何匹配"：类名扫不到（前 6 层都是通用容器），因此按
	// 「尺寸≈组件行 + 纵向位置≈系统行位置」来找那个虚线框，然后整体平移 delta。
	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	CGRect stock = [layoutClass frameForElements:kSokoComplicationRowElement variant:kSokoReticleVariant];
	if (CGRectIsNull(stock)) return 0;

	CGRect bounds = root.bounds;
	CGFloat targetTop = CGRectGetMaxY(bounds) - inset - CGRectGetHeight(stock) + offset;
	CGFloat delta = targetTop - CGRectGetMinY(stock);
	if (fabs(delta) < 0.5) return 0;

	id firstContainer = controller.complicationContainerViewControllers.firstObject;
	UIView *container = [firstContainer isKindOfClass:[UIViewController class]] ? ((UIViewController *)firstContainer).viewIfLoaded : nil;

	CGFloat stockCenterY = CGRectGetMidY(stock);
	CGFloat rowW = CGRectGetWidth(stock);
	CGFloat rowH = CGRectGetHeight(stock);

	NSInteger hits = 0;
	NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
	NSInteger visited = 0;
	while (stack.count && visited < 400) {
		UIView *v = stack.lastObject;
		[stack removeLastObject];
		visited++;

		if (v != container && v != root) {
			CGRect inRoot = [v.superview convertRect:v.bounds toView:root];
			BOOL sizeOK = CGRectGetWidth(inRoot) > rowW * 0.5 && CGRectGetWidth(inRoot) < rowW * 1.6 &&
			              CGRectGetHeight(inRoot) > rowH * 0.5 && CGRectGetHeight(inRoot) < rowH * 1.8;
			BOOL posOK = fabs(CGRectGetMidY(inRoot) - stockCenterY) < 10.0;
			if (sizeOK && posOK && v.alpha > 0.01) {
				v.transform = CGAffineTransformMakeTranslation(0.0, delta);
				hits++;
			}
		}

		for (UIView *sub in v.subviews) [stack addObject:sub];
	}

	SokoTrace(17, hits);
	SokoTrace(18, (long)llround(delta * 10.0));
	SokoTrace(19, (long)llround(offset));
	return hits;
}

@end