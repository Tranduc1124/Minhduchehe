#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdint.h>

#import "GameLogic.h"
#import "WeaponTextures.h"
#import "ESPRole.h"

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
    
    // The grey card behind each name. It is a fill, not a stroke, so it cannot
    // share the overlay's single stroked layer: a stroke only carries a colour
    // and a width, and there is nothing in a CGPath that says fill this part and
    // stroke the rest. One extra layer draws every card in the frame, because
    // CGPathAddRects is one call for any number of rectangles.
    CGMutablePathRef cardPath;

    CGMutablePathRef hpFillGreenPath;  
    CGMutablePathRef hpFillOrangePath; 
    CGMutablePathRef hpFillRedPath;    
    CGMutablePathRef alertPath;
    CGMutablePathRef bgFillBlackPath;

    bool boxDirty;
    bool boxBotDirty;
    bool boxKnockedDirty;
    
    bool boneDirty;
    bool boneBotDirty;
    bool boneKnockedDirty;
    
    bool snaplineDirty;
    bool snaplineBotDirty;
    bool snaplineKnockedDirty;
    
    bool cardDirty;
    bool hpFillGreenDirty;
    bool hpFillOrangeDirty;
    bool hpFillRedDirty;
    bool alertDirty;
    bool bgFillBlackDirty;
} ESPGeometryBuffers;

typedef struct { 
    int realCount; 
    int botCount;  
    bool inMatch; 
    CGMutablePathRef aimAssistPath; 
} ESPFrameStats;

// key is the identity of the thing the text belongs to, so the overlay can keep
// one label per pawn rather than one label per distinct string. Every bot in
// this game is called BOT, so matching labels by their text gave all of them a
// single label that they took turns writing. Zero means no identity.
typedef void (*ESPAddTextCallback)(
    void *context,
    NSString *string,
    int role,
    uint64_t key,
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
extern bool isCamPC;
extern float camPCValue;

// --- AIMBOT (hard LookAt only; Aim Silent removed) ---
extern bool isAimbot;
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

bool RenderFOVCirclePath(CGMutablePathRef path, float viewWidth, float viewHeight, bool aimbotEnabled, float fovRadius);

// Fast path when caller already has head/HP/flags (avoids double memory reads in crowded games).
void RenderESPForPawnEx(
    ESPGeometryBuffers *buffers,
    ESPAddTextCallback textCallback,
    ESPAddImageCallback imageCallback,
    void *callbackContext,
    uint64_t PawnObject,
    int CurHP,
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

void ToggleSpeedX50(bool enable);

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
@end

@interface ESPOverlayView : UIView
- (instancetype)initWithFrame:(CGRect)frame;
@end