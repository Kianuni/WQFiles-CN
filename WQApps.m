//
//  WQApps.m
//  WQ Files app backup and restore manager
//

#import "WQApps.h"
#import "WQDir.h"
#import "WQUI.h"
#import "WQSharing.h"
#import "WQAccess.h"
#import "WQCore.h"

#pragma mark - Apps manager

@interface WQAppItem : NSObject
@property (nonatomic, copy) NSString *container;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) BOOL hasAccess;
@property (nonatomic, copy) NSArray<NSDictionary *> *backups;
@end
@implementation WQAppItem
@end

@implementation WQAppsViewController {
    NSArray<WQAppItem *> *_apps;
    NSString *_query;
    NSString *_status;
    BOOL _busy;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
    BOOL _scanning;
}

static NSArray<NSString *> *kAppDataParts(void) { return @[@"Documents", @"Library", @"tmp"]; }

static NSString *wq_app_backup_root(NSString *bundleID)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [[docs stringByAppendingPathComponent:@"AppBackups"] stringByAppendingPathComponent:bundleID];
}

// An app backup is AppBackups/<bundle id>/<date>/{Documents,Library} plus a
// manifest. It is built in a hidden staging folder and only renamed into
// place, with the manifest, once every file was copied: a failed or
// interrupted backup never shows up as one that can be restored.
static NSString *const kBackupManifest = @".wqbackup.plist";
static NSString *const kBackupStagingPrefix = @".incomplete-";
static NSString *const kBackupReasonBeforeRestore = @"Before restore";

static NSDictionary *wq_backup_manifest(NSString *backup)
{
    NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:[backup stringByAppendingPathComponent:kBackupManifest]];
    return [m[@"Complete"] boolValue] ? m : nil;
}

// Newest first. Complete backups only; backups made before manifests existed
// (WQ Files 0.1/0.2) are included with verified = NO.
static NSArray<NSDictionary *> *wq_app_backups(NSString *bundleID)
{
    NSString *root = wq_app_backup_root(bundleID);
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]
                      sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *name in names.reverseObjectEnumerator) {
        if ([name hasPrefix:@"."]) continue;   // staging folders and stray files
        NSString *path = [root stringByAppendingPathComponent:name];
        BOOL dir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir] || !dir) continue;
        NSDictionary *m = wq_backup_manifest(path);
        BOOL legacy = ![NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:kBackupManifest]];
        if (!m && !legacy) continue;           // a manifest that doesn't say Complete
        [out addObject:@{ @"path": path, @"name": name, @"verified": @(m != nil),
                          @"reason": m[@"Reason"] ?: @"" }];
    }
    return out;
}

static NSString *wq_backup_label(NSDictionary *__unused backup)
{
    NSString *label = backup[@"name"];
    if ([backup[@"reason"] length]) label = [label stringByAppendingFormat:@" (%@)", [backup[@"reason"] lowercaseString]];
    if (![backup[@"verified"] boolValue]) label = [label stringByAppendingString:@" (older, unverified)"];
    return label;
}

