ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MilkyWayReborn

MilkyWayReborn_FILES = Tweak.x MWBackgrounderManager.m MWSceneHelper.m MWPassthroughWindow.m MWWindowView.m MWThemeManager.m MWSettingsWindow.m
MilkyWayReborn_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
MilkyWayReborn_FRAMEWORKS = UIKit CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
