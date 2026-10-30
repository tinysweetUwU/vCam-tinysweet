#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "vcam_shared.h"
#import "vcam_menu.h"

@interface SBVolumeControl : NSObject
- (void)handleVolumeButtonWithType:(long long)type down:(BOOL)down;
@end

static NSInteger sPendingVolumeDirection = 0;
static CFTimeInterval sPendingVolumeTime = 0;
static CFTimeInterval sLastMenuToggleTime = 0;
static const CFTimeInterval VCamChordWindow = 0.60;
static const CFTimeInterval VCamToggleDebounce = 0.90;

static void VCamRegisterVolumeDirection(NSInteger direction) {
    if (direction != 1 && direction != -1) return;

    CFTimeInterval now = CACurrentMediaTime();
    BOOL shouldToggle = NO;

    @synchronized ([VCamMenuPresenter class]) {
        if (now - sLastMenuToggleTime < VCamToggleDebounce) return;

        if (sPendingVolumeDirection != 0 &&
            now - sPendingVolumeTime > VCamChordWindow) {
            sPendingVolumeDirection = 0;
            sPendingVolumeTime = 0;
        }

        if (sPendingVolumeDirection == 0) {
            sPendingVolumeDirection = direction;
            sPendingVolumeTime = now;
        } else if (direction != sPendingVolumeDirection) {
            shouldToggle = YES;
            sPendingVolumeDirection = 0;
            sPendingVolumeTime = 0;
            sLastMenuToggleTime = now;
        }
    }

    if (shouldToggle) {
        NSLog(@"[VCam] Volume Up + Volume Down detected; toggling menu");
        dispatch_async(dispatch_get_main_queue(), ^{
            [VCamMenuPresenter toggleMenu];
        });
    }
}

%hook SBVolumeControl

- (void)handleVolumeButtonWithType:(long long)type down:(BOOL)down {
    if (down) {
        // SpringBoard uses 102 for Volume Up and 103 for Volume Down.
        if (type == 102) VCamRegisterVolumeDirection(1);
        else if (type == 103) VCamRegisterVolumeDirection(-1);
    }
    %orig(type, down);
}

%end

%ctor {
    NSLog(@"[VCam] Volume shortcut hook loaded (SBVolumeControl handleVolumeButtonWithType:down:)");
}
