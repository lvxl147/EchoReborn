#import "SokoFileLog.h"
#import "SokoLog.h"
#import <notify.h>

// 1.2.1-70 · 从"直接写文件"改成 cfprefsd 键。
//
// 为什么：iOS 17.2.1 + rootless 下 SpringBoard 写 /var/mobile/Library/Logs/EchoReborn
// 是被挡的（同一目录 echoreborn.log 也是 0 字节，目录能建、文件写不进去）。
// 而 CFPreferences 走 cfprefsd 写入是通的（ERLogMirror 一直在更新）。
//
// 键：com.strive.echoreborn.preferences / ERSokoMirror（独立环 120 行 / 20KB），
// 不与 ERLogMirror（60 行）抢行，SSH 拉 plist 直接读。
static NSString *const kSokoLogSuite = @"com.strive.echoreborn.preferences";
static NSString *const kSokoLogKey = @"ERSokoMirror";
static NSString *const kSokoTraceName = @"com.strive.echoreborn.soko.trace";
static const NSUInteger kSokoLogRingLines = 120;
static const NSUInteger kSokoLogRingBytes = 20 * 1024;

// 1.2.1-71 · 双域写入。PosterBoard 写不了 com.strive.echoreborn.preferences（实测
// SpringBoard 的该域可写、PosterBoard 的完全没出现），但每个进程都一定写得进
// **自己的 bundleId 域**。所以同时写 own-domain，SSH 读
// /var/mobile/Library/Preferences/<bundleId>.plist 就能拿到 PosterBoard 的判定。
static void SokoAppendToSuite(NSString *suiteName, NSString *keyName, NSString *line) {
	CFStringRef suite = (__bridge CFStringRef)suiteName;
	CFStringRef key = (__bridge CFStringRef)keyName;

	NSMutableArray<NSString *> *lines = nil;
	CFPropertyListRef existing = CFPreferencesCopyAppValue(key, suite);
	if (existing) {
		if (CFGetTypeID(existing) == CFArrayGetTypeID()) {
			lines = [(__bridge NSArray *)existing mutableCopy];
		}
		CFRelease(existing);
	}
	if (!lines) lines = [NSMutableArray array];

	[lines addObject:line];
	while (lines.count > kSokoLogRingLines) [lines removeObjectAtIndex:0];
	while (lines.count > 1) {
		NSUInteger bytes = 0;
		for (NSString *entry in lines) bytes += entry.length + 1;
		if (bytes <= kSokoLogRingBytes) break;
		[lines removeObjectAtIndex:0];
	}

	CFPreferencesSetAppValue(key, (__bridge CFPropertyListRef)lines, suite);
	CFPreferencesAppSynchronize(suite);
}

void SokoFileLog(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);
	if (!message.length) return;

	static NSDateFormatter *formatter = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		formatter = [[NSDateFormatter alloc] init];
		formatter.dateFormat = @"HH:mm:ss.SSS";
	});

	NSString *line = [NSString stringWithFormat:@"%@ [%@] %@",
	                  [formatter stringFromDate:[NSDate date]],
	                  NSProcessInfo.processInfo.processName,
	                  message];

	@try {
		SokoAppendToSuite(kSokoLogSuite, kSokoLogKey, line);

		// own-domain 副本：PosterBoard / PosterKit 靠这条通道留下证据
		NSString *ownSuite = NSBundle.mainBundle.bundleIdentifier;
		if (ownSuite.length && ![ownSuite isEqualToString:kSokoLogSuite]) {
			SokoAppendToSuite(ownSuite, kSokoLogKey, line);
		}
	} @catch (__unused NSException *exception) {
	}
}

// 1.2.1-74/75 · 海报进程 → SpringBoard 的判定位通道。
//
// PosterBoard / PosterKit / MercuryPoster 既写不进宿主偏好域，也写不进自己域
// （实测连 com.apple.PosterBoard.plist 都不生成），唯一可用的跨进程通道是 Darwin 通知。
//
// 1.2.1-75 修正：原来所有判定共用一条通知名 + notify state，连续两笔会被系统合并，
// 实测 code=1 直接丢失（只收到 code=2）。改为**每条 code 一条独立通知名**
// （com.strive.echoreborn.soko.tr.<code>），payload 走各自 state，不再互相覆盖。
void SokoTrace(int code, long payload) {
	if (code < 0 || code >= 32) return;

	if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
		SokoFileLog(@"TRACE code=%d payload=%ld", code, payload);
		return;
	}

	static int tokens[32];
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		for (int i = 0; i < 32; i++) {
			tokens[i] = NOTIFY_TOKEN_INVALID;
			NSString *name = [NSString stringWithFormat:@"com.strive.echoreborn.soko.tr.%d", i];
			notify_register_check(name.UTF8String, &tokens[i]);
		}
	});
	if (tokens[code] == NOTIFY_TOKEN_INVALID) return;

	notify_set_state(tokens[code], (uint64_t)(payload + kSokoTracePayloadOffset));
	NSString *name = [NSString stringWithFormat:@"com.strive.echoreborn.soko.tr.%d", code];
	notify_post(name.UTF8String);
}
