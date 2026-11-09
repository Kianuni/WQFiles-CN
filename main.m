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
#import "WQPlistEditor.h"
#import "WQHexViewer.h"

// "iPhone 17 Pro Max (iPhone18,2)\niOS 27.0.1 (24A446)"
static NSString *wq_device_line(void)
{
    struct utsname u;
    NSString *machine = (uname(&u) == 0) ? @(u.machine) : @"unknown";
    char build[64] = {0};
    size_t len = sizeof(build);
    NSString *buildStr = (sysctlbyname("kern.osversion", build, &len, NULL, 0) == 0) ? @(build) : nil;
    NSDictionary *names = @{
        @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
        @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus", @"iPhone17,5": @"iPhone 16e",
        @"iPhone18,1": @"iPhone 17 Pro", @"iPhone18,2": @"iPhone 17 Pro Max",
        @"iPhone18,3": @"iPhone 17", @"iPhone18,4": @"iPhone Air",
    };
    NSString *marketing = names[machine];
    NSString *model = marketing ? [NSString stringWithFormat:@"%@ (%@)", marketing, machine] : machine;
    NSString *ver = UIDevice.currentDevice.systemVersion;
    return buildStr ? [NSString stringWithFormat:@"%@ · iOS %@ (%@)", model, ver, buildStr]
                    : [NSString stringWithFormat:@"%@ · iOS %@", model, ver];
}

// A small centered label with the device/iOS line, for a table header.
static UIView *wq_device_header(CGFloat width)
{
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 50)];
    UILabel *header = [UILabel new];
    header.numberOfLines = 0;
    header.textAlignment = NSTextAlignmentCenter;
    header.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    header.textColor = UIColor.secondaryLabelColor;
    header.backgroundColor = UIColor.secondarySystemBackgroundColor;
    header.text = wq_device_line();
    header.frame = CGRectMake(0, 0, width, 34);
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [box addSubview:header];  // 16 pt of clear space below the strip
    return box;
}

// Private: app icon by bundle id (in UIKit; guarded with respondsToSelector).
@interface UIImage (WQPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end

// Small grey fingerprint of an icon, to recognise iOS's blank placeholder.
static NSData *wq_icon_fingerprint(UIImage *img)
{
    const size_t s = 12;
    uint8_t px[12 * 12 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, s, s, 8, s * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    if (img.CGImage) CGContextDrawImage(ctx, CGRectMake(0, 0, s, s), img.CGImage);
    CGContextRelease(ctx);
    return [NSData dataWithBytes:px length:sizeof(px)];
}

static UIImage *wq_raw_icon(NSString *bundleID)
{
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:UIScreen.mainScreen.scale];
}

// The real icon for bundleID, or nil when iOS only has its placeholder.
static UIImage *wq_real_icon(NSString *bundleID)
{
    static NSData *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ placeholder = wq_icon_fingerprint(wq_raw_icon(@"cz.kolbi.wqfiles.no-such-app")); });
    UIImage *raw = wq_raw_icon(bundleID);
    if (!raw || !raw.CGImage) return nil;
    NSData *fp = wq_icon_fingerprint(raw);
    if (!placeholder || fp.length != placeholder.length) return raw;
    // Near-identical to the placeholder (allow small rendering differences).
    const uint8_t *a = fp.bytes, *b = placeholder.bytes;
    unsigned long diff = 0;
    for (NSUInteger i = 0; i < fp.length; i++) diff += (unsigned long)abs((int)a[i] - (int)b[i]);
    return diff / fp.length < 8 ? nil : raw;
}

static UIImage *wq_round_icon(UIImage *raw)
{
    CGFloat s = 40;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.225] addClip];
        [raw drawInRect:CGRectMake(0, 0, s, s)];
    }];
}

