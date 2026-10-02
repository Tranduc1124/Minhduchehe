
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL IsHUDEnabled(void);
void SetHUDEnabled(BOOL isEnabled);

void RequestExitHUD(void);

// The app's real answer to "is an ESP session running?".
//
// IsHUDEnabled() only answers for the separate -hud process, and that process
// is not what draws here: StartESPHost() puts the ESP_View window in this
// process and SBRemotePushESPFrame mirrors it into SpringBoard. So a live
// session left IsHUDEnabled() false, the status card read Inactive, and the
// start row never turned into a stop row.
//
// Four signals, any one of which means a session exists:
//   ESPHostIsRunning      the local host window is up
//   SBoardOverlayIsOn     the SpringBoard DrawView is up
//   IsHUDEnabled          the -hud process is up, for the older path
//   App_LocalHUDState     the user's last tap in this app, for the window
//                         between a tap and the host appearing
BOOL IsESPSessionRunning(void);

// The three signals that report something actually running, with no pref in
// the answer. IsESPSessionRunning falls back to App_LocalHUDState so the Game
// tab flips to a stop button the moment it is tapped; that flag outlives the
// process that wrote it, so anything that needs to know what is true right now
// rather than what was last asked for has to ask this instead.
BOOL ESPRealSessionRunning(void);

// Actually stops the session, whichever parts are up. SetHUDEnabled(NO) only
// kills the -hud process; the parts that draw live in this process and in
// SpringBoard, so a stop that does not call this leaves ESP on screen while
// the UI reports it stopped. Main thread.
void StopESPSession(void);

#ifdef __cplusplus
}
#endif
