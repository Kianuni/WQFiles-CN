//
//  WQAccess.m
//  WQ Files
//
//  Sandbox extension technique: worse_query by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//
//  Notes from testing on 27.0.1:
//  - An extension covers the folder it was issued for. A container root
//    extension was not enough to open a file two levels down for writing, so
//    writes always ask for the file's own folder first.
//  - /var/containers/Shared/SystemGroup itself gets no token; its children do.
//

#import "WQAccess.h"
#import "WQCore.h"
#import "WQAccessSafety.h"
#import <dlfcn.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <stdatomic.h>
#import <sys/clonefile.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/xattr.h>
#import <unistd.h>
#import <xpc/xpc.h>

@implementation WQScanCancellation {
    _Atomic BOOL _cancelled;
}

- (BOOL)isCancelled
{
    return atomic_load_explicit(&_cancelled, memory_order_relaxed);
}

- (void)cancel
{
    atomic_store_explicit(&_cancelled, YES, memory_order_relaxed);
}

@end

#pragma mark - Log

static NSMutableString *gLog;
static NSLock *gLogLock;

void wq_log(NSString *format, ...)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLog = [NSMutableString new]; gLogLock = [NSLock new]; });
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[wqfiles] %@", line);
    [gLogLock lock];
    [gLog appendFormat:@"%@\n", line];
    [gLogLock unlock];
}

NSString *wq_log_text(void)
{
    [gLogLock lock];
    NSString *text = [gLog copy] ?: @"";
    [gLogLock unlock];
    return text;
}

static NSString *wq_errno(int err) { return [NSString stringWithFormat:@"%s (errno %d)", strerror(err), err]; }

#pragma mark - App group

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

NSString *wq_app_group(void)
{
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *groups = nil;
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (task) {
            CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
            if (value) groups = (__bridge_transfer NSArray *)value;
            CFRelease(task);
        }
        for (id candidate in groups) {
            if (![candidate isKindOfClass:NSString.class]) continue;
            NSURL *root = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:candidate];
            if (root) {
                group = candidate;
                if (!WQRecoverCacheSwapAtPath([root.path stringByAppendingPathComponent:@"Library"]))
                    wq_log(@"App-group cache recovery requires attention; preserved contents retained: %@ (%@)", root.path, wq_errno(errno));
                break;
            }
        }
        wq_log(@"App group: %@ (entitled: %@)", group ?: @"NONE",
               groups.count ? [groups componentsJoinedByString:@", "] : @"none");
    });
    return group;
}

#pragma mark - worse_query

typedef void *(*cq_create_fn)(void);
typedef void (*cq_set_u64_fn)(void *, uint64_t);
typedef void (*cq_set_ids_fn)(void *, xpc_object_t);
typedef void *(*cq_result_fn)(void *);
typedef void (*cq_free_fn)(void *);
typedef char *(*cq_token_fn)(void *);
typedef int64_t (*ext_consume_fn)(const char *);
// The callback returns true to continue; a void block leaves that value undefined.
typedef void (*cq_iterate_fn)(void *, bool (^)(void *));
typedef const char *(*co_get_path_fn)(void *);
typedef const char *(*co_get_id_fn)(void *);

static void wq_release_handle(int64_t handle);

static int64_t wq_query_token(NSString *group, BOOL altFlags)
{
    static void *mgr;
    static cq_create_fn create;
    static cq_set_u64_fn setClass, setFlags, setPart;
    static cq_set_ids_fn setGroups;
    static cq_result_fn single;
    static cq_free_fn freeQuery;
    static cq_token_fn copyToken;
    static ext_consume_fn consume;
    if (!mgr) {
        mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (!mgr) return -2;
        create = (cq_create_fn)dlsym(mgr, "container_query_create");
        setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
        setGroups = (cq_set_ids_fn)dlsym(mgr, "container_query_set_group_identifiers");
        setFlags = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_flags");
        setPart = (cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_part");
        single = (cq_result_fn)dlsym(mgr, "container_query_get_single_result");
        freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
        copyToken = (cq_token_fn)dlsym(mgr, "container_copy_sandbox_token");
        consume = (ext_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    }
    if (!create || !setClass || !setGroups || !setFlags || !setPart || !single || !freeQuery || !copyToken || !consume) return -2;

    void *query = create();
    if (!query) return -3;
    char *token = NULL;
    @try {
        setClass(query, 7);  // app group container
        xpc_object_t ident = xpc_string_create(group.UTF8String);
        setGroups(query, ident);
        setPart(query, 3);   // Library/Caches
        setFlags(query, altFlags ? 0x0000000800000000ULL : 0x0000008000000000ULL);
        void *result = single(query);
        token = result ? copyToken(result) : NULL;
        int64_t handle = token ? consume(token) : (result ? -6 : -5);
        return token && handle < 0 ? -7 : handle;
    } @finally {
        if (token) free(token);
        freeQuery(query);
    }
}

BOOL wq_system_areas_reachable(void)
{
    // worse_query reaches System Data, the system groups and the App Groups
    // parent only on iOS 27; on iOS 26 it reaches the individual app,
    // extension, daemon and app group containers.
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

static int64_t wq_query(NSString *target, BOOL altFlags)
{
    NSString *group = wq_app_group();
    if (!group) return -1;
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return -1;
    NSString *libraryPath = [root.path stringByAppendingPathComponent:@"Library"];
    if (![files createDirectoryAtPath:libraryPath withIntermediateDirectories:YES attributes:nil error:nil]) return -4;
    int library = WQOpenDirectoryNoLinks(libraryPath);
    if (library < 0) return -4;
    int lock = WQOpenRegularAt(library, ".wq-caches-lock", O_RDWR | O_CREAT, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        if (lock >= 0) close(lock);
        close(library);
        return -4;
    }
    int64_t handle = -4;
    @try {
        // Keep the exact Caches swap point required by worse_query, but preserve
        // its original inode and nested contents. Next acquisition recovers an
        // interrupted swap from the durable marker, before doing another query.
        if (WQCacheSwapBegin(library, target)) handle = wq_query_token(group, altFlags);
    } @catch (NSException *exception) {
        wq_log(@"token query exception: %@", exception.reason);
        handle = -9;
    } @finally {
        if (!WQCacheSwapRecover(library)) {
            wq_log(@"token cache recovery failed: %@; preserved contents retained", libraryPath);
            if (handle >= 0) wq_release_handle(handle);
            handle = -8;
        }
        close(lock);
        close(library);
    }
    return handle;
}

static NSMutableDictionary<NSString *, NSNumber *> *gGrants;
static NSMutableArray<NSString *> *gGrantOrder;   // oldest first
// The kernel limits how many sandbox extensions a process may hold. Keep a
// bounded working set and release the oldest; released paths are simply
// granted again when they are next used.
static const NSUInteger kMaxGrants = 192;

static void wq_release_handle(int64_t handle)
{
    typedef int (*ext_release_fn)(int64_t);
    static ext_release_fn release;
    if (!release) release = (ext_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release && handle >= 0) release(handle);
}
static NSRecursiveLock *gGrantLock;

static NSString *wq_norm(NSString *path)
{
    NSString *p = path.stringByStandardizingPath;
    if ([p hasPrefix:@"/var/"]) p = [@"/private" stringByAppendingString:p];
    return p;
}

BOOL wq_grant(NSString *path)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gGrants = [NSMutableDictionary new];
        gGrantOrder = [NSMutableArray new];
        gGrantLock = [NSRecursiveLock new];
    });
    NSString *key = wq_norm(path);
    [gGrantLock lock];
    NSNumber *known = gGrants[key];
    if (known) {
        [gGrantOrder removeObject:key];   // most recently used goes last
        [gGrantOrder addObject:key];
        [gGrantLock unlock];
        return YES;
    }
    while (gGrantOrder.count >= kMaxGrants) {
        NSString *oldest = gGrantOrder.firstObject;
        wq_release_handle(gGrants[oldest].longLongValue);
        [gGrants removeObjectForKey:oldest];
        [gGrantOrder removeObjectAtIndex:0];
    }
    struct stat st;
    if (lstat(key.fileSystemRepresentation, &st) != 0) {
        [gGrantLock unlock];
        return NO;  // worse_query needs an existing target
    }
    // iOS 26 needs the alternative query flags; try the likely ones first so
    // a grant costs one query, and the other set only when that fails.
    BOOL altFirst = !wq_system_areas_reachable();
    int64_t handle = wq_query(key, altFirst);
    if (handle < 0 && handle != -1 && handle != -2) {
        int64_t alt = wq_query(key, !altFirst);
        if (alt >= 0) handle = alt;
    }
    if (handle >= 0) {  // failures are retried next time
        gGrants[key] = @(handle);
        [gGrantOrder addObject:key];
    }
    [gGrantLock unlock];
    return handle >= 0;
}

static BOOL wq_is_denied(int err) { return err == EPERM || err == EACCES; }

#pragma mark - Backups

#ifdef WQ_ACCESS_TESTING
static NSString *wq_test_backup_root;
static NSString *wq_test_app_backup_root;
static int64_t wq_test_volume_limit = -1;
static void (^wq_test_mutation_hook)(NSString *stage, NSString *path);
static void (^wq_test_tree_hook)(NSString *stage, NSString *path);
static void (^wq_test_stream_hook)(NSString *stage, NSString *path);
#define WQ_TREE_HOOK(stage, path) do { if (wq_test_tree_hook) wq_test_tree_hook(stage, path); } while (0)
#define WQ_MUTATION_HOOK(stage, path) do { if (wq_test_mutation_hook) wq_test_mutation_hook(stage, path); } while (0)
#define WQ_STREAM_HOOK(stage, path) do { if (wq_test_stream_hook) wq_test_stream_hook(stage, path); } while (0)
#else
#define WQ_MUTATION_HOOK(stage, path) do {} while (0)
#define WQ_TREE_HOOK(stage, path) do {} while (0)
#define WQ_STREAM_HOOK(stage, path) do {} while (0)
#endif

