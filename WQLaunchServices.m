//
//  WQLaunchServices.m
//  WQ Files
//  GPL-3.0-or-later.
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
// When the database wasn't found: don't search again for a day (each search
// lists every daemon container), unless the user refreshes.
static NSString *const kWQLSMissKey = @"WQLaunchServicesStoreMissedAt";
static const NSTimeInterval kWQLSMissRetry = 24 * 60 * 60;

// These limits keep a malformed or unexpectedly large database from turning a
// synchronous display-name lookup into an unbounded read/parse operation.
static const size_t kWQLSMinStoreBytes = 0x1000;
static const size_t kWQLSMaxStoreBytes = 64u * 1024u * 1024u;
static const uint32_t kWQLSMaxStringID = 0x01000000u;
static const NSUInteger kWQLSMaxBundleRecords = 100000;
static const NSUInteger kWQLSMaxDecodedStrings = 200000;
static const NSUInteger kWQLSMaxDecodedStringBytes = 8u * 1024u * 1024u;

static NSObject *wq_ls_lock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *wq_find_ls_store(BOOL *searched);
static BOOL wq_ls_candidate_info(NSString *path, struct stat *st);

static BOOL wq_ls_stat_equal(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
        a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec &&
        a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec;
}

static NSDictionary *wq_ls_signature(const struct stat *st)
{
    return @{
        @"device": @(st->st_dev), @"inode": @(st->st_ino), @"size": @(st->st_size),
        @"modifiedSeconds": @(st->st_mtimespec.tv_sec),
        @"modifiedNanoseconds": @(st->st_mtimespec.tv_nsec)
    };
}

static BOOL wq_ls_signature_equal(NSDictionary *a, NSDictionary *b)
{
    return a && b && [a isEqualToDictionary:b];
}

static NSString *wq_ls_error(NSString *path, NSString *reason)
{
    return [NSString stringWithFormat:@"%@ (%@)", path ?: @"<none>", reason ?: @"unknown error"];
}

static BOOL wq_ls_candidate_info(NSString *path, struct stat *st)
{
    if (!path.length || !wq_stat(path, st) || !S_ISREG(st->st_mode) ||
        st->st_size < (off_t)kWQLSMinStoreBytes || st->st_size > (off_t)kWQLSMaxStoreBytes) {
        return NO;
    }
    NSString *error = nil;
    NSData *header = wq_read(path, 4, &error);
    if (header.length != 4 || memcmp(header.bytes, "bdsl", 4) != 0) return NO;
    return YES;
}

static BOOL wq_ls_is_newer(NSString *path, const struct stat *st,
                           NSString *bestPath, const struct stat *best)
{
    if (!bestPath) return YES;
    if (st->st_mtimespec.tv_sec != best->st_mtimespec.tv_sec)
        return st->st_mtimespec.tv_sec > best->st_mtimespec.tv_sec;
    if (st->st_mtimespec.tv_nsec != best->st_mtimespec.tv_nsec)
        return st->st_mtimespec.tv_nsec > best->st_mtimespec.tv_nsec;
    if (st->st_size != best->st_size) return st->st_size > best->st_size;
    return [path compare:bestPath] == NSOrderedAscending;
}

static void wq_ls_consider_candidate(NSString *path, NSString **bestPath,
                                      struct stat *best, NSMutableSet<NSString *> *seen)
{
    if (!path.length || [seen containsObject:path]) return;
    [seen addObject:path];

    struct stat st;
    if (!wq_ls_candidate_info(path, &st)) return;
    if (wq_ls_is_newer(path, &st, *bestPath, best)) {
        *bestPath = path;
        *best = st;
    }
}

