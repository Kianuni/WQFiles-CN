//
//  main.m
//  WQ Files
//
//  Proof-of-concept file browser for iOS 27 that reaches other containers
//  through the worse_query sandbox escape by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//  This app is GPL-3.0-or-later as well (see LICENSE).
//

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "WQAccess.h"
#import "WQUI.h"
#import "WQSharing.h"
#import "WQDir.h"
#import "WQApps.h"
#import "WQCache.h"
#import "WQCore.h"
#import "WQPlistEditor.h"
#import "WQHexViewer.h"

static BOOL wq_looks_like_uuid(NSString *name)
{
    return name.length == 36 && [[NSUUID alloc] initWithUUIDString:name] != nil;
}

#pragma mark - Item

@interface WQItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *bundleID;  // for the app icon
@property (nonatomic) BOOL isDir;
@property (nonatomic) BOOL isLink;
@property (nonatomic) unsigned long long size;
@property (nonatomic) mode_t mode;
@property (nonatomic) uid_t uid;
@property (nonatomic, strong) NSDate *modified;
@end

@implementation WQItem
@end

#pragma mark - File viewer

typedef NS_ENUM(NSInteger, WQOpenMode) { WQOpenAuto, WQOpenPlist, WQOpenText, WQOpenHex };
// Opens a file in the fitting viewer (Auto: chosen from its first bytes).
static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode);

typedef NS_ENUM(NSInteger, WQViewKind) { WQViewText, WQViewPlist, WQViewImage, WQViewHex };

@interface WQFileViewController : UIViewController <UITextViewDelegate, WQUnsavedEditing>
@property (nonatomic) BOOL readOnly;
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation WQFileViewController {
    NSString *_path;
    UITextView *_textView;
    UIImageView *_imageView;
    UIBarButtonItem *_editButton;
    WQViewKind _kind;
    NSPropertyListFormat _plistFormat;
    BOOL _truncated;
    WQEditState *_editState;
    NSDictionary<NSString *, NSNumber *> *_version;
}

static const NSUInteger kViewLimit = 4 * 1024 * 1024;
static const NSUInteger kHexLimit = 64 * 1024;

- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _path = [path copy];
        _editState = [WQEditState new];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _textView.editable = NO;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.smartQuotesType = UITextSmartQuotesTypeNo;
    _textView.smartDashesType = UITextSmartDashesTypeNo;
    _textView.alwaysBounceVertical = YES;
    _textView.delegate = self;
    [self.view addSubview:_textView];
    __weak typeof(self) weakSelf = self;
    self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
    _imageView = [UIImageView new];
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.hidden = YES;
    [self.view addSubview:_imageView];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    for (UIView *v in @[_textView, _imageView]) {
        [NSLayoutConstraint activateConstraints:@[
            [v.topAnchor constraintEqualToAnchor:g.topAnchor],
            [v.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
            [v.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [v.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        ]];
    }
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                           target:self action:@selector(share:)];
    UIMenu *openAs = [UIMenu menuWithTitle:@"Open As" children:@[
        [UIAction actionWithTitle:@"Plist Editor" image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenPlist]; }],
        [UIAction actionWithTitle:@"Hex Viewer" image:[UIImage systemImageNamed:@"number"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenHex]; }],
    ]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:openAs];
    self.navigationItem.rightBarButtonItems = @[share, more];
    _textView.text = @"Loading…";
    [self load];
}

- (void)load
{
    NSString *path = _path;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        struct stat st;
        BOOL exists = wq_stat(path, &st);
        NSDictionary *__unused before = wq_file_version(path);
        NSData *data = wq_read(path, kViewLimit + 1, &error);
        NSDictionary *version = wq_file_version(path);
        if (data && (!before || ![before isEqualToDictionary:version])) {
            data = nil;
            error = @"The file changed while it was being read. Open it again.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_version = version;
            if (!data) {
                NSString *hint = wq_permission_hint(path, NO);
                self->_textView.text = [NSString stringWithFormat:@"Cannot read this file.\n\n%@", hint ?: error];
                return;
            }
            NSString *info = exists
                ? [NSString stringWithFormat:@"%@ · mode %o · uid %u", wq_size_text((unsigned long long)st.st_size),
                   st.st_mode & 07777, st.st_uid]
                : @"";
            self.navigationItem.prompt = info.length ? info : nil;
            if (wq_permission_hint(path, YES)) self->_readOnly = YES;   // only the owner may write it
            [self show:data];
        });
    });
}

