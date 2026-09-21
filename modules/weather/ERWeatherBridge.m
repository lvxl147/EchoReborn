#import "ERWeatherBridge.h"
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <CoreLocation/CoreLocation.h>

// ---------------------------------------------------------------------------
// 诊断日志
// ---------------------------------------------------------------------------
// 与 prefs 的 ERModuleLog 写同一个文件，只是标签换成 [WEATHER]，这样导出一次
// 日志就能同时看到设置侧与控制中心侧。文件写入失败时静默放弃 —— 日志永远不该
// 成为磁贴崩溃的原因。
static NSString *const kERWeatherLogPath = @"/var/mobile/Library/Logs/EchoReborn/echoreborn.log";

void ERWeatherLog(NSString *format, ...) {
    // ------------------------------------------------------------------
    // 1.0.8-38 · **日志限流**：每秒最多 200 行，超出丢弃并累计。
    //
    // 20260920-0427 的日志里，天气模块 12 秒写了 **93,887 行 / 10MB**（≈870 行/秒）。
    // 后果有两个：① 导出困难；② 同一份日志里别的模块（锁屏音乐、横屏）的行
    // **被完全挤掉** —— 那一次 93,896 行里只有 8 行是别的模块的，等于没法排查。
    // 这个限流是纯粹的安全网：正常路径每秒最多几行，永远碰不到它。
    // 每个新窗口的第一条会把上一秒丢弃的数量补报一行，信息面不丢。
    // ------------------------------------------------------------------
    static CFTimeInterval windowStart = 0.0;
    static NSUInteger windowCount = 0;
    static NSUInteger windowDropped = 0;
    CFTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - windowStart >= 1.0) {
        windowStart = now;
        windowCount = 0;
        if (windowDropped) {
            NSUInteger dropped = windowDropped;
            windowDropped = 0;
            ERWeatherLog(@"[rate-limit] previous second dropped %lu line(s)", (unsigned long)dropped);
        }
    }
    if (++windowCount > 200) {
        windowDropped++;
        return;
    }

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ [WEATHER] %@\n", [NSDate date].description, message];
    NSString *directory = [kERWeatherLogPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kERWeatherLogPath];
    if (!handle) {
        [line writeToFile:kERWeatherLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *exception) {
    } @finally {
        @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
    }
}

// ---------------------------------------------------------------------------
// 取值助手
// ---------------------------------------------------------------------------
// 私有类的属性名跨版本会变，所以每一处读取都写成「按候选名逐个试，第一个非 nil
// 的胜出，并把命中的名字记进日志」。命中名会出现在 WEATHER: 行里，这是修正这张
// 候选表唯一可靠的依据。

/// 静默 KVC。私有类上不存在的键会抛 NSUnknownKeyException，必须拦住。
static id ERWValueQuietly(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// 按候选键列表逐个尝试；命中时把命中名写入 `hits`（供日志使用）。
static id ERWFirstValue(id object, NSArray<NSString *> *keys, NSString *label, NSMutableArray<NSString *> *hits) {
    for (NSString *key in keys) {
        id value = ERWValueQuietly(object, key);
        if (value && ![value isKindOfClass:[NSNull class]]) {
            if (hits) [hits addObject:[NSString stringWithFormat:@"%@=%@", label, key]];
            return value;
        }
    }
    return nil;
}

/// 无参选择器调用（同样静默）。
static id ERWPerformQuietly(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [object performSelector:selector];
#pragma clang diagnostic pop
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// 把 NSNumber / NSMeasurement / NSString / NSDictionary 统一变成 NSNumber。
/// 温度在不同版本里分别是裸 double、NSMeasurement 与带 value 键的字典。
static NSNumber *ERWNumber(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return value;
    if ([value isKindOfClass:[NSString class]]) {
        static NSNumberFormatter *formatter = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ formatter = [[NSNumberFormatter alloc] init]; });
        return [formatter numberFromString:value];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"value", @"temperature", @"amount", @"doubleValue"]) {
            NSNumber *inner = ERWNumber(value[key]);
            if (inner) return inner;
        }
        return nil;
    }
    // NSMeasurement（以及任何暴露 doubleValue 的对象）
    if ([value respondsToSelector:@selector(doubleValue)]) {
        @try {
            double raw = [value doubleValue];
            return @(raw);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

static NSString *ERWString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    // 显式转成 NSNumber 再取描述：`value` 的静态类型是 id，点语法需要已知的
    // 对象类型，否则是 -Werror 下的编译错误（方括号派发 + 显式转换两样都要）。
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value description];
    return nil;
}

/// 有符号整数温度文本："23°" / "-4°"。
static NSString *ERWDegreesText(NSNumber *celsius) {
    if (!celsius) return @"--°";
    return [NSString stringWithFormat:@"%ld°", (long)lround(celsius.doubleValue)];
}

// ---------------------------------------------------------------------------
// 值对象
// ---------------------------------------------------------------------------
@implementation ERWeatherHour
@end

@implementation ERWeatherSnapshot

- (instancetype)init {
    if ((self = [super init])) {
        // 占位态：磁贴一定要画出东西来，绝不返回空白矩形。
        _cityText = @"天气";
        _temperatureText = @"--°";
        _conditionText = @"暂无数据";
        _highLowText = @"";
        _precipText = @"";
        _conditionCode = 32;      // Sunny — 占位图标用晴天，视觉上最中性
        _isDay = YES;
        _hours = @[];
        _hasLiveData = NO;
    }
    return self;
}

@end

// ---------------------------------------------------------------------------
// 私有框架句柄与符号
// ---------------------------------------------------------------------------
// 声明放在这里（条件表之前），因为条件表里的 +symbolNameForConditionCode:isDay:
// 要优先用框架自带的字形函数。
//
// 解析顺序（每一步失败都只是降级，不会中断）：
//   1. dlopen Weather.framework / WeatherUI.framework（失败则继续 —— 类可能已随
//      进程一起加载）
//   2. dlsym 两个 C 函数：WAConditionsLineStringFromConditionCode /
//      WASymbolGlyphFromConditionCode（框架自带的文案与字形）
//   3. NSClassFromString 取 today model（见 -resolveTodayModel）
static void *gERWeatherHandle = NULL;
static BOOL gERWeatherHandleTried = NO;

// 刻意用 void * 返回而不是 NSString *：ARC 对「返回 ObjC 对象类型的函数指针」有
// 额外的所有权约定，而 dlsym 拿到的签名无从声明。统一按「非托管指针 + __bridge」
// 处理，语义明确，也不会有任何 ARC 诊断。
typedef void *(*ERWCodeFn)(NSInteger);

static ERWCodeFn gERWConditionsText = NULL;
static ERWCodeFn gERWSymbolGlyph = NULL;

// ---------------------------------------------------------------------------
// 桥接器
// ---------------------------------------------------------------------------
// 句柄与符号的声明见文件上方「私有框架句柄与符号」一节（条件表要用到字形函数）。
// 这里只接着写 model 的解析路径：
//   NSClassFromString(@"WALockscreenWidgetViewController") → -todayModel
//   这是参考插件取模型的路径；取不到再退到 +[WATodayModel todayModelForLocation:]
//   拿到 model 后按候选名读 forecastModel / dayForecasts / hourlyForecasts / city，
//   并调用 executeModelUpdateWithCompletion: 触发拉取。
@interface ERWeatherBridge ()
@property (nonatomic, strong, nullable) id todayModel;
// 1.0.6-15：候选 model 全表与当前游标。某个候选刷新失败时按顺序往后试下一个。
@property (nonatomic, strong) NSArray *candidates;
@property (nonatomic) NSUInteger candidateIndex;
@property (nonatomic, strong, nullable) id forecastModel;
@property (nonatomic, strong) ERWeatherSnapshot *snapshot;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL refreshInFlight;
@property (nonatomic) NSTimeInterval lastRefresh;
@property (nonatomic, assign) BOOL modelObserved;
@property (nonatomic, assign) BOOL updating;        // 1.0.8-35：requestModelUpdate 重入保护
@property (nonatomic, assign) BOOL rebuildScheduled; // 1.0.8-35：重建合并（同一轮只跑一次）
@property (nonatomic, weak) id kickstartedModel;     // 1.0.8-36：同一个模型只 kickstart 一次
@property (nonatomic, assign) NSInteger retryBudget;   // 1.0.8-38：一次刷新周期内最多换几次候选
// 1.0.8-41 · 公共 API 兜底（Weather 框架在本进程发不出请求时的备用数据源）
@property (nonatomic, assign) BOOL apiHasData;
@property (nonatomic, assign) CGFloat apiTemperature;
@property (nonatomic, copy)   NSString *apiConditionText;
@property (nonatomic, assign) NSInteger apiConditionCode;
@property (nonatomic, copy)   NSString *apiHighLowText;
// 1.0.8-42 · **这里必须是 strong** —— 1.0.8-41 写成了 `assign`：对象属性不持有，
// 临时数组一释放就成悬垂指针，下一轮 rebuildSnapshot 读它时 objc_retain 到垃圾内存
// → SIGBUS → SpringBoard 进安全模式（20260920-1406 的崩溃栈：objc_retain 崩在
// ERWeatherModule 的 NSURLSession 回调线程，正是读这个数组的地方）。
@property (nonatomic, strong) NSArray<NSNumber *> *apiHourly;
@property (nonatomic, copy)   NSArray<NSString *> *apiHourlyLabels;
@property (nonatomic, assign) NSTimeInterval apiLastFetch;
@property (nonatomic, assign) BOOL apiInFlight;
// 1.0.8-42 · 城市覆盖（设置页「天气 → 天气城市」）
@property (nonatomic, copy)   NSString *overrideCity;        // 上次已处理的城市名（用于发现变更）
@property (nonatomic, assign) CGFloat overrideLat;
@property (nonatomic, assign) CGFloat overrideLon;
@property (nonatomic, copy)   NSString *overrideName;        // 地理编码返回的城市名（展示用）
@property (nonatomic, assign) BOOL overrideResolved;
@property (nonatomic, assign) BOOL overrideInFlight;
@property (nonatomic, strong) NSMutableArray<NSString *> *resolvedNames;
@end

