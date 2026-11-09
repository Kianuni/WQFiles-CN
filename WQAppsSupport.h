#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <limits.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Portable, side-effect-free validation shared by the Apps implementation and
// its macOS fixture tests. Filesystem agreement is checked by WQApps.m.
static inline BOOL WQAppsSupportIsBool(id value)
{
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static inline BOOL WQAppsSupportIsInteger(id value)
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

static inline BOOL WQAppsSupportManifestFailure(NSString **errorOut, NSString *message)
{
    if (errorOut) *errorOut = message;
    return NO;
}

static inline BOOL WQAppsSupportManifestFields(NSDictionary *manifest, NSString *bundleID,
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

static inline NSString *WQAppsSupportTreeSignature(NSString *path, BOOL includeIdentity,
                                            BOOL *exists, NSString **errorOut)
{
    struct stat rootStat;
    if (lstat(path.fileSystemRepresentation, &rootStat) != 0) {
        if (errno == ENOENT) {
            if (exists) *exists = NO;
            return @"<missing>";
        }
        if (errorOut) *errorOut = [NSString stringWithFormat:@"Cannot inspect %@", path.lastPathComponent];
        return nil;
    }
    if (!S_ISDIR(rootStat.st_mode)) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"%@ is not a directory", path.lastPathComponent];
        return nil;
    }
    NSError *listError = nil;
    if (![NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:&listError]) {
        if (errorOut) *errorOut = listError.localizedDescription ?: [NSString stringWithFormat:@"Cannot read %@", path.lastPathComponent];
        return nil;
    }
    if (exists) *exists = YES;

    NSMutableArray<NSString *> *entries = [NSMutableArray new];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:path];
    for (NSString *relative in enumerator) {
        NSString *item = [path stringByAppendingPathComponent:relative];
        struct stat itemStat;
        if (lstat(item.fileSystemRepresentation, &itemStat) != 0) {
            if (errorOut) *errorOut = [NSString stringWithFormat:@"Cannot inspect %@", relative];
            return nil;
        }
        unsigned type = (unsigned)(itemStat.st_mode & S_IFMT);
        NSString *name = [NSString stringWithFormat:@"%lu:%@", (unsigned long)relative.length, relative];
        NSString *entry = nil;
        if (includeIdentity) {
            entry = [NSString stringWithFormat:@"I|%@|%u|%llu|%lld.%09ld|%lld.%09ld|%lld",
                     name, type, (unsigned long long)itemStat.st_ino,
                     (long long)itemStat.st_mtimespec.tv_sec, itemStat.st_mtimespec.tv_nsec,
                     (long long)itemStat.st_ctimespec.tv_sec, itemStat.st_ctimespec.tv_nsec,
                     (long long)itemStat.st_size];
        } else if (type == S_IFREG) {
            entry = [NSString stringWithFormat:@"R|%@|%lld|%u", name,
                     (long long)itemStat.st_size, (unsigned)(itemStat.st_mode & 07777)];
        } else if (type == S_IFDIR) {
            entry = [NSString stringWithFormat:@"D|%@|%u", name, (unsigned)(itemStat.st_mode & 07777)];
        } else if (type == S_IFLNK) {
            char target[PATH_MAX];
            ssize_t length = readlink(item.fileSystemRepresentation, target, sizeof(target) - 1);
            if (length < 0 || length >= (ssize_t)sizeof(target) - 1) {
                if (errorOut) *errorOut = [NSString stringWithFormat:@"Cannot inspect link %@", relative];
                return nil;
            }
            target[length] = 0;
            NSString *value = [NSString stringWithUTF8String:target];
            if (!value) {
                if (errorOut) *errorOut = [NSString stringWithFormat:@"Cannot decode link %@", relative];
                return nil;
            }
            entry = [NSString stringWithFormat:@"L|%lu:%@|%lu:%@",
                     (unsigned long)relative.length, relative, (unsigned long)value.length, value];
        } else {
            entry = [NSString stringWithFormat:@"O|%@|%u", name, type];
        }
        [entries addObject:entry];
    }
    [entries sortUsingSelector:@selector(compare:)];
    return [entries componentsJoinedByString:@"\n"];
}

static inline NSUInteger WQAppsSupportBackupSequence(NSString *name)
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

static inline NSComparisonResult WQAppsSupportCompareBackupMetadata(NSDate *dateA, NSUInteger sequenceA, NSString *nameA,
                                                              NSDate *dateB, NSUInteger sequenceB, NSString *nameB)
{
    NSComparisonResult dateOrder = [dateA compare:dateB];
    if (dateOrder != NSOrderedSame) return dateOrder;
    if (sequenceA < sequenceB) return NSOrderedAscending;
    if (sequenceA > sequenceB) return NSOrderedDescending;
    return [nameA compare:nameB options:NSNumericSearch];
}

typedef NS_ENUM(NSInteger, WQAppsSupportJournalState) {
    WQAppsSupportJournalMissing,
    WQAppsSupportJournalActive,
    WQAppsSupportJournalCommitted,
    WQAppsSupportJournalUnknown,
};

static inline WQAppsSupportJournalState WQAppsSupportJournalStateForDictionary(NSDictionary *journal)
{
    if (![journal isKindOfClass:NSDictionary.class]) return WQAppsSupportJournalMissing;
    id state = journal[@"State"];
    if (![state isKindOfClass:NSString.class]) return WQAppsSupportJournalUnknown;
    if ([state isEqualToString:@"Active"]) return WQAppsSupportJournalActive;
    if ([state isEqualToString:@"Committed"]) return WQAppsSupportJournalCommitted;
    return WQAppsSupportJournalUnknown;
}

// A new restore may start only when no recovery is pending. A committed
// journal is safe to clean up and replace; an Active or unknown journal must
// be recovered or explicitly discarded first.
static inline BOOL WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalState state, NSString **error)
{
    if (state == WQAppsSupportJournalActive) {
        if (error) *error = @"An interrupted restore is still active. Recover or discard it before starting another restore";
        return NO;
    }
    if (state == WQAppsSupportJournalUnknown) {
        if (error) *error = @"The existing restore recovery journal has an unknown state";
        return NO;
    }
    return YES;
}
