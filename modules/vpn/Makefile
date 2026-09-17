ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0

# Selected by CI (`make package THEOS_PACKAGE_SCHEME=rootless` / `=roothide`).
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ERConnectivityVPNModule

ERConnectivityVPNModule_FILES = ERConnectivityVPNModule.m
# /Library is rewritten by Theos per scheme: rootless -> /var/jb/Library,
# roothide -> jbroot-relative. Both are directories EchoReborn scans when it
# builds its 「添加控制项」 catalog.
ERConnectivityVPNModule_INSTALL_PATH = /Library/ControlCenter/Bundles
ERConnectivityVPNModule_PRIVATE_FRAMEWORKS = ControlCenterUIKit
ERConnectivityVPNModule_CFLAGS = -fobjc-arc -I..
# Theos stages a bundle's Info.plist through its resource directories (this is
# how EchoRebornPrefs gets its own). Keeping it in Resources/ rather than relying
# on a project-root plist, which bundle.mk does not stage.
ERConnectivityVPNModule_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk
