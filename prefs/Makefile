ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = EchoRebornPrefs

EchoRebornPrefs_FILES = ERRootListController.m ERCategoryOrderController.m ERShortcutController.m ERGlassListController.m ERShortcutScanner.m ERModuleSettingsController.m ERUIHelpers.m ERSegmentedCell.m ERAuthorCell.m EREntryCell.m ERUtilitySwitchCell.m ERSliderCell.m EREnhancedSettingsController.m ERSokoController.m ERSiriController.m ERSystemEnhanceController.m ERLandscapeResetCell.m
EchoRebornPrefs_FRAMEWORKS = UIKit
EchoRebornPrefs_PRIVATE_FRAMEWORKS = Preferences
# Shortcuts store is read by ERShortcutScanner via dlopen, but link libsqlite3 so
# the symbol source is present on the device (matches EvoCenter16's Settings dylib).
EchoRebornPrefs_LDFLAGS = -lsqlite3
EchoRebornPrefs_INSTALL_PATH = /Library/PreferenceBundles
EchoRebornPrefs_CFLAGS = -fobjc-arc
EchoRebornPrefs_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk

after-EchoRebornPrefs-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp "Resources/EchoRebornPrefs.plist" "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/EchoRebornPrefs.plist"$(ECHO_END)
