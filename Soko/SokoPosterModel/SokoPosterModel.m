#import "SokoPosterModel.h"
#import "../SokoLog.h"

static NSString *const kSokoBottomLayoutCodingKey = @"SokoComplicationsUseBottomLayout";
// 1.2.1-79 · 行偏移（pt，0 = 底部基准，-507 = 顶部）
static NSString *const kSokoRowOffsetCodingKey = @"ERSokoRowOffset";

static const void *kSokoBottomLayoutKey = &kSokoBottomLayoutKey;
static const void *kSokoRowOffsetKey = &kSokoRowOffsetKey;
static NSNumber *gSokoPendingRowOffset;

// 1.2.1-68 · marker 改名：原来是 moe.waru.soko.default-layout，与真·Soko 包抢同一
// 个文件（两台都装时谁先删谁赢）。换成 EchoReborn 自己的域。
static NSString *SokoPendingDefaultLayoutPath(void) {
	return jbroot(@"/var/mobile/Library/Preferences/com.strive.echoreborn.default-layout");
}

@implementation SokoPosterModel

+ (BOOL)isSupported {
	Class layoutClass = NSClassFromString(@"PRPosterComplicationLayout");
	if ([layoutClass instancesRespondToSelector:NSSelectorFromString(@"complicationsUseBottomLayout")]) return NO;

	return [layoutClass instancesRespondToSelector:@selector(encodeWithCoder:)] && [layoutClass instancesRespondToSelector:@selector(initWithCoder:)];
}

+ (NSNumber *)bottomLayoutValueForComplicationLayout:(id)layout {
	return layout ? objc_getAssociatedObject(layout, kSokoBottomLayoutKey) : nil;
}

+ (void)setBottomLayoutValue:(NSNumber *)value forComplicationLayout:(id)layout {
	if (layout) objc_setAssociatedObject(layout, kSokoBottomLayoutKey, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (BOOL)complicationLayoutUsesBottomLayout:(id)layout {
	return [[self bottomLayoutValueForComplicationLayout:layout] boolValue];
}

+ (NSNumber *)rowOffsetForComplicationLayout:(id)layout {
	return layout ? objc_getAssociatedObject(layout, kSokoRowOffsetKey) : nil;
}

+ (void)setPendingRowOffset:(NSNumber *)offset {
	gSokoPendingRowOffset = offset;
}

+ (void)setRowOffset:(NSNumber *)offset forComplicationLayout:(id)layout {
	if (layout) objc_setAssociatedObject(layout, kSokoRowOffsetKey, offset, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (BOOL)applyPendingDefaultLayoutToConfiguration:(PRSPosterConfiguration *)configuration {
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *markerPath = SokoPendingDefaultLayoutPath();
	if (!configuration || ![self isSupported] || ![fileManager fileExistsAtPath:markerPath]) return NO;
	if (![fileManager removeItemAtPath:markerPath error:nil]) return NO;

	Class configurationClass = NSClassFromString(@"PRMutablePosterConfiguration");
	id path = [configuration respondsToSelector:@selector(_path)] ? configuration._path : nil;
	if (!path || ![configurationClass instancesRespondToSelector:@selector(storeComplicationLayout:error:)]) return NO;

	PRMutablePosterConfiguration *mutableConfiguration = [[configurationClass alloc] _initWithPath:path];
	id layout = [mutableConfiguration loadComplicationLayoutWithError:nil];
	if (!layout) return NO;

	[self setBottomLayoutValue:@YES forComplicationLayout:layout];
	return [mutableConfiguration storeComplicationLayout:layout error:nil];
}

+ (void)encodeComplicationLayout:(id)layout withCoder:(id)coder {
	if (![coder respondsToSelector:@selector(encodeBool:forKey:)]) return;

	// 1.2.1-98 · 关键修复：原来这里有一句
	//   if (![self complicationLayoutUsesBottomLayout:layout]) return;
	// 只要"底部态"布尔没设上就直接返回，下面我们的偏移编码永远执行不到
	// （实测 SOKO-ENC-OFFSET 恒为 0 就是这个原因）。
	// 现在布尔与偏移各自独立编码：系统保存壁纸时这一趟必然会被调用，
	// 所以"完成才落盘、取消不落盘"由系统本身保证，归档也天然是按壁纸各一份。
	if ([self complicationLayoutUsesBottomLayout:layout]) {
		[coder encodeBool:YES forKey:kSokoBottomLayoutCodingKey];
	}

	NSNumber *offset = [self rowOffsetForComplicationLayout:layout] ?: gSokoPendingRowOffset;
	if (offset && [coder respondsToSelector:@selector(encodeDouble:forKey:)]) {
		[coder encodeDouble:offset.doubleValue forKey:kSokoRowOffsetCodingKey];
		ERSokoLog(@"SOKO-ENC-OFFSET proc=%@ v=%.1f",
		          NSProcessInfo.processInfo.processName, offset.doubleValue);
	}
}

+ (void)decodeComplicationLayout:(id)layout withCoder:(id)coder {
	if (!layout || ![coder respondsToSelector:@selector(decodeBoolForKey:)]) return;

	if ([coder decodeBoolForKey:kSokoBottomLayoutCodingKey]) {
		[self setBottomLayoutValue:@YES forComplicationLayout:layout];
		ERSokoLog(@"SOKO-DEC proc=%@ cls=%@ bottom=1",
		          NSProcessInfo.processInfo.processName, NSStringFromClass([layout class]));
	}

	if ([coder respondsToSelector:@selector(containsValueForKey:)] &&
	    [coder containsValueForKey:kSokoRowOffsetCodingKey]) {
		double offset = [coder decodeDoubleForKey:kSokoRowOffsetCodingKey];
		[self setRowOffset:@(offset) forComplicationLayout:layout];
		ERSokoLog(@"SOKO-DEC-OFFSET proc=%@ v=%.1f", NSProcessInfo.processInfo.processName, offset);
	}
}

+ (void)copyBottomLayoutFromComplicationLayout:(id)source toComplicationLayout:(id)copy {
	if (copy == source) return;

	NSNumber *value = [self bottomLayoutValueForComplicationLayout:source];
	if (value) [self setBottomLayoutValue:value forComplicationLayout:copy];

	NSNumber *offset = [self rowOffsetForComplicationLayout:source];
	if (offset) [self setRowOffset:offset forComplicationLayout:copy];
}

+ (BOOL)complicationLayout:(id)layout hasSameBottomLayoutAsComplicationLayout:(id)other {
	if ([self complicationLayoutUsesBottomLayout:layout] != [self complicationLayoutUsesBottomLayout:other]) return NO;

	// 1.2.1-79 · 偏移也要参与相等判断，否则系统认为"布局没变"而不落盘
	NSNumber *a = [self rowOffsetForComplicationLayout:layout];
	NSNumber *b = [self rowOffsetForComplicationLayout:other];
	return fabs(a.doubleValue - b.doubleValue) < 0.01 && (a != nil) == (b != nil);
}

@end
