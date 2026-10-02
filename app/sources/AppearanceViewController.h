#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Accent colour picker. Pushes instead of the old sheet, writes on every
// change, and no longer offers dark/light: the app window is light-only.
// The spectrum maths is the same one AppSettingsViewController used.
@interface AppearanceViewController : UIViewController
@end

#ifdef __cplusplus
}
#endif