// Copies the app's Documents and Library into a new complete backup. Returns
// its path, or nil with *error (nothing is left behind then).
static NSString *wq_make_app_backup(NSString *bundleID, NSString *container, NSString *reason, NSString **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = wq_app_backup_root(bundleID);
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil])   // leftovers of interrupted runs
        if ([name hasPrefix:kBackupStagingPrefix]) [fm removeItemAtPath:[root stringByAppendingPathComponent:name] error:nil];

    NSString *staging = [root stringByAppendingPathComponent:
                         [kBackupStagingPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:nil error:nil]) {
        if (error) *error = @"Cannot create the backup folder";
        return nil;
    }
    NSMutableArray *parts = [NSMutableArray new];
    BOOL ok = YES;
    for (NSString *part in @[@"Documents", @"Library"]) {
        NSString *src = [container stringByAppendingPathComponent:part];
        struct stat st;
        if (lstat(src.fileSystemRepresentation, &st) != 0 && errno == ENOENT) continue;   // the app has none
        if (!wq_stat(src, &st)) { ok = NO; if (error) *error = [NSString stringWithFormat:@"Cannot access %@", part]; break; }
        if (!wq_copy_contents(src, [staging stringByAppendingPathComponent:part], error)) { ok = NO; break; }
        [parts addObject:part];
    }
    NSDictionary *manifest = @{ @"Complete": @YES, @"BundleID": bundleID, @"Created": NSDate.date,
                                @"Parts": parts, @"Reason": reason ?: @"", @"Format": @1 };
    if (ok && ![manifest writeToFile:[staging stringByAppendingPathComponent:kBackupManifest] atomically:YES]) {
        ok = NO;
        if (error) *error = @"Cannot write the backup manifest";
    }
    NSString *final = nil;
    if (ok) {
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"yyyy-MM-dd HH.mm.ss";
        NSString *stamp = [fmt stringFromDate:NSDate.date];
        final = [root stringByAppendingPathComponent:stamp];
        for (int n = 2; [fm fileExistsAtPath:final]; n++)
            final = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%d)", stamp, n]];
        if (rename(staging.fileSystemRepresentation, final.fileSystemRepresentation) != 0) {
            ok = NO;
            if (error) *error = [NSString stringWithFormat:@"Cannot finish the backup (errno %d)", errno];
        }
    }
    if (!ok) {
        [fm removeItemAtPath:staging error:nil];
        wq_log(@"app backup %@: FAILED (%@)", bundleID, error && *error ? *error : @"?");
        return nil;
    }
    wq_log(@"app backup %@ -> %@ (%@)", bundleID, final.lastPathComponent, [parts componentsJoinedByString:@", "]);
    return final;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Apps";
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search apps";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.tableView.tableHeaderView = wq_device_header(self.view.bounds.size.width);
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(scan) forControlEvents:UIControlEventValueChanged];
    [self scan];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (_scanning && _scanCancellation.isCancelled) [self scan];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (_scanning) [_scanCancellation cancel];
}

- (void)setBusy:(BOOL)busy status:(NSString *)status
{
    _busy = busy;
    _status = status;
    [self.tableView reloadData];
}

- (void)scan
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanning = YES;
    [self setBusy:YES status:@"Finding apps…"];
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    dispatch_async(wq_io(), ^{
        NSArray *containers = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, cancellation,
            ^(int64_t done, int64_t total, NSUInteger __unused f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_status = [NSString stringWithFormat:@"Finding apps… %lld%%", (long long)(done * 100 / total)];
                    [self.tableView reloadData];
                });
            });
        NSMutableArray<WQAppItem *> *apps = [NSMutableArray new];
        NSUInteger i = 0, grantFailures = 0, missingLabels = 0, limited = 0;
        for (NSString *c in containers) {
            if (cancellation.isCancelled) return;
            i++;
            if ([[c stringByResolvingSymlinksInPath] isEqualToString:home]) continue;  // ourselves
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_status = [NSString stringWithFormat:@"Measuring %lu/%lu…", (unsigned long)i, (unsigned long)containers.count];
                [self.tableView reloadData];
            });
            BOOL granted = wq_grant(c);
            if (!granted) {
                grantFailures++;
                if (grantFailures <= 3) wq_log(@"app scan: grant failed for %@", c);
            }
            NSString *bid = wq_container_label(c);
            if (!bid.length) {
                missingLabels++;
                if (missingLabels <= 3) wq_log(@"app scan: no container identifier for %@", c);
            }
            if (!granted || !bid.length) limited++;
            WQAppItem *app = [WQAppItem new];
            app.container = c;
            app.bundleID = bid;
            app.hasAccess = granted;
            app.name = bid.length ? (wq_display_name(bid) ?: bid)
                                  : [NSString stringWithFormat:@"Unknown container (%@)", c.lastPathComponent];
            app.bytes = granted ? wq_dir_size(c) : 0;
            app.backups = granted && bid.length ? wq_app_backups(bid) : @[];
            [apps addObject:app];
        }
        if (cancellation.isCancelled) return;
        [apps sortUsingComparator:^NSComparisonResult(WQAppItem *a, WQAppItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSString *note = nil;
        if (!containers) note = @"Container enumeration failed. Check the App Group and see Log.";
        else if (!containers.count) note = @"No app containers were found. Check the App Group and see Log.";
        else if (limited) note = [NSString stringWithFormat:@"%lu containers · %lu with limited access or no identifier. See Log.",
                                  (unsigned long)apps.count, (unsigned long)limited];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || cancellation.isCancelled) return;
            self->_scanning = NO;
            self->_apps = apps;
            [self.refreshControl endRefreshing];
            [self setBusy:NO status:note];
        });
    });
}

