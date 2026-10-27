// 1.2.1-67 · 旧设置项桥（rc.3 语义完整保留）：ERSokoController 设置页
// （com.strive.echoreborn.preferences 域，soko_ 前缀）继续实时生效。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

CGFloat SokoPrefWidgetOffset(void);        // 组件区垂直偏移（有效值，关=0）
CGFloat SokoPrefNotificationOffset(void);  // 通知列表垂直偏移（有效值，关=0）
BOOL SokoPrefQuickActionsEnabled(void);    // 快捷操作开关
CGFloat SokoPrefQuickActionsIndent(void);  // 快捷操作横向缩进（有效值，关=0）

// 1.2.1-73 · 偏好变更后的重排回调（SpringBoard 侧注册；设置页改完立即重算组件行，
// 不必再等锁屏重建布局）
void SokoPreferencesSetChangeHandler(void (^handler)(void));
