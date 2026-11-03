ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0

# Selected by CI (`make package THEOS_PACKAGE_SCHEME=rootless` / `=roothide`).
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ERShortcut17Module

ERShortcut17Module_FILES = ERShortcut17Module.m
# /Library is rewritten by Theos per scheme: rootless -> /var/jb/Library,
# roothide -> jbroot-relative. Both are directories EchoReborn scans when it
# builds its 「添加控制项」 catalog, so a slot bundle is discovered exactly the
# way the seven 连接 bundles are.
ERShortcut17Module_INSTALL_PATH = /Library/ControlCenter/Bundles
ERShortcut17Module_PRIVATE_FRAMEWORKS = ControlCenterUIKit
ERShortcut17Module_CFLAGS = -fobjc-arc -I..
ERShortcut17Module_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk
