#import "SokoPosterLayout.h"
#import "../SokoLog.h"
#import "../SokoFileLog.h"

static const void *kSokoEditorBottomLayoutKey = &kSokoEditorBottomLayoutKey;
static const void *kSokoLiquidAssConfigurationKey = &kSokoLiquidAssConfigurationKey;
static const void *kSokoLiquidAssUserInfoKey = &kSokoLiquidAssUserInfoKey;

static NSHashTable<UIViewController *> *gComplicationContainerViewControllers;
static NSHashTable<PREditingSceneViewController *> *gEditingSceneViewControllers;

static __thread BOOL gComputingStockLayout;
static BOOL gIgnoringGraphicComplications;

static __weak PREditingSceneViewController *gDodgingEditingSceneViewController;
static BOOL gCoveredByHostModalPresentation;

static NSHashTable *SokoRegister(NSHashTable *table, id object) {
	if (!table) table = [NSHashTable weakObjectsHashTable];

	[table addObject:object];
	return table;
}

@implementation SokoPosterLayout

+ (BOOL)isSupported {
	Class containerClass = NSClassFromString(@"PRComplicationContainerViewController");
	if ([containerClass instancesRespondToSelector:NSSelectorFromString(@"setWidgetsUseBottomLayout:")]) return NO;

	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	return [layoutClass instancesRespondToSelector:@selector(_frameForElement:withBoundingRect:variant:)] &&
		[layoutClass instancesRespondToSelector:@selector(complicationRowElementEditingReticleFrameWithBoundingRect:)] &&
		[layoutClass instancesRespondToSelector:@selector(frameForElements:variant:withBoundingRect:)] &&
		[layoutClass respondsToSelector:@selector(frameForElements:variant:)];
}

+ (BOOL)liquidAssPosterCellUsesBottomLayout:(UIView *)cell {
	id pair = SokoIvarObject(cell, "posterPair");
	id configuration = SokoIvarObject(pair, "configuration");
	if (!configuration) return SokoDockActiveUsesBottomLayout();

	if (objc_getAssociatedObject(cell, kSokoLiquidAssConfigurationKey) != configuration) {
		objc_setAssociatedObject(cell, kSokoLiquidAssConfigurationKey, configuration, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		objc_setAssociatedObject(cell, kSokoLiquidAssUserInfoKey, SokoLiquidAssUserInfoForConfiguration(configuration) ?: @{}, OBJC_ASSOCIATION_COPY_NONATOMIC);
	}

	return SokoLiquidAssUserInfoUsesBottomLayout(objc_getAssociatedObject(cell, kSokoLiquidAssUserInfoKey));
}

+ (BOOL)layoutControllerUsesBottomLayout:(CSProminentLayoutController *)layoutController {
	static Class cellClass;
	static Ivar layoutIvar;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cellClass = NSClassFromString(@"_TtC11PosterBoard34LockScreenPosterCollectionViewCell");
		layoutIvar = cellClass ? class_getInstanceVariable(cellClass, "complicationLayout") : NULL;
	});

	id environment = [layoutController respondsToSelector:@selector(traitEnvironment)] ? layoutController.traitEnvironment : nil;
	UIView *view = [environment isKindOfClass:[UIViewController class]] ? ((UIViewController *)environment).viewIfLoaded : environment;
	if (![view isKindOfClass:[UIView class]]) view = nil;

	for (; cellClass && view; view = view.superview) {
		if (![view isKindOfClass:cellClass]) continue;
		// 1.2.1-75 · 只有这张壁纸自己带 LiquidAss 时钟配置时才走它那套，
		// 否则仍按本插件存的状态走（否则装了 LiquidAss 就永远读不到我们的值）。
		if (SokoLiquidAssClockEnabled()) {
			id pair = SokoIvarObject(view, "posterPair");
			id configuration = SokoIvarObject(pair, "configuration");
			if (SokoLiquidAssUserInfoIsActive(SokoLiquidAssUserInfoForConfiguration(configuration))) {
				return [self liquidAssPosterCellUsesBottomLayout:view];
			}
		}

		return layoutIvar && [SokoPosterModel complicationLayoutUsesBottomLayout:object_getIvar(view, layoutIvar)];
	}

	return SokoDockActiveUsesBottomLayout();
}

