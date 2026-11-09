#import <Foundation/Foundation.h>
#import "WQAppsSupport.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static NSDictionary *WQBaseManifest(void)
{
    return @{ @"Complete": @YES, @"Format": @1, @"BundleID": @"com.example.app",
              @"Created": [NSDate dateWithTimeIntervalSinceReferenceDate:100],
              @"Parts": @[@"Documents", @"Library"], @"Sequence": @1 };
}

static void TestManifestTypes(void)
{
    NSString *error = nil;
    NSArray *parts = nil;
    WQCheck(WQAppsSupportManifestFields(WQBaseManifest(), @"com.example.app", &parts, &error));
    BOOL canonicalParts = [parts isEqualToArray:@[@"Documents", @"Library"]];
    WQCheck(canonicalParts);

    NSMutableDictionary *wrongBundle = [WQBaseManifest() mutableCopy];
    wrongBundle[@"BundleID"] = @"com.other.app";
    WQCheck(!WQAppsSupportManifestFields(wrongBundle, @"com.example.app", NULL, &error));

    NSMutableDictionary *wrongFormat = [WQBaseManifest() mutableCopy];
    wrongFormat[@"Format"] = @2;
    WQCheck(!WQAppsSupportManifestFields(wrongFormat, @"com.example.app", NULL, &error));

    NSMutableDictionary *missingTimestamp = [WQBaseManifest() mutableCopy];
    [missingTimestamp removeObjectForKey:@"Created"];
    WQCheck(!WQAppsSupportManifestFields(missingTimestamp, @"com.example.app", NULL, &error));

    NSMutableDictionary *duplicatePart = [WQBaseManifest() mutableCopy];
    duplicatePart[@"Parts"] = @[@"Documents", @"Documents"];
    WQCheck(!WQAppsSupportManifestFields(duplicatePart, @"com.example.app", NULL, &error));

    NSMutableDictionary *unexpectedPart = [WQBaseManifest() mutableCopy];
    unexpectedPart[@"Parts"] = @[@"Documents", @"tmp"];
    WQCheck(!WQAppsSupportManifestFields(unexpectedPart, @"com.example.app", NULL, &error));

    NSMutableDictionary *missingParts = [WQBaseManifest() mutableCopy];
    [missingParts removeObjectForKey:@"Parts"];
    WQCheck(!WQAppsSupportManifestFields(missingParts, @"com.example.app", NULL, &error));

    NSMutableDictionary *malformedReason = [WQBaseManifest() mutableCopy];
    malformedReason[@"Reason"] = @[@"not", @"text"];
    WQCheck(!WQAppsSupportManifestFields(malformedReason, @"com.example.app", NULL, &error));

    NSMutableDictionary *malformedSequence = [WQBaseManifest() mutableCopy];
    malformedSequence[@"Sequence"] = @0;
    WQCheck(!WQAppsSupportManifestFields(malformedSequence, @"com.example.app", NULL, &error));

    NSMutableDictionary *stringSequence = [WQBaseManifest() mutableCopy];
    stringSequence[@"Sequence"] = @"10";
    WQCheck(!WQAppsSupportManifestFields(stringSequence, @"com.example.app", NULL, &error));

    NSMutableDictionary *partialManifest = [WQBaseManifest() mutableCopy];
    partialManifest[@"Parts"] = @[@"Library"];
    parts = nil;
    WQCheck(WQAppsSupportManifestFields(partialManifest, @"com.example.app", &parts, &error));
    WQCheck([parts isEqualToArray:@[@"Library"]]);

    NSMutableDictionary *typedComplete = [WQBaseManifest() mutableCopy];
    typedComplete[@"Complete"] = @1;
    WQCheck(!WQAppsSupportManifestFields(typedComplete, @"com.example.app", NULL, &error));
}

static void TestNumericOrdering(void)
{
    NSDate *sameTime = [NSDate dateWithTimeIntervalSinceReferenceDate:100];
    WQCheck(WQAppsSupportBackupSequence(@"2026-11-09 20.00.00") == 1);
    WQCheck(WQAppsSupportBackupSequence(@"2026-11-09 20.00.00 (9)") == 9);
    WQCheck(WQAppsSupportBackupSequence(@"2026-11-09 20.00.00 (10)") == 10);
    WQCheck(WQAppsSupportCompareBackupMetadata(sameTime, 10, @"stamp (10)",
                                                sameTime, 9, @"stamp (9)") == NSOrderedDescending);
    WQCheck(WQAppsSupportCompareBackupMetadata(sameTime, 9, @"stamp (9)",
                                                sameTime, 10, @"stamp (10)") == NSOrderedAscending);
    NSDate *newer = [NSDate dateWithTimeIntervalSinceReferenceDate:101];
    WQCheck(WQAppsSupportCompareBackupMetadata(newer, 1, @"newer",
                                                sameTime, 99, @"older") == NSOrderedDescending);
}

int main(void)
{
    @autoreleasepool {
        TestManifestTypes();
        TestNumericOrdering();
        if (failures) {
            fprintf(stderr, "%d Apps regression check(s) failed\n", failures);
            return 1;
        }
        puts("All Apps manifest/order regression tests passed.");
    }
    return 0;
}
