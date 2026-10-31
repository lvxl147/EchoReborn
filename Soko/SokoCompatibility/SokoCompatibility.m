#import "SokoCompatibility.h"

static NSString *const kSokoLiquidAssWidgetsAtTopKey = @"dylv.liquidass.clock.widgetsAtTop";
static NSString *const kSokoLiquidAssStyleKey = @"dylv.liquidass.clock.style";

// 1.2.1-67 · EchoReborn 集成：Soko 编译进 EchoReborn.dylib，与 GlassKit 同体
// ——上游的 dlopen(liquidass.dylib) 桥改为进程内直调 GlassKit 的 lgHostEnabled。
extern BOOL lgHostEnabled(NSString *feature);

BOOL SokoLiquidAssClockEnabled(void) {
	return lgHostEnabled(@"Clock");
}

NSDictionary *SokoLiquidAssUserInfoForConfiguration(id configuration) {
	if (![configuration respondsToSelector:@selector(loadUserInfoWithError:)]) return nil;

	NSDictionary *info = [configuration loadUserInfoWithError:NULL];
	return [info isKindOfClass:[NSDictionary class]] ? info : nil;
}

static BOOL SokoLiquidAssStyleIsClassic(NSDictionary *style) {
	if (![style isKindOfClass:[NSDictionary class]]) return NO;

	NSNumber *modern = style[@"modern"];
	NSNumber *weight = style[@"weight"];
	NSNumber *softness = style[@"softness"] ?: @60;
	if (![modern isKindOfClass:[NSNumber class]] || ![weight isKindOfClass:[NSNumber class]] || ![softness isKindOfClass:[NSNumber class]]) return NO;
	if (!isfinite(weight.doubleValue) || weight.doubleValue < 100.0 || weight.doubleValue > 1000.0) return NO;
	if (!isfinite(softness.doubleValue) || softness.doubleValue < 0.0 || softness.doubleValue > 100.0) return NO;

	return !modern.boolValue;
}

BOOL SokoLiquidAssUserInfoUsesBottomLayout(NSDictionary *userInfo) {
	if (![userInfo isKindOfClass:[NSDictionary class]]) return YES;
	if (SokoLiquidAssStyleIsClassic(userInfo[kSokoLiquidAssStyleKey])) return NO;

	id widgetsAtTop = userInfo[kSokoLiquidAssWidgetsAtTopKey];
	return ![widgetsAtTop isKindOfClass:[NSNumber class]] || ![widgetsAtTop boolValue];
}

BOOL SokoLiquidAssUserInfoIsActive(NSDictionary *userInfo) {
	if (![userInfo isKindOfClass:[NSDictionary class]]) return NO;
	return [userInfo objectForKey:kSokoLiquidAssStyleKey] != nil;
}
