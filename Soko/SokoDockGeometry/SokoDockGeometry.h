#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <notify.h>

FOUNDATION_EXPORT NSString *const SokoDockGeometryDidChangeNotification;
FOUNDATION_EXPORT NSString *const SokoEditorDodgingDidChangeNotification;
FOUNDATION_EXPORT NSString *const SokoActiveBottomLayoutDidChangeNotification;
FOUNDATION_EXPORT NSString *const SokoEditorBottomLayoutDidChangeNotification;

// 1.2.1-76 · 行偏移通道（SpringBoard → PosterBoard）：
//   RowOffset = 当前壁纸"生效中的行偏移"（0 = 底部基准；负 = 向上；未设置时 = TopOffset）
//   TopOffset = 顶部（系统原位）相对底部基准的位移（实测 -518）
//   RowSet    = 用户是否显式设置过（未设置 = 该壁纸处于顶部态）
FOUNDATION_EXPORT NSString *const SokoRowOffsetDidChangeNotification;
FOUNDATION_EXPORT NSString *const SokoTopOffsetDidChangeNotification;
FOUNDATION_EXPORT NSString *const SokoRowOffsetIsSetDidChangeNotification;
// PosterBoard → SpringBoard：编辑器里滑动后请求写入该值（SpringBoard 落盘到偏好）
FOUNDATION_EXPORT NSString *const SokoSetRowOffsetRequestNotification;

static const CGFloat kSokoDockBottomToButtonCenter = 45.0;

FOUNDATION_EXPORT void SokoDockGeometryReload(void);
FOUNDATION_EXPORT void SokoDockGeometryObserve(void (^handler)(void));

FOUNDATION_EXPORT void SokoDockGeometryPublishBottomInset(CGFloat inset);
FOUNDATION_EXPORT CGFloat SokoDockGeometryBottomInset(void);

FOUNDATION_EXPORT void SokoDockPublishActiveUsesBottomLayout(BOOL usesBottomLayout);
FOUNDATION_EXPORT BOOL SokoDockActiveUsesBottomLayout(void);

FOUNDATION_EXPORT void SokoEditorPublishUsesBottomLayout(BOOL usesBottomLayout);
FOUNDATION_EXPORT BOOL SokoEditorUsesBottomLayout(void);

FOUNDATION_EXPORT void SokoEditorPublishDodging(BOOL dodging);
FOUNDATION_EXPORT BOOL SokoEditorDodging(void);

FOUNDATION_EXPORT void SokoDockPublishRowOffsets(CGFloat rowOffset, CGFloat topOffset, BOOL isSet);
FOUNDATION_EXPORT CGFloat SokoRowOffsetValue(void);
FOUNDATION_EXPORT CGFloat SokoTopOffsetValue(void);
FOUNDATION_EXPORT BOOL SokoRowOffsetIsSet(void);
// 1.2.1-88 · "调整组件位置"总开关（编辑器据此禁用上下滑）
FOUNDATION_EXPORT void SokoDockPublishWidgetsEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL SokoWidgetsEnabledValue(void);
FOUNDATION_EXPORT void SokoEditorRequestRowOffset(CGFloat offset);
// SpringBoard 侧读取编辑器最后一次请求的值（NAN 表示没有）
FOUNDATION_EXPORT CGFloat SokoRowOffsetRequestValue(void);
