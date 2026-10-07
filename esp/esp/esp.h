#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <stdint.h>

#import "GameLogic.h"
#import "WeaponTextures.h"

// One ray of a snapline fan, drawn as part of a single polyline for the whole
// layer rather than as its own subpath.
//
// Every snapline leaves the same point: layerWidth/2, 35 in one mode, the screen
// centre in the other. That makes a layer a fan from one origin, and
// CGPathAddLines joins consecutive points, so one polyline holding every ray costs
// one remote call for the layer instead of one per player. With twenty to thirty
// players that is the difference between twenty to thirty crossings a publish and
// one, and it is the only term in the overlay that scaled with the player count.
//
// Each ray goes out as origin, target, origin. The doubled leg is what fills the
// gap CGPathAddLines would otherwise leave by joining one player's target to the
// next player's origin, which would be a cable strung across the screen instead of
// a fan. Redrawing a ray in the opposite direction is idempotent under an opaque
// stroke, which all three snapline colours are; see where they are built in
// esp.mm. If anyone ever gives the stroke an alpha below one, the doubled leg
// reads as a darker seam and this needs revisiting. That note belongs here, at the
// emitter, rather than in a commit message nobody will read when they try it.
//
// The count is always 2N+1, so always odd, and the decoder's four point rectangle
// test and its two point line branch can never claim a fan. It lands in the generic
// polyline branch, which is the one it wants anyway.
//
// This was previously attempted as rectangles, which is the obvious way to batch
// it, and that was wrong twice over: a slanted line's corners are not its bounding
// box's corners so the rectangle test rejected it, and the elbow it drew hid the
// nearer player behind the farther one. The fan needs neither workaround.
//
// It lives here rather than in espdraw.mm because both emitters need it and
// espdraw.mm's helpers are file static.
static inline void ESPAddFanRay(CGMutablePathRef path, CGPoint origin, CGPoint target, bool *started) {
    if (!path || !started) return;
    if (!*started) {
        CGPathMoveToPoint(path, NULL, origin.x, origin.y);
        *started = true;
    }
    CGPathAddLineToPoint(path, NULL, target.x, target.y);
    CGPathAddLineToPoint(path, NULL, origin.x, origin.y);
}

typedef struct {
    CGMutablePathRef boxPath;
    CGMutablePathRef boxBotPath;
    CGMutablePathRef boxKnockedPath;
    
    // Đã phân tách 3 đường xương chuẩn
    CGMutablePathRef bonePath;
    CGMutablePathRef boneBotPath;
    CGMutablePathRef boneKnockedPath;
    
    CGMutablePathRef snaplinePath;
    CGMutablePathRef snaplineBotPath;
    CGMutablePathRef snaplineKnockedPath;
    
    CGMutablePathRef hpFillGreenPath;  
    CGMutablePathRef hpFillOrangePath; 
    CGMutablePathRef hpFillRedPath;    
    CGMutablePathRef alertPath;
    CGMutablePathRef bgFillBlackPath;

    // Name plate, the two halves of it.
    //
    // The host window runs at alpha 0, so a CATextLayer is never seen and the
    // nickname has to be geometry: nameTextPath carries the glyph outlines for
    // every player in the frame, nameBgPath carries one plate rectangle per
    // player. SpringBoard picks both up over KVC and fills them, white on the
    // dark plate.
    //
    // nameBgPath is here rather than drawn straight into the alert counter's
    // background because the plate's rectangle is computed in espdraw.mm, by the
    // same function that computes the box, and that background is a local of the
    // frame loop in esp.mm. The two halves of the frame meet in this struct.
    //
    // One path for all players, not one per player: a layer is published whole,
    // so thirty players cost the same two crossings as one. See the snapline fan
    // note above for the same argument about a different shape.
    CGMutablePathRef nameTextPath;
    CGMutablePathRef nameBgPath;

    bool boxDirty;
    bool boxBotDirty;
    bool boxKnockedDirty;
    
    bool boneDirty;
    bool boneBotDirty;
    bool boneKnockedDirty;
    
    bool snaplineDirty;
    bool snaplineBotDirty;
    bool snaplineKnockedDirty;

    // Whether each snapline path already holds its moveTo. Every snapline in a
    // layer leaves the same point, so the whole layer is one fan from one origin
    // and can go out as a single polyline: one remote call per layer instead of
    // one per player, which is the only per-player term in the whole overlay.
    //
    // These must be initialised in ESPGeometryBuffersCreate, and they are. The
    // struct is a raw local with no memset, so "resets because the struct is
    // rebuilt every frame" is not true on its own: it was believed to be true
    // when the fan landed, the initialiser was never extended to match, and the
    // three bytes came back as stack garbage that only ever went one way. Do not
    // add a field here without adding it there.
    bool snaplineFanStarted;
    bool snaplineBotFanStarted;
    bool snaplineKnockedFanStarted;
    
    bool hpFillGreenDirty;
    bool hpFillOrangeDirty;
    bool hpFillRedDirty;
    bool alertDirty;
    bool bgFillBlackDirty;
    // Only the glyphs need one of these. The plate rectangles ride along in
    // nameBgPath, which is merged into the alert counter's background path and
    // assigned unconditionally at the end of the frame, so there is no dirty
    // edge to get wrong there.
    bool nameTextDirty;
} ESPGeometryBuffers;

