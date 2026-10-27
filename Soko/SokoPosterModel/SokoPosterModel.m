#import "SokoPosterModel.h"
#import "../SokoLog.h"

static NSString *const kSokoBottomLayoutCodingKey = @"SokoComplicationsUseBottomLayout";

static const void *kSokoBottomLayoutKey = &kSokoBottomLayoutKey;

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
	if (![self complicationLayoutUsesBottomLayout:layout] || ![coder respondsToSelector:@selector(encodeBool:forKey:)]) return;

	// 1.2.1-68 · 落盘判据：这一行出现在哪个进程，就说明那个进程的 filter 生效了
	// （只在"底部布局"被写进归档时打印，不会刷屏）。
	ERSokoLog(@"SOKO-ENC proc=%@ cls=%@ key=%@",
	          NSProcessInfo.processInfo.processName,
	          NSStringFromClass([layout class]), kSokoBottomLayoutCodingKey);

	[coder encodeBool:YES forKey:kSokoBottomLayoutCodingKey];
}

+ (void)decodeComplicationLayout:(id)layout withCoder:(id)coder {
	if (!layout || ![coder respondsToSelector:@selector(decodeBoolForKey:)]) return;

	if ([coder decodeBoolForKey:kSokoBottomLayoutCodingKey]) {
		[self setBottomLayoutValue:@YES forComplicationLayout:layout];
		ERSokoLog(@"SOKO-DEC proc=%@ cls=%@ bottom=1",
		          NSProcessInfo.processInfo.processName, NSStringFromClass([layout class]));
	}
}

+ (void)copyBottomLayoutFromComplicationLayout:(id)source toComplicationLayout:(id)copy {
	if (copy == source) return;

	NSNumber *value = [self bottomLayoutValueForComplicationLayout:source];
	if (value) [self setBottomLayoutValue:value forComplicationLayout:copy];
}

+ (BOOL)complicationLayout:(id)layout hasSameBottomLayoutAsComplicationLayout:(id)other {
	return [self complicationLayoutUsesBottomLayout:layout] == [self complicationLayoutUsesBottomLayout:other];
}

@end
