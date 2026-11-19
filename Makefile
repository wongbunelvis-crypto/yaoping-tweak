ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YaopingCtl
YaopingCtl_FILES = Tweak.x
YaopingCtl_CFLAGS += -fobjc-arc -Wno-everything
YaopingCtl_FRAMEWORKS = UIKit CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
