//
//  WQCache.m
//  WQ Files cache cleaner
//

#import "WQCache.h"
#import "WQDir.h"
#import "WQUI.h"
#import "WQAccess.h"
#import "WQCacheSafety.h"

#import <errno.h>
#import <sys/stat.h>

#pragma mark - Cache cleaner

static NSString *const kCrashLogsPath =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs/CrashReporter";

@interface WQCacheTargetRecord : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic) BOOL existed;
@property (nonatomic) BOOL identityKnown;
@property (nonatomic) dev_t device;
@property (nonatomic) ino_t inode;
@property (nonatomic) mode_t mode;
@end
@implementation WQCacheTargetRecord
@end

@interface WQCacheItem : NSObject
@property (nonatomic, copy) NSString *name;        // app name or "Crash Logs"
@property (nonatomic, copy) NSString *bundleID;    // for the icon; nil for logs
@property (nonatomic, copy) NSArray<NSString *> *targets;  // dirs to purge
@property (nonatomic) unsigned long long cacheBytes;
@property (nonatomic) unsigned long long tempBytes;
@property (nonatomic) BOOL cacheKnown;
@property (nonatomic) BOOL tempKnown;
@property (nonatomic) BOOL limited;
@property (nonatomic) BOOL crashLogs;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic) BOOL containerIdentityKnown;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic) mode_t containerMode;
@property (nonatomic, copy) NSArray<WQCacheTargetRecord *> *targetRecords;
@property (nonatomic) BOOL selected;
@property (nonatomic, readonly) unsigned long long bytes;
@end
@implementation WQCacheItem
- (unsigned long long)bytes { return self.cacheBytes + self.tempBytes; }
@end

static void WQCacheSelectionCategories(NSArray<WQCacheItem *> *items,
                                       BOOL *hasApps,
                                       BOOL *hasCrashLogs,
                                       NSUInteger *appCount)
{
    BOOL apps = NO, crashLogs = NO;
    NSUInteger count = 0;
    for (WQCacheItem *item in items) {
        if (item.crashLogs) {
            crashLogs = YES;
        } else {
            apps = YES;
            count++;
        }
    }
    if (hasApps) *hasApps = apps;
    if (hasCrashLogs) *hasCrashLogs = crashLogs;
    if (appCount) *appCount = count;
}

static NSString *WQCacheConfirmationScope(NSArray<WQCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    NSUInteger appCount = 0;
    WQCacheSelectionCategories(items, &hasApps, &hasCrashLogs, &appCount);
    if (hasApps && hasCrashLogs) {
        return [NSString stringWithFormat:@"Delete Library/Caches and tmp for %lu app%@, plus Crash Logs",
                (unsigned long)appCount, appCount == 1 ? @"" : @"s"];
    }
    if (hasApps) {
        return [NSString stringWithFormat:@"Delete Library/Caches and tmp for %lu app%@",
                (unsigned long)appCount, appCount == 1 ? @"" : @"s"];
    }
    if (hasCrashLogs) return @"Delete Crash Logs";
    return @"Delete the selected cache targets";
}

static NSString *WQCacheFooterScope(NSArray<WQCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    WQCacheSelectionCategories(items, &hasApps, &hasCrashLogs, NULL);
    if (hasApps && hasCrashLogs) {
        return @"Clears each selected app's Library/Caches and tmp, and deletes selected Crash Logs. Apps rebuild "
                "their caches as you use them; some keep offline content (music, maps, downloads) there and "
                "will download it again. No backup is kept.";
    }
    if (hasApps) {
        return @"Clears each selected app's Library/Caches and tmp. Apps rebuild their caches as you use them; "
                "some keep offline content (music, maps, downloads) there and will download it again. No backup "
                "is kept.";
    }
    if (hasCrashLogs) return @"Deletes selected Crash Logs. This cannot be undone. No backup is kept.";
    return @"Select app caches or Crash Logs to see the deletion scope. No backup is kept.";
}

typedef NS_ENUM(NSInteger, WQCacheMeasurementState) {
    WQCacheMeasurementMissing,
    WQCacheMeasurementKnown,
    WQCacheMeasurementLimited,
    WQCacheMeasurementCancelled,
};

