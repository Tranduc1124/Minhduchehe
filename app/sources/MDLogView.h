#import <UIKit/UIKit.h>

// Shared log console view.
//
// Two screens use it: LogViewController (whole history) and
// BootLogViewController (startup, with a Hide button). Both read the same
// MDLog buffer, so a boot started from the Game tab shows up on the Log tab
// too.

#ifdef __cplusplus
extern "C" {
#endif

@interface MDLogView : UIView

// Drops whatever the view is showing and re-reads MDLog. The view also
// observes MDLog itself, so this is only needed when the buffer changed
// underneath it.
- (void)refresh;

@end

#ifdef __cplusplus
}
#endif