// *searched: the daemon containers were actually listed (a failed or cancelled
// scan says nothing about whether the database exists).
static NSString *wq_find_ls_store(BOOL *searched)
{
    if (searched) *searched = NO;
    NSString *cached = [NSUserDefaults.standardUserDefaults stringForKey:kWQLSStoreKey];
    NSString *bestPath = nil;
    struct stat best = {0};
    struct stat cachedStat;
    BOOL cachedValid = cached.length && wq_ls_candidate_info(cached, &cachedStat);
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (cachedValid) wq_ls_consider_candidate(cached, &bestPath, &best, seen);

    NSArray *daemons = wq_enumerate(@"/private/var/mobile/Containers/Data/InternalDaemon", 0, nil, nil);
    if (daemons && searched) *searched = YES;
    if (daemons) {
        for (NSString *container in daemons) {
            NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
            NSArray *items = wq_list(caches, NULL);
            for (NSString *name in [items sortedArrayUsingSelector:@selector(compare:)]) {
                if (![name hasPrefix:@"com.apple.LaunchServices-"] || ![name hasSuffix:@".csstore"]) continue;
                wq_ls_consider_candidate([caches stringByAppendingPathComponent:name], &bestPath, &best, seen);
            }
        }
    }

    // Keep a valid cached path usable if enumeration is temporarily unavailable.
    if (!bestPath && cachedValid) {
        bestPath = cached;
    }
    return bestPath;
}

