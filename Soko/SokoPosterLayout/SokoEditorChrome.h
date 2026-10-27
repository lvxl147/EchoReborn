#import "../SokoCompatibility/SokoCompatibility.h"
#import "SokoPosterLayout.h"

@interface SokoEditorChrome : NSObject
+ (void)registerEditorRootViewController:(PREditorRootViewController *)controller;
+ (void)update;
// 1.2.1-81 · 兜底：直接在编辑场景视图树里找 reticle 类视图并强制定位
// （系统自己的 updateReticleViewFrames 会覆盖我们的 frame/transform）
+ (NSInteger)forceReticlesInEditingSceneViewController:(PREditingSceneViewController *)controller;
@end