NSString *wq_backup_root(void)
{
#ifdef WQ_ACCESS_TESTING
    if (wq_test_backup_root) return wq_test_backup_root;
#endif
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Backups"];
}

NSString *wq_app_backup_root(void)
{
#ifdef WQ_ACCESS_TESTING
    if (wq_test_app_backup_root) return wq_test_app_backup_root;
#endif
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"AppBackups"];
}

BOOL wq_is_backup_storage_path(NSString *path)
{
    NSString *original = WQCanonicalVarPath(path);
    NSMutableArray<NSString *> *roots = [NSMutableArray new];
    NSString *fileRoot = WQCanonicalVarPath(wq_backup_root());
    NSString *appRoot = WQCanonicalVarPath(wq_app_backup_root());
    if (fileRoot.length) [roots addObject:fileRoot];
    if (appRoot.length) [roots addObject:appRoot];
    for (NSString *root in roots) {
        if ([original isEqualToString:root] || [original hasPrefix:[root stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static int wq_open(NSString *path, int flags, mode_t mode);
static int wq_open_directory_flags(NSString *path, int flags);

// Copies everything from fd `in` to fd `out` in chunks; fsyncs `out`.
static BOOL wq_stream(int in, int out, NSString **errorText)
{
    static const size_t kChunk = 1 << 20;
    uint8_t *buf = malloc(kChunk);
    if (!buf) { if (errorText) *errorText = @"Out of memory"; return NO; }
    BOOL ok = YES;
    for (;;) {
        ssize_t n = read(in, buf, kChunk);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = NO; if (errorText) *errorText = wq_errno(errno); break; }
        if (n == 0) break;
        for (ssize_t done = 0; done < n; ) {
            ssize_t w = write(out, buf + done, (size_t)(n - done));
            if (w < 0 && errno == EINTR) continue;
            if (w <= 0) { ok = NO; if (errorText) *errorText = wq_errno(w == 0 ? EIO : errno); break; }
            done += w;
        }
        if (!ok) break;
    }
    free(buf);
    if (ok && fsync(out) != 0) { ok = NO; if (errorText) *errorText = wq_errno(errno); }
    return ok;
}

// Always durable, including own files. Safety artifacts themselves are protected
// from generic overwrite/delete: recursively backing up Backups is unbounded.
static BOOL wq_backup_fd(NSString *path, int fd, NSString **backupPath, NSString **errorText)
{
    if (errorText) *errorText = nil;
    NSString *original = WQCanonicalVarPath(path);
    NSString *root = WQCanonicalVarPath(wq_backup_root());
    if (!WQAbsolutePathGrammar(original) || wq_is_backup_storage_path(original)) {
        wq_log(@"backup: refusing invalid path or mutation of backup storage: %@", path);
        if (errorText) *errorText = @"The path is invalid or belongs to backup storage.";
        return NO;
    }
    static NSDateFormatter *fmt;
    static uint64_t counter;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        fmt.dateFormat = @"yyyyMMdd-HHmmss-SSS";
        lock = [NSLock new];
    });
    [lock lock];
    NSString *stamp = counter == UINT64_MAX ? nil :
        [NSString stringWithFormat:@"%@-%llu", [fmt stringFromDate:NSDate.date], (unsigned long long)++counter];
    [lock unlock];
    if (!stamp) {
        if (errorText) *errorText = @"Cannot allocate a backup name.";
        return NO;
    }
    NSString *dest = [[root stringByAppendingPathComponent:stamp] stringByAppendingString:original];
    int parent = WQCreateDirectoriesNoLinks(dest.stringByDeletingLastPathComponent);
    if (parent < 0) {
        if (errorText) *errorText = wq_errno(errno);
        return NO;
    }
    const char *name = dest.lastPathComponent.fileSystemRepresentation;
    NSString *error = nil;
    BOOL ok = NO;
    // APFS clone first: a copy-on-write snapshot is independent, durable, and
    // does not require a full-size duplicate for every edited file.
    if (fclonefileat(fd, parent, name, 0) == 0) {
        int cloned = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat clonedStat = {0}, sourceStat = {0};
        if (cloned >= 0 && fstat(cloned, &clonedStat) == 0 && fstat(fd, &sourceStat) == 0 &&
            clonedStat.st_size == sourceStat.st_size && fsync(cloned) == 0) {
            ok = YES;
        } else {
            error = wq_errno(errno);
        }
        if (cloned >= 0) close(cloned);
        if (!ok) {
            unlinkat(parent, name, 0);
            wq_log(@"backup: clone verification failed for %@ (%@)", path, error ?: @"unknown error");
        }
    } else {
        int cloneError = errno;
        wq_log(@"backup: clone unavailable for %@ (%@); streaming", path, wq_errno(cloneError));
        struct stat sourceStat = {0};
        struct statfs space = {0};
        if (fstat(fd, &sourceStat) == 0 && fstatfs(parent, &space) == 0) {
            unsigned long long available = (unsigned long long)space.f_bavail * (unsigned long long)space.f_bsize;
            if ((unsigned long long)sourceStat.st_size > available) {
                error = @"Not enough free space for a full backup copy";
                wq_log(@"backup: %@ (%@)", path, error);
                if (errorText) *errorText = error;
                close(parent);
                return NO;
            }
        }
        int out = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (out >= 0) {
            ok = lseek(fd, 0, SEEK_SET) >= 0 && wq_stream(fd, out, &error);
            if (close(out) != 0) ok = NO;
        } else {
            error = wq_errno(errno);
        }
        if (ok && fsync(parent) != 0) ok = NO;
        if (!ok) unlinkat(parent, name, 0);
    }
    if (ok && fsync(parent) != 0) { ok = NO; error = wq_errno(errno); }
    if (!ok) unlinkat(parent, name, 0);
    close(parent);
    wq_log(@"backup: %@ -> %@", path, ok ? dest : error ?: @"FAILED");
    if (ok && backupPath) *backupPath = dest;
    if (!ok && errorText) *errorText = error ?: @"Backup copy failed.";
    return ok;
}

NSString *wq_backup_original_path(NSString *backupPath)
{
    // Validate raw components before normalization, so traversal is never hidden.
    if (!WQAbsolutePathGrammar(backupPath)) return nil;
    NSString *rootPath = WQCanonicalVarPath(wq_backup_root());
    if (!rootPath.length) return nil;
    NSString *root = [rootPath stringByAppendingString:@"/"];
    NSString *p = WQCanonicalVarPath(backupPath);
    if (![p hasPrefix:root]) return nil;
    NSArray *parts = [[p substringFromIndex:root.length] componentsSeparatedByString:@"/"];
    if (parts.count < 2 || !WQBackupStampValid(parts[0])) return nil;
    NSString *original = [@"/" stringByAppendingString:[[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"/"]];
    return WQAbsolutePathGrammar(original) ? original : nil;
}

#pragma mark - File operations

static NSDictionary<NSString *, NSNumber *> *wq_version_for_stat(const struct stat *st)
{
    return @{ @"device": @(st->st_dev), @"inode": @(st->st_ino), @"size": @(st->st_size),
              @"modifiedSeconds": @(st->st_mtimespec.tv_sec), @"modifiedNanoseconds": @(st->st_mtimespec.tv_nsec),
              @"changedSeconds": @(st->st_ctimespec.tv_sec), @"changedNanoseconds": @(st->st_ctimespec.tv_nsec) };
}

NSDictionary<NSString *, NSNumber *> *wq_file_version(NSString *path)
{
    struct stat st;
    if (!wq_stat(path, &st) || !S_ISREG(st.st_mode)) return nil;
    return wq_version_for_stat(&st);
}

static BOOL wq_changed(NSString **errorText)
{
    if (errorText) *errorText = @"The file changed after it was opened. Your edits were not written; reopen it and compare the changes.";
    return NO;
}

typedef struct {
    int fd;
    int parent;
    struct stat before;
} WQMutation;

static void wq_mutation_close(WQMutation *mutation)
{
    if (mutation->fd >= 0) close(mutation->fd);
    if (mutation->parent >= 0) close(mutation->parent);
    mutation->fd = mutation->parent = -1;
}

// Revalidate the descriptor, directory entry, and the current parent path. A
// pathname swap never redirects backup, mutation, or rollback to the new inode.
static BOOL wq_mutation_current(NSString *path, WQMutation *mutation, BOOL version, NSString **errorText)
{
    struct stat current, entry, parent, currentParent;
    int checkParent = WQOpenDirectoryNoLinksFlags(path.stringByDeletingLastPathComponent, O_SEARCH);
    BOOL ok = checkParent >= 0 && fstat(checkParent, &currentParent) == 0 &&
        fstat(mutation->parent, &parent) == 0 && WQSameObject(&parent, &currentParent) &&
        fstat(mutation->fd, &current) == 0 && S_ISREG(current.st_mode) &&
        fstatat(mutation->parent, path.lastPathComponent.fileSystemRepresentation, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISREG(entry.st_mode) && WQSameObject(&entry, &current) && WQSameObject(&current, &mutation->before);
    if (checkParent >= 0) close(checkParent);
    if (ok && version) ok = [wq_version_for_stat(&current) isEqualToDictionary:wq_version_for_stat(&mutation->before)];
    return ok ? YES : wq_changed(errorText);
}

static BOOL wq_mutation_open(NSString *path, NSDictionary *expected, WQMutation *mutation, int flags, NSString **errorText)
{
    *mutation = (WQMutation){ .fd = -1, .parent = -1 };
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path))) { if (errorText) *errorText = @"Invalid file path"; return NO; }
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = @"Backup storage cannot be overwritten or deleted through the file browser.";
        return NO;
    }
    NSString *parent = path.stringByDeletingLastPathComponent;
    mutation->parent = WQOpenDirectoryNoLinksFlags(parent, O_SEARCH);
    if (mutation->parent < 0 && wq_is_denied(errno) && wq_grant(parent)) mutation->parent = WQOpenDirectoryNoLinksFlags(parent, O_SEARCH);
    if (mutation->parent >= 0) {
        mutation->fd = WQOpenRegularAt(mutation->parent, path.lastPathComponent.fileSystemRepresentation, flags, 0);
        if (mutation->fd < 0 && wq_is_denied(errno) && wq_grant(path))
            mutation->fd = WQOpenRegularAt(mutation->parent, path.lastPathComponent.fileSystemRepresentation, flags, 0);
    }
    if (mutation->fd < 0) { if (errorText) *errorText = wq_errno(errno); wq_mutation_close(mutation); return NO; }
    if (flock(mutation->fd, LOCK_EX | LOCK_NB) != 0) {
        int err = errno;
        // Some providers do not implement locks. Keep descriptor/version checks;
        // this is advisory serialization, not atomicity against other writers.
        if (err != ENOTSUP && err != EOPNOTSUPP && err != ENOSYS) {
            if (errorText) *errorText = wq_errno(err);
            wq_mutation_close(mutation); return NO;
        }
        wq_log(@"advisory locking unsupported: %@", path);
    }
    if (fstat(mutation->fd, &mutation->before) != 0 ||
        (expected && ![wq_version_for_stat(&mutation->before) isEqualToDictionary:expected]) ||
        !wq_mutation_current(path, mutation, YES, errorText)) {
        wq_changed(errorText); wq_mutation_close(mutation); return NO;
    }
    WQ_MUTATION_HOOK(@"verified", path);
    return YES;
}

