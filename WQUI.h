//
//  WQUI.h
//  WQ Files shared UI helpers
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

dispatch_queue_t wq_io(void);
void wq_alert(UIViewController *host, NSString *title, NSString *_Nullable message);
NSString *wq_size_text(unsigned long long size);
UIView *wq_device_header(CGFloat width);
UIImage *_Nullable wq_app_icon(NSString *_Nullable bundleID);

NS_ASSUME_NONNULL_END
