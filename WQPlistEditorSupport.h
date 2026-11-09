//
//  WQPlistEditorSupport.h
//  WQ Files
//
//  Portable limits shared by the property-list editor and its regression tests.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    WQPMaxDisplayedStringCharacters = 512,
    WQPMaxStringInputCharacters = 64 * 1024,
    WQPMaxDataBytes = 4 * 1024,
    WQPMaxDataInputCharacters = 16 * 1024,
    WQPMaxSerializedBytes = 64 * 1024 * 1024,
};

static inline BOOL WQPStringInputWithinLimit(NSString *text)
{
    return text.length <= WQPMaxStringInputCharacters;
}

static inline BOOL WQPDataInputWithinLimit(NSString *text)
{
    return text.length <= WQPMaxDataInputCharacters;
}

static inline BOOL WQPSerializedDataWithinLimit(NSData *data)
{
    return data.length <= WQPMaxSerializedBytes;
}

static inline NSString *WQPBoundedStringPreview(NSString *value)
{
    if (value.length == 0) return @"(empty)";
    if (value.length <= WQPMaxDisplayedStringCharacters) return value;

    NSString *suffix = [NSString stringWithFormat:@" … (%lu chars)", (unsigned long)value.length];
    NSUInteger prefixLength = suffix.length < WQPMaxDisplayedStringCharacters
        ? WQPMaxDisplayedStringCharacters - suffix.length : 0;
    return [[value substringToIndex:prefixLength] stringByAppendingString:suffix];
}

NS_ASSUME_NONNULL_END
