//
//  WQPlistEditor.m
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import "WQPlistEditor.h"
#import "WQAccess.h"
#import "WQCore.h"

typedef NS_ENUM(NSInteger, WQPType) {
    WQPTypeString, WQPTypeInteger, WQPTypeReal, WQPTypeBoolean, WQPTypeDate, WQPTypeData,
    WQPTypeDictionary, WQPTypeArray, WQPTypeUnknown,
};

static WQPType wqp_type(id v)
{
    if ([v isKindOfClass:NSString.class]) return WQPTypeString;
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) return WQPTypeBoolean;
        return CFNumberIsFloatType((__bridge CFNumberRef)v) ? WQPTypeReal : WQPTypeInteger;
    }
    if ([v isKindOfClass:NSDate.class]) return WQPTypeDate;
    if ([v isKindOfClass:NSData.class]) return WQPTypeData;
    if ([v isKindOfClass:NSDictionary.class]) return WQPTypeDictionary;
    if ([v isKindOfClass:NSArray.class]) return WQPTypeArray;
    return WQPTypeUnknown;
}

static NSString *wqp_type_name(WQPType t)
{
    switch (t) {
        case WQPTypeString: return @"String";
        case WQPTypeInteger: return @"Number";
        case WQPTypeReal: return @"Real";
        case WQPTypeBoolean: return @"Boolean";
        case WQPTypeDate: return @"Date";
        case WQPTypeData: return @"Data";
        case WQPTypeDictionary: return @"Dictionary";
        case WQPTypeArray: return @"Array";
        case WQPTypeUnknown: return @"?";
    }
    return @"?";
}

static NSString *wqp_hex(NSData *data, NSUInteger max)
{
    const uint8_t *b = data.bytes;
    NSUInteger n = MIN(data.length, max);
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 3];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:i ? @" %02x" : @"%02x", b[i]];
    if (data.length > max) [s appendString:@" …"];
    return s;
}

static NSISO8601DateFormatter *wqp_dates(void)
{
    static NSISO8601DateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSISO8601DateFormatter new]; });
    return f;
}

static NSString *wqp_summary(id v)
{
    switch (wqp_type(v)) {
        case WQPTypeString: return [v length] ? v : @"(empty)";
        case WQPTypeInteger: case WQPTypeReal: return [v stringValue];
        case WQPTypeBoolean: return [v boolValue] ? @"YES" : @"NO";
        case WQPTypeDate: return [wqp_dates() stringFromDate:v];
        case WQPTypeData: return [NSString stringWithFormat:@"%lu bytes · %@", (unsigned long)[v length], wqp_hex(v, 24)];
        case WQPTypeDictionary: return [NSString stringWithFormat:@"%lu keys", (unsigned long)[v count]];
        case WQPTypeArray: return [NSString stringWithFormat:@"%lu items", (unsigned long)[v count]];
        case WQPTypeUnknown: return [v description];
    }
    return @"";
}

static id wqp_default(WQPType t)
{
    switch (t) {
        case WQPTypeString: return @"";
        case WQPTypeInteger: return @0;
        case WQPTypeReal: return @0.0;
        case WQPTypeBoolean: return @NO;
        case WQPTypeDate: return NSDate.date;
        case WQPTypeData: return [NSData data];
        case WQPTypeDictionary: return [NSMutableDictionary dictionary];
        case WQPTypeArray: return [NSMutableArray array];
        case WQPTypeUnknown: return @"";
    }
    return @"";
}

static void wqp_alert(UIViewController *host, NSString *title, NSString *message)
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:a animated:YES completion:nil];
}

#pragma mark - Document

@interface WQPlistDocument : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) id root;
@property (nonatomic) NSPropertyListFormat format;
@property (nonatomic) BOOL readOnly;
@property (nonatomic, strong) WQEditState *edit;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *version;
@end

@implementation WQPlistDocument
@end

#pragma mark - Editor

@interface WQPlistEditorViewController ()
@property (nonatomic, strong) WQPlistDocument *doc;
@property (nonatomic, strong) id container;   // NSMutableDictionary or NSMutableArray
@property (nonatomic, copy) NSArray *keys;    // sorted keys (dictionary) or nil (array)
@property (nonatomic, copy) NSString *status; // loading / error text
@property (nonatomic) BOOL isRoot;
@end

@implementation WQPlistEditorViewController

- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _doc = [WQPlistDocument new];
        _doc.path = path;
        _doc.readOnly = readOnly;
        _doc.edit = [WQEditState new];
        _isRoot = YES;
        _status = @"Loading…";
        self.title = path.lastPathComponent;
    }
    return self;
}

