ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0

# Selected by CI (`make package THEOS_PACKAGE_SCHEME=rootless` / `=roothide`).
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ERWeatherModule

ERWeatherModule_FILES = ERWeatherModule.m ERWeatherContentViewController.m ERWeatherBridge.m
# /Library is rewritten by Theos per scheme: rootless -> /var/jb/Library,
# roothide -> jbroot-relative. Both are directories EchoReborn scans when it
# builds its 「添加控制项」 catalog (see availableControlCatalog in Tweak.xm).
ERWeatherModule_INSTALL_PATH = /Library/ControlCenter/Bundles
ERWeatherModule_FRAMEWORKS = UIKit
# ControlCenterUIKit is only needed so the CCUIContentModule protocols have a
# real declaration to compile against; ERWeatherModule.h falls back to a minimal
# local declaration when the SDK's vendor headers lack one.
#
# Weather / WeatherUI are deliberately NOT linked. They are private frameworks
# and their .tbd stubs are not guaranteed to be present in the Theos SDK, so a
# hard link would turn a missing stub into a build failure on some SDK revisions.
# They are resolved at runtime with dlopen + NSClassFromString instead, which
# also degrades cleanly on an OS where the framework or a given class has been
# renamed (see ERWeatherBridge.m).
ERWeatherModule_PRIVATE_FRAMEWORKS = ControlCenterUIKit
ERWeatherModule_CFLAGS = -fobjc-arc -I..
# Theos stages a bundle's Info.plist through its resource directories (this is how
# the connectivity modules get theirs). Keeping it in Resources/ rather than a
# project-root plist, which bundle.mk does not stage.
ERWeatherModule_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk
