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
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/xattr.h>
#import <unistd.h>
#import <xpc/xpc.h>

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
            if ([NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:candidate]) {
                group = candidate;
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

static void wq_restore_caches(NSURL *root)
{
    NSURL *caches = [root URLByAppendingPathComponent:@"Library/Caches"];
    [NSFileManager.defaultManager removeItemAtURL:caches error:nil];
    [NSFileManager.defaultManager createDirectoryAtURL:caches withIntermediateDirectories:YES attributes:nil error:nil];
}

static int64_t wq_query(NSString *target, BOOL altFlags)
{
    NSString *group = wq_app_group();
    if (!group) return -1;
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return -1;
    NSString *caches = [root URLByAppendingPathComponent:@"Library/Caches"].path;

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
    setClass(query, 7);  // app group container
    xpc_object_t ident = xpc_string_create(group.UTF8String);
    setGroups(query, ident);
    setPart(query, 3);   // Library/Caches
    setFlags(query, altFlags ? 0x0000000800000000ULL : 0x0000008000000000ULL);

    // Our Library/Caches -> target: containermanagerd issues the token for it.
    [files removeItemAtPath:caches error:nil];
    if (![files createSymbolicLinkAtPath:caches withDestinationPath:target error:nil]) {
        freeQuery(query);
        wq_restore_caches(root);
        return -4;
    }
    void *result = single(query);
    char *token = result ? copyToken(result) : NULL;
    int64_t handle = token ? consume(token) : (result ? -6 : -5);
    if (token && handle < 0) {
        handle = -7;
    }
    if (token) free(token);
    freeQuery(query);
    wq_restore_caches(root);
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
    int64_t handle = wq_query(key, NO);
    if (handle < 0 && handle != -1 && handle != -2) {
        int64_t alt = wq_query(key, YES);
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

NSString *wq_backup_root(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Backups"];
}

static BOOL wq_is_own(NSString *path)
{
    NSString *home = wq_norm(NSHomeDirectory());
    NSString *p = wq_norm(path);
    if ([p hasPrefix:[home stringByAppendingString:@"/"]]) return YES;
    NSString *group = wq_app_group();
    NSURL *groupRoot = group ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
    return groupRoot && [p hasPrefix:[wq_norm(groupRoot.path) stringByAppendingString:@"/"]];
}

static int wq_open(NSString *path, int flags, mode_t mode);

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

// Copies a file from anywhere (access is asked for) to `dest`, which must not
// exist yet and is created exclusively. A partial copy is removed.
static BOOL wq_copy_file_out(NSString *path, NSString *dest, NSString **errorText)
{
    int in = wq_open(path, O_RDONLY, 0);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    int out = open(dest.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (out < 0) { if (errorText) *errorText = wq_errno(errno); close(in); return NO; }
    BOOL ok = wq_stream(in, out, errorText);
    close(in);
    if (close(out) != 0 && ok) { ok = NO; if (errorText) *errorText = wq_errno(errno); }
    if (!ok) unlink(dest.fileSystemRepresentation);
    return ok;
}

// Backups/<yyyyMMdd-HHmmss-SSS-n>/<original absolute path>. The stamp is
// unique per operation, so two saves in the same second never collide. Writes
// in our own container use a private temporary rollback copy instead.
static BOOL wq_backup(NSString *path, NSString **backupPath)
{
    BOOL own = wq_is_own(path);
    if (own && !backupPath) return YES;
    NSString *dest = nil;
    if (own) {
        dest = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [@"wq-rollback-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    } else {
        static NSDateFormatter *fmt;
        static int counter;
        static NSLock *lock;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            fmt = [NSDateFormatter new];
            fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            fmt.dateFormat = @"yyyyMMdd-HHmmss-SSS";
            lock = [NSLock new];
        });
        [lock lock];
        NSString *stamp = [NSString stringWithFormat:@"%@-%d", [fmt stringFromDate:NSDate.date], ++counter];
        [lock unlock];
        dest = [[wq_backup_root() stringByAppendingPathComponent:stamp] stringByAppendingPathComponent:wq_norm(path)];
    }
    NSError *dirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dest.stringByDeletingLastPathComponent
                                 withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        wq_log(@"backup: cannot create folder for %@: %@", path, dirError);
        return NO;
    }
    NSString *error = nil;
    BOOL ok = wq_copy_file_out(path, dest, &error);
    wq_log(@"backup: %@ -> %@", path, ok ? dest : [@"FAILED: " stringByAppendingString:error ?: @"?"]);
    if (ok && backupPath) *backupPath = dest;
    return ok;
}

// Restores the backup through the normal access path. This deliberately keeps
// the destination inode and metadata, just like the original in-place write.
static BOOL wq_restore_backup(NSString *path, NSString *backup, NSString **errorText)
{
    int in = open(backup.fileSystemRepresentation, O_RDONLY);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    int out = wq_open(path, O_WRONLY | O_TRUNC, 0);
    if (out < 0) { if (errorText) *errorText = wq_errno(errno); close(in); return NO; }
    BOOL ok = wq_stream(in, out, errorText);
    int saved = errno;
    close(in);
    if (close(out) != 0 && ok) { ok = NO; if (errorText) *errorText = wq_errno(errno); }
    if (!ok && errorText && !*errorText) *errorText = wq_errno(saved);
    return ok;
}

static void wq_report_write_failure(NSString *path, NSString *backup, NSString *failure, NSString **errorText)
{
    NSString *rollbackError = nil;
    BOOL restored = backup && wq_restore_backup(path, backup, &rollbackError);
    NSString *message = restored
        ? [NSString stringWithFormat:@"%@; the original contents were restored", failure]
        : [NSString stringWithFormat:@"%@; rollback %@. Backup: %@", failure,
           backup ? [@"also failed: " stringByAppendingString:rollbackError ?: @"unknown error"] : @"was unavailable",
           backup ?: @"none"];
    wq_log(@"write failure: %@ -> %@", path, message);
    if (errorText) *errorText = message;
}

static void wq_discard_temporary_backup(NSString *path, NSString *backup)
{
    if (backup && wq_is_own(path)) [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
}

NSString *wq_backup_original_path(NSString *backupPath)
{
    NSString *root = [wq_norm(wq_backup_root()) stringByAppendingString:@"/"];
    NSString *p = wq_norm(backupPath);
    if (![p hasPrefix:root]) return nil;
    NSArray *parts = [[p substringFromIndex:root.length] componentsSeparatedByString:@"/"];
    if (parts.count < 3) return nil;  // <stamp>/private/...
    return [@"/" stringByAppendingString:[[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"/"]];
}

#pragma mark - File operations

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
    int fd = open(path.fileSystemRepresentation, flags, mode);
    if (fd >= 0 || !wq_is_denied(errno)) return fd;
    // The file's own folder first, then the file itself.
    if (wq_grant(path.stringByDeletingLastPathComponent)) {
        fd = open(path.fileSystemRepresentation, flags, mode);
        if (fd >= 0 || !wq_is_denied(errno)) return fd;
    }
    if (!(flags & O_CREAT) && wq_grant(path)) fd = open(path.fileSystemRepresentation, flags, mode);
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

BOOL wq_write(NSString *path, NSData *data, NSString **errorText)
{
    NSString *backup = nil;
    if (!wq_backup(path, &backup)) {
        if (errorText) *errorText = @"Backup of the current file failed, nothing was written";
        return NO;
    }
    int fd = wq_open(path, O_WRONLY | O_TRUNC, 0);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        wq_discard_temporary_backup(path, backup);
        return NO;
    }
    BOOL ok = wq_write_all(fd, data);
    int err = errno;
    ok = wq_finish_fd(fd, ok, &err);
    wq_log(@"write: %@ (%lu bytes) -> %@", path, (unsigned long)data.length, ok ? @"OK" : wq_errno(err));
    if (!ok) wq_report_write_failure(path, backup, wq_errno(err), errorText);
    else wq_discard_temporary_backup(path, backup);
    return ok;
}

BOOL wq_write_from_file(NSString *path, NSString *source, NSString **errorText)
{
    int in = open(source.fileSystemRepresentation, O_RDONLY);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    NSString *backup = nil;
    if (!wq_backup(path, &backup)) {
        close(in);
        if (errorText) *errorText = @"Backup of the current file failed, nothing was written";
        return NO;
    }
    int fd = wq_open(path, O_WRONLY | O_TRUNC, 0);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        close(in);
        wq_discard_temporary_backup(path, backup);
        return NO;
    }
    NSString *error = nil;
    BOOL ok = wq_stream(in, fd, &error);
    close(in);
    if (close(fd) != 0 && ok) { ok = NO; error = wq_errno(errno); }
    wq_log(@"write: %@ from %@ -> %@", path, source.lastPathComponent, ok ? @"OK" : error);
    if (!ok) wq_report_write_failure(path, backup, error ?: @"Write failed", errorText);
    else wq_discard_temporary_backup(path, backup);
    return ok;
}

BOOL wq_create_file_from(NSString *path, NSString *source, NSString **errorText)
{
    int in = open(source.fileSystemRepresentation, O_RDONLY);
    if (in < 0) { if (errorText) *errorText = wq_errno(errno); return NO; }
    int fd = wq_open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) { if (errorText) *errorText = wq_errno(errno); close(in); return NO; }
    NSString *error = nil;
    BOOL ok = wq_stream(in, fd, &error);
    close(in);
    if (close(fd) != 0 && ok) { ok = NO; error = wq_errno(errno); }
    if (!ok) unlink(path.fileSystemRepresentation);
    wq_log(@"create: %@ from %@ -> %@", path, source.lastPathComponent, ok ? @"OK" : error);
    if (!ok && errorText) *errorText = error;
    return ok;
}

BOOL wq_copy_to_local(NSString *path, NSString *dest, NSString **errorText)
{
    unlink(dest.fileSystemRepresentation);
    return wq_copy_file_out(path, dest, errorText);
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

BOOL wq_patch(NSString *path, NSDictionary<NSNumber *, NSData *> *runs, NSString **errorText)
{
    struct stat before;
    if (!wq_stat(path, &before) || !S_ISREG(before.st_mode)) {
        if (errorText) *errorText = @"Not a regular file";
        return NO;
    }
    unsigned long long size = (unsigned long long)before.st_size;
    for (NSNumber *off in runs) {
        unsigned long long start = off.unsignedLongLongValue;
        if (start > size || runs[off].length > size - start) {
            if (errorText) *errorText = @"A change lies past the end of the file";
            return NO;
        }
    }
    NSString *backup = nil;
    if (!wq_backup(path, &backup)) {
        if (errorText) *errorText = @"Backup of the current file failed, nothing was written";
        return NO;
    }
    int fd = wq_open(path, O_WRONLY, 0);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        wq_discard_temporary_backup(path, backup);
        return NO;
    }
    BOOL ok = YES;
    int err = 0;
    NSUInteger bytes = 0;
    for (NSNumber *off in [runs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *run = runs[off];
        for (NSUInteger done = 0; ok && done < run.length; ) {
            ssize_t n = pwrite(fd, (const uint8_t *)run.bytes + done, run.length - done, (off_t)(off.unsignedLongLongValue + done));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ok = NO; err = n == 0 ? EIO : errno; break; }
            done += (NSUInteger)n;
        }
        if (!ok) break;
        bytes += run.length;
    }
    ok = wq_finish_fd(fd, ok, &err);
    wq_log(@"patch: %@ (%lu bytes in %lu runs) -> %@", path, (unsigned long)bytes, (unsigned long)runs.count,
           ok ? @"OK" : wq_errno(err));
    if (!ok) wq_report_write_failure(path, backup, wq_errno(err), errorText);
    else wq_discard_temporary_backup(path, backup);
    return ok;
}

BOOL wq_create_file(NSString *path, NSData *data, NSString **errorText)
{
    int fd = wq_open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        if (errorText) *errorText = wq_errno(errno);
        return NO;
    }
    BOOL ok = wq_write_all(fd, data);
    int err = errno;
    ok = wq_finish_fd(fd, ok, &err);
    if (!ok) unlink(path.fileSystemRepresentation);
    wq_log(@"create: %@ (%lu bytes) -> %@", path, (unsigned long)data.length, ok ? @"OK" : wq_errno(err));
    if (!ok && errorText) *errorText = wq_errno(err);
    return ok;
}

