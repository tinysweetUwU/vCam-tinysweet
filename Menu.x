#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import "vcam_shared.h"
#import "vcam_menu.h"

// Observe actual volume adjustments in SpringBoard and pair opposite directions
// to detect the Volume Up + Volume Down shortcut.
@interface SBVolumeControl : NSObject
- (float)_effectiveVolume;
- (void)setVolume:(float)volume forKeyPress:(BOOL)forKeyPress;
@end

static NSInteger sPendingVolumeDirection = 0;
static CFTimeInterval sPendingVolumeTime = 0;
static CFTimeInterval sLastMenuToggleTime = 0;
static const CFTimeInterval VCamChordWindow = 0.45;
static const CFTimeInterval VCamToggleDebounce = 0.90;

static void VCamObserveVolumeChord(SBVolumeControl *controller, float requestedVolume, BOOL forKeyPress) {
    if (!forKeyPress || !controller) return;

    float currentVolume = 0.0f;
    SEL currentSelector = @selector(_effectiveVolume);
    if ([controller respondsToSelector:currentSelector]) {
        currentVolume = ((float (*)(id, SEL))objc_msgSend)(controller, currentSelector);
    }

    NSInteger direction = requestedVolume >= currentVolume ? 1 : -1;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL shouldToggle = NO;

    @synchronized ([VCamMenuPresenter class]) {
        if (now - sLastMenuToggleTime < VCamToggleDebounce) return;

        if (sPendingVolumeDirection != 0 &&
            direction != sPendingVolumeDirection &&
            now - sPendingVolumeTime <= VCamChordWindow) {
            shouldToggle = YES;
            sPendingVolumeDirection = 0;
            sPendingVolumeTime = 0;
            sLastMenuToggleTime = now;
        } else {
            sPendingVolumeDirection = direction;
            sPendingVolumeTime = now;
        }
    }

    if (shouldToggle) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [VCamMenuPresenter toggleMenu];
        });
    }
}

%hook SBVolumeControl

- (void)setVolume:(float)volume forKeyPress:(BOOL)forKeyPress {
    VCamObserveVolumeChord(self, volume, forKeyPress);
    %orig(volume, forKeyPress);
}

%end