+ (CGRect)frameByAdjustingFrame:(CGRect)frame forElement:(unsigned long long)element boundingRect:(CGRect)boundingRect variant:(unsigned long long)variant layoutController:(CSProminentLayoutController *)layoutController {
	// 1.2.1-77 · 允许编辑态虚线框（variant 3）走同一套定位 —— 17.2.1 上边框是
	// 通过 _frameForElement:...variant:3 算出来的，之前在这里被早退，所以组件滑走了
	// 边框留在原位。
	if (element != kSokoComplicationRowElement || gComputingStockLayout) return frame;

	CGFloat inset = SokoDockGeometryBottomInset();
	if (isnan(inset) || CGRectIsNull(frame) || CGRectGetHeight(frame) <= 0.0 || !SokoIsPortrait(boundingRect)) return frame;

	// 1.2.1-76 · 统一模型：行 y = 底部基准行 + 生效偏移。
	//   偏移来自 SpringBoard 发布的通道（0 = 底部；-T = 顶部；中间值 = 任意位置），
	//   编辑态与非编辑态用同一套，因此"滑块 -200 → 进入自定义也在 -200"成立。
	CGFloat offset = SokoRowOffsetIsSet() ? SokoRowOffsetValue() : SokoTopOffsetValue();
	if (isnan(offset)) return frame;

	frame.origin.y = CGRectGetMaxY(boundingRect) - inset - CGRectGetHeight(frame) + offset;
	return frame;
}

+ (CGRect)reticleFrameByAdjustingFrame:(CGRect)frame layoutController:(CSProminentLayoutController *)layoutController boundingRect:(CGRect)boundingRect {
	if (gComputingStockLayout || CGRectIsNull(frame)) return frame;

	// 1.2.1-76 · 边框直接钉到"行应该出现的位置"，不再靠"系统行框差值"平移。
	// 原实现：frame.origin.y += (row.minY - stockRow.minY)；实测系统两套行框在
	// 17.2.1 上相同 → 差值恒 0 → 组件滑走了、虚线框留在原地。
	CGFloat inset = SokoDockGeometryBottomInset();
	CGFloat offset = SokoRowOffsetIsSet() ? SokoRowOffsetValue() : SokoTopOffsetValue();
	if (isnan(inset) || isnan(offset) || !SokoIsPortrait(boundingRect)) return frame;

	frame.origin.y = CGRectGetMaxY(boundingRect) - inset - CGRectGetHeight(frame) + offset;
	return frame;
}

+ (CGRect)editingRowFrame {
	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	CGRect frame = [layoutClass frameForElements:kSokoComplicationRowElement variant:kSokoEditingVariant];

	// 1.2.1-69 · 手势判定用的就是这个 rect。它是「系统编辑态行位置」，不是我们
	// 挪到底部之后的实际位置 —— 若两者不一致，点在底部行上会被判成 outside-row。
	static CFTimeInterval lastLog = 0.0;
	CFTimeInterval now = CACurrentMediaTime();
	if (now - lastLog > 0.5) {
		lastLog = now;
		SokoTrace(16, (long)frame.origin.y);
		SokoFileLog(@"ROW editingRowFrame=(%.1f,%.1f,%.1fx%.1f) inset=%.1f usesBottomEditingRow=%d editorBottom=%d dodging=%d",
		            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
		            SokoDockGeometryBottomInset(), (int)[self usesBottomEditingRow],
		            (int)SokoEditorUsesBottomLayout(), (int)[self isDodging]);
	}
	return frame;
}

+ (void)registerComplicationContainerViewController:(UIViewController *)controller {
	gComplicationContainerViewControllers = SokoRegister(gComplicationContainerViewControllers, controller);
}

+ (BOOL)editingSceneViewControllerEditsLockScreen:(PREditingSceneViewController *)controller {
	if (![controller respondsToSelector:@selector(posterRole)]) return YES;

	NSString *role = controller.posterRole;
	return [role isKindOfClass:[NSString class]] && [role isEqualToString:@"PRPosterRoleLockScreen"];
}

+ (BOOL)registerEditingSceneViewController:(PREditingSceneViewController *)controller {
	if (![self editingSceneViewControllerEditsLockScreen:controller]) return NO;

	gEditingSceneViewControllers = SokoRegister(gEditingSceneViewControllers, controller);
	SokoEditorPublishUsesBottomLayout([self editingSceneViewControllerUsesBottomLayout:controller]);
	[self relayoutAnimated:NO];
	return YES;
}

+ (NSArray<PREditingSceneViewController *> *)editingSceneViewControllers {
	return gEditingSceneViewControllers.allObjects ?: @[];
}

+ (PREditingSceneViewController *)editingSceneViewControllerForComplicationContainerViewController:(UIViewController *)container {
	if (!container) return nil;

	PREditingSceneViewController *candidate = nil;
	for (PREditingSceneViewController *controller in gEditingSceneViewControllers.allObjects) {
		NSArray *containers = [controller respondsToSelector:@selector(complicationContainerViewControllers)] ? controller.complicationContainerViewControllers : nil;
		if ([containers isKindOfClass:[NSArray class]] && [containers containsObject:container]) return controller;

		if (controller.viewIfLoaded.window) candidate = controller;
	}
	return candidate;
}

