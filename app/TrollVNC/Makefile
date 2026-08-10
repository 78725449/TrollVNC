ARCHS := arm64
TARGET := iphone:clang:latest:14.0

INSTALL_TARGET_PROCESSES += TrollVNC

include $(THEOS)/makefiles/common.mk

XCODEPROJ_NAME := TrollVNC
TrollVNC_XCODE_SCHEME := TrollVNC

ifeq ($(DEBUG),1)
TrollVNC_XCODEFLAGS += GCC_PREPROCESSOR_DEFINITIONS="DEBUG=1 THEBOOTSTRAP=1 THEOS_PACKAGE_SCHEME=\\\"bootstrap\\\" PACKAGE_VERSION=\\\"$(PACKAGE_VERSION)\\\"" THEOS="$(THEOS)"
else
TrollVNC_XCODEFLAGS += GCC_PREPROCESSOR_DEFINITIONS="THEBOOTSTRAP=1 THEOS_PACKAGE_SCHEME=\\\"bootstrap\\\" PACKAGE_VERSION=\\\"$(PACKAGE_VERSION)\\\"" THEOS="$(THEOS)"
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
TrollVNC_CODESIGN_FLAGS += -f -s - --entitlements TrollVNC/TrollVNC.entitlements
else
TrollVNC_CODESIGN_FLAGS += -STrollVNC/TrollVNC.entitlements
endif

TrollVNC_XCODEFLAGS += HEADER_SEARCH_PATHS="$(CURDIR)/../../include"
# Use the theos iOS 16.5 SDK for the app xcodebuild: Xcode 18.2 SDK links
# SwiftUICore whose tbd disallows direct app linking (swiftUIKit force-load),
# while the 16.5 SDK has no SwiftUICore. Appends after theos default
# "-sdk iphoneos", so this last -sdk wins.
TrollVNC_XCODEOPTS += -sdk "$(THEOS)/sdks/iPhoneOS16.5.sdk"

include $(THEOS_MAKE_PATH)/xcodeproj.mk
