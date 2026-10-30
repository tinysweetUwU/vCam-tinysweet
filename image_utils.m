#import "image_utils.h"
#import "vcam_shared.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <ImageIO/ImageIO.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

// Shared with the SpringBoard menu through settings.plist.
typedef NS_ENUM(NSUInteger, VCamMode) {
    VCamModeNone = 0,
    VCamModeImage,
    VCamModeVideo
};

static NSObject *sLock = nil;
static dispatch_once_t sLockOnce;
static CIContext *sRenderContext = nil;
static CGColorSpaceRef sRenderColorSpace = NULL;
static UIImage *sReplacementImage = nil;
static AVPlayer *sVideoPlayer = nil;
static AVPlayerItemVideoOutput *sVideoOutput = nil;
static id sVideoEndObserver = nil;
static CVPixelBufferRef sCurrentVideoBuffer = NULL;
static CGAffineTransform sVideoPreferredTransform = {1, 0, 0, 1, 0, 0};
static VCamMode sCurrentMode = VCamModeNone;
static BOOL sEnabled = NO;
static CGFloat sOffsetX = 0.0;
static CGFloat sOffsetY = 0.0;
static CGFloat sZoom = 1.0;
static NSInteger sRotation = 0;
static NSUInteger sRefreshTicks = 0;
static NSUInteger sLoadGeneration = 0;
static BOOL sHasReadSettings = NO;
static BOOL sIsLoading = NO;
static NSString *sRequestedPath = nil;
static NSString *sLoadedPath = nil;
static BOOL sHasLoggedFirstRender = NO;

static void VCamEnsureState(void) {
    dispatch_once(&sLockOnce, ^{
        sLock = [[NSObject alloc] init];
        sRenderContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
        sRenderColorSpace = CGColorSpaceCreateDeviceRGB();
    });
}

static CGFloat VCamNumber(id value, CGFloat fallback) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static void VCamStopVideoPlaybackLocked(void) {
    if (sVideoEndObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:sVideoEndObserver];
        sVideoEndObserver = nil;
    }
    [sVideoPlayer pause];
    [sVideoPlayer replaceCurrentItemWithPlayerItem:nil];
    sVideoPlayer = nil;
    sVideoOutput = nil;
    if (sCurrentVideoBuffer) {
        CVPixelBufferRelease(sCurrentVideoBuffer);
        sCurrentVideoBuffer = NULL;
    }
    sVideoPreferredTransform = CGAffineTransformIdentity;
}

static BOOL VCamDecodeImage(NSString *path, UIImage **imageOut) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!imageSource) {
        VCamSetRuntimeStatus(@"mediaState", @"image-open-failed");
        VCamSetRuntimeStatus(@"mediaDetail", @"ImageIO could not open the selected photo from the shared media folder");
        return NO;
    }

    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL));
    NSUInteger width = [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    NSUInteger maxDimension = MAX(width, height);
    if (maxDimension == 0) maxDimension = 32768;

    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxDimension),
        (__bridge NSString *)kCGImageSourceShouldCache: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES
    };
    CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, (__bridge CFDictionaryRef)options);
    CFRelease(imageSource);
    if (!imageRef) {
        VCamSetRuntimeStatus(@"mediaState", @"image-decode-failed");
        VCamSetRuntimeStatus(@"mediaDetail", @"ImageIO could not decode the selected photo at its original pixel dimensions");
        return NO;
    }

    size_t decodedWidth = CGImageGetWidth(imageRef);
    size_t decodedHeight = CGImageGetHeight(imageRef);
    UIImage *image = [UIImage imageWithCGImage:imageRef scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(imageRef);
    if (imageOut) *imageOut = image;

    VCamSetRuntimeStatus(@"mediaState", @"loaded-image");
    VCamSetRuntimeStatus(@"mediaDetail", [NSString stringWithFormat:@"Photo decoded (%zux%zu, original pixel dimensions)", decodedWidth, decodedHeight]);
    return YES;
}

