#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Settings tab. Four groups: GAME, QUICK ACTIONS, TWEAKS, DNS, then ABOUT.
//
// The rows are all real: every one of them either pushes a screen that exists
// or opens something that already works. Nothing here is a stub pretending to
// install a feature.
@interface SettingsViewController : UIViewController
@end

#ifdef __cplusplus
}
#endif