#import <UIKit/UIKit.h>

// App chrome theme.
//
// The app is light-only: MainApplicationDelegate forces
// UIUserInterfaceStyleLight on the window, so there is no second palette to
// keep in sync and MDThemeIsLight() always answers YES. The accent stays
// user-selectable (prefs: AppAccentMode, AppAccentColorR/G/B) because the
// accent is used for the tab bar, the Activate row and the accent picker.
//
// The in-game menu has its own copy of these tokens inside
// ModMenuViewController.mm and reads AppThemeMode/AppAccent* straight from
// prefs. Nothing here writes AppThemeMode, so switching the app to light can
// never move the in-game menu's theme.
//
// ModMenuViewController.mm is frozen. Only the app process uses this header.

#ifdef __cplusplus
extern "C" {
#endif

extern NSString * const MDThemeDidChangeNotification;

void MDThemeLoadFromPrefs(void);
void MDThemeNotifyChanged(void);

BOOL MDThemeIsLight(void);
int MDThemeAccentMode(void); // 0 default mint, 1 custom

UIColor *MDThemeBg(void);
UIColor *MDThemePanel(void);
UIColor *MDThemePanel2(void);
UIColor *MDThemeLine(void);
UIColor *MDThemeText(void);
UIColor *MDThemeMuted(void);
UIColor *MDThemeAccent(void);
UIColor *MDThemeAccentSoft(CGFloat alpha);
UIColor *MDThemeBlue(void);
UIColor *MDThemeOrange(void);
UIColor *MDThemeRed(void);
UIColor *MDThemeGreen(void);
UIColor *MDThemeTeal(void);
UIColor *MDThemePurple(void);

UIFont *MDThemeFont(CGFloat size, UIFontWeight weight);

// Default mint accent.
extern const float kMDThemeDefaultAccentR;
extern const float kMDThemeDefaultAccentG;
extern const float kMDThemeDefaultAccentB;

// Tab bar chrome. Call again after MDThemeLoadFromPrefs when the accent moves.
void MDThemeApplyToTabBar(UITabBar *tabBar);

#ifdef __cplusplus
}
#endif