BOOL wq_create_dir(NSString *path, NSString **errorText)
{
    int rc = mkdir(path.fileSystemRepresentation, 0755);
    if (rc != 0 && wq_is_denied(errno) && wq_grant(path.stringByDeletingLastPathComponent))
        rc = mkdir(path.fileSystemRepresentation, 0755);
    int err = errno;
    wq_log(@"mkdir: %@ -> %@", path, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = wq_errno(err);
    return rc == 0;
}

BOOL wq_delete(NSString *path, NSString **errorText)
{
    struct stat st;
    if (!wq_stat(path, &st)) {
        if (errorText) *errorText = @"Not found";
        return NO;
    }
    int rc;
    if (S_ISDIR(st.st_mode)) {
        rc = rmdir(path.fileSystemRepresentation);
        if (rc != 0 && wq_is_denied(errno) && wq_grant(path.stringByDeletingLastPathComponent))
            rc = rmdir(path.fileSystemRepresentation);
    } else {
        if (S_ISREG(st.st_mode) && !wq_backup(path, NULL)) {
            if (errorText) *errorText = @"Backup failed, nothing was deleted";
            return NO;
        }
        rc = unlink(path.fileSystemRepresentation);
        if (rc != 0 && wq_is_denied(errno) && wq_grant(path.stringByDeletingLastPathComponent))
            rc = unlink(path.fileSystemRepresentation);
    }
    int err = errno;
    wq_log(@"delete: %@ -> %@", path, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = err == ENOTEMPTY ? @"Only empty folders can be deleted" : wq_errno(err);
    return rc == 0;
}

BOOL wq_rename(NSString *path, NSString *newName, NSString **errorText)
{
    if (newName.length == 0 || [newName containsString:@"/"]) {
        if (errorText) *errorText = @"Invalid name";
        return NO;
    }
    NSString *dest = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:newName];
    struct stat st;
    if (lstat(dest.fileSystemRepresentation, &st) == 0) {
        if (errorText) *errorText = @"An item with that name already exists";
        return NO;
    }
    int rc = rename(path.fileSystemRepresentation, dest.fileSystemRepresentation);
    if (rc != 0 && wq_is_denied(errno) && wq_grant(path.stringByDeletingLastPathComponent))
        rc = rename(path.fileSystemRepresentation, dest.fileSystemRepresentation);
    int err = errno;
    wq_log(@"rename: %@ -> %@: %@", path, newName, rc == 0 ? @"OK" : wq_errno(err));
    if (rc != 0 && errorText) *errorText = wq_errno(err);
    return rc == 0;
}

// fsgetpath: resolve a filesystem object id to a path. Not in the public SDK.
extern ssize_t fsgetpath(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

// Highest object id in use on the volume, roughly: APFS hands out ids in
// increasing order, so a file created now gets one of the newest. Containers
// of apps installed long after setup sit far above the ids of Apple's own
// apps; a fixed limit misses them on a well-used device.
static int64_t wq_volume_max_inode(fsid_t fsid)
{
    NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"wq-inode-%u", arc4random()]];
    int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fd < 0) {
        wq_log(@"inode probe: cannot create %@ (%@)", probe, wq_errno(errno));
        return 0;
    }
    struct stat st = {0};
    struct statfs sfs = {0};
    BOOL ok = fstat(fd, &st) == 0 && fstatfs(fd, &sfs) == 0;
    int err = errno;
    close(fd);
    unlink(probe.fileSystemRepresentation);
    if (!ok) {
        wq_log(@"inode probe: cannot inspect %@ (%@)", probe, wq_errno(err));
        return 0;
    }
    if (memcmp(&sfs.f_fsid, &fsid, sizeof(fsid)) != 0) {
        wq_log(@"inode probe: %@ is on a different volume", probe);
        return 0;
    }
    return (int64_t)st.st_ino + 100000;
}

