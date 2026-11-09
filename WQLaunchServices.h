//
//  WQLaunchServices.h
//  WQ Files
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Human app name for a bundle id, from LaunchServices' database (read from
// lsd's container), a built-in table of Apple services, or the parent app.
NSString *_Nullable wq_display_name(NSString *_Nullable bundleID);

// Whether the name database is loaded; loading it (blocking, off the main
// thread) the first time can take a while, so screens show a status for it.
BOOL wq_display_names_loaded(void);
void wq_load_display_names(void);
// After a user's refresh: search for a database that wasn't found before
// right away instead of waiting a day.
void wq_display_names_reset_miss(void);

NS_ASSUME_NONNULL_END
