#import "SokoFileLog.h"

static NSString *const kSokoLogDirectory = @"/var/mobile/Library/Logs/EchoReborn";
static NSString *const kSokoLogFileName = @"soko.log";
static const unsigned long long kSokoLogLimitBytes = 256 * 1024;

void SokoFileLog(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);
	if (!message.length) return;

	static NSString *path = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		[[NSFileManager defaultManager] createDirectoryAtPath:kSokoLogDirectory
		                          withIntermediateDirectories:YES
		                                           attributes:nil
		                                                error:nil];
		path = [kSokoLogDirectory stringByAppendingPathComponent:kSokoLogFileName];
	});

	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
	NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
	                  [formatter stringFromDate:[NSDate date]],
	                  NSProcessInfo.processInfo.processName,
	                  message];

	@try {
		NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
		if (!handle) {
			[line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
			return;
		}
		[handle seekToEndOfFile];
		if ([handle offsetInFile] > kSokoLogLimitBytes) {
			[handle truncateFileAtOffset:0];
		}
		[handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
		[handle closeFile];
	} @catch (__unused NSException *exception) {
	}
}