NSArray<NSString *> *wq_enumerate(NSString *dir, int64_t maxInode,
                                  void (^progress)(int64_t, int64_t, NSUInteger))
{
    NSString *base = wq_norm(dir);  // /private/var/... form
    struct statfs sfs;
    if (statfs(base.fileSystemRepresentation, &sfs) != 0 &&
        statfs("/private/var/mobile", &sfs) != 0) {
        wq_log(@"enumerate %@: statfs failed (%@)", dir, wq_errno(errno));
        return nil;
    }
    fsid_t fsid = sfs.f_fsid;
    if (maxInode <= 0) {
        maxInode = wq_volume_max_inode(fsid);
        if (maxInode <= 0) {
            maxInode = 4000000;
            wq_log(@"enumerate %@: dynamic inode limit unavailable; falling back to %lld", dir, (long long)maxInode);
        }
    }
    wq_log(@"enumerate %@: scanning object ids 1...%lld", dir, (long long)maxInode);
    const char *prefix = base.fileSystemRepresentation;
    size_t prefixLen = strlen(prefix);
    NSMutableArray<NSString *> *found = [NSMutableArray new];
    NSLock *lock = [NSLock new];

    // fsgetpath is a plain syscall; scan the id range in chunks on all cores.
    const int64_t chunk = 32768;
    size_t chunks = (size_t)((maxInode + chunk - 1) / chunk);
    __block int64_t done = 0;
    dispatch_apply(chunks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t c) {
        int64_t first = (int64_t)c * chunk + 1, last = MIN(first + chunk - 1, maxInode);
        NSMutableArray *local = [NSMutableArray new];
        fsid_t id = fsid;
        char buf[1200];
        for (int64_t ino = first; ino <= last; ino++) {
            ssize_t n = fsgetpath(buf, sizeof(buf), &id, (uint64_t)ino);
            // fsgetpath returns /private/var/...; base is normalized the same way.
            if (n > 0 && strncmp(buf, prefix, prefixLen) == 0 && buf[prefixLen] == '/' &&
                strchr(buf + prefixLen + 1, '/') == NULL)
                [local addObject:[NSString stringWithUTF8String:buf]];
        }
        [lock lock];
        [found addObjectsFromArray:local];
        done += last - first + 1;
        int64_t nowDone = done;
        NSUInteger count = found.count;
        [lock unlock];
        if (progress) progress(nowDone, maxInode, count);
    });
    [found sortUsingSelector:@selector(compare:)];
    wq_log(@"enumerate %@: found %lu direct child container(s)", dir, (unsigned long)found.count);
    return found;
}

