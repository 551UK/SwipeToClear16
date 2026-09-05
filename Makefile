ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SwipeToClear16
SwipeToClear16_FILES = Tweak.xm
SwipeToClear16_FRAMEWORKS = UIKit CoreFoundation CoreHaptics
SwipeToClear16_CFLAGS = -fobjc-arc

SUBPROJECTS += SwipeToClear16Prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 Preferences || true"
	install.exec "killall -9 SpringBoard"
