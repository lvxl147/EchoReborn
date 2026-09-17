#import <Foundation/Foundation.h>
#import "ERWeatherModule.h"

NS_ASSUME_NONNULL_BEGIN

/// One entry of the hourly strip.
@interface ERWeatherHour : NSObject
/// "现在" for the first entry, otherwise a 24-hour "14时".
@property (nonatomic, copy) NSString *timeText;
/// "23°"
@property (nonatomic, copy) NSString *temperatureText;
@property (nonatomic) NSInteger conditionCode;
@property (nonatomic) BOOL isDay;
/// YES for the leading "现在" entry — it is rendered with a heavier weight.
@property (nonatomic) BOOL isNow;
@end

/// Everything the tile draws, in one immutable value.
///
/// `hasLiveData == NO` is a fully supported state, not an error: the tile then
/// renders the placeholder (icon + 天气 + --°) instead of an empty rectangle.
/// A blank tile reads as a bug, which is exactly what the connectivity modules'
/// glyph fallback chain exists to prevent; the same rule applies here.
@interface ERWeatherSnapshot : NSObject
@property (nonatomic, copy) NSString *cityText;
@property (nonatomic, copy) NSString *temperatureText;
@property (nonatomic, copy) NSString *conditionText;
@property (nonatomic, copy) NSString *highLowText;
@property (nonatomic, copy) NSString *precipText;
@property (nonatomic) NSInteger conditionCode;
@property (nonatomic) BOOL isDay;
@property (nonatomic, copy) NSArray<ERWeatherHour *> *hours;
/// NO when the Weather framework could not be read (see ERWeatherBridge).
@property (nonatomic) BOOL hasLiveData;
/// Human-readable reason for the placeholder state; only used in the log.
@property (nonatomic, copy, nullable) NSString *diagnostic;
@end

/// Reads Apple's private Weather framework.
///
/// Design notes — why this is so defensive
/// --------------------------------------
/// The reference plugin (com.simon.ccweathermodule) shows weather without any
/// networking, which means it reads the forecast Weather.framework already keeps
/// on the device. That is also the only route that works without a location
/// prompt and without an API key, so it is the route taken here.
///
/// But `WATodayModel`, `WAForecastModel`, `WADayForecast`, `WAHourlyForecast` and
/// the WeatherUI glyph helpers are all private and have changed shape across iOS
/// releases. Nothing here can be exercised off-device, so:
///
///   * the framework is dlopen'd rather than linked, so a missing .tbd or a
///     renamed framework is a runtime no-op instead of a build or load failure;
///   * every class and selector is resolved by name and nil-checked;
///   * every read is wrapped in @try, because an unrecognised selector on a
///     private class raises rather than returning nil;
///   * any failure leaves `hasLiveData == NO`, and the tile still draws.
///
/// Diagnostics are the point of the exercise: each step logs what it found, so a
/// device log identifies the exact class or selector that a given iOS build did
/// not provide, and the table can be corrected without guesswork.
@interface ERWeatherBridge : NSObject

+ (instancetype)sharedBridge;

/// Called on the main thread whenever `snapshot` may have changed. The content
/// view controller uses it to redraw; it must not retain the controller.
@property (nonatomic, copy, nullable) void (^onUpdate)(void);

/// Resolve the framework and kick the first refresh. Idempotent.
- (void)start;

/// Ask the Weather framework for a fresh model when the cached one is stale or
/// still missing. Cheap to call on every appearance.
- (void)refreshIfNeeded;

/// The latest value. Never nil; falls back to the placeholder snapshot.
- (ERWeatherSnapshot *)snapshot;

/// SF Symbol for a Weather framework condition code, with an isDay hint for the
/// codes that have distinct day/night glyphs (27–34, 45–47). Always returns a
/// usable symbol name — the generic "cloud.fill" is the last resort.
+ (NSString *)symbolNameForConditionCode:(NSInteger)code isDay:(BOOL)isDay;

/// Chinese condition text for a condition code, used only when the framework's
/// own localized string is unavailable. Mirrors the reference plugin's icon set
/// (晴天-白天 / 晴天-夜间 / 中度雾霾 / 雨夹雪 / 龙卷风 …).
+ (NSString *)conditionTextForConditionCode:(NSInteger)code isDay:(BOOL)isDay;

@end

NS_ASSUME_NONNULL_END