BOOL wq_stat(NSString *path, struct stat *st)
{
    if (lstat(path.fileSystemRepresentation, st) == 0) return YES;
    if (!wq_is_denied(errno)) return NO;
    if (wq_grant(path.stringByDeletingLastPathComponent) && lstat(path.fileSystemRepresentation, st) == 0) return YES;
    return NO;
}

unsigned long long wq_dir_size(NSString *dir)
{
    struct stat st;
    if (!wq_stat(dir, &st)) return 0;
    if (!S_ISDIR(st.st_mode)) return (unsigned long long)st.st_size;
    // Ask for a token only when the folder can't already be read (a grant on
    // the container covers its subfolders).
    if (![NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) wq_grant(dir);
    unsigned long long total = 0;
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:dir];
    for (NSString *__unused rel in en) {
        NSDictionary *attrs = en.fileAttributes;
        if ([attrs.fileType isEqualToString:NSFileTypeRegular]) total += attrs.fileSize;
    }
    return total;
}

BOOL wq_purge_contents(NSString *dir, unsigned long long *freed)
{
    struct stat st;
    if (lstat(dir.fileSystemRepresentation, &st) != 0) {
        if (errno == ENOENT) return YES;  // not there: nothing to remove
        if (!wq_stat(dir, &st)) {
            wq_log(@"purge: %@ -> cannot access (%@)", dir, wq_errno(errno));
            return NO;
        }
    }
    if (!S_ISDIR(st.st_mode)) {
        wq_log(@"purge: %@ -> not a folder", dir);
        return NO;
    }
    NSString *listError = nil;
    NSArray *children = wq_list(dir, &listError);
    if (!children) {
        wq_log(@"purge: %@ -> cannot list (%@)", dir, listError);
        return NO;
    }
    BOOL allOk = YES;
    for (NSString *name in children) {
        NSString *child = [dir stringByAppendingPathComponent:name];
        unsigned long long before = wq_dir_size(child);
        NSError *error = nil;
        BOOL ok = [NSFileManager.defaultManager removeItemAtPath:child error:&error];
        // Retry once with a token on the child's own folder (deep subtree).
        if (!ok && wq_grant(child)) ok = [NSFileManager.defaultManager removeItemAtPath:child error:nil];
        if (ok) {
            if (freed) *freed += before;
        } else {
            allOk = NO;
            wq_log(@"purge: %@ -> %@", child, error.localizedDescription ?: @"failed");
        }
    }
    return allOk;
}

