#import "SokoPosterLayout.h"
#import "../SokoLog.h"
#import "../SokoFileLog.h"

static const void *kSokoEditorBottomLayoutKey = &kSokoEditorBottomLayoutKey;
static const void *kSokoEditorRowOffsetKey = &kSokoEditorRowOffsetKey;
static const void *kSokoLiquidAssConfigurationKey = &kSokoLiquidAssConfigurationKey;
static const void *kSokoLiquidAssUserInfoKey = &kSokoLiquidAssUserInfoKey;

static NSHashTable<UIViewController *> *gComplicationContainerViewControllers;
static NSHashTable<PREditingSceneViewController *> *gEditingSceneViewControllers;

static __thread BOOL gComputingStockLayout;
// 1.2.1-110 · 系统算出的编辑态 reticle 矩形（complicationRowElementEditingReticleFrame）
static CGRect gSystemReticleRect = {{0, 0, 0, 0}};   // 高度>0 才有效
static BOOL gIgnoringGraphicComplications;
// 1.2.1-78 · 编辑会话内的偏移（NAN = 跟随 SpringBoard 发布值）
static CGFloat gEditingRowOffset = NAN;
// 1.2.1-99 · 本次会话是否真的滑动过（决定"完成"时是否提交）
static BOOL gEditingRowOffsetDirty;

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
	// 1.2.1-90 · 回到上游：reticle 变体必须在这里早退。否则编辑器算边框时会拿到
	// 已被我们改写的行框，chrome 里「目标 − 系统位置」恒为 0，边框原地不动（TRACE 17=-4 实锤）。
	if (element != kSokoComplicationRowElement || variant == kSokoReticleVariant || gComputingStockLayout) return frame;

	CGFloat inset = SokoDockGeometryBottomInset();
	if (isnan(inset) || CGRectIsNull(frame) || CGRectGetHeight(frame) <= 0.0 || !SokoIsPortrait(boundingRect)) return frame;

	// 1.2.1-76 · 统一模型：行 y = 底部基准行 + 生效偏移。
	//   偏移来自 SpringBoard 发布的通道（0 = 底部；-T = 顶部；中间值 = 任意位置），
	//   编辑态与非编辑态用同一套，因此"滑块 -200 → 进入自定义也在 -200"成立。
	CGFloat offset = [self effectiveRowOffset];
	if (isnan(offset)) return frame;

	frame.origin.y = CGRectGetMaxY(boundingRect) - inset - CGRectGetHeight(frame) + offset;
	return frame;
}

+ (CGRect)reticleFrameByAdjustingFrame:(CGRect)frame layoutController:(CSProminentLayoutController *)layoutController boundingRect:(CGRect)boundingRect {
	if (gComputingStockLayout || CGRectIsNull(frame)) return frame;

	// 1.2.1-90 · 上游实现：用「编辑态行(已调整) − 编辑态行(系统原值)」的差做平移。
	// 这里的第二次调用靠 gComputingStockLayout 关掉我方调整，拿到真正的原值。
	CGRect row = [layoutController frameForElements:kSokoComplicationRowElement variant:kSokoEditingVariant withBoundingRect:boundingRect];

	gComputingStockLayout = YES;
	CGRect stockRow = [layoutController frameForElements:kSokoComplicationRowElement variant:kSokoEditingVariant withBoundingRect:boundingRect];
	gComputingStockLayout = NO;

	// 1.2.1-92 · 探针：60=进入(reticle frame.y) 61=row.minY 62=stockRow.minY 63=返回值
	SokoTrace(60, (long)llround(CGRectGetMinY(frame)));
	SokoTrace(61, (long)llround(CGRectGetMinY(row)));
	SokoTrace(62, (long)llround(CGRectGetMinY(stockRow)));

	if (CGRectIsNull(row) || CGRectIsNull(stockRow)) return frame;

	// 1.2.1-102 · **边框不跟随的真凶：这里二次位移了。**
	//   放开 SokoTrace 的 32 码上限后第一次真正拿到 60~63（此前"恒为 0"是假阴性）：
	//     60=212 61=221 62=221 → reticle.y == row.minY - 9
	//     60=719 61=728 62=221 → reticle.y == row.minY - 9
	//   **系统自己就是按我们改过的行算虚线框的**（reticle.y 恒等于 row.minY-9）。
	//   再叠加 (row - stockRow) 就成了二次位移：
	//     偏移=顶部(-507) 时 delta=0，侥幸正确（这就是"滑到上面边框正常"）；
	//     偏移=底部(0)    时 delta=+507 → 719+507=1226 → 飞出屏幕
	//     —— 正是用户说的"滑动到下面，直接变为不显示"。
	//   所以这里什么都不做，直接把系统算好的 frame 原样返回。
	// 1.2.1-110 · 把系统算出来的 reticle 矩形存下来，给视图查找当**精确**筛选条件
	//   （60/63 证明系统确实会算这个矩形：顶部 212、底部 719）
	gSystemReticleRect = frame;

	SokoTrace(63, (long)llround(frame.origin.y));
	return frame;
}

+ (CGRect)systemReticleRect {
	return gSystemReticleRect;
}

+ (CGRect)editingRowFrame {
	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	CGRect frame = [layoutClass frameForElements:kSokoComplicationRowElement variant:kSokoEditingVariant];

	// 1.2.1-69 · 手势判定用的就是这个 rect。它是「系统编辑态行位置」，不是我们
	// 挪到底部之后的实际位置 —— 若两者不一致，点在底部行上会被判成 outside-row。
	static CFTimeInterval lastLog = 0.0;
	CFTimeInterval now = CACurrentMediaTime();
	if (now - lastLog > 3.0) {
		lastLog = now;
		SokoTrace(16, (long)frame.origin.y);
		SokoFileLog(@"ROW editingRowFrame=(%.1f,%.1f,%.1fx%.1f) inset=%.1f usesBottomEditingRow=%d editorBottom=%d dodging=%d",
		            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
		            SokoDockGeometryBottomInset(), (int)[self usesBottomEditingRow],
		            (int)SokoEditorUsesBottomLayout(), (int)[self isDodging]);
	}
	return frame;
}

