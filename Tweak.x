#import "image_utils.h"
#import "vcam_shared.h"
#import <objc/message.h>

%ctor {
    NSLog(@"[VCam] mediaserverd tweak loaded; shared media directory=%@", VCamMediaDirectory());
}

static dispatch_once_t sVCamFirstOutputLog;
static dispatch_once_t sVCamFirstVideoLog;

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    dispatch_once(&sVCamFirstOutputLog, ^{
        NSLog(@"[VCam] BWNodeOutput hook received a sample; mediaType=0x%08x", mediaType);
    });
    if (mediaType != 'vide') {
        %orig(sampleBuffer);
        return;
    }

    dispatch_once(&sVCamFirstVideoLog, ^{
        NSLog(@"[VCam] video sample buffers observed; replacement hook is active");
    });

    CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        %orig(sampleBuffer);
        return;
    }

    @autoreleasepool {
        loadReplacementMedia();
        CVPixelBufferLockBaseAddress(imageBuffer, 0);
        @try {
            drawReplacementOntoBuffer(imageBuffer);
        } @catch (NSException *exception) {
            NSLog(@"[VCam] Failed to render replacement media: %@", exception);
        } @finally {
            CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
        }
    }

    %orig(sampleBuffer);
}

%end