- (void)show:(NSData *)all
{
    _truncated = all.length > kViewLimit;
    NSData *data = _truncated ? [all subdataWithRange:NSMakeRange(0, kViewLimit)] : all;

    if (!_truncated) {
        NSPropertyListFormat format = 0;
        id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:&format error:nil];
        if (plist) {
            NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0
                                                                    options:0 error:nil];
            NSString *text = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : nil;
            if (text) {
                _kind = WQViewPlist;
                _plistFormat = format;
                _textView.text = text;
                if (!_readOnly) [self enableEditing];
                return;
            }
        }
    }
    UIImage *image = [UIImage imageWithData:data];
    if (image) {
        _kind = WQViewImage;
        _imageView.image = image;
        _imageView.hidden = NO;
        _textView.hidden = YES;
        return;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text && ![text containsString:@"\0"]) {
        _kind = WQViewText;
        _textView.text = text;
        if (!_truncated && !_readOnly) [self enableEditing];
        return;
    }
    _kind = WQViewHex;
    _textView.text = [self hexDump:data];
}

- (NSString *)hexDump:(NSData *)data
{
    NSUInteger len = MIN(data.length, kHexLimit);
    const uint8_t *b = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:len * 4];
    for (NSUInteger off = 0; off < len; off += 16) {
        [out appendFormat:@"%08lx  ", (unsigned long)off];
        NSMutableString *ascii = [NSMutableString new];
        for (NSUInteger i = 0; i < 16; i++) {
            if (off + i < len) {
                uint8_t c = b[off + i];
                [out appendFormat:@"%02x ", c];
                [ascii appendFormat:@"%c", (c >= 0x20 && c < 0x7f) ? c : '.'];
            } else {
                [out appendString:@"   "];
            }
        }
        [out appendFormat:@" %@\n", ascii];
    }
    if (data.length > len || _truncated) [out appendString:@"\n… (only the beginning is shown)\n"];
    return out;
}

- (void)updateEditButton
{
    _editButton.title = _textView.editable ? @"Save" : @"Edit";
    _editButton.style = _textView.editable ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain;
    _editButton.enabled = !_editState.saving;
}

- (void)enableEditing
{
    if (_editButton) return;
    _editButton = [[UIBarButtonItem alloc] initWithTitle:@"Edit" style:UIBarButtonItemStylePlain
                                                  target:self action:@selector(toggleEdit:)];
    NSArray *items = self.navigationItem.rightBarButtonItems;
    self.navigationItem.rightBarButtonItems = [items arrayByAddingObject:_editButton];
}

- (void)textViewDidChange:(UITextView *)textView
{
    if (_editState.saving) return;
    [_editState noteChange];
}

- (BOOL)blockWhileSaving
{
    if (!_editState.saving) return NO;
    wq_alert(self, @"Save in progress", @"Wait for the current save to finish before leaving or making more changes.");
    return YES;
}

- (BOOL)wq_needsLeaveConfirmation
{
    return _editState.dirty || _editState.saving;
}

- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!_editState.dirty) { proceed(); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Discard changes?"
        message:@"Your text changes have not been saved." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Discard" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self->_editState discard];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        proceed();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)leave
{
    [self confirmLeaveThen:^{ [self.navigationController popViewControllerAnimated:YES]; }];
}

- (void)toggleEdit:(UIBarButtonItem *)sender
{
    if ([self blockWhileSaving]) return;
    if (!_textView.editable) {
        _textView.editable = YES;
        [self updateEditButton];
        [_textView becomeFirstResponder];
        return;
    }
    if (!_editState.dirty) {
        _textView.editable = NO;
        [_textView resignFirstResponder];
        [self updateEditButton];
        return;
    }
    NSData *newData = nil;
    if (_kind == WQViewPlist) {
        NSData *xml = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id plist = xml ? [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:&error] : nil;
        if (!plist) {
            wq_alert(self, @"Not a valid property list", error.localizedDescription ?: @"Check the XML.");
            return;
        }
        newData = [NSPropertyListSerialization dataWithPropertyList:plist format:_plistFormat options:0 error:&error];
        if (!newData) {
            wq_alert(self, @"Cannot encode", error.localizedDescription ?: @"");
            return;
        }
    } else {
        newData = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!newData) {
        wq_alert(self, @"Cannot encode", @"The text could not be encoded as UTF-8.");
        return;
    }
    NSString *message = [NSString stringWithFormat:@"%@ will be overwritten in place. The current version is backed up to Backups first.", _path];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Save changes?" message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        NSUInteger savedRevision = [self->_editState beginSave];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        NSString *path = self->_path;
        dispatch_async(wq_io(), ^{
            NSString *error = nil;
            BOOL ok = wq_write_if_unchanged(path, newData, self->_version, &error);
            NSDictionary *newVersion = ok ? wq_file_version(path) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_editState finishSave:ok revision:savedRevision];
                if (ok) self->_version = newVersion;
                self->_textView.editable = self->_editState.dirty;
                [self updateEditButton];
                if (!ok) wq_alert(self, @"Save failed", error ?: wq_permission_hint(path, YES) ?: @"Unknown error");
            });
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)share:(UIBarButtonItem *)sender
{
    wq_share(self, _path, nil);
}