static WQCacheMeasurementState WQCacheMeasureDirectory(NSString *path,
                                                        WQScanCancellation *cancellation,
                                                        unsigned long long *bytes)
{
    if (cancellation.isCancelled) return WQCacheMeasurementCancelled;
    struct stat st = {0};
    if (!wq_stat(path, &st)) {
        struct stat direct = {0};
        if (lstat(path.fileSystemRepresentation, &direct) != 0 &&
            (errno == ENOENT || errno == ENOTDIR)) return WQCacheMeasurementMissing;
        return WQCacheMeasurementLimited;
    }
    if (!S_ISDIR(st.st_mode)) return WQCacheMeasurementLimited;

    // wq_list performs the access retry and, unlike wq_dir_size, exposes a
    // failed root listing.  The enumerator below then measures the tree once
    // while retaining cancellation checks between entries.
    NSString *listError = nil;
    NSArray<NSString *> *children = wq_list(path, &listError);
    if (!children) {
        wq_log(@"cache scan: cannot list %@%@", path,
               listError.length ? [NSString stringWithFormat:@" (%@)", listError] : @"");
        return WQCacheMeasurementLimited;
    }
    if (!children.count) {
        if (bytes) *bytes = 0;
        return WQCacheMeasurementKnown;
    }

    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:path];
    if (!enumerator) {
        wq_log(@"cache scan: cannot enumerate %@", path);
        return WQCacheMeasurementLimited;
    }
    unsigned long long total = 0;
    for (NSString *__unused relativePath in enumerator) {
        if (cancellation.isCancelled) return WQCacheMeasurementCancelled;
        NSDictionary *attributes = enumerator.fileAttributes;
        if (!attributes) {
            wq_log(@"cache scan: missing attributes while enumerating %@", path);
            return WQCacheMeasurementLimited;
        }
        if ([attributes.fileType isEqualToString:NSFileTypeRegular]) total += attributes.fileSize;
    }
    if (cancellation.isCancelled) return WQCacheMeasurementCancelled;
    if (bytes) *bytes = total;
    return WQCacheMeasurementKnown;
}

typedef NS_ENUM(NSInteger, WQCachePathState) {
    WQCachePathMissing,
    WQCachePathExisting,
    WQCachePathInaccessible,
};

static WQCachePathState WQCacheInspectPath(NSString *path, struct stat *st)
{
    if (wq_stat(path, st)) return WQCachePathExisting;
    struct stat direct = {0};
    if (lstat(path.fileSystemRepresentation, &direct) == 0) {
        if (st) *st = direct;
        return WQCachePathExisting;
    }
    if (errno == ENOENT || errno == ENOTDIR) return WQCachePathMissing;
    return WQCachePathInaccessible;
}

static WQCacheTargetRecord *WQCacheTargetRecordForPath(NSString *path, NSString *relativePath)
{
    WQCacheTargetRecord *record = [WQCacheTargetRecord new];
    record.path = path;
    record.relativePath = relativePath;
    struct stat st = {0};
    WQCachePathState state = WQCacheInspectPath(path, &st);
    if (state == WQCachePathExisting) {
        record.existed = YES;
        record.identityKnown = YES;
        record.device = st.st_dev;
        record.inode = st.st_ino;
        record.mode = st.st_mode & S_IFMT;
    }
    return record;
}

static void WQCacheCaptureContainerIdentity(WQCacheItem *item)
{
    struct stat st = {0};
    if (item.containerPath.length && wq_stat(item.containerPath, &st) && S_ISDIR(st.st_mode)) {
        item.containerIdentityKnown = YES;
        item.containerDevice = st.st_dev;
        item.containerInode = st.st_ino;
        item.containerMode = st.st_mode & S_IFMT;
    }
}

static BOOL WQCacheRecordIdentityMatches(WQCacheTargetRecord *record, NSString **reason)
{
    struct stat st = {0};
    WQCachePathState state = WQCacheInspectPath(record.path, &st);
    if (!record.existed) {
        if (state == WQCachePathMissing) return YES;
        if (reason) *reason = [NSString stringWithFormat:@"%@ appeared after the scan", record.path];
        return NO;
    }
    if (state != WQCachePathExisting || !record.identityKnown ||
        st.st_dev != record.device || st.st_ino != record.inode ||
        (st.st_mode & S_IFMT) != record.mode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ changed after the scan", record.path];
        return NO;
    }
    return YES;
}

