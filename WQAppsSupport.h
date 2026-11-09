#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <string.h>

// Portable, side-effect-free validation shared by the Apps implementation and
// its macOS fixture tests. Filesystem agreement is checked by WQApps.m.
static BOOL WQAppsSupportIsBool(id value)
{
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL WQAppsSupportIsInteger(id value)
{
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    const char *type = [(NSNumber *)value objCType];
    return strcmp(type, @encode(char)) == 0 || strcmp(type, @encode(unsigned char)) == 0 ||
           strcmp(type, @encode(short)) == 0 || strcmp(type, @encode(unsigned short)) == 0 ||
           strcmp(type, @encode(int)) == 0 || strcmp(type, @encode(unsigned int)) == 0 ||
           strcmp(type, @encode(long)) == 0 || strcmp(type, @encode(unsigned long)) == 0 ||
           strcmp(type, @encode(long long)) == 0 || strcmp(type, @encode(unsigned long long)) == 0;
}

static BOOL WQAppsSupportManifestFailure(NSString **errorOut, NSString *message)
{
    if (errorOut) *errorOut = message;
    return NO;
}

static BOOL WQAppsSupportManifestFields(NSDictionary *manifest, NSString *bundleID,
                                        NSArray<NSString *> **partsOut, NSString **errorOut)
{
    if (![manifest isKindOfClass:NSDictionary.class]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest is not a dictionary");
    }
    if (!WQAppsSupportIsBool(manifest[@"Complete"]) || ![manifest[@"Complete"] boolValue]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest is not marked complete");
    }
    if (!WQAppsSupportIsInteger(manifest[@"Format"]) || [manifest[@"Format"] unsignedIntegerValue] != 1) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest format is unsupported");
    }
    if (![manifest[@"BundleID"] isKindOfClass:NSString.class] ||
        ![(NSString *)manifest[@"BundleID"] length] ||
        ![(NSString *)manifest[@"BundleID"] isEqualToString:bundleID]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest belongs to another app");
    }
    if (![manifest[@"Created"] isKindOfClass:NSDate.class]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest has no valid creation timestamp");
    }
    id reason = manifest[@"Reason"];
    if (reason && ![reason isKindOfClass:NSString.class]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest reason is malformed");
    }
    id sequence = manifest[@"Sequence"];
    if (sequence && (!WQAppsSupportIsInteger(sequence) || [sequence compare:@1] == NSOrderedAscending)) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest sequence is malformed");
    }
    NSArray *parts = manifest[@"Parts"];
    if (![parts isKindOfClass:NSArray.class]) {
        return WQAppsSupportManifestFailure(errorOut, @"The backup manifest parts are malformed");
    }
    NSSet *allowed = [NSSet setWithObjects:@"Documents", @"Library", nil];
    NSMutableSet *seen = [NSMutableSet setWithCapacity:parts.count];
    for (id part in parts) {
        if (![part isKindOfClass:NSString.class] || ![allowed containsObject:part] || [seen containsObject:part]) {
            return WQAppsSupportManifestFailure(errorOut, @"The backup manifest contains an invalid or duplicate part");
        }
        [seen addObject:part];
    }
    NSMutableArray *canonical = [NSMutableArray arrayWithCapacity:seen.count];
    for (NSString *part in @[@"Documents", @"Library"])
        if ([seen containsObject:part]) [canonical addObject:part];
    if (partsOut) *partsOut = canonical;
    return YES;
}

static NSUInteger WQAppsSupportBackupSequence(NSString *name)
{
    if (![name isKindOfClass:NSString.class] || !name.length) return 0;
    if ([name hasSuffix:@")"]) {
        NSRange open = [name rangeOfString:@" (" options:NSBackwardsSearch];
        if (open.location != NSNotFound && open.location + 3 < name.length) {
            NSString *digits = [name substringWithRange:NSMakeRange(open.location + 2, name.length - open.location - 3)];
            NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
            if (digits.length && [digits rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
                NSUInteger sequence = digits.integerValue;
                if (sequence > 0) return sequence;
            }
        }
    }
    return 1;
}

static NSComparisonResult WQAppsSupportCompareBackupMetadata(NSDate *dateA, NSUInteger sequenceA, NSString *nameA,
                                                              NSDate *dateB, NSUInteger sequenceB, NSString *nameB)
{
    NSComparisonResult dateOrder = [dateA compare:dateB];
    if (dateOrder != NSOrderedSame) return dateOrder;
    if (sequenceA < sequenceB) return NSOrderedAscending;
    if (sequenceA > sequenceB) return NSOrderedDescending;
    return [nameA compare:nameB options:NSNumericSearch];
}