// Symbol tile for system services and extensions that have no icon at all,
// picked from keywords in the bundle id.
static UIImage *wq_service_tile(NSString *bundleID)
{
    static NSArray<NSArray *> *rules;
    static NSCache *tiles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tiles = [NSCache new];
        UIColor *blue = UIColor.systemBlueColor, *green = UIColor.systemGreenColor, *red = UIColor.systemRedColor,
                *orange = UIColor.systemOrangeColor, *purple = UIColor.systemPurpleColor, *indigo = UIColor.systemIndigoColor,
                *teal = UIColor.systemTealColor, *pink = UIColor.systemPinkColor, *gray = UIColor.systemGrayColor;
        // keywords (lower case, any match), symbol, colour
        rules = @[
            @[@[@"emoji"], @"face.smiling.inverse", orange],
            @[@[@"keyboard", @"inputui", @"textinput", @"dictation"], @"keyboard.fill", gray],
            @[@[@"airdrop", @"sharing", @"sharesheet"], @"antenna.radiowaves.left.and.right", blue],
            @[@[@"widget", @"chrono"], @"square.grid.2x2.fill", blue],
            @[@[@"screenshot", @"screencapture", @"screenrecord"], @"camera.viewfinder", indigo],
            @[@[@"poster", @"wallpaper"], @"photo.on.rectangle.angled", purple],
            @[@[@"siri", @"assistant"], @"waveform", indigo],
            @[@[@"camera"], @"camera.fill", gray],
            @[@[@"photo"], @"photo.fill", orange],
            @[@[@"music", @"audio", @"shazam", @"musicrecognition"], @"music.note", pink],
            @[@[@"headphone", @"airpods", @"bluetooth"], @"headphones", gray],
            @[@[@"hearing"], @"ear.fill", blue],
            @[@[@"weather"], @"cloud.sun.fill", teal],
            @[@[@"location", @"maps", @"navigation"], @"location.fill", blue],
            @[@[@"health", @"fitness", @"workout"], @"heart.fill", red],
            @[@[@"pay", @"wallet", @"passbook", @"cash", @"finance"], @"creditcard.fill", green],
            @[@[@"mail"], @"envelope.fill", blue],
            @[@[@"message", @"sms", @"imessage"], @"message.fill", green],
            @[@[@"facetime", @"video"], @"video.fill", green],
            @[@[@"phone", @"call", @"telephony"], @"phone.fill", green],
            @[@[@"notification", @"usernotification", @"bulletin"], @"bell.fill", red],
            @[@[@"shortcut", @"workflow", @"intent"], @"square.on.square", indigo],
            @[@[@"safari", @"web"], @"safari.fill", blue],
            @[@[@"news", @"stocks"], @"newspaper.fill", red],
            @[@[@"calendar", @"event"], @"calendar", red],
            @[@[@"note", @"paper"], @"note.text", orange],
            @[@[@"reminder"], @"checklist", blue],
            @[@[@"game"], @"gamecontroller.fill", purple],
            @[@[@"auth", @"account", @"appsso", @"password", @"keychain", @"tcc", @"privacy"], @"lock.fill", gray],
            @[@[@"print"], @"printer.fill", gray],
            @[@[@"clarity", @"accessib"], @"accessibility", blue],
            @[@[@"home"], @"house.fill", orange],
            @[@[@"findmy", @"fmd", @"fmip"], @"location.circle.fill", green],
            @[@[@"carplay", @"carradio", @"cartrip", @"car."], @"car.fill", gray],
            @[@[@"tvremote", @"tvsetup", @"com.apple.tv"], @"tv.fill", gray],
            @[@[@"book"], @"book.fill", orange],
            @[@[@"podcast"], @"mic.fill", purple],
            @[@[@"spotlight", @"search"], @"magnifyingglass", gray],
            @[@[@"diagnostic", @"logging", @"crash", @"analytics"], @"stethoscope", gray],
            @[@[@"font"], @"textformat", gray],
            @[@[@"translate"], @"character.bubble.fill", blue],
            @[@[@"file", @"document", @"cloud"], @"folder.fill", blue],
            @[@[@"setup", @"buddy", @"onboarding"], @"gearshape.2.fill", gray],
        ];
    });
    NSString *key = bundleID.lowercaseString;
    NSString *symbol = @"gearshape.fill";
    UIColor *color = UIColor.systemGrayColor;
    for (NSArray *rule in rules) {
        BOOL hit = NO;
        for (NSString *word in rule[0]) if ([key containsString:word]) { hit = YES; break; }
        if (hit) { symbol = rule[1]; color = rule[2]; break; }
    }
    NSString *cacheKey = [symbol stringByAppendingString:color.description];
    UIImage *tile = [tiles objectForKey:cacheKey];
    if (tile) return tile;
    CGFloat s = 40;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    UIColor *fill = [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]];
    tile = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [fill setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.225] fill];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
        UIImage *g = [[UIImage systemImageNamed:symbol withConfiguration:cfg] ?: [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        [g drawInRect:CGRectMake((s - g.size.width) / 2, (s - g.size.height) / 2, g.size.width, g.size.height)];
    }];
    [tiles setObject:tile forKey:cacheKey];
    return tile;
}

