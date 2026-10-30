#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VCamPreferenceDomain;
FOUNDATION_EXPORT NSString * const VCamMediaPathKey;
FOUNDATION_EXPORT NSString * const VCamEnabledKey;
FOUNDATION_EXPORT NSString * const VCamOffsetXKey;
FOUNDATION_EXPORT NSString * const VCamOffsetYKey;
FOUNDATION_EXPORT NSString * const VCamRotationKey;
FOUNDATION_EXPORT NSString * const VCamZoomKey;
FOUNDATION_EXPORT NSString * const VCamRuntimeVersion;

FOUNDATION_EXPORT id _Nullable VCamCopySetting(NSString *key);
FOUNDATION_EXPORT void VCamSetSetting(NSString *key, id _Nullable value);
FOUNDATION_EXPORT NSString *VCamMediaDirectory(void);

// Runtime status is written by mediaserverd and read by the SpringBoard menu.
FOUNDATION_EXPORT NSDictionary *VCamCopyRuntimeStatus(void);
FOUNDATION_EXPORT void VCamSetRuntimeStatus(NSString *key, id _Nullable value);
FOUNDATION_EXPORT void VCamResetRuntimeStatus(void);

NS_ASSUME_NONNULL_END
