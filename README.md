# VCam iOS 0.1.5

Virtual camera replacement tweak for RootHide / rootless jailbreaks.

## Target device tested by the user

- iPhone XS (A12)
- iOS 17.6.1
- Relaxin RootHide 0.5.6

## Changes in 0.1.5

- Targets `mediaserverd` as the camera daemon on iOS 17.6.1. The `cameracaptured` target was removed because it was an unverified assumption for this OS version. The upstream VCam implementation documents `mediaserverd` for iOS 15–17.
- Publishes daemon heartbeat through Darwin `notify` state, which is system-wide and not dependent on SpringBoard and daemon sharing the same `/tmp` sandbox view. The plist remains supplemental diagnostic detail.
- Marks heartbeat stale after 8 seconds so a terminated/restarted daemon is detected.
- Hooks all video sample buffers emitted by `BWNodeOutput`; there is no front/rear lens filter, so both live preview streams use the same replacement path.
- Removes `CVPixelBufferLockBaseAddress` around Core Image rendering. The hook does not access raw CPU bytes; the Core Image context renders directly to the pixel buffer.
- Takes a short state snapshot and releases the lock before the render, reducing contention with settings/media updates.
- Reduces video decode resolution to 480px max and samples at 15 fps (up to 48 frames) to reduce memory pressure while improving playback cadence over the previous 8.3 fps sampling.
- Downsamples still images to 1280px max before use.

## Important Relaxin setting

Relaxin has a global `Tweak Injection` setting. Make sure it is enabled, then run a Userspace Reboot. SpringBoard may retain an already-injected menu after the setting is switched off, while a newly launched `mediaserverd` will not receive the tweak.

## Build

Use the GitHub Actions workflow. Install the RootHide package (`vcam-roothide.deb`) on Relaxin RootHide, not the rootless package.

## Camera behavior

The active front or rear live video feed is replaced when it passes through `mediaserverd`'s `BWNodeOutput` video sample path. This does not claim to replace every still-photo/HEIF/JPEG capture pipeline; still-photo capture can use a different output path.

## Diagnostics

Open the VCam menu and use **Copy diagnostics**. The menu reports a live `mediaserverd` heartbeat from Darwin notify, hook state, first frame state, media decode state and first replacement render. No system log extraction is required.
