#import <Preferences/PSListController.h>

NS_ASSUME_NONNULL_BEGIN

/// 底部组件子页：锁屏底部（手电筒 ↔ 相机之间）的组件。
/// 现在只有「音乐胶囊」一节（自 LSMusicCapsule 移植），后续新增的底部组件
/// 都加在本页里 —— 所以页名与入口行都叫「底部组件」而不是「音乐胶囊」。
@interface ERBottomComponentsController : PSListController
@end

NS_ASSUME_NONNULL_END
