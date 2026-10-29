#import "image_utils.h"
#import "vcam_shared.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <ImageIO/ImageIO.h>

#define VCAM_VIDEO_MAX_FRAMES 45
#define VCAM_VIDEO_SAMPLE_INTERVAL 0.12
#define VCAM_VIDEO_MAX_DIMENSION 640.0

// These values are shared with the SpringBoard menu through the shared preferences plist.
typedef NS_ENUM(NSUInteger, VCamMode) {
    VCamModeNone = 0,
    VCamModeImage,
    VCamModeVideo
};

static NSObject *sLock = nil;
static dispatch_once_t sLockOnce;
static CIContext *sRenderContext = nil;
static CGColorSpaceRef sRenderColorSpace = NULL;
static CFTimeInterval sVideoStartTime = 0;
static UIImage *sReplacementImage = nil;
static NSArray<UIImage *> *sVideoFrames = nil;
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

static UIImage *VCamDownsampleVideoFrame(CVPixelBufferRef pixelBuffer, CIContext *context, CGAffineTransform preferredTransform) {
    if (!pixelBuffer || !context) return nil;
    CIImage *frame = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!CGAffineTransformIsIdentity(preferredTransform)) {
        frame = [frame imageByApplyingTransform:preferredTransform];
    }
    CGRect originalExtent = frame.extent;
    frame = [frame imageByApplyingTransform:CGAffineTransformMakeTranslation(-originalExtent.origin.x, -originalExtent.origin.y)];
    CGRect extent = frame.extent;
    if (CGRectIsEmpty(extent) || extent.size.width <= 0 || extent.size.height <= 0) return nil;

    CGFloat scale = MIN(1.0, VCAM_VIDEO_MAX_DIMENSION / MAX(extent.size.width, extent.size.height));
    if (scale < 1.0) {
        frame = [frame imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    }

    CGImageRef cgFrame = [context createCGImage:frame fromRect:frame.extent];
    if (!cgFrame) return nil;
    UIImage *result = [UIImage imageWithCGImage:cgFrame scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cgFrame);
    return result;
}

static BOOL VCamDecodeMedia(NSString *path, UIImage **imageOut, NSArray<UIImage *> **framesOut) {
    if (imageOut) *imageOut = nil;
    if (framesOut) *framesOut = nil;
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;

    NSString *extension = path.pathExtension.lowercaseString;
    NSSet *videoExtensions = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v"]];
    if (![videoExtensions containsObject:extension]) {
        NSURL *imageURL = [NSURL fileURLWithPath:path];
        CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)imageURL, NULL);
        if (!imageSource) return NO;
        NSDictionary *thumbnailOptions = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @1920,
            (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES
        };
        CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0,
                                                                    (__bridge CFDictionaryRef)thumbnailOptions);
        CFRelease(imageSource);
        if (!thumbnail) return NO;
        UIImage *image = [UIImage imageWithCGImage:thumbnail scale:1.0 orientation:UIImageOrientationUp];
        CGImageRelease(thumbnail);
        if (imageOut) *imageOut = image;
        return YES;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @NO }];
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader || error) return NO;

    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return NO;

    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks.firstObject
                                                                         outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) return NO;

    CIContext *decodeContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:VCAM_VIDEO_MAX_FRAMES];
    CGAffineTransform preferredTransform = tracks.firstObject.preferredTransform;
    double nextSampleTime = 0.0;

    while (reader.status == AVAssetReaderStatusReading && frames.count < VCAM_VIDEO_MAX_FRAMES) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (!sample) break;
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
            double seconds = CMTIME_IS_NUMERIC(pts) ? CMTimeGetSeconds(pts) : 0.0;
            BOOL shouldKeep = frames.count == 0 || !isfinite(seconds) || seconds + 0.001 >= nextSampleTime;
            if (shouldKeep) {
                CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sample);
                UIImage *frame = VCamDownsampleVideoFrame(pixelBuffer, decodeContext, preferredTransform);
                if (frame) [frames addObject:frame];
                nextSampleTime = (isfinite(seconds) ? seconds : nextSampleTime) + VCAM_VIDEO_SAMPLE_INTERVAL;
            }
            CFRelease(sample);
        }
    }
    if (reader.status == AVAssetReaderStatusReading) [reader cancelReading];
    if (frames.count == 0) return NO;
    if (framesOut) *framesOut = [frames copy];
    return YES;
}

