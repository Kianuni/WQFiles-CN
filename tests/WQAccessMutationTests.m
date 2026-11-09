// Compile the real implementation with temp-only backup storage and test barriers.
// Entitlement stubs guarantee that these fixtures cannot issue sandbox tokens.
#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#include <stdlib.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s (errno %d)\n", name.UTF8String, errno); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static void put(NSString *path, NSString *text) { check([bytes(text) writeToFile:path atomically:YES], @"write temp file"); }
static BOOL has(NSString *path, NSString *text) { return [[NSData dataWithContentsOfFile:path] isEqual:bytes(text)]; }
static NSArray<NSString *> *backups(void)
{
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *rel in [NSFileManager.defaultManager enumeratorAtPath:wq_test_backup_root]) {
        NSString *path = [wq_test_backup_root stringByAppendingPathComponent:rel];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) [result addObject:path];
    }
    return result;
}

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"WQAccessMutationTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        check([fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil], @"create temp fixture");
        wq_test_backup_root = [base stringByAppendingPathComponent:@"Backups"];
        wq_test_app_backup_root = [base stringByAppendingPathComponent:@"AppBackups"];
        @try {
            NSString *file = [base stringByAppendingPathComponent:@"file"];
            NSString *error = nil;
            put(file, @"original");
            NSDictionary *version = wq_file_version(file);
            struct stat identity;
            check(wq_stat(file, &identity), @"capture original identity");
            check(wq_write_if_unchanged(file, bytes(@"new"), version, &error), @"conditional write succeeds");
            check(has(file, @"new") && backups().count == 1, @"overwrite retains durable backup");
            NSString *backup = backups().firstObject;
            check(has(backup, @"original") && [wq_backup_original_path(backup) isEqual:file], @"backup maps to original and contains old bytes");
            struct stat after;
            check(wq_stat(file, &after) && WQSameObject(&identity, &after), @"write keeps inode");
            check(!wq_write_if_unchanged(file, bytes(@"stale"), version, &error) && has(file, @"new"), @"stale version rejects without truncation");
            check(wq_write_from_file(file, backup, &error) && has(file, @"original"), @"existing valid backup restores");
            check(!wq_write_from_file(file, file, &error) && has(file, @"original"), @"streamed self-write rejected");
            check(!wq_write(backup, bytes(@"bad"), &error) && has(backup, @"original"), @"backup storage overwrite refused without recursive backup");
            check(!wq_delete(backup, &error) && has(backup, @"original"), @"backup storage delete refused");
            check(wq_delete(file, &error) && ![fm fileExistsAtPath:file] && backups().count == 3, @"regular delete retains durable backup");

            check(wq_is_backup_storage_path(wq_test_backup_root), @"file backup root is protected");
            check(wq_is_backup_storage_path(wq_test_app_backup_root), @"app backup root is protected");
            NSString *appBackup = [[[wq_test_app_backup_root stringByAppendingPathComponent:@"com.example.app"]
                                    stringByAppendingPathComponent:@"2026-11-09 21.00.00"]
                                   stringByAppendingPathComponent:@"Documents/data"];
            check([fm createDirectoryAtPath:appBackup.stringByDeletingLastPathComponent
                  withIntermediateDirectories:YES attributes:nil error:nil], @"create app backup fixture");
            put(appBackup, @"app backup bytes");
            check(!wq_write(appBackup, bytes(@"bad"), &error) && has(appBackup, @"app backup bytes"), @"app backup overwrite refused");
            check(!wq_delete(appBackup, &error) && has(appBackup, @"app backup bytes"), @"app backup delete refused");
            check(!wq_rename(appBackup, @"renamed", &error) && has(appBackup, @"app backup bytes"), @"app backup rename refused");
            check(!wq_create_file([wq_test_app_backup_root stringByAppendingPathComponent:@"new"], bytes(@"x"), &error), @"app backup create refused");
            check(!wq_create_dir([wq_test_app_backup_root stringByAppendingPathComponent:@"newdir"], &error), @"app backup mkdir refused");
            NSString *appSource = [base stringByAppendingPathComponent:@"app-source"];
            put(appSource, @"source");
            check(!wq_create_file_from([wq_test_app_backup_root stringByAppendingPathComponent:@"copy"], appSource, &error), @"app backup streamed create refused");
            check(!wq_copy_to_local(appSource, [wq_test_app_backup_root stringByAppendingPathComponent:@"export"], &error), @"app backup local copy refused");

            NSString *streamSource = [base stringByAppendingPathComponent:@"stream-source"];
            NSString *streamDest = [base stringByAppendingPathComponent:@"stream-dest"];
            put(streamSource, @"source bytes");
            put(streamDest, @"destination original");
            wq_test_stream_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"ready"] && [path isEqual:streamSource]) {
                    put(streamSource, @"source changed while streaming");
                }
            };
            check(!wq_write_from_file(streamDest, streamSource, &error) && has(streamDest, @"destination original"),
                  @"streamed write rejects a source that changes during the copy");
            wq_test_stream_hook = nil;
            put(streamSource, @"source bytes");
            NSString *streamNew = [base stringByAppendingPathComponent:@"stream-new"];
            wq_test_stream_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"ready"] && [path isEqual:streamSource]) {
                    put(streamSource, @"source changed while streaming");
                }
            };
            check(!wq_create_file_from(streamNew, streamSource, &error) && ![fm fileExistsAtPath:streamNew],
                  @"streamed create removes a partial destination when the source changes");
            wq_test_stream_hook = nil;

            // Deterministic version change after descriptor verification, before backup.
            put(file, @"original");
            version = wq_file_version(file);
            wq_test_mutation_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"verified"]) put(path, @"concurrent");
            };
            check(!wq_write_if_unchanged(file, bytes(@"bad"), version, &error) && has(file, @"concurrent"), @"write rejects pathname replacement after verification");
            wq_test_mutation_hook = nil;
            put(file, @"original"); version = wq_file_version(file);
            wq_test_mutation_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"backedUp"]) {
                    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_TRUNC);
                    check(fd >= 0 && WQWriteBytes(fd, bytes(@"concurrent")), @"inject uncooperative same-inode write");
                    close(fd);
                }
            };
            check(!wq_patch_if_unchanged(file, @{ @0: bytes(@"bad") }, version, &error) && has(file, @"concurrent"), @"patch rejects same-inode change after backup");
            wq_test_mutation_hook = nil;
            put(file, @"original"); version = wq_file_version(file);
            NSString *detached = [base stringByAppendingPathComponent:@"detached"];
            wq_test_mutation_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"written"]) {
                    check(rename(path.fileSystemRepresentation, detached.fileSystemRepresentation) == 0, @"inject target rename during finish");
                    put(path, @"newer-target");
                }
            };
            check(!wq_write_if_unchanged(file, bytes(@"changed"), version, &error), @"target swap during finish reports failure");
            check(has(file, @"newer-target") && has(detached, @"original"), @"rollback restores only pinned inode, not replacement");
            wq_test_mutation_hook = nil;
            int locked = open(file.fileSystemRepresentation, O_RDWR);
            check(locked >= 0 && flock(locked, LOCK_EX | LOCK_NB) == 0, @"hold cooperating writer lock");
            check(!wq_write(file, bytes(@"bad"), &error) && has(file, @"newer-target"), @"mutation refuses another writer lock");
            close(locked);
            check(wq_patch(file, @{ @0: bytes(@"NEW") }, &error) && has(file, @"NEWer-target"), @"valid patch keeps size and remaining bytes");
            check(!wq_patch(file, @{ @999: bytes(@"bad") }, &error), @"out-of-range patch refused");

            NSString *fifo = [base stringByAppendingPathComponent:@"fifo"];
            check(mkfifo(fifo.fileSystemRepresentation, 0600) == 0, @"create temp FIFO");
            check(!wq_read(fifo, 0, &error) && !wq_read_range(fifo, 0, 10, &error), @"FIFO reads return without blocking");
            check(!wq_write(fifo, bytes(@"bad"), &error), @"FIFO write refused");
            check(!wq_read(base, 0, &error), @"directory read refused");
            NSString *link = [base stringByAppendingPathComponent:@"link"];
            check(symlink(file.fileSystemRepresentation, link.fileSystemRepresentation) == 0, @"create final symlink fixture");
            check(!wq_write(link, bytes(@"bad"), &error) && has(file, @"NEWer-target"), @"symlink mutation refused");

            NSString *restricted = [base stringByAppendingPathComponent:@"search-only-parent"];
            check([fm createDirectoryAtPath:restricted withIntermediateDirectories:YES attributes:nil error:nil], @"create search-only parent");
            NSString *restrictedFile = [restricted stringByAppendingPathComponent:@"file"];
            put(restrictedFile, @"restricted original");
            check(chmod(restricted.fileSystemRepresentation, 0111) == 0, @"remove ancestor enumeration permission");
            @try {
                check(wq_write(restrictedFile, bytes(@"restricted new"), &error) && has(restrictedFile, @"restricted new"), @"mutation needs search but not ancestor read-directory rights");
            } @finally { chmod(restricted.fileSystemRepresentation, 0700); }
            check(chmod(restrictedFile.fileSystemRepresentation, 0400) == 0, @"make disposable file read-only");
            check(wq_delete(restrictedFile, &error), @"read-only regular file delete still backs up and succeeds");

            for (NSString *stage in @[@"verified", @"backedUp"]) {
                for (NSNumber *patch in @[@NO, @YES]) {
                    for (NSNumber *replace in @[@NO, @YES]) {
                        put(file, @"original");
                        NSDictionary *snapshot = wq_file_version(file);
                        wq_test_mutation_hook = ^(NSString *point, NSString *path) {
                            if (![point isEqual:stage]) return;
                            if (replace.boolValue) put(path, @"newer");
                            else {
                                int fd = open(path.fileSystemRepresentation, O_WRONLY | O_TRUNC);
                                check(fd >= 0 && WQWriteBytes(fd, bytes(@"newer")), @"inject version-race matrix write");
                                close(fd);
                            }
                        };
                        BOOL changed = patch.boolValue ? wq_patch_if_unchanged(file, @{ @0: bytes(@"bad") }, snapshot, &error)
                                                       : wq_write_if_unchanged(file, bytes(@"bad"), snapshot, &error);
                        check(!changed && has(file, @"newer"), @"write/patch reject inode or version swap at both pre-write barriers");
                        wq_test_mutation_hook = nil;
                    }
                }
            }

            check(WQBackupStampValid(@"20261109-203000-123-11") && WQBackupStampValid(@"20261109-203000"), @"current and historical stamps accepted");
            for (NSString *stamp in @[@"garbage", @"20261109-203000\n", @"20261309-203000-123-1", @"20260230-203000-123-1", @"20261109-253000-123-1", @"20261109-203000-123-0", @"20261109-203000-123-01", @"20261109-203000-123-18446744073709551616"]) {
                check(!WQBackupStampValid(stamp), @"malformed stamp rejected");
            }
            check(!wq_backup_original_path([wq_test_backup_root stringByAppendingPathComponent:@"garbage/private/var/file"]), @"arbitrary stamp cannot supply restore path");
            check(!wq_backup_original_path([wq_test_backup_root stringByAppendingString:@"/20261109-203000-123-1/private/var/../file"]), @"raw traversal restore path rejected");

            NSDictionary *savedVersion = nil;
            put(file, @"original");
            check(wq_write_if_unchanged_get_version(file, bytes(@"first"), wq_file_version(file), &savedVersion, &error), @"verified write returns saved descriptor version");
            check([savedVersion isEqual:wq_file_version(file)] && has(file, @"first"), @"saved write version belongs to verified contents");
            check(wq_write_if_unchanged_get_version(file, bytes(@"second"), savedVersion, &savedVersion, &error), @"repeat write does not require reopening");
            check(wq_patch_if_unchanged_get_version(file, @{ @0: bytes(@"S") }, savedVersion, &savedVersion, &error) && has(file, @"Second"), @"verified patch returns reusable version");
            check(wq_patch_if_unchanged_get_version(file, @{ @1: bytes(@"E") }, savedVersion, &savedVersion, &error) && has(file, @"SEcond"), @"repeat patch does not require reopening");
            NSDictionary *oldSavedVersion = savedVersion;
            put(file, @"external later");
            check(!wq_write_if_unchanged_get_version(file, bytes(@"bad"), oldSavedVersion, &savedVersion, &error) && savedVersion == nil && has(file, @"external later"), @"later external edit rejects old result version");
            for (NSNumber *patch in @[@NO, @YES]) {
                put(file, @"original");
                NSDictionary *snapshot = wq_file_version(file);
                wq_test_mutation_hook = ^(NSString *stage, NSString *path) {
                    if ([stage isEqual:@"written"]) {
                        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_TRUNC);
                        check(fd >= 0 && WQWriteBytes(fd, bytes(@"external")), @"inject post-write concurrent contents");
                        close(fd);
                    }
                };
                BOOL ok = patch.boolValue ? wq_patch_if_unchanged_get_version(file, @{ @0: bytes(@"X") }, snapshot, &savedVersion, &error)
                                         : wq_write_if_unchanged_get_version(file, bytes(@"intended"), snapshot, &savedVersion, &error);
                check(!ok && savedVersion == nil && has(file, @"external"), @"post-write interference is not adopted or rolled back over");
                wq_test_mutation_hook = nil;
            }
            check(wq_enumerate([base stringByAppendingPathComponent:@"absent"], 1, nil, nil) == nil, @"missing enumeration base is failure, not empty success");
            wq_test_volume_limit = 0;
            check(wq_enumerate(base, 0, nil, nil) == nil, @"unavailable inode probe is failure, not silent fixed-range success");
            check(wq_enumerate(base, 1, nil, nil) != nil, @"explicit small bound still supports successful empty enumeration");
            check(wq_enumerate(base, INT64_MAX, nil, nil) == nil, @"overflowing scan bound is rejected before work dispatch");
            wq_test_volume_limit = -1;
        } @finally {
            wq_test_mutation_hook = nil;
            wq_test_stream_hook = nil;
            wq_test_backup_root = nil;
            wq_test_app_backup_root = nil;
            wq_test_volume_limit = -1;
            [fm removeItemAtPath:base error:nil];
        }
    }
    return 0;
}