+ (void)setEditingRowOffset:(CGFloat)offset {
	// 1.2.1-99 · 不再同步"待提交值"到模型层：那会让取消也把会话值漏进归档。
	// 会话值只在"完成"时由 PRPosterConfiguredProperties setComplicationLayout: 取走。
	gEditingRowOffset = offset;
	if (!isnan(offset)) gEditingRowOffsetDirty = YES;
}

+ (CGFloat)editingRowOffset {
	return gEditingRowOffset;
}

+ (BOOL)editingRowOffsetDirty {
	return gEditingRowOffsetDirty;
}

+ (void)clearEditingSession {
	gEditingRowOffset = NAN;
	gEditingRowOffsetDirty = NO;
}

+ (CGFloat)effectiveRowOffset {
	// 只有存在活动编辑会话时才算"编辑中"；取消退出后会话被清空，自动回落到发布值。
	BOOL hasSession = gEditingSceneViewControllers.allObjects.count > 0;
	if (hasSession && !isnan(gEditingRowOffset)) return gEditingRowOffset;
	return SokoRowOffsetIsSet() ? SokoRowOffsetValue() : SokoTopOffsetValue();
}

+ (CGFloat)editingRowDelta {
	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	CGRect adjusted = [layoutClass frameForElements:kSokoComplicationRowElement variant:kSokoEditingVariant];

	gComputingStockLayout = YES;
	CGRect stock = [layoutClass frameForElements:kSokoComplicationRowElement variant:kSokoEditingVariant];
	gComputingStockLayout = NO;

	if (CGRectIsNull(adjusted) || CGRectIsNull(stock)) return NAN;
	return CGRectGetMinY(adjusted) - CGRectGetMinY(stock);
}

+ (CGFloat)stockEditingRowMinY {
	Class layoutClass = NSClassFromString(@"CSProminentLayoutController");
	gComputingStockLayout = YES;
	CGRect frame = [layoutClass frameForElements:kSokoComplicationRowElement variant:kSokoReticleVariant];
	gComputingStockLayout = NO;
	return CGRectIsNull(frame) ? NAN : CGRectGetMinY(frame);
}

+ (void)registerComplicationContainerViewController:(UIViewController *)controller {
	gComplicationContainerViewControllers = SokoRegister(gComplicationContainerViewControllers, controller);

	// 1.2.1-96 · 容器登记是必然发生的入口，在这里补跑一次类名扫描
	for (PREditingSceneViewController *scene in gEditingSceneViewControllers.allObjects) {
		[SokoEditorChrome dumpCandidateViewsInEditingSceneViewController:scene];
	}
}

+ (BOOL)editingSceneViewControllerEditsLockScreen:(PREditingSceneViewController *)controller {
	if (![controller respondsToSelector:@selector(posterRole)]) return YES;

	NSString *role = controller.posterRole;
	return [role isKindOfClass:[NSString class]] && [role isEqualToString:@"PRPosterRoleLockScreen"];
}

+ (BOOL)registerEditingSceneViewController:(PREditingSceneViewController *)controller {
	if (![self editingSceneViewControllerEditsLockScreen:controller]) return NO;

	// 1.2.1-78 · 进编辑就把"当前生效值"取进会话；之后滑动只改会话值，
	// 不再跨进程写偏好（原版语义：点完成才生效）。
	// 1.2.1-85 · 不再用归档值播种：之前完成时写进归档的 0 会让每次进入都落在 0。
	// 现在只认 SpringBoard 发布过来的"当前生效值"（= 设置页滑块）。
	// 1.2.1-104 · 进编辑器先把"编辑前的值"发给 SpringBoard 存基线（取消时回滚用）。
	//   必须在设置会话值之前取，否则取到的会是刚播种的会话值。
	SokoEditorRequestBaseline([self effectiveRowOffset]);

	gEditingRowOffset = [self effectiveRowOffset];
	gEditingRowOffsetDirty = NO;   // 1.2.1-99 · 新会话：还没滑动过
	gEditingSceneViewControllers = SokoRegister(gEditingSceneViewControllers, controller);
	[SokoEditorChrome installEditorButtonWatchers:controller];

	// 1.2.1-95 · 视图还没建好时按钮扫不到，延迟再补扫一次（并跑一次类名扫描探针）
	__weak PREditingSceneViewController *weakScene = controller;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		PREditingSceneViewController *scene = weakScene;
		if (!scene) return;
		[SokoEditorChrome installEditorButtonWatchers:scene];
		[SokoEditorChrome dumpCandidateViewsInEditingSceneViewController:scene];
	});
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

+ (void)setInitialRowOffset:(NSNumber *)offset forEditingSceneViewController:(PREditingSceneViewController *)controller {
	objc_setAssociatedObject(controller, kSokoEditorRowOffsetKey, offset, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

		// 1.2.1-93 · 只读：扫一遍候选视图类名（用于定位编辑态虚线框）
		for (PREditingSceneViewController *scene in gEditingSceneViewControllers.allObjects) {
			[SokoEditorChrome dumpCandidateViewsInEditingSceneViewController:scene];
		}

	};

	if (!animated) {
		layout();
		return;
	}

	UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
	// 1.2.1-78 · 编辑期全程本地、没有跨进程等待，0.3s 弹簧即为原版手感
	[UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:1.0 initialSpringVelocity:0.0 options:options animations:layout completion:nil];
}

@end
