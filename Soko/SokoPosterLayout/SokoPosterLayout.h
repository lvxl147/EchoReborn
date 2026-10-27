#import "../SokoCompatibility/SokoCompatibility.h"
#import "../SokoDockGeometry/SokoDockGeometry.h"
#import "../SokoPosterModel/SokoPosterModel.h"
#import "../SokoRuntime/SokoRuntime.h"
#import "SokoEditorChrome.h"

@interface SokoPosterLayout : NSObject
+ (BOOL)isSupported;

+ (CGRect)frameByAdjustingFrame:(CGRect)frame forElement:(unsigned long long)element boundingRect:(CGRect)boundingRect variant:(unsigned long long)variant layoutController:(CSProminentLayoutController *)layoutController;
+ (CGRect)reticleFrameByAdjustingFrame:(CGRect)frame layoutController:(CSProminentLayoutController *)layoutController boundingRect:(CGRect)boundingRect;
+ (CGRect)editingRowFrame;

+ (void)registerComplicationContainerViewController:(UIViewController *)controller;
+ (BOOL)registerEditingSceneViewController:(PREditingSceneViewController *)controller;
+ (NSArray<PREditingSceneViewController *> *)editingSceneViewControllers;
+ (PREditingSceneViewController *)editingSceneViewControllerForComplicationContainerViewController:(UIViewController *)container;

+ (void)setInitialComplicationLayout:(id)layout forEditingSceneViewController:(PREditingSceneViewController *)controller;
+ (void)setInitialRowOffset:(NSNumber *)offset forEditingSceneViewController:(PREditingSceneViewController *)controller;
+ (BOOL)editingSceneViewControllerUsesBottomLayout:(PREditingSceneViewController *)controller;
+ (void)setUsesBottomLayout:(BOOL)usesBottomLayout forEditingSceneViewController:(PREditingSceneViewController *)controller;
+ (NSNumber *)bottomLayoutValueForDismissingEditor;

+ (BOOL)canSwipeEditingSceneViewController:(PREditingSceneViewController *)controller;
+ (BOOL)usesBottomEditingRow;
// 1.2.1-78 · 编辑会话内的行偏移（编辑期只改这个，不写偏好；点"完成"才落盘）
+ (void)setEditingRowOffset:(CGFloat)offset;
+ (CGFloat)editingRowOffset;                 // 无会话时为 NAN
+ (CGFloat)effectiveRowOffset;               // 编辑期取会话值，否则取发布值
+ (CGFloat)stockEditingRowMinY;              // 系统原位行（不含我们的调整）
// 1.2.1-69 · 手势门禁日志要读它（实现本来就在 .m 里，只是没在头文件声明）
+ (BOOL)editingSceneViewControllerIsDismissing:(PREditingSceneViewController *)controller;

+ (void)setIgnoringGraphicComplications:(BOOL)ignoring;
+ (BOOL)isIgnoringGraphicComplications;

+ (BOOL)isDodging;
+ (void)setCoveredByHostModalPresentation:(BOOL)covered;
+ (void)editingSceneViewControllerDidChangePresentation:(PREditingSceneViewController *)controller;

+ (void)relayoutAnimated:(BOOL)animated;
@end
