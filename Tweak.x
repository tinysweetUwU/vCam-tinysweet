#import "image_utils.h"
#import <objc/message.h>

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType != 'vide') {
        %orig(sampleBuffer);
        return;
    }

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
