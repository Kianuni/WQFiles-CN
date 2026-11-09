//
//  WQLaunchServices.m
//  WQ Files
//

#import "WQLaunchServices.h"
#import "WQAccess.h"
#import <string.h>
#import <sys/stat.h>

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
    NSArray *daemons = wq_enumerate(@"/private/var/mobile/Containers/Data/InternalDaemon", 0, nil, nil);
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
