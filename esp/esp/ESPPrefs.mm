#import "ESPPrefs.h"
#import <Foundation/Foundation.h>

// Fixed suite + file so settings survive restart / reinstall of tipa better than
// process-local defaults alone. Legacy path is still read for migration.
static NSString *const kPrefsSuiteName = @"com.trminhduc.fifai.settings";
static NSString *const kPrefsFileName  = @"com.trminhduc.fifai.settings.plist";
static NSString *const kLegacyPrefsPath = @"/var/mobile/Library/Preferences/com.hth.shared.plist";

static NSMutableDictionary *gCache = nil;
static NSUserDefaults *gSuite = nil;
static NSString *gPrimaryPath = nil;
static NSString *gBackupPath = nil;
static dispatch_once_t gLoadOnce;

static NSArray<NSString *> *ESPPrefsCandidatePaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    [paths addObject:[@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:kPrefsFileName]];
    [paths addObject:kLegacyPrefsPath];

    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count > 0) {
        [paths addObject:[docs.firstObject stringByAppendingPathComponent:kPrefsFileName]];
    }

    NSArray<NSString *> *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (caches.count > 0) {
        [paths addObject:[caches.firstObject stringByAppendingPathComponent:kPrefsFileName]];
    }

    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:kPrefsFileName];
    if (tmp.length > 0) {
        [paths addObject:tmp];
    }

    return paths;
}

static BOOL ESPPrefsEnsureParentDir(NSString *path) {
    if (path.length == 0) return NO;
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (dir.length == 0) return NO;
    NSError *err = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                        withIntermediateDirectories:YES
                                                         attributes:nil
                                                              error:&err];
    return ok || [[NSFileManager defaultManager] fileExistsAtPath:dir];
}