static BOOL wq_mutation_backup(NSString *path, WQMutation *mutation, NSString **backup, NSString **errorText)
{
    if (!wq_mutation_current(path, mutation, YES, errorText)) return NO;
    NSString *backupError = nil;
    if (!wq_backup_fd(path, mutation->fd, backup, &backupError)) {
        if (errorText) *errorText = [NSString stringWithFormat:@"Backup of the current file failed, nothing was written: %@",
                                     backupError ?: @"unknown error"];
        return NO;
    }
    WQ_MUTATION_HOOK(@"backedUp", path);
    return wq_mutation_current(path, mutation, YES, errorText);
}

static BOOL wq_restore_backup_fd(WQMutation *mutation, NSString *backup, NSString **errorText)
{
    int in = WQOpenRegularAt(AT_FDCWD, backup.fileSystemRepresentation, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    // This is still the original, locked descriptor, never a reopened pathname.
    BOOL ok = lseek(mutation->fd, 0, SEEK_SET) >= 0 && ftruncate(mutation->fd, 0) == 0 &&
        wq_stream(in, mutation->fd, errorText);
    close(in);
    return ok;
}

static BOOL wq_pread_exact(int fd, void *buffer, size_t length, off_t offset)
{
    size_t done = 0;
    while (done < length) {
        ssize_t n = pread(fd, (uint8_t *)buffer + done, length - done, offset + (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return NO; }
        done += (size_t)n;
    }
    return YES;
}

// Compare a complete intended document, or the complete backup with patches
// overlaid in write order. Buffers stay bounded even for a very large hex file.
static NSDictionary *wq_verified_saved_version(WQMutation *mutation, NSData *data,
                                               NSDictionary<NSNumber *, NSData *> *runs)
{
    struct stat before, after;
    if (fstat(mutation->fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size < 0) return nil;
    uint8_t expected[65536], actual[65536];
    BOOL ok = YES;
    if (data) {
        if ((unsigned long long)before.st_size != data.length) return nil;
        for (unsigned long long offset = 0; offset < data.length && ok; ) {
            size_t count = (size_t)MIN((unsigned long long)sizeof(expected), (unsigned long long)data.length - offset);
            memcpy(expected, (const uint8_t *)data.bytes + (NSUInteger)offset, count);
            ok = wq_pread_exact(mutation->fd, actual, count, (off_t)offset) &&
                 memcmp(expected, actual, count) == 0;
            offset += count;
        }
    } else {
        // A patch leaves every unedited byte untouched. The descriptor was
        // pinned and version-checked; verifying the changed runs is sufficient
        // and avoids reading the entire file for a one-byte edit.
        if (!runs || (unsigned long long)before.st_size != (unsigned long long)mutation->before.st_size) return nil;
        for (NSNumber *key in runs) {
            NSData *run = runs[key];
            unsigned long long start = key.unsignedLongLongValue;
            if (!WQPatchRangeValid(start, run.length, (unsigned long long)before.st_size)) return nil;
            for (NSUInteger done = 0; done < run.length && ok; ) {
                size_t count = (size_t)MIN((NSUInteger)sizeof(expected), run.length - done);
                ok = wq_pread_exact(mutation->fd, actual, count, (off_t)(start + done)) &&
                     memcmp((const uint8_t *)run.bytes + done, actual, count) == 0;
                done += (NSUInteger)count;
            }
            if (!ok) break;
        }
    }
    if (!ok || fstat(mutation->fd, &after) != 0 ||
        ![wq_version_for_stat(&before) isEqualToDictionary:wq_version_for_stat(&after)]) return nil;
    return wq_version_for_stat(&after);
}

static BOOL wq_mutation_finish(NSString *path, WQMutation *mutation, NSString *backup, BOOL ok,
                               NSString *failure, NSString **errorText, NSDictionary **savedVersion,
                               NSData *expectedData, NSDictionary<NSNumber *, NSData *> *expectedRuns)
{
    if (savedVersion) *savedVersion = nil;
    NSDictionary *verifiedVersion = nil;
    BOOL rollbackAllowed = YES;
    if (ok && fsync(mutation->fd) != 0) { ok = NO; failure = wq_errno(errno); }
    WQ_MUTATION_HOOK(@"written", path);
    if (ok && !wq_mutation_current(path, mutation, NO, errorText)) {
        ok = NO; failure = @"The target path was replaced during writing";
    }
    if (ok && (expectedData || expectedRuns)) {
        verifiedVersion = wq_verified_saved_version(mutation, expectedData, expectedRuns);
        if (!verifiedVersion || !wq_mutation_current(path, mutation, NO, errorText)) {
            ok = NO;
            rollbackAllowed = NO; // A concurrent writer may own the newer contents.
            failure = @"Saved contents could not be verified; possible concurrent modification";
        }
    }
    if (!ok) {
        NSString *rollbackError = nil;
        BOOL restored = rollbackAllowed && backup && wq_restore_backup_fd(mutation, backup, &rollbackError);
        if (errorText) *errorText = [NSString stringWithFormat:@"%@; %@. Backup: %@", failure ?: @"Write failed",
            restored ? @"the original descriptor contents were restored" :
            (rollbackAllowed ? [@"rollback failed: " stringByAppendingString:rollbackError ?: @"unknown error"] :
             @"no rollback was attempted to avoid overwriting concurrent changes"), backup ?: @"none"];
    }
    // Rollback must finish before close releases the lock. A close failure has
    // no safe reopen/rollback path; retain the durable backup and report it.
    if (close(mutation->fd) != 0 && ok) {
        ok = NO;
        if (errorText) *errorText = [NSString stringWithFormat:@"Close failed: %@. Backup: %@", wq_errno(errno), backup];
    }
    mutation->fd = -1;
    wq_mutation_close(mutation);
    if (ok && savedVersion) *savedVersion = verifiedVersion;
    return ok;
}

NSArray<NSString *> *wq_list(NSString *dir, NSString **errorText)
{
    NSError *error = nil;
    NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
    if (!items && wq_grant(dir)) items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&error];
    if (!items && errorText) *errorText = error.localizedDescription ?: @"Cannot list this folder";
    return items;
}

static int wq_open(NSString *path, int flags, mode_t mode)
{
    if (flags & O_TRUNC) { errno = EINVAL; return -1; }
    int fd = WQOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
    if (fd >= 0 || !wq_is_denied(errno)) return fd;
    // The file's own folder first, then the file itself.
    if (wq_grant(path.stringByDeletingLastPathComponent)) {
        fd = WQOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
        if (fd >= 0 || !wq_is_denied(errno)) return fd;
    }
    if (!(flags & O_CREAT) && wq_grant(path)) fd = WQOpenRegularAt(AT_FDCWD, path.fileSystemRepresentation, flags, mode);
    if (fd < 0) {
        // Say why: a sandbox refusal (EPERM) and plain Unix permissions
        // (EACCES: owner/mode don't allow it) need different fixes.
        int err = errno;
        struct stat st;
        BOOL have = lstat(path.fileSystemRepresentation, &st) == 0;
        wq_log(@"open %@ for %@ -> %@; file uid %d mode %o, we are uid %d", path,
               (flags & O_ACCMODE) == O_RDONLY ? @"reading" : @"writing", wq_errno(err),
               have ? (int)st.st_uid : -1, have ? (int)(st.st_mode & 07777) : 0, (int)getuid());
        errno = err;
    }
    return fd;
}

NSData *wq_read(NSString *path, NSUInteger maxBytes, NSString **errorText)
{
    int fd = wq_open(path, O_RDONLY, 0);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        return nil;
    }
    NSMutableData *data = [NSMutableData new];
    uint8_t buf[65536];
    for (;;) {
        size_t want = sizeof(buf);
        if (maxBytes && data.length + want > maxBytes) want = maxBytes - data.length;
        if (want == 0) break;
        ssize_t n = read(fd, buf, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errorText) *errorText = wq_errno(errno);
            close(fd);
            return nil;
        }
        if (n == 0) break;
        [data appendBytes:buf length:(NSUInteger)n];
    }
    close(fd);
    return data;
}