- (void)reopenAs:(WQOpenMode)mode
{
    [self confirmLeaveThen:^{
        UINavigationController *nav = self.navigationController;
        NSString *path = self->_path;
        BOOL readOnly = self->_readOnly;
        [nav popViewControllerAnimated:NO];
        wq_open_file(nav, path, readOnly, mode);
    }];
}

@end

#pragma mark - Choosing a viewer

static WQOpenMode wq_sniff(NSData *head)
{
    const uint8_t *b = head.bytes;
    NSUInteger n = head.length;
    if (n >= 7 && memcmp(b, "bplist0", 7) == 0) return WQOpenPlist;
    if ((n >= 8 && memcmp(b, "\x89PNG", 4) == 0) || (n >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
        (n >= 4 && memcmp(b, "GIF8", 4) == 0) || (n >= 12 && memcmp(b + 4, "ftyp", 4) == 0))
        return WQOpenText;   // images: the file viewer renders them
    if (n == 0) return WQOpenText;
    if (memchr(b, 0, n)) return WQOpenHex;
    NSString *text = nil;
    for (NSUInteger cut = 0; cut < 4 && !text && cut < n; cut++)   // the sample may end mid-character
        text = [[NSString alloc] initWithBytes:b length:n - cut encoding:NSUTF8StringEncoding];
    if (!text) return WQOpenHex;
    if ([text containsString:@"<plist"] || [text containsString:@"<!DOCTYPE plist"]) return WQOpenPlist;
    return WQOpenText;
}

static NSUInteger wq_open_generation;

static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode)
{
    // All calls originate on the main thread. A newer explicit or automatic
    // open invalidates older sniff requests, and leaving the originating screen
    // also prevents a late push.
    NSUInteger request = ++wq_open_generation;
    UIViewController *origin = nav.topViewController;
    void (^push)(WQOpenMode) = ^(WQOpenMode m) {
        if (request != wq_open_generation || nav.topViewController != origin) return;
        UIViewController *vc;
        if (m == WQOpenPlist) {
            WQPlistEditorViewController *editor = [[WQPlistEditorViewController alloc] initWithPath:path readOnly:readOnly];
            __weak UINavigationController *weakNav = nav;
            editor.openAsText = ^{ wq_open_file(weakNav, path, readOnly, WQOpenText); };
            editor.openAsHex = ^{ wq_open_file(weakNav, path, readOnly, WQOpenHex); };
            vc = editor;
        } else if (m == WQOpenHex) {
            vc = [[WQHexViewController alloc] initWithPath:path readOnly:readOnly];
        } else {
            WQFileViewController *file = [[WQFileViewController alloc] initWithPath:path];
            file.readOnly = readOnly;
            vc = file;
        }
        [nav pushViewController:vc animated:YES];
    };
    if (mode != WQOpenAuto) { push(mode); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *head = wq_permission_hint(path, NO) ? nil : wq_read_range(path, 0, 4096, NULL);
        WQOpenMode m = head ? wq_sniff(head) : WQOpenText;   // unreadable: the file viewer shows why
        dispatch_async(dispatch_get_main_queue(), ^{ push(m); });
    });
}

#pragma mark - Folder

@implementation WQDirViewController {
    NSString *_path;
    NSArray<WQItem *> *_all;     // everything in the folder
    NSArray<WQItem *> *_items;   // what the search lets through (shown)
    NSString *_query;
    UILabel *_pathLabel;
    NSString *_scanStatus;
    CGFloat _headerWidth;
    NSString *_error;
    BOOL _labels;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
}

- (instancetype)initWithPath:(NSString *)path title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = [path copy];
        self.title = title ?: (path.lastPathComponent.length ? path.lastPathComponent : @"/");
        // Container parents: show bundle/group identifiers instead of UUIDs.
        NSString *parent = path.lastPathComponent;
        _labels = [@[@"Application", @"AppGroup", @"PluginKitPlugin", @"InternalDaemon", @"System"] containsObject:parent];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    __weak typeof(self) weakSelf = self;
    NSString *path = _path;
    NSMutableArray<UIMenuElement *> *menuItems = [NSMutableArray new];
    if (!self.readOnly) {
        [menuItems addObject:[UIAction actionWithTitle:@"New Folder" image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf promptNewFolder]; }]];
        [menuItems addObject:[UIAction actionWithTitle:@"Import File" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf importFile]; }]];
    }
    [menuItems addObject:[UIAction actionWithTitle:@"Copy Path" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                          handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = path; }]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                                               menu:[UIMenu menuWithChildren:menuItems]];
    [self updateHeader];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = _labels ? @"Search names and bundle IDs" : @"Search this folder";
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (!_all && _scanCancellation.isCancelled) [self reload];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_scanCancellation cancel];
}

