#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>

NS_ASSUME_NONNULL_BEGIN

/// Build a tinted rounded-square icon from an SF Symbol, matching the
/// screenshot's card style (colored chip + white glyph).
UIImage *ERImageIcon(NSString *sfSymbol, NSString *colorName);

/// 1.0.4：带回落链的图标构造器。
///
/// `ERImageIcon` 只试一个 SF Symbol 名；取不到就只画彩色圆角底、**不画字形** ——
/// 这正是「蓝牙 / 隔空投送只显示背景」的成因（`bluetooth` / `airdrop` 并不在
/// SF Symbols 目录里：AirDrop 的真字形是 ConnectivityModule.bundle 资源目录里的
/// `AirDropGlyph`，蓝牙则是一个 CAPackage）。
///
/// 本函数按顺序尝试：
///   1. symbols 里的每个 SF Symbol 名（第一个能解析出来的就用）；
///   2. assetNames 里的每个名字，先在本项目的 bundle、再在系统的
///      ConnectivityModule.bundle 资源目录里找；
///   3. 都失败时用 fallbackText 的**首字符**画一个白色字形。
/// 第 3 步保证「有底、无字形」这种半截外观在任何情况下都不会再出现。
UIImage *ERImageIconWithFallbacks(NSArray<NSString *> *_Nullable symbols,
                                  NSArray<NSString *> *_Nullable assetNames,
                                  NSString *_Nullable fallbackText,
                                  NSString *colorName);

/// 「Echo Reborn x.y.z」——版本号在运行期从本 bundle 的 Info.plist 读
/// CFBundleShortVersionString，所以每次改版本号只需改一处（Info.plist / control），
/// 页面上的显示会自动跟上，不会再出现写死的旧版本号。
NSString *ERVersionFooterText(void);

/// 版本号单元格（运行时注册的 PSTableCell 子类，居中显示 ERVersionFooterText）。
extern NSString *const ERVersionFooterCellClassName;
extern NSString *const ERVersionFooterTextKey;
void EREnsureVersionFooterCellClassInstalled(void);

/// Apply icons to every specifier that carries `erIcon`/`erIconColor`.
@interface PSListController (ERUIExtensions)
- (void)erApplyIcons;

/// 挂图标 + 注册「App 回到前台时重挂一次」的兜底通知（幂等，可重复调用）。
/// 视图控制器在 viewDidLoad 里调它，并在 viewWillAppear 里再调一次 erApplyIcons。
- (void)erActivateIconRefresh;
@end

/// 1.0.7-15：「启动插件」开关搬到「界面优化」子页后，把总开关的联动逻辑
/// （初值捕获 + respring 提示）下沉为所有 PSListController 共用的分类方法。
/// 根页与子页的 controller 都从 PSListController 继承，谁挂 Enabled 的
/// specifier 谁就能响应。声明必须放在头文件里——ERRootListController.m 与
/// EREnhancedSettingsController.m 两个编译单元都要看得见。
@interface PSListController (ERMasterToggle)
- (void)erStoreInitialMasterEnabled;
- (void)setMasterEnabled:(id)value specifier:(PSSpecifier *)specifier;
- (void)respring;
@end

NS_ASSUME_NONNULL_END