void loadReplacementMedia(void) {
    VCamEnsureState();

    __block NSString *newPath = nil;
    __block NSUInteger generation = 0;
    BOOL shouldStartLoad = NO;

    @synchronized (sLock) {
        sRefreshTicks++;
        // Settings are checked about every ten frames, avoiding plist I/O on every camera frame.
        if (sHasReadSettings && (sRefreshTicks % 10) != 0) return;
        sHasReadSettings = YES;

        id enabledValue = VCamCopySetting(VCamEnabledKey);
        sEnabled = enabledValue ? [enabledValue boolValue] : NO;
        sOffsetX = MAX(-1.0, MIN(1.0, VCamNumber(VCamCopySetting(VCamOffsetXKey), 0.0)));
        sOffsetY = MAX(-1.0, MIN(1.0, VCamNumber(VCamCopySetting(VCamOffsetYKey), 0.0)));
        sZoom = MAX(0.5, MIN(3.0, VCamNumber(VCamCopySetting(VCamZoomKey), 1.0)));
        sRotation = (NSInteger)VCamNumber(VCamCopySetting(VCamRotationKey), 0);

        if (!sEnabled) return;
        id pathValue = VCamCopySetting(VCamMediaPathKey);
        if (![pathValue isKindOfClass:[NSString class]] || [(NSString *)pathValue length] == 0) return;
        newPath = [(NSString *)pathValue copy];
        if ([newPath isEqualToString:sLoadedPath] || (sIsLoading && [newPath isEqualToString:sRequestedPath])) return;

        sLoadGeneration++;
        generation = sLoadGeneration;
        sRequestedPath = [newPath copy];
        sIsLoading = YES;
        sCurrentMode = VCamModeNone;
        sReplacementImage = nil;
        sVideoFrames = nil;
        shouldStartLoad = YES;
    }

    if (!shouldStartLoad) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            UIImage *image = nil;
            NSArray<UIImage *> *frames = nil;
            BOOL success = VCamDecodeMedia(newPath, &image, &frames);

            @synchronized (sLock) {
                if (generation != sLoadGeneration) return;
                sIsLoading = NO;
                sLoadedPath = [newPath copy];
                sVideoStartTime = 0;
                if (!success) {
                    sCurrentMode = VCamModeNone;
                    sReplacementImage = nil;
                    sVideoFrames = nil;
                    return;
                }
                if (image) {
                    sReplacementImage = image;
                    sVideoFrames = nil;
                    sCurrentMode = VCamModeImage;
                } else {
                    sReplacementImage = nil;
                    sVideoFrames = frames;
                    sCurrentMode = VCamModeVideo;
                }
            }
        }
    });
}

void drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (!targetBuffer) return;
    VCamEnsureState();

    @synchronized (sLock) {
        if (!sEnabled || sCurrentMode == VCamModeNone || !sRenderContext) return;

        CIImage *source = nil;
        if (sCurrentMode == VCamModeImage && sReplacementImage.CGImage) {
            source = [CIImage imageWithCGImage:sReplacementImage.CGImage];
        } else if (sCurrentMode == VCamModeVideo && sVideoFrames.count > 0) {
            if (sVideoStartTime <= 0) sVideoStartTime = CACurrentMediaTime();
            NSTimeInterval elapsed = MAX(0, CACurrentMediaTime() - sVideoStartTime);
            NSUInteger frameIndex = ((NSUInteger)(elapsed / VCAM_VIDEO_SAMPLE_INTERVAL)) % sVideoFrames.count;
            UIImage *frame = sVideoFrames[frameIndex];
            if (frame.CGImage) source = [CIImage imageWithCGImage:frame.CGImage];
        }
        if (!source) return;

        size_t targetWidth = CVPixelBufferGetWidth(targetBuffer);
        size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
        if (targetWidth == 0 || targetHeight == 0) return;
        CGRect targetRect = CGRectMake(0, 0, targetWidth, targetHeight);

        // Normalize the image origin, rotate it, then scale-to-fill the camera buffer.
        CGRect sourceExtent = source.extent;
        source = [source imageByApplyingTransform:CGAffineTransformMakeTranslation(-sourceExtent.origin.x,
                                                                                    -sourceExtent.origin.y)];
        CGFloat radians = ((CGFloat)(sRotation % 360)) * (CGFloat)M_PI / 180.0;
        if (fabs(radians) > 0.0001) {
            source = [source imageByApplyingTransform:CGAffineTransformMakeRotation(radians)];
        }

        CGRect rotatedExtent = source.extent;
        CGFloat fitScale = MAX((CGFloat)targetWidth / MAX(rotatedExtent.size.width, 1.0),
                               (CGFloat)targetHeight / MAX(rotatedExtent.size.height, 1.0));
        CGFloat scale = fitScale * sZoom;
        source = [source imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect scaledExtent = source.extent;

        CGFloat offsetX = ((CGFloat)targetWidth - scaledExtent.size.width) / 2.0 - scaledExtent.origin.x;
        CGFloat offsetY = ((CGFloat)targetHeight - scaledExtent.size.height) / 2.0 - scaledExtent.origin.y;
        offsetX += sOffsetX * (CGFloat)targetWidth;
        offsetY += sOffsetY * (CGFloat)targetHeight;
        source = [source imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];

        CIImage *blackBackground = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
                                    imageByCroppingToRect:targetRect];
        CIImage *finalImage = [[source imageByCompositingOverImage:blackBackground] imageByCroppingToRect:targetRect];
        [sRenderContext render:finalImage toCVPixelBuffer:targetBuffer bounds:targetRect colorSpace:sRenderColorSpace];
    }
}
