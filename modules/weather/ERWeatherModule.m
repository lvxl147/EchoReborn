#import "ERWeatherModule.h"
#import "ERWeatherContentViewController.h"
#import <unistd.h>

// ---------------------------------------------------------------------------
// Control Center 主类（Info.plist 的 NSPrincipalClass）
// ---------------------------------------------------------------------------
// 参考插件走的是「协议式内容模块」而不是「继承某个 CCUI 类」：
// 它的二进制里 CCUIContentModule / CCUIContentModuleContentViewController 只作为
// **协议名**出现在 __objc_protolist，_OBJC_CLASS_$_ 里没有任何 CCUI* 条目，主类
// 的基类是 NSObject。本类照做 —— 这是能自绘 4×2 磁贴的那条路径；EchoReborn 的
// 连接模块继承 CCUIToggleModule，那是因为它要的是「开关磁贴」语义，不是自绘。
//
// Control Center 的契约很简单：把主类实例化，然后读它的 contentViewController。
// 因此这个类刻意只有一件事 —— 惰性造出内容控制器并返回它。
//
// 名字必须与两处字面一致：
//   modules/weather/Resources/Info.plist -> <key>NSPrincipalClass</key>
//   modules/weather/Makefile             -> BUNDLE_NAME = ERWeatherModule

@interface ERWeatherModule : NSObject <CCUIContentModule>
/// 内部持有的具体类型。对外暴露的 -contentViewController 刻意声明成协议里的
/// 原样类型（UIViewController<CCUIContentModuleContentViewController> *），
/// 而不是收窄成 ERWeatherContentViewController * —— 协变返回类型在协议一致性
/// 检查上容易出杂音，统一成协议签名最省事，也没有任何信息损失。
@property (nonatomic, strong, nullable) ERWeatherContentViewController *content;
@end

@implementation ERWeatherModule

// 记一行加载日志。控制中心侧的 [WEATHER] 日志都写进
// /var/mobile/Library/Logs/EchoReborn/echoreborn.log，与设置侧同一个文件。
+ (void)load {
    ERWeatherLog(@"ERWeatherModule bundle loaded ver=1.0.7-19 (pid %d)", (int)getpid());
}

// 惰性构造：磁贴可能被反复销毁重建（翻页、编辑模式），只在这里建一次
// 控制器、之后复用，避免每次都重新走一遍 Auto Layout 构建。
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!_content) {
        _content = [[ERWeatherContentViewController alloc] init];
        ERWeatherLog(@"contentViewController created");
    }
    return _content;
}

@end
