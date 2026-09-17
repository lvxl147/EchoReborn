// LGLog implementation for the GlassKit port.
//
// Upstream LiquidAss keeps LGLog in Shared/LGSharedSupport.m together with a
// large amount of unrelated machinery. Only the logger is referenced by the
// files EchoReborn actually compiles (LGLiveBackdropView.m / LGGlassKit.x), so
// this stub provides just that, gated by EchoReborn's own LoggingEnabled
// preference (same domain and key as the tweak's main log). When logging is
// off LGLog compiles away to nothing, matching upstream's
// LGDebugLoggingEnabled() gate without pulling its debug plumbing in.
#import "LGLiveBackdropView.h"
#import <Foundation/Foundation.h>

static NSString *LGGlassLogPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = @"/var/mobile/Library/Logs/EchoReborn/echoreborn-liquidglass.log";
    });
    return path;
}

static BOOL LGGlassLoggingEnabled(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("LoggingEnabled"),
                                                        CFSTR("com.strive.echoreborn.preferences"));
    BOOL enabled = NO;
    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            enabled = CFBooleanGetValue((CFBooleanRef)value);
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double number = 0.0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number)) enabled = number != 0.0;
        }
        CFRelease(value);
    }
    return enabled;
}

void LGLog(NSString *format, ...) {
    if (!LGGlassLoggingEnabled()) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[ERLiquidGlass] %@\n", message];
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    NSString *directory = [LGGlassLogPath() stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:LGGlassLogPath()];
    if (!handle) {
        [@"" writeToFile:LGGlassLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:LGGlassLogPath()];
    }
    if (!handle) return;
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}
