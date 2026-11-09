#import "AimbotMaintenance.h"
#import <UIKit/UIKit.h>

static NSTimeInterval gLastAimbotAlert = 0;

BOOL AimbotMaintenanceActive(void) {
    return YES;
}

void AimbotShowMaintenanceAlert(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - gLastAimbotAlert < 1.0) return;
        gLastAimbotAlert = now;

        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if (window.isKeyWindow) {
                        keyWindow = window;
                        break;
                    }
                }
                if (keyWindow) break;
            }
        }
        if (!keyWindow) keyWindow = UIApplication.sharedApplication.keyWindow;

        UIViewController *presenter = keyWindow.rootViewController;
        while (presenter.presentedViewController) {
            presenter = presenter.presentedViewController;
        }
        if (!presenter) return;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Aimbot"
                                                message:@"Aimbot đang được bảo trì."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}