BOOL wq_copy_contents(NSString *srcDir, NSString *dstDir, NSString **errorText)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!wq_is_own(srcDir)) wq_grant(srcDir);
    if (!wq_is_own(dstDir)) wq_grant(dstDir);
    [fm createDirectoryAtPath:dstDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *error = nil;
    NSArray *children = [fm contentsOfDirectoryAtPath:srcDir error:&error];
    if (!children) {
        if (errorText) *errorText = error.localizedDescription ?: @"Cannot read the source folder";
        return NO;
    }
    BOOL allOk = YES;
    for (NSString *name in children) {
        NSString *src = [srcDir stringByAppendingPathComponent:name];
        NSString *dst = [dstDir stringByAppendingPathComponent:name];
        [fm removeItemAtPath:dst error:nil];
        NSError *copyError = nil;
        BOOL ok = [fm copyItemAtPath:src toPath:dst error:&copyError];
        if (!ok && wq_grant(src)) ok = [fm copyItemAtPath:src toPath:dst error:&copyError];
        if (!ok) {
            allOk = NO;
            wq_log(@"copy: %@ -> %@: %@", src, dst, copyError.localizedDescription);
            if (errorText && !*errorText) *errorText = copyError.localizedDescription;
        }
    }
    wq_log(@"copy: %@ -> %@ (%lu items) %@", srcDir, dstDir, (unsigned long)children.count, allOk ? @"OK" : @"with errors");
    return allOk;
}

#pragma mark - App names from the LaunchServices database

// LaunchServices' own API refuses this app on 27.x (OSStatus -54) and the app
// bundles cannot be opened, but lsd keeps its database (CSStore2, magic
// "bdsl") in an Internal Daemon container that we can read. In it, Bundle
// records are 0x250 bytes long, preceded by [u32][u32 0x250]: +0x0c bundle
// id, +0x6c bundle name, +0x74 display name, each a string reference
// (string id << 2). Strings are stored as [u32 id][u32 length][UTF-8][NUL].
// Names that exist only in localized form (most Apple apps) are not decoded;
// the built-in table below covers those.

