//
//  WQSharing.m
//  WQ Files temporary exports and share sheets
//

#import "WQSharing.h"
#import "WQUI.h"
#import "WQAccess.h"

static NSString *wq_unique_export_directory(void)
{
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [@"WQShare-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    return [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:&error] ? dir : nil;
}

static void wq_present_share(UIViewController *host, NSString *file, NSString *exportDir, UIView *source)
{
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:file]] applicationActivities:nil];
    share.popoverPresentationController.sourceView = source ?: host.view;
    share.popoverPresentationController.sourceRect = (source ?: host.view).bounds;
    share.completionWithItemsHandler = ^(UIActivityType __unused activityType, BOOL __unused completed,
                                         NSArray *__unused returnedItems, NSError *__unused activityError) {
        [NSFileManager.defaultManager removeItemAtPath:exportDir error:nil];
    };
    [host presentViewController:share animated:YES completion:nil];
}

// Copies a file into a unique temporary directory so concurrent shares cannot
// overwrite one another. The export is removed when the share sheet finishes.
void wq_share(UIViewController *host, NSString *path, UIView *source)
{
    // Streamed in chunks (large files), and not on the serial I/O queue, which
    // may be busy with a container scan.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSString *outDir = wq_unique_export_directory();
        NSString *tmp = outDir ? [outDir stringByAppendingPathComponent:path.lastPathComponent] : nil;
        BOOL ok = tmp && wq_copy_to_local(path, tmp, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                if (outDir) [NSFileManager.defaultManager removeItemAtPath:outDir error:nil];
                wq_alert(host, @"Cannot share", error ?: @"Could not create a temporary export folder");
                return;
            }
            wq_present_share(host, tmp, outDir, source);
        });
    });
}

static NSString *wq_zip_name(NSString *dir);

// Zips a folder (the system's own zipper via NSFileCoordinator) and opens the
// share sheet, so a backup can go out over AirDrop, Files, Mail…
void wq_share_folder(UIViewController *host, NSString *dir, NSString *zipName, UIView *source)
{
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"Preparing…"
        message:@"Compressing the folder" preferredStyle:UIAlertControllerStyleAlert];
    [host presentViewController:hud animated:YES completion:nil];
    dispatch_async(wq_io(), ^{
        NSString *resolvedName = zipName ?: wq_zip_name(dir);
        NSString *safe = [[resolvedName componentsSeparatedByCharactersInSet:
                           [NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"-"];
        NSString *outDir = wq_unique_export_directory();
        NSString *zip = outDir ? [outDir stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"zip"]] : nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        wq_grant(dir);
        __block NSError *copyError = nil;
        NSError *coordError = nil;
        if (zip) {
            [[NSFileCoordinator new] coordinateReadingItemAtURL:[NSURL fileURLWithPath:dir]
                                                        options:NSFileCoordinatorReadingForUploading
                                                          error:&coordError byAccessor:^(NSURL *zipped) {
                [fm copyItemAtURL:zipped toURL:[NSURL fileURLWithPath:zip] error:&copyError];
            }];
        }
        BOOL ok = zip && [fm fileExistsAtPath:zip];
        NSString *why = (coordError ?: copyError).localizedDescription ?: @"Could not create the ZIP";
        wq_log(@"share zip: %@ -> %@ %@", dir, zip.lastPathComponent, ok ? @"OK" : why);
        dispatch_async(dispatch_get_main_queue(), ^{
            [hud dismissViewControllerAnimated:YES completion:^{
                if (!ok) {
                    if (outDir) [fm removeItemAtPath:outDir error:nil];
                    wq_alert(host, @"Cannot share", why);
                    return;
                }
                wq_present_share(host, zip, outDir, source);
            }];
        });
    });
}

// "Santander 2026-11-09 14.02.11" for AppBackups/<bundle id>/<date>, else the folder name.
static NSString *wq_zip_name(NSString *dir)
{
    NSArray *parts = dir.pathComponents;
    NSUInteger i = [parts indexOfObject:@"AppBackups"];
    if (i != NSNotFound && i + 2 == parts.count - 1) {
        NSString *bid = parts[i + 1];
        return [NSString stringWithFormat:@"%@ %@", wq_display_name(bid) ?: bid, parts.lastObject];
    }
    if (i != NSNotFound && i + 1 == parts.count - 1) {
        NSString *bid = parts.lastObject;
        return [NSString stringWithFormat:@"%@ backups", wq_display_name(bid) ?: bid];
    }
    return dir.lastPathComponent;
}