// Rounded app icon for a bundle id, cached. Falls back to the closest parent
// app's icon (extensions: com.foo.app.widget -> com.foo.app), then to a
// neutral service tile. Nil only without a bundle id.
static UIImage *wq_app_icon(NSString *bundleID)
{
    if (!bundleID.length) return nil;
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    UIImage *cached = [cache objectForKey:bundleID];
    if (cached) return cached;
    UIImage *raw = wq_real_icon(bundleID);
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    for (NSInteger n = (NSInteger)parts.count - 1; !raw && n >= 3; n--)
        raw = wq_real_icon([[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."]);
    UIImage *icon = raw ? wq_round_icon(raw) : wq_service_tile(bundleID);
    [cache setObject:icon forKey:bundleID];
    return icon;
}

static dispatch_queue_t wq_io(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("wqfiles.io", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static void wq_alert(UIViewController *host, NSString *title, NSString *message)
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

static NSString *wq_size_text(unsigned long long size)
{
    if (size == 0) return @"0 KB";
    return [NSByteCountFormatter stringFromByteCount:(long long)size countStyle:NSByteCountFormatterCountStyleFile];
}

static BOOL wq_looks_like_uuid(NSString *name)
{
    return name.length == 36 && [[NSUUID alloc] initWithUUIDString:name] != nil;
}

// Copies a file into tmp so the share sheet (another process) can read it.
static void wq_share(UIViewController *host, NSString *path, UIView *source)
{
    // Streamed in chunks (large files), and not on the serial I/O queue, which
    // may be busy with a container scan.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:path.lastPathComponent];
        BOOL ok = wq_copy_to_local(path, tmp, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                wq_alert(host, @"Cannot share", error ?: @"Copy failed");
                return;
            }
            UIActivityViewController *share = [[UIActivityViewController alloc]
                initWithActivityItems:@[[NSURL fileURLWithPath:tmp]] applicationActivities:nil];
            share.popoverPresentationController.sourceView = source ?: host.view;
            share.popoverPresentationController.sourceRect = (source ?: host.view).bounds;
            [host presentViewController:share animated:YES completion:nil];
        });
    });
}

// Zips a folder (the system's own zipper via NSFileCoordinator) and opens the
// share sheet, so a backup can go out over AirDrop, Files, Mail…
static void wq_share_folder(UIViewController *host, NSString *dir, NSString *zipName, UIView *source)
{
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"Preparing…"
        message:@"Compressing the folder" preferredStyle:UIAlertControllerStyleAlert];
    [host presentViewController:hud animated:YES completion:nil];
    dispatch_async(wq_io(), ^{
        NSString *safe = [[zipName componentsSeparatedByCharactersInSet:
                           [NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"-"];
        NSString *outDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Share"];
        NSString *zip = [outDir stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"zip"]];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:outDir error:nil];
        [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        wq_grant(dir);
        __block NSError *copyError = nil;
        NSError *coordError = nil;
        [[NSFileCoordinator new] coordinateReadingItemAtURL:[NSURL fileURLWithPath:dir]
                                                    options:NSFileCoordinatorReadingForUploading
                                                      error:&coordError byAccessor:^(NSURL *zipped) {
            [fm copyItemAtURL:zipped toURL:[NSURL fileURLWithPath:zip] error:&copyError];
        }];
        BOOL ok = [fm fileExistsAtPath:zip];
        NSString *why = (coordError ?: copyError).localizedDescription ?: @"Could not create the ZIP";
        wq_log(@"share zip: %@ -> %@ %@", dir, zip.lastPathComponent, ok ? @"OK" : why);
        dispatch_async(dispatch_get_main_queue(), ^{
            [hud dismissViewControllerAnimated:YES completion:^{
                if (!ok) { wq_alert(host, @"Cannot share", why); return; }
                UIActivityViewController *share = [[UIActivityViewController alloc]
                    initWithActivityItems:@[[NSURL fileURLWithPath:zip]] applicationActivities:nil];
                share.popoverPresentationController.sourceView = source ?: host.view;
                share.popoverPresentationController.sourceRect = (source ?: host.view).bounds;
                [host presentViewController:share animated:YES completion:nil];
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

@interface WQFileViewController : UIViewController <UITextViewDelegate>
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
    BOOL _dirty;
    BOOL _saving;
    NSUInteger _revision;
}

static const NSUInteger kViewLimit = 4 * 1024 * 1024;
static const NSUInteger kHexLimit = 64 * 1024;

- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _path = [path copy];
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
    self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *a) { [weakSelf leave]; }];
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
                          handler:^(UIAction *a) { [weakSelf reopenAs:WQOpenPlist]; }],
        [UIAction actionWithTitle:@"Hex Viewer" image:[UIImage systemImageNamed:@"number"] identifier:nil
                          handler:^(UIAction *a) { [weakSelf reopenAs:WQOpenHex]; }],
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
        NSData *data = wq_read(path, kViewLimit + 1, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
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
    _editButton.enabled = !_saving;
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
    if (_saving) return;
    _revision++;
    _dirty = YES;
}

- (BOOL)blockWhileSaving
{
    if (!_saving) return NO;
    wq_alert(self, @"Save in progress", @"Wait for the current save to finish before leaving or making more changes.");
    return YES;
}

- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!_dirty) { proceed(); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Discard changes?"
        message:@"Your text changes have not been saved." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep Editing" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Discard" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        self->_dirty = NO;
        self->_revision++;
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
    if (!_dirty) {
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
    [confirm addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSUInteger savedRevision = self->_revision;
        self->_saving = YES;
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        NSString *path = self->_path;
        dispatch_async(wq_io(), ^{
            NSString *error = nil;
            BOOL ok = wq_write(path, newData, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_saving = NO;
                if (ok && self->_revision == savedRevision) self->_dirty = NO;
                self->_textView.editable = self->_dirty;
                [self updateEditButton];
                if (!ok) wq_alert(self, @"Save failed", wq_permission_hint(path, YES) ?: error ?: @"Unknown error");
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

static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode)
{
    void (^push)(WQOpenMode) = ^(WQOpenMode m) {
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

@interface WQDirViewController : UITableViewController <UIDocumentPickerDelegate, UISearchResultsUpdating>
@property (nonatomic) BOOL readOnly;  // root/system areas: browse + read, no writes
- (instancetype)initWithPath:(NSString *)path title:(NSString *)title;
@end

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
                          handler:^(UIAction *a) { [weakSelf promptNewFolder]; }]];
        [menuItems addObject:[UIAction actionWithTitle:@"Import File" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil
                          handler:^(UIAction *a) { [weakSelf importFile]; }]];
    }
    [menuItems addObject:[UIAction actionWithTitle:@"Copy Path" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                          handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = path; }]];
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
    _items = [_all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQItem *item, NSDictionary *b) {
        for (NSString *field in @[item.label ?: @"", item.name ?: @"", item.bundleID ?: @""])
            if ([field rangeOfString:q options:opts].location != NSNotFound) return YES;
        return NO;
    }]];
}

- (void)reload
{
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
        if (!names && enumerable) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_scanStatus = @"Scanning inodes…";
                [self updateHeader];
            });
            childPaths = wq_enumerate(path, 0, ^(int64_t done, int64_t total, NSUInteger f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_scanStatus = [NSString stringWithFormat:@"Scanning inodes… %lld%% · %lu found",
                                         (long long)(done * 100 / total), (unsigned long)f];
                    [self updateHeader];
                });
            });
            dispatch_async(dispatch_get_main_queue(), ^{ self->_scanStatus = nil; [self updateHeader]; });
        }
        NSMutableArray<WQItem *> *items = [NSMutableArray new];
        NSArray *entries = names ?: childPaths;
        BOOL haveFullPaths = names == nil;
        for (NSString *entry in entries) {
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
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray *actions = [NSMutableArray new];
        if (item.isDir) {
            [actions addObject:[UIAction actionWithTitle:@"Share as ZIP (AirDrop…)" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *a) {
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (weakSelf) wq_share_folder(weakSelf, item.path, wq_zip_name(item.path), cell);
            }]];
        }
        if (!item.isDir) {
            [actions addObject:[UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *a) {
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (weakSelf) wq_share(weakSelf, item.path, cell);
            }]];
            NSString *original = wq_backup_original_path(item.path);
            if (original) {
                [actions addObject:[UIAction actionWithTitle:@"Restore to Original Location"
                                                       image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                                  identifier:nil handler:^(UIAction *a) {
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
                                  handler:^(UIAction *a) { wq_open_file(nav, item.path, ro, WQOpenPlist); }],
                [UIAction actionWithTitle:@"Text / Image" image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil
                                  handler:^(UIAction *a) { wq_open_file(nav, item.path, ro, WQOpenText); }],
                [UIAction actionWithTitle:@"Hex Viewer" image:[UIImage systemImageNamed:@"number"] identifier:nil
                                  handler:^(UIAction *a) { wq_open_file(nav, item.path, ro, WQOpenHex); }],
            ]]];
        }
        [actions addObject:[UIAction actionWithTitle:@"Copy Path" image:[UIImage systemImageNamed:@"doc.on.doc"]
                                          identifier:nil handler:^(UIAction *a) {
            UIPasteboard.generalPasteboard.string = item.path;
        }]];
        if (item.label) {
            [actions addObject:[UIAction actionWithTitle:@"Copy Identifier" image:[UIImage systemImageNamed:@"tag"]
                                              identifier:nil handler:^(UIAction *a) {
                UIPasteboard.generalPasteboard.string = item.label;
            }]];
        }
        if (!weakSelf.readOnly) {
            [actions addObject:[UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"]
                                              identifier:nil handler:^(UIAction *a) { [weakSelf promptRename:item]; }]];
            UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *a) { [weakSelf confirmDelete:item]; }];
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
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
                                                    handler:^(UIAlertAction *a) { cleanup(); }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Replace" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Open" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
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

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _textView.text = wq_log_text();
}