static BOOL wq_write_all(int fd, NSData *data)
{
    const uint8_t *p = data.bytes;
    NSUInteger left = data.length;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) { errno = EIO; return NO; }
        p += n;
        left -= (NSUInteger)n;
    }
    return YES;
}

// Writes, then flushes and closes, reporting the first failure of the three.
static BOOL wq_finish_fd(int fd, BOOL ok, int *err)
{
    if (ok && fsync(fd) != 0) { ok = NO; *err = errno; }
    if (close(fd) != 0 && ok) { ok = NO; *err = errno; }
    return ok;
}

static BOOL wq_write_checked(NSString *path, NSData *data, NSDictionary *expected,
                             NSDictionary **savedVersion, BOOL verify, NSString **errorText)
{
    if (savedVersion) *savedVersion = nil;
    WQMutation mutation;
    if (!wq_mutation_open(path, expected, &mutation, O_RDWR, errorText)) return NO;
    NSString *backup = nil;
    if (!wq_mutation_backup(path, &mutation, &backup, errorText)) { wq_mutation_close(&mutation); return NO; }
    BOOL ok = lseek(mutation.fd, 0, SEEK_SET) >= 0 && ftruncate(mutation.fd, 0) == 0 && wq_write_all(mutation.fd, data);
    NSString *failure = ok ? nil : wq_errno(errno);
    return wq_mutation_finish(path, &mutation, backup, ok, failure, errorText, savedVersion, verify ? data : nil, nil);
}

BOOL wq_write_if_unchanged_get_version(NSString *path, NSData *data, NSDictionary *expected,
                                      NSDictionary **savedVersion, NSString **errorText)
{
    return wq_write_checked(path, data, expected, savedVersion, YES, errorText);
}

BOOL wq_write_if_unchanged(NSString *path, NSData *data, NSDictionary *expected, NSString **errorText)
{
    return wq_write_checked(path, data, expected, nil, NO, errorText);
}

BOOL wq_write(NSString *path, NSData *data, NSString **errorText)
{
    return wq_write_if_unchanged(path, data, nil, errorText);
}

BOOL wq_write_from_file(NSString *path, NSString *source, NSString **errorText)
{
    int in = WQOpenRegularAt(AT_FDCWD, source.fileSystemRepresentation, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    WQMutation mutation;
    if (!wq_mutation_open(path, nil, &mutation, O_RDWR, errorText)) { close(in); return NO; }
    struct stat src;
    if (fstat(in, &src) != 0 || WQSameObject(&src, &mutation.before)) {
        if (errorText) *errorText = @"Source and destination are the same file";
        close(in); wq_mutation_close(&mutation); return NO;
    }
    NSDictionary *sourceVersion = wq_version_for_stat(&src);
    NSString *backup = nil;
    if (!wq_mutation_backup(path, &mutation, &backup, errorText)) { close(in); wq_mutation_close(&mutation); return NO; }
    WQ_STREAM_HOOK(@"ready", source);
    NSString *error = nil;
    BOOL ok = lseek(mutation.fd, 0, SEEK_SET) >= 0 && ftruncate(mutation.fd, 0) == 0 && wq_stream(in, mutation.fd, &error);
    struct stat srcAfter = {0};
    if (ok && (fstat(in, &srcAfter) != 0 ||
               ![sourceVersion isEqualToDictionary:wq_version_for_stat(&srcAfter)])) {
        ok = NO;
        error = @"The source changed while it was being copied";
    }
    if (!ok && !error) error = wq_errno(errno);
    close(in);
    return wq_mutation_finish(path, &mutation, backup, ok, error, errorText, nil, nil, nil);
}

BOOL wq_create_file_from(NSString *path, NSString *source, NSString **errorText)
{
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = @"Backup storage cannot be modified through the file browser.";
        return NO;
    }
    NSString *canonical = WQCanonicalVarPath(path);
    if (!WQAbsolutePathGrammar(canonical)) {
        if (errorText) *errorText = @"Invalid file path";
        return NO;
    }
    int in = WQOpenRegularAt(AT_FDCWD, source.fileSystemRepresentation, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) {
        if (errorText) *errorText = wq_errno(errno);
        close(in);
        return NO;
    }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    int fd = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0 && wq_is_denied(errno) && wq_grant(parentPath))
        fd = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        close(parent); close(in);
        return NO;
    }
    struct stat srcBefore = {0};
    if (fstat(in, &srcBefore) != 0) {
        close(fd); close(in); close(parent);
        unlinkat(parent, name, 0);
        if (errorText) *errorText = @"Cannot inspect the copy source";
        return NO;
    }
    NSDictionary *sourceVersion = wq_version_for_stat(&srcBefore);
    WQ_STREAM_HOOK(@"ready", source);
    NSString *error = nil;
    BOOL ok = wq_stream(in, fd, &error);
    struct stat srcAfter = {0};
    if (ok && (fstat(in, &srcAfter) != 0 ||
               ![sourceVersion isEqualToDictionary:wq_version_for_stat(&srcAfter)])) {
        ok = NO;
        error = @"The source changed while it was being copied";
    }
    close(in);
    if (close(fd) != 0 && ok) { ok = NO; error = wq_errno(errno); }
    if (ok && fsync(parent) != 0) { ok = NO; error = wq_errno(errno); }
    if (!ok) unlinkat(parent, name, 0);
    close(parent);
    wq_log(@"create: %@ from %@ -> %@", path, source.lastPathComponent, ok ? @"OK" : error);
    if (!ok && errorText) *errorText = error;
    return ok;
}

BOOL wq_copy_to_local(NSString *path, NSString *dest, NSString **errorText)
{
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path)) || !WQAbsolutePathGrammar(WQCanonicalVarPath(dest))) {
        if (errorText) *errorText = @"Invalid copy path";
        return NO;
    }
    if (wq_is_backup_storage_path(dest)) {
        if (errorText) *errorText = @"Backup storage cannot be modified through the file browser.";
        return NO;
    }
    int in = wq_open(path, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    struct stat source, destination;
    if (fstat(in, &source) != 0) { close(in); return NO; }
    // stat intentionally follows a destination alias for this identity check.
    if (stat(dest.fileSystemRepresentation, &destination) == 0 && WQSameObject(&source, &destination)) {
        close(in); if (errorText) *errorText = @"Source and destination are the same file"; return NO;
    }
    int parent = WQOpenDirectoryNoLinks(dest.stringByDeletingLastPathComponent);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); close(in); return NO; }
    NSString *stage = [@".wq-local-copy-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int out = WQOpenRegularAt(parent, stage.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (out < 0) { if (errorText) *errorText = wq_errno(errno); close(parent); close(in); return NO; }
    BOOL ok = wq_stream(in, out, errorText);
    struct stat after;
    if (ok && (fstat(in, &after) != 0 || ![wq_version_for_stat(&source) isEqualToDictionary:wq_version_for_stat(&after)])) {
        ok = NO; if (errorText) *errorText = @"The source changed while it was copied";
    }
    close(in);
    if (close(out) != 0 && ok) { ok = NO; if (errorText) *errorText = wq_errno(errno); }
    // Recheck aliases after the potentially long stream, still before replacing.
    if (ok && fstatat(parent, dest.lastPathComponent.fileSystemRepresentation, &destination, 0) == 0 && WQSameObject(&source, &destination)) {
        ok = NO; if (errorText) *errorText = @"Source and destination are the same file";
    }
    if (ok) {
        struct stat entry;
        if (fstatat(parent, dest.lastPathComponent.fileSystemRepresentation, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
            !S_ISREG(entry.st_mode) && !S_ISLNK(entry.st_mode)) {
            ok = NO; if (errorText) *errorText = @"Destination is not a regular file";
        }
    }
    if (ok && renameat(parent, stage.fileSystemRepresentation, parent, dest.lastPathComponent.fileSystemRepresentation) != 0) {
        ok = NO; if (errorText) *errorText = wq_errno(errno);
    }
    if (ok && fsync(parent) != 0) { ok = NO; if (errorText) *errorText = wq_errno(errno); }
    if (!ok) unlinkat(parent, stage.fileSystemRepresentation, 0);
    close(parent);
    return ok;
}

NSString *wq_permission_hint(NSString *path, BOOL forWriting)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return nil;
    uid_t me = getuid();
    mode_t need = forWriting ? 2 : 4;   // w / r
    BOOL allowed = st.st_uid == me ? (st.st_mode >> 6 & need) != 0
                 : (st.st_gid == getgid() ? (st.st_mode >> 3 & need) != 0 : (st.st_mode & need) != 0);
    if (allowed) return nil;
    NSString *owner = st.st_uid == 0 ? @"root" : [NSString stringWithFormat:@"uid %d", (int)st.st_uid];
    return [NSString stringWithFormat:@"This file belongs to %@ (mode %o) and only its owner may %@ it. "
            "WQ Files reaches the folder, but runs as mobile (uid %d), so no app can %@ this file.",
            owner, st.st_mode & 07777, forWriting ? @"change" : @"read", (int)me, forWriting ? @"change" : @"open"];
}

