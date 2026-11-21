# Theos Makefile for BOTBTweak (jailbreak / dev-device build variant)
# The same Objective-C sources build under Theos without Logos preprocessing.
TARGET := iphone:clang:16.1:16.1
ARCHS = arm64

INSTALL_TARGET_PROCESSED = NO

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BOTBTweak
BOTBTweak_FILES = STBTweakCore.m STBConfig.m STBImageCapture.m STBAnalyzerInterface.m STBOverlayUI.m STBCoordinateMath.c
BOTBTweak_FRAMEWORKS = UIKit Foundation CoreGraphics
BOTBTweak_CFLAGS = -fobjc-arc -Wno-error=unused-variable

include $(THEOS_MAKE_PATH)/tweak.mk