@implementation ERWeatherBridge

// ---------------------------------------------------------------------------
// 天气代码表
// ---------------------------------------------------------------------------
// 沿用 Weather 应用历代使用的 condition code 表 —— 参考插件的 30 个中文图标名
// （晴天-白天 / 晴天-夜间 / 中度雾霾 / 雨夹雪 / 龙卷风 …）正是按这张表拆分的，
// 其中 27–34 与 45–47 分昼夜两版，所以下表也按昼夜分别给符号与文案。
//
// 这张表只在框架自带文案/字形取不到时兜底；取到过框架值时以框架为准。
//
// 这两个 + 方法原先写在 @implementation ERWeatherBridge (ConditionTables)
// 分类里，但它们在 ERWeatherBridge.h 的 @interface 上声明过 —— Objective-C 要求
// 「接口里声明的方法必须由该类的**主** @implementation 实现」，写成分类会同时触发
//     category is implementing a method which will also be implemented by its primary class
//     method definition for '...' not found
// 两条诊断（本项目 -Werror，等于构建失败）。所以整节搬进主实现。

static BOOL ERWConditionCodeIsNight(NSInteger code) {
    switch (code) {
        case 27: case 29: case 31: case 33: case 45: case 46: case 47:
            return YES;
        default:
            return NO;
    }
}

+ (NSString *)symbolNameForConditionCode:(NSInteger)code isDay:(BOOL)isDay {
    // 框架自带的字形优先 —— 参考插件用的是 WeatherUI 的
    // systemSymbolForConditionCode: / sfSymbolForConditionCode: 同一族入口，
    // 它比本地表更贴合当前 iOS 版本的符号目录。取到的名字仍然要过一遍
    // systemImageNamed: 校验：符号名缺失时 UIImage 返回 nil、磁贴会渲染成空白，
    // 那比一个不太贴切的图标更像 bug。
    if (gERWSymbolGlyph) {
        @try {
            id glyph = (__bridge id)gERWSymbolGlyph(code);
            NSString *name = [glyph isKindOfClass:[NSString class]] ? glyph : nil;
            if (name.length && [UIImage systemImageNamed:name]) return name;
        } @catch (__unused NSException *exception) {
        }
    }

    // 昼夜由 code 自己决定（27–34 / 45–47），isDay 只在需要时做二次确认。
    BOOL night = ERWConditionCodeIsNight(code);
    if (!night && !isDay) night = YES;

    static NSDictionary<NSNumber *, NSString *> *daySymbols = nil;
    static NSDictionary<NSNumber *, NSString *> *nightSymbols = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        daySymbols = @{
            @0:  @"tornado",
            @1:  @"tropicalstorm",
            @2:  @"hurricane",
            @3:  @"cloud.bolt.rain.fill",
            @4:  @"cloud.bolt.rain.fill",
            @5:  @"cloud.sleet.fill",
            @6:  @"cloud.sleet.fill",
            @7:  @"cloud.sleet.fill",
            @8:  @"cloud.drizzle.fill",
            @9:  @"cloud.drizzle.fill",
            @10: @"cloud.hail.fill",
            @11: @"cloud.heavyrain.fill",
            @12: @"cloud.rain.fill",
            @13: @"cloud.snow.fill",
            @14: @"cloud.snow.fill",
            @15: @"wind.snow",
            @16: @"cloud.snow.fill",
            @17: @"cloud.hail.fill",
            @18: @"cloud.sleet.fill",
            @19: @"sun.dust.fill",
            @20: @"cloud.fog.fill",
            @21: @"sun.haze.fill",
            @22: @"smoke.fill",
            @23: @"wind",
            @24: @"wind",
            @25: @"thermometer.snowflake",
            @26: @"cloud.fill",
            @28: @"cloud.sun.fill",
            @30: @"cloud.sun.fill",
            @32: @"sun.max.fill",
            @34: @"sun.max.fill",
            @35: @"cloud.hail.fill",
            @36: @"thermometer.sun.fill",
            @37: @"cloud.sun.bolt.fill",
            @38: @"cloud.bolt.fill",
            @39: @"cloud.snow.fill",
            @40: @"cloud.heavyrain.fill",
            @41: @"cloud.sun.rain.fill",
            @42: @"snowflake",
            @43: @"cloud.snow.fill",
            @44: @"cloud.fill",
        };
        nightSymbols = @{
            @0:  @"tornado",
            @1:  @"tropicalstorm",
            @2:  @"hurricane",
            @3:  @"cloud.bolt.rain.fill",
            @4:  @"cloud.bolt.rain.fill",
            @5:  @"cloud.sleet.fill",
            @6:  @"cloud.sleet.fill",
            @7:  @"cloud.sleet.fill",
            @8:  @"cloud.drizzle.fill",
            @9:  @"cloud.drizzle.fill",
            @10: @"cloud.hail.fill",
            @11: @"cloud.heavyrain.fill",
            @12: @"cloud.rain.fill",
            @13: @"cloud.snow.fill",
            @14: @"cloud.snow.fill",
            @15: @"wind.snow",
            @16: @"cloud.snow.fill",
            @17: @"cloud.hail.fill",
            @18: @"cloud.sleet.fill",
            @19: @"moon.dust.fill",
            @20: @"cloud.fog.fill",
            @21: @"moon.haze.fill",
            @22: @"smoke.fill",
            @23: @"wind",
            @24: @"wind",
            @25: @"thermometer.snowflake",
            @26: @"cloud.fill",
            @27: @"cloud.moon.fill",
            @29: @"cloud.moon.fill",
            @31: @"moon.stars.fill",
            @33: @"moon.fill",
            @35: @"cloud.hail.fill",
            @36: @"thermometer.sun.fill",
            @38: @"cloud.moon.bolt.fill",
            @39: @"cloud.snow.fill",
            @40: @"cloud.heavyrain.fill",
            @42: @"snowflake",
            @43: @"cloud.snow.fill",
            @44: @"cloud.fill",
            @45: @"cloud.moon.rain.fill",
            @46: @"cloud.moon.rain.fill",
            @47: @"cloud.moon.bolt.fill",
        };
    });

    NSString *symbol = (night ? nightSymbols : daySymbols)[@(code)];
    if (!symbol) symbol = (night ? nightSymbols : daySymbols)[@(26)];   // 未知代码 → 阴天
    // 逐个校验 SF Symbol 是否真的存在；不存在的名字会在 UIImage 层返回 nil 并
    // 渲染成空白，所以这里直接换成一定可用的兜底。
    if ([UIImage systemImageNamed:symbol]) return symbol;
    for (NSString *fallback in @[@"cloud.fill", @"sun.max.fill", @"cloud.sun.fill"]) {
        if ([UIImage systemImageNamed:fallback]) return fallback;
    }
    return @"cloud.fill";
}

