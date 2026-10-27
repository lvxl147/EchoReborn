#import "../SokoCompatibility/SokoCompatibility.h"
#import "SokoPosterLayout.h"

@interface SokoEditorChrome : NSObject
+ (void)registerEditorRootViewController:(PREditorRootViewController *)controller;
+ (void)update;
// 1.2.1-94 · 给编辑器"完成/取消"按钮挂监听（按标题文字匹配，不依赖私有 selector）
+ (void)installEditorButtonWatchers:(PREditingSceneViewController *)controller;
// 1.2.1-93 · 只读：全深度扫描编辑器视图树，把「尺寸≈组件行、纵向位置≈系统行」的视图类名回传
+ (void)dumpCandidateViewsInEditingSceneViewController:(PREditingSceneViewController *)controller;
@end
