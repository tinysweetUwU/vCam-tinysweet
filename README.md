# VCam

VCam is an iOS jailbreak tweak made of two small injected components: the camera-frame replacement runs in `mediaserverd`, while the floating control panel and volume-button gesture run in SpringBoard. This keeps the Photos picker UI out of the camera daemon.

## Controls

- Press **Volume Up + Volume Down within about 0.45 seconds** to open or close the floating menu. SpringBoard physical-button events are used for this gesture.
- Choose a photo or video from the Photos picker.
- Enable or disable media replacement.
- Move the media left, right, up, or down; reset its position to the center.
- Rotate the media in 90-degree increments and zoom from 0.5× to 3×.

Package identifier: `com.tinysweet.vcamios`; author: `tinysweet`. The initial state is disabled until a replacement item is selected. Imported files are copied to `/var/mobile/Media/VCam`, and settings are shared between SpringBoard and `mediaserverd` through `/var/mobile/Media/VCam/settings.plist`.

After installing the updated package, respring SpringBoard (or reboot userspace) so the new SpringBoard hook is loaded. If you are changing from the previous `com.yourcompany.vcam` package, remove the old package first if your package manager does not replace it automatically.

## Build locally

Install Theos and an iOS SDK, then run one of:

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

Use the RootHide fork of Theos for the `roothide` scheme. The rootless and RootHide variants are also built automatically by [GitHub Actions](.github/workflows/build.yml) on pushes, pull requests, or manual workflow dispatch. The workflow uploads both `.deb` files as the `vcam-deb-packages` artifact.

## Notes

- The tweak targets the iOS 16.5 SDK with an iOS 15.0 deployment target. Separate filters inject `vcam.dylib` only into `mediaserverd` and `vcam_menu.dylib` only into SpringBoard.
- The volume chord is detected from SpringBoard’s `_handlePhysicalButtonEvent:` hook, using physical press types 102 (volume up) and 103 (volume down). Private interfaces may vary between iOS versions. The current target device for validation is iPhone XS on iOS 17.6.1; actual on-device testing is still required.
- Video is sampled to up to 45 frames at approximately 8 frames per second and downscaled to a maximum dimension of 640 pixels to limit `mediaserverd` memory use.
- This project is a tweak proof of concept; it has not been built or run on a physical iPhone in this environment.