+ (NSString *)conditionTextForConditionCode:(NSInteger)code isDay:(BOOL)isDay {
    BOOL night = ERWConditionCodeIsNight(code);
    if (!night && !isDay) night = YES;

    switch (code) {
        case 0:  return @"龙卷风";
        case 1:  return @"热带风暴";
        case 2:  return @"飓风";
        case 3:  return @"强雷暴";
        case 4:  return @"雷阵雨";
        case 5:  return @"雨夹雪";
        case 6:  return @"雨夹雪";
        case 7:  return @"雨夹雪";
        case 8:  return @"冻毛毛雨";
        case 9:  return @"毛毛雨";
        case 10: return @"冻雨";
        case 11: return @"阵雨";
        case 12: return @"中雨";
        case 13: return night ? @"小雪-夜间" : @"小雪-白天";
        case 14: return @"小雪";
        case 15: return @"吹雪";
        case 16: return @"中雪";
        case 17: return @"冰雹";
        case 18: return @"雨夹雪";
        case 19: return @"浮尘";
        case 20: return @"雾";
        case 21: return @"中度雾霾";
        case 22: return @"烟霾";
        case 23: return @"大风";
        case 24: return @"大风";
        case 25: return @"寒冷";
        case 26: return @"阴天";
        case 27: return @"多云-夜间";
        case 28: return @"多云-白天";
        case 29: return @"多云-夜间";
        case 30: return @"多云-白天";
        case 31: return @"晴天-夜间";
        case 32: return @"晴天-白天";
        case 33: return @"晴时多云-夜间";
        case 34: return @"晴时多云-白天";
        case 35: return @"冰雹";
        case 36: return @"炎热";
        case 37: return @"零星雷暴";
        case 38: return @"雷阵雨";
        case 39: return @"零星阵雪";
        case 40: return @"大雨";
        case 41: return @"零星阵雨";
        case 42: return @"暴雪";
        case 43: return @"暴雪";
        case 44: return @"阴天";
        case 45: return @"零星阵雨";
        case 46: return @"小雪-夜间";
        case 47: return @"雷阵雨";
        default: return @"多云";
    }
}

+ (instancetype)sharedBridge {
    static ERWeatherBridge *bridge = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [[ERWeatherBridge alloc] init]; });
    return bridge;
}

- (instancetype)init {
    if ((self = [super init])) {
        _snapshot = [[ERWeatherSnapshot alloc] init];
        _resolvedNames = [NSMutableArray array];
    }
    return self;
}

#pragma mark - 框架解析

/// dlopen 只做一次。用 RTLD_LAZY 且不 RTLD_GLOBAL：本 bundle 只借它的类用，
/// 不把自己的符号推给别的镜像，避免与其它已注入的插件互相干扰。
- (void)openWeatherFrameworkIfNeeded {
    if (gERWeatherHandleTried) return;
    gERWeatherHandleTried = YES;

    for (NSString *path in @[
             @"/System/Library/PrivateFrameworks/Weather.framework/Weather",
             @"/System/Library/PrivateFrameworks/WeatherUI.framework/WeatherUI",
         ]) {
        void *handle = dlopen(path.UTF8String, RTLD_LAZY);
        if (!handle) {
            ERWeatherLog(@"dlopen failed for %@ (%s)", path, dlerror() ?: "no error");
            continue;
        }
        if (!gERWeatherHandle) gERWeatherHandle = handle;
        ERWeatherLog(@"dlopen ok: %@", path);
    }

    if (gERWeatherHandle) {
        gERWConditionsText = (ERWCodeFn)dlsym(gERWeatherHandle, "WAConditionsLineStringFromConditionCode");
        gERWSymbolGlyph = (ERWCodeFn)dlsym(gERWeatherHandle, "WASymbolGlyphFromConditionCode");
    }
    ERWeatherLog(@"symbols: conditionsText=%@ symbolGlyph=%@",
                 gERWConditionsText ? @"yes" : @"no", gERWSymbolGlyph ? @"yes" : @"no");
}

/// 收集所有**可能**拿得到预报的候选 model，按优先级排好。
///
/// 1.0.6-15（第 2 条）：原来是「取到第一个非 nil 就 return」。实测日志证明这条路
/// 走不通 ——
///
///     [WEATHER] requested model update
///     [WEATHER] model update completed (args: nil / NSError)
///     [WEATHER] snapshot ver=1.0.9-30 live=0 city=天气 temp=--° ... hours=0
///     [WEATHER] resolved keys: none
///
/// 也就是说：确实拿到了一个 model（否则会先打 "no today model available"），
/// 但它身上 **forecastModel / city / currentForecast / dayForecasts /
/// hourlyForecasts 一个都读不出来** —— `resolved keys: none`。这就是
/// `[[WATodayAutoupdatingLocationModel alloc] init]` 出来的裸实例：类存在、
/// 构造得出来、但没有任何数据与位置，`executeModelUpdateWithCompletion:` 因此
/// 直接回调 NSError。原来的写法在它身上就停了，后面的候选根本没机会试。
///
/// 现在改成返回**全部**候选，由 -start 逐个试着读，取第一个真能读出预报字段的。
/// 拿不到数据的候选不再挡路，而「哪个类可用、哪个不可用」会一行行写进日志。
- (NSArray *)resolveTodayModelCandidates {
    // 1.0.6-13（第 2 条）：补两个候选。
    //
    // 用户报「天气模块不显示」。现有的三个候选在 iOS 17 上可能一个都不命中 ——
    // WALockscreenWidgetViewController 的 -init 在某些版本上并不产出 todayModel，
    // WATodayModel 的裸实例也拿不到缓存。WATodayAutoupdatingLocationModel 是
    // WATodayModel 的子类，天气 App 与锁屏天气视图用的就是它；WAForecastModel
    // 则直接是持有 dayForecasts / hourlyForecasts 的那一层。
    // 多一个候选不会改变任何已有行为：取不到就继续往下试，全部失败仍然是占位态。
    NSArray<NSString *> *controllerNames = @[@"WALockscreenWidgetViewController",
                                             @"WATodayAutoupdatingLocationModel",
                                             @"WATodayModel",
                                             @"WeatherTodayModel",
                                             @"WAForecastModel"];
    // 1.0.6-15：类方法工厂提到**实例构造之前**。
    //
    // 裸 `[[WATodayAutoupdatingLocationModel alloc] init]` 是没有位置的空壳（见
    // 上面的日志分析），而系统自己的入口是 `+autoupdatingLocationModel` 这类工厂
    // —— 它才会把当前城市/定位接上。原来只在 `-todayModel` 取不到时才试工厂，
    // 而且只对名字里含 "TodayModel" 的类试，等于把最有用的一条路排在最后。
    NSArray<NSString *> *factoryNames = @[@"autoupdatingLocationModel",
                                          @"todayModelForLocation:",
                                          @"modelWithLocation:",
                                          @"currentModel",
                                          @"sharedModel",
                                          @"sharedWeatherModel"];

    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *name in controllerNames) {
        Class cls = NSClassFromString(name);
        if (!cls) {
            ERWeatherLog(@"class missing: %@", name);
            continue;
        }

        for (NSString *factory in factoryNames) {
            SEL selector = NSSelectorFromString(factory);
            if (![cls respondsToSelector:selector]) continue;
            @try {
                id built = ((id (*)(id, SEL, id))objc_msgSend)(cls, selector, nil);
                if (built) {
                    [candidates addObject:built];
                    ERWeatherLog(@"candidate +[%@ %@] -> %@", name, factory, NSStringFromClass([built class]));
                }
            } @catch (__unused NSException *exception) {
            }
        }

        id instance = nil;
        @try {
            instance = [[cls alloc] init];
        } @catch (__unused NSException *exception) {
            instance = nil;
        }
        if (!instance) continue;

        // 实例方法（WALockscreenWidgetViewController 就是这条）。
        id model = ERWPerformQuietly(instance, @"todayModel");
        if (model) {
            [candidates addObject:model];
            ERWeatherLog(@"candidate -[%@ todayModel] -> %@", name, NSStringFromClass([model class]));
            continue;
        }
        [candidates addObject:instance];
        ERWeatherLog(@"candidate bare %@ instance", name);
    }
    return candidates;
}

#pragma mark - 刷新

static void ERWeatherPrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef userInfo);

