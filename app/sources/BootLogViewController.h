#import <UIKit/UIKit.h>

// Startup console shown as a sheet over the Game tab when the user taps
// Activate: light header with "Activity" and Hide, the shared MDLogView, and
// a footer that spins until KernelBoot reports ready.
//
// Dismissing it does not stop the boot. kernelBootStart() runs on its own
// queue and keeps writing into MDLog either way.

#ifdef __cplusplus
extern "C" {
#endif

@interface BootLogViewController : UIViewController
@end

#ifdef __cplusplus
}
#endif