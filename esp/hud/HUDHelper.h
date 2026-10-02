
#import <Foundation/Foundation.h>

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