// Device strip, then the full path in normal-size text that wraps at the
// slashes (the navigation bar's prompt shrank it until unreadable). Tap to copy.
- (void)updateHeader
{
    CGFloat width = self.tableView.bounds.size.width ?: self.view.bounds.size.width;
    if (!_pathLabel) {
        _pathLabel = [UILabel new];
        _pathLabel.numberOfLines = 0;
        _pathLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        _pathLabel.textColor = UIColor.secondaryLabelColor;
        _pathLabel.userInteractionEnabled = YES;
        [_pathLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyPath)]];
    }
    // Zero-width spaces after each slash let lines break between components.
    NSString *breakable = [_path stringByReplacingOccurrencesOfString:@"/" withString:@"/\u200B"];
    _pathLabel.text = _scanStatus ? [NSString stringWithFormat:@"%@\n%@", breakable, _scanStatus] : breakable;
    CGFloat side = 16, top = 42;
    CGSize fit = [_pathLabel sizeThatFits:CGSizeMake(width - 2 * side, CGFLOAT_MAX)];
    UIView *box = wq_device_header(width);
    box.frame = CGRectMake(0, 0, width, top + ceil(fit.height) + 10);
    _pathLabel.frame = CGRectMake(side, top, width - 2 * side, ceil(fit.height));
    [box addSubview:_pathLabel];
    _headerWidth = width;
    self.tableView.tableHeaderView = box;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (fabs(self.tableView.bounds.size.width - _headerWidth) > 0.5) [self updateHeader];
}

- (void)copyPath
{
    UIPasteboard.generalPasteboard.string = _path;
    _scanStatus = @"Path copied";
    [self updateHeader];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self->_scanStatus isEqualToString:@"Path copied"]) { self->_scanStatus = nil; [self updateHeader]; }
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    _query = q.length ? q : nil;
    [self applyFilter];
    [self.tableView reloadData];
}

// App name, bundle or group ID, or file name; case and accents ignored.
- (void)applyFilter
{
    if (!_query) { _items = _all; return; }
    NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSString *q = _query;
    _items = [_all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQItem *item, NSDictionary *__unused b) {
        for (NSString *field in @[item.label ?: @"", item.name ?: @"", item.bundleID ?: @""])
            if ([field rangeOfString:q options:opts].location != NSNotFound) return YES;
        return NO;
    }]];
}