static BOOL WQCacheCrashPathIsSafe(NSString *path)
{
    NSString *expected = [kCrashLogsPath stringByStandardizingPath];
    return [[path stringByStandardizingPath] isEqualToString:expected] &&
           WQCacheSafetyHasNoSymlinkAncestry(path, YES) &&
           [WQCacheSafetyCanonicalPath(path) isEqualToString:expected];
}

static BOOL WQCacheValidateItem(WQCacheItem *item, NSString **reason)
{
    if (item.limited) {
        if (reason) *reason = @"the scan had limited access";
        return NO;
    }
    if (item.crashLogs) {
        if (item.targetRecords.count != 1 || !WQCacheCrashPathIsSafe(item.targets.firstObject)) {
            if (reason) *reason = @"the crash-log target is not the expected canonical directory";
            return NO;
        }
        return WQCacheRecordIdentityMatches(item.targetRecords.firstObject, reason);
    }
    if (item.targetRecords.count != 2 || item.targets.count != 2 ||
        ![item.targets[0] isEqualToString:item.targetRecords[0].path] ||
        ![item.targets[1] isEqualToString:item.targetRecords[1].path]) {
        if (reason) *reason = @"the scanned cache targets are incomplete";
        return NO;
    }
    if (!item.containerIdentityKnown || !WQCacheSafetyHasNoSymlinkAncestry(item.containerPath, NO)) {
        if (reason) *reason = @"the app container identity or ancestry is unavailable";
        return NO;
    }
    struct stat container = {0};
    if (WQCacheInspectPath(item.containerPath, &container) != WQCachePathExisting ||
        !S_ISDIR(container.st_mode) || container.st_dev != item.containerDevice ||
        container.st_ino != item.containerInode || (container.st_mode & S_IFMT) != item.containerMode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ changed after the scan", item.name];
        return NO;
    }
    NSString *label = wq_container_label(item.containerPath);
    if (!item.bundleID.length || ![label isEqualToString:item.bundleID]) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ no longer has the scanned container identity", item.name];
        return NO;
    }
    for (WQCacheTargetRecord *record in item.targetRecords) {
        if (!WQCacheSafetyTargetMatchesContainer(record.path, item.containerPath, record.relativePath)) {
            if (reason) *reason = [NSString stringWithFormat:@"%@ has unsafe path ancestry", record.path];
            return NO;
        }
        if (!WQCacheRecordIdentityMatches(record, reason)) return NO;
    }
    return YES;
}

// Row: selection circle, icon, name with "cache · temp" below, size in a
// fixed right-hand column so long names never push it out.
@interface WQCleanerCell : UITableViewCell
@property (nonatomic, strong) UIImageView *checkView, *iconView;
@property (nonatomic, strong) UILabel *nameLabel, *detailLabel, *sizeLabel;
@end

@implementation WQCleanerCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _checkView = [UIImageView new];
        _checkView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _sizeLabel = [UILabel new];
        _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        _sizeLabel.textAlignment = NSTextAlignmentRight;
        for (UIView *v in @[_checkView, _iconView, _nameLabel, _detailLabel, _sizeLabel]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        [_sizeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_sizeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_checkView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [_checkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkView.widthAnchor constraintEqualToConstant:24],
            [_checkView.heightAnchor constraintEqualToConstant:24],
            [_iconView.leadingAnchor constraintEqualToAnchor:_checkView.trailingAnchor constant:12],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:36],
            [_iconView.heightAnchor constraintEqualToConstant:36],
            [_sizeLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [_sizeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_sizeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:76],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11],
        ]];
    }
    return self;
}

@end

// Summary card: reclaimable total, a bar for the selected share, status.
@interface WQSummaryCell : UITableViewCell
@property (nonatomic, strong) UILabel *captionLabel, *totalLabel, *statusLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation WQSummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _captionLabel = [UILabel new];
        _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _captionLabel.textColor = UIColor.secondaryLabelColor;
        _totalLabel = [UILabel new];
        _totalLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle]
                            scaledFontForFont:[UIFont systemFontOfSize:34 weight:UIFontWeightBold]];
        _totalLabel.adjustsFontForContentSizeCategory = YES;
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.progressTintColor = UIColor.systemBlueColor;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _statusLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel.numberOfLines = 0;
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.hidesWhenStopped = YES;
        UIStackView *captionRow = [[UIStackView alloc] initWithArrangedSubviews:@[_captionLabel, _spinner]];
        captionRow.spacing = 8;
        captionRow.alignment = UIStackViewAlignmentCenter;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[captionRow, _totalLabel, _bar, _statusLabel]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        [stack setCustomSpacing:10 afterView:_totalLabel];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
        ]];
    }
    return self;
}