- (void)start {
    if (self.started) return;
    self.started = YES;
    [self openWeatherFrameworkIfNeeded];
    // 1.0.8-44 · 设置改完**立即生效**。
    // 用户反馈「天气好像要注销才有反应」—— 原因是城市改动要等 10 分钟的取数节流窗口。
    // 这里监听本插件统一的 ReloadPrefs：设置页一改，就清掉节流并立刻重取。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    ERWeatherPrefsChangedCallback,
                                    CFSTR("com.strive.echoreborn/ReloadPrefs"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    NSArray *candidates = [self resolveTodayModelCandidates];
    self.candidates = candidates;
    ERWeatherLog(@"candidate count=%lu", (unsigned long)candidates.count);
    if (!candidates.count) {
        ERWeatherLog(@"no today model available — tile stays on the placeholder");
        return;
    }
    // 1.0.6-15（第 2 条）：逐个试，取第一个真能读出预报字段的。
    //
    // 只按「类存在、构造得出来」选会选到空壳（见 -resolveTodayModelCandidates 的
    // 日志分析）。这里改成用结果说话：每个候选都跑一遍 -rebuildSnapshot，谁拿到
    // 数据就用谁；全部拿不到时保留最后一个候选，再请求一次刷新 —— 有些 model 必须
    // 先 `executeModelUpdateWithCompletion:` 才有内容，那一次回调会把数据补上。
    for (NSUInteger index = 0; index < candidates.count; index++) {
        self.candidateIndex = index;
        self.todayModel = candidates[index];
        [self rebuildSnapshot];
        if (self.snapshot.hasLiveData) {
            ERWeatherLog(@"model accepted: %@", NSStringFromClass([self.todayModel class]));
            break;
        }
        ERWeatherLog(@"model rejected (no readable forecast fields): %@", NSStringFromClass([self.todayModel class]));
    }
    if (!self.snapshot.hasLiveData) {
        // 1.0.8-33：全部候选都是空的时候，原来「保留最后一个候选」——而最后一个是
        // WAForecastModel，它**没有任何拉数据的入口**（日志里那句
        // `no update selector on WAForecastModel` 就是这么来的），于是永远读缓存、
        // 温度永远是 --°。参考实现用的是 WATodayModel 系
        // （WATodayAutoupdatingLocationModel / WATodayModel），它才有
        // autoUpdate / 定位 / executeModelUpdateWithCompletion: 这些入口。
        // 这里改成按「能不能拉数据」挑，不再停在最后一个。
        NSUInteger best = [self bestDryCandidateIndex];
        if (best != self.candidateIndex) {
            self.candidateIndex = best;
            self.todayModel = self.candidates[best];
            ERWeatherLog(@"dry run: switch to fetchable candidate #%lu %@",
                         (unsigned long)best, NSStringFromClass([self.todayModel class]));
        }
    }
    [self kickstartWeatherModel];
    [self requestModelUpdate];
}

/// 在「全部候选都没数据」时挑一个最可能拉得到数据的：① 有更新入口 ② 名字带 Today ③ 第一个
- (NSUInteger)bestDryCandidateIndex {
    static NSArray<NSString *> *updateSelectors = nil;
    if (!updateSelectors) {
        updateSelectors = @[@"executeModelUpdateWithCompletion:", @"updateModelWithCompletion:",
                            @"refreshModelWithCompletion:", @"fetchWeatherDataWithCompletion:",
                            @"reloadModelWithCompletion:", @"updateForecast"];
    }
    for (NSUInteger index = 0; index < self.candidates.count; index++) {
        id model = self.candidates[index];
        for (NSString *name in updateSelectors) {
            if ([model respondsToSelector:NSSelectorFromString(name)]) return index;
        }
    }
    for (NSUInteger index = 0; index < self.candidates.count; index++) {
        if ([NSStringFromClass([self.candidates[index] class]) containsString:@"Today"]) return index;
    }
    return 0;
}

/// 换下一个候选。返回 NO 表示已经试完，不再重试。
- (BOOL)advanceToNextCandidate {
    NSUInteger next = self.candidateIndex + 1;
    if (!self.candidates.count || next >= self.candidates.count) return NO;
    self.candidateIndex = next;
    self.todayModel = self.candidates[next];
    ERWeatherLog(@"advance to candidate #%lu: %@", (unsigned long)next, NSStringFromClass([self.todayModel class]));
    return YES;
}

- (void)refreshIfNeeded {
    [self start];
    if (!self.todayModel) return;
    self.retryBudget = 2;   // 1.0.8-38：每个刷新周期最多换 2 次候选，杜绝任何形式的长时间空转
    // 15 秒内不重复拉取：磁贴会在每次展开/翻页时重建，不设节流就会刷日志。
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (self.refreshInFlight || (now - self.lastRefresh) < 15.0) return;
    [self requestModelUpdate];
}

- (void)requestModelUpdate {
    // 1.0.8-35 · **重入保护** —— 20260920-0343 两次 SpringBoard 崩溃的根因就是这里。
    //
    // 崩溃栈：
    //   [主线程] ERWeatherModule → -[NSObject valueForKey:] → valueForUndefinedKey:
    //            → NSException → 展开时踩到线程栈保护页 → EXC_BAD_ACCESS(SIGSEGV)
    //   Kernel Triage 同时报 “mach_vm_allocate_kernel failed” 与 STACK GUARD —— 栈溢出。
    //
    // 成因是一条**无界递归**：
    //   requestModelUpdate → kickstartWeatherModel → setAutoUpdate:/setLocationServicesActive:
    //   → Weather 框架同步回调 todayModelWantsUpdate: → requestModelUpdate → …
    // 1.0.8-33 把 kickstart 挂在 resolveTodayModelCandidates（很少走）里，所以这条环没被触发；
    // 1.0.8-34 我把它挪进刷新入口后，每次刷新都会踩进去 —— 于是开机几秒就崩，看起来像"卡在注销界面"。
    if (self.updating) {
        ERWeatherLog(@"requestModelUpdate: re-entered — bail out (recursion guard)");
        return;
    }
    self.updating = YES;
    self.refreshInFlight = YES;
    self.lastRefresh = NSDate.date.timeIntervalSince1970;

    // 1.0.8-38 · **这里不再挑候选** —— 那正是 870 次/秒空转的源头。
    //
    // 实机日志（20260920-0427）：12 秒里刷了 93,887 行，其中
    //   `advance to candidate #2` 与 `dry run: switch to fetchable candidate #1` 各 10,432 次 ——
    // 一进一出正好配对，形成乒乓：
    //   requestModelUpdate →（本处）把候选打回 #1 → 请求 → 失败 → completion 推进到 #2
    //   → 异步重试 requestModelUpdate →（本处）又打回 #1 → …
    // 因为 bestDryCandidateIndex 永远返回「第一个有更新入口的候选」= #1，
    // 而 completion 的 advanceToNextCandidate 往 #2 走，两者方向相反，永远到不了头。
    //
    // 「挑一个能拉数据的候选」只在 resolveTodayModelCandidates 里做**一次**（初始定锚），
    // 这里只负责 kickstart + 用当前候选发请求。
    [self kickstartWeatherModel];

    // 1.0.6-16（第 2 条）：刷新入口不止一个名字。
    //
    // 上一版日志里这行是 `no executeModelUpdateWithCompletion: — reading cached
    // model only`，也就是说选中的 model 压根没有这个方法，我们只能读它自带的
    // 缓存 —— 而那份缓存只有一个城市名（北京），没有温度。Weather 私有类的刷新
    // 入口在不同版本里叫法不同，这里按候选表逐个试，命中哪个记哪个。
    NSArray<NSString *> *updateSelectors = @[@"executeModelUpdateWithCompletion:",
                                             @"updateModelWithCompletion:",
                                             @"refreshModelWithCompletion:",
                                             @"fetchWeatherDataWithCompletion:",
                                             @"reloadModelWithCompletion:",
                                             @"updateForecast"];
    SEL selector = NULL;
    NSString *selectorName = nil;
    for (NSString *name in updateSelectors) {
        SEL candidate = NSSelectorFromString(name);
        if ([self.todayModel respondsToSelector:candidate]) { selector = candidate; selectorName = name; break; }
    }
    if (!selector) {
        // 所有刷新入口都没有，退回直接读它现有的缓存。
        ERWeatherLog(@"no update selector on %@ — reading cached model only",
                     NSStringFromClass([self.todayModel class]));
        self.refreshInFlight = NO;
        self.updating = NO;
        return;
    }
    ERWeatherLog(@"refresh via -[%@ %@]", NSStringFromClass([self.todayModel class]), selectorName);

    __weak typeof(self) weakSelf = self;
    void (^completion)(id, id) = ^(id first, id second) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.refreshInFlight = NO;
        ERWeatherLog(@"model update completed (args: %@ / %@)",
                     first ? NSStringFromClass([first class]) : @"nil",
                     second ? NSStringFromClass([second class]) : @"nil");
        // 1.0.6-15（第 2 条）：失败原因必须落盘。
        //
        // 1.0.6-14 的日志里这一行是 `model update completed (args: nil / NSError)`
        // —— 只知道失败，不知道为什么。domain / code / 描述打出来之后，一次就能
        // 分清是「没有定位」「没有网络」还是「私有类的入口签名变了」。
        if ([second isKindOfClass:[NSError class]]) {
            NSError *error = (NSError *)second;
            // 1.0.8-41 · 框架请求失败 → 走公共 API 兜底（异步、自带 10 分钟节流）
            dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf fetchWeatherFromPublicAPI]; });
            // 日志里每次都是 `com.apple.weather.errorDomain code=4`，
            // 但 localizedDescription 只有一句「未能完成操作」—— 看不出到底是
            // 没有定位、没有网络、还是权限被拒。userInfo 里有真正的原因。
            ERWeatherLog(@"model update ERROR domain=%@ code=%ld desc=%@ userInfo=%@",
                         error.domain, (long)error.code, error.localizedDescription, error.userInfo);
        }
        [strongSelf rebuildSnapshot];

        // ------------------------------------------------------------------
        // 1.0.8-37 · 这里就是 1.0.8-34/35/36 崩溃的**确切位置**。
        //
        // 崩溃栈（20260920-2004，逐帧）：
        //   Weather  -[WATodayModel executeModelUpdateWithCompletion:]
        //   ERWeatherModule  +52672 / +53356        ← 就是本 block
        //   Weather  -[WATodayModel _locationUpdateCompleted:error:completion:]
        //   Weather  __49-[WATodayModel executeModelUpdateWithCompletion:]_block_invoke
        //   Weather  -[WATodayAutoupdatingLocationModel _executeLocationUpdateWithCompletion:]
        //   Weather  -[WATodayModel executeModelUpdateWithCompletion:]   ← 回到起点
        // 这个 7 层结构在栈里**重复了上百次**，最后溢到线程栈保护页 → SIGSEGV。
        //
        // 两个致命的细节：
        //   ① 这个 completion 是**被 Weather 在自己的调用栈里同步调用**的；
        //   ② 我 1.0.8-35 把 `updating = NO` 放在了本 block 的**最前面**，
        //      于是轮到下面那句 [strongSelf requestModelUpdate] 时守卫已经放开，
        //      重入保护形同虚设 —— 这就是为什么 1.0.8-35 修完依然崩。
        //
        // 修法（两条必须同时满足）：
        //   A. `updating` 只在**真正结束**时才放行（放到 retry 判断之后）；
        //   B. 换候选重试改成**异步**，绝不在 Weather 的调用栈里同步递归。
        //     异步之后即使重试链很长，也只是 runloop 上的一次次独立任务，栈不再增长；
        //     而 advanceToNextCandidate 在候选耗尽时返回 NO，链自然终止。
        // ------------------------------------------------------------------
        // 1.0.8-38：**带 NSError 的失败不再走候选 walk**。
        // 日志里每次失败都是 `com.apple.weather.errorDomain code=4`（定位类错误）——
        // 换候选模型解决不了"拿不到定位"，只会把同一个错误重试上千次。
        // 真正的重试交给 refreshIfNeeded 的 15 秒节流。
        BOOL hardFailure = [second isKindOfClass:[NSError class]];
        BOOL retry = NO;
        if (!hardFailure && !strongSelf.snapshot.hasLiveData && strongSelf.retryBudget > 0) {
            retry = [strongSelf advanceToNextCandidate];
            if (retry) strongSelf.retryBudget -= 1;
        }
        strongSelf.updating = NO;   // ← 到这里才放行（A）
        if (retry) {
            __weak typeof(strongSelf) weakRetry = strongSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakRetry) inner = weakRetry;
                if (inner) [inner requestModelUpdate];
            });
            return;
        }
        if (strongSelf.onUpdate) strongSelf.onUpdate();
    };

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(self.todayModel, selector, completion);
        ERWeatherLog(@"requested model update");
    } @catch (__unused NSException *exception) {
        self.refreshInFlight = NO;
        self.updating = NO;
        ERWeatherLog(@"executeModelUpdateWithCompletion: raised — falling back to cached model");
    }
}

