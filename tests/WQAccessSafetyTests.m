#import "WQAccessSafety.h"
#include <stdlib.h>

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s (errno %d)\n", name.UTF8String, errno); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [NSTemporaryDirectory().stringByResolvingSymlinksInPath stringByAppendingPathComponent:
                          [@"WQAccessSafetyTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *library = [base stringByAppendingPathComponent:@"Library"];
        NSString *nested = [library stringByAppendingPathComponent:@"Caches/nested"];
        check([fm createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:nil], @"create temp fixture");
        @try {
            NSString *sentinel = [nested stringByAppendingPathComponent:@"sentinel"];
            NSData *bytes = [@"preserve these bytes" dataUsingEncoding:NSUTF8StringEncoding];
            check([bytes writeToFile:sentinel atomically:YES], @"write sentinel");
            int fd = WQOpenDirectoryNoLinks(library);
            check(fd >= 0, @"open no-link library");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin cache swap");
            check([fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-preserved/nested/sentinel"]], @"nested contents preserved while swapped");
            check(WQCacheSwapRecover(fd), @"recover simulated interruption after symlink");
            check([[NSData dataWithContentsOfFile:sentinel] isEqual:bytes], @"original bytes restored");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin second swap");
            check(unlinkat(fd, "Caches", 0) == 0, @"simulate interruption before symlink");
            check(WQCacheSwapRecover(fd), @"recover absent caches");
            check([[NSData dataWithContentsOfFile:sentinel] isEqual:bytes], @"bytes survive absent-path recovery");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin conflict test");
            check(unlinkat(fd, "Caches", 0) == 0 && mkdirat(fd, "Caches", 0755) == 0, @"simulate unexpected caches creator");
            check(!WQCacheSwapRecover(fd), @"recovery refuses unexpected directory");
            check([fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-preserved/nested/sentinel"]], @"conflict retains preserved original");
            check(unlinkat(fd, "Caches", AT_REMOVEDIR) == 0 && WQCacheSwapRecover(fd), @"recover after fixture conflict removed");
            check(WQCacheSwapRecover(fd), @"recovery idempotent");
            NSString *restricted = [base stringByAppendingPathComponent:@"search-only/child"];
            check([fm createDirectoryAtPath:restricted withIntermediateDirectories:YES attributes:nil error:nil], @"create traversal fixture");
            NSString *parent = restricted.stringByDeletingLastPathComponent;
            check(chmod(parent.fileSystemRepresentation, 0111) == 0, @"set traversal-only ancestor permissions");
            @try {
                int child = WQOpenDirectoryNoLinks(restricted);
                check(child >= 0, @"no-follow walk does not require ancestor enumeration");
                close(child);
            } @finally { chmod(parent.fileSystemRepresentation, 0700); }
            check(!WQAbsolutePathGrammar(@"/private/var/../file") && !WQAbsolutePathGrammar(@"/private//var/file"), @"grammar rejects traversal and ambiguous empty components");
            close(fd);
        } @finally {
            [fm removeItemAtPath:base error:nil];
        }
    }
    return 0;
}
