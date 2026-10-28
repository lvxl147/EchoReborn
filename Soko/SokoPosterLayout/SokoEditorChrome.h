#import "../SokoCompatibility/SokoCompatibility.h"
#import "SokoPosterLayout.h"

@interface SokoEditorChrome : NSObject
+ (void)registerEditorRootViewController:(PREditorRootViewController *)controller;
+ (void)update;
// 1.2.1-104 · 取消按钮监听（按 KVC 取 cancelButton，点了回滚）
+ (void)installCancelButtonWatcher:(PREditorRootViewController *)controller;
// 1.2.1-110 · 每次系统布局完都补一次平移（否则会被系统的 layout 冲掉）
+ (void)reapplyReticleTransform;
// 1.2.1-94 · 给编辑器"完成/取消"按钮挂监听（按标题文字匹配，不依赖私有 selector）
+ (void)installEditorButtonWatchers:(PREditingSceneViewController *)controller;
// 1.2.1-93 · 只读：全深度扫描编辑器视图树，把「尺寸≈组件行、纵向位置≈系统行」的视图类名回传
+ (void)dumpCandidateViewsInEditingSceneViewController:(PREditingSceneViewController *)controller;
@end
