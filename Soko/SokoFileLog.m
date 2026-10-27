#import "SokoFileLog.h"

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
