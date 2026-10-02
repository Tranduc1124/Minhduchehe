#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// DNS row target. The install itself lives in DNSProfile; this is the screen
// around it — the two status rows, the button, and the note about what iOS
// will and will not do on its own.
@interface DNSViewController : UIViewController
@end

#ifdef __cplusplus
}
#endif