# Aggregate for the standalone Control Center bundles.
#
# 七个连接（Connectivity）磁贴，每个一块 bundle；见 ERConnectivityModule.h
# 说明为什么每个都需要自己的主类。
#
# weather 不属于「连接」家族：它是「实用工具」里的天气磁贴
# （ERWeatherModule.bundle，com.strive.echoreborn.weather），一块 4×2 的自绘内容
# 模块，而不是七个 CCUIToggleModule 开关磁贴之一。它放在这里是因为它属于**同一类
# 产物** —— 一块落在 /Library/ControlCenter/Bundles 下、只为让 EchoReborn 那个
# 「扫描磁盘目录」的「添加控制项」目录能提供该标识符而存在的 bundle —— 也因为这
# 个 Makefile 正是给子项目准备 -I.. 那条公共包含路径的地方。
#
# common.mk has to be loaded before aggregate.mk: this Makefile defines no
# instance of its own, and without it Theos runs `rm -rf ""` during
# `make clean` and the build dies before compiling anything.
include $(THEOS)/makefiles/common.mk

SUBPROJECTS += airplane cellular airdrop hotspot bluetooth wifi vpn weather

include $(THEOS_MAKE_PATH)/aggregate.mk