- (NSArray<WQAppItem *> *)visibleApps
{
    if (!_query.length) return _apps;
    return [_apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQAppItem *a, NSDictionary *__unused b) {
        return [a.name localizedCaseInsensitiveContainsString:self->_query] ||
               [a.bundleID localizedCaseInsensitiveContainsString:self->_query];
    }]];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (_busy && !_apps.count) ? 1 : (NSInteger)self.visibleApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_status) return _status;
    unsigned long long total = 0;
    for (WQAppItem *a in _apps) total += a.bytes;
    if (_query.length) return [NSString stringWithFormat:@"%lu of %lu apps", (unsigned long)self.visibleApps.count, (unsigned long)_apps.count];
    return [NSString stringWithFormat:@"%lu apps · %@ of app data", (unsigned long)_apps.count, wq_size_text(total)];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"Tap an app to back up, restore or clear its data. Close the app first (swipe it away in the app switcher). "
            "Backups are stored in WQFiles/AppBackups and are visible in the Files app.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_busy && !_apps.count) {
        c.text = @"Scanning…";
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    c.text = app.name;
    NSString *identifier = app.bundleID.length ? app.bundleID : app.container.lastPathComponent;
    BOOL hasBackup = app.backups.count > 0;
    if (!app.hasAccess) {
        c.secondaryText = [NSString stringWithFormat:@"Access unavailable · %@", identifier];
    } else if (!app.bundleID.length) {
        c.secondaryText = [NSString stringWithFormat:@"%@ · %@ · no identifier", wq_size_text(app.bytes), identifier];
    } else {
        c.secondaryText = [NSString stringWithFormat:@"%@ · %@%@", wq_size_text(app.bytes), app.bundleID, hasBackup ? @" · backed up" : @""];
    }
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.image = wq_app_icon(app.bundleID) ?: [UIImage systemImageNamed:@"app.dashed"];
    c.imageProperties.maximumSize = CGSizeMake(36, 36);
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_busy || !self.visibleApps.count) return;
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    if (!app.hasAccess || !app.bundleID.length) {
        NSString *why = app.hasAccess
            ? @"The container identifier is unavailable. Backup, restore and clear are disabled for this entry."
            : @"Sandbox access is unavailable. Check the App Group and see Log; only the container path can be copied.";
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:app.name
            message:[NSString stringWithFormat:@"%@\n\n%@", app.container, why]
            preferredStyle:UIAlertControllerStyleActionSheet];
        if (app.hasAccess) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"Open Data Folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
                [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:app.container title:app.name] animated:YES];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Copy Container Path" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            UIPasteboard.generalPasteboard.string = app.container;
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:app.name
        message:[NSString stringWithFormat:@"%@\n%@ of data", app.bundleID, wq_size_text(app.bytes)]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Back Up Data" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        [self backUp:app then:nil];
    }]];
    NSArray *backups = app.backups;
    NSString *latest = backups.firstObject[@"path"];
    if (latest) {
        NSString *title = backups.count == 1 ? [NSString stringWithFormat:@"Restore Backup (%@)", wq_backup_label(backups.firstObject)]
                                             : [NSString stringWithFormat:@"Restore a Backup… (%lu)", (unsigned long)backups.count];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            [self pickBackupToRestore:app from:[tableView cellForRowAtIndexPath:indexPath]];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Share Latest Backup (AirDrop…)"
                                                  style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
            wq_share_folder(self, latest, [NSString stringWithFormat:@"%@ %@", app.name, latest.lastPathComponent], c);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Clear Data…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self confirmClear:app];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open Data Folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:app.container title:app.name] animated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)finish:(NSString *)title message:(NSString *)message
{
    [self setBusy:NO status:nil];
    wq_alert(self, title, message);
    [self scan];
}