NSData *wq_read_range(NSString *path, unsigned long long offset, NSUInteger length, NSString **errorText)
{
    int fd = wq_open(path, O_RDONLY, 0);
    if (fd < 0) { if (errorText) *errorText = wq_errno(errno); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:length];
    NSUInteger got = 0;
    while (got < length) {
        ssize_t n = pread(fd, (uint8_t *)data.mutableBytes + got, length - got, (off_t)(offset + got));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { if (errorText) *errorText = wq_errno(errno); close(fd); return nil; }
        if (n == 0) break;
        got += (NSUInteger)n;
    }
    close(fd);
    data.length = got;
    return data;
}

static BOOL wq_patch_checked(NSString *path, NSDictionary<NSNumber *, NSData *> *runs,
                             NSDictionary *expected, NSDictionary **savedVersion, BOOL verify, NSString **errorText)
{
    if (savedVersion) *savedVersion = nil;
    WQMutation mutation;
    if (!wq_mutation_open(path, expected, &mutation, O_RDWR, errorText)) return NO;
    unsigned long long size = (unsigned long long)mutation.before.st_size;
    for (NSNumber *off in runs) {
        if (!WQPatchRangeValid(off.unsignedLongLongValue, runs[off].length, size)) {
            if (errorText) *errorText = @"A change lies past the end of the file";
            wq_mutation_close(&mutation); return NO;
        }
    }
    NSString *backup = nil;
    if (!wq_mutation_backup(path, &mutation, &backup, errorText)) { wq_mutation_close(&mutation); return NO; }
    BOOL ok = YES;
    int err = 0;
    for (NSNumber *off in [runs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *run = runs[off];
        for (NSUInteger done = 0; done < run.length; ) {
            ssize_t n = pwrite(mutation.fd, (const uint8_t *)run.bytes + done, run.length - done, (off_t)(off.unsignedLongLongValue + done));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ok = NO; err = n == 0 ? EIO : errno; break; }
            done += (NSUInteger)n;
        }
        if (!ok) break;
    }
    return wq_mutation_finish(path, &mutation, backup, ok, ok ? nil : wq_errno(err), errorText,
                              savedVersion, nil, verify ? runs : nil);
}

BOOL wq_patch_if_unchanged_get_version(NSString *path, NSDictionary<NSNumber *, NSData *> *runs,
                                      NSDictionary *expected, NSDictionary **savedVersion, NSString **errorText)
{
    return wq_patch_checked(path, runs, expected, savedVersion, YES, errorText);
}

BOOL wq_patch_if_unchanged(NSString *path, NSDictionary<NSNumber *, NSData *> *runs,
                           NSDictionary *expected, NSString **errorText)
{
    return wq_patch_checked(path, runs, expected, nil, NO, errorText);
}

BOOL wq_patch(NSString *path, NSDictionary<NSNumber *, NSData *> *runs, NSString **errorText)
{
    return wq_patch_if_unchanged(path, runs, nil, errorText);
}

BOOL wq_backup_unit_deletable(NSString *path)
{
    NSString *canonical = WQCanonicalVarPath(path);
    if (!WQAbsolutePathGrammar(canonical) || [canonical.lastPathComponent hasPrefix:@"."]) return NO;
    NSString *parentPath = canonical.stringByDeletingLastPathComponent;
    NSString *grandparentPath = parentPath.stringByDeletingLastPathComponent;
    NSString *fileRoot = WQCanonicalVarPath(wq_backup_root());
    NSString *appRoot = WQCanonicalVarPath(wq_app_backup_root());
    if (fileRoot.length &&
        [canonical hasPrefix:[fileRoot stringByAppendingString:@"/"]] &&
        [parentPath isEqualToString:fileRoot]) return YES;
    if (appRoot.length &&
        [canonical hasPrefix:[appRoot stringByAppendingString:@"/"]] &&
        ([parentPath isEqualToString:appRoot] || [grandparentPath isEqualToString:appRoot])) return YES;
    return NO;
}

BOOL wq_delete_backup(NSString *path, NSString **errorText)
{
    if (!wq_backup_unit_deletable(path)) {
        if (errorText) *errorText = @"Only a complete backup unit can be deleted here.";
        return NO;
    }
    NSString *canonical = WQCanonicalVarPath(path);
    NSString *parentPath = canonical.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    const char *name = canonical.lastPathComponent.fileSystemRepresentation;
    struct stat st;
    if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errorText) *errorText = wq_errno(errno);
        close(parent);
        return NO;
    }
    int rc;
    if (S_ISDIR(st.st_mode)) {
        unsigned long long ignored = 0;
        if (!wq_purge_contents_cancellable(canonical, &ignored, nil)) {
            if (errorText) *errorText = @"Could not remove everything inside the backup.";
            close(parent);
            return NO;
        }
        rc = unlinkat(parent, name, AT_REMOVEDIR);
    } else {
        rc = unlinkat(parent, name, 0);
    }
    int err = errno;
    close(parent);
    wq_log(@"delete backup: %@ -> %@", path, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = wq_errno(err);
    return rc == 0;
}

static int wq_open_directory_flags(NSString *path, int flags)
{
    int fd = WQOpenDirectoryNoLinksFlags(path, flags);
    if (fd < 0 && wq_is_denied(errno) && wq_grant(path)) fd = WQOpenDirectoryNoLinksFlags(path, flags);
    return fd;
}

static int wq_open_directory(NSString *path)
{
    return wq_open_directory_flags(path, O_RDONLY);
}

BOOL wq_create_file(NSString *path, NSData *data, NSString **errorText)
{
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = @"Backup storage cannot be modified through the file browser.";
        return NO;
    }
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path))) {
        if (errorText) *errorText = @"Invalid file path";
        return NO;
    }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    int fd = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0 && wq_is_denied(errno) && wq_grant(parentPath))
        fd = WQOpenRegularAt(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        close(parent);
        return NO;
    }
    BOOL ok = wq_write_all(fd, data);
    int err = errno;
    ok = wq_finish_fd(fd, ok, &err);
    if (ok && fsync(parent) != 0) { ok = NO; err = errno; }
    if (!ok) unlinkat(parent, name, 0);
    close(parent);
    wq_log(@"create: %@ (%lu bytes) -> %@", path, (unsigned long)data.length, ok ? @"OK" : wq_errno(err));
    if (!ok && errorText) *errorText = wq_errno(err);
    return ok;
}

BOOL wq_create_dir(NSString *path, NSString **errorText)
{
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = @"Backup storage cannot be modified through the file browser.";
        return NO;
    }
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path))) {
        if (errorText) *errorText = @"Invalid folder path";
        return NO;
    }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    int rc = mkdirat(parent, name, 0755);
    if (rc != 0 && wq_is_denied(errno) && wq_grant(parentPath))
        rc = mkdirat(parent, name, 0755);
    int err = errno;
    if (rc == 0 && fsync(parent) != 0) { rc = -1; err = errno; }
    close(parent);
    wq_log(@"mkdir: %@ -> %@", path, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = wq_errno(err);
    return rc == 0;
}

BOOL wq_delete(NSString *path, NSString **errorText)
{
    if (wq_is_backup_storage_path(path)) {
        if (errorText) *errorText = @"Backup storage cannot be overwritten or deleted through the file browser.";
        return NO;
    }
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path))) {
        if (errorText) *errorText = @"Invalid file path";
        return NO;
    }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    const char *name = path.lastPathComponent.fileSystemRepresentation;
    struct stat st;
    if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) != 0 &&
        !(wq_is_denied(errno) && wq_grant(parentPath) &&
          fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0)) {
        if (errorText) *errorText = errno == ENOENT ? @"Not found" : wq_errno(errno);
        close(parent);
        return NO;
    }
    if (S_ISREG(st.st_mode)) {
        close(parent);
        WQMutation mutation;
        if (!wq_mutation_open(path, wq_version_for_stat(&st), &mutation, O_RDONLY, errorText)) return NO;
        NSString *backup = nil;
        if (!wq_mutation_backup(path, &mutation, &backup, errorText)) { wq_mutation_close(&mutation); return NO; }
        int rc = unlinkat(mutation.parent, name, 0);
        int err = errno;
        wq_mutation_close(&mutation);
        if (rc != 0 && errorText) *errorText = wq_errno(err);
        wq_log(@"delete: %@ -> %@", path, rc == 0 ? @"OK" : wq_errno(err));
        return rc == 0;
    }
    int flags = S_ISDIR(st.st_mode) ? AT_REMOVEDIR : 0;
    int rc = unlinkat(parent, name, flags);
    if (rc != 0 && wq_is_denied(errno) && wq_grant(parentPath))
        rc = unlinkat(parent, name, flags);
    int err = errno;
    close(parent);
    wq_log(@"delete: %@ -> %@", path, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = err == ENOTEMPTY ? @"Only empty folders can be deleted" : wq_errno(err);
    return rc == 0;
}