static uint32_t wq_rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static NSString *wq_cs_string(const uint8_t *b, size_t n, size_t o)
{
    if (o > n || n - o < 8) return nil;
    uint32_t len = wq_rd32(b + o + 4);
    if (len == 0 || len >= 0x800 || len >= n - o - 8 || b[o + 8 + len] != 0) return nil;
    if (memchr(b + o + 8, 0, len)) return nil;
    NSString *s = [[NSString alloc] initWithBytes:b + o + 8 length:len encoding:NSUTF8StringEncoding];
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

// Unicode format characters include bidi overrides/isolates, zero-width
// characters, and BOM-like markers. They are replaced visibly while ordinary
// international letters, accents, and scripts remain unchanged.
static BOOL wq_is_name_format_scalar(uint32_t c)
{
    return c == 0x00ad || (c >= 0x0600 && c <= 0x0605) || c == 0x061c || c == 0x06dd ||
        c == 0x070f || (c >= 0x0890 && c <= 0x0891) || c == 0x08e2 || c == 0x180e ||
        (c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e) ||
        (c >= 0x2060 && c <= 0x206f) || c == 0xfeff;
}

static NSString *wq_safe_name(NSString *value)
{
    if (!value.length) return nil;
    NSMutableString *safe = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger i = 0; i < value.length;) {
        uint32_t scalar = [value characterAtIndex:i++];
        if (scalar >= 0xd800 && scalar <= 0xdbff) {
            if (i >= value.length) return nil;
            unichar low = [value characterAtIndex:i++];
            if (low < 0xdc00 || low > 0xdfff) return nil;
            scalar = 0x10000u + ((scalar - 0xd800u) << 10) + (low - 0xdc00u);
        } else if (scalar >= 0xdc00 && scalar <= 0xdfff) {
            return nil;
        }

        if (wq_is_name_format_scalar(scalar) || scalar == 0x2028 || scalar == 0x2029) {
            [safe appendString:@"\uFFFD"];
        } else if (scalar <= 0xffff) {
            [safe appendFormat:@"%C", (unichar)scalar];
        } else {
            scalar -= 0x10000u;
            [safe appendFormat:@"%C%C", (unichar)(0xd800u + (scalar >> 10)),
             (unichar)(0xdc00u + (scalar & 0x3ffu))];
        }
    }

    NSString *normalized = [safe precomposedStringWithCanonicalMapping];
    normalized = [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!normalized.length || [normalized hasPrefix:@"/"] || [normalized containsString:@".app/"]) return nil;
    if ([normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return normalized;
}

static BOOL wq_parse_ls_store(NSData *data, NSDictionary **displayOut,
                              NSDictionary **bundleNameOut)
{
    if (displayOut) *displayOut = nil;
    if (bundleNameOut) *bundleNameOut = nil;

    const uint8_t *b = data.bytes;
    size_t n = data.length;
    if (n < kWQLSMinStoreBytes || !b || memcmp(b, "bdsl", 4) != 0) {
        wq_log(@"names: not a LaunchServices store");
        return NO;
    }
    NSRange heapRange = [data rangeOfData:[NSData dataWithBytes:"<string>" length:8]
                                  options:0 range:NSMakeRange(0, n)];
    size_t heap = heapRange.location == NSNotFound ? 0 : heapRange.location;

    // Pass 1: Bundle records, and which string ids they need.
    const uint32_t kIDs = kWQLSMaxStringID;
    size_t bitsetBytes = kIDs / 8;
    uint8_t *need = calloc(bitsetBytes, 1), *inHeap = calloc(bitsetBytes, 1);
    NSMutableData *recs = [NSMutableData dataWithCapacity:kWQLSMaxBundleRecords * 3 * sizeof(uint32_t)];
    if (!need || !inHeap || !recs) {
        free(need);
        free(inHeap);
        wq_log(@"names: LaunchServices parser allocation failed");
        return NO;
    }

    BOOL tooManyRecords = NO;
    for (size_t o = 0; o <= n - 8 - 0x250; o += 4) {
        if (wq_rd32(b + o + 4) != 0x250) continue;
        if (recs.length / (3 * sizeof(uint32_t)) >= kWQLSMaxBundleRecords) {
            tooManyRecords = YES;
            break;
        }
        const uint8_t *u = b + o + 8;
        uint32_t r[3] = { wq_rd32(u + 0x0c), wq_rd32(u + 0x6c), wq_rd32(u + 0x74) };
        if (!r[0] || (r[0] & 3) || (r[0] >> 2) >= kIDs) continue;
        [recs appendBytes:r length:sizeof(r)];
        for (int i = 0; i < 3; i++) {
            if (r[i] && !(r[i] & 3) && (r[i] >> 2) < kIDs)
                need[(r[i] >> 2) / 8] |= 1 << ((r[i] >> 2) % 8);
        }
    }
    if (tooManyRecords) {
        free(need);
        free(inHeap);
        wq_log(@"names: LaunchServices store exceeds record limit");
        return NO;
    }

    // Pass 2: the strings, preferring copies inside the string table.
    NSMutableDictionary<NSNumber *, NSString *> *strings = [NSMutableDictionary new];
    NSUInteger decodedStringBytes = 0;
    BOOL tooManyStrings = NO;
    for (size_t o = 0; o <= n - 8; o += 4) {
        uint32_t sid = wq_rd32(b + o);
        if (!sid || sid >= kIDs || !(need[sid / 8] & (1 << (sid % 8)))) continue;
        BOOL here = o >= heap, had = strings[@(sid)] != nil;
        if (had && (!here || (inHeap[sid / 8] & (1 << (sid % 8))))) continue;
        NSString *s = wq_cs_string(b, n, o);
        if (!s) continue;
        if (!had && (strings.count >= kWQLSMaxDecodedStrings ||
                     s.length > kWQLSMaxDecodedStringBytes - decodedStringBytes)) {
            tooManyStrings = YES;
            break;
        }
        strings[@(sid)] = s;
        if (!had) decodedStringBytes += s.length;
        if (here) inHeap[sid / 8] |= 1 << (sid % 8);
    }
    free(need);
    free(inHeap);
    if (tooManyStrings) {
        wq_log(@"names: LaunchServices store exceeds string limit");
        return NO;
    }
    if (!recs.length) {
        wq_log(@"names: LaunchServices store contains no bundle records");
        return NO;
    }

    NSMutableDictionary *display = [NSMutableDictionary new], *bundleName = [NSMutableDictionary new];
    const uint32_t *r = recs.bytes;
    for (NSUInteger i = 0; i < recs.length / sizeof(uint32_t); i += 3) {
        NSString *bid = strings[@(r[i] >> 2)];
        if (!wq_looks_like_bundle_id(bid)) continue;
        NSString *nm = (r[i + 1] & 3) ? nil : strings[@(r[i + 1] >> 2)];
        NSString *dn = (r[i + 2] & 3) ? nil : strings[@(r[i + 2] >> 2)];
        NSString *safeDisplay = wq_safe_name(dn);
        NSString *safeBundleName = wq_safe_name(nm);
        if (safeDisplay && !display[bid]) display[bid] = safeDisplay;
        if (safeBundleName && !bundleName[bid]) bundleName[bid] = safeBundleName;
    }

    if (displayOut) *displayOut = [display copy];
    if (bundleNameOut) *bundleNameOut = [bundleName copy];
    return YES;
}

static NSDictionary *gLSDisplay;
static NSDictionary *gLSBundleName;
static NSString *gLSStorePath;
static NSDictionary *gLSStoreSignature;
static BOOL gLSLoaded;
static NSUInteger gLSFailureCount;
static NSTimeInterval gLSNextRetryAt;

static void wq_ls_clear_snapshot_if_changed(BOOL changed)
{
    if (!changed) return;
    gLSDisplay = nil;
    gLSBundleName = nil;
    gLSStorePath = nil;
    gLSStoreSignature = nil;
    gLSLoaded = NO;
}

static void wq_ls_note_failure(NSTimeInterval now, NSString *reason)
{
    gLSFailureCount = MIN(gLSFailureCount + 1, (NSUInteger)6);
    NSUInteger shift = gLSFailureCount > 1 ? gLSFailureCount - 1 : 0;
    NSTimeInterval delay = (NSTimeInterval)(1u << MIN(shift, (NSUInteger)5));
    gLSNextRetryAt = now + delay;
    if (reason) wq_log(@"names: %@; retrying in %.0f s", reason, delay);
}

static void wq_load_ls_names_locked(void)
{
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    BOOL currentChanged = NO;
    if (gLSLoaded && gLSStorePath) {
        struct stat current;
        if (wq_ls_candidate_info(gLSStorePath, &current)) {
            NSDictionary *signature = wq_ls_signature(&current);
            currentChanged = !wq_ls_signature_equal(signature, gLSStoreSignature);
            if (!currentChanged) return;
        } else {
            currentChanged = YES;
        }
    } else if (!gLSLoaded && now < gLSNextRetryAt) {
        return;
    } else if (!gLSLoaded && ![NSUserDefaults.standardUserDefaults stringForKey:kWQLSStoreKey].length) {
        NSDate *missed = [NSUserDefaults.standardUserDefaults objectForKey:kWQLSMissKey];
        if ([missed isKindOfClass:NSDate.class] && now - missed.timeIntervalSinceReferenceDate < kWQLSMissRetry &&
            now >= missed.timeIntervalSinceReferenceDate) {
            gLSNextRetryAt = missed.timeIntervalSinceReferenceDate + kWQLSMissRetry;
            return;
        }
    }

    BOOL hadLocation = [NSUserDefaults.standardUserDefaults stringForKey:kWQLSStoreKey].length > 0;
    BOOL searched = NO;
    NSString *path = wq_find_ls_store(&searched);
    if (!path) {
        wq_ls_clear_snapshot_if_changed(currentChanged);
        if (!hadLocation && searched) {
            // Never found, after a complete search: wait a day (or a refresh).
            [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:kWQLSMissKey];
            gLSNextRetryAt = now + kWQLSMissRetry;
            wq_log(@"names: LaunchServices database not found; searching again in a day or on refresh");
        } else {
            // A known database that's briefly unreadable, or a scan that failed.
            wq_ls_note_failure(now, @"LaunchServices database not found");
        }
        return;
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQLSMissKey];

    struct stat before;
    if (!wq_ls_candidate_info(path, &before)) {
        wq_ls_clear_snapshot_if_changed(currentChanged);
        wq_ls_note_failure(now, wq_ls_error(path, @"candidate is no longer valid"));
        return;
    }
    NSDictionary *beforeSignature = wq_ls_signature(&before);
    BOOL snapshotChanged = !gLSLoaded || ![path isEqualToString:gLSStorePath] ||
        !wq_ls_signature_equal(beforeSignature, gLSStoreSignature);
    if (gLSLoaded && [path isEqualToString:gLSStorePath] &&
        wq_ls_signature_equal(beforeSignature, gLSStoreSignature)) {
        gLSFailureCount = 0;
        gLSNextRetryAt = 0;
        return;
    }

    NSString *error = nil;
    NSData *data = wq_read(path, kWQLSMaxStoreBytes + 1, &error);
    if (!data || data.length > kWQLSMaxStoreBytes) {
        wq_ls_clear_snapshot_if_changed(snapshotChanged);
        wq_ls_note_failure(now, wq_ls_error(path, error ?: @"store exceeds size limit"));
        return;
    }

    NSDictionary *display = nil, *bundleName = nil;
    if (!wq_parse_ls_store(data, &display, &bundleName)) {
        wq_ls_clear_snapshot_if_changed(snapshotChanged);
        wq_ls_note_failure(now, wq_ls_error(path, @"store rejected by bounded parser"));
        return;
    }

    // Do not publish a snapshot that was changed while it was being read or parsed.
    struct stat after;
    if (!wq_ls_candidate_info(path, &after) || !wq_ls_stat_equal(&before, &after)) {
        wq_ls_clear_snapshot_if_changed(snapshotChanged);
        wq_ls_note_failure(now, wq_ls_error(path, @"store changed during read"));
        return;
    }

    // Dictionaries are immutable copies and are assigned only after a complete,
    // validated parse. Readers therefore see either the previous snapshot or this one.
    gLSDisplay = [display copy] ?: @{};
    gLSBundleName = [bundleName copy] ?: @{};
    gLSStorePath = [path copy];
    gLSStoreSignature = [beforeSignature copy];
    gLSLoaded = YES;
    gLSFailureCount = 0;
    gLSNextRetryAt = 0;
    [NSUserDefaults.standardUserDefaults setObject:gLSStorePath forKey:kWQLSStoreKey];
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

static NSString *wq_known_name_locked(NSString *bundleID)
{
    wq_load_ls_names_locked();
    return gLSDisplay[bundleID] ?: wq_builtin_names()[bundleID] ?: gLSBundleName[bundleID];
}

BOOL wq_display_names_loaded(void)
{
    @synchronized (wq_ls_lock()) { return gLSLoaded; }
}

void wq_load_display_names(void)
{
    @synchronized (wq_ls_lock()) { wq_load_ls_names_locked(); }
}

void wq_display_names_reset_miss(void)
{
    @synchronized (wq_ls_lock()) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQLSMissKey];
        gLSNextRetryAt = 0;
        gLSFailureCount = 0;
    }
}

NSString *wq_display_name(NSString *bundleID)
{
    if (!bundleID) return nil;
    @synchronized (wq_ls_lock()) {
        NSString *name = wq_known_name_locked(bundleID);
        if (name) return name;
        // Unknown id: use the closest parent app (com.apple.news.widget -> News).
        NSArray *parts = [bundleID componentsSeparatedByString:@"."];
        for (NSInteger n = (NSInteger)parts.count - 1; n >= 2; n--) {
            NSString *prefix = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."];
            NSString *parent = wq_known_name_locked(prefix);
            if (parent) {
                NSString *suffix = wq_safe_name(parts.lastObject);
                return suffix.length ? [NSString stringWithFormat:@"%@ \u2013 %@", parent, suffix] : parent;
            }
        }
        return nil;
    }
}