#pragma mark - 模型自动更新（1.0.8-31）

// ---------------------------------------------------------------------------
// 1.0.8-31 · 让 Weather 框架自己把数据拉回来 —— 而不是只读缓存。
//
// 对照参考实现（com.simon.ccweathermodule 1.0.4，逆向可得）它的做法是三件事：
//   ① 给模型打开三个开关：autoUpdate / isLocationTrackingEnabled / locationServicesActive
//      —— Weather 框架只有看到这几个位才会自己发起网络请求与定位；
//   ② 把自己注册成模型的 delegate / 观察者 —— 数据是**异步**回来的，
//      只在 viewDidAppear 读一次必然读到空壳（temp=--°、hours=0）；
//   ③ 主动调 executeModelUpdateWithCompletion: 兜底。
// 我们原本只做了 ③，而且选中的 WAForecastModel 上根本没有那个方法 → 永远读缓存。
//
// 全部用 respondsToSelector 探测 + @try 兜底：私有类的这些开关在 iOS 版本之间
// 名字会变，缺哪个都不该让磁贴挂掉。
// ---------------------------------------------------------------------------
// 1.0.8-40 · 模型能力表（可重复调用，最多 4 次）。
// 1.0.8-39 把它内联在 kickstart 里、且在"只 kickstart 一次"的守卫之后，等于从没执行过。
- (void)dumpModelCapabilitiesIfNeeded {
    static NSUInteger dumpCount = 0;
    if (dumpCount >= 4) return;
    dumpCount++;

    // ------------------------------------------------------------------
    // 1.0.8-39 · 诊断：把这个模型的「能力表」打全。
    //
    // 现在已知：`executeModelUpdateWithCompletion:` 每次都失败在
    //   com.apple.weather.errorDomain code=4，且 userInfo 是**空的**；
    // 同时 probe 显示城市缓存里有「北京」，但没有任何读数（temp=--°）。
    // 参考实现（com.simon.ccweathermodule）额外链接了 CoreLocation、并且有
    // -_kickstartLocationManager / reverseGeocodeLocation: 这套动作 ——
    // 说明它需要**自己把定位踢起来**。
    // 这一行把「模型有没有 setLocation:/setCity:、当前 location/city 是什么」
    // 全部记下来，下一版就能直接补上缺的那一步，而不是继续猜。
    // ------------------------------------------------------------------
    id model = self.todayModel;
    NSMutableArray<NSString *> *caps = [NSMutableArray array];
    NSArray<NSString *> *probes = @[@"setLocation:", @"setCity:", @"setWeatherLocation:",
                                    @"setIsLocationTrackingEnabled:", @"setLocationServicesActive:",
                                    @"setAutoUpdate:", @"executeModelUpdateWithCompletion:",
                                    @"updateLocation:", @"setDelegate:"];
    for (NSString *name in probes) {
        if ([model respondsToSelector:NSSelectorFromString(name)]) [caps addObject:name];
    }
    id locationValue = ERWValueQuietly(model, @"location");
    id cityValue = ERWValueQuietly(model, @"city");
    id locModelValue = ERWValueQuietly(model, @"locationModel");
    ERWeatherLog(@"model caps: %@ | supports=%@ | location=%@ | city=%@ | locationModel=%@",
                 NSStringFromClass([model class]), caps,
                 locationValue ? [NSString stringWithFormat:@"%@<%@>", NSStringFromClass([locationValue class]), locationValue] : @"(nil)",
                 cityValue ? [NSString stringWithFormat:@"%@<%@>", NSStringFromClass([cityValue class]), cityValue] : @"(nil)",
                 locModelValue ? NSStringFromClass([locModelValue class]) : @"(nil)");
}

static void ERWeatherPrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ERWeatherBridge *bridge = (__bridge ERWeatherBridge *)observer;
        if (!bridge) return;
        bridge.apiLastFetch = 0.0;     // 清掉公共 API 的 10 分钟节流
        bridge.lastRefresh = 0.0;      // 清掉 refreshIfNeeded 的 15 秒节流（不清会挡住立即刷新）
        bridge.refreshInFlight = NO;
        bridge.retryBudget = 2;
        [bridge refreshIfNeeded];
        ERWeatherLog(@"prefs changed — refresh now (throttle cleared)");
    });
}