BOOL wq_rename(NSString *path, NSString *newName, NSString **errorText)
{
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(path)) || newName.length == 0 || [newName containsString:@"/"] ||
        [newName isEqualToString:@"."] || [newName isEqualToString:@".."] || [newName rangeOfString:@"\0"].location != NSNotFound) {
        if (errorText) *errorText = @"Invalid name";
        return NO;
    }
    if (wq_is_backup_storage_path(path) ||
        wq_is_backup_storage_path([path.stringByDeletingLastPathComponent stringByAppendingPathComponent:newName])) {
        if (errorText) *errorText = @"Backup storage cannot be renamed through the file browser.";
        return NO;
    }
    NSString *parentPath = path.stringByDeletingLastPathComponent;
    int parent = wq_open_directory_flags(parentPath, O_SEARCH);
    if (parent < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    WQ_TREE_HOOK(@"renameReady", [parentPath stringByAppendingPathComponent:newName]);
    int rc = renameatx_np(parent, path.lastPathComponent.fileSystemRepresentation, parent, newName.fileSystemRepresentation, RENAME_EXCL);
    if (rc != 0 && wq_is_denied(errno) && wq_grant(parentPath))
        rc = renameatx_np(parent, path.lastPathComponent.fileSystemRepresentation, parent, newName.fileSystemRepresentation, RENAME_EXCL);
    int err = errno;
    close(parent);
    wq_log(@"rename: %@ -> %@: %@", path, newName, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = err == EEXIST ? @"An item with that name already exists" : wq_errno(err);
    return rc == 0;
}

// fsgetpath: resolve a filesystem object id to a path. Not in the public SDK.
extern ssize_t fsgetpath(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

// Highest object id in use on the volume, roughly: APFS hands out ids in
// increasing order, so a file created now gets one of the newest. Containers
// of apps installed long after setup sit far above the ids of Apple's own
// apps; a fixed limit misses them on a well-used device.
static const int64_t kWQInodeMargin = 100000;

static int64_t wq_volume_max_inode(fsid_t fsid, int64_t *probeInode)
{
    if (probeInode) *probeInode = 0;
#ifdef WQ_ACCESS_TESTING
    if (wq_test_volume_limit >= 0) return wq_test_volume_limit;
#endif
    NSArray<NSString *> *directories = @[
        NSTemporaryDirectory() ?: @"",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],
        [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] ?: @"",
    ];
    for (NSString *directory in directories) {
        if (!directory.length) continue;
        NSString *probe = [directory stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"wq-inode-%u", arc4random()]];
        int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fd < 0) {
            wq_log(@"inode probe: cannot create %@ (%@)", probe, wq_errno(errno));
            continue;
        }
        struct stat st = {0};
        struct statfs sfs = {0};
        BOOL ok = fstat(fd, &st) == 0 && fstatfs(fd, &sfs) == 0;
        int err = errno;
        close(fd);
        unlink(probe.fileSystemRepresentation);
        if (!ok) {
            wq_log(@"inode probe: cannot inspect %@ (%@)", probe, wq_errno(err));
            continue;
        }
        if (memcmp(&sfs.f_fsid, &fsid, sizeof(fsid)) != 0) {
            wq_log(@"inode probe: %@ is on a different volume", probe);
            continue;
        }
        if ((uint64_t)st.st_ino > (uint64_t)INT64_MAX - (uint64_t)kWQInodeMargin) return 0;
        if (probeInode) *probeInode = (int64_t)st.st_ino;
        return (int64_t)st.st_ino + kWQInodeMargin;
    }
    return 0;
}

// Scans object ids 1...maxInode once and collects the direct children of every
// base in `bases` (each a /private/var/... path). Uses at most 4 worker threads
// (half the cores) at utility priority: a full scan of a well-used device is
// millions of ids, and running it on every core made phones hot. Returns one
// array per base, or nil when cancelled.
static NSArray<NSMutableArray<NSString *> *> *wq_scan_children(fsid_t fsid, int64_t maxInode, NSArray<NSString *> *bases,
                                                               WQScanCancellation *cancellation,
                                                               void (^progress)(int64_t, int64_t, NSUInteger),
                                                               NSUInteger reportBase)
{
    NSUInteger baseCount = MIN(bases.count, (NSUInteger)8);
    // Heap tables: blocks can't capture C arrays.
    char **prefixes = calloc(8, sizeof(char *));
    size_t *prefixLens = calloc(8, sizeof(size_t));
    if (!prefixes || !prefixLens) { free(prefixes); free(prefixLens); return nil; }
    NSMutableArray<NSMutableArray<NSString *> *> *found = [NSMutableArray new];
    for (NSUInteger i = 0; i < baseCount; i++) {
        prefixes[i] = strdup(bases[i].fileSystemRepresentation);
        prefixLens[i] = strlen(prefixes[i]);
        [found addObject:[NSMutableArray new]];
    }
    NSLock *lock = [NSLock new];
    const int64_t chunk = 32768;
    int64_t chunks = (maxInode + chunk - 1) / chunk;
    __block int64_t nextChunk = 0, done = 0;
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    size_t workers = (size_t)MAX((NSUInteger)1, MIN((NSUInteger)4, cores / 2));
    dispatch_apply(workers, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t __unused w) {
        fsid_t id = fsid;
        char buf[1200];
        for (;;) {
            if (cancellation.isCancelled) return;
            [lock lock];
            int64_t c = nextChunk++;
            [lock unlock];
            if (c >= chunks) return;
            int64_t first = c * chunk + 1, last = MIN(first + chunk - 1, maxInode);
            NSMutableArray *local[8] = {nil};
            for (int64_t ino = first; ino <= last; ino++) {
                if ((ino & 127) == 0 && cancellation.isCancelled) return;
                ssize_t n = fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino);
                if (n <= 0) continue;
                // fsgetpath returns /private/var/...; bases are normalized the same way.
                for (NSUInteger i = 0; i < baseCount; i++) {
                    if (strncmp(buf, prefixes[i], prefixLens[i]) == 0 && buf[prefixLens[i]] == '/' &&
                        strchr(buf + prefixLens[i] + 1, '/') == NULL) {
                        if (!local[i]) local[i] = [NSMutableArray new];
                        [local[i] addObject:[NSString stringWithUTF8String:buf]];
                        break;
                    }
                }
            }
            [lock lock];
            for (NSUInteger i = 0; i < baseCount; i++) if (local[i]) [found[i] addObjectsFromArray:local[i]];
            done += last - first + 1;
            int64_t nowDone = done;
            NSUInteger count = reportBase < found.count ? found[reportBase].count : 0;
            [lock unlock];
            if (progress && !cancellation.isCancelled) progress(nowDone, maxInode, count);
        }
    });
    for (NSUInteger i = 0; i < baseCount; i++) free(prefixes[i]);
    free(prefixes);
    free(prefixLens);
    if (cancellation.isCancelled) return nil;
    for (NSMutableArray *list in found) [list sortUsingSelector:@selector(compare:)];
    return found;
}

static void wq_check_scan_completion(fsid_t fsid, int64_t probeInode, NSString *what)
{
    if (probeInode <= 0) return;
    int64_t afterProbe = 0;
    if (wq_volume_max_inode(fsid, &afterProbe) <= 0 || afterProbe <= 0) {
        // A completion probe failure must not turn a usable partial list
        // into "no apps at all". The initial bound still found what it
        // scanned; callers can refresh later.
        wq_log(@"enumerate %@: completion probe unavailable; returning the scanned subset", what);
    } else if (afterProbe > probeInode + kWQInodeMargin) {
        wq_log(@"enumerate %@: inode IDs advanced beyond the scanned bound; the list may be incomplete until refreshed", what);
    }
}

// The three container parents that can only be listed by scanning. One scan
// collects all three and is reused for a while: the Cache Cleaner alone used to
// scan the whole id range three times (apps, extensions, and the daemon scan
// that finds the app name database).
static NSArray<NSString *> *wq_shared_scan_roots(void)
{
    return @[ @"/private/var/mobile/Containers/Data/Application",
              @"/private/var/mobile/Containers/Data/PluginKitPlugin",
              @"/private/var/mobile/Containers/Data/InternalDaemon" ];
}
static const NSTimeInterval kWQSharedScanTTL = 600;
static NSLock *gSharedScanLock;
static NSObject *gSharedScanGuard;
static NSDictionary<NSString *, NSArray<NSString *> *> *gSharedScan;
static NSTimeInterval gSharedScanAt;

static void wq_shared_scan_setup(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSharedScanLock = [NSLock new]; gSharedScanGuard = [NSObject new]; });
}

void wq_enumerate_invalidate(void)
{
    wq_shared_scan_setup();
    @synchronized (gSharedScanGuard) {
        gSharedScan = nil;
        gSharedScanAt = 0;
    }
}

static NSArray<NSString *> *wq_shared_children(NSString *base, fsid_t fsid, WQScanCancellation *cancellation,
                                               void (^progress)(int64_t, int64_t, NSUInteger))
{
    wq_shared_scan_setup();
    // One scan at a time; a second caller waits and then uses its result.
    while (![gSharedScanLock lockBeforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]]) {
        if (cancellation.isCancelled) return nil;
    }
    NSArray<NSString *> *result = nil;
    @try {
        NSDictionary *cached = nil;
        @synchronized (gSharedScanGuard) {
            if (gSharedScan && NSDate.date.timeIntervalSinceReferenceDate - gSharedScanAt < kWQSharedScanTTL) cached = gSharedScan;
        }
        if (cached) {
            result = cached[base];
            if (progress) progress(1, 1, result.count);
            return result;
        }
        int64_t probeInode = 0;
        int64_t maxInode = wq_volume_max_inode(fsid, &probeInode);
        if (maxInode <= 0) {
            wq_log(@"enumerate %@: dynamic inode limit unavailable; refusing to present a fixed-range partial scan as complete", base);
            return nil;
        }
        if (maxInode > INT64_MAX - 32768) {
            wq_log(@"enumerate %@: inode bound is too large to scan safely", base);
            return nil;
        }
        NSArray<NSString *> *roots = wq_shared_scan_roots();
        NSArray *lists = wq_scan_children(fsid, maxInode, roots, cancellation, progress, [roots indexOfObject:base]);
        if (!lists) return nil;
        wq_check_scan_completion(fsid, probeInode, @"containers");
        NSMutableDictionary *scan = [NSMutableDictionary new];
        for (NSUInteger i = 0; i < roots.count; i++) scan[roots[i]] = [lists[i] copy];
        @synchronized (gSharedScanGuard) {
            gSharedScan = scan;
            gSharedScanAt = NSDate.date.timeIntervalSinceReferenceDate;
        }
        result = scan[base];
    } @finally {
        [gSharedScanLock unlock];
    }
    return result;
}