@end

@implementation WQCacheCleanerViewController {
    NSArray<WQCacheItem *> *_items;
    NSString *_query;
    NSString *_status;   // scan / clean progress, nil when idle
    NSString *_result;   // last clean result
    BOOL _scanning, _cleaning, _scanLimited;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Cache Cleaner";
    self.tableView.tableHeaderView = wq_device_header(self.view.bounds.size.width);
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search apps";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
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

- (NSArray<WQCacheItem *> *)visibleItems
{
    if (!_query.length) return _items;
    return [_items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQCacheItem *it, NSDictionary *__unused b) {
        return [it.name localizedCaseInsensitiveContainsString:self->_query] ||
               (it.bundleID && [it.bundleID localizedCaseInsensitiveContainsString:self->_query]);
    }]];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)setStatus:(NSString *)status
{
    _status = status;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)updateButtons
{
    if (_scanning || _cleaning) {
        self.navigationItem.rightBarButtonItems = nil;
        return;
    }
    NSUInteger n = 0;
    for (WQCacheItem *it in _items) if (it.selected) n++;
    UIBarButtonItem *clean = [[UIBarButtonItem alloc] initWithTitle:@"Clean" style:wq_primary_button_style()
                                                             target:self action:@selector(confirmClean)];
    clean.enabled = n > 0 && !_scanLimited;
    NSArray *visible = self.visibleItems;
    BOOL allVisible = visible.count > 0;
    for (WQCacheItem *it in visible) if (!it.selected) { allVisible = NO; break; }
    __weak typeof(self) weakSelf = self;
    UIAction *__unused all = [UIAction actionWithTitle:@"Select All" image:[UIImage systemImageNamed:@"checkmark.circle"]
                                   identifier:nil handler:^(UIAction *__unused a) { [weakSelf selectWhere:^BOOL(WQCacheItem *__unused it) { return YES; }]; }];
    UIAction *none = [UIAction actionWithTitle:@"Select None" image:[UIImage systemImageNamed:@"circle"]
                                    identifier:nil handler:^(UIAction *__unused a) { [weakSelf selectWhere:^BOOL(WQCacheItem *__unused it) { return NO; }]; }];
    UIAction *large = [UIAction actionWithTitle:@"Select Large Caches (50 MB+)" image:[UIImage systemImageNamed:@"arrow.up.circle"]
                                     identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf selectWhere:^BOOL(WQCacheItem *__unused it) { return it.bytes >= 50ull * 1000 * 1000; }];
    }];
    all.state = allVisible ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIBarButtonItem *select = [[UIBarButtonItem alloc] initWithTitle:@"Select"
                                                                menu:[UIMenu menuWithChildren:@[all, none, large]]];
    select.enabled = visible.count > 0;
    self.navigationItem.rightBarButtonItems = @[clean, select];
}

