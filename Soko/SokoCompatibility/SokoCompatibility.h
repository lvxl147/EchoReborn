#import <Foundation/Foundation.h>
#import <dlfcn.h>

#import "../SokoRuntime/SokoPrivate.h"

FOUNDATION_EXPORT BOOL SokoLiquidAssClockEnabled(void);
FOUNDATION_EXPORT NSDictionary *SokoLiquidAssUserInfoForConfiguration(id configuration);
FOUNDATION_EXPORT BOOL SokoLiquidAssUserInfoUsesBottomLayout(NSDictionary *userInfo);
// 1.2.1-75 · 判断"这张壁纸本身是否配了 LiquidAss 时钟"（有 style 键才算）。
// 之前只用全局开关 lgHostEnabled("Clock") 判定，装了 LiquidAss 就等于接管，
// 于是标准编辑器钩子被整段跳过 —— 长按进自定义既不在底部也拖不动。
FOUNDATION_EXPORT BOOL SokoLiquidAssUserInfoIsActive(NSDictionary *userInfo);
