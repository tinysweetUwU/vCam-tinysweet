#import <CoreMedia/CoreMedia.h>

// Refreshes shared settings cheaply and loads changed media asynchronously.
void loadReplacementMedia(void);
void drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer);
