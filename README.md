# VCam

VCam is an iOS jailbreak tweak made of two small injected components: the camera-frame replacement runs in `cameracaptured` on newer iOS releases and in `mediaserverd` on builds that still route capture frames there, while the floating control panel and volume-button gesture run in SpringBoard. This keeps the Photos picker UI out of the camera daemon.

## Controls

- Press **Volume Up + Volume Down within about 0.45 seconds** to open or close the floating menu. SpringBoard physical-button events are used for this gesture.
- Choose a photo or video from the Photos picker.
- Enable or disable media replacement.
- Move the media left, right, up, or down; reset its position to the center.
- Rotate the media in 90-degree increments and zoom from 0.5× to 3×.

Package identifier: `com.tinysweet.vcamios`; author: `tinysweet`; version: `0.1.4`. The initial state is disabled until a replacement item is selected. Imported files are copied to `/tmp/VCam` (directory mode `0755`, media/settings files mode `0644`). Per-daemon runtime status is stored separately under `/tmp/VCamStatus` (directory mode `0777`) so `cameracaptured` and `mediaserverd` can report independently without broadening write access to the media directory. This is intentional because `/tmp` is readable by both processes on builds where `mediaserverd`'s sandbox blocks direct access to the mobile media directory. Temporary storage may be cleared during a userspace reboot, so reselect the image/video after updating or rebooting if the menu says no media is selected.

After installing the updated package, perform a userspace reboot (recommended) so SpringBoard and the camera services load the new tweaks. A SpringBoard-only respring may leave `mediaserverd` or `cameracaptured` running without the newly installed camera hook. If you are changing from the previous `com.yourcompany.vcam` package, remove the old package first if your package manager does not replace it automatically.

## Build locally

Install Theos and an iOS SDK, then run one of:

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

Use the RootHide fork of Theos for the `roothide` scheme. The rootless and RootHide variants are also built automatically by [GitHub Actions](.github/workflows/build.yml) on pushes, pull requests, or manual workflow dispatch. The workflow uploads both `.deb` files as the `vcam-deb-packages` artifact.

## Notes

- The tweak targets the iOS 16.5 SDK with an iOS 15.0 deployment target. The camera filter targets both `cameracaptured` and `mediaserverd`; the menu filter targets only SpringBoard. iOS 17 split several media responsibilities out of `mediaserverd`, so both camera service processes are included.
- The volume chord is detected from SpringBoard’s `_handlePhysicalButtonEvent:` hook, using physical press types 102 (volume up) and 103 (volume down). Private interfaces may vary between iOS versions. The current target device for validation is iPhone XS on iOS 17.6.1; actual on-device testing is still required.
- Video is sampled to up to 45 frames at approximately 8 frames per second and downscaled to a maximum dimension of 640 pixels to limit camera-daemon memory use.
- This project is a tweak proof of concept; it has not been built or run on a physical iPhone in this environment.

## On-device camera diagnostics

The menu now includes a live **Camera status** panel. It reports injection separately for `cameracaptured` and `mediaserverd`, whether the `BWNodeOutput` hook was installed, whether camera frames reached the hook, whether the selected image/video decoded, and whether a replacement frame was rendered. The **Copy diagnostics** button copies this status to the clipboard; no system-log viewer is required.

The camera tweak explicitly loads Apple's private `CMCapture.framework` before installing the `BWNodeOutput -emitSampleBuffer:` hook, then retries installation while the camera service starts. This avoids assuming the Objective-C class is already registered at tweak-constructor time. The camera path is still device/OS specific and must be verified on iOS 17.6.1 hardware.
