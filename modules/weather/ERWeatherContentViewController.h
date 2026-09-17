#import <UIKit/UIKit.h>
#import "ERWeatherModule.h"

NS_ASSUME_NONNULL_BEGIN

/// The 4×2 tile's content.
///
/// Mirrors the reference plugin's WCCContentViewController layout: a header line
/// (city on the left, condition glyph on the right), a large temperature, a
/// detail line (condition / high-low / precipitation), a divider, and a
/// horizontally scrolling hourly strip.
///
/// The reference declares no background view of its own and neither does this
/// controller — Control Center draws the standard platter, so the tile inherits
/// the system corner radius, material and shadow instead of imitating them. That
/// is also why `providesOwnPlatter` is left alone (default NO) in
/// ERWeatherModule.h.
@interface ERWeatherContentViewController : UIViewController <CCUIContentModuleContentViewController>
@end

NS_ASSUME_NONNULL_END
