#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// 1.2.1-68 · jbroot() 由 SokoPrivate.h 统一提供（roothide 有 <roothide.h>，
// rootless 走恒等兜底），这里不再直接 import，否则 rootless 构建直接失败。
#import "../SokoRuntime/SokoPrivate.h"

@interface SokoPosterModel : NSObject
+ (BOOL)isSupported;

+ (NSNumber *)bottomLayoutValueForComplicationLayout:(id)layout;
+ (void)setBottomLayoutValue:(NSNumber *)value forComplicationLayout:(id)layout;
+ (BOOL)complicationLayoutUsesBottomLayout:(id)layout;
+ (BOOL)applyPendingDefaultLayoutToConfiguration:(PRSPosterConfiguration *)configuration;

+ (void)encodeComplicationLayout:(id)layout withCoder:(id)coder;
+ (void)decodeComplicationLayout:(id)layout withCoder:(id)coder;
+ (void)copyBottomLayoutFromComplicationLayout:(id)source toComplicationLayout:(id)copy;
+ (BOOL)complicationLayout:(id)layout hasSameBottomLayoutAsComplicationLayout:(id)other;

// 1.2.1-79 · 每张壁纸的行偏移（double）。写进壁纸归档，由系统在"完成"时落盘，
// 取消不落盘 —— 这正是原版"取消不生效"的机制。
+ (NSNumber *)rowOffsetForComplicationLayout:(id)layout;
+ (void)setRowOffset:(NSNumber *)offset forComplicationLayout:(id)layout;
@end
