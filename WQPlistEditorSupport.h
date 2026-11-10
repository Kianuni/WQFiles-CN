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

// CoreFoundation can write only XML and binary property lists. OpenStep and
// unknown formats are readable but must be treated as read-only documents.
static inline BOOL WQPlistFormatIsWritable(NSPropertyListFormat format)
{
    return format == NSPropertyListXMLFormat_v1_0 || format == NSPropertyListBinaryFormat_v1_0;
}

static inline NSString *WQPlistFormatName(NSPropertyListFormat format)
{
    switch (format) {
        case NSPropertyListXMLFormat_v1_0: return @"XML";
        case NSPropertyListBinaryFormat_v1_0: return @"二进制";
        case NSPropertyListOpenStepFormat: return @"OpenStep";
        default: return @"未知";
    }
}

static inline NSString *WQPBoundedStringPreview(NSString *value)
{
    if (value.length == 0) return @"（空）";
    if (value.length <= WQPMaxDisplayedStringCharacters) return value;

    NSString *suffix = [NSString stringWithFormat:@" …（%lu 个字符）", (unsigned long)value.length];
    NSUInteger prefixLength = suffix.length < WQPMaxDisplayedStringCharacters
        ? WQPMaxDisplayedStringCharacters - suffix.length : 0;
    return [[value substringToIndex:prefixLength] stringByAppendingString:suffix];
}

// NSKeyedArchiver stores object references as CFKeyedArchiverUID values. They
// are not NSNumber/NSString/NSData, and they do not implement -stringValue or
// NSCopying. They are nevertheless valid property-list leaves and must be
// preserved when the document is re-serialized.
static inline BOOL WQPlistIsKeyedArchiveUID(id value)
{
    if (!value) return NO;
    NSString *className = NSStringFromClass([value class]);
    if (![className isEqualToString:@"__NSCFType"] && ![className containsString:@"KeyedArchiverUID"])
        return NO;
    NSString *description = [value description];
    return [description hasPrefix:@"<CFKeyedArchiverUID "];
}

// Immutable, serializable copy of the editor's mutable document. Keyed-archive
// UID leaves are immutable and are passed through unchanged; unsupported
// objects fail the copy instead of reaching NSPropertyListSerialization.
static inline id _Nullable WQPlistImmutableCopy(id value, NSString *_Nullable *_Nullable errorOut)
{
    if (!value) {
        if (errorOut) *errorOut = @"属性列表中包含空值 (nil)。";
        return nil;
    }
    if (WQPlistIsKeyedArchiveUID(value)) return value;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *source = value;
        NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithCapacity:source.count];
        for (id key in source) {
            if (![key isKindOfClass:NSString.class]) {
                if (errorOut) *errorOut = @"字典的键不是字符串类型。";
                return nil;
            }
            id child = WQPlistImmutableCopy(source[key], errorOut);
            if (!child) return nil;
            copy[key] = child;
        }
        return [copy copy];
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSArray *source = value;
        NSMutableArray *copy = [NSMutableArray arrayWithCapacity:source.count];
        for (id childValue in source) {
            id child = WQPlistImmutableCopy(childValue, errorOut);
            if (!child) return nil;
            [copy addObject:child];
        }
        return [copy copy];
    }
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSDate.class] || [value isKindOfClass:NSData.class]) {
        return [value copy];
    }
    if (errorOut) *errorOut = @"属性列表中包含不受支持的值类型。";
    return nil;
}

NS_ASSUME_NONNULL_END