- (void)reload
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    NSString *path = _path;
    BOOL labels = _labels;
    BOOL enumerable = [@[@"/private/var/mobile/Containers/Data/Application",
                         @"/var/mobile/Containers/Data/Application",
                         @"/private/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/private/var/mobile/Containers/Data/InternalDaemon",
                         @"/var/mobile/Containers/Data/InternalDaemon"] containsObject:path];
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSArray *names = wq_list(path, &error);
        NSArray *childPaths = nil;
        // Parent gives no token on 27.x: discover children with fsgetpath.
        if (!names && enumerable && !cancellation.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = @"Scanning inodes…";
                [self updateHeader];
            });
            childPaths = wq_enumerate(path, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_scanStatus = [NSString stringWithFormat:@"Scanning inodes… %lld%% · %lu found",
                                         (long long)(done * 100 / total), (unsigned long)f];
                    [self updateHeader];
                });
            });
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = nil;
                [self updateHeader];
            });
        }
        if (cancellation.isCancelled) return;
        NSMutableArray<WQItem *> *items = [NSMutableArray new];
        NSArray *entries = names ?: childPaths;
        BOOL haveFullPaths = names == nil;
        for (NSString *entry in entries) {
            if (cancellation.isCancelled) return;
            WQItem *item = [WQItem new];
            item.name = haveFullPaths ? entry.lastPathComponent : entry;
            item.path = haveFullPaths ? entry : [path stringByAppendingPathComponent:entry];
            NSString *name = item.name;
            // Enumerated containers need a token before they can be stat'd.
            if (haveFullPaths) {
                item.isDir = YES;
                BOOL token = wq_grant(item.path);
                NSString *bid = token ? wq_container_label(item.path) : nil;
                item.bundleID = bid;
                item.label = token ? (wq_display_name(bid) ?: bid ?: @"(no label)") : @"NO TOKEN";
            }
            struct stat st;
            if (lstat(item.path.fileSystemRepresentation, &st) == 0) {
                item.isLink = S_ISLNK(st.st_mode);
                item.isDir = S_ISDIR(st.st_mode);
                if (item.isLink) {
                    struct stat target;
                    if (stat(item.path.fileSystemRepresentation, &target) == 0) item.isDir = S_ISDIR(target.st_mode);
                }
                item.size = (unsigned long long)st.st_size;
                item.mode = st.st_mode;
                item.uid = st.st_uid;
                item.modified = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec];
            }
            if (!haveFullPaths && labels && item.isDir && wq_looks_like_uuid(name)) {
                NSString *bid = wq_container_label(item.path);
                item.bundleID = bid;
                item.label = wq_display_name(bid) ?: bid;
            }
            if (!haveFullPaths && item.isDir && !item.bundleID) {
                // App backups: AppBackups/<bundle id>/...
                if ([path.lastPathComponent isEqualToString:@"AppBackups"]) {
                    item.bundleID = name;
                    item.label = wq_display_name(name) ?: name;
                }
                // File backups mirror the original path; label container UUIDs
                // from the live container they came from.
                NSRange r = [item.path rangeOfString:@"/private/var/mobile/Containers/"];
                if (r.location != NSNotFound && r.location > 0 && wq_looks_like_uuid(name)) {
                    NSString *live = [item.path substringFromIndex:r.location];
                    NSString *bid = wq_container_label(live);
                    if (bid) { item.bundleID = bid; item.label = wq_display_name(bid) ?: bid; }
                }
                if ([path isEqualToString:wq_backup_root().stringByDeletingLastPathComponent]) {
                    if ([name isEqualToString:@"Backups"]) item.label = @"File Backups";
                    if ([name isEqualToString:@"AppBackups"]) item.label = @"App Backups";
                }
            }
            [items addObject:item];
        }
        [items sortUsingComparator:^NSComparisonResult(WQItem *a, WQItem *b) {
            if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
            return [(a.label ?: a.name) localizedCaseInsensitiveCompare:(b.label ?: b.name)];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || cancellation.isCancelled) return;
            self->_all = items;
            [self applyFilter];
            self->_error = (names || childPaths.count) ? nil : error;
            [self.refreshControl endRefreshing];
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _error ? 1 : (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_error) {
        c.text = @"Cannot open this folder";
        BOOL container = [_path containsString:@"/Containers/"] || [_path containsString:@"/SystemGroup/"];
        c.secondaryText = container ? _error
            : [NSString stringWithFormat:@"%@\n\nThis method only opens containers. Use App Data, App Groups, "
               "Extension Data, Internal Daemons or System Groups for the folders inside /private/var.", _error];
        c.secondaryTextProperties.numberOfLines = 0;
        c.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQItem *item = _items[(NSUInteger)indexPath.row];
    c.text = item.label ?: item.name;
    NSString *date = item.modified ? [NSDateFormatter localizedStringFromDate:item.modified
                                                                   dateStyle:NSDateFormatterShortStyle
                                                                   timeStyle:NSDateFormatterShortStyle] : @"";
    NSString *detail = item.isDir ? date : [NSString stringWithFormat:@"%@ · %@", wq_size_text(item.size), date];
    if (item.label) detail = [NSString stringWithFormat:@"%@\n%@", item.name, detail];
    if (item.isLink) detail = [@"symlink · " stringByAppendingString:detail];
    c.secondaryText = detail;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    UIImage *appIcon = item.bundleID ? wq_app_icon(item.bundleID) : nil;
    c.image = appIcon ?: [UIImage systemImageNamed:item.isDir ? @"folder.fill" : (item.isLink ? @"link" : @"doc")];
    if (appIcon) c.imageProperties.maximumSize = CGSizeMake(36, 36);
    cell.contentConfiguration = c;
    cell.accessoryType = item.isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_error) return;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    UIViewController *next;
    if (item.isDir) {
        WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:item.path title:item.label ?: item.name];
        dir.readOnly = self.readOnly;
        next = dir;
    } else {
        wq_open_file(self.navigationController, item.path, self.readOnly, WQOpenAuto);
        return;
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (_error) return nil;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        NSMutableArray *actions = [NSMutableArray new];
        if (item.isDir) {
            [actions addObject:[UIAction actionWithTitle:@"Share as ZIP (AirDrop…)" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (weakSelf) wq_share_folder(weakSelf, item.path, nil, cell);
            }]];
        }
        if (!item.isDir) {
            [actions addObject:[UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (weakSelf) wq_share(weakSelf, item.path, cell);
            }]];
            NSString *original = wq_backup_original_path(item.path);
            if (original) {
                [actions addObject:[UIAction actionWithTitle:@"Restore to Original Location"
                                                       image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    [weakSelf restoreBackup:item.path to:original];
                }]];
            }
        }
        if (!item.isDir) {
            BOOL ro = weakSelf.readOnly;
            UINavigationController *nav = weakSelf.navigationController;
            [actions addObject:[UIMenu menuWithTitle:@"Open As" image:[UIImage systemImageNamed:@"arrow.up.forward.app"] identifier:nil
                                             options:0 children:@[
                [UIAction actionWithTitle:@"Plist Editor" image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                                  handler:^(UIAction *__unused a) { wq_open_file(nav, item.path, ro, WQOpenPlist); }],
                [UIAction actionWithTitle:@"Text / Image" image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil
                                  handler:^(UIAction *__unused a) { wq_open_file(nav, item.path, ro, WQOpenText); }],
                [UIAction actionWithTitle:@"Hex Viewer" image:[UIImage systemImageNamed:@"number"] identifier:nil
                                  handler:^(UIAction *__unused a) { wq_open_file(nav, item.path, ro, WQOpenHex); }],
            ]]];
        }
        [actions addObject:[UIAction actionWithTitle:@"Copy Path" image:[UIImage systemImageNamed:@"doc.on.doc"]
                                          identifier:nil handler:^(UIAction *__unused a) {
            UIPasteboard.generalPasteboard.string = item.path;
        }]];
        if (item.label) {
            [actions addObject:[UIAction actionWithTitle:@"Copy Identifier" image:[UIImage systemImageNamed:@"tag"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                UIPasteboard.generalPasteboard.string = item.label;
            }]];
        }
        if (!weakSelf.readOnly) {
            [actions addObject:[UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"]
                                              identifier:nil handler:^(UIAction *__unused a) { [weakSelf promptRename:item]; }]];
            UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *__unused a) { [weakSelf confirmDelete:item]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:del];
        }
        return [UIMenu menuWithChildren:actions];
    }];
}

