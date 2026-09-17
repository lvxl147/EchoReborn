#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 「外观 / 偏移」滑杆行用的 cell（1.0.0 重写，见 ERSliderCell.m 顶部的说明）。
//
// plist 侧通过 `cellClass` = `ERSliderTrackCell` 引用本类；常量与 plist 必须逐字
// 一致，_tools 下的产物校验脚本会核对。
FOUNDATION_EXPORT NSString *const ERSliderCellClassName;

// 1.0.2：滑块圆点缩小到原来的 2/3。这个函数返回那枚统一的圆点图。
// 四个页面（增强设置 / 液态玻璃 / 锁屏控制项 / iOS27 Siri）共 12 个滑杆行
// 现在**全部**是自绘的 ERSliderTrackCell，圆点一律取自这里，因此大小完全一致；
// 不再去 hook Preferences 自带的原生滑杆 cell（原因见 ERUIHelpers.m 文件尾）。
FOUNDATION_EXPORT UIImage *ERSliderThumbImage(void);