+ (void)setInitialComplicationLayout:(id)layout forEditingSceneViewController:(PREditingSceneViewController *)controller {
	BOOL bottom = [SokoPosterModel complicationLayoutUsesBottomLayout:layout];
	objc_setAssociatedObject(controller, kSokoEditorBottomLayoutKey, @(bottom), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (BOOL)editingSceneViewControllerUsesBottomLayout:(PREditingSceneViewController *)controller {
	return [objc_getAssociatedObject(controller, kSokoEditorBottomLayoutKey) boolValue];
}

+ (void)setUsesBottomLayout:(BOOL)usesBottomLayout forEditingSceneViewController:(PREditingSceneViewController *)controller {
	if (usesBottomLayout == [self editingSceneViewControllerUsesBottomLayout:controller]) return;

	objc_setAssociatedObject(controller, kSokoEditorBottomLayoutKey, @(usesBottomLayout), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	SokoEditorPublishUsesBottomLayout(usesBottomLayout);

	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
	[self relayoutAnimated:YES];
}

+ (BOOL)editingSceneViewControllerIsDismissing:(PREditingSceneViewController *)controller {
	return [controller respondsToSelector:@selector(isDismissing)] && controller.isDismissing;
}

+ (NSNumber *)bottomLayoutValueForDismissingEditor {
	for (PREditingSceneViewController *controller in gEditingSceneViewControllers.allObjects) {
		if ([self editingSceneViewControllerIsDismissing:controller]) return @([self editingSceneViewControllerUsesBottomLayout:controller]);
	}
	return nil;
}

+ (BOOL)canSwipeEditingSceneViewController:(PREditingSceneViewController *)controller {
	if (!controller || controller.presentedViewController) return NO;
	if (isnan(SokoDockGeometryBottomInset()) || [self isDodging]) return NO;
	if ([self editingSceneViewControllerIsDismissing:controller]) return NO;

	return SokoIsPortrait(controller.view.bounds);
}

+ (BOOL)usesBottomEditingRow {
	return !isnan(SokoDockGeometryBottomInset()) && SokoEditorUsesBottomLayout() && ![self isDodging];
}

+ (void)setIgnoringGraphicComplications:(BOOL)ignoring {
	gIgnoringGraphicComplications = ignoring;
}

+ (BOOL)isIgnoringGraphicComplications {
	return gIgnoringGraphicComplications;
}

+ (BOOL)isDodging {
	return SokoEditorDodging() || gCoveredByHostModalPresentation;
}

+ (void)setCoveredByHostModalPresentation:(BOOL)covered {
	if (covered == gCoveredByHostModalPresentation) return;

	gCoveredByHostModalPresentation = covered;
	[self relayoutAnimated:YES];
}

+ (BOOL)editingSceneViewControllerIsPresentingSheet:(PREditingSceneViewController *)controller {
	static NSArray<NSString *> *sheetSelectors;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		sheetSelectors = @[
			NSStringFromSelector(@selector(presentedComplicationsGallery)),
			NSStringFromSelector(@selector(presentedInlineComplicationsGallery)),
			NSStringFromSelector(@selector(presentedWidgetConfigurationViewController)),
			NSStringFromSelector(@selector(presentedComplicationWidgetConfigurationViewController)),
			NSStringFromSelector(@selector(presentedControlsGallery)),
			NSStringFromSelector(@selector(presentedControlWidgetConfigurationViewController)),
		];
	});

	for (NSString *selector in sheetSelectors) {
		if ([controller respondsToSelector:NSSelectorFromString(selector)] && [controller valueForKey:selector]) return YES;
	}
	return NO;
}

+ (void)editingSceneViewControllerDidChangePresentation:(PREditingSceneViewController *)controller {
	if ([self editingSceneViewControllerIsPresentingSheet:controller]) {
		gDodgingEditingSceneViewController = controller;
		[self updateDodging];
		return;
	}

	__weak PREditingSceneViewController *weakController = controller;
	dispatch_async(dispatch_get_main_queue(), ^{
		PREditingSceneViewController *strongController = weakController;
		BOOL stillDodging = gDodgingEditingSceneViewController == strongController;
		if (stillDodging && ![self editingSceneViewControllerIsPresentingSheet:strongController]) {
			gDodgingEditingSceneViewController = nil;
		}

		[self updateDodging];
	});
}

+ (void)updateDodging {
	BOOL dodging = gDodgingEditingSceneViewController != nil;
	if (dodging == SokoEditorDodging()) return;

	SokoEditorPublishDodging(dodging);
	[self relayoutAnimated:YES];
}

+ (void)relayoutAnimated:(BOOL)animated {
	void (^layout)(void) = ^{
		for (UIViewController *controller in gComplicationContainerViewControllers.allObjects) {
			UIView *view = controller.viewIfLoaded;
			[view setNeedsLayout];
			[view layoutIfNeeded];
		}

		[SokoEditorChrome update];
	};

	if (!animated) {
		layout();
		return;
	}

	UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
	// 1.2.1-77 · 0.45s 的弹簧在编辑态被感知为"停顿一下才动"，压到 0.18s 且用 ease-out
	[UIView animateWithDuration:0.18 delay:0.0 options:options animations:layout completion:nil];
}

@end