- (instancetype)initWithDocument:(WQPlistDocument *)doc container:(id)container title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _doc = doc;
        _container = container;
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    if (self.isRoot) {
        __weak typeof(self) weakSelf = self;
        self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
        [self load];
    }
    [self updateBar];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)load
{
    NSString *path = self.doc.path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSDictionary *__unused before = wq_file_version(path);
        NSData *data = wq_read(path, 64 * 1024 * 1024, &error);
        NSDictionary *version = wq_file_version(path);
        if (data && (!before || ![before isEqualToDictionary:version])) {
            data = nil;
            error = @"The file changed while it was being read. Open it again.";
        }
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        NSError *parseError = nil;
        id root = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                  options:NSPropertyListMutableContainersAndLeaves
                                                                   format:&format error:&parseError] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.doc.version = version;
            if (!root) {
                self.status = data ? [NSString stringWithFormat:@"Not a property list: %@", parseError.localizedDescription]
                                   : (wq_permission_hint(path, NO) ?: [NSString stringWithFormat:@"Cannot read this file: %@", error]);
            } else if (![root isKindOfClass:NSMutableDictionary.class] && ![root isKindOfClass:NSMutableArray.class]) {
                // A plist whose root is a single value: wrap it for display only.
                self.doc.root = root;
                self.doc.readOnly = YES;
                self.container = [NSMutableArray arrayWithObject:root];
                self.status = nil;
            } else {
                if (wq_permission_hint(path, YES)) self.doc.readOnly = YES;   // readable, but only the owner may write
                self.doc.root = root;
                self.doc.format = format;
                self.container = root;
                self.status = nil;
            }
            [self refresh];
        });
    });
}

- (void)refresh
{
    if ([self.container isKindOfClass:NSDictionary.class])
        self.keys = [[self.container allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    else
        self.keys = nil;
    [self updateBar];
    [self.tableView reloadData];
}

- (BOOL)isArray
{
    return [self.container isKindOfClass:NSArray.class];
}

- (void)updateBar
{
    NSMutableArray *items = [NSMutableArray array];
    if (!self.doc.readOnly && self.container) {
        UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStyleDone
                                                                target:self action:@selector(save)];
        save.enabled = self.doc.edit.dirty && !self.doc.edit.saving;
        [items addObject:save];
        UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                              target:self action:@selector(add)];
        add.enabled = !self.doc.edit.saving;
        [items addObject:add];
    }
    NSMutableArray *menu = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    if (self.isArray && !self.doc.readOnly && !self.doc.edit.saving && self.container) {
        [menu addObject:[UIAction actionWithTitle:self.tableView.editing ? @"Done Reordering" : @"Reorder Items"
                                            image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil
                                          handler:^(UIAction *__unused a) {
            [weakSelf.tableView setEditing:!weakSelf.tableView.editing animated:YES];
            [weakSelf updateBar];
        }]];
    }
    if (self.openAsText) [menu addObject:[UIAction actionWithTitle:@"Open as XML Text" image:[UIImage systemImageNamed:@"doc.plaintext"]
                                                         identifier:nil handler:^(UIAction *__unused a) { [weakSelf leaveThen:weakSelf.openAsText]; }]];
    if (self.openAsHex) [menu addObject:[UIAction actionWithTitle:@"Open in Hex Viewer" image:[UIImage systemImageNamed:@"number"]
                                                        identifier:nil handler:^(UIAction *__unused a) { [weakSelf leaveThen:weakSelf.openAsHex]; }]];
    if (menu.count)
        [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                           menu:[UIMenu menuWithChildren:menu]]];
    self.navigationItem.rightBarButtonItems = items;
}

#pragma mark Leaving and saving

- (BOOL)wq_needsLeaveConfirmation
{
    return self.doc.edit.dirty || self.doc.edit.saving;
}

- (void)leave
{
    [self leaveThen:nil];
}

- (BOOL)blockWhileSaving
{
    if (!self.doc.edit.saving) return NO;
    wqp_alert(self, @"Save in progress", @"Wait for the current save to finish before leaving or making more changes.");
    return YES;
}

