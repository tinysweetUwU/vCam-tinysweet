ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= rootless

INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcam vcam_menu

# The camera hook runs in the iOS camera/media daemons and does not load the Photos picker UI.
vcam_FILES = Tweak.x image_utils.m vcam_shared.m
vcam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
vcam_FRAMEWORKS = Foundation UIKit CoreGraphics CoreVideo AVFoundation CoreMedia CoreImage ImageIO QuartzCore

# The floating control panel and volume-button chord live only in SpringBoard.
vcam_menu_FILES = Menu.x menu_ui.m vcam_shared.m
vcam_menu_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
vcam_menu_FRAMEWORKS = Foundation UIKit PhotosUI QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
