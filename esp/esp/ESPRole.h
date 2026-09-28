//
//  ESPRole.h
//
//  What a piece of ESP text is, shared by the app that produces it and the
//  overlay that draws it.
//
//  This lives in its own header because esp.h cannot be included from
//  SpringBoardOverlay.m: esp.h reaches GameLogic.h, which reaches Vector3.h,
//  which is C++, and the overlay is compiled as Objective-C rather than
//  Objective-C++. Declaring the enum twice, once per file, is the alternative
//  and it is the exact failure this project keeps hitting, so it is not taken.
//
//  It exists at all because the overlay used to guess. It looked for the enemy
//  counter inside the per-pawn text pool by font size, when the counter does not
//  live there, then read it back off a different layer, and the name and
//  distance labels were going to be told apart by frame width. Four builds went
//  into that. The producer already knows what each string is, so it says.
//

#ifndef ESPRole_h
#define ESPRole_h

typedef enum {
    ESPTextRoleName      = 0,   // player name, drawn in the grey card
    ESPTextRoleDistance  = 1,   // [35m], plain, under the feet
    ESPTextRoleWeapon    = 2,   // weapon name, deliberately not sent to the overlay
    ESPTextRoleCounter   = 3,   // the red count
} ESPTextRole;

#endif /* ESPRole_h */
