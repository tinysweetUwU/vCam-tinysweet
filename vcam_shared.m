#import "vcam_shared.h"
#import <sys/stat.h>
#import <notify.h>
#import <time.h>
#import <dispatch/dispatch.h>

NSString * const VCamPreferenceDomain = @"com.tinysweet.vcamios";
NSString * const VCamMediaPathKey = @"MediaPath";
NSString * const VCamMediaTypeKey = @"MediaType";
NSString * const VCamEnabledKey = @"Enabled";
NSString * const VCamOffsetXKey = @"OffsetX";
NSString * const VCamOffsetYKey = @"OffsetY";
NSString * const VCamRotationKey = @"Rotation";
NSString * const VCamZoomKey = @"Zoom";
NSString * const VCamVideoPausedKey = @"VideoPaused";
NSString * const VCamRuntimeVersion = @"0.1.10";

static NSString *VCamPreferencesFilePath(void) {
    return [VCamMediaDirectory() stringByAppendingPathComponent:@"settings.plist"];
}

// On iOS 17.6 the supported camera path for this tweak is mediaserverd.
// Do not report cameracaptured as a required daemon on OS versions where it
// is not part of the camera delivery path.
static NSArray<NSString *> *VCamCameraDaemonNames(void) {
    return @[@"mediaserverd"];
}

static NSString *VCamCurrentDaemonName(void) {
    NSString *name = NSProcessInfo.processInfo.processName.lowercaseString;
    for (NSString *candidate in VCamCameraDaemonNames()) {
        if ([name isEqualToString:candidate]) return candidate;
    }
    return name.length ? name : @"unknown";
}

static NSString *VCamRuntimeStatusDirectory(void) {
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

static NSString *VCamHeartbeatName(NSString *processName) {
    return [NSString stringWithFormat:@"com.tinysweet.vcamios.heartbeat.%@", processName];
}

// notify state is system-wide and does not depend on SpringBoard and
// mediaserverd sharing a sandboxed /tmp view. Tokens are process-local; state
// is maintained by notifyd and can be read by another process.
static int VCamNotifyToken(NSString *processName) {
    static NSMutableDictionary<NSString *, NSNumber *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = [NSMutableDictionary dictionary];
    });

    @synchronized (tokens) {
        NSNumber *cached = tokens[processName];
        if (cached) return cached.intValue;

        int token = NOTIFY_TOKEN_INVALID;
        NSString *name = VCamHeartbeatName(processName);
        uint32_t status = notify_register_check(name.UTF8String, &token);
        if (status != NOTIFY_STATUS_OK || token == NOTIFY_TOKEN_INVALID) {
            NSLog(@"[VCam] notify_register_check failed for %@: %u", name, status);
            return NOTIFY_TOKEN_INVALID;
        }
        tokens[processName] = @(token);
        return token;
    }
}

static uint64_t VCamReadHeartbeatForProcess(NSString *processName) {
    int token = VCamNotifyToken(processName);
    if (token == NOTIFY_TOKEN_INVALID) return 0;
    uint64_t timestamp = 0;
    if (notify_get_state(token, &timestamp) != NOTIFY_STATUS_OK) return 0;
    return timestamp;
}

static void VCamPublishHeartbeatForProcess(NSString *processName) {
    int token = VCamNotifyToken(processName);
    if (token == NOTIFY_TOKEN_INVALID) return;
    uint64_t timestamp = (uint64_t)time(NULL);
    if (notify_set_state(token, timestamp) == NOTIFY_STATUS_OK) {
        notify_post(VCamHeartbeatName(processName).UTF8String);
    }
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
    uint64_t now = (uint64_t)time(NULL);

    for (NSString *processName in VCamCameraDaemonNames()) {
        NSMutableDictionary *status = [VCamReadRuntimeStatusForProcess(processName) mutableCopy];
        if (!status) status = [NSMutableDictionary dictionary];

        uint64_t heartbeat = VCamReadHeartbeatForProcess(processName);
        BOOL heartbeatCurrent = heartbeat > 0 && now >= heartbeat && (now - heartbeat) <= 8;
        status[@"daemonProcess"] = processName;
        status[@"daemonLoaded"] = @(heartbeatCurrent);
        status[@"heartbeatTimestamp"] = @(heartbeat);
        status[@"heartbeatAgeSeconds"] = heartbeat > 0 && now >= heartbeat ? @(now - heartbeat) : @(-1);
        if (heartbeatCurrent && ![status[@"runtimeVersion"] isEqualToString:VCamRuntimeVersion]) {
            status[@"runtimeVersion"] = VCamRuntimeVersion;
            status[@"daemonPID"] = @0; // heartbeat proves the injected runtime is alive; PID may be sandbox-hidden.
        }
        daemonStatuses[processName] = [status copy];

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
    NSString *path = VCamRuntimeStatusFilePathForProcess(processName);
    @synchronized (processName) {
        if (VCamEnsureRuntimeStatusDirectory()) {
            BOOL didWrite = [initial writeToFile:path atomically:YES];
            if (didWrite) chmod(path.fileSystemRepresentation, 0644);
            else NSLog(@"[VCam] failed to reset runtime status %@", path);
        }
    }

    // Publish immediately, then refresh every 2 seconds. A stale state expires
    // after 8 seconds in SpringBoard, so a crashed/restarted daemon is detected.
    VCamPublishHeartbeatForProcess(processName);
    static dispatch_source_t heartbeatTimer;
    static dispatch_once_t timerOnce;
    dispatch_once(&timerOnce, ^{
        heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(heartbeatTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC,
                                  250 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(heartbeatTimer, ^{
            VCamPublishHeartbeatForProcess(processName);
        });
        dispatch_resume(heartbeatTimer);
    });
}

NSString *VCamMediaDirectory(void) {
    return @"/var/mobile/Media/VCam";
}
