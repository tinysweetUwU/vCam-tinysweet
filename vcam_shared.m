#import "vcam_shared.h"
#import <sys/stat.h>

NSString * const VCamPreferenceDomain = @"com.tinysweet.vcamios";
NSString * const VCamMediaPathKey = @"MediaPath";
NSString * const VCamEnabledKey = @"Enabled";
NSString * const VCamOffsetXKey = @"OffsetX";
NSString * const VCamOffsetYKey = @"OffsetY";
NSString * const VCamRotationKey = @"Rotation";
NSString * const VCamZoomKey = @"Zoom";

static NSString *VCamPreferencesFilePath(void) {
    return [VCamMediaDirectory() stringByAppendingPathComponent:@"settings.plist"];
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
        NSError *error = nil;
        NSString *directory = path.stringByDeletingLastPathComponent;
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:@{ NSFilePosixPermissions: @0755 }
                                                        error:&error];
        if (!error && [settings writeToFile:path atomically:YES]) {
            chmod(path.fileSystemRepresentation, 0644);
        }
    }
}

NSString *VCamMediaDirectory(void) {
    return @"/var/mobile/Media/VCam";
}