- (void)scan
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanning = YES;
    _scanLimited = NO;
    _result = nil;
    [self updateButtons];
    [self setStatus:@"Finding apps…"];
    dispatch_async(wq_io(), ^{
        NSMutableArray<WQCacheItem *> *items = [NSMutableArray new];
        NSMutableArray<NSString *> *emptyRoots = [NSMutableArray new];
        BOOL scanLimited = NO;
        NSUInteger failedEnumerations = 0;
        NSUInteger limitedContainers = 0;
        NSUInteger limitedMeasurements = 0;
        NSArray *roots = @[@"/private/var/mobile/Containers/Data/Application",
                           @"/private/var/mobile/Containers/Data/PluginKitPlugin"];
        for (NSString *root in roots) {
            if (cancellation.isCancelled) return;
            NSString *kind = [root.lastPathComponent isEqualToString:@"Application"] ? @"apps" : @"extensions";
            NSArray *containers = wq_enumerate(root, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    [self setStatus:[NSString stringWithFormat:@"Finding %@… %lld%%", kind, (long long)(done * 100 / total)]];
                });
            });
            if (!containers) {
                if (cancellation.isCancelled) return;
                scanLimited = YES;
                failedEnumerations++;
                wq_log(@"cache scan: %@ container enumeration failed", kind);
                continue;
            }
            if (!containers.count) [emptyRoots addObject:kind];
            NSUInteger idx = 0;
            for (NSString *c in containers) {
                if (cancellation.isCancelled) return;
                idx++;
                if (idx % 10 == 0 || idx == containers.count) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                        [self setStatus:[NSString stringWithFormat:@"Measuring %@ %lu of %lu…", kind,
                                         (unsigned long)idx, (unsigned long)containers.count]];
                    });
                }
                BOOL safeContainer = WQCacheSafetyHasNoSymlinkAncestry(c, NO);
                BOOL granted = safeContainer && wq_grant(c);  // one token for the whole container
                NSString *caches = [c stringByAppendingPathComponent:@"Library/Caches"];
                NSString *tmp = [c stringByAppendingPathComponent:@"tmp"];
                unsigned long long cacheBytes = 0, tempBytes = 0;
                BOOL safeCaches = safeContainer &&
                    WQCacheSafetyTargetMatchesContainer(caches, c, @"Library/Caches");
                BOOL safeTmp = safeContainer &&
                    WQCacheSafetyTargetMatchesContainer(tmp, c, @"tmp");
                WQCacheMeasurementState cacheState = granted && safeCaches
                    ? WQCacheMeasureDirectory(caches, cancellation, &cacheBytes)
                    : WQCacheMeasurementLimited;
                if (cacheState == WQCacheMeasurementCancelled) return;
                WQCacheMeasurementState tempState = granted && safeTmp
                    ? WQCacheMeasureDirectory(tmp, cancellation, &tempBytes)
                    : WQCacheMeasurementLimited;
                if (tempState == WQCacheMeasurementCancelled) return;
                if (!granted || !safeContainer) {
                    scanLimited = YES;
                    limitedContainers++;
                    wq_log(@"cache scan: %@ container access or path safety check failed", c);
                }
                if (cacheState == WQCacheMeasurementLimited || tempState == WQCacheMeasurementLimited) {
                    scanLimited = YES;
                    limitedMeasurements++;
                }
                BOOL cacheKnown = cacheState != WQCacheMeasurementLimited;
                BOOL tempKnown = tempState != WQCacheMeasurementLimited;
                if (cacheKnown && tempKnown && cacheBytes + tempBytes < 64 * 1024) continue;
                WQCacheItem *item = [WQCacheItem new];
                NSString *bid = granted ? wq_container_label(c) : nil;
                item.bundleID = bid;
                item.name = wq_display_name(bid) ?: bid ?: c.lastPathComponent;
                item.targets = @[caches, tmp];
                item.cacheBytes = cacheBytes;
                item.tempBytes = tempBytes;
                item.cacheKnown = cacheKnown;
                item.tempKnown = tempKnown;
                item.limited = !cacheKnown || !tempKnown;
                item.containerPath = c;
                item.targetRecords = @[
                    WQCacheTargetRecordForPath(caches, @"Library/Caches"),
                    WQCacheTargetRecordForPath(tmp, @"tmp"),
                ];
                WQCacheCaptureContainerIdentity(item);
                item.selected = YES;
                [items addObject:item];
            }
        }
        if (cancellation.isCancelled) return;
        unsigned long long crash = 0;
        BOOL safeCrashPath = WQCacheCrashPathIsSafe(kCrashLogsPath);
        WQCacheMeasurementState crashState = safeCrashPath
            ? WQCacheMeasureDirectory(kCrashLogsPath, cancellation, &crash)
            : WQCacheMeasurementLimited;
        if (crashState == WQCacheMeasurementCancelled) return;
        if (crashState == WQCacheMeasurementLimited) {
            scanLimited = YES;
            limitedMeasurements++;
        }
        if (crashState == WQCacheMeasurementLimited || crash > 0) {
            WQCacheItem *logs = [WQCacheItem new];
            logs.name = @"Crash Logs";
            logs.targets = @[kCrashLogsPath];
            logs.cacheBytes = crash;
            logs.cacheKnown = crashState != WQCacheMeasurementLimited;
            logs.crashLogs = YES;
            logs.limited = crashState == WQCacheMeasurementLimited;
            logs.targetRecords = @[WQCacheTargetRecordForPath(kCrashLogsPath, nil)];
            logs.selected = YES;
            [items addObject:logs];
        }
        [items sortUsingComparator:^NSComparisonResult(WQCacheItem *a, WQCacheItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSString *> *notes = [NSMutableArray new];
        if (failedEnumerations) {
            [notes addObject:[NSString stringWithFormat:@"%lu container enumeration%@ failed",
                              (unsigned long)failedEnumerations, failedEnumerations == 1 ? @"" : @"s"]];
        }
        if (limitedContainers) {
            [notes addObject:[NSString stringWithFormat:@"%lu container%@ had limited access",
                              (unsigned long)limitedContainers, limitedContainers == 1 ? @"" : @"s"]];
        }
        if (limitedMeasurements) {
            [notes addObject:[NSString stringWithFormat:@"%lu cache tree measurement%@ was limited",
                              (unsigned long)limitedMeasurements, limitedMeasurements == 1 ? @"" : @"s"]];
        }
        NSString *note = nil;
        if (scanLimited) {
            [notes addObject:@"cleaning is disabled until a complete scan succeeds"];
            note = [NSString stringWithFormat:@"Scan incomplete: %@. See Log.", [notes componentsJoinedByString:@"; "]];
        } else if (emptyRoots.count) {
            note = [NSString stringWithFormat:@"No %@ container%@ found.",
                    [emptyRoots componentsJoinedByString:@" or "], emptyRoots.count == 1 ? @"" : @"s"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || cancellation.isCancelled) return;
            self->_items = items;
            self->_scanning = NO;
            self->_scanLimited = scanLimited;
            self->_status = note;
            [self.tableView reloadData];
            [self updateButtons];
        });
    });
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : (NSInteger)self.visibleItems.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSUInteger shown = self.visibleItems.count;
    return _query.length ? [NSString stringWithFormat:@"%lu of %lu", (unsigned long)shown, (unsigned long)_items.count]
                         : [NSString stringWithFormat:@"%lu apps and extensions", (unsigned long)_items.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSArray<WQCacheItem *> *selected = [_items filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"selected == YES"]];
    return WQCacheFooterScope(selected);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        WQSummaryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"summary"]
            ?: [[WQSummaryCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"summary"];
        unsigned long long total = 0, selected = 0;
        NSUInteger n = 0;
        for (WQCacheItem *it in _items) { total += it.bytes; if (it.selected) { selected += it.bytes; n++; } }
        BOOL busy = _scanning || _cleaning;
        cell.captionLabel.text = busy ? (_cleaning ? @"Cleaning" : @"Scanning") : @"Reclaimable";
        if (busy) [cell.spinner startAnimating]; else [cell.spinner stopAnimating];
        cell.totalLabel.text = (_scanning && !_items.count) ? @"–" : wq_size_text(total);
        cell.bar.progress = total ? (float)((double)selected / (double)total) : 0;
        cell.bar.hidden = _scanning && !_items.count;
        cell.statusLabel.text = _status ?: _result
            ?: [NSString stringWithFormat:@"%@ selected in %lu item%@", wq_size_text(selected), (unsigned long)n, n == 1 ? @"" : @"s"];
        return cell;
    }
    WQCleanerCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[WQCleanerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"item"];
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    cell.nameLabel.text = item.name;
    if (item.crashLogs) {
        cell.detailLabel.text = item.cacheKnown ? @"Crash Logs · osanalytics" : @"Crash Logs · access limited";
    } else {
        NSString *cache = item.cacheKnown ? wq_size_text(item.cacheBytes) : @"unknown";
        NSString *temp = item.tempKnown ? wq_size_text(item.tempBytes) : @"unknown";
        cell.detailLabel.text = [NSString stringWithFormat:@"cache %@ · temp %@%@", cache, temp,
                                 item.limited ? @" · access limited" : @""];
    }
    cell.sizeLabel.text = wq_size_text(item.bytes);
    cell.iconView.image = wq_app_icon(item.bundleID)
        ?: [UIImage systemImageNamed:item.bundleID ? @"app.dashed" : @"exclamationmark.triangle"];
    cell.iconView.tintColor = UIColor.secondaryLabelColor;
    cell.checkView.image = [UIImage systemImageNamed:item.selected ? @"checkmark.circle.fill" : @"circle"];
    cell.checkView.tintColor = item.selected ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 || _scanning || _cleaning) return;
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    item.selected = !item.selected;
    [tableView reloadRowsAtIndexPaths:@[indexPath, [NSIndexPath indexPathForRow:0 inSection:0]]
                     withRowAnimation:UITableViewRowAnimationNone];
    [self updateButtons];
}