- (void)kickstartWeatherModel {
    if (!self.todayModel) return;
    // 1.0.8-36 · **同一个模型实例只 kickstart 一次**。
    //
    // 这个方法现在挂在刷新入口上（每次刷新都会走到）。反复 setAutoUpdate: / setDelegate: /
    // addObserver: 会让 Weather 框架一次次回调，虽然 1.0.8-35 已经断了递归环，
    // 但"每 15 秒重设一次开关"本身没有任何收益，只会增加与私有框架交互的面。
    // 记一次实例就够了 —— 换模型（候选切换）时会自动重新 kickstart。
    if (self.kickstartedModel == self.todayModel) {
        // 1.0.8-40 · **跳过 kickstart 时也要打一次能力表**。
        // 1.0.8-39 把能力表放在了这条守卫**后面**，结果：模型在用户清空日志之前就
        // 已经 kickstart 过，之后每次刷新都被守卫跳过 —— 那份日志里 `kickstart`
        // 与 `caps` 一行都没有，诊断白做。现在改成"跳过也打"。
        [self dumpModelCapabilitiesIfNeeded];
        return;
    }
    self.kickstartedModel = self.todayModel;
    ERWeatherLog(@"kickstart: begin on %@", NSStringFromClass([self.todayModel class]));

    // ① 打开自动更新 / 定位跟踪
    NSArray<NSString *> *flagSelectors = @[
        @"setAutoUpdate:", @"setAutoUpdateEnabled:",
        @"setIsLocationTrackingEnabled:", @"setLocationTrackingEnabled:",
        @"setLocationServicesActive:", @"setLocationServicesEnabled:",
    ];
    NSMutableArray<NSString *> *flagHits = [NSMutableArray array];
    for (NSString *name in flagSelectors) {
        SEL selector = NSSelectorFromString(name);
        if (![self.todayModel respondsToSelector:selector]) continue;
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(self.todayModel, selector, YES);
            [flagHits addObject:name];
        } @catch (__unused NSException *exception) {
            ERWeatherLog(@"kickstart: %@ raised", name);
        }
    }
    // 命中的名字写进日志 —— 这是下一次修正候选表唯一可靠的依据（不命中也要记，
    // 否则无法区分「类上没有这个方法」和「代码没跑到」）。
    ERWeatherLog(@"kickstart: flag hits=%@", flagHits.count ? flagHits : @"(none)");

    [self dumpModelCapabilitiesIfNeeded];


    // ② 注册成 delegate（WATodayModel 的回调是 informally declared 的三个方法，见文件尾部）
    if ([self.todayModel respondsToSelector:@selector(setDelegate:)]) {
        id current = ERWValueQuietly(self.todayModel, @"delegate");
        if (current != self) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(self.todayModel, @selector(setDelegate:), self);
                ERWeatherLog(@"kickstart: registered as model delegate");
            } @catch (__unused NSException *exception) {
                ERWeatherLog(@"kickstart: setDelegate: raised");
            }
        }
    }

    // ③ KVO 兜底：不走 delegate 的模型（比如 WAForecastModel 直接持有数据），
    //    数据回来时会改这些属性，一改我们就重画。
    if (!self.modelObserved) {
        self.modelObserved = YES;
        for (NSString *key in @[@"hourlyForecasts", @"dailyForecasts", @"currentConditions",
                                @"todayForecast", @"forecast", @"weatherData"]) {
            @try {
                [self.todayModel addObserver:self forKeyPath:key
                                     options:NSKeyValueObservingOptionNew context:nil];
            } @catch (__unused NSException *exception) {
                // 私有类上没有这个键 → 不观察它，继续试下一个
            }
        }
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (object != self.todayModel) {
        // 不是我们观察的对象 —— 必须交回给上层，否则会吞掉别人的 KVO
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    ERWeatherLog(@"model changed keyPath=%@", keyPath);
    [self scheduleRebuild];
}

// 1.0.8-35 · 所有「数据回来了」的回调统一走这里：**异步 + 合并**。
//
// 原来 observeValueForKeyPath / todayModel:forecastWasUpdated: / todayModelUpdated: 都
// 直接同步调 -rebuildSnapshot，而 rebuildSnapshot 会通过 valueForKey: 去读被观察的键 ——
// 一旦读的动作本身又触发一次通知，就变成同步递归（配合 kickstart 打开的 autoUpdate，
// 就是 20260920-0343 那次栈溢出崩溃）。
// 现在：同一轮内的多次通知只排一次任务，且永远在下一个 runloop 上执行。
- (void)scheduleRebuild {
    if (self.rebuildScheduled) return;
    self.rebuildScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.rebuildScheduled = NO;
        [strongSelf rebuildSnapshot];
        if (strongSelf.snapshot.hasLiveData && strongSelf.onUpdate) strongSelf.onUpdate();
    });
}

// Weather 框架的 WATodayModelDelegate 回调（informal protocol，按名字命中就生效）
- (void)todayModel:(id)model forecastWasUpdated:(id)forecast {
    ERWeatherLog(@"delegate: forecastWasUpdated");
    [self scheduleRebuild];   // 1.0.8-35：改走异步合并，杜绝同步递归
}

- (void)todayModelUpdated:(id)model {
    ERWeatherLog(@"delegate: todayModelUpdated");
    [self scheduleRebuild];   // 同上
}

- (void)todayModelWantsUpdate:(id)model {
    // 1.0.8-35：**绝不在委托回调里同步再调 requestModelUpdate**。
    // 那会和 kickstart 里打开的 autoUpdate 组成无界递归（见 requestModelUpdate 顶部说明，
    // 那正是栈溢出崩溃的成因）。这里只记一条日志，真正的刷新交给 15 秒节流的 refreshIfNeeded。
    ERWeatherLog(@"delegate: todayModelWantsUpdate (ignored — throttled refresh owns the cycle)");
}

#pragma mark - 公共 API 兜底（1.0.8-41）

// ---------------------------------------------------------------------------
// 1.0.8-41 · 为什么需要这个兜底。
//
// 诊断（20260920-1315 的 model caps）证明模型**什么都不缺**：
//   · supports=( setIsLocationTrackingEnabled:, setLocationServicesActive:,
//                executeModelUpdateWithCompletion: )
//   · location=WFLocation< geoLocation:<+39.92,+116.42> >   ← 定位是有的（北京）
// 但 executeModelUpdateWithCompletion: 每次都失败在
//   com.apple.weather.errorDomain code=4，且 userInfo 为空。
// 结论：不是我们缺哪一步，而是 Weather 框架的网络请求**按 App 颁发凭据**，
// SpringBoard 进程没有天气的 entitlement，请求在框架内部就被拒了。
//
// 所以这里换一条完全独立的路：用模型里已有的经纬度直接问公共天气 API
// （Open-Meteo，无需任何密钥/entitlement），拿到温度与天气码后填进快照。
// 触发时机：Weather 框架那次请求**失败之后**才走，成功时仍优先用框架数据。
// ---------------------------------------------------------------------------

/// Open-Meteo 的 WMO 天气码 → 中文描述 + 我们图标用的 conditionCode
static void ERWeatherMapWMOCode(NSInteger code, NSString **textOut, NSInteger *iconCodeOut) {
    // 图标用的 conditionCode 空间沿用 Weather 框架的（3200=多云、32=晴、11=雨…）
    if (code == 0)      { *textOut = @"晴";   *iconCodeOut = 32; }
    else if (code <= 2) { *textOut = @"多云"; *iconCodeOut = 3200; }
    else if (code == 3) { *textOut = @"阴";   *iconCodeOut = 3200; }
    else if (code <= 48){ *textOut = @"雾";   *iconCodeOut = 3200; }
    else if (code <= 57){ *textOut = @"毛毛雨"; *iconCodeOut = 11; }
    else if (code <= 67){ *textOut = @"雨";   *iconCodeOut = 11; }
    else if (code <= 77){ *textOut = @"雪";   *iconCodeOut = 13; }
    else if (code <= 82){ *textOut = @"阵雨"; *iconCodeOut = 11; }
    else if (code <= 86){ *textOut = @"阵雪"; *iconCodeOut = 13; }
    else                { *textOut = @"雷阵雨"; *iconCodeOut = 4; }
}

/// 设置页「天气城市」。每次现读，改完即生效。
static NSString *ERWeatherCityOverride(void) {
    NSString *value = nil;
    CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("Weather.CityOverride"),
                                                      CFSTR("com.strive.echoreborn.preferences"));
    if (raw) {
        if (CFGetTypeID(raw) == CFStringGetTypeID()) value = [(__bridge NSString *)raw copy];
        CFRelease(raw);
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)fetchWeatherFromPublicAPI {
    if (self.apiInFlight || self.overrideInFlight) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - self.apiLastFetch < 600.0) return;   // 10 分钟一次足够

    // ── ① 城市覆盖（设置页「天气城市」）─────────────────────────────────
    // 用户填了城市就走 Open-Meteo 的地理编码拿坐标（顺带拿到标准城市名做展示），
    // 不再依赖天气框架缓存的那个城市（它可能是「北京」而不是用户所在的位置）。
    NSString *wanted = ERWeatherCityOverride();
    if (wanted.length) {
        if (![wanted isEqualToString:self.overrideCity]) {
            self.overrideCity = wanted;
            self.overrideResolved = NO;
            [self geocodeCityName:wanted];
            return;                       // 解析回来之后，下一次刷新就会带上坐标
        }
        if (!self.overrideResolved) return;
        [self fetchForecastAtLatitude:self.overrideLat longitude:self.overrideLon city:self.overrideName];
        return;
    }

    // ── ② 默认：天气框架模型里缓存的位置 ────────────────────────────────
    id wfLocation = ERWValueQuietly(self.todayModel, @"location");
    id clLocation = ERWValueQuietly(wfLocation, @"geoLocation");
    if (![clLocation isKindOfClass:[CLLocation class]]) {
        ERWeatherLog(@"public api: no location on model — skip");
        return;
    }
    CLLocationCoordinate2D coordinate = [(CLLocation *)clLocation coordinate];
    if (coordinate.latitude == 0.0 && coordinate.longitude == 0.0) {
        ERWeatherLog(@"public api: zero coordinate — skip");
        return;
    }
    NSString *cachedCity = ERWString(ERWValueQuietly(self.todayModel, @"city"));
    [self fetchForecastAtLatitude:coordinate.latitude longitude:coordinate.longitude city:cachedCity];
}

