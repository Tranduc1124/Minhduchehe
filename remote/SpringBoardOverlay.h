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

// Read-only view of whether the SpringBoard-hosted DrawView is currently up.
// The app UI needs a real answer for its status card: IsHUDEnabled() only
// knows about the separate -hud process and stays false while the session in
// this process is live and drawing.
int SBoardOverlayIsOn(void);
// Mirror the local ESP_View into the SB-hosted view (called every frame
// from updateFrame; no-op when the overlay isn't up).
void SBRemotePushESPFrame(UIView *espView);

// Take the name plate and the name glyphs off the screen, once.
//
// A CAShapeLayer keeps whatever path it was last handed, and the layers that hold
// the plate and the names are cleared by the publish's "off edge" — which only
// runs inside a publish. When a match ends the ESP goes completely silent:
// mergePaths returns NO, SBRemotePushESPFrame drops the frame before the publish
// body, and no publish happens at all. So the plate and the names were never
// cleared and the dark plate stayed on screen for the rest of the session.
//
// Called by the app at the match -> lobby edge. Takes the transport lock, so it
// cannot interleave inside a publish.
void SBClearESPNameLayers(void);

#ifdef __cplusplus
}
#endif
