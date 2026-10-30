#import "vcam_shared.h"
#import <sys/stat.h>

NSString * const VCamPreferenceDomain = @"com.tinysweet.vcamios";
NSString * const VCamMediaPathKey = @"MediaPath";
NSString * const VCamEnabledKey = @"Enabled";
NSString * const VCamOffsetXKey = @"OffsetX";
NSString * const VCamOffsetYKey = @"OffsetY";
NSString * const VCamRotationKey = @"Rotation";
NSString * const VCamZoomKey = @"Zoom";
NSString * const VCamRuntimeVersion = @"0.1.4";

static NSString *VCamPreferencesFilePath(void) {
    return [VCamMediaDirectory() stringByAppendingPathComponent:@"settings.plist"];
}

static NSArray<NSString *> *VCamCameraDaemonNames(void) {
    return @[@"cameracaptured", @"mediaserverd"];
}

static NSString *VCamCurrentDaemonName(void) {
    NSString *name = NSProcessInfo.processInfo.processName.lowercaseString;
    for (NSString *candidate in VCamCameraDaemonNames()) {
        if ([name isEqualToString:candidate]) return candidate;
    }
    return name.length ? name : @"unknown";
}

static NSString *VCamRuntimeStatusDirectory(void) {
    // Keep status separate from imported media. Camera daemons can run under
    // different sandbox identities, so this small diagnostics directory is shared.
    return @"/tmp/VCamStatus";
}

static NSString *VCamRuntimeStatusFilePathForProcess(NSString *processName) {
    NSString *filename = [NSString stringWithFormat:@"runtime-status-%@.plist", processName];
    return [VCamRuntimeStatusDirectory() stringByAppendingPathComponent:filename];
}

static BOOL VCamEnsureRuntimeStatusDirectory(void) {
    NSString *directory = VCamRuntimeStatusDirectory();
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                         withIntermediateDirectories:YES
                                                          attributes:@{ NSFilePosixPermissions: @0777 }
                                                               error:&error];
    if (ok) chmod(directory.fileSystemRepresentation, 0777);
    if (!ok) NSLog(@"[VCam] cannot create runtime status directory %@: %@", directory, error);
    return ok;
}

static NSDictionary *VCamReadRuntimeStatusForProcess(NSString *processName) {
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:VCamRuntimeStatusFilePathForProcess(processName)];
    return [status isKindOfClass:[NSDictionary class]] ? status : @{};
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
    NSMutableDictionary *daemonStatuses = [NSMutableDictionary dictionary];
    NSDictionary *newestStatus = nil;
    NSDate *newestDate = nil;

    for (NSString *processName in VCamCameraDaemonNames()) {
        NSDictionary *status = VCamReadRuntimeStatusForProcess(processName);
        if (status.count == 0) continue;
        daemonStatuses[processName] = status;
        NSDate *loadedAt = [status[@"daemonLoadedAt"] isKindOfClass:[NSDate class]] ? status[@"daemonLoadedAt"] : nil;
        if (!newestStatus || (loadedAt && (!newestDate || [loadedAt compare:newestDate] == NSOrderedDescending))) {
            newestStatus = status;
            newestDate = loadedAt;
        }
    }

    NSMutableDictionary *combined = [newestStatus mutableCopy] ?: [NSMutableDictionary dictionary];
    combined[@"daemonStatuses"] = [daemonStatuses copy];
    return [combined copy];
}

void VCamSetRuntimeStatus(NSString *key, id value) {
    if (key.length == 0) return;
    NSString *processName = VCamCurrentDaemonName();
    NSString *path = VCamRuntimeStatusFilePathForProcess(processName);
    @synchronized (processName) {
        NSMutableDictionary *status = [VCamReadRuntimeStatusForProcess(processName) mutableCopy];
        if (!status) status = [NSMutableDictionary dictionary];
        status[@"daemonProcess"] = processName;
        id oldValue = status[key];
        if (value && [oldValue isEqual:value]) return;
        if (!value && !oldValue) return;
        if (value) status[key] = value;
        else [status removeObjectForKey:key];
        if (!VCamEnsureRuntimeStatusDirectory()) return;
        BOOL didWrite = [status writeToFile:path atomically:YES];
        if (didWrite) chmod(path.fileSystemRepresentation, 0644);
        else NSLog(@"[VCam] failed to write runtime status %@", path);
    }
}

void VCamResetRuntimeStatus(void) {
    NSString *processName = VCamCurrentDaemonName();
    NSString *path = VCamRuntimeStatusFilePathForProcess(processName);
    NSDictionary *initial = @{
        @"runtimeVersion": VCamRuntimeVersion,
        @"daemonLoaded": @YES,
        @"daemonLoadedAt": [NSDate date],
        @"daemonProcess": processName,
        @"daemonPID": @([[NSProcessInfo processInfo] processIdentifier]),
        @"hookState": @"searching",
        @"cameraFramesSeen": @NO,
        @"mediaState": @"not-checked",
        @"replacementRendered": @NO
    };
    @synchronized (processName) {
        if (!VCamEnsureRuntimeStatusDirectory()) return;
        BOOL didWrite = [initial writeToFile:path atomically:YES];
        if (didWrite) chmod(path.fileSystemRepresentation, 0644);
        else NSLog(@"[VCam] failed to reset runtime status %@", path);
    }
}

NSString *VCamMediaDirectory(void) {
    // Shared, world-readable media directory for SpringBoard and camera services.
    // The directory stays 0755 and imported media/settings files stay 0644.
    return @"/tmp/VCam";
}