static BOOL ESPPrefsCanUsePath(NSString *path) {
    if (path.length == 0) return NO;
    if ([path isEqualToString:kLegacyPrefsPath]) return NO; // migrate-from only
    if (!ESPPrefsEnsureParentDir(path)) return NO;

    NSString *probe = [path stringByAppendingString:@".writeprobe"];
    NSError *err = nil;
    BOOL wrote = [@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (wrote) {
        [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
        return YES;
    }
    return NO;
}

static void ESPPrefsChoosePaths(void) {
    NSArray<NSString *> *candidates = ESPPrefsCandidatePaths();
    for (NSString *path in candidates) {
        if (ESPPrefsCanUsePath(path)) {
            gPrimaryPath = path;
            break;
        }
    }
    if (!gPrimaryPath) {
        // Last resort: still point at preferred location even if probe failed.
        gPrimaryPath = candidates.firstObject;
        ESPPrefsEnsureParentDir(gPrimaryPath);
    }

    // Backup in app Documents when primary is outside container.
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count > 0) {
        gBackupPath = [docs.firstObject stringByAppendingPathComponent:kPrefsFileName];
        if ([gBackupPath isEqualToString:gPrimaryPath]) {
            gBackupPath = nil;
        } else {
            ESPPrefsEnsureParentDir(gBackupPath);
        }
    }
}

static BOOL ESPPrefsWriteDictionary(NSDictionary *dict, NSString *path) {
    if (!dict || path.length == 0) return NO;
    if (!ESPPrefsEnsureParentDir(path)) return NO;

    NSString *tmp = [path stringByAppendingString:@".tmp"];
    if ([dict writeToFile:tmp atomically:YES]) {
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if ([[NSFileManager defaultManager] moveItemAtPath:tmp toPath:path error:&err]) {
            return YES;
        }
        // Fallback if move fails (cross-device rare on iOS).
        return [dict writeToFile:path atomically:YES];
    }
    return [dict writeToFile:path atomically:YES];
}

static void ESPPrefsLoadIfNeeded(void) {
    dispatch_once(&gLoadOnce, ^{
        gCache = [NSMutableDictionary dictionary];
        gSuite = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuiteName];
        if (!gSuite) {
            gSuite = [NSUserDefaults standardUserDefaults];
        }

        ESPPrefsChoosePaths();

        // 1) Load first non-empty file among candidates (new path, then legacy, then docs...)
        for (NSString *path in ESPPrefsCandidatePaths()) {
            NSDictionary *fileDict = [NSDictionary dictionaryWithContentsOfFile:path];
            if (fileDict.count > 0) {
                [gCache addEntriesFromDictionary:fileDict];
                break;
            }
        }

        // 2) Merge suite domain (survives in defaults database)
        NSDictionary *suiteDomain = [gSuite persistentDomainForName:kPrefsSuiteName];
        if (suiteDomain.count > 0) {
            [suiteDomain enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                if (gCache[key] == nil) {
                    gCache[key] = obj;
                }
            }];
        }

        // 3) Merge standardUserDefaults for keys we already know about / common app keys.
        // Avoid dumping the entire Apple defaults domain into cache.
        NSArray<NSString *> *seedKeys = @[
            @"MenuLayoutStyle", @"AppLanguageIsEnglish", @"AppLanguage", @"AppThemeMode",
            @"AppAccentColor", @"AppAccentMode", @"AppAccentColorR", @"AppAccentColorG", @"AppAccentColorB", @"AppAccentColorMode",
            @"EnableHaptic", @"StreamerMode", @"SpeedX50",
            @"Speed", @"SpeedValue",
            @"FastReload", @"FastReloadSpeed", @"CamPC", @"CamPCValue",
            @"AntiBanMax", @"AutoCleanRAMPeriodic", @"AutoVarCleanBeforeHUD", @"AntiCrashRAM",
            @"FloatingMenuBtnX", @"FloatingMenuBtnY", @"FloatingAimBtnX", @"FloatingAimBtnY",
            @"FloatingAimPosBtnX", @"FloatingAimPosBtnY", @"FloatAimBtn", @"FloatAimPosBtn", @"ShowMenuIcon", @"LockMenuIcon", @"MenuIconAutoRecovered", @"MenuIconAutoRecovered_v2", @"MenuIconForceShow_v3",
            @"App_LocalHUDState", @"App_LocalInAppHackState", @"HideMenu1",
            @"EnableESP", @"EnableESP2", @"Box", @"BoxMode", @"Bone", @"Health", @"Name",
            @"Distance", @"AimDistance", @"Line", @"EspBot", @"Weapon", @"Count", @"Alert360", @"AlertNum",
            @"EspCheckVisible",
            @"AimIgnoreBot", @"AimOnBot", @"AimIgnoreKnock",
            @"AimBehindWall",
            @"AimMaster", @"AimTypeMode",
            @"AimRage", @"AimLegit", @"Aimbot", @"AimAssist", @"AimSilent", @"Aim360", @"AimSphereMode",
            @"AimMode", @"TriggerMode", @"AimPos", @"AimTargetMode", @"Fov", @"AimSpeed", @"ShowFovCircle",
            @"EspDistanceLimit", @"Norecoil", @"BrutalSpeed", @"FloatingPanelX", @"FloatingPanelY", @"MenuLastTab",
            @"CustomName", @"SetName",
            @"CustomToggleBtnX", @"CustomToggleBtnY", @"CustomToggleBtnState",
            @"SelectedGameId"
        ];
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        for (NSString *key in seedKeys) {
            id obj = [std objectForKey:key];
            if (obj != nil && gCache[key] == nil) {
                gCache[key] = obj;
            }
            // Lite-suffixed copies
            NSString *liteKey = [key stringByAppendingString:@"_Lite"];
            id liteObj = [std objectForKey:liteKey];
            if (liteObj != nil && gCache[liteKey] == nil) {
                gCache[liteKey] = liteObj;
            }
        }

        // Persist merged view immediately so next cold start has a single source of truth.
        if (gCache.count > 0) {
            ESPPrefsWriteDictionary(gCache, gPrimaryPath);
            if (gBackupPath.length > 0) {
                ESPPrefsWriteDictionary(gCache, gBackupPath);
            }
            [gSuite setPersistentDomain:[gCache copy] forName:kPrefsSuiteName];
            [gSuite synchronize];
        }
    });
}

NSString *ESPPrefsPath(void) {
    ESPPrefsLoadIfNeeded();
    return gPrimaryPath ?: kLegacyPrefsPath;
}

