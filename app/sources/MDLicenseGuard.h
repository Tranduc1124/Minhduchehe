#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bootstraps the Tserver APIClient SDK with compile-time token obfuscation,
/// Frida guard, host function/method integrity protection, and live revocation
/// monitoring. Calls `onAuthorized` on the main thread ONLY after a signed
/// ES256 lease is verified via both `APIClientValidConfirmed()` and
/// `APIClientPerformAuthorized(@"paid", ...)`. Calls `onRevoked` on the main
/// thread whenever the lease expires, is revoked, or tampering is detected.
void MDLicenseGuardBootstrap(void (^onAuthorized)(void),
                             void (^onRevoked)(NSString *reason));

/// Forwards a custom-scheme URL (`tserver.<bundle-id>://device-auth`) to the
/// Tserver APIClient SDK during device verification.
BOOL MDLicenseGuardHandleOpenURL(NSURL *url);

/// Performs a full multi-layer live verification of the signed lease,
/// anti-tamper prologues, and `APIClientPerformAuthorized(@"paid", ...)`.
/// Returns YES only if every check passes.
BOOL MDLicenseGuardVerifyLive(const char *siteTag);

/// Executes `workBlock` ONLY if `MDLicenseGuardVerifyLive(siteTag)` and
/// `APIClientPerformAuthorized(@"paid", ...)` both succeed.
/// Returns YES if `workBlock` was executed, NO if blocked.
BOOL MDLicenseGuardPerformProtected(const char *siteTag,
                                    dispatch_block_t workBlock);

/// Lightweight periodic check for the 60Hz ESP/Aim render loop.
/// Throttles full `MDLicenseGuardVerifyLive("esp_tick")` to once every 2.0s
/// while checking the volatile lease ticket every frame.
BOOL MDLicenseGuardVerifyRenderTick(void);

/// Returns a formatted summary of the active license (e.g.
/// "Key: XXXX · Hạn: 2d 14h") or a locked status string if unauthorized.
NSString *MDLicenseGuardStatusSummary(void);

#ifdef __cplusplus
}
#endif
