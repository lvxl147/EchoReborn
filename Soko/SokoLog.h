// 1.2.1-68 · 跨编译单元日志桥
//
// Soko 的每个 .m 是独立 TU，Tweak.xm 里的 ERLogMessage / ERLogInfo 都是 static，
// 拿不到。这里只声明一个 C 链接的函数，实现放在 Tweak.xm（用 ERLogRecord 落到
// ERPocketMirror / ERLogMirror 环，SSH 拉 plist 即可取证）。
//
// Tweak.xm 是 ObjC++（.xm），实现必须带 extern "C"，否则 C++ 名字修饰会让
// Soko 侧的 C 声明链接不到。
#import <Foundation/Foundation.h>

// 1.2.1-74 · SokoTrace 的编码长度（SpringBoard 侧解码用）
#define kSokoTraceCodeMask 0xFFULL
#define kSokoTracePayloadOffset 100000L

#ifdef __cplusplus
extern "C" {
#endif

void ERSokoLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// 1.2.1-74 · 海报进程（PosterBoard 等）无法写偏好域也无法写日志目录，只能发 Darwin
// 通知；SpringBoard 侧收到后落盘。code 见各调用点注释，payload 为附加整数。
void SokoTrace(int code, long payload);

#ifdef __cplusplus
}
#endif