- (void)openFolder:(NSString *)path title:(NSString *)title
{
    [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:title] animated:YES];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    // Not during a scan or clean: the browser would show a tree that changes underneath it.
    if (indexPath.section == 0 || _scanning || _cleaning) return nil;
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        NSMutableArray *actions = [NSMutableArray new];
        if (!item.bundleID) {
            NSString *root = item.targets.firstObject;
            [actions addObject:[UIAction actionWithTitle:@"Show Crash Logs in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *__unused a) { [weakSelf openFolder:root title:@"Crash Logs"]; }]];
        } else {
            NSString *caches = item.targets[0], *tmp = item.targets[1];
            [actions addObject:[UIAction actionWithTitle:@"Show Caches in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf openFolder:caches title:[item.name stringByAppendingString:@" · Caches"]];
            }]];
            if (item.tempBytes > 0)
                [actions addObject:[UIAction actionWithTitle:@"Show tmp in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    [weakSelf openFolder:tmp title:[item.name stringByAppendingString:@" · tmp"]];
                }]];
            [actions addObject:[UIAction actionWithTitle:@"Show App Data in File Browser" image:[UIImage systemImageNamed:@"folder.badge.gearshape"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf openFolder:caches.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent title:item.name];
            }]];
        }
        return [UIMenu menuWithTitle:item.name children:actions];
    }];
}