/// Open-Meteo 地理编码：城市名 → 坐标 + 标准名
- (void)geocodeCityName:(NSString *)name {
    self.overrideInFlight = YES;
    NSString *urlText = [NSString stringWithFormat:
        @"https://geocoding-api.open-meteo.com/v1/search?name=%@&count=1&language=zh&format=json",
        [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    ERWeatherLog(@"geocoding: %@", urlText);
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlText]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.overrideInFlight = NO;
            NSDictionary *root = nil;
            @try { root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; }
            @catch (__unused NSException *exception) { root = nil; }
            NSArray *results = ERWValueQuietly(root, @"results");
            if (![results isKindOfClass:[NSArray class]] || !results.count) {
                ERWeatherLog(@"geocoding: no result for %@", name);
                return;
            }
            NSDictionary *first = results.firstObject;
            NSNumber *lat = ERWValueQuietly(first, @"latitude");
            NSNumber *lon = ERWValueQuietly(first, @"longitude");
            NSString *resolved = ERWString(ERWValueQuietly(first, @"name"));
            if (![lat isKindOfClass:[NSNumber class]] || ![lon isKindOfClass:[NSNumber class]]) {
                ERWeatherLog(@"geocoding: bad result");
                return;
            }
            strongSelf.overrideLat = [lat doubleValue];
            strongSelf.overrideLon = [lon doubleValue];
            strongSelf.overrideName = resolved.length ? resolved : name;
            strongSelf.overrideResolved = YES;
            strongSelf.apiLastFetch = 0.0;   // 解析完立即允许取一次天气
            ERWeatherLog(@"geocoding: %@ -> %.4f,%.4f", strongSelf.overrideName,
                         strongSelf.overrideLat, strongSelf.overrideLon);
        }];
    [task resume];
}

- (void)fetchForecastAtLatitude:(CGFloat)latitude longitude:(CGFloat)longitude city:(NSString *)city {

    self.apiInFlight = YES;
    self.apiLastFetch = NSDate.date.timeIntervalSince1970;
    NSString *urlText = [NSString stringWithFormat:
        @"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        @"&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min"
        @"&hourly=temperature_2m&forecast_days=1&timezone=auto",
        latitude, longitude];
    ERWeatherLog(@"public api: fetching %@", urlText);

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlText]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.apiInFlight = NO;
            if (error || !data) {
                ERWeatherLog(@"public api: failed %@", error.localizedDescription ?: @"(no data)");
                return;
            }
            id json = nil;
            @try { json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; }
            @catch (__unused NSException *exception) { json = nil; }
            if (![json isKindOfClass:[NSDictionary class]]) {
                ERWeatherLog(@"public api: unexpected payload");
                return;
            }
            NSDictionary *root = (NSDictionary *)json;
            NSDictionary *current = ERWValueQuietly(root, @"current");
            NSNumber *temperature = ERWValueQuietly(current, @"temperature_2m");
            NSNumber *weatherCode = ERWValueQuietly(current, @"weather_code");
            if (![temperature isKindOfClass:[NSNumber class]] || ![weatherCode isKindOfClass:[NSNumber class]]) {
                ERWeatherLog(@"public api: missing current fields");
                return;
            }

            NSString *conditionText = nil;
            NSInteger iconCode = 32;
            ERWeatherMapWMOCode([weatherCode integerValue], &conditionText, &iconCode);

            strongSelf.apiTemperature = [temperature floatValue];
            strongSelf.apiConditionText = conditionText;
            strongSelf.apiConditionCode = iconCode;

            NSDictionary *daily = ERWValueQuietly(root, @"daily");
            NSArray *highs = ERWValueQuietly(daily, @"temperature_2m_max");
            NSArray *lows  = ERWValueQuietly(daily, @"temperature_2m_min");
            if ([highs isKindOfClass:[NSArray class]] && highs.count &&
                [lows isKindOfClass:[NSArray class]] && lows.count) {
                strongSelf.apiHighLowText = [NSString stringWithFormat:@"%ld° / %ld°",
                                             (long)lround([highs.firstObject doubleValue]),
                                             (long)lround([lows.firstObject doubleValue])];
            }

            NSDictionary *hourly = ERWValueQuietly(root, @"hourly");
            NSArray *hourlyTemps = ERWValueQuietly(hourly, @"temperature_2m");
            NSArray *hourlyTimes = ERWValueQuietly(hourly, @"time");
            if ([hourlyTemps isKindOfClass:[NSArray class]]) {
                NSMutableArray<NSNumber *> *values = [NSMutableArray array];
                for (NSUInteger i = 0; i < hourlyTemps.count && i < 24; i++) {
                    id v = hourlyTemps[i];
                    if ([v isKindOfClass:[NSNumber class]]) [values addObject:v];
                }
                strongSelf.apiHourly = values;
                // 时间标签："13时"。hourly.time[i] 形如 "2026-09-20T13:00"，取 T 后面的小时。
                NSMutableArray<NSString *> *labels = [NSMutableArray array];
                if ([hourlyTimes isKindOfClass:[NSArray class]]) {
                    for (NSUInteger i = 0; i < hourlyTimes.count && i < 24; i++) {
                        NSString *stamp = [NSString stringWithFormat:@"%@", hourlyTimes[i] ?: @""];
                        NSArray *parts = [stamp componentsSeparatedByString:@"T"];
                        NSString *hm = parts.count > 1 ? parts[1] : stamp;
                        NSArray *hmParts = [hm componentsSeparatedByString:@":"];
                        [labels addObject:hmParts.count ? [NSString stringWithFormat:@"%@时", hmParts[0]] : @""];
                    }
                }
                strongSelf.apiHourlyLabels = labels;
            }

            strongSelf.apiHasData = YES;
            ERWeatherLog(@"public api: ok temp=%.1f code=%ld cond=%@ hours=%lu",
                         strongSelf.apiTemperature, (long)strongSelf.apiConditionCode,
                         strongSelf.apiConditionText, (unsigned long)strongSelf.apiHourly.count);
            [strongSelf scheduleRebuild];
        }];
    [task resume];
}

#pragma mark - 快照