static NSString *const kWQLSStoreKey = @"WQLaunchServicesStore";

static NSString *wq_find_ls_store(void)
{
    struct stat st;
    NSString *cached = [NSUserDefaults.standardUserDefaults stringForKey:kWQLSStoreKey];
    if (cached && wq_stat(cached, &st)) return cached;
    NSArray *daemons = wq_enumerate(@"/private/var/mobile/Containers/Data/InternalDaemon", 0, nil);
    for (NSString *c in daemons) {
        NSString *caches = [c stringByAppendingPathComponent:@"Library/Caches"];
        for (NSString *k in wq_list(caches, NULL)) {
            if (![k hasPrefix:@"com.apple.LaunchServices-"] || ![k hasSuffix:@".csstore"]) continue;
            NSString *path = [caches stringByAppendingPathComponent:k];
            [NSUserDefaults.standardUserDefaults setObject:path forKey:kWQLSStoreKey];
            return path;
        }
    }
    return nil;
}

static uint32_t wq_rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static NSString *wq_cs_string(const uint8_t *b, size_t n, size_t o)
{
    uint32_t len = wq_rd32(b + o + 4);
    if (len == 0 || len >= 0x800 || o + 8 + len >= n || b[o + 8 + len] != 0) return nil;
    if (memchr(b + o + 8, 0, len)) return nil;
    NSString *s = [[NSString alloc] initWithBytes:b + o + 8 length:len encoding:NSUTF8StringEncoding];
    if (!s || [s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return s;
}

static BOOL wq_looks_like_bundle_id(NSString *s)
{
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    });
    return s.length > 2 && [s containsString:@"."] && ![s hasPrefix:@"."]
        && [s rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static BOOL wq_good_name(NSString *s) { return s.length && ![s hasPrefix:@"/"] && ![s containsString:@".app/"]; }

static NSDictionary *gLSDisplay, *gLSBundleName;

static void wq_parse_ls_store(NSData *data)
{
    const uint8_t *b = data.bytes;
    size_t n = data.length;
    if (n < 0x1000 || memcmp(b, "bdsl", 4) != 0) { wq_log(@"names: not a LaunchServices store"); return; }
    NSRange heapRange = [data rangeOfData:[NSData dataWithBytes:"<string>" length:8] options:0 range:NSMakeRange(0, n)];
    size_t heap = heapRange.location == NSNotFound ? 0 : heapRange.location;

    // Pass 1: Bundle records, and which string ids they need.
    const size_t kIDs = 0x1000000;
    uint8_t *need = calloc(kIDs / 8, 1), *inHeap = calloc(kIDs / 8, 1);
    NSMutableData *recs = [NSMutableData new];  // triples of refs
    for (size_t o = 0; o + 8 + 0x250 <= n; o += 4) {
        if (wq_rd32(b + o + 4) != 0x250) continue;
        const uint8_t *u = b + o + 8;
        uint32_t r[3] = { wq_rd32(u + 0x0c), wq_rd32(u + 0x6c), wq_rd32(u + 0x74) };
        if (!r[0] || (r[0] & 3) || (r[0] >> 2) >= kIDs) continue;
        [recs appendBytes:r length:sizeof(r)];
        for (int i = 0; i < 3; i++)
            if (r[i] && !(r[i] & 3) && (r[i] >> 2) < kIDs) need[(r[i] >> 2) / 8] |= 1 << ((r[i] >> 2) % 8);
    }

    // Pass 2: the strings, preferring copies inside the string table.
    NSMutableDictionary<NSNumber *, NSString *> *strings = [NSMutableDictionary new];
    for (size_t o = 0; o + 8 < n; o += 4) {
        uint32_t sid = wq_rd32(b + o);
        if (!sid || sid >= kIDs || !(need[sid / 8] & (1 << (sid % 8)))) continue;
        BOOL here = o >= heap, had = strings[@(sid)] != nil;
        if (had && (!here || (inHeap[sid / 8] & (1 << (sid % 8))))) continue;
        NSString *s = wq_cs_string(b, n, o);
        if (!s) continue;
        strings[@(sid)] = s;
        if (here) inHeap[sid / 8] |= 1 << (sid % 8);
    }
    free(need);
    free(inHeap);

    NSMutableDictionary *display = [NSMutableDictionary new], *bundleName = [NSMutableDictionary new];
    const uint32_t *r = recs.bytes;
    for (NSUInteger i = 0; i < recs.length / sizeof(uint32_t); i += 3) {
        NSString *bid = strings[@(r[i] >> 2)];
        if (!wq_looks_like_bundle_id(bid)) continue;
        NSString *nm = (r[i + 1] & 3) ? nil : strings[@(r[i + 1] >> 2)];
        NSString *dn = (r[i + 2] & 3) ? nil : strings[@(r[i + 2] >> 2)];
        if (wq_good_name(dn) && !display[bid]) display[bid] = dn;
        if (wq_good_name(nm) && !bundleName[bid]) bundleName[bid] = nm;
    }
    gLSDisplay = display;
    gLSBundleName = bundleName;
}

static void wq_load_ls_names(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = wq_find_ls_store();
        if (!path) { wq_log(@"names: LaunchServices database not found"); return; }
        NSString *err = nil;
        NSData *data = wq_read(path, 0, &err);
        if (!data) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQLSStoreKey];
            wq_log(@"names: cannot read %@: %@", path, err);
            return;
        }
        @autoreleasepool { wq_parse_ls_store(data); }
    });
}