static BOOL IsGlobalKey(NSString *key) {
    static NSSet *globalKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        globalKeys = [NSSet setWithArray:@[
            @"MenuLayoutStyle",
            @"AppLanguageIsEnglish",
            @"AppLanguage",
            @"AppThemeMode",
            @"AppAccentColor",
            @"AppAccentMode",
            @"AppAccentColorR",
            @"AppAccentColorG",
            @"AppAccentColorB",
            @"AppAccentColorMode",
            @"EnableHaptic",
            @"StreamerMode",
                        @"SpeedX50",
            @"Speed",
            @"SpeedValue",
            @"FastReload",
            @"FastReloadSpeed",
            @"CamPC",
            @"CamPCValue",
            @"AntiBanMax",
            @"AutoCleanRAMPeriodic",
            @"AutoVarCleanBeforeHUD",
            @"AntiCrashRAM",
            @"FloatingMenuBtnX", @"FloatingMenuBtnY",
            @"FloatingAimBtnX", @"FloatingAimBtnY",
            @"FloatingAimPosBtnX", @"FloatingAimPosBtnY",
            @"FloatAimBtn",
            @"FloatAimPosBtn",
            @"ShowMenuIcon",
            @"LockMenuIcon",
            @"MenuIconAutoRecovered",
            @"MenuIconAutoRecovered_v2",
            @"MenuIconForceShow_v3",
            @"App_LocalHUDState",
            @"App_LocalInAppHackState",
            @"HideMenu1",
            @"FloatingPanelX",
            @"FloatingPanelY",
            @"CustomName",
            @"SetName",
            @"CustomToggleBtnX",
            @"CustomToggleBtnY",
            @"CustomToggleBtnState",
            @"SelectedGameId"
        ]];
    });
    return [globalKeys containsObject:key];
}

static NSString *ResolveKey(NSString *originalKey) {
    if (originalKey.length == 0) return originalKey ?: @"";
    if (IsGlobalKey(originalKey)) {
        return originalKey;
    }

    // Menu layout is global and must not itself be Lite-suffixed.
    int menuStyle = 0;
    id styleVal = nil;
    @synchronized (gCache ?: [NSNull null]) {
        styleVal = gCache[@"MenuLayoutStyle"];
    }
    if (styleVal != nil) {
        menuStyle = [styleVal intValue];
    } else {
        menuStyle = (int)[[NSUserDefaults standardUserDefaults] floatForKey:@"MenuLayoutStyle"];
    }

    if (menuStyle == 1) {
        return [NSString stringWithFormat:@"%@_Lite", originalKey];
    }
    return originalKey;
}

static dispatch_queue_t ESPPrefsIOQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("com.trminhduc.fifai.espprefs.io", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// Flush disk writes off the main thread. Memory/cache updates stay sync so
// ESPSyncFromPrefs sees toggles immediately.
static void ESPPrefsPersistAsync(BOOL forceNow) {
    ESPPrefsLoadIfNeeded();

    static dispatch_block_t sPendingBlock = nil;
    static NSObject *sPendingLock = nil;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{
        sPendingLock = [[NSObject alloc] init];
    });

    void (^flush)(void) = ^{
        NSDictionary *snap = nil;
        NSString *primary = nil;
        NSString *backup = nil;
        NSUserDefaults *suite = nil;
        @synchronized (gCache) {
            snap = [gCache copy];
            primary = gPrimaryPath;
            backup = gBackupPath;
            suite = gSuite;
        }
        if (!snap) return;

        ESPPrefsWriteDictionary(snap, primary);
        if (backup.length > 0) {
            ESPPrefsWriteDictionary(snap, backup);
        }
        [suite setPersistentDomain:snap forName:kPrefsSuiteName];
        [suite synchronize];
        // Avoid blocking main-thread UI on every toggle with standard synchronize.
    };

    if (forceNow) {
        @synchronized (sPendingLock) {
            if (sPendingBlock) {
                dispatch_block_cancel(sPendingBlock);
                sPendingBlock = nil;
            }
        }
        // Always hop to IO queue so file writes never hit the UI thread.
        if (strcmp(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL),
                   dispatch_queue_get_label(ESPPrefsIOQueue())) == 0) {
            flush();
        } else {
            dispatch_sync(ESPPrefsIOQueue(), flush);
        }
        return;
    }

    @synchronized (sPendingLock) {
        if (sPendingBlock) {
            dispatch_block_cancel(sPendingBlock);
            sPendingBlock = nil;
        }
        sPendingBlock = dispatch_block_create(DISPATCH_BLOCK_ASSIGN_CURRENT, ^{
            @synchronized (sPendingLock) {
                sPendingBlock = nil;
            }
            flush();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       ESPPrefsIOQueue(),
                       sPendingBlock);
    }
}

