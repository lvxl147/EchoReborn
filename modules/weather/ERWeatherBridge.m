#import "ERWeatherBridge.h"
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
// 诊断日志
// ---------------------------------------------------------------------------
// 与 prefs 的 ERModuleLog 写同一个文件，只是标签换成 [WEATHER]，这样导出一次
// 日志就能同时看到设置侧与控制中心侧。文件写入失败时静默放弃 —— 日志永远不该
// 成为磁贴崩溃的原因。
static NSString *const kERWeatherLogPath = @"/var/mobile/Library/Logs/EchoReborn/echoreborn.log";

void ERWeatherLog(NSString *format, ...) {
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
///     [WEATHER] snapshot ver=1.0.8-16 live=0 city=天气 temp=--° ... hours=0
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

- (void)start {
    if (self.started) return;
    self.started = YES;
    [self openWeatherFrameworkIfNeeded];
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
    [self requestModelUpdate];
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
    // 15 秒内不重复拉取：磁贴会在每次展开/翻页时重建，不设节流就会刷日志。
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (self.refreshInFlight || (now - self.lastRefresh) < 15.0) return;
    [self requestModelUpdate];
}

- (void)requestModelUpdate {
    self.refreshInFlight = YES;
    self.lastRefresh = NSDate.date.timeIntervalSince1970;

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
            ERWeatherLog(@"model update ERROR domain=%@ code=%ld desc=%@",
                         error.domain, (long)error.code, error.localizedDescription);
        }
        [strongSelf rebuildSnapshot];
        // 当前候选刷新完仍然没有数据：换下一个再试一次。全部试完就停在最后一个，
        // 由 refreshIfNeeded 的 15 秒节流兜底，不会形成死循环。
        if (!strongSelf.snapshot.hasLiveData && [strongSelf advanceToNextCandidate]) {
            [strongSelf requestModelUpdate];
            return;
        }
        if (strongSelf.onUpdate) strongSelf.onUpdate();
    };

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(self.todayModel, selector, completion);
        ERWeatherLog(@"requested model update");
    } @catch (__unused NSException *exception) {
        self.refreshInFlight = NO;
        ERWeatherLog(@"executeModelUpdateWithCompletion: raised — falling back to cached model");
    }
}

#pragma mark - 快照

- (void)rebuildSnapshot {
    ERWeatherSnapshot *snapshot = [[ERWeatherSnapshot alloc] init];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];

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

    ERWeatherLog(@"snapshot ver=1.0.8-16 live=%d city=%@ temp=%@ cond=%@(%ld) highLow=%@ precip=%@ hours=%lu",
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