#pragma mark Actions

- (void)runIO:(BOOL (^)(NSString **error))work failure:(NSString *)failureTitle
{
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        BOOL ok = work(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) wq_alert(self, failureTitle, error ?: @"Unknown error");
            [self reload];
        });
    });
}

- (void)promptNewFolder
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"New Folder" message:_path
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"Name"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [self->_path stringByAppendingPathComponent:name];
        [self runIO:^BOOL(NSString **error) { return wq_create_dir(path, error); } failure:@"Cannot create folder"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptRename:(WQItem *)item
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename" message:item.path
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = item.name; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        [self runIO:^BOOL(NSString **error) { return wq_rename(item.path, name, error); } failure:@"Cannot rename"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDelete:(WQItem *)item
{
    NSString *message = item.isDir
        ? [NSString stringWithFormat:@"%@\n\nOnly empty folders can be deleted.", item.path]
        : [NSString stringWithFormat:@"%@\n\nA copy is kept in Backups.", item.path];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete \"%@\"?", item.name]
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) { return wq_delete(item.path, error); } failure:@"Cannot delete"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreBackup:(NSString *)backup to:(NSString *)original
{
    NSString *message = [NSString stringWithFormat:@"Write this backup back to\n%@?\n\nIf a file is there now, it is backed up first.", original];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) {
            struct stat st;
            return wq_stat(original, &st) ? wq_write_from_file(original, backup, error)
                                          : wq_create_file_from(original, backup, error);
        } failure:@"Restore failed"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importFile
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    // The picker hands over a local copy (asCopy). It is streamed into place,
    // never read into memory, and the existence check runs off the main thread.
    NSString *source = urls.firstObject.path;
    if (!source) return;
    NSString *dest = [_path stringByAppendingPathComponent:source.lastPathComponent];
    void (^cleanup)(void) = ^{ [NSFileManager.defaultManager removeItemAtPath:source error:nil]; };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct stat st;
        BOOL exists = wq_stat(dest, &st);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!exists) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_create_file_from(dest, source, error);
                    cleanup();
                    return ok;
                } failure:@"Import failed"];
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Replace existing file?"
                message:[NSString stringWithFormat:@"%@ already exists. It is backed up before being replaced.", dest]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction *__unused a) { cleanup(); }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Replace" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_write_from_file(dest, source, error);
                    cleanup();
                    return ok;
                } failure:@"Import failed"];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end

#pragma mark - System groups

// The SystemGroup parent gets no token on 27.0.1, so it cannot be listed.
// Known container names are checked one by one (lstat works without access).
@interface WQSystemGroupsViewController : UITableViewController
@end

@implementation WQSystemGroupsViewController {
    NSArray<NSString *> *_names;
    BOOL _listed;
}

static NSString *const kSystemGroupRoot = @"/private/var/containers/Shared/SystemGroup";

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"System Groups";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self action:@selector(tryName)];
    dispatch_async(wq_io(), ^{
        NSArray *listed = wq_list(kSystemGroupRoot, NULL);
        NSArray *names = listed;
        if (!names) {
            NSArray *known = @[
                @"systemgroup.com.apple.configurationprofiles", @"systemgroup.com.apple.mobilegestaltcache",
                @"systemgroup.com.apple.osanalytics", @"systemgroup.com.apple.lsd.iconscache",
                @"systemgroup.com.apple.lsd.identifiers", @"systemgroup.com.apple.ManagedSettings",
                @"systemgroup.com.apple.sharedpclogging", @"systemgroup.com.apple.media.shared.books",
                @"systemgroup.com.apple.nsurlstoragedresources", @"systemgroup.com.apple.pisco.suinfo",
                @"systemgroup.com.apple.icloud.findmydevice.managed", @"systemgroup.com.apple.mobilestoragemounter",
                @"systemgroup.com.apple.mobileactivationd", @"systemgroup.com.apple.sensorkit",
                @"systemgroup.com.apple.powerlog", @"systemgroup.com.apple.diagnosticextensionsd",
                @"systemgroup.com.apple.mediaanalysisd", @"systemgroup.com.apple.translationd",
                @"systemgroup.com.apple.chronod", @"systemgroup.com.apple.coreaudio",
                @"systemgroup.com.apple.ManagedConfiguration.ExternalTrust", @"systemgroup.com.apple.cfprefsd",
            ];
            NSMutableArray *found = [NSMutableArray new];
            for (NSString *name in known) {
                struct stat st;
                NSString *p = [kSystemGroupRoot stringByAppendingPathComponent:name];
                if (lstat(p.fileSystemRepresentation, &st) == 0) [found addObject:name];
            }
            names = found;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_listed = listed != nil;
            self->_names = [names sortedArrayUsingSelector:@selector(compare:)];
            [self.tableView reloadData];
        });
    });
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (!_names) return @"Loading…";
    return _listed ? nil : @"This folder cannot be listed on this iOS version. Known names that exist are shown; tap + to try another name.";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_names.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"g"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"g"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.text = [_names[(NSUInteger)indexPath.row] stringByReplacingOccurrencesOfString:@"systemgroup." withString:@""];
    c.image = [UIImage systemImageNamed:@"folder.fill"];
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = _names[(NSUInteger)indexPath.row];
    [self.navigationController pushViewController:[[WQDirViewController alloc]
        initWithPath:[kSystemGroupRoot stringByAppendingPathComponent:name] title:nil] animated:YES];
}

