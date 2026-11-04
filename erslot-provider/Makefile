ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ERSlotProvider

ERSlotProvider_FILES = ERSlotProvider.m
ERSlotProvider_INSTALL_PATH = /Library/ControlCenter/CCSupport_Providers
ERSlotProvider_PRIVATE_FRAMEWORKS = ControlCenterUIKit
ERSlotProvider_CFLAGS = -fobjc-arc -I..

include $(THEOS_MAKE_PATH)/bundle.mk