NSArray<NSString *> *wq_enumerate(NSString *dir, int64_t maxInode, WQScanCancellation *cancellation,
                                  void (^progress)(int64_t, int64_t, NSUInteger))
{
    if (cancellation.isCancelled) return nil;
    NSString *base = wq_norm(dir);  // /private/var/... form
    struct stat baseStat = {0};
    int baseError = lstat(base.fileSystemRepresentation, &baseStat);
    if (baseError == 0 && !S_ISDIR(baseStat.st_mode)) {
        wq_log(@"enumerate %@: base is not a directory", dir);
        return nil;
    }
    if (baseError != 0 && errno != EACCES && errno != EPERM) {
        wq_log(@"enumerate %@: base is missing (%@)", dir, wq_errno(errno));
        return nil;
    }
    struct statfs sfs;
    if (statfs(base.fileSystemRepresentation, &sfs) != 0) {
        // The container parent may not even be stat-able without a token. In
        // that case fall back to the data volume's fsid and let fsgetpath do
        // the work; a denied parent is not the same thing as a missing parent.
        if (statfs("/private/var/mobile", &sfs) != 0) {
            wq_log(@"enumerate %@: statfs failed (%@)", dir, wq_errno(errno));
            return nil;
        }
    }
    fsid_t fsid = sfs.f_fsid;
    BOOL dynamicBound = maxInode <= 0;
    if (dynamicBound && [wq_shared_scan_roots() containsObject:base])
        return wq_shared_children(base, fsid, cancellation, progress);
    int64_t probeInode = 0;
    if (dynamicBound) {
        maxInode = wq_volume_max_inode(fsid, &probeInode);
        if (maxInode <= 0) {
            wq_log(@"enumerate %@: dynamic inode limit unavailable; refusing to present a fixed-range partial scan as complete", dir);
            return nil;
        }
    }
    if (maxInode > INT64_MAX - 32768) {
        wq_log(@"enumerate %@: inode bound is too large to scan safely", dir);
        return nil;
    }
    NSArray *lists = wq_scan_children(fsid, maxInode, @[base], cancellation, progress, 0);
    if (!lists) return nil;
    if (dynamicBound) wq_check_scan_completion(fsid, probeInode, dir);
    return lists.firstObject;
}

BOOL wq_stat(NSString *path, struct stat *st)
{
    if (lstat(path.fileSystemRepresentation, st) == 0) return YES;
    if (!wq_is_denied(errno)) return NO;
    if (wq_grant(path.stringByDeletingLastPathComponent) && lstat(path.fileSystemRepresentation, st) == 0) return YES;
    return NO;
}

WQMeasureResult wq_measure_tree(NSString *dir, WQScanCancellation *cancellation, unsigned long long *bytes)
{
    if (cancellation.isCancelled) return WQMeasureResultCancelled;
    struct stat st = {0};
    if (!wq_stat(dir, &st)) {
        struct stat direct = {0};
        if (lstat(dir.fileSystemRepresentation, &direct) != 0 &&
            (errno == ENOENT || errno == ENOTDIR)) return WQMeasureResultMissing;
        return WQMeasureResultLimited;
    }
    if (!S_ISDIR(st.st_mode)) return WQMeasureResultLimited;
    if (![NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) wq_grant(dir);

    NSURL *root = [NSURL fileURLWithPath:dir isDirectory:YES];
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey,
                                       NSURLFileSizeKey, NSURLIsDirectoryKey];
    __block BOOL limited = NO;
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:root includingPropertiesForKeys:keys options:0
           errorHandler:^BOOL(NSURL *errorURL, NSError *error) {
        limited = YES;
        wq_log(@"measure: cannot enumerate %@ (%@)", errorURL.path, error.localizedDescription ?: @"unknown error");
        return YES;
    }];
    if (!enumerator) return WQMeasureResultLimited;

    unsigned long long total = 0;
    for (NSURL *item in enumerator) {
        if (cancellation.isCancelled) return WQMeasureResultCancelled;
        NSNumber *isLink = nil, *isRegular = nil, *size = nil;
        NSError *error = nil;
        if (![item getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:&error] ||
            ![item getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:&error]) {
            limited = YES;
            continue;
        }
        if (isLink.boolValue || !isRegular.boolValue) continue;
        if (![item getResourceValue:&size forKey:NSURLFileSizeKey error:&error]) {
            limited = YES;
            continue;
        }
        total += size.unsignedLongLongValue;
    }
    if (cancellation.isCancelled) return WQMeasureResultCancelled;
    if (bytes) *bytes = total;
    return limited ? WQMeasureResultLimited : WQMeasureResultKnown;
}

static BOOL wq_directory_current(NSString *path, int fd)
{
    int current = WQOpenDirectoryNoLinksFlags(path, O_SEARCH);
    struct stat a, b;
    BOOL ok = current >= 0 && fstat(current, &a) == 0 && fstat(fd, &b) == 0 && WQSameObject(&a, &b);
    if (current >= 0) close(current);
    return ok;
}

static BOOL wq_remove_entry(int parent, NSString *name, NSString *path, unsigned long long *freed,
                            WQScanCancellation *cancellation);

// Purge uses fd-relative removal, so the path is only a swap detector. One
// lstat is enough; reopening every ancestor for every child is needlessly
// expensive on large caches.
static BOOL wq_purge_root_matches(NSString *path, int fd)
{
    struct stat pathStat, fdStat;
    return lstat(path.fileSystemRepresentation, &pathStat) == 0 &&
           fstat(fd, &fdStat) == 0 && WQSameObject(&pathStat, &fdStat);
}

static BOOL wq_purge_fd(int fd, NSString *path, unsigned long long *freed, WQScanCancellation *cancellation)
{
    int listing = dup(fd);
    if (listing < 0) return NO;
    DIR *dir = fdopendir(listing);
    if (!dir) { close(listing); return NO; }
    BOOL ok = YES;
    for (;;) {
        if (cancellation.isCancelled) { ok = NO; break; }
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) ok = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) { ok = NO; break; }
        WQ_TREE_HOOK(@"purgeChild", path);
        // Fail closed on changed ancestry; all removal remains fd-relative even
        // in the final race window. Symlink children are unlinked, never followed.
        if (!wq_purge_root_matches(path, fd)) { ok = NO; break; }
        if (!wq_remove_entry(fd, name, [path stringByAppendingPathComponent:name], freed, cancellation)) ok = NO;
    }
    if (closedir(dir) != 0) ok = NO;
    return ok;
}