- (void)backUp:(WQAppItem *)app then:(void (^)(BOOL ok))next
{
    [self setBusy:YES status:[NSString stringWithFormat:@"Backing up %@…", app.name]];
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSString *dest = wq_make_app_backup(app.bundleID, app.container, nil, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (next) { next(dest != nil); return; }
            [self finish:dest ? @"Backed up" : @"Backup failed"
                 message:dest ? [NSString stringWithFormat:@"Saved to AppBackups/%@/%@", app.bundleID, dest.lastPathComponent]
                              : [NSString stringWithFormat:@"Nothing was saved: %@", error ?: @"see Log"]];
        });
    });
}

- (void)clear:(WQAppItem *)app
{
    [self setBusy:YES status:[NSString stringWithFormat:@"Clearing %@…", app.name]];
    dispatch_async(wq_io(), ^{
        unsigned long long freed = 0;
        BOOL ok = YES;
        for (NSString *part in kAppDataParts())
            if (!wq_purge_contents([app.container stringByAppendingPathComponent:part], &freed)) ok = NO;
        wq_log(@"clear data: %@ freed %llu ok=%d", app.bundleID, freed, ok);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finish:ok ? @"Data cleared" : @"Partly cleared"
                 message:[NSString stringWithFormat:@"Freed about %@.%@ Open %@ to start fresh.", wq_size_text(freed),
                          ok ? @"" : @" Some items could not be removed (see Log).", app.name]];
        });
    });
}

