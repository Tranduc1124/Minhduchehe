#import "MainApplicationDelegate.h"
#import "MainApplication.h"
#import "GameViewController.h"
#import "LogViewController.h"
#import "SettingsViewController.h"
#import "MDTheme.h"
#import "MDUI.h"
#import "MDLog.h"
#import "ESPPrefs.h"
#import "KeepAlive.h"
#import "HUDHelper.h"
#import "SpringBoardOverlay.h"
#import "MDLicenseGate.h"
#import "../KernelBoot.h"

// The custom accent picker is gone, but an install that used it has
// AppAccentMode=1 and an RGB triple on disk. The app's own MDTheme ignores
// them now; ModMenuViewController.mm has its own copy of those tokens and is
// frozen, so it would still pick the old colour up. Clearing the keys once
// here puts both halves back on mint.
static void MDResetAccentPrefs(void) {
    if (ESPPrefsFloat(@"AppAccentMode", 0.0f) == 0.0f &&
        ESPPrefsFloat(@"AppAccentColorR", -1.0f) < 0.0f &&
        ESPPrefsFloat(@"AppAccentColorG", -1.0f) < 0.0f &&
        ESPPrefsFloat(@"AppAccentColorB", -1.0f) < 0.0f) {
        return;
    }
    ESPPrefsSetFloat(@"AppAccentMode", 0.0f);
    ESPPrefsSetFloat(@"AppAccentColorR", kMDThemeDefaultAccentR);
    ESPPrefsSetFloat(@"AppAccentColorG", kMDThemeDefaultAccentG);
    ESPPrefsSetFloat(@"AppAccentColorB", kMDThemeDefaultAccentB);
    ESPPrefsSync();
}

@implementation MainApplicationDelegate {
    UITabBarController *_tabController;
    UIViewController *_lockController;
}

- (void)themeDidChange {
    MDThemeLoadFromPrefs();
    self.window.backgroundColor = MDThemeBg();
    if (_tabController) MDThemeApplyToTabBar(_tabController.tabBar);
    for (UINavigationController *nav in _tabController.viewControllers) {
        MDUIApplyNavigationBarStyle(nav.navigationBar);
    }
}

/// Builds the tab bar UI. Only installed as the window root once the license
/// gate authorizes, so an unlicensed run never reaches the product.
- (UITabBarController *)buildMainTabController {
    GameViewController *gameVC = [[GameViewController alloc] init];
    LogViewController *logVC = [[LogViewController alloc] init];
    SettingsViewController *settingsVC = [[SettingsViewController alloc] init];

    UINavigationController *gameNav = [[UINavigationController alloc] initWithRootViewController:gameVC];
    UINavigationController *logNav = [[UINavigationController alloc] initWithRootViewController:logVC];
    UINavigationController *settingsNav = [[UINavigationController alloc] initWithRootViewController:settingsVC];

    for (UINavigationController *nav in @[ gameNav, logNav, settingsNav ]) {
        nav.navigationBarHidden = NO;
        nav.view.userInteractionEnabled = YES;
        MDUIApplyNavigationBarStyle(nav.navigationBar);
    }

    if (@available(iOS 13.0, *)) {
        gameNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Game"
                                                            image:MDUISymbol(@"gamecontroller.fill", 22.0f, UIFontWeightRegular)
                                                              tag:0];
        logNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Log"
                                                           image:MDUISymbol(@"terminal.fill", 22.0f, UIFontWeightRegular)
                                                             tag:1];
        settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Settings"
                                                                image:MDUISymbol(@"gearshape.2.fill", 22.0f, UIFontWeightRegular)
                                                                  tag:2];
    } else {
        gameNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Game" image:nil tag:0];
        logNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Log" image:nil tag:1];
        settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Settings" image:nil tag:2];
    }

    UITabBarController *tab = [[UITabBarController alloc] init];
    tab.viewControllers = @[ gameNav, logNav, settingsNav ];
    tab.selectedIndex = 0;
    tab.view.userInteractionEnabled = YES;
    tab.tabBar.userInteractionEnabled = YES;
    MDThemeApplyToTabBar(tab.tabBar);
    return tab;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id> *)launchOptions {
    MDResetAccentPrefs();
    MDThemeLoadFromPrefs();

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    // The app is light-only. UIViewControllerBasedStatusBarAppearance is
    // false in Info.plist, so the window's style also decides the status bar.
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.window.backgroundColor = MDThemeBg();

    // KernelBoot has a single C callback, so the sink goes in once here
    // rather than per screen. Both log views read the same buffer.
    [MDLog attachKernelBoot];

    // Drop the optimistic flag when nothing is actually running. App_LocalHUDState
    // is written the moment the user taps Activate and is what makes the Game
    // tab turn into a Stop button without waiting for a poll. It also survives
    // the process that wrote it, so a kernel-only launch used to open on a Stop
    // button for a session that had ended long ago: the first tap killed
    // nothing and the second one started the real thing.
    if (!ESPRealSessionRunning() && ESPPrefsBool(@"App_LocalHUDState", NO)) {
        ESPPrefsSetBool(@"App_LocalHUDState", NO);
        ESPPrefsSync();
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(themeDidChange)
                                                 name:MDThemeDidChangeNotification
                                               object:nil];

    // License gate: the window opens on the lock screen and only swaps to the
    // tab bar once the SDK reports a fresh signed lease. AutoBoot and the
    // exploit run after authorization, never before it.
    // __typeof__ not typeof: the project compiles .mm with -std=c++17, and
    // strict mode rejects the GNU typeof spelling.
    __weak __typeof__(self) weakSelf = self;
    _lockController = [MDLicenseGate lockViewController];
    self.window.rootViewController = _lockController;
    [self.window makeKeyAndVisible];

    [MDLicenseGate startWithAuthorized:^{
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_tabController = [strongSelf buildMainTabController];
        MDThemeApplyToTabBar(strongSelf->_tabController.tabBar);
        strongSelf.window.rootViewController = strongSelf->_tabController;
        [strongSelf->_lockController removeFromParent];
        strongSelf->_lockController = nil;
        if (ESPPrefsBool(@"AutoBootOnLaunch", NO)) {
            [MDLog appendLine:@"RUN Preparing the exploit at launch."];
            kernelBootStartKernelOnly();
        }
    } terminal:^(NSString *message) {
        [MDLog appendLine:[NSString stringWithFormat:@"LICENSE %@", message]];
    }];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // KeepAlive must survive audio interruptions / media-server resets.
    [[KeepAlive shared] start];
    dispatch_async(dispatch_get_main_queue(), ^{
        ESPPrefsSync();
        MDThemeLoadFromPrefs();
        if (self->_tabController) MDThemeApplyToTabBar(self->_tabController.tabBar);
    });
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Re-assert silent audio + bg task so process is not jetsammed.
    [[KeepAlive shared] start];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    // Do NOT restore krw sockets — the exploit bumps so_usecount to
    // astronomically high values so sodealloc never fires. Restoring
    // (hacking usecount back) triggers sodealloc on the corrupted
    // socket → kernel panic → device respring. The leak IS the fix.
    //
    // Hide SB overlay so a killed app does not leave a ghost DrawView.
    SBoardStopOverlay();
}

@end