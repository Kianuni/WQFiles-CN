//
//  WQEditing.h
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Editors implement this so every navigation route (Back, Home and the
// interactive edge swipe) protects unsaved changes in the same way.
@protocol WQUnsavedEditing <NSObject>
- (BOOL)wq_needsLeaveConfirmation;
- (void)confirmLeaveThen:(void (^)(void))proceed;
@end

NS_ASSUME_NONNULL_END