- (void)tryName
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Open System Group" message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = @"systemgroup.com.apple.";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [kSystemGroupRoot stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0) {
            wq_alert(self, @"Not found", path);
            return;
        }
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil] animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Log

@interface WQLogViewController : UIViewController
@end

@implementation WQLogViewController {
    UITextView *_textView;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Log";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:_textView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                           target:self action:@selector(share:)];
}

// App version, device and iOS first, so a Log someone sends in says where it
// came from.
- (NSString *)fullLog
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"WQ Files %@ (%@)\n%@\n\n%@",
            info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?", wq_device_line(), wq_log_text()];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _textView.text = [self fullLog];
}

- (void)share:(UIBarButtonItem *)sender
{
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[self fullLog]]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

@end

#pragma mark - Navigation

// Adds a Home button next to Back on screens two or more levels deep. Editors
// guard Back, Home and the interactive edge swipe through WQUnsavedEditing.
@interface WQNavigationController : UINavigationController <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@end

@implementation WQNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;
    self.interactivePopGestureRecognizer.delegate = self;
}

- (void)navigationController:(UINavigationController *)nav willShowViewController:(UIViewController *)vc animated:(BOOL)animated
{
    NSUInteger depth = [nav.viewControllers indexOfObject:vc];
    if (depth == NSNotFound || depth < 2) {
        if (vc.navigationItem.leftBarButtonItem.tag == 0x484f4d45) vc.navigationItem.leftBarButtonItem = nil;
        return;
    }
    if (vc.navigationItem.leftBarButtonItem) return;
    UIBarButtonItem *home = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"house"]
                                                             style:UIBarButtonItemStylePlain target:self action:@selector(goHome)];
    home.tag = 0x484f4d45;   // "HOME"
    home.accessibilityLabel = @"Home";
    vc.navigationItem.leftItemsSupplementBackButton = YES;
    vc.navigationItem.leftBarButtonItem = home;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer != self.interactivePopGestureRecognizer) return YES;
    if (self.viewControllers.count <= 1) return NO;
    UIViewController<WQUnsavedEditing> *editor = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    if (![editor conformsToProtocol:@protocol(WQUnsavedEditing)] || !editor.wq_needsLeaveConfirmation) return YES;
    __weak typeof(self) weakSelf = self;
    [editor confirmLeaveThen:^{ [weakSelf popViewControllerAnimated:YES]; }];
    return NO;
}

- (void)goHome
{
    UIViewController<WQUnsavedEditing> *top = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    __weak typeof(self) weakSelf = self;
    void (^home)(void) = ^{ [weakSelf popToRootViewControllerAnimated:YES]; };
    if ([top conformsToProtocol:@protocol(WQUnsavedEditing)]) [top confirmLeaveThen:home];
    else home();
}

@end

#pragma mark - Root

@interface WQRootViewController : UITableViewController
@end

@implementation WQRootViewController {
    NSArray<NSArray<NSString *> *> *_locations;  // title, path, symbol
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"WQ Files";
        _locations = @[
            @[@"App Data", @"/private/var/mobile/Containers/Data/Application", @"square.grid.2x2"],
            @[@"App Groups", @"/private/var/mobile/Containers/Shared/AppGroup", @"square.stack.3d.up"],
            @[@"Extension Data", @"/private/var/mobile/Containers/Data/PluginKitPlugin", @"puzzlepiece.extension"],
            @[@"Internal Daemons", @"/private/var/mobile/Containers/Data/InternalDaemon", @"gearshape.2"],
            @[@"System Data", @"/private/var/containers/Data/System", @"cpu"],
        ];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.tableFooterView = [self authorFooter];
    dispatch_async(wq_io(), ^{
        NSString *recovery = wq_recover_interrupted_restore();
        if (recovery) {
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_alert(self, @"Restore recovery", recovery);
            });
        }
        NSString *group = wq_app_group();
        if (!group) {
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_alert(self, @"No App Group",
                         @"This app needs an App Group to reach other folders. Re-sign it with a tool that keeps the App Group entitlement.");
            });
        }
    });
}

