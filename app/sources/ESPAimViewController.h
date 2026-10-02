#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Every ESP/aim switch the app exposes, grouped as on the reference screen:
// SCREEN, DRAW, VIEW, AIM. Each one writes its pref live and calls
// ESPSyncFromPrefs so the next frame of a running session sees it.
@interface ESPAimViewController : UITableViewController
@end

#ifdef __cplusplus
}
#endif