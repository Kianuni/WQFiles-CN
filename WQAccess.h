//
//  WQAccess.h
//  WQ Files
//
//  File access outside the sandbox through the worse_query technique by
//  Taj C (forcequit), https://github.com/forcequitOS/worse_query,
//  GPL-3.0-or-later. This reimplementation is GPL-3.0-or-later as well.
//

#import <Foundation/Foundation.h>
#import "WQLaunchServices.h"
#import <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

// Log shared with the UI.
void wq_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *wq_log_text(void);

// Picks the app group the signer actually gave us. Nil when there is none.
NSString *_Nullable wq_app_group(void);

// Asks for a sandbox extension covering path (once per path). Returns YES
// when one is held for it.
BOOL wq_grant(NSString *path);

// Directory listing; asks for access when the plain call is refused.
NSArray<NSString *> *_Nullable wq_list(NSString *dir, NSString *_Nullable *_Nullable errorText);

// Reads a whole file (up to maxBytes; 0 = no limit).
NSData *_Nullable wq_read(NSString *path, NSUInteger maxBytes, NSString *_Nullable *_Nullable errorText);

// A file's identity, size and change timestamps, for optimistic concurrency.
NSDictionary<NSString *, NSNumber *> *_Nullable wq_file_version(NSString *path);

// Overwrites a file in place (same inode, owner and xattrs). The previous
// contents are backed up first, and a failed write attempts to roll back.
// The _if_unchanged forms refuse to overwrite a file modified since `expected`.
BOOL wq_write(NSString *path, NSData *data, NSString *_Nullable *_Nullable errorText);
BOOL wq_write_if_unchanged(NSString *path, NSData *data, NSDictionary<NSString *, NSNumber *> *_Nullable expected,
                           NSString *_Nullable *_Nullable errorText);

// Same as wq_write / wq_create_file, but streamed from a local file (for large
// files; nothing is held in memory). A failed create leaves no partial file.
BOOL wq_write_from_file(NSString *path, NSString *source, NSString *_Nullable *_Nullable errorText);
BOOL wq_create_file_from(NSString *path, NSString *source, NSString *_Nullable *_Nullable errorText);
// Streams a file from anywhere into a local path (replaced if it exists).
BOOL wq_copy_to_local(NSString *path, NSString *dest, NSString *_Nullable *_Nullable errorText);

// When Unix permissions (not the sandbox) keep this app out of `path`: an
// explanation for the user; nil if the owner and mode allow it.
NSString *_Nullable wq_permission_hint(NSString *path, BOOL forWriting);

// Reads `length` bytes at `offset` (fewer at the end of the file).
NSData *_Nullable wq_read_range(NSString *path, unsigned long long offset, NSUInteger length,
                                NSString *_Nullable *_Nullable errorText);
// Overwrites bytes in place: offset -> replacement bytes. The file keeps its
// size; it is backed up first, and flush/close errors are reported.
BOOL wq_patch(NSString *path, NSDictionary<NSNumber *, NSData *> *runs, NSString *_Nullable *_Nullable errorText);
BOOL wq_patch_if_unchanged(NSString *path, NSDictionary<NSNumber *, NSData *> *runs,
                           NSDictionary<NSString *, NSNumber *> *_Nullable expected, NSString *_Nullable *_Nullable errorText);

// Creates a new file or folder inside dir.
BOOL wq_create_file(NSString *path, NSData *data, NSString *_Nullable *_Nullable errorText);
BOOL wq_create_dir(NSString *path, NSString *_Nullable *_Nullable errorText);

// Deletes a file (backed up first) or an empty folder.
BOOL wq_delete(NSString *path, NSString *_Nullable *_Nullable errorText);
BOOL wq_rename(NSString *path, NSString *newName, NSString *_Nullable *_Nullable errorText);

// lstat with access retry. Returns NO if the item does not exist.
BOOL wq_stat(NSString *path, struct stat *st);

// Thread-safe cancellation for expensive filesystem scans.
@interface WQScanCancellation : NSObject
@property (atomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

// Discovers direct children of dir by brute-forcing inode numbers with
// fsgetpath (not sandbox-gated), the way KAMUI/bad_query_list do. Needs no
// token on dir. maxInode bounds the scan (0 = up to the newest id on the
// volume); progress is called off the main thread, from several threads.
// Returns absolute child paths, sorted, or nil on failure/cancellation.
NSArray<NSString *> *_Nullable wq_enumerate(NSString *dir, int64_t maxInode,
                                            WQScanCancellation *_Nullable cancellation,
                                            void (^_Nullable progress)(int64_t done, int64_t total, NSUInteger found));

// Total byte size of a directory tree (grants access as needed). 0 if missing.
unsigned long long wq_dir_size(NSString *dir);

// Deletes every item *inside* dir (dir itself stays). No backup — for caches.
// Adds freed bytes to *freed. A missing dir counts as done; NO if dir cannot
// be read or listed, or if some items could not be removed.
BOOL wq_purge_contents(NSString *dir, unsigned long long *freed);

// Copies every item inside srcDir into dstDir (replacing same-named items).
// Either side may be another app's container. Returns NO if anything failed.
BOOL wq_copy_contents(NSString *srcDir, NSString *dstDir, NSString *_Nullable *_Nullable errorText);

// MCM container identifier (bundle or group id) of a container folder.
NSString *_Nullable wq_container_label(NSString *dir);

// Backups of overwritten or deleted files, mirrored by original path.
NSString *wq_backup_root(void);
NSString *_Nullable wq_backup_original_path(NSString *backupPath);

NS_ASSUME_NONNULL_END

