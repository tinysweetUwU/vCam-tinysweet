#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "vcam_shared.h"
#import "vcam_menu.h"

// SpringBoard forwards physical volume-button transitions through this private
// UIKit method. This is more reliable than inferring button presses from volume
// changes, especially when both buttons are pressed close together.
@interface SpringBoard : UIApplication
- (BOOL)_handlePhysicalButtonEvent:(UIPressesEvent *)event;
@end

static NSInteger sPendingVolumeDirection = 0;
static CFTimeInterval sPendingVolumeTime = 0;
static CFTimeInterval sLastMenuToggleTime = 0;
static const CFTimeInterval VCamChordWindow = 0.45;
static const CFTimeInterval VCamToggleDebounce = 0.90;

static void VCamRegisterVolumeDirection(NSInteger direction) {
    if (direction != 1 && direction != -1) return;

    CFTimeInterval now = CACurrentMediaTime();
    BOOL shouldToggle = NO;

    @synchronized ([VCamMenuPresenter class]) {
        // One physical press may generate more than one event. Ignore duplicate
        // events during the debounce window instead of toggling twice.
        if (now - sLastMenuToggleTime < VCamToggleDebounce) return;

        if (sPendingVolumeDirection != 0 &&
            now - sPendingVolumeTime <= VCamChordWindow &&
            direction != sPendingVolumeDirection) {
            shouldToggle = YES;
            sPendingVolumeDirection = 0;
            sPendingVolumeTime = 0;
            sLastMenuToggleTime = now;
        } else if (sPendingVolumeDirection == 0 ||
                   now - sPendingVolumeTime > VCamChordWindow) {
            sPendingVolumeDirection = direction;
            sPendingVolumeTime = now;
        }
        // Repeated events from the same held button do not extend the chord
        // window, so they cannot prevent the opposite button from matching.
    }

    if (shouldToggle) {
        NSLog(@"[VCam] Volume-button chord detected; toggling menu");
        dispatch_async(dispatch_get_main_queue(), ^{
            [VCamMenuPresenter toggleMenu];
        });
    }
}

static void VCamObservePhysicalButtonEvent(UIPressesEvent *event) {
    if (!event) return;

    // On the iOS 16/17 SpringBoard path, physical button types are 102 (volume
    // up) and 103 (volume down); force is non-zero while the button is pressed.
    for (UIPress *press in event.allPresses.allObjects) {
        NSInteger type = (NSInteger)press.type;
        if (type != 102 && type != 103) continue;

        NSLog(@"[VCam] Physical volume event: type=%ld force=%.2f", (long)type, (double)press.force);
        if (press.force <= 0.0) continue;

        if (type == 102) VCamRegisterVolumeDirection(1);
        else if (type == 103) VCamRegisterVolumeDirection(-1);
    }
}

%hook SpringBoard

- (BOOL)_handlePhysicalButtonEvent:(UIPressesEvent *)event {
    VCamObservePhysicalButtonEvent(event);
    return %orig(event);
}

%end

%ctor {
    NSLog(@"[VCam] SpringBoard menu/volume hook loaded");
}
