# VCam

VCam is an iOS jailbreak tweak made of two small injected components: the camera-frame replacement runs in `mediaserverd`, while the floating control panel and volume-button gesture run in SpringBoard. This keeps the Photos picker UI out of the camera daemon.

## Controls

- Press **Volume Up + Volume Down together** to open or close the floating menu.
- Choose a photo or video from the Photos picker.
- Enable or disable media replacement.
- Move the media left, right, up, or down; reset its position to the center.
- Rotate the media in 90-degree increments and zoom from 0.5× to 3×.

The initial state is disabled until a replacement item is selected. Imported files are copied to `/var/mobile/Media/VCam`, and settings are shared between SpringBoard and `mediaserverd` through `/var/mobile/Media/VCam/settings.plist`.

## Build locally

Install Theos and an iOS SDK, then run one of:

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

Use the RootHide fork of Theos for the `roothide` scheme. The rootless and RootHide variants are also built automatically by [GitHub Actions](.github/workflows/build.yml) on pushes, pull requests, or manual workflow dispatch. The workflow uploads both `.deb` files as the `vcam-deb-packages` artifact.

## Notes

- The tweak targets the iOS 16.5 SDK with an iOS 15.0 deployment target. Separate filters inject `vcam.dylib` only into `mediaserverd` and `vcam_menu.dylib` only into SpringBoard.
- The volume chord is detected from SpringBoard's `SBVolumeControl` key-press volume updates. Apple changes private interfaces across iOS versions, so this hook should be tested on the exact iOS version in use.
- Video is sampled to up to 45 frames at approximately 8 frames per second and downscaled to a maximum dimension of 640 pixels to limit `mediaserverd` memory use.
- This project is a tweak proof of concept; it has not been built or run on a physical iPhone in this environment.
