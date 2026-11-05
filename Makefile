THEOS_PACKAGE_SCHEME ?= rootless

TARGET := iphone:clang:latest:15.0
ARCHS  = arm64 arm64e

INSTALL_TARGET_PROCESSES = Reddit

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RedditAIBridge
RedditAIBridge_FILES = Tweak.x RABConfig.m RABLog.m RABNet.m RABGhost.m RABPanel.m RABEngine.m
RedditAIBridge_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness
RedditAIBridge_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