- (void)rebuildSnapshot {
    ERWeatherSnapshot *snapshot = [[ERWeatherSnapshot alloc] init];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];

    // 1.0.8-41 · **公共 API 兜底优先级**：框架那路发不出请求（code=4），所以只要
    // API 已经有数据，就直接用它拼快照 —— 磁贴一定能画出真实的温度与天气。
    if (self.apiHasData) {
        snapshot.temperatureText = [NSString stringWithFormat:@"%ld°",
                                    (long)lround(self.apiTemperature)];
        snapshot.conditionText = self.apiConditionText;
        snapshot.conditionCode = self.apiConditionCode;
        snapshot.highLowText = self.apiHighLowText;
        snapshot.precipText = @"";
        // 城市名：设置了「天气城市」就用地理编码返回的标准名，否则沿用框架缓存的
        if (self.overrideResolved && self.overrideName.length) snapshot.cityText = self.overrideName;
        else if (self.snapshot.cityText.length) snapshot.cityText = self.snapshot.cityText;
        // 小时条：每 2 小时取一个点，最多 6 个，与原实现的密度接近
        if (self.apiHourly.count) {
            NSMutableArray<ERWeatherHour *> *hours = [NSMutableArray array];
            for (NSUInteger i = 0; i + 1 < self.apiHourly.count; i += 2) {
                ERWeatherHour *hour = [[ERWeatherHour alloc] init];
                hour.temperatureText = [NSString stringWithFormat:@"%ld°",
                                        (long)lround(self.apiHourly[i].doubleValue)];
                if (i < self.apiHourlyLabels.count) hour.timeText = self.apiHourlyLabels[i];
                [hours addObject:hour];
            }
            snapshot.hours = hours;
        }
        snapshot.hasLiveData = YES;
        self.snapshot = snapshot;
        ERWeatherLog(@"snapshot (public api) temp=%@ cond=%@ hours=%lu",
                     snapshot.temperatureText, snapshot.conditionText,
                     (unsigned long)snapshot.hours.count);
        return;
    }


    id forecast = ERWPerformQuietly(self.todayModel, @"forecastModel");
    if (!forecast) forecast = ERWFirstValue(self.todayModel, @[@"forecastModel", @"forecast", @"model"], @"forecast", hits);
    if (forecast) self.forecastModel = forecast;
    id source = self.forecastModel ?: self.todayModel;

    // ---- 城市名 ----
    id city = ERWFirstValue(source, @[@"city", @"location", @"cityName"], @"city", hits);
    NSString *cityText = ERWString(ERWFirstValue(city, @[@"name", @"cityName", @"displayName", @"locality"], @"city.name", hits));
    if (!cityText.length) cityText = ERWString(city);
    if (cityText.length) snapshot.cityText = cityText;

    // ---- 当前温度 ----
    // 优先读「当前」条目，其次日预报，最后小时预报的第一项。
    NSNumber *temperature = nil;
    id current = ERWFirstValue(source, @[@"currentForecast", @"currentConditions", @"currentObservation"], @"current", hits);
    if (current) temperature = ERWNumber(ERWFirstValue(current, @[@"temperature", @"temp", @"temperatureCelsius"], @"current.temperature", hits));

    NSArray *dayForecasts = ERWFirstValue(source, @[@"dayForecasts", @"dailyForecasts", @"days"], @"dayForecasts", hits);
    NSArray *hourlyForecasts = ERWFirstValue(source, @[@"hourlyForecasts", @"hourlyForecast", @"hours"], @"hourlyForecasts", hits);

    id firstDay = ([dayForecasts isKindOfClass:[NSArray class]] && dayForecasts.count) ? dayForecasts.firstObject : nil;
    if (!temperature) {
        temperature = ERWNumber(ERWFirstValue(firstDay, @[@"currentTemperature", @"temperature", @"temp"], @"day.temperature", hits));
    }

    // ---- 最高 / 最低 ----
    NSNumber *high = ERWNumber(ERWFirstValue(firstDay, @[@"high", @"highTemperature", @"maxTemperature"], @"day.high", hits));
    NSNumber *low = ERWNumber(ERWFirstValue(firstDay, @[@"low", @"lowTemperature", @"minTemperature"], @"day.low", hits));
    if (high || low) {
        snapshot.highLowText = [NSString stringWithFormat:@"最高 %@  最低 %@",
                                high ? ERWDegreesText(high) : @"--°",
                                low ? ERWDegreesText(low) : @"--°"];
    }

    // ---- 天气代码 / 昼夜 / 文案 ----
    NSInteger conditionCode = 32;
    id codeValue = ERWFirstValue(current, @[@"conditionCode", @"weatherCode"], @"current.conditionCode", hits);
    if (!codeValue) codeValue = ERWFirstValue(firstDay, @[@"conditionCode", @"weatherCode"], @"day.conditionCode", hits);
    if (!codeValue) {
        id firstHour = ([hourlyForecasts isKindOfClass:[NSArray class]] && hourlyForecasts.count) ? hourlyForecasts.firstObject : nil;
        codeValue = ERWFirstValue(firstHour, @[@"conditionCode", @"weatherCode"], @"hour.conditionCode", hits);
    }
    NSNumber *numericCode = ERWNumber(codeValue);
    if (numericCode) conditionCode = numericCode.integerValue;

    id isDayValue = ERWFirstValue(current, @[@"isDay", @"daylight"], @"current.isDay", hits);
    if (!isDayValue) isDayValue = ERWFirstValue(firstDay, @[@"isDay", @"daylight"], @"day.isDay", hits);
    BOOL isDay = isDayValue ? [isDayValue boolValue] : YES;
    snapshot.conditionCode = conditionCode;
    snapshot.isDay = isDay;
    snapshot.conditionText = [self conditionTextForCode:conditionCode isDay:isDay];

    // ---- 降水概率 ----
    NSNumber *precip = ERWNumber(ERWFirstValue(current, @[@"precipitationChance", @"chanceOfRain", @"precipitationProbability"], @"current.precip", hits));
    if (!precip) precip = ERWNumber(ERWFirstValue(firstDay, @[@"precipitationChance", @"chanceOfRain", @"precipitationProbability"], @"day.precip", hits));

    // ---- 小时预报 ----
    if ([hourlyForecasts isKindOfClass:[NSArray class]] && hourlyForecasts.count) {
        NSMutableArray<ERWeatherHour *> *hours = [NSMutableArray array];
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"H时";
        });
        // 同一时刻的温度/代码在第一条小时预报与当前温度之间可能不一致；小时内
        // 第一项统一标成「现在」，并把当前温度灌进去，避免出现「现在 24° 而
        // 下面第一格也是 24° 但当前大标题却是 21°」这种自相矛盾。
        NSUInteger limit = MIN(hourlyForecasts.count, (NSUInteger)12);
        for (NSUInteger index = 0; index < limit; index++) {
            id entry = hourlyForecasts[index];
            ERWeatherHour *hour = [[ERWeatherHour alloc] init];
            NSNumber *hourTemp = ERWNumber(ERWFirstValue(entry, @[@"temperature", @"temp", @"temperatureCelsius"], @"hour.temperature", hits));
            NSNumber *hourCode = ERWNumber(ERWFirstValue(entry, @[@"conditionCode", @"weatherCode"], @"hour.code", hits));
            id hourIsDay = ERWFirstValue(entry, @[@"isDay", @"daylight"], @"hour.isDay", hits);
            id date = ERWFirstValue(entry, @[@"date", @"time", @"forecastDate"], @"hour.date", hits);

            hour.temperatureText = ERWDegreesText(hourTemp);
            hour.conditionCode = hourCode ? hourCode.integerValue : conditionCode;
            hour.isDay = hourIsDay ? [hourIsDay boolValue] : YES;
            hour.isNow = (index == 0);
            if (hour.isNow) {
                hour.timeText = @"现在";
                if (temperature) hour.temperatureText = ERWDegreesText(temperature);
                hour.conditionCode = conditionCode;
                hour.isDay = isDay;
            } else if ([date isKindOfClass:[NSDate class]]) {
                hour.timeText = [formatter stringFromDate:date];
            } else {
                hour.timeText = [NSString stringWithFormat:@"%lu时", (unsigned long)(index + 1)];
            }
            [hours addObject:hour];
        }
        snapshot.hours = hours;
    }

    if (precip) {
        // 框架给的是 0–1 的小数，也有版本直接给 0–100。
        double raw = precip.doubleValue;
        double percent = (raw <= 1.0) ? raw * 100.0 : raw;
        snapshot.precipText = [NSString stringWithFormat:@"降水 %.0f%%", percent];
    }

    // ---- 判定是否拿到了真实数据 ----
    BOOL live = (temperature != nil) || (high != nil) || (dayForecasts.count > 0) || (hourlyForecasts.count > 0);
    snapshot.hasLiveData = live;
    if (temperature) snapshot.temperatureText = ERWDegreesText(temperature);
    if (!live) {
        snapshot.diagnostic = @"no forecast fields readable from the Weather framework";
    }
    self.snapshot = snapshot;

    ERWeatherLog(@"snapshot ver=1.0.9-30 live=%d city=%@ temp=%@ cond=%@(%ld) highLow=%@ precip=%@ hours=%lu",
                 live, snapshot.cityText, snapshot.temperatureText, snapshot.conditionText,
                 (long)conditionCode, snapshot.highLowText, snapshot.precipText,
                 (unsigned long)snapshot.hours.count);
    ERWeatherLog(@"resolved keys: %@", self.resolvedNames.count ? [self.resolvedNames componentsJoinedByString:@" | "] : @"none");
    if (hits.count) ERWeatherLog(@"probe hits: %@", [hits componentsJoinedByString:@" "]);
    // 磁贴每次展开/翻页都会重建快照，不清空的话这份记录会无界增长。
    // 已经写进日志了，留着也没有第二个用途。
    [self.resolvedNames removeAllObjects];
}

/// 框架自带的本地化文案优先；取不到再用本文件的中文表。
- (NSString *)conditionTextForCode:(NSInteger)code isDay:(BOOL)isDay {
    if (gERWConditionsText) {
        @try {
            NSString *text = (__bridge NSString *)gERWConditionsText(code);
            if ([text isKindOfClass:[NSString class]] && text.length) return text;
        } @catch (__unused NSException *exception) {
        }
    }
    return [ERWeatherBridge conditionTextForConditionCode:code isDay:isDay];
}

- (ERWeatherSnapshot *)snapshot {
    return _snapshot ?: [[ERWeatherSnapshot alloc] init];
}

@end

NSString *ERWeatherDebugSummary(void) {
    ERWeatherSnapshot *snapshot = ERWeatherBridge.sharedBridge.snapshot;
    return [NSString stringWithFormat:@"live=%d city=%@ temp=%@ cond=%@ hours=%lu",
            snapshot.hasLiveData, snapshot.cityText, snapshot.temperatureText,
            snapshot.conditionText, (unsigned long)snapshot.hours.count];
}
