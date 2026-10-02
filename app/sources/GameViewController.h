#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Game tab: status card, activate/deactivate action, and the startup console.
//
// Starting the session is the only thing on this screen that touches the
// kernel, so it lives behind a deliberate tap on the action row. The VarClean
// and kernel boot steps come from app/KernelBoot.m unchanged.
@interface GameViewController : UIViewController
@end

#ifdef __cplusplus
}
#endif