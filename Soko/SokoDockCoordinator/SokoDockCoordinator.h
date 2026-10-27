#import "../SokoDockGeometry/SokoDockGeometry.h"
#import "../SokoRuntime/SokoRuntime.h"
#import "SokoNotificationList.h"
#import "SokoQuickActions.h"

FOUNDATION_EXPORT NSString *const SokoProminentDisplayVibrancyDidChangeNotification;
FOUNDATION_EXPORT NSString *const SokoProminentDisplayContentAlphaDidChangeNotification;

@interface SokoDockCoordinator : NSObject
// 1.2.1-79 · 当前壁纸归档里的行偏移（nil = 该壁纸没设置过 → 顶部）
+ (void)setActiveRowOffset:(NSNumber *)offset; <SokoNotificationListDock>
@property (nonatomic, readonly) SokoNotificationList *notificationList;

+ (BOOL)isSupported;
+ (instancetype)coordinatorForCoverSheetViewController:(CSCoverSheetViewController *)controller;
+ (instancetype)coordinatorForCoverSheetView:(UIView *)view;
+ (instancetype)activeCoordinator;

- (void)setEnabled:(BOOL)enabled;
- (void)refresh;
- (void)coverSheetViewDidLayout;
@end
