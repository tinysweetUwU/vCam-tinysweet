#import "vcam_shared.h"
#import <sys/stat.h>

NSString * const VCamPreferenceDomain = @"com.tinysweet.vcamios";
NSString * const VCamMediaPathKey = @"MediaPath";
NSString * const VCamEnabledKey = @"Enabled";
NSString * const VCamOffsetXKey = @"OffsetX";
NSString * const VCamOffsetYKey = @"OffsetY";
NSString * const VCamRotationKey = @"Rotation";
NSString * const VCamZoomKey = @"Zoom";
NSString * const VCamRuntimeVersion = @"0.1.3";

static NSString *VCamPreferencesFilePath(void) {
    return [VCamMediaDirectory() stringByAppendingPathComponent:@"settings.plist"];
}

static NSString *VCamRuntimeStatusFilePath(void) {
    // Keep diagnostics directly in /tmp so mediaserverd can write its own
    // status without making the selected-media directory world-writable.
    return @"/tmp/VCam-runtime-status.plist";
}

static BOOL VCamEnsureSharedDirectory(void) {
    NSString *directory = VCamMediaDirectory();
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                         withIntermediateDirectories:YES
                                                          attributes:@{ NSFilePosixPermissions: @0755 }
                                                               error:&error];
    if (ok) chmod(directory.fileSystemRepresentation, 0755);
    if (!ok) NSLog(@"[VCam] cannot create shared directory %@: %@", directory, error);
    return ok;
}

id VCamCopySetting(NSString *key) {
    if (key.length == 0) return nil;
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:VCamPreferencesFilePath()];
    return settings[key];
}

void VCamSetSetting(NSString *key, id value) {
    if (key.length == 0) return;
    NSString *path = VCamPreferencesFilePath();
    @synchronized (VCamPreferenceDomain) {
        NSMutableDictionary *settings = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
        if (!settings) settings = [NSMutableDictionary dictionary];
        if (value) settings[key] = value;
        else [settings removeObjectForKey:key];
        if (!VCamEnsureSharedDirectory()) return;
        BOOL didWrite = [settings writeToFile:path atomically:YES];
        if (didWrite) chmod(path.fileSystemRepresentation, 0644);
        else NSLog(@"[VCam] failed to write shared settings %@", path);
    }
}

NSDictionary *VCamCopyRuntimeStatus(void) {
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:VCamRuntimeStatusFilePath()];
    return [status isKindOfClass:[NSDictionary class]] ? status : @{};
}

void VCamSetRuntimeStatus(NSString *key, id value) {
    if (key.length == 0) return;
    NSString *path = VCamRuntimeStatusFilePath();
    @synchronized (@"com.tinysweet.vcamios.runtime") {
        NSMutableDictionary *status = [VCamCopyRuntimeStatus() mutableCopy];
        if (!status) status = [NSMutableDictionary dictionary];
        id oldValue = status[key];
        if (value && [oldValue isEqual:value]) return;
        if (!value && !oldValue) return;
        if (value) status[key] = value;
        else [status removeObjectForKey:key];
        BOOL didWrite = [status writeToFile:path atomically:YES];
        if (didWrite) chmod(path.fileSystemRepresentation, 0644);
        else NSLog(@"[VCam] failed to write runtime status %@", path);
    }
}

void VCamResetRuntimeStatus(void) {
    NSString *path = VCamRuntimeStatusFilePath();
    NSDictionary *initial = @{
        @"runtimeVersion": VCamRuntimeVersion,
        @"daemonLoaded": @YES,
        @"daemonLoadedAt": [NSDate date],
        @"hookState": @"searching",
        @"cameraFramesSeen": @NO,
        @"mediaState": @"not-checked",
        @"replacementRendered": @NO
    };
    @synchronized (@"com.tinysweet.vcamios.runtime") {
        BOOL didWrite = [initial writeToFile:path atomically:YES];
        if (didWrite) chmod(path.fileSystemRepresentation, 0644);
        else NSLog(@"[VCam] failed to reset runtime status %@", path);
    }
}

NSString *VCamMediaDirectory(void) {
    // Shared, world-readable directory so both SpringBoard and mediaserverd
    // can exchange the selected file and diagnostic state.
    return @"/tmp/VCam";
}