static void ESPPrefsPersist(void) {
    ESPPrefsPersistAsync(YES);
}

static void ESPPrefsSetValueEx(NSString *key, id value, BOOL schedulePersist) {
    if (key.length == 0) return;
    ESPPrefsLoadIfNeeded();

    NSString *realKey = ResolveKey(key);

    @synchronized (gCache) {
        if (value != nil && value != [NSNull null]) {
            // Skip no-op writes (slider can emit same float repeatedly).
            id old = gCache[realKey];
            if ([old isEqual:value]) {
                // still may need persist schedule only if forced later
            } else {
                gCache[realKey] = value;
            }
            // Live drag (schedulePersist=NO): cache only — no UserDefaults / suite writes.
            // Commit path (schedulePersist=YES): sync suite + standard for other readers.
            if (schedulePersist) {
                [gSuite setObject:value forKey:realKey];
                [[NSUserDefaults standardUserDefaults] setObject:value forKey:realKey];
            }
        } else {
            [gCache removeObjectForKey:realKey];
            if (schedulePersist) {
                [gSuite removeObjectForKey:realKey];
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:realKey];
            }
        }
    }

    if (schedulePersist) {
        // Debounced disk write — UI / ESP flags update from cache immediately.
        ESPPrefsPersistAsync(NO);
    }
}

static void ESPPrefsSetValue(NSString *key, id value) {
    ESPPrefsSetValueEx(key, value, YES);
}

static id ESPPrefsGetValue(NSString *key) {
    if (key.length == 0) return nil;
    ESPPrefsLoadIfNeeded();

    NSString *realKey = ResolveKey(key);
    @synchronized (gCache) {
        id cached = gCache[realKey];
        if (cached != nil) return cached;
    }

    id suiteVal = [gSuite objectForKey:realKey];
    if (suiteVal != nil) {
        @synchronized (gCache) {
            gCache[realKey] = suiteVal;
        }
        return suiteVal;
    }

    id stdVal = [[NSUserDefaults standardUserDefaults] objectForKey:realKey];
    if (stdVal != nil) {
        @synchronized (gCache) {
            gCache[realKey] = stdVal;
        }
        return stdVal;
    }

    return nil;
}

void ESPPrefsSetBool(NSString *key, BOOL value) {
    ESPPrefsSetValue(key, @(value));
}

void ESPPrefsSetFloat(NSString *key, float value) {
    ESPPrefsSetValue(key, @(value));
}

void ESPPrefsSetBoolLive(NSString *key, BOOL value) {
    ESPPrefsSetValueEx(key, @(value), NO);
}

void ESPPrefsSetFloatLive(NSString *key, float value) {
    ESPPrefsSetValueEx(key, @(value), NO);
}

void ESPPrefsSync(void) {
    // Force pending writes out now (background close / HUD launch / drag end).
    ESPPrefsPersistAsync(YES);
}

BOOL ESPPrefsBool(NSString *key, BOOL defaultValue) {
    id value = ESPPrefsGetValue(key);
    if (value == nil) return defaultValue;
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value boolValue];
    }
    return defaultValue;
}

float ESPPrefsFloat(NSString *key, float defaultValue) {
    id value = ESPPrefsGetValue(key);
    if (value == nil) return defaultValue;
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value floatValue];
    }
    return defaultValue;
}

id AppSettingsObjectForKey(NSString *key) {
    return ESPPrefsGetValue(key);
}

void AppSettingsSetObject(NSString *key, id value) {
    ESPPrefsSetValue(key, value);
}

void AppSettingsRemoveKeys(NSArray<NSString *> *keys) {
    if (keys.count == 0) return;
    ESPPrefsLoadIfNeeded();

    @synchronized (gCache) {
        for (NSString *k in keys) {
            NSString *realKey = ResolveKey(k);
            [gCache removeObjectForKey:realKey];
            [gSuite removeObjectForKey:realKey];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:realKey];
        }
    }
    ESPPrefsPersist();
}
