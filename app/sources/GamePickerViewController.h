#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Picks which build to attach to: Free Fire MAX or Free Fire THG.
// Writes through GameTargetSetSelectedId, which also reloads the offset table.
@interface GamePickerViewController : UITableViewController
@end

#ifdef __cplusplus
}
#endif