#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Three switches, each backed by something that already exists:
//   AutoBootOnLaunch  runs the boot from application:didFinishLaunching
//   SandboxEscapeOn   gates sandbox_escape in KernelBoot stage 3
//   KeepAliveOn       gates KeepAlive.start, which every caller goes through
@interface LaunchOptionsViewController : UITableViewController
@end

#ifdef __cplusplus
}
#endif