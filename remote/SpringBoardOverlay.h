//
//  SpringBoardOverlay.h — Fl0rk-style SpringBoard overlay
//  remote_objc mirrors the local ESP_View frame into a UIView hosted in
//  SpringBoard's process — full ESP (box/bone/line/hp/name/dist/weapon/
//  fov/aim) renders above EVERY app. No entitlement.
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Call AFTER kexploit_opa334(). Returns 0 on success.
int SBoardStartOverlay(void);
void SBoardStopOverlay(void);
// Mirror the local ESP_View into the SB-hosted view (called every frame
// from updateFrame; no-op when the overlay isn't up).
void SBRemotePushESPFrame(UIView *espView);

#ifdef __cplusplus
}
#endif