static BOOL VCamPrepareVideo(NSString *path,
                             AVPlayer **playerOut,
                             AVPlayerItemVideoOutput **outputOut,
                             id *observerOut,
                             CGAffineTransform *preferredTransformOut) {
    if (playerOut) *playerOut = nil;
    if (outputOut) *outputOut = nil;
    if (observerOut) *observerOut = nil;
    if (preferredTransformOut) *preferredTransformOut = CGAffineTransformIdentity;

    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @NO }];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = tracks.firstObject;
    if (!videoTrack) {
        VCamSetRuntimeStatus(@"mediaState", @"video-track-missing");
        VCamSetRuntimeStatus(@"mediaDetail", @"The selected file contains no readable video track");
        return NO;
    }

    NSDictionary *pixelAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    AVPlayerItemVideoOutput *videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixelAttributes];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    [item addOutput:videoOutput];
    item.preferredForwardBufferDuration = 1.0;

    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.muted = YES;
    player.volume = 0.0;
    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    player.automaticallyWaitsToMinimizeStalling = NO;

    __weak AVPlayer *weakPlayer = player;
    id endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                        object:item
                                                                         queue:nil
                                                                    usingBlock:^(NSNotification *notification) {
        AVPlayer *activePlayer = weakPlayer;
        if (!activePlayer || activePlayer.currentItem != notification.object) return;
        [activePlayer seekToTime:kCMTimeZero
                 toleranceBefore:kCMTimeZero
                  toleranceAfter:kCMTimeZero
               completionHandler:^(BOOL finished) {
            if ((finished || activePlayer.currentItem) && ![VCamCopySetting(VCamVideoPausedKey) boolValue]) {
                [activePlayer play];
            }
        }];
    }];

    if (playerOut) *playerOut = player;
    if (outputOut) *outputOut = videoOutput;
    if (observerOut) *observerOut = endObserver;
    if (preferredTransformOut) *preferredTransformOut = videoTrack.preferredTransform;

    VCamSetRuntimeStatus(@"mediaState", @"loaded-video");
    VCamSetRuntimeStatus(@"mediaDetail", @"Video player ready; full-resolution frames are streamed in real time");
    return YES;
}

static BOOL VCamOpenSelectedMediaForRead(NSString *path) {
    if (path.length == 0) {
        VCamSetRuntimeStatus(@"mediaFileAccess", @"failed");
        VCamSetRuntimeStatus(@"mediaState", @"file-not-readable");
        VCamSetRuntimeStatus(@"mediaDetail", @"The selected media path is empty");
        return NO;
    }

    // The selected media is copied by SpringBoard into /tmp/VCamMedia.
    // This intentionally uses the same direct filesystem access pattern as
    // the original working /tmp/test.png implementation, without sandbox tokens.
    errno = 0;
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
        int savedErrno = errno;
        VCamSetRuntimeStatus(@"mediaFileAccess", @"failed");
        VCamSetRuntimeStatus(@"mediaFileOpenErrno", @(savedErrno));
        VCamSetRuntimeStatus(@"mediaState", @"file-not-readable");
        VCamSetRuntimeStatus(@"mediaDetail", [NSString stringWithFormat:@"open() failed (errno %d: %s); path %@", savedErrno, strerror(savedErrno), path]);
        return NO;
    }

    struct stat fileInfo;
    BOOL regularFile = fstat(descriptor, &fileInfo) == 0 && S_ISREG(fileInfo.st_mode);
    int statErrno = errno;
    close(descriptor);
    if (!regularFile) {
        VCamSetRuntimeStatus(@"mediaFileAccess", @"failed");
        VCamSetRuntimeStatus(@"mediaState", @"invalid-file");
        VCamSetRuntimeStatus(@"mediaDetail", [NSString stringWithFormat:@"The selected path is not a regular file (errno %d: %s)", statErrno, strerror(statErrno)]);
        return NO;
    }

    VCamSetRuntimeStatus(@"mediaFileAccess", @"readable");
    VCamSetRuntimeStatus(@"mediaFileOpenErrno", @0);
    VCamSetRuntimeStatus(@"mediaFileSize", @((unsigned long long)fileInfo.st_size));
    VCamSetRuntimeStatus(@"mediaDetail", [NSString stringWithFormat:@"File readable by mediaserverd (%llu bytes)", (unsigned long long)fileInfo.st_size]);
    return YES;
}