- (void)confirmClear:(WQAppItem *)app
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Clear %@?", app.name]
        message:@"Deletes everything in the app's Documents, Library and tmp, like a fresh install. "
                "Logins, settings and offline content are lost. Close the app first."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Back Up, Then Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self backUp:app then:^(BOOL ok) {
            if (ok) [self clear:app];
            else [self finish:@"Not cleared" message:@"The backup did not complete, so nothing was deleted."];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear Without Backup" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self clear:app];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pickBackupToRestore:(WQAppItem *)app from:(UIView *)source
{
    NSArray *backups = app.backups;
    if (backups.count == 1) { [self confirmRestore:app from:backups.firstObject]; return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Restore which backup?" message:app.name
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *__unused b in backups) {
        [sheet addAction:[UIAlertAction actionWithTitle:wq_backup_label(b) style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *__unused a) { [self confirmRestore:app from:b]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = (source ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRestore:(WQAppItem *)app from:(NSDictionary *)backup
{
    NSString *path = backup[@"path"];
    NSString *warning = [backup[@"verified"] boolValue] ? @""
        : @"\n\nThis backup was made by an older WQ Files that couldn't tell whether it was complete.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Restore %@?", app.name]
        message:[NSString stringWithFormat:@"Replaces the app's current Documents and Library with the backup from %@. "
                 "The current data is backed up first, and put back if anything fails. Close the app first.%@",
                 wq_backup_label(backup), warning]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self setBusy:YES status:[NSString stringWithFormat:@"Restoring %@…", app.name]];
        dispatch_async(wq_io(), ^{
            NSString *title = nil, *message = nil;
            [self restore:app from:path title:&title message:&message];
            dispatch_async(dispatch_get_main_queue(), ^{ [self finish:title message:message]; });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Replaces one part (Documents/Library) of the container with `src`.
static BOOL wq_replace_part(NSString *src, NSString *dst, NSString **error)
{
    unsigned long long ignored = 0;
    if (!wq_purge_contents(dst, &ignored)) {
        if (error && !*error) *error = [NSString stringWithFormat:@"Could not empty %@", dst.lastPathComponent];
        return NO;
    }
    return wq_copy_contents(src, dst, error);
}

static NSString *wq_restore_journal_path(void)
{
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"active-restore.plist"];
}

static BOOL wq_begin_restore_journal(WQAppItem *app, NSString *backup, NSString *safety, NSString **error)
{
    NSString *path = wq_restore_journal_path();
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                       attributes:nil error:nil]) {
        if (error) *error = @"Cannot create the restore recovery folder";
        return NO;
    }
    NSDictionary *journal = @{ @"Format": @1, @"State": @"Active", @"BundleID": app.bundleID,
                               @"Container": app.container, @"Backup": backup, @"Safety": safety,
                               @"Started": NSDate.date };
    if (![journal writeToFile:path atomically:YES]) {
        if (error) *error = @"Cannot write the restore recovery journal";
        return NO;
    }
    return YES;
}

static BOOL wq_clear_restore_journal(NSString **error)
{
    NSString *path = wq_restore_journal_path();
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) return YES;
    // Mark the transaction committed before removing it. A crash between these
    // steps must not make the next launch roll back a completed restore.
    NSMutableDictionary *journal = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (!journal) {
        if (error) *error = @"The restore recovery journal is unreadable";
        return NO;
    }
    journal[@"State"] = @"Committed";
    if (![journal writeToFile:path atomically:YES]) {
        if (error) *error = @"Cannot mark the restore recovery journal as committed";
        return NO;
    }
    NSError *removeError = nil;
    if (![fm removeItemAtPath:path error:&removeError]) {
        if (error) *error = removeError.localizedDescription ?: @"Cannot remove the restore recovery journal";
        return NO;
    }
    return YES;
}

static BOOL wq_rollback_safety(NSString *container, NSString *safety, NSString **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL ok = YES;
    for (NSString *part in @[@"Documents", @"Library"]) {
        NSString *saved = [safety stringByAppendingPathComponent:part];
        NSString *dst = [container stringByAppendingPathComponent:part];
        if ([fm fileExistsAtPath:saved]) {
            if (!wq_replace_part(saved, dst, error)) ok = NO;
        } else {
            unsigned long long ignored = 0;
            if (!wq_purge_contents(dst, &ignored)) {
                ok = NO;
                if (error && !*error) *error = [NSString stringWithFormat:@"Could not remove current %@", part];
            }
        }
    }
    return ok;
}

// Called on the serial I/O queue at launch. An active journal means termination
// may have left only some restored parts in place, so reapply the safety state.
NSString *wq_recover_interrupted_restore(void)
{
    NSString *path = wq_restore_journal_path();
    NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!journal) return nil;
    if (![journal[@"State"] isEqualToString:@"Active"]) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return nil;
    }
    NSString *bundleID = journal[@"BundleID"], *container = journal[@"Container"], *safety = journal[@"Safety"];
    if (!bundleID.length || !container.length || !wq_backup_manifest(safety)) {
        wq_log(@"restore recovery: invalid journal or incomplete safety backup at %@", path);
        return @"An interrupted restore was found, but its recovery journal or safety backup is invalid. See Log.";
    }
    NSString *error = nil;
    BOOL ok = wq_rollback_safety(container, safety, &error);
    if (ok) {
        NSString *cleanup = nil;
        if (!wq_clear_restore_journal(&cleanup)) ok = NO;
        if (!ok) error = cleanup;
    }
    wq_log(@"restore recovery for %@: %@", bundleID, ok ? @"OK" : error);
    return ok ? [NSString stringWithFormat:@"An interrupted restore of %@ was recovered from its safety backup.", bundleID]
              : [NSString stringWithFormat:@"Automatic recovery of %@ failed: %@. The safety backup is %@; see Log.",
                 bundleID, error ?: @"unknown error", safety.lastPathComponent];
}

- (void)restore:(WQAppItem *)app from:(NSString *)backup title:(NSString **)title message:(NSString **)message
{
    NSFileManager *fm = NSFileManager.defaultManager;
    // 1. The backup must be readable before anything is touched.
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *part in @[@"Documents", @"Library"]) {
        NSString *src = [backup stringByAppendingPathComponent:part];
        if (![fm fileExistsAtPath:src]) continue;
        if (![fm contentsOfDirectoryAtPath:src error:nil]) {
            *title = @"Not restored";
            *message = [NSString stringWithFormat:@"The backup's %@ can't be read. Nothing was changed.", part];
            return;
        }
        [parts addObject:part];
    }
    if (!parts.count) {
        *title = @"Not restored";
        *message = @"The backup is empty. Nothing was changed.";
        return;
    }
    // 2. Keep the current data and a durable recovery journal before touching
    // anything, so both ordinary failures and process termination are covered.
    NSString *error = nil;
    NSString *safety = wq_make_app_backup(app.bundleID, app.container, kBackupReasonBeforeRestore, &error);
    if (!safety) {
        *title = @"Not restored";
        *message = [NSString stringWithFormat:@"The current data couldn't be backed up first (%@). Nothing was changed.",
                    error ?: @"see Log"];
        return;
    }
    if (!wq_begin_restore_journal(app, backup, safety, &error)) {
        *title = @"Not restored";
        *message = [NSString stringWithFormat:@"%@. Nothing was changed.", error];
        return;
    }
    // 3. Restore the complete Documents/Library state. A part absent from the
    // backup must also be absent afterwards, not silently survive the restore.
    error = nil;
    BOOL ok = YES;
    NSDictionary *restorePlan = WQRestorePlan([parts containsObject:@"Documents"],
                                               [parts containsObject:@"Library"]);
    for (NSString *part in @[@"Documents", @"Library"]) {
        NSString *src = [backup stringByAppendingPathComponent:part];
        NSString *dst = [app.container stringByAppendingPathComponent:part];
        if ([restorePlan[part] boolValue]) {
            if (!wq_replace_part(src, dst, &error)) { ok = NO; break; }
        } else {
            unsigned long long ignored = 0;
            if (!wq_purge_contents(dst, &ignored)) {
                ok = NO;
                error = [NSString stringWithFormat:@"Could not remove current %@", part];
                break;
            }
        }
    }
    if (ok) {
        NSString *cleanupError = nil;
        if (wq_clear_restore_journal(&cleanupError)) {
            wq_log(@"restore %@ from %@: OK", app.bundleID, backup.lastPathComponent);
            *title = @"Restored";
            *message = [NSString stringWithFormat:@"Open %@ to use the restored data. The data from before is kept as backup %@.",
                        app.name, safety.lastPathComponent];
            return;
        }
        // Never leave a completed restore with an active journal: the next
        // launch would otherwise roll it back unexpectedly.
        error = [NSString stringWithFormat:@"The restore finished, but its recovery journal could not be cleared (%@)", cleanupError];
    }
    wq_log(@"restore %@ from %@: FAILED (%@), rolling back", app.bundleID, backup.lastPathComponent, error);
    NSString *rollbackError = nil;
    BOOL rolledBack = wq_rollback_safety(app.container, safety, &rollbackError);
    // Keep the journal when the rollback failed, so the next launch tries the
    // recovery again instead of leaving the app half restored.
    NSString *cleanupError = nil;
    BOOL cleared = rolledBack && wq_clear_restore_journal(&cleanupError);
    if (!rolledBack) cleanupError = @"kept for recovery at the next launch";
    wq_log(@"restore %@: rollback %@, journal %@", app.bundleID,
           rolledBack ? @"OK" : @"FAILED", cleared ? @"cleared" : cleanupError);
    *title = @"Restore failed";
    *message = rolledBack
        ? [NSString stringWithFormat:@"%@. The previous data was put back.%@", error ?: @"Some files couldn't be written",
           cleared ? @"" : @" Recovery will run again at the next launch because the journal could not be removed."]
        : [NSString stringWithFormat:@"%@, and putting the previous data back also failed (%@). It is in backup %@; see the Log.%@",
           error ?: @"Some files couldn't be written", rollbackError ?: @"see Log", safety.lastPathComponent,
           cleared ? @"" : @" Recovery will run again at the next launch."];
}

@end

