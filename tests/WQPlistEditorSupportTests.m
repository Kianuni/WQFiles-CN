//
//  WQPlistEditorSupportTests.m
//  WQ Files regression tests
//

#import <Foundation/Foundation.h>
#import "WQPlistEditorSupport.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void TestInputLimits(void)
{
    NSString *stringLimit = [@"" stringByPaddingToLength:WQPMaxStringInputCharacters
                                               withString:@"x"
                                          startingAtIndex:0];
    NSString *stringOver = [stringLimit stringByAppendingString:@"x"];
    NSString *dataLimit = [@"" stringByPaddingToLength:WQPMaxDataInputCharacters
                                             withString:@"0"
                                        startingAtIndex:0];
    NSString *dataOver = [dataLimit stringByAppendingString:@"0"];

    WQCheck(WQPStringInputWithinLimit(stringLimit));
    WQCheck(!WQPStringInputWithinLimit(stringOver));
    WQCheck(WQPDataInputWithinLimit(dataLimit));
    WQCheck(!WQPDataInputWithinLimit(dataOver));
}

static void TestPreviewAndSerializedLimits(void)
{
    NSString *longString = [@"" stringByPaddingToLength:WQPMaxDisplayedStringCharacters + 200
                                             withString:@"a"
                                        startingAtIndex:0];
    NSString *preview = WQPBoundedStringPreview(longString);
    WQCheck(preview.length <= WQPMaxDisplayedStringCharacters);
    WQCheck([preview containsString:@"…"]);
    WQCheck([WQPBoundedStringPreview(@"") isEqualToString:@"(empty)"]);
    WQCheck(WQPBoundedStringPreview(@"short").length == 5);

    NSData *atLimit = [NSMutableData dataWithLength:WQPMaxSerializedBytes];
    NSData *overLimit = [NSMutableData dataWithLength:WQPMaxSerializedBytes + 1];
    WQCheck(WQPSerializedDataWithinLimit(atLimit));
    WQCheck(!WQPSerializedDataWithinLimit(overLimit));
}

int main(void)
{
    @autoreleasepool {
        TestInputLimits();
        TestPreviewAndSerializedLimits();
        if (failures) {
            fprintf(stderr, "%d plist support regression check(s) failed\n", failures);
            return 1;
        }
        puts("All WQPlistEditorSupport regression tests passed.");
    }
    return 0;
}
