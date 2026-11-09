//
//  WQLaunchServices.h
//  WQ Files
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Human app name for a bundle id, from LaunchServices' database (read from
// lsd's container), a built-in table of Apple services, or the parent app.
NSString *_Nullable wq_display_name(NSString *_Nullable bundleID);

NS_ASSUME_NONNULL_END
