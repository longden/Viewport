#import <Foundation/Foundation.h>

/// Booted CoreSimulator `SimDevice` for `udid`, loading frameworks on demand.
/// Internal to the IndigoTouch target.
id _Nullable ViewportBootedSimDevice(NSString *_Nonnull udid, NSError *_Nullable *_Nullable error);