static BOOL wq_remove_entry(int parent, NSString *name, NSString *path, unsigned long long *freed,
                            WQScanCancellation *cancellation)
{
    if (cancellation.isCancelled) return NO;
    const char *item = name.fileSystemRepresentation;
    struct stat before, current;
    if (fstatat(parent, item, &before, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT;
    BOOL directory = S_ISDIR(before.st_mode);
    if (directory) {
        int child = openat(parent, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (child < 0 && wq_is_denied(errno) && wq_grant(path))
            child = openat(parent, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (child < 0) return NO;
        BOOL ok = fstat(child, &current) == 0 && WQSameObject(&before, &current) &&
            wq_purge_root_matches(path, child) && wq_purge_fd(child, path, freed, cancellation);
        close(child);
        if (!ok) return NO;
    }
    if (fstatat(parent, item, &current, AT_SYMLINK_NOFOLLOW) != 0 || !WQSameObject(&before, &current) ||
        (current.st_mode & S_IFMT) != (before.st_mode & S_IFMT)) return NO;
    int rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
    if (rc != 0 && wq_is_denied(errno) && wq_grant(path.stringByDeletingLastPathComponent)) {
        if (fstatat(parent, item, &current, AT_SYMLINK_NOFOLLOW) != 0 || !WQSameObject(&before, &current)) return NO;
        rc = unlinkat(parent, item, directory ? AT_REMOVEDIR : 0);
    }
    if (rc == 0 && !directory && freed) *freed += (unsigned long long)before.st_size;
    if (rc != 0) wq_log(@"purge: %@ -> %@", path, wq_errno(errno));
    return rc == 0;
}

BOOL wq_purge_contents_cancellable(NSString *dir, unsigned long long *freed, WQScanCancellation *cancellation)
{
    if (cancellation.isCancelled) return NO;
    if (!WQAbsolutePathGrammar(WQCanonicalVarPath(dir))) return NO;
    int fd = wq_open_directory(dir);
    if (fd < 0) {
        if (errno == ENOENT) return YES;
        wq_log(@"purge: %@ -> unsafe ancestry or inaccessible (%@)", dir, wq_errno(errno));
        return NO;
    }
    BOOL ok = wq_purge_fd(fd, dir, freed, cancellation);
    close(fd);
    return ok;
}

BOOL wq_purge_contents(NSString *dir, unsigned long long *freed)
{
    return wq_purge_contents_cancellable(dir, freed, nil);
}

// Flush a completed staging tree without following any links or opening special
// files. This does not claim to snapshot a concurrently changing source tree.
static BOOL wq_sync_entry(int parent, NSString *name)
{
    struct stat st;
    if (fstatat(parent, name.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW) != 0) return NO;
    if (S_ISLNK(st.st_mode)) return YES;
    if (S_ISREG(st.st_mode)) {
        int fd = WQOpenRegularAt(parent, name.fileSystemRepresentation, O_RDONLY, 0);
        if (fd < 0) return NO;
        struct stat current;
        BOOL ok = fstat(fd, &current) == 0 && WQSameObject(&st, &current) && fsync(fd) == 0;
        close(fd); return ok;
    }
    if (!S_ISDIR(st.st_mode)) { errno = EINVAL; return NO; }
    int fd = openat(parent, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NO;
    int listing = dup(fd);
    DIR *dir = listing >= 0 ? fdopendir(listing) : NULL;
    if (!dir) { if (listing >= 0) close(listing); close(fd); return NO; }
    BOOL ok = YES;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) ok = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *child = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!child || !wq_sync_entry(fd, child)) { ok = NO; break; }
    }
    if (closedir(dir) != 0) ok = NO;
    if (ok && fsync(fd) != 0) ok = NO;
    close(fd);
    return ok;
}

BOOL wq_copy_contents(NSString *srcDir, NSString *dstDir, NSString **errorText)
{
    srcDir = WQCanonicalVarPath(srcDir);
    dstDir = WQCanonicalVarPath(dstDir);
    if (!WQAbsolutePathGrammar(srcDir) || !WQAbsolutePathGrammar(dstDir) || [srcDir isEqual:dstDir] ||
        [srcDir hasPrefix:[dstDir stringByAppendingString:@"/"]] || [dstDir hasPrefix:[srcDir stringByAppendingString:@"/"]]) {
        if (errorText) *errorText = @"Source and destination trees overlap or have invalid paths";
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    int source = wq_open_directory(srcDir);
    if (source < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    int destination = WQCreateDirectoriesNoLinksMode(dstDir, 0755);
    if (destination < 0 && wq_is_denied(errno) && wq_grant(dstDir.stringByDeletingLastPathComponent))
        destination = WQCreateDirectoriesNoLinksMode(dstDir, 0755);
    struct stat srcStat, dstStat;
    if (destination < 0 || fstat(source, &srcStat) != 0 || fstat(destination, &dstStat) != 0 || WQSameObject(&srcStat, &dstStat)) {
        if (errorText) *errorText = @"Cannot safely open distinct source and destination folders";
        close(source); if (destination >= 0) close(destination); return NO;
    }
    NSError *error = nil;
    NSArray *children = [fm contentsOfDirectoryAtPath:srcDir error:&error];
    if (!children) {
        if (errorText) *errorText = error.localizedDescription ?: @"Cannot read the source folder";
        close(source); close(destination); return NO;
    }
    BOOL allOk = YES;
    NSString *firstFailure = nil;
    for (NSString *name in children) {
        if (!wq_directory_current(srcDir, source) || !wq_directory_current(dstDir, destination)) {
            allOk = NO; firstFailure = firstFailure ?: @"A copy root changed during copying"; break;
        }
        NSString *src = [srcDir stringByAppendingPathComponent:name];
        NSString *dst = [dstDir stringByAppendingPathComponent:name];
        NSString *stageName = [@".wq-copy-stage-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *stagePath = [dstDir stringByAppendingPathComponent:stageName];
        if (mkdirat(destination, stageName.fileSystemRepresentation, 0700) != 0) {
            allOk = NO; firstFailure = firstFailure ?: wq_errno(errno); continue;
        }
        int stage = openat(destination, stageName.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (stage < 0) { allOk = NO; firstFailure = firstFailure ?: wq_errno(errno); continue; }
        NSString *newPath = [stagePath stringByAppendingPathComponent:@"New"];
        WQ_TREE_HOOK(@"copyReady", src);
        NSError *copyError = nil;
        BOOL ok = wq_directory_current(stagePath, stage) && [fm copyItemAtPath:src toPath:newPath error:&copyError];
        if (!ok && wq_grant(src) && wq_directory_current(srcDir, source) && wq_directory_current(stagePath, stage)) {
            if (wq_remove_entry(stage, @"New", newPath, NULL, nil)) {
                NSError *retryError = nil;
                ok = [fm copyItemAtPath:src toPath:newPath error:&retryError];
                if (!ok) copyError = retryError ?: copyError;
            }
        }
        if (ok) ok = wq_sync_entry(stage, @"New") && fsync(stage) == 0;
        WQ_TREE_HOOK(@"copyStaged", dst);
        if (ok) ok = wq_directory_current(srcDir, source) && wq_directory_current(dstDir, destination) && wq_directory_current(stagePath, stage);
        BOOL installed = NO;
        if (ok) {
            struct stat previous;
            BOOL exists = fstatat(destination, name.fileSystemRepresentation, &previous, AT_SYMLINK_NOFOLLOW) == 0;
            if (!exists && errno != ENOENT) ok = NO;
            if (ok) {
                // Swap retains the previous destination at stage/New until the
                // copy has completed and the new namespace has been flushed.
                installed = renameatx_np(stage, "New", destination, name.fileSystemRepresentation, exists ? RENAME_SWAP : RENAME_EXCL) == 0;
                ok = installed && fsync(destination) == 0 && fsync(stage) == 0;
            }
        }
        NSString *failure = ok ? nil : copyError.localizedDescription ?: wq_errno(errno);
        // Never erase the preserved destination if installation durability failed.
        BOOL cleaned = !installed || ok;
        if (cleaned) cleaned = wq_remove_entry(stage, @"New", newPath, NULL, nil);
        close(stage);
        if (cleaned) cleaned = unlinkat(destination, stageName.fileSystemRepresentation, AT_REMOVEDIR) == 0 && fsync(destination) == 0;
        if (!ok || !cleaned) {
            allOk = NO;
            NSString *message = cleaned ? failure : [NSString stringWithFormat:@"%@; staging/recovery contents retained at %@", failure ?: wq_errno(errno), stagePath];
            firstFailure = firstFailure ?: message;
            wq_log(@"copy: %@ -> %@: %@", src, dst, message);
        }
    }
    close(source); close(destination);
    if (errorText && !allOk) *errorText = firstFailure;
    wq_log(@"copy: %@ -> %@ (%lu items) %@", srcDir, dstDir, (unsigned long)children.count, allOk ? @"OK" : @"with errors");
    return allOk;
}

// Container-manager enumeration is a second, permission-independent way to
// map a container path to its identifier. The enumeration pattern is the one
// used by terminal_worse (GPL-3.0); no part-domain traversal is involved. The UUID xattr and the root-only
// metadata plist are the fast paths; this query is the fallback for devices
// or containers where either is unavailable. Paths and identifiers stay in a
// short-lived cache because labels are requested for every row.
static NSDictionary<NSString *, NSString *> *wq_container_identifier_map(void)
{
    static NSObject *lock;
    static NSDictionary<NSString *, NSString *> *cached;
    static NSTimeInterval cachedAt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (cached && now - cachedAt < 60) return cached;

        NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary new];
        void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (mgr) {
            cq_create_fn create = (cq_create_fn)dlsym(mgr, "container_query_create");
            cq_set_u64_fn setClass = (cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
            cq_iterate_fn iterate = (cq_iterate_fn)dlsym(mgr, "container_query_iterate_results_sync");
            cq_free_fn freeQuery = (cq_free_fn)dlsym(mgr, "container_query_free");
            co_get_path_fn getPath = (co_get_path_fn)dlsym(mgr, "container_object_get_path");
            co_get_id_fn getIdentifier = (co_get_id_fn)dlsym(mgr, "container_object_get_identifier");
            if (!getIdentifier) getIdentifier = (co_get_id_fn)dlsym(mgr, "container_result_get_identifier");
            if (create && setClass && iterate && freeQuery && getPath) {
                const uint64_t classes[] = { 0, 2, 5, 7, 8, 10, 11, 13 };
                for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
                    void *query = create();
                    if (!query) continue;
                    setClass(query, classes[i]);
                    iterate(query, ^bool(void *object) {
                        if (!object) return true;
                        const char *path = getPath(object);
                        const char *ident = getIdentifier ? getIdentifier(object) : NULL;
                        if (!path || !path[0] || !ident || !ident[0]) return true;
                        NSString *p = [NSString stringWithUTF8String:path];
                        NSString *v = [NSString stringWithUTF8String:ident];
                        if (!p.length || !v.length) return true;
                        NSString *key = WQCanonicalVarPath(p);
                        if (key.length && !map[key]) map[key] = v;
                        return true;
                    });
                    freeQuery(query);
                }
            }
            dlclose(mgr);
        }
        cached = map;
        cachedAt = now;
        return cached;
    }
}

static NSString *(*gContainerLabelResolver)(NSString *path);

void wq_set_container_label_resolver(NSString *(*resolver)(NSString *path))
{
    gContainerLabelResolver = resolver;
}

NSString *wq_container_label(NSString *dir)
{
    char buf[512];
    ssize_t len = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
    if (len > 0) {
        buf[len] = 0;
        return [NSString stringWithUTF8String:buf];
    }
    // Reading the attribute can need a token on the container: ask, try again.
    if (wq_grant(dir)) {
        len = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
        if (len > 0) {
            buf[len] = 0;
            return [NSString stringWithUTF8String:buf];
        }
    }
    // Prefer the container-manager query over the metadata plist: it needs no
    // file permission and can also label containers whose plist is root-only.
    NSString *queried = wq_container_identifier_map()[WQCanonicalVarPath(dir)];
    if (queried.length) return queried;
    // The LaunchServices database maps app and extension data containers to
    // bundle ids (set by the app; this file doesn't depend on that module).
    NSString *resolved = gContainerLabelResolver ? gContainerLabelResolver(WQCanonicalVarPath(dir)) : nil;
    if (resolved.length) return resolved;
    // The metadata plist is usually root-only (mode 600); only try it when the
    // owner and mode let this app read it, so the Log isn't flooded.
    NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    if (wq_permission_hint(meta, NO)) return nil;
    NSData *data = wq_read(meta, 256 * 1024, NULL);
    if (!data) return nil;
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    id ident = [plist isKindOfClass:NSDictionary.class] ? plist[@"MCMMetadataIdentifier"] : nil;
    return [ident isKindOfClass:NSString.class] ? ident : nil;
}
