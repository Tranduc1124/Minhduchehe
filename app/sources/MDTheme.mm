#import "MDTheme.h"
#import "ESPPrefs.h"

NSString * const MDThemeDidChangeNotification = @"MDThemeDidChangeNotification";

const float kMDThemeDefaultAccentR = 0.208f;
const float kMDThemeDefaultAccentG = 0.827f;
const float kMDThemeDefaultAccentB = 0.604f;

static int g_accentMode = 0;
static float g_ar = kMDThemeDefaultAccentR;
static float g_ag = kMDThemeDefaultAccentG;
static float g_ab = kMDThemeDefaultAccentB;

// Light-only palette. These are the systemGroupedBackground /
// secondarySystemGroupedBackground / separator / label / secondaryLabel light
// values written out as literals rather than looked up by name, because the
// app runs on iOS 15+ where all five exist; the literals only mean the app
// looks the same if a lookup ever fails on an odd build.
static UIColor *MDHex(uint32_t rgb, CGFloat alpha) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:alpha];
}

void MDThemeLoadFromPrefs(void) {
    g_accentMode = (int)ESPPrefsFloat(@"AppAccentMode", 0.0f);
    if (g_accentMode < 0) g_accentMode = 0;
    if (g_accentMode > 1) g_accentMode = 1;
    if (g_accentMode == 0) {
        g_ar = kMDThemeDefaultAccentR;
        g_ag = kMDThemeDefaultAccentG;
        g_ab = kMDThemeDefaultAccentB;
    } else {
        g_ar = ESPPrefsFloat(@"AppAccentColorR", kMDThemeDefaultAccentR);
        g_ag = ESPPrefsFloat(@"AppAccentColorG", kMDThemeDefaultAccentG);
        g_ab = ESPPrefsFloat(@"AppAccentColorB", kMDThemeDefaultAccentB);
        if (g_ar < 0) g_ar = 0; if (g_ar > 1) g_ar = 1;
        if (g_ag < 0) g_ag = 0; if (g_ag > 1) g_ag = 1;
        if (g_ab < 0) g_ab = 0; if (g_ab > 1) g_ab = 1;
    }
}

void MDThemeNotifyChanged(void) {
    MDThemeLoadFromPrefs();
    [[NSNotificationCenter defaultCenter] postNotificationName:MDThemeDidChangeNotification object:nil];
}

BOOL MDThemeIsLight(void) { return YES; }
int MDThemeAccentMode(void) { return g_accentMode; }

UIColor *MDThemeBg(void)     { return MDHex(0xF2F2F7, 1.0f); } // systemGroupedBackground
UIColor *MDThemePanel(void)  { return MDHex(0xFFFFFF, 1.0f); } // card
UIColor *MDThemePanel2(void) { return MDHex(0xEFEFF4, 1.0f); } // secondary fill
UIColor *MDThemeLine(void)   { return MDHex(0xC6C6C8, 0.7f); }  // separator
UIColor *MDThemeText(void)   { return MDHex(0x000000, 1.0f); }
UIColor *MDThemeMuted(void)  { return MDHex(0x8A8A8E, 1.0f); } // secondaryLabel

UIColor *MDThemeAccent(void) {
    return [UIColor colorWithRed:g_ar green:g_ag blue:g_ab alpha:1.0f];
}
UIColor *MDThemeAccentSoft(CGFloat alpha) {
    return [UIColor colorWithRed:g_ar green:g_ag blue:g_ab alpha:alpha];
}

UIColor *MDThemeBlue(void)   { return MDHex(0x007AFF, 1.0f); }
UIColor *MDThemeGreen(void)  { return MDHex(0x34C759, 1.0f); }
UIColor *MDThemeOrange(void) { return MDHex(0xFF9500, 1.0f); }
UIColor *MDThemeRed(void)    { return MDHex(0xFF3B30, 1.0f); }
UIColor *MDThemeTeal(void)   { return MDHex(0x30B0C7, 1.0f); }
UIColor *MDThemePurple(void) { return MDHex(0xAF52DE, 1.0f); }

// SF Pro. The bundled Inter/FA .ttf files this used to load are not in the
// repo, so every one of those lookups fell through to the system font anyway.
UIFont *MDThemeFont(CGFloat size, UIFontWeight weight) {
    return [UIFont systemFontOfSize:size weight:weight];
}

void MDThemeApplyToTabBar(UITabBar *tabBar) {
    if (!tabBar) return;
    MDThemeLoadFromPrefs();
    tabBar.translucent = NO;
    tabBar.tintColor = MDThemeAccent();
    if ([tabBar respondsToSelector:@selector(setUnselectedItemTintColor:)]) {
        tabBar.unselectedItemTintColor = MDThemeMuted();
    }
    tabBar.barTintColor = MDThemePanel();
    tabBar.backgroundColor = MDThemePanel();

    Class appearanceCls = NSClassFromString(@"UITabBarAppearance");
    if (!appearanceCls) return;
    id app = [[appearanceCls alloc] init];
    if ([app respondsToSelector:@selector(configureWithOpaqueBackground)]) {
        [app configureWithOpaqueBackground];
    }
    if ([app respondsToSelector:@selector(setBackgroundColor:)]) {
        [app setBackgroundColor:MDThemePanel()];
    }
    if ([app respondsToSelector:@selector(setShadowColor:)]) {
        [app setShadowColor:MDThemeLine()];
    }
    UIColor *sel = MDThemeAccent();
    UIColor *uns = MDThemeMuted();
    @try {
        id stacked = [app valueForKey:@"stackedLayoutAppearance"];
        id normal = [stacked valueForKey:@"normal"];
        id selected = [stacked valueForKey:@"selected"];
        [normal setValue:uns forKey:@"iconColor"];
        [normal setValue:@{ NSForegroundColorAttributeName: uns } forKey:@"titleTextAttributes"];
        [selected setValue:sel forKey:@"iconColor"];
        [selected setValue:@{ NSForegroundColorAttributeName: sel } forKey:@"titleTextAttributes"];
    } @catch (__unused NSException *e) {}
    if ([tabBar respondsToSelector:@selector(setStandardAppearance:)]) {
        [tabBar setValue:app forKey:@"standardAppearance"];
    }
    if ([tabBar respondsToSelector:NSSelectorFromString(@"setScrollEdgeAppearance:")]) {
        @try { [tabBar setValue:app forKey:@"scrollEdgeAppearance"]; } @catch (__unused NSException *e) {}
    }
}