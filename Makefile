TARGET := iphone:clang:latest:15.0

export ARCHS = arm64

THEOS_PACKAGE_SCHEME = rootless

export DEBUG=0
export FINALPACKAGE=1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DouyinBGMBlocker

DouyinBGMBlocker_FILES = Tweak/DouyinBGMBlocker.xm
DouyinBGMBlocker_CFLAGS = -fobjc-arc
DouyinBGMBlocker_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