typedef struct { 
    int realCount; 
    int botCount;  
    bool inMatch; 
    CGMutablePathRef aimAssistPath; 
} ESPFrameStats;

typedef void (*ESPAddTextCallback)(
    void *context,
    NSString *string,
    CGRect frame,
    UIColor *color,
    CGFloat fontSize,
    BOOL leftAligned
);

typedef void (*ESPAddImageCallback)(
    void *context,
    UIImage *image,
    CGRect frame
);

extern uint64_t Moudule_Base;

extern bool isESP;
extern bool isESP2;
extern bool isBox;
extern bool isBone;
extern bool isHealth;
extern bool isName;
extern bool isDis;
extern bool isLine;
extern bool isEspBot;
extern bool isWeapon;
extern bool isCount;
extern bool isEspCheckVisible;
extern bool isAimIgnoreBot;
extern bool isAimIgnoreKnock;
// Aim sau tường (FOV LookAt + silent/spoof khi ON).
extern bool isAimBehindWall;
extern bool isAimRage;
extern bool isAimLegit;
extern bool isFastReload;

// --- AIMBOT (hard LookAt only; Aim Silent removed) ---
extern bool isAimbot;
// Whether the game's own chest magnet gets stomped at all. Read at three call
// sites of DisableGameDefaultAimAssist, two of which are above the definition in
// esp.mm, so it has to be visible from here rather than declared locally.
extern bool isKillGameAA;
extern int  triggerMode;
extern int  aimPosition;
extern int  aimTargetMode;
extern float aimFov;
extern float aimDistance;
extern float aimSpeed;
extern int aimMode; 

extern bool isStreamerMode;
extern bool isAimAssist;


extern UIColor *colorBox;
extern UIColor *colorBone;
extern UIColor *colorLine;
extern UIColor *colorName;
extern UIColor *colorDis;
extern UIColor *colorWeapon;
extern UIColor *colorBot;
extern UIColor *colorKnocked;

extern int g_PlayerDrawIndex;

#ifdef __cplusplus
extern "C" {
#endif

bool get_IsBot(uint64_t PawnObject);
bool get_IsKnockedDown(uint64_t PawnObject);
bool get_IsBeingRescued(uint64_t PawnObject);

UIFont *GetCustomFont(CGFloat size);

// The PostScript name of the font the counter layer draws with, i.e. the one the
// name plate has to use too, or the same overlay ends up carrying two typefaces.
//
// It is a name and not a UIFont or a CTFont on purpose. LoadCountFont is a file
// static in esp.mm and the glyph builder that needs it is a file static in
// espdraw.mm, so a name is the only thing worth handing across: the loader stays
// in one file and each side keeps the CFType it works in, which is the one it
// has to hand to CoreText anyway.
// Returns a +1 CTFontRef built from the UIFont the counter uses, so the caller
// must CFRelease it. Passing the size matters: UIFont's CGFont is already
// rasterised at one size and reusing it at another produces metrics that do not
// match the point size.
#ifdef __cplusplus
extern "C" {
#endif
CTFontRef ESPNameTextCTFont(CGFloat size);
#ifdef __cplusplus
}
#endif

bool RenderFOVCirclePath(CGMutablePathRef path, float viewWidth, float viewHeight, bool aimbotEnabled, float fovRadius);

// Fast path when caller already has head/HP/flags (avoids double memory reads in crowded games).
void RenderESPForPawnEx(
    ESPGeometryBuffers *buffers,
    ESPAddTextCallback textCallback,
    ESPAddImageCallback imageCallback,
    void *callbackContext,
    uint64_t PawnObject,
    int CurHP,
    int MaxHP,
    float dis,
    float *matrix,
    float layerWidth,
    float layerHeight,
    float matrixVpWidth,
    float matrixVpHeight,
    float headX, float headY, float headZ,
    float hipX, float hipY, float hipZ,
    int isBotFlag,
    int isKnockedFlag
);

void ESPSyncFromPrefs(void);

void ESPSetAimBehindWallLive(bool behindWall);

#ifdef __cplusplus
}
// C++ only — Vector3 cannot be in extern "C".
Vector3 ResolvePawnWorldPosForESP(uint64_t pawn);
Vector3 ResolveHeadWorldPosForESP(uint64_t pawn);
#endif

@interface ESP_View : UIView
- (instancetype)initWithFrame:(CGRect)frame;
- (void)hideMenu;
- (void)showMenu;
- (void)handlePan:(UIPanGestureRecognizer *)gesture;
- (void)layoutSubviews;
- (void)centerMenu;
// Cancels the 60fps render timer and drops the layers. The app's Stop button
// needs this: nothing else in the tree can stop the loop that draws the ESP.
// Main thread.
- (void)stopRendering;
@end

@interface ESPOverlayView : UIView
- (instancetype)initWithFrame:(CGRect)frame;
@end