- (void)share:(UIBarButtonItem *)sender
{
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[wq_log_text()]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

@end

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

@interface WQCacheCleanerViewController : UITableViewController <UISearchResultsUpdating>
@end

@implementation WQCacheCleanerViewController {
    NSArray<WQCacheItem *> *_items;
    NSString *_query;
    NSString *_status;   // scan / clean progress, nil when idle
    NSString *_result;   // last clean result
    BOOL _scanning, _cleaning;
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

- (NSArray<WQCacheItem *> *)visibleItems
{
    if (!_query.length) return _items;
    return [_items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQCacheItem *it, NSDictionary *b) {
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
    UIAction *all = [UIAction actionWithTitle:@"Select All" image:[UIImage systemImageNamed:@"checkmark.circle"]
                                   identifier:nil handler:^(UIAction *a) { [weakSelf selectWhere:^BOOL(WQCacheItem *it) { return YES; }]; }];
    UIAction *none = [UIAction actionWithTitle:@"Select None" image:[UIImage systemImageNamed:@"circle"]
                                    identifier:nil handler:^(UIAction *a) { [weakSelf selectWhere:^BOOL(WQCacheItem *it) { return NO; }]; }];
    UIAction *large = [UIAction actionWithTitle:@"Select Large Caches (50 MB+)" image:[UIImage systemImageNamed:@"arrow.up.circle"]
                                     identifier:nil handler:^(UIAction *a) {
        [weakSelf selectWhere:^BOOL(WQCacheItem *it) { return it.bytes >= 50ull * 1000 * 1000; }];
    }];
    all.state = allVisible ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIBarButtonItem *select = [[UIBarButtonItem alloc] initWithTitle:@"Select"
                                                                menu:[UIMenu menuWithChildren:@[all, none, large]]];
    select.enabled = visible.count > 0;
    self.navigationItem.rightBarButtonItems = @[clean, select];
}

- (void)scan
{
    _scanning = YES;
    _result = nil;
    [self updateButtons];
    [self setStatus:@"Finding apps…"];
    dispatch_async(wq_io(), ^{
        NSMutableArray<WQCacheItem *> *items = [NSMutableArray new];
        NSArray *roots = @[@"/private/var/mobile/Containers/Data/Application",
                           @"/private/var/mobile/Containers/Data/PluginKitPlugin"];
        for (NSString *root in roots) {
            NSString *kind = [root.lastPathComponent isEqualToString:@"Application"] ? @"apps" : @"extensions";
            NSArray *containers = wq_enumerate(root, 0, ^(int64_t done, int64_t total, NSUInteger f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setStatus:[NSString stringWithFormat:@"Finding %@… %lld%%", kind, (long long)(done * 100 / total)]];
                });
            });
            NSUInteger idx = 0;
            for (NSString *c in containers) {
                idx++;
                if (idx % 10 == 0 || idx == containers.count) {
                    dispatch_async(dispatch_get_main_queue(), ^{
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
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray *actions = [NSMutableArray new];
        if (!item.bundleID) {
            NSString *root = item.targets.firstObject;
            [actions addObject:[UIAction actionWithTitle:@"Show Crash Logs in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *a) { [weakSelf openFolder:root title:@"Crash Logs"]; }]];
        } else {
            NSString *caches = item.targets[0], *tmp = item.targets[1];
            [actions addObject:[UIAction actionWithTitle:@"Show Caches in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *a) {
                [weakSelf openFolder:caches title:[item.name stringByAppendingString:@" · Caches"]];
            }]];
            if (item.tempBytes > 0)
                [actions addObject:[UIAction actionWithTitle:@"Show tmp in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                                  identifier:nil handler:^(UIAction *a) {
                    [weakSelf openFolder:tmp title:[item.name stringByAppendingString:@" · tmp"]];
                }]];
            [actions addObject:[UIAction actionWithTitle:@"Show App Data in File Browser" image:[UIImage systemImageNamed:@"folder.badge.gearshape"]
                                              identifier:nil handler:^(UIAction *a) {
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Clean" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
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

#pragma mark - Apps manager

@interface WQAppItem : NSObject
@property (nonatomic, copy) NSString *container;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) BOOL hasAccess;
@end
@implementation WQAppItem
@end

@interface WQAppsViewController : UITableViewController <UISearchResultsUpdating>
@end

@implementation WQAppsViewController {
    NSArray<WQAppItem *> *_apps;
    NSString *_query;
    NSString *_status;
    BOOL _busy;
}

static NSArray<NSString *> *const kAppDataParts(void) { return @[@"Documents", @"Library", @"tmp"]; }

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

static NSString *wq_latest_app_backup(NSString *bundleID)
{
    return wq_app_backups(bundleID).firstObject[@"path"];
}

static NSString *wq_backup_label(NSDictionary *backup)
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

- (void)setBusy:(BOOL)busy status:(NSString *)status
{
    _busy = busy;
    _status = status;
    [self.tableView reloadData];
}

- (void)scan
{
    [self setBusy:YES status:@"Finding apps…"];
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    dispatch_async(wq_io(), ^{
        NSArray *containers = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0,
            ^(int64_t done, int64_t total, NSUInteger f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_status = [NSString stringWithFormat:@"Finding apps… %lld%%", (long long)(done * 100 / total)];
                    [self.tableView reloadData];
                });
            });
        NSMutableArray<WQAppItem *> *apps = [NSMutableArray new];
        NSUInteger i = 0, grantFailures = 0, missingLabels = 0, limited = 0;
        for (NSString *c in containers) {
            i++;
            if ([[c stringByResolvingSymlinksInPath] isEqualToString:home]) continue;  // ourselves
            dispatch_async(dispatch_get_main_queue(), ^{
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
            [apps addObject:app];
        }
        [apps sortUsingComparator:^NSComparisonResult(WQAppItem *a, WQAppItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        wq_log(@"app scan: discovered %lu, showing %lu, limited %lu (grant failures %lu, missing labels %lu)",
               (unsigned long)containers.count, (unsigned long)apps.count, (unsigned long)limited,
               (unsigned long)grantFailures, (unsigned long)missingLabels);
        NSString *note = nil;
        if (!containers) note = @"Container enumeration failed. Check the App Group and see Log.";
        else if (!containers.count) note = @"No app containers were found. Check the App Group and see Log.";
        else if (limited) note = [NSString stringWithFormat:@"%lu containers · %lu with limited access or no identifier. See Log.",
                                  (unsigned long)apps.count, (unsigned long)limited];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_apps = apps;
            [self.refreshControl endRefreshing];
            [self setBusy:NO status:note];
        });
    });
}

- (NSArray<WQAppItem *> *)visibleApps
{
    if (!_query.length) return _apps;
    return [_apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQAppItem *a, NSDictionary *b) {
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
    BOOL hasBackup = app.hasAccess && app.bundleID.length && wq_latest_app_backup(app.bundleID) != nil;
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
            [sheet addAction:[UIAlertAction actionWithTitle:@"Open Data Folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:app.container title:app.name] animated:YES];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Copy Container Path" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"Back Up Data" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self backUp:app then:nil];
    }]];
    NSArray *backups = wq_app_backups(app.bundleID);
    NSString *latest = backups.firstObject[@"path"];
    if (latest) {
        NSString *title = backups.count == 1 ? [NSString stringWithFormat:@"Restore Backup (%@)", wq_backup_label(backups.firstObject)]
                                             : [NSString stringWithFormat:@"Restore a Backup… (%lu)", (unsigned long)backups.count];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self pickBackupToRestore:app from:[tableView cellForRowAtIndexPath:indexPath]];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Share Latest Backup (AirDrop…)"
                                                  style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
            wq_share_folder(self, latest, [NSString stringWithFormat:@"%@ %@", app.name, latest.lastPathComponent], c);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Clear Data…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self confirmClear:app];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open Data Folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Back Up, Then Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self backUp:app then:^(BOOL ok) {
            if (ok) [self clear:app];
            else [self finish:@"Not cleared" message:@"The backup did not complete, so nothing was deleted."];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear Without Backup" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self clear:app];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pickBackupToRestore:(WQAppItem *)app from:(UIView *)source
{
    NSArray *backups = wq_app_backups(app.bundleID);
    if (backups.count == 1) { [self confirmRestore:app from:backups.firstObject]; return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Restore which backup?" message:app.name
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *b in backups) {
        [sheet addAction:[UIAlertAction actionWithTitle:wq_backup_label(b) style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [self confirmRestore:app from:b]; }]];
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
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
    // 2. Keep the current data, so a failure can be undone.
    NSString *error = nil;
    NSString *safety = wq_make_app_backup(app.bundleID, app.container, kBackupReasonBeforeRestore, &error);
    if (!safety) {
        *title = @"Not restored";
        *message = [NSString stringWithFormat:@"The current data couldn't be backed up first (%@). Nothing was changed.",
                    error ?: @"see Log"];
        return;
    }
    // 3. Replace each part; on any failure put the previous data back.
    error = nil;
    BOOL ok = YES;
    for (NSString *part in parts) {
        if (!wq_replace_part([backup stringByAppendingPathComponent:part],
                             [app.container stringByAppendingPathComponent:part], &error)) { ok = NO; break; }
    }
    if (ok) {
        wq_log(@"restore %@ from %@: OK", app.bundleID, backup.lastPathComponent);
        *title = @"Restored";
        *message = [NSString stringWithFormat:@"Open %@ to use the restored data. The data from before is kept as backup %@.",
                    app.name, safety.lastPathComponent];
        return;
    }
    wq_log(@"restore %@ from %@: FAILED (%@), rolling back", app.bundleID, backup.lastPathComponent, error);
    NSString *rollbackError = nil;
    BOOL rolledBack = YES;
    for (NSString *part in parts) {
        NSString *saved = [safety stringByAppendingPathComponent:part];
        NSString *dst = [app.container stringByAppendingPathComponent:part];
        if ([fm fileExistsAtPath:saved]) {
            if (!wq_replace_part(saved, dst, &rollbackError)) rolledBack = NO;
        } else {
            unsigned long long ignored = 0;
            if (!wq_purge_contents(dst, &ignored)) rolledBack = NO;   // the part was empty before
        }
    }
    wq_log(@"restore %@: rollback %@", app.bundleID, rolledBack ? @"OK" : @"FAILED");
    *title = @"Restore failed";
    *message = rolledBack
        ? [NSString stringWithFormat:@"%@. The previous data was put back.", error ?: @"Some files couldn't be written"]
        : [NSString stringWithFormat:@"%@, and putting the previous data back also failed (%@). It is in backup %@; see the Log.",
           error ?: @"Some files couldn't be written", rollbackError ?: @"see Log", safety.lastPathComponent];
}

@end

#pragma mark - Navigation

// Adds a Home button next to Back on screens two or more levels deep. Screens
// with unsaved edits (plist editor, hex viewer) are asked first.
@interface WQNavigationController : UINavigationController <UINavigationControllerDelegate>
@end

@implementation WQNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;
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

- (void)goHome
{
    UIViewController *top = self.topViewController;
    SEL ask = NSSelectorFromString(@"confirmLeaveThen:");
    __weak typeof(self) weakSelf = self;
    void (^home)(void) = ^{ [weakSelf popToRootViewControllerAnimated:YES]; };
    if ([top respondsToSelector:ask]) {
        ((void (*)(id, SEL, void (^)(void)))[top methodForSelector:ask])(top, ask, home);
        return;
    }
    home();
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
        return [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
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
    UIButton *credit = [UIButton buttonWithConfiguration:creditCfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Open" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
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
