//
//  WQLaunchServicesTests.m
//  Portable LaunchServices parser/cache regression tests.
//

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "WQAccess.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void Put32(NSMutableData *data, NSUInteger offset, uint32_t value)
{
    memcpy((uint8_t *)data.mutableBytes + offset, &value, sizeof(value));
}

static NSData *StoreWithName(NSString *displayName)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000;
    const NSUInteger nameOffset = 0x1040;
    const NSUInteger displayOffset = 0x1080;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);
    Put32(data, recordOffset + 8 + 0x6c, 2u << 2);
    Put32(data, recordOffset + 8 + 0x74, 3u << 2);

    NSArray<NSString *> *values = @[@"com.example.international", @"Example", displayName];
    NSArray<NSNumber *> *offsets = @[@(idOffset), @(nameOffset), @(displayOffset)];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSData *utf8 = [values[i] dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger offset = offsets[i].unsignedIntegerValue;
        Put32(data, offset, (uint32_t)(i + 1));
        Put32(data, offset + 4, (uint32_t)utf8.length);
        memcpy(bytes + offset + 8, utf8.bytes, utf8.length);
        bytes[offset + 8 + utf8.length] = 0;
    }
    return data;
}

static NSData *StoreWithTruncatedDisplayName(void)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000;
    const NSUInteger truncatedOffset = 0x1ff0;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);
    Put32(data, recordOffset + 8 + 0x6c, 3u << 2);
    Put32(data, recordOffset + 8 + 0x74, 3u << 2);

    NSData *bundleID = [@"com.example.international" dataUsingEncoding:NSUTF8StringEncoding];
    Put32(data, idOffset, 1u);
    Put32(data, idOffset + 4, (uint32_t)bundleID.length);
    memcpy(bytes + idOffset + 8, bundleID.bytes, bundleID.length);
    bytes[idOffset + 8 + bundleID.length] = 0;

    const char *truncated = "Truncate";
    Put32(data, truncatedOffset, 3u);
    Put32(data, truncatedOffset + 4, 8u);
    memcpy(bytes + truncatedOffset + 8, truncated, 8);
    return data;
}

static NSString *TemporaryStorePath(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"WQLaunchServicesTests-%d.csstore", getpid()]];
}

static void WriteData(NSData *data, NSString *path)
{
    NSError *error = nil;
    WQCheck([data writeToFile:path options:NSDataWritingAtomic error:&error]);
    WQCheck(!error);
}

static void TestRetryAfterDiscoveryFailure(NSString *path)
{
    NSMutableData *invalid = [NSMutableData dataWithLength:0x0fff];
    memcpy(invalid.mutableBytes, "bdsl", 4);
    WriteData(invalid, path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    WQCheck(wq_display_name(@"com.example.international") == nil);

    WriteData(StoreWithName(@"Retry 日本"), path);
    sleep(2); // The bounded retry backoff starts at one second.
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Retry 日本"]);
}

static void TestRefreshAndUnicodeSafety(NSString *path)
{
    WriteData(StoreWithName(@"Cafe\u0301 日本 \u202Eevil"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Café 日本 �evil"]);

    WriteData(StoreWithTruncatedDisplayName(), path);
    WQCheck(wq_display_name(@"com.example.international") == nil);

    WriteData(StoreWithName(@"Fresh name"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Fresh name"]);
}

static void TestOversizedStoreFailsClosed(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    WQCheck(fd >= 0);
    if (fd < 0) return;
    off_t size = (off_t)(64u * 1024u * 1024u + 1u);
    WQCheck(ftruncate(fd, size) == 0);
    WQCheck(write(fd, "bdsl", 4) == 4);
    close(fd);
    WQCheck(wq_display_name(@"com.example.international") == nil);
}

int main(void)
{
    @autoreleasepool {
        NSString *path = TemporaryStorePath();
        id oldPreference = [NSUserDefaults.standardUserDefaults objectForKey:@"WQLaunchServicesStore"];
        @try {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WQLaunchServicesStore"];
            TestRetryAfterDiscoveryFailure(path);
            TestRefreshAndUnicodeSafety(path);
            TestOversizedStoreFailsClosed(path);
        } @finally {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            if (oldPreference) [NSUserDefaults.standardUserDefaults setObject:oldPreference forKey:@"WQLaunchServicesStore"];
            else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WQLaunchServicesStore"];
        }
        if (failures) {
            fprintf(stderr, "%d LaunchServices regression check(s) failed\n", failures);
            return 1;
        }
        puts("All LaunchServices regression tests passed.");
    }
    return 0;
}

#pragma mark - Portable WQAccess test doubles

void wq_log(NSString *__unused format, ...)
{
}

BOOL wq_stat(NSString *path, struct stat *st)
{
    return lstat(path.fileSystemRepresentation, st) == 0;
}

NSData *wq_read(NSString *path, NSUInteger maxBytes, NSString **errorText)
{
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (!data) {
        if (errorText) *errorText = error.localizedDescription ?: @"read failed";
        return nil;
    }
    if (maxBytes && data.length > maxBytes) return [data subdataWithRange:NSMakeRange(0, maxBytes)];
    return data;
}

NSArray<NSString *> *wq_enumerate(NSString *__unused dir, int64_t __unused maxInode,
                                   WQScanCancellation *__unused cancellation,
                                   void (^__unused progress)(int64_t, int64_t, NSUInteger))
{
    return nil;
}

NSArray<NSString *> *wq_list(NSString *__unused dir, NSString *__unused *errorText)
{
    return nil;
}