// Apple's own apps and services: LaunchServices refuses this app on 27.x
// (OSStatus -54) and /Applications is not listable, so names come from here.
static NSDictionary<NSString *, NSString *> *wq_builtin_names(void)
{
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @"com.apple.AppStore": @"App Store", @"com.apple.mobilesafari": @"Safari", @"com.apple.weather": @"Weather",
            @"com.apple.news": @"News", @"com.apple.stocks": @"Stocks", @"com.apple.mobilemail": @"Mail",
            @"com.apple.MobileSMS": @"Messages", @"com.apple.mobilephone": @"Phone", @"com.apple.mobileslideshow": @"Photos",
            @"com.apple.camera": @"Camera", @"com.apple.mobilecal": @"Calendar", @"com.apple.mobilenotes": @"Notes",
            @"com.apple.reminders": @"Reminders", @"com.apple.Maps": @"Maps", @"com.apple.Music": @"Music",
            @"com.apple.tv": @"TV", @"com.apple.podcasts": @"Podcasts", @"com.apple.iBooks": @"Books",
            @"com.apple.Health": @"Health", @"com.apple.Passbook": @"Wallet", @"com.apple.Preferences": @"Settings",
            @"com.apple.mobiletimer": @"Clock", @"com.apple.calculator": @"Calculator", @"com.apple.compass": @"Compass",
            @"com.apple.VoiceMemos": @"Voice Memos", @"com.apple.facetime": @"FaceTime", @"com.apple.MobileAddressBook": @"Contacts",
            @"com.apple.DocumentsApp": @"Files", @"com.apple.findmy": @"Find My", @"com.apple.Home": @"Home",
            @"com.apple.shortcuts": @"Shortcuts", @"com.apple.Translate": @"Translate", @"com.apple.Fitness": @"Fitness",
            @"com.apple.Bridge": @"Watch", @"com.apple.freeform": @"Freeform", @"com.apple.journal": @"Journal",
            @"com.apple.Passwords": @"Passwords", @"com.apple.measure": @"Measure", @"com.apple.Magnifier": @"Magnifier",
            @"com.apple.tips": @"Tips", @"com.apple.siri": @"Siri", @"com.apple.games": @"Games", @"com.apple.gamecenter": @"Game Center",
            @"com.apple.Image-Playground": @"Image Playground", @"com.apple.Photos": @"Photos", @"com.apple.Keynote": @"Keynote",
            @"com.apple.Pages": @"Pages", @"com.apple.Numbers": @"Numbers", @"com.apple.mobileme.fmip1": @"Find iPhone",
            @"com.apple.store.Jolly": @"Apple Store", @"com.apple.supportapp": @"Apple Support", @"com.apple.Diagnostics": @"Diagnostics",
            @"com.apple.PosterBoard": @"Wallpaper", @"com.apple.MercuryPoster": @"Wallpaper (Mercury)",
            @"com.apple.WallpaperKit.CollectionsPoster": @"Wallpaper Collections",
            @"com.apple.PhotosUIPrivate.PhotosPosterProvider": @"Photo Wallpaper",
            @"com.apple.chrono.WidgetRenderer-Default": @"Widgets", @"com.apple.ScreenshotServicesService": @"Screenshots",
            @"com.apple.Sharing.AirDrop": @"AirDrop", @"com.apple.AppleMediaServicesUI": @"Apple Media Services",
            @"com.apple.AppleMediaServices": @"Apple Media Services", @"com.apple.ClarityCamera": @"Assistive Access Camera",
            @"com.apple.ClarityPhotos": @"Assistive Access Photos", @"com.apple.SystemVoiceAssistant": @"Voice Assistant",
            @"com.apple.ShazamEventsApp": @"Shazam", @"com.apple.ScreenTimeWidgetApplication": @"Screen Time",
            @"com.apple.CBRemoteSetup": @"Remote Setup", @"com.apple.DemoApp": @"Demo", @"com.apple.AAUIViewService": @"Apple Account",
            @"com.apple.AccountAuthenticationDialog": @"Account Sign-In", @"com.apple.StoreKitUISceneService": @"App Store Sheets",
            @"com.apple.NewDeviceOutreachApp": @"New Device Setup", @"com.apple.PDUIApp": @"Printing", @"com.apple.EventViewService": @"Events",
            @"com.apple.MXUIService": @"Media Picker", @"com.apple.ctkui": @"Smart Card", @"com.apple.InCallService": @"Call Screen",
            @"com.apple.springboard": @"SpringBoard", @"com.apple.SafariViewService": @"Safari View", @"com.apple.mobilesms.compose": @"Message Compose",
            @"com.apple.CompanionViewService": @"Companion", @"com.apple.musicrecognition": @"Music Recognition",
            @"com.apple.FontInstallViewService": @"Font Install", @"com.apple.CMViewSrvc": @"Continuity Markup",
            @"com.apple.AppleCashStickerPackHost": @"Apple Cash Stickers", @"com.apple.TVSetupUIService": @"Apple TV Setup",
            @"com.apple.HearingApp": @"Hearing", @"com.apple.CompanionSetup": @"Companion Setup",
            @"com.apple.CarPlayWallpaper": @"CarPlay Wallpaper", @"com.apple.CloudKit.ShareBear": @"iCloud Sharing",
            @"com.apple.EnhancedLogging": @"Enhanced Logging", @"com.apple.tcc.AuthorizationPromptService": @"Privacy Prompts",
            @"com.apple.WebContentFilter.remoteUI.WebContentAnalysisUI": @"Content Filter",
            @"com.apple.SystemPaperViewService": @"Quick Note", @"com.apple.HeadphoneProxService": @"Headphones",
            @"com.apple.datadetectors.DDActionsService": @"Data Detectors", @"com.apple.ServicesPaymentAngel": @"Apple Pay",
            @"com.apple.HomeCaptiveViewService": @"Wi-Fi Login", @"com.apple.DiagnosticsService": @"Diagnostics",
            @"com.apple.CarTirePressure": @"Tire Pressure", @"com.apple.FCAuthenticationUI": @"Authentication",
            @"com.apple.icloud.FindMyDevice.FindMyExtensionContainer": @"Find My",
            @"com.apple.messages.RemoteAlerts": @"Messages Alerts",
            @"com.apple.AccessoryNotifications.SourceSelection": @"Accessory Source",
            @"com.apple.printcenter": @"Print Center", @"com.apple.BarcodeScanner": @"Code Scanner",
            @"com.apple.chrono.WidgetRenderer-Snapshots": @"Widget Snapshots",
            @"com.apple.AMSEngagementViewService": @"Apple Media Services",
            @"com.apple.appManagedFeatures.Restrictions": @"Restrictions", @"com.apple.CarRadio": @"Car Radio",
            @"com.apple.PassbookUIService": @"Wallet Sheets", @"com.apple.Spotlight": @"Spotlight", @"com.apple.InputUI": @"Keyboard",
        };
    });
    return names;
}