// "by kolbicz" with GitHub and X links, under the last section.
- (UIView *)authorFooter
{
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 128)];
    UILabel *by = [UILabel new];
    by.text = @"WQ Files by kolbicz";
    by.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    by.textColor = UIColor.secondaryLabelColor;

    UIButton *(^link)(NSString *, NSString *, NSString *) = ^UIButton *(NSString *title, NSString *symbol, NSString *url) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
        cfg.title = title;
        cfg.image = [UIImage systemImageNamed:symbol];
        cfg.imagePadding = 6;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.buttonSize = UIButtonConfigurationSizeSmall;
        return [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
        }]];
    };
    UIStackView *links = [[UIStackView alloc] initWithArrangedSubviews:@[
        link(@"GitHub", @"chevron.left.forwardslash.chevron.right", @"https://github.com/kolbicz"),
        link(@"@_kolbicz", @"at", @"https://x.com/_kolbicz"),
    ]];
    links.spacing = 12;

    UIButtonConfiguration *creditCfg = [UIButtonConfiguration plainButtonConfiguration];
    creditCfg.attributedTitle = [[NSAttributedString alloc] initWithString:@"Sandbox escape: worse_query by @forcequitOS"
        attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]}];
    creditCfg.buttonSize = UIButtonConfigurationSizeSmall;
    UIButton *credit = [UIButton buttonWithConfiguration:creditCfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://x.com/forcequitOS"] options:@{} completionHandler:nil];
    }]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[by, links, credit]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
    ]];
    return footer;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? (NSInteger)_locations.count + 1 : 5;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"Containers" : @"Tools";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 1
        ? @"Overwritten and deleted files are copied to Backups first (also visible in the Files app). Long-press a backup to restore it."
        : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"r"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"r"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            c.text = loc[0];
            c.image = [UIImage systemImageNamed:loc[2]];
        } else {
            c.text = @"System Groups";
            c.image = [UIImage systemImageNamed:@"lock.square.stack"];
        }
    } else {
        NSArray *tools = @[@[@"Apps", @"square.grid.3x3"], @[@"Cache Cleaner", @"trash"], @[@"Go to Path…", @"arrow.right.circle"], @[@"Backups", @"clock.arrow.circlepath"], @[@"Log", @"doc.plaintext"]];
        c.text = tools[(NSUInteger)indexPath.row][0];
        c.image = [UIImage systemImageNamed:tools[(NSUInteger)indexPath.row][1]];
    }
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            next = [[WQDirViewController alloc] initWithPath:loc[1] title:loc[0]];
        } else {
            next = [WQSystemGroupsViewController new];
        }
    } else if (indexPath.row == 0) {
        next = [WQAppsViewController new];
    } else if (indexPath.row == 1) {
        next = [WQCacheCleanerViewController new];
    } else if (indexPath.row == 2) {
        [self goToPath];
        return;
    } else if (indexPath.row == 3) {
        [NSFileManager.defaultManager createDirectoryAtPath:wq_backup_root() withIntermediateDirectories:YES attributes:nil error:nil];
        next = [[WQDirViewController alloc] initWithPath:wq_backup_root().stringByDeletingLastPathComponent title:@"Backups"];
    } else {
        next = [WQLogViewController new];
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (void)goToPath
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Go to Path" message:@"A folder or file path"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = UIPasteboard.generalPasteboard.hasStrings && [UIPasteboard.generalPasteboard.string hasPrefix:@"/"]
            ? UIPasteboard.generalPasteboard.string : @"/private/var/";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *path = alert.textFields.firstObject.text.stringByStandardizingPath;
        if (![path hasPrefix:@"/"]) return;
        dispatch_async(wq_io(), ^{
            struct stat st;
            BOOL exists = wq_stat(path, &st);
            BOOL isDir = exists && S_ISDIR(st.st_mode);
            if (exists && S_ISLNK(st.st_mode)) {
                struct stat target;
                isDir = stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!exists) {
                    wq_alert(self, @"Not found", path);
                    return;
                }
                if (!isDir) { wq_open_file(self.navigationController, path, NO, WQOpenAuto); return; }
                [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil]
                                                     animated:YES];
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - App

@interface WQSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WQSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.rootViewController = [[WQNavigationController alloc] initWithRootViewController:[WQRootViewController new]];
    [window makeKeyAndVisible];
    self.window = window;
}

@end

@interface WQAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation WQAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    config.delegateClass = WQSceneDelegate.class;
    return config;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WQAppDelegate.class));
    }
}
