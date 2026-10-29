#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import "vcam_shared.h"
#import "vcam_menu.h"

// SBVolumeControl receives this selector on current SpringBoard releases when
// a physical volume key changes the system volume. Pair opposite directions
// in a short window to approximate a simultaneous chord.
@interface SBVolumeControl : NSObject
- (float)_effectiveVolume;
- (void)setVolume:(float)volume forKeyPress:(BOOL)forKeyPress;
@end

static NSInteger sLastVolumeDirection = 0;
static CFTimeInterval sLastVolumeChange = 0;

static void VCamObserveVolumeChord(SBVolumeControl *controller, float requestedVolume, BOOL forKeyPress) {
    if (!forKeyPress || !controller) return;
    float currentVolume = 0.0f;
    SEL currentSelector = @selector(_effectiveVolume);
    if ([controller respondsToSelector:currentSelector]) {
        currentVolume = ((float (*)(id, SEL))objc_msgSend)(controller, currentSelector);
    }
    NSInteger direction = requestedVolume >= currentVolume ? 1 : -1;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL matched = NO;

    @synchronized ([VCamMenuPresenter class]) {
        if (sLastVolumeDirection != 0 && direction != sLastVolumeDirection &&
            (now - sLastVolumeChange) <= 0.35) {
            matched = YES;
            sLastVolumeDirection = 0;
            sLastVolumeChange = 0;
        } else {
            sLastVolumeDirection = direction;
            sLastVolumeChange = now;
        }
    }

    if (matched) {
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