static NSString *wq_known_name(NSString *bundleID)
{
    wq_load_ls_names();
    return gLSDisplay[bundleID] ?: wq_builtin_names()[bundleID] ?: gLSBundleName[bundleID];
}

NSString *wq_display_name(NSString *bundleID)
{
    if (!bundleID) return nil;
    NSString *name = wq_known_name(bundleID);
    if (name) return name;
    // Unknown id: use the closest parent app (com.apple.news.widget -> News).
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    for (NSInteger n = (NSInteger)parts.count - 1; n >= 2; n--) {
        NSString *prefix = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."];
        NSString *parent = wq_known_name(prefix);
        if (parent) return [NSString stringWithFormat:@"%@ \u2013 %@", parent, parts.lastObject];
    }
    return nil;
}

NSString *wq_container_label(NSString *dir)
{
    char buf[512];
    ssize_t len = getxattr(dir.fileSystemRepresentation, "com.apple.containermanager.identifier", buf, sizeof(buf) - 1, 0, 0);
    if (len > 0) {
        buf[len] = 0;
        return [NSString stringWithUTF8String:buf];
    }
    wq_grant(dir);  // the metadata plist needs a token on the container
    NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSData *data = wq_read(meta, 256 * 1024, NULL);
    if (!data) return nil;
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    id ident = [plist isKindOfClass:NSDictionary.class] ? plist[@"MCMMetadataIdentifier"] : nil;
    return [ident isKindOfClass:NSString.class] ? ident : nil;
}