// Asks before throwing away unsaved changes, then pops to the folder and runs `then`.
- (void)leaveThen:(void (^)(void))then
{
    if ([self blockWhileSaving]) return;
    UINavigationController *nav = self.navigationController;
    NSUInteger rootIndex = [nav.viewControllers indexOfObjectPassingTest:^BOOL(UIViewController *vc, NSUInteger __unused i, BOOL *__unused stop) {
        return [vc isKindOfClass:WQPlistEditorViewController.class] && ((WQPlistEditorViewController *)vc).isRoot &&
               ((WQPlistEditorViewController *)vc).doc == self.doc;
    }];
    void (^go)(void) = ^{
        if (rootIndex != NSNotFound && rootIndex > 0)
            [nav popToViewController:nav.viewControllers[rootIndex - 1] animated:then == nil];
        if (then) then();
    };
    if (!self.doc.edit.dirty) { go(); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Discard changes?"
        message:@"Your edits to this property list have not been saved." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Discard" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused x) {
        [self.doc.edit discard];
        go();
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// Home button: ask before throwing away unsaved changes.
- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!self.doc.edit.dirty) { proceed(); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Discard changes?"
        message:@"Your edits to this property list have not been saved." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Discard" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused x) {
        [self.doc.edit discard];
        proceed();
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)save
{
    if ([self blockWhileSaving] || !self.doc.edit.dirty) return;
    WQPlistDocument *doc = self.doc;
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:doc.root format:doc.format options:0 error:&error];
    id check = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
    if (!check) {
        wqp_alert(self, @"Cannot save", error.localizedDescription ?: @"The edited property list is not valid.");
        return;
    }
    NSString *fmt = doc.format == NSPropertyListXMLFormat_v1_0 ? @"XML" : @"binary";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save changes?"
        message:[NSString stringWithFormat:@"%@ is overwritten in place (%@ format). The current version is backed up first.",
                 doc.path, fmt]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused x) {
        NSUInteger savedRevision = [doc.edit beginSave];
        [self refresh];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *writeError = nil;
            BOOL ok = wq_write_if_unchanged(doc.path, data, doc.version, &writeError);
            dispatch_async(dispatch_get_main_queue(), ^{
                [doc.edit finishSave:ok revision:savedRevision];
                if (ok) doc.version = wq_file_version(doc.path);
                [self refresh];
                if (!ok) wqp_alert(self, @"Save failed", wq_permission_hint(doc.path, YES) ?: writeError ?: @"Unknown error");
            });
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)changed
{
    if (self.doc.edit.saving) return;
    [self.doc.edit noteChange];
    [self refresh];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.status ? 0 : (NSInteger)[self.container count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (self.status) return self.status;
    if (!self.isRoot) return nil;
    NSString *fmt = self.doc.format == NSPropertyListXMLFormat_v1_0 ? @"XML" : @"Binary";
    return self.doc.readOnly ? [NSString stringWithFormat:@"%@ property list · read only", fmt]
                             : [NSString stringWithFormat:@"%@ property list. Tap a value to edit it, swipe to delete or rename, + to add.", fmt];
}

- (id)keyAt:(NSInteger)row
{
    return self.isArray ? @(row) : self.keys[(NSUInteger)row];
}

- (id)valueAt:(NSInteger)row
{
    return self.isArray ? self.container[(NSUInteger)row] : self.container[self.keys[(NSUInteger)row]];
}

- (void)setValue:(id)value at:(NSInteger)row
{
    if (self.isArray) self.container[(NSUInteger)row] = value;
    else self.container[self.keys[(NSUInteger)row]] = value;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    id value = [self valueAt:indexPath.row];
    WQPType t = wqp_type(value);
    c.text = self.isArray ? [NSString stringWithFormat:@"Item %ld", (long)indexPath.row] : [self keyAt:indexPath.row];
    c.secondaryText = [NSString stringWithFormat:@"%@ · %@", wqp_type_name(t), wqp_summary(value)];
    c.secondaryTextProperties.numberOfLines = 3;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    if (t == WQPTypeDictionary || t == WQPTypeArray) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (t == WQPTypeBoolean) {
        UISwitch *sw = [UISwitch new];
        sw.on = [value boolValue];
        sw.enabled = !self.doc.readOnly && !self.doc.edit.saving;
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(boolChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)boolChanged:(UISwitch *)sw
{
    [self setValue:@(sw.on) at:sw.tag];
    [self changed];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id value = [self valueAt:indexPath.row];
    WQPType t = wqp_type(value);
    NSString *name = self.isArray ? [NSString stringWithFormat:@"Item %ld", (long)indexPath.row] : [self keyAt:indexPath.row];
    if (t == WQPTypeDictionary || t == WQPTypeArray) {
        WQPlistEditorViewController *child = [[WQPlistEditorViewController alloc] initWithDocument:self.doc container:value title:name];
        [self.navigationController pushViewController:child animated:YES];
        return;
    }
    if (t == WQPTypeBoolean || self.doc.readOnly || self.doc.edit.saving) return;
    NSInteger row = indexPath.row;
    [self editValueOfType:t current:value title:name done:^(id newValue) {
        [self setValue:newValue at:row];
        [self changed];
    }];
}

// Asks for a scalar value of type `t`; `done` gets the parsed value.
- (void)editValueOfType:(WQPType)t current:(id)current title:(NSString *)title done:(void (^)(id value))done
{
    if (t == WQPTypeData && [current length] > 4096) {
        wqp_alert(self, @"Too large to edit here", @"Data over 4 KB can't be edited in this editor.");
        return;
    }
    NSString *hint = nil;
    switch (t) {
        case WQPTypeInteger: hint = @"Whole number"; break;
        case WQPTypeReal: hint = @"Number"; break;
        case WQPTypeDate: hint = @"ISO 8601, e.g. 2026-11-09T15:00:00Z"; break;
        case WQPTypeData: hint = @"Hex bytes, e.g. 01 ab ff"; break;
        default: break;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                message:[wqp_type_name(t) stringByAppendingString:hint ? [@" · " stringByAppendingString:hint] : @""]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = t == WQPTypeData ? wqp_hex(current, 4096) : (t == WQPTypeDate ? [wqp_dates() stringFromDate:current]
                                                                              : ([current isKindOfClass:NSString.class] ? current : [current stringValue]));
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeAlways;
        if (t == WQPTypeInteger) f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        if (t == WQPTypeReal) f.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused x) {
        NSString *text = a.textFields.firstObject.text ?: @"";
        id value = nil;
        switch (t) {
            case WQPTypeString: value = text; break;
            case WQPTypeInteger: {
                NSScanner *sc = [NSScanner scannerWithString:text];
                long long n;
                if ([sc scanLongLong:&n] && sc.isAtEnd) value = @(n);
                break;
            }
            case WQPTypeReal: {
                NSScanner *sc = [NSScanner scannerWithString:text];
                double d;
                if ([sc scanDouble:&d] && sc.isAtEnd) value = @(d);
                break;
            }
            case WQPTypeDate: value = [wqp_dates() dateFromString:text]; break;
            case WQPTypeData: value = WQParseHex(text, YES); break;
            default: break;
        }
        if (!value) { wqp_alert(self, @"Not a valid value", [NSString stringWithFormat:@"Expected: %@", hint ?: wqp_type_name(t)]); return; }
        done(value);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Adding, deleting, renaming, moving

- (void)add
{
    if (self.doc.edit.saving) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Add" message:@"Type of the new value"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (WQPType t = WQPTypeString; t <= WQPTypeArray; t++) {
        [sheet addAction:[UIAlertAction actionWithTitle:wqp_type_name(t) style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused x) {
            [self addValueOfType:t];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.count > 1
        ? self.navigationItem.rightBarButtonItems[1] : self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)addValueOfType:(WQPType)t
{
    void (^insert)(NSString *key) = ^(NSString *key) {
        id value = wqp_default(t);
        void (^put)(id) = ^(id v) {
            if (self.isArray) {
                [self.container addObject:v];
            } else {
                if (!key.length) return;  // dictionary insertion always has a validated key
                NSMutableDictionary *dictionary = self.container;
                dictionary[key] = v;
            }
            [self changed];
        };
        if (t == WQPTypeDictionary || t == WQPTypeArray || t == WQPTypeBoolean) { put(value); return; }
        [self editValueOfType:t current:value title:key ?: @"New Item" done:put];
    };
    if (self.isArray) { insert(nil); return; }
    [self askKey:nil title:@"Key" done:insert];
}

- (void)askKey:(NSString *)current title:(NSString *)title done:(void (^)(NSString *key))done
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = current;
        f.placeholder = @"Key";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused x) {
        NSString *key = a.textFields.firstObject.text ?: @"";
        if (key.length == 0) return;
        if (![key isEqualToString:current] && self.container[key]) {
            wqp_alert(self, @"Key exists", [NSString stringWithFormat:@"There is already a key named \"%@\".", key]);
            return;
        }
        done(key);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.doc.readOnly || self.doc.edit.saving) return nil;
    NSInteger row = indexPath.row;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *__unused action, UIView *__unused view, void (^completion)(BOOL)) {
        if (self.isArray) [self.container removeObjectAtIndex:(NSUInteger)row];
        else [self.container removeObjectForKey:self.keys[(NSUInteger)row]];
        [self changed];
        completion(YES);
    }];
    if (self.isArray) return [UISwipeActionsConfiguration configurationWithActions:@[del]];
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Rename"
        handler:^(UIContextualAction *__unused action, UIView *__unused view, void (^completion)(BOOL)) {
        NSString *old = self.keys[(NSUInteger)row];
        [self askKey:old title:@"Rename Key" done:^(NSString *key) {
            if ([key isEqualToString:old]) return;
            id v = self.container[old];
            [self.container removeObjectForKey:old];
            self.container[key] = v;
            [self changed];
        }];
        completion(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, rename]];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return self.isArray && !self.doc.readOnly && !self.doc.edit.saving;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to
{
    if (self.doc.edit.saving) return;
    id v = self.container[(NSUInteger)from.row];
    [self.container removeObjectAtIndex:(NSUInteger)from.row];
    [self.container insertObject:v atIndex:(NSUInteger)to.row];
    [self.doc.edit noteChange];
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

@end
