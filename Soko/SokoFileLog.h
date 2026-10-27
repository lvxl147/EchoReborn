// 1.2.1-69 · Soko 独立文件日志
//
// 为什么不用 ERSokoLog：ERLogMirror 是 60 行环，SpringBoard 的 CC 心跳会把它冲掉，
// 编辑器里的判定（PosterBoard 进程）根本留不住。这里直接写自己的文件，按进程名
// 前缀区分，200KB 截断。
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void SokoFileLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#ifdef __cplusplus
}
#endif
