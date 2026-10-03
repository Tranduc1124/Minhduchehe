//
//  MDLicenseGate.h — license gate for the MINHDUC app.
//
//  The main UI (Game / Log / Settings tabs) is only installed as the window's
//  root view controller after the Tserver SDK reports a fresh, signed
//  authorization lease. Without a valid key the window stays on a lock screen
//  and nothing of the product is reachable.
//
//  Deliberately NOT a security boundary: the SDK's signed lease is the
//  authority. This class only decides what the user can see.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MDLicenseGate : NSObject

/// YES once this process has a verified license (set from the SDK callback).
@property (class, nonatomic, readonly) BOOL authorized;

/// Asks the SDK for a license. Calls `onAuthorized` on the main queue only
/// after the signed lease authorizes this run; `onTerminal` receives a
/// Vietnamese message when the run ended without a license.
+ (void)startWithAuthorized:(dispatch_block_t)onAuthorized
                   terminal:(void (^)(NSString *message))onTerminal;

/// Lock screen used as rootViewController until authorized. Blocks touches.
+ (UIViewController *)lockViewController;

@end

NS_ASSUME_NONNULL_END