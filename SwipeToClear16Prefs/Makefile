ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SwipeToClear16Prefs
SwipeToClear16Prefs_FILES = STCRootListController.m
SwipeToClear16Prefs_FRAMEWORKS = Foundation CoreFoundation UIKit
SwipeToClear16Prefs_PRIVATE_FRAMEWORKS = Preferences
SwipeToClear16Prefs_INSTALL_PATH = /Library/PreferenceBundles
SwipeToClear16Prefs_INFOPLIST_FILE = Info.plist
SwipeToClear16Prefs_RESOURCE_FILES = Resources/Root.plist
SwipeToClear16Prefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