#pragma mark Actions

// Applies to the rows the current search shows.
- (void)selectWhere:(BOOL (^)(WQCacheItem *item))rule
{
    for (WQCacheItem *it in self.visibleItems) it.selected = rule(it);
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)confirmClean
{
    NSMutableArray<WQCacheItem *> *selected = [NSMutableArray new];
    unsigned long long sel = 0;
    for (WQCacheItem *item in _items) {
        if (!item.selected) continue;
        [selected addObject:item];
        sel += item.bytes;
    }
    if (!selected.count) return;
    NSString *msg = [NSString stringWithFormat:@"%@, about %@? This cannot be undone.",
                     WQCacheConfirmationScope(selected), wq_size_text(sel)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clean caches?" message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clean" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self clean];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clean
{
    NSArray<WQCacheItem *> *selected = [_items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"selected == YES"]];
    _cleaning = YES;
    [self updateButtons];
    [self setStatus:@"Cleaning…"];
    dispatch_async(wq_io(), ^{
        unsigned long long freed = 0;
        BOOL allOk = YES;
        NSString *validationFailure = nil;
        for (WQCacheItem *item in selected) {
            NSString *reason = nil;
            if (!WQCacheValidateItem(item, &reason)) {
                allOk = NO;
                validationFailure = validationFailure ?: [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"identity changed"];
                wq_log(@"clean: refusing %@ because %@", item.name, reason ?: @"identity validation failed");
            }
        }
        if (validationFailure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_cleaning = NO;
                self->_scanLimited = YES;
                self->_status = nil;
                self->_result = [NSString stringWithFormat:@"Clean cancelled: %@. Scan again before retrying.", validationFailure];
                [self.tableView reloadData];
                [self updateButtons];
            });
            return;
        }
        NSUInteger i = 0;
        for (WQCacheItem *item in selected) {
            i++;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setStatus:[NSString stringWithFormat:@"Cleaning %lu of %lu: %@",
                                 (unsigned long)i, (unsigned long)selected.count, item.name]];
            });
            for (WQCacheTargetRecord *record in item.targetRecords) {
                NSString *reason = nil;
                if (!WQCacheValidateItem(item, &reason)) {
                    allOk = NO;
                    validationFailure = [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"identity changed"];
                    wq_log(@"clean: stopped before %@ because %@", record.path, reason ?: @"identity validation failed");
                    break;
                }
                if (!wq_purge_contents(record.path, &freed)) allOk = NO;
            }
            if (validationFailure) break;
        }
        wq_log(@"clean: freed %llu bytes, allOk=%d", freed, allOk);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_cleaning = NO;
            if (validationFailure) {
                self->_scanLimited = YES;
                self->_status = nil;
                self->_result = [NSString stringWithFormat:@"Clean stopped: %@. Scan again before retrying.", validationFailure];
                [self.tableView reloadData];
                [self updateButtons];
            } else {
                self->_status = nil;
                [self scan];
                self->_result = [NSString stringWithFormat:@"Freed %@.%@", wq_size_text(freed),
                                 allOk ? @"" : @" Some items could not be removed (see Log)."];
            }
        });
    });
}

@end
