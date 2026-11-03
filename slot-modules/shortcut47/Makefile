ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0

# Selected by CI (`make package THEOS_PACKAGE_SCHEME=rootless` / `=roothide`).
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ERShortcut47Module

ERShortcut47Module_FILES = ERShortcut47Module.m
# /Library is rewritten by Theos per scheme: rootless -> /var/jb/Library,
# roothide -> jbroot-relative. Both are directories EchoReborn scans when it
# builds its 「添加控制项」 catalog, so a slot bundle is discovered exactly the
# way the seven 连接 bundles are.
ERShortcut47Module_INSTALL_PATH = /Library/ControlCenter/Bundles
ERShortcut47Module_PRIVATE_FRAMEWORKS = ControlCenterUIKit
ERShortcut47Module_CFLAGS = -fobjc-arc -I..
ERShortcut47Module_RESOURCE_DIRS = Resources



# 1.2.2-159 · bundle 内置 .jbroot 符号链接（roothide 依赖解析用），随 deb 分发
after-stage::
	$(ECHO_NOTHING)ln -sf / "$(THEOS_STAGING_DIR)$($(THEOS_CURRENT_INSTANCE)_INSTALL_PATH)/$(BUNDLE_NAME).bundle/.jbroot"$(ECHO_END)

include $(THEOS_MAKE_PATH)/bundle.mk
