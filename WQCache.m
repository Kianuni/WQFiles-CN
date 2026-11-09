//
//  WQCache.m
//  WQ Files cache cleaner
//

#import "WQCache.h"
#import "WQDir.h"
#import "WQUI.h"
#import "WQAccess.h"

#pragma mark - Cache cleaner

@interface WQCacheItem : NSObject
@property (nonatomic, copy) NSString *name;        // app name or "Crash Logs"
@property (nonatomic, copy) NSString *bundleID;    // for the icon; nil for logs
@property (nonatomic, copy) NSArray<NSString *> *targets;  // dirs to purge
@property (nonatomic) unsigned long long cacheBytes;
@property (nonatomic) unsigned long long tempBytes;
@property (nonatomic) BOOL selected;
@property (nonatomic, readonly) unsigned long long bytes;
@end
@implementation WQCacheItem
- (unsigned long long)bytes { return self.cacheBytes + self.tempBytes; }
@end

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
    BOOL _scanning, _cleaning;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
}

static NSString *const kCrashLogsPath =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs/CrashReporter";

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
    UIBarButtonItem *clean = [[UIBarButtonItem alloc] initWithTitle:@"Clean" style:UIBarButtonItemStyleDone
                                                             target:self action:@selector(confirmClean)];
    clean.enabled = n > 0;
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
    _result = nil;
    [self updateButtons];
    [self setStatus:@"Finding apps…"];
    dispatch_async(wq_io(), ^{
        NSMutableArray<WQCacheItem *> *items = [NSMutableArray new];
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
                wq_grant(c);  // one token for the whole container
                NSString *caches = [c stringByAppendingPathComponent:@"Library/Caches"];
                NSString *tmp = [c stringByAppendingPathComponent:@"tmp"];
                unsigned long long cacheBytes = wq_dir_size(caches), tempBytes = wq_dir_size(tmp);
                if (cacheBytes + tempBytes < 64 * 1024) continue;
                WQCacheItem *item = [WQCacheItem new];
                NSString *bid = wq_container_label(c);
                item.bundleID = bid;
                item.name = wq_display_name(bid) ?: bid ?: c.lastPathComponent;
                item.targets = @[caches, tmp];
                item.cacheBytes = cacheBytes;
                item.tempBytes = tempBytes;
                item.selected = YES;
                [items addObject:item];
            }
        }
        if (cancellation.isCancelled) return;
        unsigned long long crash = wq_dir_size(kCrashLogsPath);
        if (crash > 0) {
            WQCacheItem *logs = [WQCacheItem new];
            logs.name = @"Crash Logs";
            logs.targets = @[kCrashLogsPath];
            logs.cacheBytes = crash;
            logs.selected = YES;
            [items addObject:logs];
        }
        [items sortUsingComparator:^NSComparisonResult(WQCacheItem *a, WQCacheItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || cancellation.isCancelled) return;
            self->_items = items;
            self->_scanning = NO;
            self->_status = nil;
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
    return @"Clears each app's Library/Caches and tmp. Apps rebuild their caches as you use them; some keep "
            "offline content (music, maps, downloads) there and will download it again. No backup is kept.";
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
    cell.detailLabel.text = item.bundleID
        ? [NSString stringWithFormat:@"cache %@ · temp %@", wq_size_text(item.cacheBytes), wq_size_text(item.tempBytes)]
        : @"osanalytics";
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
    unsigned long long sel = 0; NSUInteger n = 0;
    for (WQCacheItem *it in _items) if (it.selected) { sel += it.bytes; n++; }
    if (!n) return;
    NSString *msg = [NSString stringWithFormat:@"Delete the cache and temp files of %lu item%@, about %@? This cannot be undone.",
                     (unsigned long)n, n == 1 ? @"" : @"s", wq_size_text(sel)];
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
        NSUInteger i = 0;
        for (WQCacheItem *item in selected) {
            i++;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setStatus:[NSString stringWithFormat:@"Cleaning %lu of %lu: %@",
                                 (unsigned long)i, (unsigned long)selected.count, item.name]];
            });
            for (NSString *dir in item.targets)
                if (!wq_purge_contents(dir, &freed)) allOk = NO;
        }
        wq_log(@"clean: freed %llu bytes, allOk=%d", freed, allOk);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_cleaning = NO;
            self->_status = nil;
            [self scan];
            self->_result = [NSString stringWithFormat:@"Freed %@.%@", wq_size_text(freed),
                             allOk ? @"" : @" Some items could not be removed (see Log)."];
        });
    });
}

@end