static BOOL VCamDecodeMedia(NSString *path,
                            UIImage **imageOut,
                            AVPlayer **playerOut,
                            AVPlayerItemVideoOutput **videoOutputOut,
                            id *observerOut,
                            CGAffineTransform *preferredTransformOut) {
    if (imageOut) *imageOut = nil;
    if (playerOut) *playerOut = nil;
    if (videoOutputOut) *videoOutputOut = nil;
    if (observerOut) *observerOut = nil;
    if (preferredTransformOut) *preferredTransformOut = CGAffineTransformIdentity;

    if (!VCamOpenSelectedMediaForRead(path)) return NO;

    NSString *extension = path.pathExtension.lowercaseString;
    NSSet *videoExtensions = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"3gp", @"3g2", @"avi", @"mts", @"m2ts", @"qt"]];
    NSString *mediaType = VCamCopySetting(VCamMediaTypeKey);
    if ([mediaType isEqualToString:@"video"] || [videoExtensions containsObject:extension]) {
        return VCamPrepareVideo(path, playerOut, videoOutputOut, observerOut, preferredTransformOut);
    }
    return VCamDecodeImage(path, imageOut);
}

void loadReplacementMedia(void) {
    VCamEnsureState();

    NSString *newPath = nil;
    NSUInteger generation = 0;
    BOOL shouldStartLoad = NO;

    @synchronized (sLock) {
        sRefreshTicks++;
        if (sHasReadSettings && (sRefreshTicks % 10) != 0) return;
        sHasReadSettings = YES;

        id enabledValue = VCamCopySetting(VCamEnabledKey);
        if (enabledValue) {
            sEnabled = [enabledValue boolValue];
            VCamSetRuntimeStatus(@"enabledSettingRead", @"confirmed");
        } else {
            // notify_get_state can briefly fail while SpringBoard is publishing
            // the value. A transient miss must not restore the live camera feed.
            // Preserve the last confirmed Enabled value instead of defaulting OFF.
            VCamSetRuntimeStatus(@"enabledSettingRead", @"transient-miss-kept-last-value");
        }
        VCamSetRuntimeStatus(@"replacementEnabled", @(sEnabled));
        sOffsetX = MAX(-1.0, MIN(1.0, VCamNumber(VCamCopySetting(VCamOffsetXKey), 0.0)));
        sOffsetY = MAX(-1.0, MIN(1.0, VCamNumber(VCamCopySetting(VCamOffsetYKey), 0.0)));
        sZoom = MAX(0.5, MIN(3.0, VCamNumber(VCamCopySetting(VCamZoomKey), 1.0)));
        sRotation = (NSInteger)VCamNumber(VCamCopySetting(VCamRotationKey), 0);
        BOOL videoPaused = [VCamCopySetting(VCamVideoPausedKey) boolValue];

        id pathValue = VCamCopySetting(VCamMediaPathKey);
        NSString *observedPath = [pathValue isKindOfClass:[NSString class]] ? [(NSString *)pathValue copy] : nil;
        NSString *observedType = VCamCopySetting(VCamMediaTypeKey);
        VCamSetRuntimeStatus(@"mediaSelectionReceived", @(observedPath.length > 0));
        VCamSetRuntimeStatus(@"mediaSelectionTransport", @"Darwin Notify");
        VCamSetRuntimeStatus(@"mediaSelectionFilename", observedPath.lastPathComponent ?: @"");
        VCamSetRuntimeStatus(@"mediaSelectionType", observedType ?: @"unknown");

        if (!sEnabled) {
            if (sCurrentMode == VCamModeVideo) [sVideoPlayer pause];
            VCamSetRuntimeStatus(@"replacementRendered", @NO);
            VCamSetRuntimeStatus(@"mediaState", @"disabled");
            VCamSetRuntimeStatus(@"mediaDetail", @"Replacement is turned off");
            return;
        }
        if (![pathValue isKindOfClass:[NSString class]] || [(NSString *)pathValue length] == 0) {
            VCamSetRuntimeStatus(@"replacementRendered", @NO);
            VCamSetRuntimeStatus(@"mediaState", @"no-selection");
            VCamSetRuntimeStatus(@"mediaDetail", @"mediaserverd has not received a selected media path from SpringBoard");
            return;
        }
        newPath = observedPath;
        if ([newPath isEqualToString:sLoadedPath]) {
            if (sCurrentMode == VCamModeVideo) {
                if (videoPaused) [sVideoPlayer pause];
                else [sVideoPlayer play];
            }
            return;
        }
        if (sIsLoading && [newPath isEqualToString:sRequestedPath]) return;

        sLoadGeneration++;
        generation = sLoadGeneration;
        sRequestedPath = [newPath copy];
        sIsLoading = YES;
        sCurrentMode = VCamModeNone;
        sReplacementImage = nil;
        VCamStopVideoPlaybackLocked();
        sHasLoggedFirstRender = NO;
        VCamSetRuntimeStatus(@"replacementRendered", @NO);
        VCamSetRuntimeStatus(@"replacementRenderedAt", nil);
        VCamSetRuntimeStatus(@"renderError", nil);
        VCamSetRuntimeStatus(@"mediaState", @"loading");
        VCamSetRuntimeStatus(@"mediaDetail", @"Opening selected media in the camera service");
        shouldStartLoad = YES;
    }

    if (!shouldStartLoad) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            UIImage *image = nil;
            AVPlayer *player = nil;
            AVPlayerItemVideoOutput *videoOutput = nil;
            id endObserver = nil;
            CGAffineTransform preferredTransform = CGAffineTransformIdentity;
            BOOL success = VCamDecodeMedia(newPath, &image, &player, &videoOutput, &endObserver, &preferredTransform);

            @synchronized (sLock) {
                if (generation != sLoadGeneration) {
                    [player pause];
                    if (endObserver) [[NSNotificationCenter defaultCenter] removeObserver:endObserver];
                    return;
                }
                sIsLoading = NO;
                sLoadedPath = [newPath copy];
                if (!success) {
                    VCamSetRuntimeStatus(@"mediaState", @"load-failed");
                    VCamSetRuntimeStatus(@"replacementRendered", @NO);
                    sCurrentMode = VCamModeNone;
                    sReplacementImage = nil;
                    VCamStopVideoPlaybackLocked();
                    return;
                }
                sRequestedPath = nil;
                if (image) {
                    sReplacementImage = image;
                    sCurrentMode = VCamModeImage;
                    VCamSetRuntimeStatus(@"mediaDetail", [NSString stringWithFormat:@"Photo ready (%zux%zu)", CGImageGetWidth(image.CGImage), CGImageGetHeight(image.CGImage)]);
                } else {
                    sVideoPlayer = player;
                    sVideoOutput = videoOutput;
                    sVideoEndObserver = endObserver;
                    sVideoPreferredTransform = preferredTransform;
                    sCurrentMode = VCamModeVideo;
                    sReplacementImage = nil;
                    if (!sEnabled || [VCamCopySetting(VCamVideoPausedKey) boolValue]) [sVideoPlayer pause];
                    else [sVideoPlayer play];
                }
            }
        }
    });
}

void drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (!targetBuffer) return;
    VCamEnsureState();

    UIImage *replacementImage = nil;
    AVPlayer *videoPlayer = nil;
    AVPlayerItemVideoOutput *videoOutput = nil;
    CGAffineTransform videoTransform = CGAffineTransformIdentity;
    VCamMode mode = VCamModeNone;
    CGFloat offsetXValue = 0.0;
    CGFloat offsetYValue = 0.0;
    CGFloat zoomValue = 1.0;
    NSInteger rotationValue = 0;
    CIContext *renderContext = nil;
    CGColorSpaceRef renderColorSpace = NULL;

    @synchronized (sLock) {
        if (!sEnabled || sCurrentMode == VCamModeNone || !sRenderContext) return;
        mode = sCurrentMode;
        replacementImage = sReplacementImage;
        videoPlayer = sVideoPlayer;
        videoOutput = sVideoOutput;
        videoTransform = sVideoPreferredTransform;
        offsetXValue = sOffsetX;
        offsetYValue = sOffsetY;
        zoomValue = sZoom;
        rotationValue = sRotation;
        renderContext = sRenderContext;
        renderColorSpace = sRenderColorSpace;
    }

    CIImage *source = nil;
    CVPixelBufferRef videoBuffer = NULL;
    if (mode == VCamModeImage && replacementImage.CGImage) {
        source = [CIImage imageWithCGImage:replacementImage.CGImage];
    } else if (mode == VCamModeVideo && videoOutput && videoPlayer) {
        CMTime itemTime = [videoOutput itemTimeForHostTime:CACurrentMediaTime()];
        if (!CMTIME_IS_VALID(itemTime) || !CMTIME_IS_NUMERIC(itemTime)) itemTime = videoPlayer.currentTime;
        if ([videoOutput hasNewPixelBufferForItemTime:itemTime]) {
            CVPixelBufferRef nextBuffer = [videoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
            if (nextBuffer) {
                @synchronized (sLock) {
                    if (sCurrentVideoBuffer) CVPixelBufferRelease(sCurrentVideoBuffer);
                    sCurrentVideoBuffer = nextBuffer;
                    CVPixelBufferRetain(sCurrentVideoBuffer);
                }
                CVPixelBufferRelease(nextBuffer);
            }
        }
        @synchronized (sLock) {
            if (sCurrentVideoBuffer) {
                videoBuffer = sCurrentVideoBuffer;
                CVPixelBufferRetain(videoBuffer);
            }
        }
        if (videoBuffer) {
            source = [CIImage imageWithCVPixelBuffer:videoBuffer];
            if (!CGAffineTransformIsIdentity(videoTransform)) {
                source = [source imageByApplyingTransform:videoTransform];
            }
            CGRect videoExtent = source.extent;
            source = [source imageByApplyingTransform:CGAffineTransformMakeTranslation(-videoExtent.origin.x, -videoExtent.origin.y)];
        }
    }

    if (!source) {
        if (videoBuffer) CVPixelBufferRelease(videoBuffer);
        return;
    }

    size_t targetWidth = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    if (targetWidth == 0 || targetHeight == 0) {
        if (videoBuffer) CVPixelBufferRelease(videoBuffer);
        return;
    }
    CGRect targetRect = CGRectMake(0, 0, targetWidth, targetHeight);

    CGRect sourceExtent = source.extent;
    source = [source imageByApplyingTransform:CGAffineTransformMakeTranslation(-sourceExtent.origin.x,
                                                                                -sourceExtent.origin.y)];
    CGFloat radians = ((CGFloat)(rotationValue % 360)) * (CGFloat)M_PI / 180.0;
    if (fabs(radians) > 0.0001) source = [source imageByApplyingTransform:CGAffineTransformMakeRotation(radians)];

    CGRect rotatedExtent = source.extent;
    CGFloat fitScale = MAX((CGFloat)targetWidth / MAX(rotatedExtent.size.width, 1.0),
                           (CGFloat)targetHeight / MAX(rotatedExtent.size.height, 1.0));
    CGFloat scale = fitScale * zoomValue;
    source = [source imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = source.extent;

    CGFloat translateX = ((CGFloat)targetWidth - scaledExtent.size.width) / 2.0 - scaledExtent.origin.x;
    CGFloat translateY = ((CGFloat)targetHeight - scaledExtent.size.height) / 2.0 - scaledExtent.origin.y;
    translateX += offsetXValue * (CGFloat)targetWidth;
    translateY += offsetYValue * (CGFloat)targetHeight;
    source = [source imageByApplyingTransform:CGAffineTransformMakeTranslation(translateX, translateY)];

    CIImage *background = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
                          imageByCroppingToRect:targetRect];
    CIImage *finalImage = [[source imageByCompositingOverImage:background] imageByCroppingToRect:targetRect];
    [renderContext render:finalImage toCVPixelBuffer:targetBuffer bounds:targetRect colorSpace:renderColorSpace];

    if (videoBuffer) CVPixelBufferRelease(videoBuffer);

    if (!sHasLoggedFirstRender) {
        @synchronized (sLock) {
            if (!sHasLoggedFirstRender) {
                sHasLoggedFirstRender = YES;
                VCamSetRuntimeStatus(@"replacementRendered", @YES);
                VCamSetRuntimeStatus(@"replacementRenderedAt", [NSDate date]);
                VCamSetRuntimeStatus(@"renderedFrameSize", [NSString stringWithFormat:@"%zux%zu", targetWidth, targetHeight]);
            }
        }
    }
}
