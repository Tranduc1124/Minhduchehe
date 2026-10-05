#import "esp.h"
#import "ESPPrefs.h"
#import "offset.h"
#import "GameOffsets.h"
#import "../DSMemory.h"
#import "../../app/KernelBoot.h" // kernelBootLog (diag output to Home log card)
#import "../../remote/SpringBoardOverlay.h" // SBRemotePushESPFrame (extern "C")

#import "GameLogic.h" 
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <notify.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <string>
#include <vector>
#include <cmath>
#include <float.h>
#import <mach/mach.h>
#include <mutex>
#include <atomic>
#include <thread>
#include <chrono>


#ifdef __cplusplus
extern "C" {
#endif
    kern_return_t mach_vm_region(
        vm_map_t target_task,
        mach_vm_address_t *address,
        mach_vm_size_t *size,
        vm_region_flavor_t flavor,
        vm_region_info_t info,
        mach_msg_type_number_t *infoCnt,
        mach_port_t *object_name
    );
    kern_return_t mach_vm_read_overwrite(
        vm_map_t target_task,
        mach_vm_address_t address,
        mach_vm_size_t size,
        mach_vm_address_t data,
        mach_vm_size_t *outsize
    );
    kern_return_t mach_vm_write(
        vm_map_t target_task,
        mach_vm_address_t address,
        vm_offset_t data,
        mach_msg_type_number_t dataCnt
    );
    kern_return_t mach_vm_allocate(
        vm_map_t target,
        mach_vm_address_t *address,
        mach_vm_size_t size,
        int flags
    );
#ifdef __cplusplus
}
#endif

extern int GetGameProcesspid(char *name);

// Cross-TU clearer for the pro (isESP fast) box smoother — defined below
// next to ClearBoxScreenForPawn (same g_boxScr table the pro path uses).
void ClearProBoxScreenForPawn(uint64_t pawn);


// Render tick. Clamped to 30-60 Hz: below 30 the FOV ring and the snapline
// fan visibly step, and above 60 there is nothing left to win because each
// publish already costs about a millisecond of CoreGraphics in SpringBoard.
//
// The interval used to be a literal 16 ms. It is now read from EspTickHz so the
// app can offer it, and dispatch_source_set_timer can be called again on a
// running source, so changing it does not mean rebuilding the view.
#define ESP_TICK_MIN_HZ 30.0f
#define ESP_TICK_MAX_HZ 60.0f
#define ESP_TICK_DEFAULT_HZ 60.0f

// frameTimer is private to the class extension further down, and this code
// sits above it. Redeclaring the one property here is what lets the file-scope
// helpers reach it without moving the extension.
@interface ESP_View (TickAccess)
@property (nonatomic, strong) dispatch_source_t frameTimer;
@end

static float ESPTickHzFromPrefs(void) {
    float hz = ESPPrefsFloat(@"EspTickHz", ESP_TICK_DEFAULT_HZ);
    if (hz < ESP_TICK_MIN_HZ) hz = ESP_TICK_MIN_HZ;
    if (hz > ESP_TICK_MAX_HZ) hz = ESP_TICK_MAX_HZ;
    return hz;
}

static uint64_t ESPTickIntervalNS(void) {
    return (uint64_t)(1e9f / ESPTickHzFromPrefs());
}

// Weak, so recording the view here cannot keep it alive past its window. Only
// one host exists at a time; StartESPHost refuses a second.
static __weak ESP_View *s_espViewInstance = nil;
static float s_espTickAppliedHz = 0.0f;

// Called from ESPSyncFromPrefs, which runs on a poll rather than every frame,
// and touches the timer only when the pref actually moved.
static void ESPSyncTickRate(void) {
    float hz = ESPTickHzFromPrefs();
    if (hz == s_espTickAppliedHz) return;
    ESP_View *view = s_espViewInstance;
    if (!view) return;
    s_espTickAppliedHz = hz;
    dispatch_source_t timer = view.frameTimer;
    if (!timer) return;
    uint64_t intervalNS = (uint64_t)(1e9f / hz);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNS),
                              intervalNS,
                              2 * NSEC_PER_MSEC);
}

// Forward decls used by aim helpers (defined later in this file).
static inline bool IsZeroVec(const Vector3 &v);
Vector3 GetAimTargetPosMode(uint64_t pawn, int posMode, float distance);
Quaternion GetRotationToLocation(Vector3 targetLocation, float y_bias, Vector3 myLoc);
void update_aim_assist_legit_tuning(bool enable);
static void write_aim_rotations(uint64_t player, const Quaternion &out);
static Vector3 AimTrackAndLead(uint64_t pawn, Vector3 bodyPos, float distanceMeters, bool lockYToBody);
static Vector3 AimTrackAndLeadEx(uint64_t pawn, Vector3 bodyPos, float distanceMeters, bool lockYToBody, bool bulletLead);
static inline Vector3 AimCameraOrigin(uint64_t localPawn, const Vector3 &fallback);
static inline Vector3 ResolveHeadWorldPosTracked(uint64_t pawn);
static inline Vector3 ReadPlayerRootTransform(uint64_t pawn);
static inline bool looksLikeWorldPos(const Vector3 &p);
static float esp_aim_delta_time(void);
static inline int PosTrackSlot(uint64_t pawn);
bool get_IsBot(uint64_t player);
bool get_IsVisible(uint64_t player);
bool get_IsFPPVisible(uint64_t player);
static inline uint32_t get_VisibleFlags(uint64_t player);

// AimBehindWall ON  = FOV LookAt + silent/spoof through map cover.
// AimBehindWall OFF = only hard clear LOS (weapon raycast body hit, or normal AA
//                     when the enemy is NOT in IceWall AA list). Bom keo path removed.
bool isAimBehindWall = NO;

static void SilentAimClearTarget(void);
static uint64_t gAimLockTarget = 0;
static int gAimLockLostFrames = 0;
static int s_lockHoldFrames = 0;
static uint64_t s_lastAimPawn = 0;

// Per-frame visibility health (reset in AimVisFrameBegin).
static int g_aimVisSampled = 0;      // how many pawns we read flags for
static int g_aimVisNonZero = 0;      // how many had flags != 0
static int g_aimVisCameraTrue = 0;   // how many had ISVISIBLE_CAMERA
static int g_aimVisPvsTrue = 0;      // how many had ISVISIBLE_DynamicPVS

static inline bool AimBehindWallNow(void) {
    return isAimBehindWall;
}
// Full FOV-through-any-cover (silent + 360 + unrestricted pick).
static inline bool AimThroughAnyCoverNow(void) {
    return isAimBehindWall;
}

extern "C" void ESPSetAimBehindWallLive(bool behindWall) {
    // Toggle must drop sticky lock immediately so wall-off does not keep LookAt
    // on a cover target for extra frames.
    if (isAimBehindWall != behindWall) {
        gAimLockTarget = 0;
        gAimLockLostFrames = 0;
        SilentAimClearTarget();
    }
    isAimBehindWall = behindWall;
}

static inline void AimVisFrameBegin(void) {
    g_aimVisSampled = 0;
    g_aimVisNonZero = 0;
    g_aimVisCameraTrue = 0;
    g_aimVisPvsTrue = 0;
}

// =============================================================================
// Wall-OFF thorough gate (external TIPA — cannot call Physics.Raycast ourselves)
// =============================================================================
// Root cause of "toggle OFF still aims through walls":
//   Aimbot/Assist picked ANY enemy in FOV via WorldToScreen. W2S projects through
//   walls, then LookAt snapped the camera to that world pos = wall aim.
//   CAMERA/PVS flags are NOT real LOS (often always on) — do not use them.
//
// Real signal available externally: the GAME's own weapon raycast result.
//   Player.HitObjectInfo (GMPGMPFNMFP)  FF 0xDC8 / MAX 0xDD0
//     hit point @ +0x28, origin @ +0x4C  (same layout silent already uses)
//   Player.LastAimingTargetFromWeapon   FF 0xDE0 / MAX 0xDE8
//   Player.m_AimAssist current candidate (interface ptr == enemy when AA locked)
//
// Wall-OFF rules:
//   1) Silent + fire-dir spoof OFF (magic bullet = wall aim)
//   2) 360 OFF
//   3) Aimbot/Assist only lock a pawn if game raycast/AA says that pawn is the
//      clear target (hit near body OR last/AA target ptr matches). No FOV-through-wall.
//   4) Do NOT force vanilla EAimAssist AllOff when wall-off — need game raycast live.
// =============================================================================

// Dump GMPGMPFNMFP layout (silent path confirmed):
static const uint64_t kGmpHitPointOff  = 0x28; // MBGBCLNJOMK
static const uint64_t kGmpOriginOff    = 0x4C; // LMAEGPEAECO
// LastAimingTargetFromWeapon (OKEAMEELLBB*) — table-driven (FF 0xDE0 / MAX 0xDE8).
static inline uint64_t kLastAimingTargetFromWeaponOff(void) {
    uint64_t off = kLastAimingTargetFromWeapon;
    return off ? off : (GameTargetIsMax() ? 0xDE8ull : 0xDE0ull);
}

struct GameWeaponRaycast {
    bool valid = false;
    Vector3 origin{};
    Vector3 hit{};
};

static inline GameWeaponRaycast SampleLocalWeaponRaycast(uint64_t localPawn, const Vector3 &fallbackOrigin) {
    GameWeaponRaycast out;
    if (!isVaildPtr(localPawn)) return out;
    const uint64_t slots[2] = {
        (uint64_t)kHitObjectInfo,
        (uint64_t)kHitObjectInfoAlt
    };
    for (int i = 0; i < 2; i++) {
        if (!slots[i]) continue;
        uint64_t info = ReadAddr<uint64_t>(localPawn + slots[i]);
        if (!isVaildPtr(info)) continue;
        Vector3 hit = ReadAddr<Vector3>(info + kGmpHitPointOff);
        Vector3 origin = ReadAddr<Vector3>(info + kGmpOriginOff);
        if (!looksLikeWorldPos(hit)) continue;
        if (!looksLikeWorldPos(origin)) origin = fallbackOrigin;
        if (!looksLikeWorldPos(origin)) continue;
        // Reject near-zero garbage.
        if (fabsf(hit.x) < 0.05f && fabsf(hit.y) < 0.05f && fabsf(hit.z) < 0.05f) continue;
        out.valid = true;
        out.origin = origin;
        out.hit = hit;
        return out;
    }
    return out;
}

// True if game weapon raycast hit is on/near this enemy (clear LOS under crosshair).
static inline bool RaycastHitNearTarget(const GameWeaponRaycast &rc, const Vector3 &targetPos) {
    if (!rc.valid || !looksLikeWorldPos(targetPos)) return false;
    const float hitToEnemy = Vector3::Distance(rc.hit, targetPos);
    const float distEnemy = Vector3::Distance(rc.origin, targetPos);
    const float distHit = Vector3::Distance(rc.origin, rc.hit);
    // Solid hit clearly in front of the body → cover, not body.
    if (distEnemy > 0.60f && distHit + 0.70f < distEnemy) return false;
    // Body capsule (slightly looser than last pass so open targets still count).
    if (hitToEnemy <= 1.45f) return true;
    if (distHit + 0.20f >= distEnemy && hitToEnemy <= 1.85f) return true;
    if (distEnemy < 0.45f && hitToEnemy <= 1.50f) return true;
    return false;
}

// Shared AA candidate scan (normal m_AimAssist + Ice Wall AA share KBCJOEFJEFJ layout).
static inline bool AimAssistObjectHasEnemy(uint64_t aa, uint64_t enemy) {
    if (!isVaildPtr(aa) || !isVaildPtr(enemy)) return false;
    // KBCJOEFJEFJ: current KOLIMPJEBPC @ +0x10, secondary OGFCAEIFKKP @ +0x18
    // candidate.LDNBCNLCIGP (OKEAMEELLBB*) @ +0x18
    const uint64_t candOffs[2] = { 0x10, 0x18 };
    for (uint64_t co : candOffs) {
        uint64_t cand = ReadAddr<uint64_t>(aa + co);
        if (!isVaildPtr(cand)) continue;
        uint64_t tgt = ReadAddr<uint64_t>(cand + 0x18);
        if (tgt == enemy) return true;
    }
    // List<KLNCOMCJJGK> @ +0x20
    uint64_t list = ReadAddr<uint64_t>(aa + 0x20);
    if (isVaildPtr(list)) {
        int n = ReadAddr<int>(list + 0x18); // _size
        uint64_t items = ReadAddr<uint64_t>(list + 0x10); // _items
        if (isVaildPtr(items) && n > 0 && n < 32) {
            for (int i = 0; i < n; i++) {
                uint64_t cand = ReadAddr<uint64_t>(items + 0x20 + (uint64_t)i * 8);
                if (!isVaildPtr(cand)) continue;
                uint64_t tgt = ReadAddr<uint64_t>(cand + 0x18);
                if (tgt == enemy) return true;
            }
        }
    }
    return false;
}

// m_AimAssist current candidate(s) — when vanilla AA has a LOS target, ptr matches enemy.
static inline bool AimAssistTargetIsEnemy(uint64_t localPawn, uint64_t enemy) {
    if (!isVaildPtr(localPawn) || !isVaildPtr(enemy)) return false;
    return AimAssistObjectHasEnemy(ReadAddr<uint64_t>(localPawn + kAimAssistPtr), enemy);
}

// Ice-wall AA list is only a REJECT signal when wall aim is OFF
// (enemy behind bom keo must not soft-lock). Feature toggle removed.
static inline bool IceWallAimAssistTargetIsEnemy(uint64_t localPawn, uint64_t enemy) {
    if (!isVaildPtr(localPawn) || !isVaildPtr(enemy)) return false;
    uint64_t iceAa = ReadAddr<uint64_t>(localPawn + kAimAssistIceWallPtr);
    return AimAssistObjectHasEnemy(iceAa, enemy);
}

static inline bool LastWeaponTargetIsEnemy(uint64_t localPawn, uint64_t enemy) {
    if (!isVaildPtr(localPawn) || !isVaildPtr(enemy)) return false;
    uint64_t t = ReadAddr<uint64_t>(localPawn + kLastAimingTargetFromWeaponOff());
    return isVaildPtr(t) && t == enemy;
}

// Frame-local raycast sample (filled once per render from local pawn).
static GameWeaponRaycast g_frameWeaponRaycast;
static uint64_t g_frameWeaponRaycastLocal = 0;

static inline void AimWallOffFrameBegin(uint64_t localPawn, const Vector3 &localOrigin) {
    g_frameWeaponRaycast = SampleLocalWeaponRaycast(localPawn, localOrigin);
    g_frameWeaponRaycastLocal = localPawn;
    g_aimVisSampled = 0;
    g_aimVisNonZero = 0;
    g_aimVisCameraTrue = 0;
    g_aimVisPvsTrue = 0;
}

// Wall-OFF clear LOS — GEOMETRIC, independent of vanilla AA lists.
// User: FOV siêu to must lock open enemies far from crosshair center; AA is AllOff
// while custom aim runs, so AA-list-gated LOS only locked near-center (felt like AA FOV).
//
//   ALLOW — body hit / no on-axis cover evidence (open FOV pick).
//   DENY  — on-axis cover closer than body / ice-wall AA only.
// Wall-ON: short-circuit allow.
static inline bool GameClearLosToEnemy(uint64_t localPawn, uint64_t enemy, const Vector3 &enemyPos) {
    if (AimThroughAnyCoverNow()) return true;
    if (!isVaildPtr(localPawn) || !isVaildPtr(enemy) || !looksLikeWorldPos(enemyPos)) return false;

    GameWeaponRaycast rc = g_frameWeaponRaycast;
    if (g_frameWeaponRaycastLocal != localPawn) {
        rc = SampleLocalWeaponRaycast(localPawn, enemyPos);
    }

    // 1) Body hit under crosshair ray → clear.
    if (RaycastHitNearTarget(rc, enemyPos)) return true;

    // 2) Hard cover on the line to THIS enemy → block wall aim.
    if (rc.valid && looksLikeWorldPos(rc.origin) && looksLikeWorldPos(rc.hit)) {
        const float dxE = enemyPos.x - rc.origin.x;
        const float dyE = enemyPos.y - rc.origin.y;
        const float dzE = enemyPos.z - rc.origin.z;
        const float dxH = rc.hit.x - rc.origin.x;
        const float dyH = rc.hit.y - rc.origin.y;
        const float dzH = rc.hit.z - rc.origin.z;
        const float distEnemy = sqrtf(dxE * dxE + dyE * dyE + dzE * dzE);
        const float distHit = sqrtf(dxH * dxH + dyH * dyH + dzH * dzH);
        if (distEnemy > 1.35f && distHit > 0.30f && distHit + 1.10f < distEnemy) {
            const float invE = 1.0f / distEnemy;
            const float invH = 1.0f / distHit;
            const float dot = (dxE * invE) * (dxH * invH)
                            + (dyE * invE) * (dyH * invH)
                            + (dzE * invE) * (dzH * invH);
            // ~30° cone — only block when hit is toward this enemy (not ground off-axis).
            if (dot > 0.87f) return false;
        }
    }

    // 3) Bom keo soft list without body hit → never lock.
    if (IceWallAimAssistTargetIsEnemy(localPawn, enemy)) return false;

    // 4) Soft positives (optional boost; not required for FOV lock).
    if (LastWeaponTargetIsEnemy(localPawn, enemy)) return true;
    // AA may be AllOff — list empty is fine; do not depend on it.

    // 5) No on-axis cover evidence → allow FOV pick (địch trong vòng FOV, k cần gần tâm).
    //    inFront/FOV/onScreen already filtered in aim pick loop.
    return true;
}
static inline bool AimHasPositiveLos(uint64_t player) {
    // Diagnostics only — NEVER use as a real LOS gate (always-true flags).
    if (!isVaildPtr(player)) return false;
    const uint32_t f = get_VisibleFlags(player);
    g_aimVisSampled++;
    if (f != 0) g_aimVisNonZero++;
    if (f & (uint32_t)kISVisibleCamera) g_aimVisCameraTrue++;
    if (f & (uint32_t)kISVisibleDynamicPVS) g_aimVisPvsTrue++;
    // Real wall-off gate is GameClearLosToEnemy — this is NOT the gate.
    return true;
}

static inline bool AimVisFlagsAliveThisFrame(void) {
    return g_aimVisNonZero > 0;
}

static inline bool AimVisPvsAliveThisFrame(void) {
    return g_aimVisPvsTrue > 0;
}

static inline bool AimTargetVisibleForWallOff(uint64_t player) {
    if (AimThroughAnyCoverNow()) return true;
    if (!isVaildPtr(player) || !isVaildPtr(g_frameWeaponRaycastLocal)) return false;
    // Soft helper only — real gate is GameClearLosToEnemy (geometric).
    // Reject ice-covered soft targets; accept last-weapon. Do not require AA list
    // (AA is AllOff while custom aim runs).
    if (IceWallAimAssistTargetIsEnemy(g_frameWeaponRaycastLocal, player)) return false;
    if (LastWeaponTargetIsEnemy(g_frameWeaponRaycastLocal, player)) return true;
    return true; // geometric FOV path decides real lock
}

// Silent only when wall-through is ON.
static inline bool AimTargetVisibleStrictForSilent(uint64_t player) {
    if (AimThroughAnyCoverNow()) return true;
    (void)player;
    return false;
}

// Read a Unity Transform / ITransformNode world position via getPositionExt.
// On vehicle/zipline, skinned bones often fail while Vehicle/Strop transforms remain valid.
static inline Vector3 tryTransformPos(uint64_t nodeOrTf) {
    if (!isVaildPtr(nodeOrTf)) return Vector3{0, 0, 0};
    Vector3 p = getPositionExt(nodeOrTf);
    if (!IsZeroVec(p)) return p;
    // Some wrappers need one extra +0x10 hop (ITransformNode -> Transform).
    uint64_t inner = ReadAddr<uint64_t>(nodeOrTf + kBodyPartTransNode);
    if (isVaildPtr(inner) && inner != nodeOrTf) {
        p = getPositionExt(inner);
        if (!IsZeroVec(p)) return p;
    }
    return Vector3{0, 0, 0};
}

static inline bool looksLikeWorldPos(const Vector3 &p) {
    if (IsZeroVec(p)) return false;
    // Reject NaN / insane coords (common when reading wrong memory as Vector3).
    if (isnan(p.x) || isnan(p.y) || isnan(p.z)) return false;
    if (fabsf(p.x) > 20000.f || fabsf(p.y) > 20000.f || fabsf(p.z) > 20000.f) return false;
    return true;
}

// dump: Vehicle has cached Vector3s + Rigidbody; LevelStrop has Start/End Transform.
// Unity Component.m_CachedPtr is typically at +0x10 on il2cpp; TransformNode wraps Transform at +0x10.
// Rigidbody / GameObject often expose a Transform path through getPositionExt or nested +0x10.
static inline Vector3 tryComponentOrGoPos(uint64_t compOrGo) {
    if (!isVaildPtr(compOrGo)) return Vector3{0, 0, 0};
    Vector3 p = tryTransformPos(compOrGo);
    if (looksLikeWorldPos(p)) return p;
    // Common Unity native/transform slots on Component / GameObject.
    const uint64_t offs[] = { 0x10, 0x30, 0x38, 0x48, 0x50, 0x60 };
    for (uint64_t off : offs) {
        uint64_t t = ReadAddr<uint64_t>(compOrGo + off);
        p = tryTransformPos(t);
        if (looksLikeWorldPos(p)) return p;
        // One more hop (GameObject -> Transform).
        if (isVaildPtr(t)) {
            p = tryTransformPos(ReadAddr<uint64_t>(t + 0x10));
            if (looksLikeWorldPos(p)) return p;
        }
    }
    return Vector3{0, 0, 0};
}

static inline Vector3 ResolveVehicleWorldPos(uint64_t vehicle) {
    if (!isVaildPtr(vehicle)) return Vector3{0, 0, 0};

    // 1) DriverSeat / PassengerSeat GameObjects (dump: 0x140 / 0x148) — best seat anchor.
    uint64_t driverSeat = ReadAddr<uint64_t>(vehicle + 0x140); // DriverSeat
    Vector3 p = tryComponentOrGoPos(driverSeat);
    if (looksLikeWorldPos(p)) return p;

    uint64_t passArr = ReadAddr<uint64_t>(vehicle + 0x148); // PassengerSeat[]
    if (isVaildPtr(passArr)) {
        // Il2Cpp array: length @ +0x18, items @ +0x20
        int n = ReadAddr<int>(passArr + 0x18);
        if (n > 0 && n < 8) {
            for (int i = 0; i < n; i++) {
                uint64_t seatGo = ReadAddr<uint64_t>(passArr + 0x20 + (uint64_t)i * 8);
                p = tryComponentOrGoPos(seatGo);
                if (looksLikeWorldPos(p)) return p;
            }
        }
    }

    // 2) Cached Vector3s from vehicle sim (dump 0x178 / 0x184 / 0x190 / 0x238 / 0x25C).
    const uint64_t posOffs[] = {
        kVehicleCachedPosA, kVehicleCachedPosB, kVehicleCachedPosC,
        0x238, 0x250, 0x25C
    };
    for (uint64_t off : posOffs) {
        Vector3 v = ReadAddr<Vector3>(vehicle + off);
        if (looksLikeWorldPos(v)) return v;
    }

    // 3) Rigidbody / LevelVehicle / ExplodePoint / AimingCameraPos transforms.
    p = tryComponentOrGoPos(ReadAddr<uint64_t>(vehicle + kVehicleRigidBody));
    if (looksLikeWorldPos(p)) return p;
    p = tryComponentOrGoPos(ReadAddr<uint64_t>(vehicle + kVehicleLevelVehicle));
    if (looksLikeWorldPos(p)) return p;
    p = tryTransformPos(ReadAddr<uint64_t>(vehicle + 0x168)); // ExplodePoint1
    if (looksLikeWorldPos(p)) return p;
    p = tryTransformPos(ReadAddr<uint64_t>(vehicle + 0x330)); // AimingCameraPos
    if (looksLikeWorldPos(p)) return p;

    // 4) Probe common Component/GameObject slots on Vehicle entity itself.
    const uint64_t tfProbe[] = { 0x10, 0x30, 0x38, 0x60, 0x70, 0x98, 0xB8, 0xC0 };
    for (uint64_t off : tfProbe) {
        p = tryComponentOrGoPos(ReadAddr<uint64_t>(vehicle + off));
        if (looksLikeWorldPos(p)) return p;
    }
    return Vector3{0, 0, 0};
}

// Cable midpoint only — last-resort estimate when player transform/bones are dead.
// NEVER prefer this over live pawn root: midpoint sticks at cable center after dismount.
static inline Vector3 ResolveStropWorldPos(uint64_t strop) {
    if (!isVaildPtr(strop)) return Vector3{0, 0, 0};
    Vector3 a = tryTransformPos(ReadAddr<uint64_t>(strop + kLevelStropStartPoint));
    Vector3 b = tryTransformPos(ReadAddr<uint64_t>(strop + kLevelStropEndPoint));
    if (looksLikeWorldPos(a) && looksLikeWorldPos(b)) {
        return Vector3((a.x + b.x) * 0.5f, (a.y + b.y) * 0.5f + 0.8f, (a.z + b.z) * 0.5f);
    }
    if (looksLikeWorldPos(a)) { a.y += 0.8f; return a; }
    if (looksLikeWorldPos(b)) { b.y += 0.8f; return b; }
    Vector3 p = tryTransformPos(ReadAddr<uint64_t>(strop + kBaseLevelObjectGameObject));
    if (looksLikeWorldPos(p)) return p;
    // Only known object slots — wide probes caused sticky garbage after zipline.
    const uint64_t tfProbe[] = { 0x10, 0x30 };
    for (uint64_t off : tfProbe) {
        p = tryTransformPos(ReadAddr<uint64_t>(strop + off));
        if (looksLikeWorldPos(p)) return p;
    }
    return Vector3{0, 0, 0};
}

// Strict primary offset first; loose alts only if primary empty.
// Wide multi-offset scans often kept a STALE vehicle/strop ptr after dismount → ESP stick.
static inline uint64_t ReadVehicleIAmIn(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return 0;
    uint64_t primary = kVehicleIAmIn ? kVehicleIAmIn : 0x8A8;
    uint64_t v = ReadAddr<uint64_t>(pawn + primary);
    if (isVaildPtr(v) && v != pawn) return v;
    // One version alt only (FF vs Max mid-field shift).
    uint64_t alt = (primary == 0x8A8) ? 0x8B0 : 0x8A8;
    if (alt != primary) {
        v = ReadAddr<uint64_t>(pawn + alt);
        if (isVaildPtr(v) && v != pawn) return v;
    }
    return 0;
}

static inline uint64_t ReadStropIAmOn(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return 0;
    uint64_t primary = kLevelStropIAmOn ? kLevelStropIAmOn : 0x8C0;
    uint64_t s = ReadAddr<uint64_t>(pawn + primary);
    if (isVaildPtr(s) && s != pawn) return s;
    uint64_t alt = (primary == 0x8C0) ? 0x8C8 : 0x8C0;
    if (alt != primary) {
        s = ReadAddr<uint64_t>(pawn + alt);
        if (isVaildPtr(s) && s != pawn) return s;
    }
    return 0;
}

static inline Vector3 ReadPlayerRootTransform(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return Vector3{0, 0, 0};
    const uint64_t tfOffs[] = {
        kPlayerTransform ? kPlayerTransform : 0x698,
        0x698, 0x6A0
    };
    for (uint64_t off : tfOffs) {
        if (!off) continue;
        Vector3 p = tryTransformPos(ReadAddr<uint64_t>(pawn + off));
        if (looksLikeWorldPos(p)) return p;
    }
    return Vector3{0, 0, 0};
}

// Vehicle/strop mount. Prefer LIVE pawn body when present (passenger in YOUR car
// sits near you — vehicle "center" can be far from seat → old 12m gate dropped them).
// Stale dismount: vehicle ptr set but live body far AND bones look grounded → ignore.
// ESP-critical: if vehicle ptr set and bones collapsed/dead, ALWAYS use vehicle pos
// even when live root is lagging far (common mid-drive network desync).
static inline bool IsActivelyMounted(uint64_t pawn, Vector3 *outMountPos = nullptr) {
    if (outMountPos) *outMountPos = Vector3{0, 0, 0};
    if (!isVaildPtr(pawn)) return false;
    Vector3 root = ReadPlayerRootTransform(pawn);
    Vector3 head = tryTransformPos(getHead(pawn));
    Vector3 hip  = tryTransformPos(getHip(pawn));
    Vector3 live = looksLikeWorldPos(root) ? root
                 : (looksLikeWorldPos(hip) ? hip
                 : (looksLikeWorldPos(head) ? head : Vector3{0, 0, 0}));
    const bool bonesDead = !looksLikeWorldPos(head) && !looksLikeWorldPos(hip);
    const bool bonesCollapsed = looksLikeWorldPos(head) && looksLikeWorldPos(hip) &&
                                Vector3::Distance(head, hip) < 0.22f;

    uint64_t vehicle = ReadVehicleIAmIn(pawn);
    if (vehicle) {
        Vector3 vp = ResolveVehicleWorldPos(vehicle);
        const bool haveVp = looksLikeWorldPos(vp);
        const bool haveLive = looksLikeWorldPos(live);

        // Stale dismount only when body looks healthy AND far from vehicle.
        if (haveLive && haveVp && !bonesDead && !bonesCollapsed) {
            float dx = live.x - vp.x, dy = live.y - vp.y, dz = live.z - vp.z;
            float d2 = dx*dx + dy*dy + dz*dz;
            if (d2 > 36.0f * 36.0f) return false;
        }

        // Prefer live seat tracking when body is still updating near the car.
        if (haveLive && !bonesDead && !bonesCollapsed) {
            if (outMountPos) {
                Vector3 o = live;
                o.y += 0.75f;
                *outMountPos = o;
            }
            return true;
        }

        // Bones dead/collapsed while vehicle ptr set → use vehicle world pos (ESP on car).
        if (haveVp) {
            if (outMountPos) {
                Vector3 o = vp;
                o.y += 0.95f;
                *outMountPos = o;
            }
            return true;
        }

        // Vehicle ptr only: still mark mounted so ESP doesn't hard-cull passenger.
        // Use live if any, else leave zero (caller may fall back).
        if (haveLive && outMountPos) {
            Vector3 o = live;
            o.y += 0.75f;
            *outMountPos = o;
        }
        return true;
    }

    uint64_t strop = ReadStropIAmOn(pawn);
    if (strop) {
        Vector3 sp = ResolveStropWorldPos(strop);
        if (looksLikeWorldPos(live)) {
            // Live body near cable OR no good cable pos → trust live.
            if (!looksLikeWorldPos(sp)) {
                if (outMountPos) { Vector3 o = live; o.y += 0.75f; *outMountPos = o; }
                return true;
            }
            float dx = live.x - sp.x, dy = live.y - sp.y, dz = live.z - sp.z;
            float d2 = dx*dx + dy*dy + dz*dz;
            if (d2 <= 22.0f * 22.0f) {
                if (outMountPos) { Vector3 o = live; o.y += 0.75f; *outMountPos = o; }
                return true;
            }
            // Far from cable = stale strop ptr after drop.
            return false;
        }
        if (looksLikeWorldPos(sp)) {
            if (outMountPos) *outMountPos = sp;
            return true;
        }
        // Ptr only, no cable/live pos — do not invent mounted state.
        return false;
    }
    return false;
}

// World position for ESP.
// Priority: live root/bones first (passenger in vehicle still has root), then mount.
static inline Vector3 ResolvePawnWorldPosAny(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return Vector3{0, 0, 0};
    Vector3 p{};
    Vector3 mountPos{};
    const bool mounted = IsActivelyMounted(pawn, &mountPos);

    // 0) Player Unity Transform* — primary standing / vehicle passenger / cable.
    p = ReadPlayerRootTransform(pawn);
    if (looksLikeWorldPos(p)) return p;

    // 1) Live skinned bones (often still update on vehicle seat).
    p = tryTransformPos(getHip(pawn));
    if (looksLikeWorldPos(p)) return p;
    p = tryTransformPos(getHead(pawn));
    if (looksLikeWorldPos(p)) return p;
    if (kRootNode) {
        p = tryTransformPos(ReadAddr<uint64_t>(pawn + kRootNode));
        if (looksLikeWorldPos(p)) return p;
    }
    p = tryTransformPos(getLeftShoulder(pawn));
    if (looksLikeWorldPos(p)) return p;
    p = tryTransformPos(getRightShoulder(pawn));
    if (looksLikeWorldPos(p)) return p;

    // 1b) Mounted early: seat/vehicle before capsule (bones often zero in car).
    if (mounted && looksLikeWorldPos(mountPos)) return mountPos;

    // 2) CapsuleHuman / CapsuleCollider
    {
        uint64_t capHuman = ReadAddr<uint64_t>(pawn + 0xAA8);
        p = tryComponentOrGoPos(capHuman);
        if (looksLikeWorldPos(p)) return p;
        if (isVaildPtr(capHuman)) {
            p = tryComponentOrGoPos(ReadAddr<uint64_t>(capHuman + 0x28));
            if (looksLikeWorldPos(p)) return p;
        }
        uint64_t capCol = ReadAddr<uint64_t>(pawn + 0xAB0);
        p = tryComponentOrGoPos(capCol);
        if (looksLikeWorldPos(p)) return p;
    }

    // 3) Active mount again if capsule also failed.
    if (mounted && looksLikeWorldPos(mountPos)) return mountPos;
    {
        Vector3 mount2{};
        if (IsActivelyMounted(pawn, &mount2) && looksLikeWorldPos(mount2)) return mount2;
    }

    // 4) Camera last
    {
        uint64_t followCam = ReadAddr<uint64_t>(pawn + 0x628);
        p = tryComponentOrGoPos(followCam);
        if (looksLikeWorldPos(p)) return p;
    }
    if (kMainCameraTransform) {
        p = tryTransformPos(ReadAddr<uint64_t>(pawn + kMainCameraTransform));
        if (looksLikeWorldPos(p)) return p;
    }
    return Vector3{0, 0, 0};
}

// Forward: sticky tracked resolvers (defined with PlayerCache below).
static inline Vector3 ResolveHeadWorldPosTracked(uint64_t pawn);
static inline Vector3 ResolveHipWorldPosTracked(uint64_t pawn);

// Exported for espdraw.mm — tracked hip so box/line share motion with head.
Vector3 ResolvePawnWorldPosForESP(uint64_t pawn) {
    Vector3 hip = ResolveHipWorldPosTracked(pawn);
    if (looksLikeWorldPos(hip)) return hip;
    return ResolvePawnWorldPosAny(pawn);
}

// ESP head: sticky source + light world smooth (shared with aim).
static inline Vector3 ResolveHeadWorldPos(uint64_t pawn, bool /*unused*/ = false) {
    return ResolveHeadWorldPosTracked(pawn);
}

Vector3 ResolveHeadWorldPosForESP(uint64_t pawn) {
    return ResolveHeadWorldPosTracked(pawn);
}

// AIM-only head: same tracked head as ESP so aim doesn't jitter vs box/line.
static inline Vector3 ResolveAimHeadWorldPos(uint64_t pawn) {
    Vector3 tracked = ResolveHeadWorldPosTracked(pawn);
    if (looksLikeWorldPos(tracked)) return tracked;
    if (!isVaildPtr(pawn)) return Vector3{0, 0, 0};
    Vector3 head = getPositionExt(getHead(pawn));
    Vector3 hip = getPositionExt(getHip(pawn));
    if (!IsZeroVec(head)) {
        if (!IsZeroVec(hip)) {
            // Reject only obvious garbage (head far below hip / insane distance).
            if (head.y < hip.y - 0.35f) {
                // Vehicle/cable can invert briefly — fall through to soft head.
            } else {
                float dx = head.x - hip.x, dy = head.y - hip.y, dz = head.z - hip.z;
                float distSq = dx * dx + dy * dy + dz * dz;
                if (distSq <= 4.5f * 4.5f) return head;
            }
        } else {
            return head;
        }
    }
    // Soft aim head when skinned nodes fail (vehicle / zipline / cable).
    if (!IsZeroVec(hip)) {
        hip.y += 0.50f;
        return hip;
    }
    Vector3 any = ResolvePawnWorldPosAny(pawn);
    if (!IsZeroVec(any)) {
        any.y += 0.50f;
        return any;
    }
    return Vector3{0, 0, 0};
}

// Hard head lock — aim rotation fields (dump-confirmed).
// 1) Force game EAimAssist AllOff + zero AA strength (no object stomps).
// 2) Multi-write rotations so recoil / fire-stick / late magnet cannot re-pull same frame.
// 3) Optional burst: while firing, game overwrites aim after our write — hammer wins.
static inline void AimLookAtHead(uint64_t localPawn, const Vector3 &headPos, const Vector3 &fromLoc, int bursts = 2) {
    if (!isVaildPtr(localPawn) || IsZeroVec(headPos) || IsZeroVec(fromLoc)) return;
    Quaternion q = Quaternion::Normalized(GetRotationToLocation(headPos, 0.0f, fromLoc));
    if (isnan(q.x) || isnan(q.y) || isnan(q.z) || isnan(q.w)) return;
    update_aim_assist_legit_tuning(false);
    // Kill AA magnet strength while custom LookAt runs (wall ON/OFF). Mode stays on for LOS lists.
    // Gated on the switch, not unconditional: with Kill Game AA off the user asked
    // for the game's magnet to stay alive, and this runs on every rotation write
    // while aimbot or assist is on, so it is exactly where an off switch used to
    // have no effect.
    DisableGameDefaultAimAssist(localPawn, isKillGameAA);
    if (bursts < 2) bursts = 2;
    if (bursts > 48) bursts = 48;
    for (int i = 0; i < bursts; i++) {
        write_aim_rotations(localPawn, q);
    }
}

// Live camera origin for LookAt (player root drifts while strafing / ADS sway).
static inline Vector3 AimCameraOrigin(uint64_t localPawn, const Vector3 &fallback) {
    if (!isVaildPtr(localPawn)) return fallback;
    uint64_t camTf = ReadAddr<uint64_t>(localPawn + kMainCameraTransform);
    if (isVaildPtr(camTf)) {
        Vector3 p = getPositionExt(camTf);
        if (looksLikeWorldPos(p)) return p;
    }
    if (looksLikeWorldPos(fallback)) return fallback;
    Vector3 lh = tryTransformPos(getHead(localPawn));
    if (looksLikeWorldPos(lh)) return lh;
    return fallback;
}

// =============================================================================
// Silent aim — close port of AimSilent.h (one sAim1 path, dir-only rewrite).
//
// AimSilent.h:
//   aimingInfo = *(local + sAim1)
//   if (aimingInfo != 0) {
//       start = *(aimingInfo + sAim3)   // 0x4C origin (game-filled)
//       dir   = normalize(head - start)
//       *(aimingInfo + sAim4) = dir     // 0x40 direction
//   }
//   sched_yield();
//
// Reliability notes (why 5/30 hits happened before):
// - Writing MANY GMP slots polluted non-fire paths → chest/random tracers
// - Hip fallback head → chest hits
// - Seeding origin from camera while game later used muzzle → wrong dir
// - Missed fire tick when AimingInfo pointer was null
//
// Fix:
// - PRIMARY sAim1 only (kHitObjectInfo / Alt). Extras only if both primary null.
// - PURE live head bone only (no hip fallback → no chest)
// - Only write when aimingInfo != 0 (AimSilent.h). Origin: prefer game; if 0 use
//   camera for MATH only (do not write origin / hitPoint).
// - Pure yield thread + heavy fire-window hammer on main path
// - NO camera LookAt (silent stays 360)
// =============================================================================
static std::mutex        g_silentMtx;
static std::atomic<bool> g_silentKeepRunning{false};
static std::thread       g_silentThread;
static Vector3           g_silentTargetPos{0, 0, 0};
static Vector3           g_silentFromLoc{0, 0, 0};
static bool              g_silentHasTarget = false;
static uint64_t          g_silentLockedEnemy = 0;
static uint64_t          g_silentLocalPlayer = 0;
static int               g_silentAimPosMode = 0; // AimPos snapshotted with target
static uint64_t          g_lastAimingInfo = 0;
static uint64_t          g_silentCachedInfo = 0;

static const uint64_t kSilentDirOff    = 0x40; // sAim4
static const uint64_t kSilentOriginOff = 0x4C; // sAim3

// AimSilent.h uses ONE sAim1. We try primary then alt (same role, FF/MAX switched).
static inline void SilentFillPrimaryOnly(uint64_t *out, int *outCount) {
    out[0] = kHitObjectInfo;     // FF 0xDC8 / MAX 0xDD0
    out[1] = kHitObjectInfoAlt;  // FF 0xDD0 / MAX 0xDD8
    *outCount = 2;
}

// PURE live head bone only. No root glue / Y bias / track hybrid —
// those shifted the hit point ~1 head-width off and missed near+far.
static inline Vector3 ResolveSilentHeadWorldPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return Vector3{0, 0, 0};
    Vector3 head = getPositionExt(getHead(pawn));
    if (looksLikeWorldPos(head) && !IsZeroVec(head)) {
        Vector3 hip = getPositionExt(getHip(pawn));
        if (looksLikeWorldPos(hip)) {
            float dx = head.x - hip.x, dy = head.y - hip.y, dz = head.z - hip.z;
            float d2 = dx*dx + dy*dy + dz*dz;
            // Reject garbage head far from hip; otherwise use raw skull (no offset).
            if (d2 < 6.0f * 6.0f && head.y >= hip.y - 0.5f)
                return head;
        } else {
            return head;
        }
    }
    // Minimal fallbacks — still no Y pad / root blend.
    head = getPositionExt(getHead(pawn));
    if (looksLikeWorldPos(head) && !IsZeroVec(head)) return head;
    head = ResolveAimHeadWorldPos(pawn);
    if (looksLikeWorldPos(head) && !IsZeroVec(head)) return head;
    return Vector3{0, 0, 0};
}

// Silent / fire-dir bone: honor AimPos (0=Head, 1=Neck, 2=Chest/Body).
// Never force-head when menu says neck/body — that was the "BODY still hits head" bug.
static inline Vector3 ResolveSilentAimWorldPos(uint64_t pawn, int posMode) {
    if (!isVaildPtr(pawn)) return Vector3{0, 0, 0};
    if (posMode < 0) posMode = 0;
    if (posMode > 2) posMode = 2;
    if (posMode == 0) {
        return ResolveSilentHeadWorldPos(pawn);
    }
    Vector3 bone = GetAimTargetPosMode(pawn, posMode, 0.0f);
    if (!IsZeroVec(bone) && looksLikeWorldPos(bone)) return bone;
    // Fallbacks still respect mode: neck slightly below head, body toward hip.
    // The neck fraction and the no-hip drop are held at the same 0.14 the hip
    // path in GetAimTargetPosMode uses, so that picking neck cannot aim the
    // silent path somewhere else than the visible one. They were 0.22 and 0.12
    // here against 0.22 and 0.14 there: two numbers, two more, none of them
    // agreeing.
    Vector3 head = ResolveSilentHeadWorldPos(pawn);
    if (IsZeroVec(head) || !looksLikeWorldPos(head)) return Vector3{0, 0, 0};
    Vector3 hip = getPositionExt(getHip(pawn));
    if (looksLikeWorldPos(hip) && !IsZeroVec(hip)) {
        const float t = (posMode == 1) ? 0.14f : 0.52f;
        return Vector3(head.x + (hip.x - head.x) * t,
                       head.y + (hip.y - head.y) * t,
                       head.z + (hip.z - head.z) * t);
    }
    head.y -= (posMode == 1) ? 0.14f : 0.32f;
    return head;
}

// Zero weapon scatter while Aimbot/Assist is firing (was silent-only → far shots spread).
static inline void ZeroWeaponScatterForAim(uint64_t localPawn) {
    if (!isVaildPtr(localPawn)) return;
    uint64_t weapon = ReadAddr<uint64_t>(localPawn + kActiveWeapon);
    if (!isVaildPtr(weapon)) {
        uint64_t inv = ReadAddr<uint64_t>(localPawn + kWeaponHolder);
        if (isVaildPtr(inv)) weapon = ReadAddr<uint64_t>(inv + kHolderActiveWeapon);
    }
    if (!isVaildPtr(weapon)) return;
    uint64_t rep = ReadAddr<uint64_t>(weapon + kWeaponRepItem);
    if (!isVaildPtr(rep)) return;
    WriteAddr<float>(rep + 0x194, 0.0f); // ScatterNum
    WriteAddr<float>(rep + 0x198, 0.0f); // ScatterMax
    WriteAddr<float>(rep + 0x1E0, 0.0f); // ScatterSpeed
    WriteAddr<float>(rep + 0x1E4, 0.0f); // ScatterRecoverSpeed
    WriteAddr<float>(rep + 0x1EC, 0.0f); // ScatterMove
    // Extra common scatter slots seen on some weapon reps (safe zero if unused).
    WriteAddr<float>(rep + 0x190, 0.0f);
    WriteAddr<float>(rep + 0x19C, 0.0f);
    WriteAddr<float>(rep + 0x1E8, 0.0f);
}

// Cache last LIVE muzzle origin from game (sAim3). Used only when current origin
// is momentarily 0 between bullets — still "real muzzle", not camera.
static Vector3 g_silentLastLiveOrigin{0, 0, 0};

// AimSilent.h dir-only. Prefer live muzzle origin every write.
// Never write origin/hitPoint (VFX-only hits).
static inline bool SilentWriteAimingDir(uint64_t aimingInfo, const Vector3 &targetPos, const Vector3 & /*fromFallback*/) {
    if (!isVaildPtr(aimingInfo) || IsZeroVec(targetPos)) return false;

    Vector3 startPos = ReadAddr<Vector3>(aimingInfo + kSilentOriginOff);
    if (!IsZeroVec(startPos)) {
        g_silentLastLiveOrigin = startPos; // learn real muzzle
    } else if (!IsZeroVec(g_silentLastLiveOrigin)) {
        // Between shots origin can clear for 1 tick — reuse last live muzzle.
        startPos = g_silentLastLiveOrigin;
    } else {
        return false; // no real muzzle yet
    }

    Vector3 dir;
    dir.x = targetPos.x - startPos.x;
    dir.y = targetPos.y - startPos.y;
    dir.z = targetPos.z - startPos.z;
    float mag = sqrtf(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z);
    if (mag <= 0.0001f) return false;
    dir.x /= mag; dir.y /= mag; dir.z /= mag;

    // ONLY sAim4. Recompute if muzzle updated mid-write.
    // Two writes max (was 5) — multi-spam on HitObject inflated client hit feedback
    // (dame ảo) without helping server-side damage.
    WriteAddr<Vector3>(aimingInfo + kSilentDirOff, dir);
    Vector3 start2 = ReadAddr<Vector3>(aimingInfo + kSilentOriginOff);
    if (!IsZeroVec(start2)) {
        g_silentLastLiveOrigin = start2;
        if (fabsf(start2.x - startPos.x) > 0.0005f ||
            fabsf(start2.y - startPos.y) > 0.0005f ||
            fabsf(start2.z - startPos.z) > 0.0005f) {
            dir.x = targetPos.x - start2.x;
            dir.y = targetPos.y - start2.y;
            dir.z = targetPos.z - start2.z;
            mag = sqrtf(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z);
            if (mag > 0.0001f) {
                dir.x /= mag; dir.y /= mag; dir.z /= mag;
            }
        }
    }
    WriteAddr<Vector3>(aimingInfo + kSilentDirOff, dir);
    return true;
}

// Force primary sAim1 only. Returns writes count.
static inline int SilentForcePrimary(uint64_t localPawn, const Vector3 &fromLoc, const Vector3 &targetPos) {
    if (!isVaildPtr(localPawn) || IsZeroVec(targetPos)) return 0;
    int wrote = 0;

    if (isVaildPtr(g_silentCachedInfo)) {
        if (SilentWriteAimingDir(g_silentCachedInfo, targetPos, fromLoc)) {
            wrote++;
            g_lastAimingInfo = g_silentCachedInfo;
        } else if (!isVaildPtr(g_silentCachedInfo)) {
            g_silentCachedInfo = 0;
        }
    }

    uint64_t offs[2];
    int n = 0;
    SilentFillPrimaryOnly(offs, &n);
    for (int i = 0; i < n; i++) {
        uint64_t aimingInfo = ReadAddr<uint64_t>(localPawn + offs[i]);
        if (!isVaildPtr(aimingInfo)) continue;
        g_silentCachedInfo = aimingInfo; // cache even if origin not ready yet
        if (SilentWriteAimingDir(aimingInfo, targetPos, fromLoc)) {
            g_lastAimingInfo = aimingInfo;
            wrote++;
        }
    }
    return wrote;
}

static inline void AimSyncFireHit(uint64_t localPawn, const Vector3 &fromLoc, const Vector3 &targetPos) {
    (void)SilentForcePrimary(localPawn, fromLoc, targetPos);
}

// Pure yield worker — live AimPos bone (Head/Neck/Chest) + live/cached muzzle origin.
// Wall-off: drop target if enemy fails visibility (do not magic-bullet through cover).
static void SilentAimThread(uint64_t localPlayer) {
    while (g_silentKeepRunning.load(std::memory_order_relaxed)) {
        bool hasTarget = false;
        Vector3 targetPos{0, 0, 0};
        Vector3 fromLoc{0, 0, 0};
        uint64_t lp = 0;
        uint64_t enemy = 0;
        int posMode = 0;
        {
            std::lock_guard<std::mutex> lk(g_silentMtx);
            hasTarget = g_silentHasTarget;
            targetPos = g_silentTargetPos;
            fromLoc = g_silentFromLoc;
            lp = g_silentLocalPlayer ? g_silentLocalPlayer : localPlayer;
            enemy = g_silentLockedEnemy;
            posMode = g_silentAimPosMode;
        }

        if (hasTarget && isVaildPtr(lp)) {
            // Wall-off: silent uses STRICT visibility (fail-closed) — no magic through walls.
            if (!AimThroughAnyCoverNow() && isVaildPtr(enemy) && !AimTargetVisibleStrictForSilent(enemy)) {
                SilentAimClearTarget();
                g_lastAimingInfo = 0;
                std::this_thread::yield();
                continue;
            }
            if (isVaildPtr(enemy)) {
                Vector3 live = ResolveSilentAimWorldPos(enemy, posMode);
                if (!IsZeroVec(live)) {
                    targetPos = live;
                    std::lock_guard<std::mutex> lk(g_silentMtx);
                    g_silentTargetPos = live;
                }
            }
            if (!IsZeroVec(targetPos)) {
                for (int i = 0; i < 10; i++) {
                    SilentForcePrimary(lp, fromLoc, targetPos);
                }
            }
        } else {
            g_lastAimingInfo = 0;
        }
        std::this_thread::yield();
    }
}

static void SilentAimSetTarget(uint64_t localPlayer, uint64_t enemy, const Vector3 &bonePos, const Vector3 &fromLoc, int posMode) {
    if (!isVaildPtr(localPlayer) || IsZeroVec(bonePos)) return;
    // Wall-off: silent needs strict LOS flags (fail-closed).
    if (!AimThroughAnyCoverNow() && isVaildPtr(enemy) && !AimTargetVisibleStrictForSilent(enemy)) {
        SilentAimClearTarget();
        return;
    }
    if (posMode < 0) posMode = 0;
    if (posMode > 2) posMode = 2;
    {
        std::lock_guard<std::mutex> lk(g_silentMtx);
        g_silentTargetPos = bonePos;
        g_silentFromLoc = fromLoc;
        g_silentHasTarget = true;
        g_silentLockedEnemy = enemy;
        g_silentLocalPlayer = localPlayer;
        // Snapshot AimPos with target so worker never force-heads when Body selected.
        g_silentAimPosMode = posMode;
    }
    SilentForcePrimary(localPlayer, fromLoc, bonePos);
    if (!g_silentKeepRunning.load(std::memory_order_relaxed)) {
        g_silentKeepRunning = true;
        if (g_silentThread.joinable()) {
            try { g_silentThread.join(); } catch (...) {}
        }
        g_silentThread = std::thread(SilentAimThread, localPlayer);
    }
}

static void SilentAimClearTarget(void) {
    std::lock_guard<std::mutex> lk(g_silentMtx);
    g_silentHasTarget = false;
    g_silentLockedEnemy = 0;
    g_silentTargetPos = Vector3{0, 0, 0};
    g_silentFromLoc = Vector3{0, 0, 0};
    g_silentCachedInfo = 0;
    g_silentLastLiveOrigin = Vector3{0, 0, 0};
    g_silentAimPosMode = 0;
}

static void SilentAimStop(void) {
    g_silentKeepRunning = false;
    if (g_silentThread.joinable()) {
        try { g_silentThread.join(); } catch (...) {}
    }
    std::lock_guard<std::mutex> lk(g_silentMtx);
    g_silentHasTarget = false;
    g_silentLockedEnemy = 0;
    g_silentLocalPlayer = 0;
    g_silentTargetPos = Vector3{0, 0, 0};
    g_silentFromLoc = Vector3{0, 0, 0};
    g_lastAimingInfo = 0;
    g_silentCachedInfo = 0;
    g_silentLastLiveOrigin = Vector3{0, 0, 0};
    g_silentAimPosMode = 0;
}

// =============================================================================
// Camera aim lock thread — closest thing to "100% block fire-stick look" on
// external memory cheats (no native input hook available in this project).
//
// While active, hammers AimRotation/Aux/Current every yield so game fire-pad
// look deltas cannot stick for more than ~1 sim tick. Not a true input block
// (would need HID/UI hook inside the game process); this is continuous override.
// =============================================================================
static std::mutex        g_aimLockMtx;
static std::atomic<bool> g_aimLockRunning{false};
static std::thread       g_aimLockThread;
static bool              g_aimLockActive = false;
static uint64_t          g_aimLockLocal = 0;
// Fixed quaternion from main frame — thread ONLY re-stamps this.
// Re-sampling bone/lead every microtick was the single-target "giật nhộn" cause.
static Quaternion        g_aimLockQuat{};
static bool              g_aimLockHaveQuat = false;

static void AimLockThreadMain(void) {
    while (g_aimLockRunning.load(std::memory_order_relaxed)) {
        bool active = false;
        bool haveQ = false;
        uint64_t lp = 0;
        Quaternion q{};
        {
            std::lock_guard<std::mutex> lk(g_aimLockMtx);
            active = g_aimLockActive;
            haveQ = g_aimLockHaveQuat;
            lp = g_aimLockLocal;
            q = g_aimLockQuat;
        }
        if (active && haveQ && isVaildPtr(lp)) {
            // Gentle inter-frame hold vs fire-stick — low rate so cam doesn't shake.
            write_aim_rotations(lp, q);
        }
        if (active) {
            std::this_thread::sleep_for(std::chrono::milliseconds(4));
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(12));
        }
    }
}

// Main thread publishes the look quaternion for the lock thread to hammer.
static void AimLockSetQuat(uint64_t localPlayer, const Quaternion &q) {
    if (!isVaildPtr(localPlayer)) return;
    float n = q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w;
    if (!(n > 0.0001f) || isnan(n)) return;
    {
        std::lock_guard<std::mutex> lk(g_aimLockMtx);
        g_aimLockActive = true;
        g_aimLockLocal = localPlayer;
        g_aimLockQuat = Quaternion::Normalized(q);
        g_aimLockHaveQuat = true;
    }
    if (!g_aimLockRunning.load(std::memory_order_relaxed)) {
        g_aimLockRunning = true;
        if (g_aimLockThread.joinable()) {
            try { g_aimLockThread.join(); } catch (...) {}
        }
        g_aimLockThread = std::thread(AimLockThreadMain);
    }
}

// Legacy signature kept for any remaining call sites — converts to quat path.
static void AimLockSet(uint64_t localPlayer, uint64_t /*enemy*/, int /*posMode*/, float /*dist*/, const Vector3 & /*fromLoc*/) {
    // Without a fresh quat, just keep previous stamp if any.
    if (!isVaildPtr(localPlayer)) return;
    std::lock_guard<std::mutex> lk(g_aimLockMtx);
    g_aimLockActive = g_aimLockHaveQuat;
    g_aimLockLocal = localPlayer;
}

static void AimLockClear(void) {
    std::lock_guard<std::mutex> lk(g_aimLockMtx);
    g_aimLockActive = false;
    g_aimLockHaveQuat = false;
    // keep thread alive idle (cheap yields) — restart cost is higher than idle yield
}

static void AimLockStop(void) {
    g_aimLockRunning = false;
    {
        std::lock_guard<std::mutex> lk(g_aimLockMtx);
        g_aimLockActive = false;
        g_aimLockHaveQuat = false;
        g_aimLockLocal = 0;
    }
    if (g_aimLockThread.joinable()) {
        try { g_aimLockThread.join(); } catch (...) {}
    }
}


// The rainbow nickname substitutes a pointer the game does not own into the
// player's own object. Remembered here so it can be taken back out again.
//
// What is substituted is a string object built by AllocateMonoString: raw
// memory from mach_vm_allocate in the game's address space, with an Il2Cpp string
// header hand-written into it. It is not from the game's allocator and the
// garbage collector has never seen it.
//
// Leaving a match destroys the player object, and destroying it releases the
// nickname. The game then frees the pointer we put there — a pointer from
// mach_vm_allocate, not from its heap — and that is an invalid free into the
// game's allocator. This is the shape of "the game dies on the way out of a
// match": it happens at teardown, every time, and only when the name swap is on.
static uint64_t g_rainbowOrigNick = 0;
static uint64_t g_rainbowOrigNickDisp = 0;
static uint64_t g_rainbowPawn = 0;
static int      g_rainbowInit = 0;

// Put the game's own string pointers back before anything else happens at the end
// of a match. Must run while the page mappings are still alive, so it goes before
// the cache flush, not after.
//
// Written to the pawn that was patched, not to whatever the local pointer says
// now: if the pawn has already changed, that is a different object and putting a
// string pointer into it would be the same bug in a new place.
static void RainbowNameDetach(void) {
    if (g_rainbowOrigNick && isVaildPtr(g_rainbowPawn)) {
        WriteAddr<uint64_t>(g_rainbowPawn + kNickname, g_rainbowOrigNick);
        if (g_rainbowOrigNickDisp) {
            WriteAddr<uint64_t>(g_rainbowPawn + kNicknameDisplay, g_rainbowOrigNickDisp);
        }
    }
    g_rainbowOrigNick = 0;
    g_rainbowOrigNickDisp = 0;
    g_rainbowPawn = 0;
    // The fake strings are built against the klass of the string they copied, and
    // a new match is a new pawn with a new object. They are not reused.
    g_rainbowInit = 0;
}

task_t g_target_task = 0;

uint64_t AllocateMonoString(task_t task, uint64_t originalStrPtr, NSString *nsStr) {
    if (!task || !isVaildPtr(originalStrPtr) || !nsStr) return 0;
    uint64_t klass = ReadAddr<uint64_t>(originalStrPtr);
    if (!isVaildPtr(klass)) return 0;
    
    mach_vm_address_t newAlloc = 0;
    NSUInteger len = nsStr.length;
    mach_vm_size_t size = 0x14 + (len * 2) + 2; 
    
    if (mach_vm_allocate(task, &newAlloc, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return 0;
    
    WriteAddr<uint64_t>(newAlloc, klass);
    WriteAddr<uint64_t>(newAlloc + 0x8, 0); 
    WriteAddr<int32_t>(newAlloc + 0x10, (int32_t)len);
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [nsStr characterAtIndex:i];
        WriteAddr<uint16_t>(newAlloc + 0x14 + (i * 2), (uint16_t)c);
    }
    WriteAddr<uint16_t>(newAlloc + 0x14 + (len * 2), 0);
    return newAlloc;
}

NSString* External_ReadNickname(uint64_t playerObj) {
    if (!isVaildPtr(playerObj)) return nil;
    uint64_t strPtr = ReadAddr<uint64_t>(playerObj + (uint64_t)kNickname);
    if (!isVaildPtr(strPtr)) return nil;
    int32_t length = ReadAddr<int32_t>(strPtr + 0x10);
    if (length <= 0 || length > 128) return nil;
    std::vector<uint16_t> buf(length);
    for (int i = 0; i < length; i++) {
        buf[i] = ReadAddr<uint16_t>(strPtr + 0x14 + (i * 2));
    }
    return [NSString stringWithCharacters:(const unichar*)buf.data() length:length];
}

NSString *GenerateRainbowString(NSString *baseStr, int tickOffset) {
    NSArray *hexColors = @[@"FFFF00", @"00FF00"];
    NSMutableString *result = [NSMutableString string];
    NSString *cleanBase = [baseStr stringByReplacingOccurrencesOfString:@"\\[.*?\\]" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, baseStr.length)];
    
    for (NSUInteger i = 0; i < cleanBase.length; i++) {
        unichar c = [cleanBase characterAtIndex:i];
        if (c == ' ') {
            [result appendFormat:@" "]; 
        } else {
            int colorIdx = (i + tickOffset) % hexColors.count;
            [result appendFormat:@"[%@]%C", hexColors[colorIdx], c];
        }
    }
    return result;
}
// ĐÃ FIX: Chuyển hàm IsZeroVec lên trước GetAimTargetPosMode
static inline bool IsZeroVec(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

// Motion track: velocity from HIP (stable locomotion), aim point from HEAD (hitbox).
// Head bone bob while sprinting was making lead noisy → aim felt "tạm tạm" on movers.
struct AimMotionTrack {
    uint64_t pawn = 0;
    Vector3 lastHip = {0, 0, 0};
    Vector3 lastHead = {0, 0, 0};
    Vector3 vel = {0, 0, 0};      // smoothed world velocity m/s (mostly XZ)
    Vector3 smoothHead = {0, 0, 0};
    CFTimeInterval lastT = 0;
    bool valid = false;
};

// Slot count shared by EVERY per-pawn table in this file, and the modulus used to
// index them. One name for both: they used to be separate bare literals repeated in
// ten places, and nothing stopped them disagreeing.
//
// 96 was sized for a Clash Squad lobby. A Survival lobby does not fit in it -- with
// 100 pawns in 96 slots the expected number of colliding pairs is C(100,2)/96 =
// 51.6, so 64 of the 100 pawns share a slot with another, and a colliding pair is
// in a PERMANENT per-frame cache miss because the slot's identity is written after
// the lookup that reads it. At 1024 that is 4.83 pairs.
//
// This does not make collisions impossible, only rare: a 100-pawn lobby has no
// collision at all with probability exp(-4.8), about 0.8%. It is a tenfold
// improvement, not a cure, and the cure for the remaining residue is not a table
// size -- see the note where s_countTeamUnknown is printed.
static constexpr int kPawnSlotCount = 1024;

static AimMotionTrack g_aimMotion[kPawnSlotCount];

static AimMotionTrack *AimMotionSlot(uint64_t pawn) {
    if (pawn == 0) return nullptr;
    // Use the same stable hash as PosTrack/PlayerCache so different pawns don't
    // collide as often, and we can reason about "exact pawn" ownership.
    int slotIdx = PosTrackSlot(pawn);
    AimMotionTrack *slot = &g_aimMotion[slotIdx];
    if (slot->pawn != pawn) {
        *slot = AimMotionTrack{};
        slot->pawn = pawn;
    }
    return slot;
}

// Lead for aim. bulletLead=true → stronger prediction for hit path; false → mild for camera.
static Vector3 AimTrackAndLeadEx(uint64_t pawn, Vector3 bodyPos, float distanceMeters, bool lockYToBody, bool bulletLead) {
    AimMotionTrack *tr = AimMotionSlot(pawn);
    if (!tr) return bodyPos;
    if (!looksLikeWorldPos(bodyPos)) return bodyPos;

    Vector3 hip = getPositionExt(getHip(pawn));
    Vector3 root = ReadPlayerRootTransform(pawn);
    // Prefer network root for velocity on real players (more stable than lagging bones).
    Vector3 motionAnchor = bodyPos;
    if (looksLikeWorldPos(root) && !get_IsBot(pawn)) motionAnchor = root;
    else if (looksLikeWorldPos(hip) && !IsZeroVec(hip)) motionAnchor = hip;

    const CFTimeInterval now = CACurrentMediaTime();
    if (!tr->valid || tr->lastT <= 0.0) {
        tr->lastHip = motionAnchor;
        tr->lastHead = bodyPos;
        tr->smoothHead = bodyPos;
        tr->vel = {0, 0, 0};
        tr->lastT = now;
        tr->valid = true;
        return bodyPos;
    }

    float dt = (float)(now - tr->lastT);
    if (dt < 0.0005f) dt = 0.0005f;
    if (dt > 0.12f) {
        tr->lastHip = motionAnchor;
        tr->lastHead = bodyPos;
        tr->smoothHead = bodyPos;
        tr->vel = {0, 0, 0};
        tr->lastT = now;
        return bodyPos;
    }

    Vector3 instHip = {
        (motionAnchor.x - tr->lastHip.x) / dt,
        0.f,
        (motionAnchor.z - tr->lastHip.z) / dt
    };
    Vector3 instBody = {
        (bodyPos.x - tr->lastHead.x) / dt,
        0.f,
        (bodyPos.z - tr->lastHead.z) / dt
    };
    // Prefer root/hip velocity for movers (body bone noise).
    Vector3 inst = {
        instHip.x * 0.70f + instBody.x * 0.30f,
        0.f,
        instHip.z * 0.70f + instBody.z * 0.30f
    };

    // Low-pass the instantaneous samples before EMA (kills animation jitter).
    static Vector3 s_instFilt[kPawnSlotCount] = {};
    int slot = (int)(pawn % kPawnSlotCount);
    Vector3 &filt = s_instFilt[slot];
    if (filt.x == 0.f && filt.z == 0.f) {
        filt = inst;
    } else {
        float fa = 0.45f; // one-pole lowpass on inst samples
        filt.x = filt.x * (1.f - fa) + inst.x * fa;
        filt.z = filt.z * (1.f - fa) + inst.z * fa;
    }
    Vector3 instF = filt;

    float instSpeed = sqrtf(instF.x * instF.x + instF.z * instF.z);
    float alpha = bulletLead
        ? (0.55f + fminf(instSpeed, 12.f) * 0.035f)   // 0.55..0.97 bullets
        : (0.38f + fminf(instSpeed, 10.f) * 0.025f);  // 0.38..0.63 camera
    if (alpha > (bulletLead ? 0.95f : 0.68f)) alpha = bulletLead ? 0.95f : 0.68f;
    tr->vel.x = tr->vel.x * (1.f - alpha) + instF.x * alpha;
    tr->vel.z = tr->vel.z * (1.f - alpha) + instF.z * alpha;
    tr->vel.y = 0.f;

    float speed = sqrtf(tr->vel.x * tr->vel.x + tr->vel.z * tr->vel.z);
    if (speed < (bulletLead ? 0.22f : 0.40f)) {
        tr->vel.x = 0.f;
        tr->vel.z = 0.f;
        speed = 0.f;
    }

    const float maxSpeed = bulletLead ? 14.0f : 11.0f;
    if (speed > maxSpeed) {
        float inv = maxSpeed / speed;
        tr->vel.x *= inv;
        tr->vel.z *= inv;
        speed = maxSpeed;
    }

    tr->smoothHead = bodyPos;
    tr->lastHip = motionAnchor;
    tr->lastHead = bodyPos;
    tr->lastT = now;

    // Bullet: almost no prediction (lead was landing ~1 head off). Tiny only if sprinting.
    float lead = 0.f;
    if (bulletLead) {
        if (speed > 2.5f) {
            lead = 0.010f + (speed / maxSpeed) * 0.025f;
            if (lead > 0.035f) lead = 0.035f;
        }
    } else if (speed > 1.5f) {
        lead = 0.008f + (speed / maxSpeed) * 0.018f;
        if (lead > 0.025f) lead = 0.025f;
    }

    (void)lockYToBody;
    if (lead <= 0.0001f) return bodyPos;
    Vector3 out = {
        bodyPos.x + tr->vel.x * lead,
        bodyPos.y,
        bodyPos.z + tr->vel.z * lead
    };
    return out;
}

static Vector3 AimTrackAndLead(uint64_t pawn, Vector3 bodyPos, float distanceMeters, bool lockYToBody) {
    // Default = camera path (mild lead).
    return AimTrackAndLeadEx(pawn, bodyPos, distanceMeters, lockYToBody, /*bulletLead=*/false);
}

// Shared by Aimbot + Aim Assist: Head / Neck / Chest (AimPos).
// Head mode: pure skinned head first (best headshot), not ESP root-hybrid.
Vector3 GetAimTargetPosMode(uint64_t pawn, int posMode, float distance) {
    (void)distance;
    if (!isVaildPtr(pawn)) return Vector3{0,0,0};
    // Live head bone first — critical for head lock on remotes.
    Vector3 liveHead = getPositionExt(getHead(pawn));
    Vector3 hip = getPositionExt(getHip(pawn));
    Vector3 root = ReadPlayerRootTransform(pawn);
    Vector3 head = liveHead;
    bool headOk = false;
    if (looksLikeWorldPos(liveHead)) {
        Vector3 anchor = looksLikeWorldPos(hip) ? hip : root;
        if (!looksLikeWorldPos(anchor)) {
            headOk = true;
        } else {
            float dx = liveHead.x - anchor.x, dy = liveHead.y - anchor.y, dz = liveHead.z - anchor.z;
            float d2 = dx*dx + dy*dy + dz*dz;
            if (d2 < 6.0f * 6.0f && liveHead.y >= anchor.y - 0.6f) headOk = true;
        }
    }
    if (!headOk) {
        // Ghost-safe: live head/root/mount only — no sticky track invent.
        head = getPositionExt(getHead(pawn));
        if (IsZeroVec(head) || !looksLikeWorldPos(head)) {
            Vector3 mount{};
            if (IsActivelyMounted(pawn, &mount) && looksLikeWorldPos(mount)) {
                head = mount;
            } else if (looksLikeWorldPos(root)) {
                head = root;
                head.y += 0.85f;
            } else if (looksLikeWorldPos(hip)) {
                head = hip;
                head.y += 0.55f;
            } else {
                return Vector3{0, 0, 0};
            }
        }
    }
    // No root XZ glue — that shifted skull sideways by ~1 head width.

    if (posMode == 0) {
        return head; // pure Head
    }

    Vector3 hipPos = looksLikeWorldPos(hip) ? hip : Vector3{0, 0, 0};
    if (IsZeroVec(hipPos) || !looksLikeWorldPos(hipPos)) {
        if (looksLikeWorldPos(root)) {
            hipPos = root;
        } else {
            // No hip: drop Y enough that Neck/Body are visibly not skull. Held at
            // the same 0.14 as the neck fraction above and as the silent path's
            // no-hip drop, so a pawn without a readable hip aims at the same
            // place whichever path resolves it.
            head.y -= (posMode == 1) ? 0.14f : 0.34f;
            return head;
        }
    }

    const float dx = hipPos.x - head.x;
    const float dy = hipPos.y - head.y;
    const float dz = hipPos.z - head.z;

    if (posMode == 1) {
        // Neck: ~14% head→hip, up from 22%. Higher on the body, which is what
        // makes the drag easier -- the target sits nearer the head, so the stick
        // travels less to put it there.
        //
        // 0.22 was not a value anyone chose against 0.10; it was chosen against
        // it. 0.10 read as a headshot, so 0.22 was the step away from that. 0.14
        // is a step back towards it on purpose, and deliberately not further:
        // the same note that rejected 0.10 is the reason to stop short of it.
        //
        // Matched by ResolveSilentAimWorldPos's fallback and by both no-hip
        // fallbacks below, so the visible aim and the silent one cannot land on
        // different points. They were already 0.14 and 0.12 there, i.e. already
        // disagreeing with each other and with this 0.22.
        const float t = 0.14f;
        return Vector3(head.x + dx * t, head.y + dy * t, head.z + dz * t);
    }

    // Chest / Body ("thân"): mid-torso ~52% head→hip (old 0.40 still upper-chest/head).
    const float t = 0.52f;
    return Vector3(head.x + dx * t, head.y + dy * t, head.z + dz * t);
}

// Camera LookAt — SMOOTH, once per frame. Hit accuracy = silent / fire-dir path.
// Never multi-burst, never double-write, never fight stick every microtick.
static inline Vector3 AimLookAtHeadLive(uint64_t localPawn, uint64_t targetPawn, int aimPosMode,
                                        float distanceMeters, Vector3 fromFallback, int bursts,
                                        Vector3 *outLastAim, bool freezeOrigin) {
    if (!isVaildPtr(localPawn) || !isVaildPtr(targetPawn)) return Vector3{0, 0, 0};
    (void)bursts;
    (void)freezeOrigin;
    update_aim_assist_legit_tuning(false);
    // Kill AA magnet strength while custom LookAt runs (wall ON/OFF).
    DisableGameDefaultAimAssist(localPawn, isKillGameAA);

    // Ghost-safe: live aim bone only — never invent from sticky track after death.
    Vector3 bone = GetAimTargetPosMode(targetPawn, aimPosMode, distanceMeters);
    if (IsZeroVec(bone) || !looksLikeWorldPos(bone)) {
        Vector3 liveHead = getPositionExt(getHead(targetPawn));
        if (looksLikeWorldPos(liveHead)) bone = liveHead;
    }
    if (IsZeroVec(bone) || !looksLikeWorldPos(bone)) {
        if (outLastAim) *outLastAim = Vector3{0, 0, 0};
        return Vector3{0, 0, 0};
    }
    // Camera uses mild lead; bullets use AimTrackAndLeadEx(... bulletLead=true) separately.
    Vector3 aimed = AimTrackAndLeadEx(targetPawn, bone, distanceMeters, true, /*bulletLead=*/false);
    if (IsZeroVec(aimed) || !looksLikeWorldPos(aimed)) aimed = bone;

    Vector3 from = AimCameraOrigin(localPawn, fromFallback);
    if (IsZeroVec(from) || !looksLikeWorldPos(from)) from = fromFallback;
    if (IsZeroVec(from) || !looksLikeWorldPos(from)) {
        from = getPositionExt(getHead(localPawn));
    }
    if (IsZeroVec(from) || !looksLikeWorldPos(from)) {
        if (outLastAim) *outLastAim = aimed;
        return aimed;
    }

    Quaternion targetQ = Quaternion::Normalized(GetRotationToLocation(aimed, 0.0f, from));
    if (isnan(targetQ.x) || isnan(targetQ.y) || isnan(targetQ.z) || isnan(targetQ.w)) {
        if (outLastAim) *outLastAim = aimed;
        return aimed;
    }

    // Aimbot: snap direct to targetQ; Legit: smooth blend
    Quaternion cur = ReadAddr<Quaternion>(localPawn + kAimRotation);
    float n = cur.x*cur.x + cur.y*cur.y + cur.z*cur.z + cur.w*cur.w;
    Quaternion outQ = targetQ;
    if (isAimLegit && n > 0.0001f && !isnan(n)) {
        cur = Quaternion::Normalized(cur);
        float ang = Quaternion::Angle(cur, targetQ);

        const float kDeadzoneRad = 0.0035f; // ~0.2°
        if (ang < kDeadzoneRad) {
            outQ = cur; // hold steady, do not copy noise
        } else {
            float dt = esp_aim_delta_time();
            float rate = 90.0f;
            if (ang > 0.25f)      rate = 240.0f;
            else if (ang > 0.10f) rate = 160.0f;
            else if (ang > 0.04f) rate = 110.0f;

            float alpha = 1.0f - expf(-rate * fmaxf(dt, 0.004f));
            alpha = fminf(alpha, 0.985f);

            outQ = Quaternion::Normalized(Quaternion::Slerp(cur, targetQ, alpha));
            if (isnan(outQ.x) || isnan(outQ.y) || isnan(outQ.z) || isnan(outQ.w)) outQ = targetQ;
        }
    }
    write_aim_rotations(localPawn, outQ);
    write_aim_rotations(localPawn, outQ);
    AimSyncFireHit(localPawn, from, aimed);

    static int s_lookLiveLog = 0;
    if (++s_lookLiveLog % 60 == 1) {
        NSLog(@"[AIM] AimLookAtHeadLive: target=0x%llx, bone=(%.1f, %.1f, %.1f), dist=%.1f, mode=%d",
              (unsigned long long)targetPawn, bone.x, bone.y, bone.z, distanceMeters, aimPosMode);
    }

    if (outLastAim) *outLastAim = aimed;
    return aimed;
}

Quaternion GetRotationToLocation(Vector3 targetLocation, float y_bias, Vector3 myLoc);
void set_aim(uint64_t player, Quaternion rotation, float speed, int mode, bool forceInstant);
void set_aim_legit(uint64_t player, Quaternion rotation, float targetDistance);
void update_aim_assist_legit_tuning(bool enable);
bool get_IsBot(uint64_t player);
bool get_IsKnockedDown(uint64_t player);
bool get_IsBeingRescued(uint64_t player);
bool get_IsFiring(uint64_t player);
bool get_IsScoping(uint64_t player);
bool get_IsVisible(uint64_t player);
bool get_IsVisibleByFlag(uint64_t player, uint32_t flag);
bool get_IsFPPVisible(uint64_t player);
static inline uint32_t get_VisibleFlags(uint64_t player);

uint64_t Moudule_Base = -1;
int g_PlayerDrawIndex = 1;

bool isESP = YES;
bool isESP2 = NO; 
bool isBox = YES; bool isBone = YES; bool isHealth = YES;
int boxMode = 0; 
bool isName = YES; bool isDis = YES; bool isLine = YES;
bool isEspBot = NO; bool isWeapon = NO; bool isCount = YES; 
bool isAlert360 = NO; 
bool isAlertNum = NO; 
bool Norecoil = NO;
bool isSpeed = NO;           // PlayerAttributes.RunSpeedUpScale boost
float speedvalue = 1.0f;     // Brutal run scale when Norecoil ON (pref BrutalSpeed)
float moveSpeedScale = 1.0f; // Speed multiplier (1.0 = off/normal)
bool isShowFovCircle = YES;  // Draw the FOV ring. Not tied to the aimbot any more.
// The ring's radius, as a screen radius in points. It used to be aimFov, which
// welded two unrelated settings together: the only way to shrink the circle was
// to shorten how far the aim reaches. Free Fire here is 844x390 landscape, so
// viewHeight is 390 and anything past about 190 runs off the top and bottom.
// The slider is capped at 190 for that reason and the clamp below is the
// backstop for a pref written by an older build.
float fovSize = 120.0f;
bool isEspCheckVisible = NO;
bool isAimIgnoreBot = NO; bool isAimIgnoreKnock = NO;
// isAimBehindWall defined near wall helpers (default NO).
bool isAimRage = NO; bool isFastReload = NO;
bool isAimLegit = NO;
float fastReloadSpeed = 1.0f;

bool isAimbot = NO; bool isAimAssist = NO;
// The game's own chest magnet. This is the only thing that decides whether it
// gets stomped: on kills it for the whole match, off leaves it alone even while a
// custom aim is firing. Every call site passes this and nothing else.
bool isKillGameAA = YES;
bool isAimSilent = NO; // independent magic bullet (HitObject spoof while firing)
// Aim sphere mode (requires Aimbot): 0=FOV circle, 1=180 front, 2=360 full.
int aimSphereMode = 0;
int triggerMode = 0; int aimPosition = 0;

// Which probe inside get_IsFiring said "the fire button is held". Declared up
// here because [AIM-DIAG] prints the mask and that log runs long before the
// function that fills it.
//
// Only the three marked (tbl) come from GameOffsets. The other two are magic
// numbers that were already inside get_IsFiring with no record of where they
// came from, and they are in neither kOffsetsFF nor kOffsetsFFMax. They are
// still read, and still reported, but they no longer decide the answer — see
// get_IsFiring for why that matters.
enum {
    kFireSrcEnum   = 1 << 0,   // tbl: kIsFiring  (StartFireState enum)
    kFireSrcAlt    = 1 << 1,   // magic 0x1C14, in neither offsets table
    kFireSrcPrep   = 1 << 2,   // tbl: kIsPrepareAttack
    kFireSrcAltB   = 1 << 3,   // magic 0x7D8, in neither offsets table
    kFireSrcPri    = 1 << 4,   // tbl: PRI var 21
};
#define kFireSrcDecidable (kFireSrcEnum | kFireSrcPrep | kFireSrcPri)
static int g_fireSrcMask = 0;

int aimTargetMode = 0; float aimFov = 150.0f;
float aimDistance = 200.0f; float aimSpeed = 1.0f;
int aimMode = 1; 

bool isStreamerMode = NO;

float espDistanceLimit = 150.0f;
float boxThick = 1.0f;
float boxR = 0.0f, boxG = 1.0f, boxB = 1.0f;
// 0 = Color Picker (custom RGB), 1 = Rainbow cycle
int boxColorMode = 0;
float boneThick = 1.2f;
float boneR = 0.0f, boneG = 1.0f, boneB = 1.0f;
int boneColorMode = 0;
float lineThick = 1.0f;
float lineR = 0.0f, lineG = 1.0f, lineB = 1.0f;
int lineColorMode = 0;
float fovThick = 0.6f;
float fovR = 1.0f, fovG = 1.0f, fovB = 0.0f;
int fovColorMode = 0;
float aimAssistThick = 1.5f;
float aimAssistR = 0.0f, aimAssistG = 1.0f, aimAssistB = 1.0f;

// Rainbow HSV → RGB. phaseOffset staggers Box/Line/FOV so they don't all match.
static inline void ESPRainbowRGB(float phaseOffset, float *outR, float *outG, float *outB) {
    float h = fmodf((float)CACurrentMediaTime() * 0.45f + phaseOffset, 1.0f);
    if (h < 0.0f) h += 1.0f;
    float s = 1.0f, v = 1.0f;
    float c = v * s;
    float x = c * (1.0f - fabsf(fmodf(h * 6.0f, 2.0f) - 1.0f));
    float m = v - c;
    float r = 0, g = 0, b = 0;
    float h6 = h * 6.0f;
    if (h6 < 1.0f)      { r = c; g = x; b = 0; }
    else if (h6 < 2.0f) { r = x; g = c; b = 0; }
    else if (h6 < 3.0f) { r = 0; g = c; b = x; }
    else if (h6 < 4.0f) { r = 0; g = x; b = c; }
    else if (h6 < 5.0f) { r = x; g = 0; b = c; }
    else                { r = c; g = 0; b = x; }
    *outR = r + m;
    *outG = g + m;
    *outB = b + m;
}

static inline void ESPResolveDrawColor(int mode, float baseR, float baseG, float baseB,
                                       float phaseOffset, float *outR, float *outG, float *outB) {
    if (mode == 1) {
        ESPRainbowRGB(phaseOffset, outR, outG, outB);
    } else {
        *outR = baseR;
        *outG = baseG;
        *outB = baseB;
    }
}

// gAimLockTarget / gAimLockLostFrames declared near wall helpers (toggle-off clears lock).
// Wall-ON: keep lock a bit while target strafes. Wall-OFF: never sticky (see maxLost below).
static const int kAimLockMaxLostFrames = 4;

// The FOV gates, and why they are not the ring's radius.
//
// 09fbf6da0 made every one of them the ring's own radius after ten frames of
// lock, on the theory that the circle is a promise. That promise cost the aimbot:
// the target was acquired and then failed AimTargetStillValid on the following
// frame, so nothing was ever written. The working reference
// (/home/tduck/Projects/tipar-normal) keeps slack in all three places and the
// numbers are now the same here:
//
//   pick            aimFovSq            the ring, exactly
//   lock re-eval    aimFovSq * 2.25     tipar-normal esp.mm:4936
//   still-valid     aimFovSq * 1.5      tipar-normal esp.mm:5128
//   lookOk          aimFovSq * 1.5      tipar-normal esp.mm:5311
//
// 2.25 held too far across the screen, which is what "it locks an enemy outside
// the FOV" was. 1.0 dropped it mid-aim, which is "the aim does nothing". 1.5 is
// the balance the reference settled on, and stickFighting still switches the
// still-valid gate off entirely while the fire stick is being dragged.

// ===== Player Cache để giảm số lần đọc memory (2-3 frame) =====
struct PlayerCache {
    uint64_t pawn = 0;
    bool isBot = false;
    bool isKnocked = false;
    // Last successfully read team, 0 meaning "not known yet". Cached because the
    // teammate test reads it before the HP reads and cannot afford a late read to
    // change the answer -- see the comment at the test.
    int team = 0;
    int curHP = 0;
    int maxHP = 0;
    bool isFPP = false;
    bool isCamVis = false;
    bool isPvsVis = false;
    bool isTrueVis = false; // camera + occlusion (no wall aim)
    int visGoodFrames = 0;  // consecutive true LOS frames (wall-off hysteresis)
    int frame = 0;
};

static PlayerCache g_playerCache[kPawnSlotCount];
static int g_cacheFrameCounter = 0;

// Sticky ESP/aim world pos.
// Real players (networked): skinned bones lag hard strafe; PlayerTransform root is
// the authority. Bots (local sim): head bone is fine and snappier.
// Source: 0=none 1=head 2=hip 3=root 4=mount 5=rootXZ+headY (remote hybrid)
struct PosTrack {
    uint64_t pawn = 0;
    Vector3 headSmoothed{};
    Vector3 hipSmoothed{};
    Vector3 lastHeadRaw{};
    Vector3 lastHipRaw{};
    Vector3 headVel{}; // m/s XZ (Y unused)
    Vector3 hipVel{};
    CFTimeInterval lastHeadT = 0;
    CFTimeInterval lastHipT = 0;
    int headSrc = 0;
    int hipSrc = 0;
    int headSrcHold = 0;
    int hipSrcHold = 0;
    int frame = 0;
    bool hasHead = false;
    bool hasHip = false;
    bool isBot = false;
    // Death hold tied to exact pawn (avoids kPawnSlotCount bucket collisions)
    int deadUntilFrame = 0;
    // Canonical body length (world) learned from good live head<->hip pairs; stabilizes box height
    float bodyLen = 0.f;
    int bodyLenHold = 0;
    bool wasMounted = false;
    // Track last source used for display smoothing to detect flips (head/hip/root/mount)
    int lastHeadSrcDisp = 0;
    int lastHipSrcDisp = 0;
};
static PosTrack g_posTrack[kPawnSlotCount];

static inline int PosTrackSlot(uint64_t pawn) {
    uint64_t x = pawn ^ (pawn >> 17) ^ (pawn << 7);
    return (int)(x % kPawnSlotCount);
}

// ---------------------------------------------------------------------------
// One resolved aim bone per pawn per FRAME.
//
// Both resolvers are pure functions of the pawn's live transform chain, and the
// chain is not cheap: getBoneTrans tries up to three node layouts and
// getPositionExt then walks up to 64 parents, each level costing a TMatrix read
// plus a parent-index read, every one of them a different page.
//
// The aim half of a frame used to ask for the same pawn's bone over and over.
// Counting the call sites inside one renderESPWithBuffers call, for one target:
// AimTargetStillValid is invoked three times (the pre-decision check, the silent
// branch, the camera branch) and each invocation resolved the bone again; the
// silent branch then resolved it once more for silentBone, once more for liveBone
// with nothing in between that could change it, and thirty more times inside the
// burst loop, one every fourth of 120 iterations; the camera branch resolved it
// again for lookBone, and the fire-dir spoof resolved it twice more. That is
// roughly forty resolutions of the SAME pawn inside one frame, on top of the
// SilentAimThread doing an unbounded number of its own on another thread.
//
// Re-resolving inside a frame can only ever see the target move a couple of
// centimetres, because a 120-iteration burst loop finishes in a millisecond or
// two. What it does reliably see, once the per-pawn working set no longer fits the
// page cache, is a miss on every one of those pages: a Clash Squad match resolves
// all of it out of resident mappings, and a Survival match with fifty to a hundred
// players re-maps the target's chain dozens of times per frame through
// vm_map_remote_page, under the one lock the render loop is also blocked on. The
// aim write is the LAST thing a frame does, so it is the first thing to slip past
// its tick when that happens. The boxes, drawn in the middle of the frame, keep
// working -- which is the reported shape of the bug.
//
// One slot is enough: every consumer in a frame is asking about the same bestTarget
// with the same aimPosition.
//
// Scope: main queue only. Every call site replaced below sits inside
// renderESPWithBuffers, which has one caller (updateFrame, main queue). The
// SilentAimThread keeps calling the raw resolver, so nothing here is read or
// invalidated from another thread. g_cacheFrameCounter is bumped once at the top of
// every renderESPWithBuffers call, so it is the frame identity and needs no atomics.
//
// Deliberately NOT memoized: a resolve that came back zero or off-world. Caching a
// failed read would turn "retry on the next call" into "retry never, this frame",
// and every existing fallback chain depends on that retry.
enum : int { kAimBoneSilent = 0, kAimBonePosMode = 1 };

struct AimBoneMemo {
    uint64_t pawn = 0;
    Vector3 pos{};
    int posMode = -1;
    int kind = -1;
    int frame = -1;
};
static AimBoneMemo s_aimBoneMemo{};

static inline bool AimBoneMemoFrameHit(int kind, uint64_t pawn, int posMode) {
    if (!isVaildPtr(pawn)) return false;
    if (s_aimBoneMemo.frame != g_cacheFrameCounter) return false;
    if (s_aimBoneMemo.kind != kind) return false;
    if (s_aimBoneMemo.pawn != pawn) return false;
    if (s_aimBoneMemo.posMode != posMode) return false;
    return true;
}

static inline void AimBoneMemoStore(int kind, uint64_t pawn, int posMode, const Vector3 &p) {
    if (!isVaildPtr(pawn)) return;
    if (IsZeroVec(p) || !looksLikeWorldPos(p)) return; // never memoize a failed read
    s_aimBoneMemo.pawn = pawn;
    s_aimBoneMemo.pos = p;
    s_aimBoneMemo.posMode = posMode;
    s_aimBoneMemo.kind = kind;
    s_aimBoneMemo.frame = g_cacheFrameCounter;
}

static inline Vector3 ResolveSilentAimWorldPosOnce(uint64_t pawn, int posMode) {
    if (AimBoneMemoFrameHit(kAimBoneSilent, pawn, posMode)) return s_aimBoneMemo.pos;
    Vector3 p = ResolveSilentAimWorldPos(pawn, posMode);
    AimBoneMemoStore(kAimBoneSilent, pawn, posMode, p);
    return p;
}

static inline Vector3 GetAimTargetPosModeOnce(uint64_t pawn, int posMode, float distance) {
    if (AimBoneMemoFrameHit(kAimBonePosMode, pawn, posMode)) return s_aimBoneMemo.pos;
    Vector3 p = GetAimTargetPosMode(pawn, posMode, distance);
    AimBoneMemoStore(kAimBonePosMode, pawn, posMode, p);
    return p;
}

static inline int PlayerCacheSlot(uint64_t pawn) {
    // Stable per-pawn slot so cache state (visGoodFrames, isTrueVis, etc.) survives
    // dict walk order changes and pawns temporarily leaving the processed set.
    return PosTrackSlot(pawn);
}

// Per-frame ESP/aim snapshot: collect world data first, sample camera matrix LAST,
// then project. Fixes external-overlay "box sticks to cam then snaps" (matrix went
// stale while walking the player dict + reading bones).
struct EspPawnSnap {
    uint64_t pawn = 0;
    // Carried so the tally can dedup by identity without a second read per pawn
    // per frame. The count is decided in the draw pass, not in the world-read
    // pass, because that is where on-screen is known.
    uint64_t uid = 0;
    Vector3 head{};
    Vector3 hip{};
    Vector3 aimPos{};
    float dis = 0.f;
    int curHP = 0;
    int maxHP = 200;
    bool isBot = false;
    bool isKnocked = false;
    bool treatAsVehicle = false;
    bool canAim = false;
    bool wantDraw = false;
};

// Update velocity + optional display lead (remote hard-strafe catch-up).
// Also applies light world-space EMA so bone noise doesn't jitter the box every frame.
static inline Vector3 TrackAndExtrapolate(Vector3 raw, Vector3 &lastRaw, Vector3 &vel,
                                          CFTimeInterval &lastT, bool &has, float leadSec) {
    if (!looksLikeWorldPos(raw)) {
        has = false;
        return Vector3{0, 0, 0};
    }
    const CFTimeInterval now = CACurrentMediaTime();
    if (!has || lastT <= 0.0) {
        lastRaw = raw;
        vel = Vector3{0, 0, 0};
        lastT = now;
        has = true;
        return raw;
    }
    float dt = (float)(now - lastT);
    if (dt < 0.0005f) dt = 0.0005f;
    if (dt > 0.18f) {
        // Hitch / teleport — snap, no fake velocity.
        lastRaw = raw;
        vel = Vector3{0, 0, 0};
        lastT = now;
        return raw;
    }
    Vector3 inst = {
        (raw.x - lastRaw.x) / dt,
        (raw.y - lastRaw.y) / dt,
        (raw.z - lastRaw.z) / dt
    };
    float instSp = sqrtf(inst.x * inst.x + inst.z * inst.z);
    // Fast EMA so hard pull updates velocity in 1–2 frames.
    float a = 0.62f + fminf(instSp, 12.f) * 0.025f;
    if (a > 0.92f) a = 0.92f;
    vel.x = vel.x * (1.f - a) + inst.x * a;
    vel.z = vel.z * (1.f - a) + inst.z * a;
    vel.y = vel.y * (1.f - a) + inst.y * a;
    float sp = sqrtf(vel.x * vel.x + vel.z * vel.z);
    if (sp < 0.30f) { vel.x = 0.f; vel.z = 0.f; sp = 0.f; }
    if (sp > 15.f) {
        float inv = 15.f / sp;
        vel.x *= inv; vel.z *= inv; sp = 15.f;
    }
    // World-space EMA — stickier follow so box/line ride the body (not lag then snap).
    // Fast targets track almost raw; idle still damps bone micro-noise.
    float posA = 0.62f + fminf(sp, 10.f) * 0.032f;
    if (posA > 0.94f) posA = 0.94f;
    // Large jump = teleport / source switch — snap, don't lerp across the map.
    float jump = Vector3::Distance(raw, lastRaw);
    if (jump > 1.10f) posA = 1.0f;
    Vector3 smoothed = {
        lastRaw.x * (1.f - posA) + raw.x * posA,
        lastRaw.y * (1.f - posA) + raw.y * posA,
        lastRaw.z * (1.f - posA) + raw.z * posA
    };
    lastRaw = smoothed;
    lastT = now;
    has = true;

    // Tiny lead only on hard sprint — keeps stick without overshoot wobble.
    float lead = 0.f;
    if (sp > 2.4f && leadSec > 0.f) {
        lead = leadSec * fminf(sp / 10.f, 1.0f);
        if (lead > 0.055f) lead = 0.055f;
    }
    Vector3 out = smoothed;
    out.x += vel.x * lead;
    out.z += vel.z * lead;
    return out;
}

// Screen-space box lock (Lite + Pro): height/width/center must not pump every frame
// when ankle/hip W2S jitters. Snap only on big jumps (teleport / hard cam turn).
struct BoxScreenTrack {
    uint64_t pawn = 0;
    float h = 0.f;
    float w = 0.f;
    float cx = 0.f;
    float topY = 0.f;
    bool has = false;
};
static BoxScreenTrack g_boxScr[kPawnSlotCount];

static inline void SmoothBoxScreen(uint64_t pawn, float &topY, float &centerX,
                                   float &boxH, float &boxW) {
    // Screen space smoothing is off. It was producing three separate faults:
    //
    //   offset     the minimum follow factor is 0.55, so the box converges on the
    //              true position asymptotically and never reaches it. A moving
    //              player is drawn permanently behind where they are.
    //   wrong      the track table has kPawnSlotCount slots indexed by a pawn
    //              hash. Two different pawns collide, the t.pawn check resets on
    //              each collision, and the box alternates between the two
    //              players' remembered state, which reads as boxes jumping
    //              around.
    //   stale      the table is static and is never cleared on a match change,
    //              so a new pawn landing on a recycled address inherits the old
    //              one's size.
    //
    // The input is already smoothed. TrackAndExtrapolate applies a light
    // world space EMA for exactly this reason, so filtering again here was
    // smoothing twice and the second pass is what the player could see.
    (void)pawn; (void)topY; (void)centerX; (void)boxH; (void)boxW;
    return;

#if 0
    if (pawn == 0 || boxH < 1.f || boxW < 1.f) return;
    BoxScreenTrack &t = g_boxScr[pawn % kPawnSlotCount];
    if (t.pawn != pawn || !t.has) {
        t.pawn = pawn;
        t.h = boxH; t.w = boxW; t.cx = centerX; t.topY = topY;
        t.has = true;
        return;
    }
    // Relative change thresholds — size stays locked to body, position sticks hard.
    const float dh = fabsf(boxH - t.h) / fmaxf(t.h, 1.f);
    const float dw = fabsf(boxW - t.w) / fmaxf(t.w, 1.f);
    const float dc = fabsf(centerX - t.cx);
    const float dy = fabsf(topY - t.topY);
    // Size: very sticky (ankle swing used to pump 20–40% every step).
    float aH = (dh > 0.28f) ? 0.85f : ((dh > 0.12f) ? 0.42f : 0.18f);
    float aW = (dw > 0.28f) ? 0.85f : ((dw > 0.12f) ? 0.42f : 0.18f);
    // Position: stick to person — follow fast, but damp 1px noise.
    float aC = (dc > 28.f) ? 0.95f : ((dc > 10.f) ? 0.72f : 0.55f);
    float aY = (dy > 28.f) ? 0.95f : ((dy > 10.f) ? 0.72f : 0.55f);
    t.h = t.h * (1.f - aH) + boxH * aH;
    t.w = t.w * (1.f - aW) + boxW * aW;
    t.cx = t.cx * (1.f - aC) + centerX * aC;
    t.topY = t.topY * (1.f - aY) + topY * aY;
    boxH = t.h;
    boxW = t.w;
    centerX = t.cx;
    topY = t.topY;
#endif
}

static inline void ClearBoxScreenForPawn(uint64_t pawn) {
    if (pawn == 0) return;
    BoxScreenTrack &t = g_boxScr[pawn % kPawnSlotCount];
    if (t.pawn == pawn) t = BoxScreenTrack{};
}

// Pro (isESP fast) path uses the SAME g_boxScr smoother as the Lite path.
// Clears this pawn's entry when it dies/despawns so stale box size never
// bleeds to a new occupant of the same slot.
void ClearProBoxScreenForPawn(uint64_t pawn) {
    ClearBoxScreenForPawn(pawn);
}

// Pick stable source. Real players: network root XZ + head Y under hard move.
static inline Vector3 PickStableHeadRaw(uint64_t pawn, PosTrack &tr) {
    Vector3 head = getPositionExt(getHead(pawn));
    Vector3 hip  = getPositionExt(getHip(pawn));
    Vector3 root = ReadPlayerRootTransform(pawn);
    Vector3 mount{};
    const bool mounted = IsActivelyMounted(pawn, &mount);
    // Cache bot bit on track (bots = local sim, bones are truthful).
    if (!tr.hasHead || tr.pawn != pawn) {
        tr.isBot = get_IsBot(pawn);
    }
    const bool remoteHuman = !tr.isBot;

    auto validHeadNear = [&](const Vector3 &h, const Vector3 &anchor, float maxD) -> bool {
        if (!looksLikeWorldPos(h) || !looksLikeWorldPos(anchor)) return false;
        float dx = h.x - anchor.x, dy = h.y - anchor.y, dz = h.z - anchor.z;
        float d2 = dx*dx + dy*dy + dz*dz;
        return d2 < maxD * maxD && h.y >= anchor.y - 0.85f;
    };

    int preferred = 0;
    Vector3 raw{};

    // Vehicle/zipline first: skinned head/hip often zero or collapsed while seated.
    // Prefer live mount/root so ESP keeps drawing passengers.
    if (mounted && looksLikeWorldPos(mount)) {
        bool bonesDead = !looksLikeWorldPos(head) && !looksLikeWorldPos(hip);
        bool collapsed = false;
        if (looksLikeWorldPos(head) && looksLikeWorldPos(hip)) {
            float bd = Vector3::Distance(head, hip);
            collapsed = (bd < 0.20f);
        }
        if (bonesDead || collapsed || !looksLikeWorldPos(root)) {
            preferred = 4;
            raw = mount; // already seat-height biased in IsActivelyMounted
        }
    }

    // --- Real players: root is network authority; skinned head lags hard strafe ---
    if (preferred == 0 && remoteHuman && looksLikeWorldPos(root)) {
        float headLagXZ = 0.f;
        if (looksLikeWorldPos(head)) {
            float dx = head.x - root.x, dz = head.z - root.z;
            headLagXZ = sqrtf(dx * dx + dz * dz);
        }
        // Soft move: head still near root → use live head (snappy).
        // Hard pull: head trails root → root XZ + head/root Y (pro-ESP style).
        if (looksLikeWorldPos(head) && headLagXZ < 0.85f && validHeadNear(head, root, mounted ? 5.5f : 4.0f)) {
            preferred = 1;
            raw = head;
        } else if (looksLikeWorldPos(head) && headLagXZ < 2.8f) {
            // Hybrid: network XZ, bone height (box top still correct).
            preferred = 5;
            raw.x = root.x;
            raw.z = root.z;
            raw.y = head.y;
            if (raw.y < root.y + 0.2f) raw.y = root.y + (mounted ? 1.05f : 0.85f);
        } else {
            preferred = 3;
            raw = root;
            raw.y += mounted ? 1.05f : 0.85f;
        }
    } else if (preferred == 0) {
        // Bots / no root: prefer skinned head (local simulation, zero net lag).
        if (looksLikeWorldPos(head)) {
            Vector3 anchor = looksLikeWorldPos(hip) ? hip : root;
            float maxD = mounted ? 5.5f : 4.0f;
            if (!looksLikeWorldPos(anchor) || validHeadNear(head, anchor, maxD)) {
                preferred = 1;
                raw = head;
            }
        }
        if (preferred == 0 && looksLikeWorldPos(hip)) {
            preferred = 2;
            raw = hip;
            raw.y += 0.55f;
        }
        if (preferred == 0 && looksLikeWorldPos(root)) {
            preferred = 3;
            raw = root;
            raw.y += mounted ? 1.05f : 0.85f;
        }
    }
    if (preferred == 0 && mounted && looksLikeWorldPos(mount)) {
        preferred = 4;
        raw = mount;
    }
    if (preferred == 0) return Vector3{0, 0, 0};

    // Sticky source (2 frames) — avoid root↔head flicker on soft moves.
    if (tr.pawn == pawn && tr.headSrc != 0 && tr.headSrcHold > 0) {
        Vector3 keep{};
        bool ok = false;
        if (tr.headSrc == 1 && looksLikeWorldPos(head)) {
            Vector3 anchor = looksLikeWorldPos(root) ? root : hip;
            if (!looksLikeWorldPos(anchor) || validHeadNear(head, anchor, 5.5f)) {
                keep = head; ok = true;
            }
        } else if (tr.headSrc == 5 && looksLikeWorldPos(root)) {
            keep = root;
            keep.y = looksLikeWorldPos(head) ? head.y : (root.y + 0.85f);
            ok = true;
        } else if (tr.headSrc == 2 && looksLikeWorldPos(hip)) {
            keep = hip; keep.y += 0.55f; ok = true;
        } else if (tr.headSrc == 3 && looksLikeWorldPos(root)) {
            keep = root; keep.y += mounted ? 1.05f : 0.85f; ok = true;
        } else if (tr.headSrc == 4 && mounted && looksLikeWorldPos(mount)) {
            keep = mount; ok = true;
        }
        // Force switch to hybrid/root when hard lag detected (head far from root).
        bool forceRoot = false;
        if (remoteHuman && looksLikeWorldPos(root) && looksLikeWorldPos(head)) {
            float dx = head.x - root.x, dz = head.z - root.z;
            if (dx*dx + dz*dz > 1.2f * 1.2f && (preferred == 3 || preferred == 5))
                forceRoot = true;
        }
        if (ok && !forceRoot && !(preferred == 5 && tr.headSrc == 1 && remoteHuman)) {
            // Allow upgrade to hybrid/root when remote hard-moves.
            if (!(remoteHuman && (preferred == 5 || preferred == 3) && tr.headSrc == 1)) {
                tr.headSrcHold--;
                raw = keep;
                preferred = tr.headSrc;
            } else {
                tr.headSrc = preferred;
                tr.headSrcHold = 2;
            }
        } else {
            tr.headSrc = preferred;
            tr.headSrcHold = 2;
        }
    } else {
        tr.headSrc = preferred;
        tr.headSrcHold = 2;
    }
    return raw;
}

static inline Vector3 PickStableHipRaw(uint64_t pawn, PosTrack &tr) {
    Vector3 hip  = getPositionExt(getHip(pawn));
    Vector3 root = ReadPlayerRootTransform(pawn);
    Vector3 head = getPositionExt(getHead(pawn));
    Vector3 mount{};
    const bool mounted = IsActivelyMounted(pawn, &mount);
    if (!tr.hasHip || tr.pawn != pawn) {
        tr.isBot = get_IsBot(pawn);
    }
    const bool remoteHuman = !tr.isBot;

    int preferred = 0;
    Vector3 raw{};
    // Vehicle/zipline: bones often dead — seat/mount first.
    if (mounted && looksLikeWorldPos(mount)) {
        bool bonesDead = !looksLikeWorldPos(hip) && !looksLikeWorldPos(head);
        bool collapsed = looksLikeWorldPos(hip) && looksLikeWorldPos(head) &&
                         Vector3::Distance(hip, head) < 0.20f;
        if (bonesDead || collapsed || !looksLikeWorldPos(root)) {
            preferred = 4;
            raw = mount;
            raw.y -= 0.35f; // hip-ish under seat head
        }
    }
    // Real players: root XZ for hip/feet base under hard strafe.
    if (preferred == 0 && remoteHuman && looksLikeWorldPos(root)) {
        if (looksLikeWorldPos(hip)) {
            float dx = hip.x - root.x, dz = hip.z - root.z;
            float lag = sqrtf(dx*dx + dz*dz);
            if (lag < 0.90f) {
                preferred = 2; raw = hip;
            } else {
                preferred = 3;
                raw = root;
                // Keep hip height if sane.
                raw.y = (lag < 2.5f) ? hip.y : root.y;
            }
        } else {
            preferred = 3; raw = root;
        }
    } else if (preferred == 0) {
        if (looksLikeWorldPos(hip)) { preferred = 2; raw = hip; }
        else if (looksLikeWorldPos(root)) { preferred = 3; raw = root; }
        else if (looksLikeWorldPos(head)) { preferred = 1; raw = head; raw.y -= 0.55f; }
        else if (mounted && looksLikeWorldPos(mount)) { preferred = 4; raw = mount; raw.y -= 0.35f; }
    }
    if (preferred == 0 && mounted && looksLikeWorldPos(mount)) {
        preferred = 4; raw = mount; raw.y -= 0.35f;
    }
    if (preferred == 0) return Vector3{0, 0, 0};

    if (tr.pawn == pawn && tr.hipSrc != 0 && tr.hipSrcHold > 0) {
        Vector3 keep{};
        bool ok = false;
        if (tr.hipSrc == 2 && looksLikeWorldPos(hip)) { keep = hip; ok = true; }
        else if (tr.hipSrc == 3 && looksLikeWorldPos(root)) { keep = root; ok = true; }
        else if (tr.hipSrc == 1 && looksLikeWorldPos(head)) { keep = head; keep.y -= 0.55f; ok = true; }
        else if (tr.hipSrc == 4 && mounted && looksLikeWorldPos(mount)) { keep = mount; keep.y -= 0.35f; ok = true; }
        bool forceRoot = false;
        if (remoteHuman && looksLikeWorldPos(root) && looksLikeWorldPos(hip)) {
            float dx = hip.x - root.x, dz = hip.z - root.z;
            if (dx*dx + dz*dz > 1.2f * 1.2f && preferred == 3) forceRoot = true;
        }
        if (ok && !forceRoot) {
            if (!(remoteHuman && preferred == 3 && tr.hipSrc == 2)) {
                tr.hipSrcHold--;
                raw = keep;
                preferred = tr.hipSrc;
            } else {
                tr.hipSrc = preferred;
                tr.hipSrcHold = 2;
            }
        } else {
            tr.hipSrc = preferred;
            tr.hipSrcHold = 2;
        }
    } else {
        tr.hipSrc = preferred;
        tr.hipSrcHold = 2;
    }
    return raw;
}

// Live + mild EMA/lead for remote hard-strafe. Bots: light smooth, no lead.
// Used for ESP display (and aim when tracked path is allowed).
static inline Vector3 ResolveHeadWorldPosTracked(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return Vector3{0, 0, 0};
    PosTrack &tr = g_posTrack[PosTrackSlot(pawn)];
    // Respect exact-pawn death tombstone: never revive a dead shell via tracked path.
    if (tr.pawn == pawn && tr.deadUntilFrame > 0 && g_cacheFrameCounter < tr.deadUntilFrame) {
        return Vector3{0, 0, 0};
    }
    if (tr.pawn != pawn) {
        tr = PosTrack{};
        tr.pawn = pawn;
        tr.isBot = get_IsBot(pawn);
    }
    Vector3 raw = PickStableHeadRaw(pawn, tr);
    if (!looksLikeWorldPos(raw)) {
        tr.hasHead = false;
        tr.headSrc = 0;
        tr.headSrcHold = 0;
        return Vector3{0, 0, 0};
    }
    // Bots: smooth only. Real players: short lead so box rides hard strafe.
    float lead = tr.isBot ? 0.f : 0.055f;
    Vector3 out = TrackAndExtrapolate(raw, tr.lastHeadRaw, tr.headVel, tr.lastHeadT, tr.hasHead, lead);
    tr.headSmoothed = out;
    tr.frame = g_cacheFrameCounter;
    return out;
}

static inline Vector3 ResolveHipWorldPosTracked(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return Vector3{0, 0, 0};
    PosTrack &tr = g_posTrack[PosTrackSlot(pawn)];
    // Respect exact-pawn death tombstone: never revive a dead shell via tracked path.
    if (tr.pawn == pawn && tr.deadUntilFrame > 0 && g_cacheFrameCounter < tr.deadUntilFrame) {
        return Vector3{0, 0, 0};
    }
    if (tr.pawn != pawn) {
        tr = PosTrack{};
        tr.pawn = pawn;
        tr.isBot = get_IsBot(pawn);
    }
    Vector3 raw = PickStableHipRaw(pawn, tr);
    if (!looksLikeWorldPos(raw)) {
        tr.hasHip = false;
        tr.hipSrc = 0;
        tr.hipSrcHold = 0;
        return Vector3{0, 0, 0};
    }
    float lead = tr.isBot ? 0.f : 0.055f;
    Vector3 out = TrackAndExtrapolate(raw, tr.lastHipRaw, tr.hipVel, tr.lastHipT, tr.hasHip, lead);
    tr.hipSmoothed = out;
    tr.frame = g_cacheFrameCounter;
    return out;
}

// Smooth a *validated* live position for ESP draw only.
// Does NOT invent ghosts: caller must already prove live bones/root/mount exist.
// Keeps box/line from micro-jittering while still snapping on teleport.
// Extra guard: if this pawn is tombstoned dead (exact match), refuse to smooth — drop.
static inline Vector3 EspSmoothDisplayPos(uint64_t pawn, Vector3 raw, bool isHead) {
    if (!looksLikeWorldPos(raw) || !isVaildPtr(pawn)) return raw;
    PosTrack &tr = g_posTrack[PosTrackSlot(pawn)];
    // Exact-pawn tombstone: if dead hold is active for THIS pawn, do not smooth or emit.
    if (tr.pawn == pawn && tr.deadUntilFrame > 0 && g_cacheFrameCounter < tr.deadUntilFrame) {
        return Vector3{0,0,0};
    }
    if (tr.pawn != pawn) {
        tr = PosTrack{};
        tr.pawn = pawn;
        tr.isBot = get_IsBot(pawn);
    }
    float lead = tr.isBot ? 0.f : 0.050f;
    if (isHead) {
        Vector3 out = TrackAndExtrapolate(raw, tr.lastHeadRaw, tr.headVel, tr.lastHeadT, tr.hasHead, lead);
        tr.headSmoothed = out;
        tr.frame = g_cacheFrameCounter;
        return out;
    }
    Vector3 out = TrackAndExtrapolate(raw, tr.lastHipRaw, tr.hipVel, tr.lastHipT, tr.hasHip, lead);
    tr.hipSmoothed = out;
    tr.frame = g_cacheFrameCounter;
    return out;
}
// ==============================================================

static void TipaEspTrace(int tag, NSString *fmt, ...) { (void)tag; (void)fmt; }

static inline float Clamp01f(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

static std::vector<mach_vm_address_t> g_patchedAddresses;

extern "C" void ToggleSpeedX50(bool enable) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        pid_t pid = (pid_t)GameTargetProcessPid();
        if (pid <= 0) return;

        task_t target_task = 0;
        if (task_for_pid(mach_task_self(), pid, &target_task) != KERN_SUCCESS) {
            NSLog(@"[HTH Cheat] LỖI: Không lấy được quyền task_for_pid!");
            return;
        }

        uint64_t originalVal = 4397530849764387586ULL; 
        uint64_t hackedVal   = 4397530849740000000ULL; 

        if (enable) {
            g_patchedAddresses.clear(); 
            mach_vm_address_t address = 0x100000000;
            mach_vm_size_t size = 0;
            vm_region_basic_info_data_64_t info;
            mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
            mach_port_t object_name;
            
            while (mach_vm_region(target_task, &address, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object_name) == KERN_SUCCESS) {
                if (address > 0x160000000) break; 
                if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE)) {
                    uint8_t *buffer = (uint8_t *)malloc(size);
                    mach_vm_size_t bytesRead = 0;
                    if (mach_vm_read_overwrite(target_task, address, size, (mach_vm_address_t)buffer, &bytesRead) == KERN_SUCCESS) {
                        for (size_t i = 0; i <= bytesRead - 8; i += 4) {
                            uint64_t currentValue = *(uint64_t *)(buffer + i);
                            if (currentValue == originalVal) {
                                mach_vm_address_t exactWriteAddress = address + i;
                                mach_vm_write(target_task, exactWriteAddress, (vm_offset_t)&hackedVal, sizeof(hackedVal));
                                g_patchedAddresses.push_back(exactWriteAddress);
                            }
                        }
                    }
                    free(buffer);
                }
                address += size;
            }
        } else {
            if (g_patchedAddresses.empty()) return;
            for (mach_vm_address_t savedAddr : g_patchedAddresses) {
                mach_vm_write(target_task, savedAddr, (vm_offset_t)&originalVal, sizeof(originalVal));
            }
            g_patchedAddresses.clear();
        }
    });
}

// A quaternion is four floats. Its first eight bytes are two components, and a
// normalised one has both inside [-1, 1], so the pair reads as a 64-bit value
// that is either zero or a denormal-looking float pattern.
//
// A pointer never looks like that. Anything at or above 0x100000000 at the target
// is therefore not a rotation field, it is a pointer the game owns, and writing
// sixteen bytes of float over it is what FreeFire-2026-10-03-082640.ips is:
//
//   EXC_BAD_ACCESS, KERN_INVALID_ADDRESS at 0x3a3a69ed00000000
//   -> 0x0000006d00000000 (possible pointer authentication failure)
//
// 0x3a3a69ed00000000 is two floats: 0.0f and 0.00059f. Stripping the PAC leaves
// 0x6d00000000, which lands in the GPU carveout — reserved, unallocated address
// space — and the game faults on it when it uses that field at teardown. The
// address is the fingerprint of this write, not a mystery: it is a normalised
// quaternion's first two components, read as a pointer.
//
// The crash was on the main thread inside UnityFramework with no ESP frames,
// because the corrupted field is read by the game long after the write.
//
// There is deliberately NO runtime guard here that refuses to write when the
// target "looks like a pointer". One was tried and it killed the aimbot, because
// the test cannot work on this data: the eight bytes of a quaternion are two
// float32s, and the second one sits in the HIGH half of the 64-bit word, so any
// quaternion with a non-zero second component reads as something enormous. A
// guard of the form "value >= 0x100000000 means pointer" therefore rejects
// essentially every rotation, which is exactly what it did — aim stopped dead
// while the game stopped crashing, and the crash was already fixed by dropping
// the stale offsets.
//
// The fix is the offsets, not a heuristic in front of them.

// The game's look axis, cached per pawn.
//
// The rotation fields are not the whole mechanism. The game samples the look
// stick, and the stick's CurrentAimWriter keeps writing Player.m_CurrentAimRotation
// from it. A quaternion written into the rotation fields without the stick moving
// with it gets stomped on the next sample — which is what "the aim does nothing"
// looks like from here: the field reads back as ours for a frame and then the
// camera does not move.
//
// Axis type 1 is Right, which is the look axis; the handler holds an array of
// them and the look one is found by type rather than by index.
static uint64_t resolve_look_axis(uint64_t handler) {
    uint64_t arr = ReadAddr<uint64_t>(handler + kUCHandlerAxisData); // 0x68
    if (!isVaildPtr(arr)) return 0;
    int32_t len = ReadAddr<int32_t>(arr + kIl2CppArrayMaxLength);
    if (len < 1 || len > 32) return 0;
    for (int32_t i = 0; i < len; i++) {
        uint64_t el = ReadAddr<uint64_t>(arr + kIl2CppArrayItems + (uint64_t)i * 8ull);
        if (!isVaildPtr(el)) continue;
        if (ReadAddr<int32_t>(el + kAxisType) == 1) return el;   // Right
    }
    return 0;
}

static uint64_t look_axis_for(uint64_t player) {
    static uint64_t s_owner = 0;
    static uint64_t s_axis  = 0;
    static int s_reported = 0;
    if (s_owner != player) {          // pawn change invalidates the cache
        s_owner = player;
        s_axis  = 0;
        s_reported = 0;
    }
    if (isVaildPtr(s_axis)) return s_axis;
    uint64_t handler = ReadAddr<uint64_t>(player + kUserControlHandler);
    if (!isVaildPtr(handler)) return 0;
    s_axis = resolve_look_axis(handler);
    if (!s_reported) {
        s_reported = 1;
        if (isVaildPtr(s_axis)) {
            int32_t type = ReadAddr<int32_t>(s_axis + kAxisType);
            Vector3 p = ReadAddr<Vector3>(s_axis + kAxisCurrentScreenPos);
            NSLog(@"[MD-AIM] look axis OK  handler=%p axis=%p type=%d screenPos=(%.1f, %.1f)",
                  (void *)handler, (void *)s_axis, (int)type, p.x, p.y);
        } else {
            NSLog(@"[MD-AIM] look axis NOT FOUND (handler=%p) — rotation is moving without input",
                  (void *)handler);
        }
    }
    return s_axis;
}

// Move the stick to the place the rotation says it should be at, in the screen
// units the game samples.
//
// The stick is fed FIRST and the rotation second, because the rotation is what
// the report correlates against the sample stream: a rotation that moves without
// a matching stick sample is the aimbot signature, not just a visual glitch.
//
// Deliberately NOT touched: m_IsTouched (axis + 0x4B) / m_IsActuallyMoved
// (axis + 0x4C) and m_IsUserControlChanged (handler + 0x78). Forcing those on
// would make the game believe the stick is held — floating stick, auto fire.
// The position alone is what gets sampled.
static bool drive_look_axis_input(uint64_t player, const Quaternion &prev, const Quaternion &next) {
    if (!isVaildPtr(player)) return false;
    if (Moudule_Base == 0 || Moudule_Base == (uint64_t)-1) return false;

    uint64_t handler = ReadAddr<uint64_t>(player + kUserControlHandler);
    if (!isVaildPtr(handler)) return false;
    uint64_t axis = look_axis_for(player);
    if (!isVaildPtr(axis)) return false;

    Vector3 e0 = Quaternion::ToEuler(prev);
    Vector3 e1 = Quaternion::ToEuler(next);
    float dYaw = e1.y - e0.y;
    if (dYaw > 180.f) dYaw -= 360.f;
    if (dYaw < -180.f) dYaw += 360.f;
    float dPitch = e1.x - e0.x;
    if (dPitch > 180.f) dPitch -= 360.f;
    if (dPitch < -180.f) dPitch += 360.f;
    if (fabsf(dYaw) < 0.0001f && fabsf(dPitch) < 0.0001f) return false;

    CGSize scr = [UIScreen mainScreen].bounds.size;
    float sw = (float)scr.width, sh = (float)scr.height;
    if (sw < 1.f || sh < 1.f) { sw = 1080.f; sh = 2340.f; }

    // px-per-degree, from the drag area, calibrated once via the AimPxPerDeg
    // pref. A flat constant cannot track sensitivity or zoom.
    float pxPerDeg = ESPPrefsFloat(@"AimPxPerDeg", 0.f);
    if (!(pxPerDeg > 0.01f) || pxPerDeg > 64.f)
        pxPerDeg = (sw * 0.22f) * 0.0085f;   // ~2.0 px/deg at 1080 pt width

    Vector3 cur   = ReadAddr<Vector3>(axis + kAxisCurrentScreenPos);
    Vector3 start = ReadAddr<Vector3>(axis + kAxisStartScreenPos);
    if (isnan(cur.x) || isnan(cur.y) || isnan(cur.z)) return false;
    if (isnan(start.x) || isnan(start.y) || isnan(start.z)) start = cur;

    Vector3 to = cur;
    to.x = cur.x + dYaw * pxPerDeg;
    to.y = cur.y - dPitch * pxPerDeg;
    if (to.x < sw * 0.50f) to.x = sw * 0.50f;      // keep it in the right drag area
    if (to.x > sw * 0.98f) to.x = sw * 0.98f;
    if (to.y < sh * 0.05f) to.y = sh * 0.05f;
    if (to.y > sh * 0.95f) to.y = sh * 0.95f;

    Vector3 step(to.x - cur.x, to.y - cur.y, 0.f);
    Vector3 delta(to.x - start.x, to.y - start.y, 0.f);
    float moved = sqrtf(step.x * step.x + step.y * step.y);

    WriteAddr<Vector3>(axis + kAxisCurrentScreenPos, to);
    WriteAddr<Vector3>(axis + kAxisDeltaPos, delta);
    WriteAddr<Vector3>(axis + kAxisCurrentDeltaValue, step);
    WriteAddr<Vector3>(axis + kAxisLastDirection, step);
    WriteAddr<float>(axis + kAxisActuallyMovedDistance, moved);
    return true;
}

// The game samples the look stick every GameVarDef.AimInputSampleIntervalTick
// ticks, and the report pairs one sample with one CallSetAimRotationCount bump.
// Rotation has to move at the same cadence as the sample stream or the mismatch
// is the aimbot signal. Read from the server config rather than hardcoded.
static CFTimeInterval aim_sample_interval(void) {
    static CFTimeInterval s_gap = 0.0;
    static CFTimeInterval s_checkedAt = 0.0;
    const CFTimeInterval now = CACurrentMediaTime();
    if (s_gap > 0.0 && (now - s_checkedAt) < 2.0) return s_gap;

    s_checkedAt = now;
    s_gap = 0.0;
    if (Moudule_Base == 0 || Moudule_Base == (uint64_t)-1) return 0.0;
    uint64_t typeInfo = ReadAddr<uint64_t>(Moudule_Base + kGameVarDefTypeInfo);
    if (!isVaildPtr(typeInfo)) return 0.0;
    uint64_t gvd = ReadAddr<uint64_t>(typeInfo + kTypeInfoStatics);
    if (!isVaildPtr(gvd)) return 0.0;

    int32_t intervalTick = ReadAddr<int32_t>(gvd + kGvdAimInputSampleIntervalTick);
    // 0 = pipeline disabled or an unexpected value: leave pacing to the game.
    if (intervalTick < 1 || intervalTick > 8) return 0.0;
    s_gap = (double)intervalTick / 60.0;   // ticks are 60 Hz
    return s_gap;
}

// Counters for [AIM-WRITE], so "the aim does nothing" has a number in it instead
// of a guess. calls / wrote / stuck (the stick axis could not be resolved or fed)
// / starved (the write was skipped) / lastGap / lastAng.
static uint32_t g_awCalls = 0, g_awWrote = 0, g_awStuck = 0, g_awStarved = 0;
static float    g_awGap = 0.f, g_awAng = 0.f;
static CFTimeInterval g_awLastLog = 0;

// The rotation write is unconditional, and that is the one thing here that is
// known from the device rather than from the reference.
//
// c60f3856b wrote kAimRotation / kAimRotationAux / kCurrentAimRotation on every
// call with no gate at all, and the camera turned. 207b54703 ported the
// reference's two gates in front of it —
//
//   if (ang < 0.4 && angCur < 0.4) return;      // already there
//   if (now - lastBump < sampleInterval) return; // too soon
//
// — and the camera stopped turning. The two of them close on each other: the
// first write puts the game's fields at our value, so the next call measures a
// zero angle and returns, and because the stick was fed the game's own writer
// keeps 0x1A8C near our value too, so the second condition holds as well. The
// lock thread then hammers this every 4ms and none of it reaches the game.
//
// The reference has the same gates and works, because its rotation comes from a
// different cadence. Porting a gate is not porting a mechanism: the gate is only
// safe when something else re-reads the target, and here the only thing that
// does is the thing being gated.
//
// So: the rotation goes in every call, exactly as it did at c60f3856b. The stick
// feed and the counter bump stay, because those are what make the input stream
// match the rotation, and they carry their own pacing. What is gone from the
// rotation path are only the three legacy offsets, which is the crash.
// ---- GameVarDef aim gates, kept in the state the camera path needs ----
//
// Two flags decide whether a rotation we write ever reaches the view, and both
// were sitting in GameOffsets.h with the explanation and no code using them:
//
//   EnableInternalSetRotation (statics+0xE4) — CurrentAimWriter reads it and,
//     when it is not 1, overwrites 0x614 from the look stick. Our rotation is
//     then discarded on the next sample.
//   RotationPlan (statics+0x380C) — HFIKAJMBGJG applies Player.m_CurrentAimRotation
//     (0x1A8C, what we write) to the camera only when the plan is 1. Plans 0 and 2
//     skip it or source it from a Lerp, and the aim never reaches the view.
//
// That is exactly the reported shape: the target is picked, the rotation fields
// hold our value, and the camera does not move.
//
// What is deliberately NOT touched, because it is the ban vector rather than a
// feature flag:
//
//   EnableCheckBuf (statics+0x458C) — forcing it 0 makes the server see a missing
//     report 0xF0, which is a ban, not a suppression. Report 0xF0/0xF1 flow.
//   EnableAimInputSample / the sample counters — never forged. The look stick is
//     moved for real by drive_look_axis_input, so SampleAimInput records a real
//     position and FillAimInputSamples never has to emit the -1.0f that marks a
//     missing sample.
static bool     g_gvdPatched = false;
static uint8_t  g_gvdSavedIntRot = 0;
static int32_t  g_gvdSavedRotationPlan = 0;

static uint64_t ResolveGameVarDefStatics(void) {
    if (Moudule_Base == 0 || Moudule_Base == (uint64_t)-1) return 0;
    uint64_t typeInfo = ReadAddr<uint64_t>(Moudule_Base + kGameVarDefTypeInfo);
    if (!isVaildPtr(typeInfo)) return 0;
    uint64_t statics = ReadAddr<uint64_t>(typeInfo + kTypeInfoStatics);
    if (!isVaildPtr(statics)) {
        const uint64_t offs[] = {0xB8, 0xB0, 0xC0, 0xA8};
        for (size_t i = 0; i < 4 && !isVaildPtr(statics); i++) {
            statics = ReadAddr<uint64_t>(typeInfo + offs[i]);
        }
    }
    return isVaildPtr(statics) ? statics : 0;
}

static void PatchAimDetectionFlags(bool enable) {
    // Read-compare-write, so this costs nothing once the flags are already right.
    if (Moudule_Base == 0 || Moudule_Base == (uint64_t)-1) return;

    uint64_t statics = ResolveGameVarDefStatics();
    if (!isVaildPtr(statics)) return;

    if (enable) {
        if (!g_gvdPatched) {
            g_gvdSavedIntRot = ReadAddr<uint8_t>(statics + kGvdEnableInternalSetRotation);
            g_gvdSavedRotationPlan = ReadAddr<int32_t>(statics + kGvdRotationPlan);
            g_gvdPatched = true;
        }
        if (ReadAddr<uint8_t>(statics + kGvdEnableInternalSetRotation) != 1)
            WriteAddr<uint8_t>(statics + kGvdEnableInternalSetRotation, 1);
        if (ReadAddr<int32_t>(statics + kGvdRotationPlan) != 1)
            WriteAddr<int32_t>(statics + kGvdRotationPlan, 1);
        return;
    }

    if (!g_gvdPatched) return;
    uint8_t ir = ReadAddr<uint8_t>(statics + kGvdEnableInternalSetRotation);
    if (ir != g_gvdSavedIntRot)
        WriteAddr<uint8_t>(statics + kGvdEnableInternalSetRotation, g_gvdSavedIntRot);
    int32_t rp = ReadAddr<int32_t>(statics + kGvdRotationPlan);
    if (rp != g_gvdSavedRotationPlan)
        WriteAddr<int32_t>(statics + kGvdRotationPlan, g_gvdSavedRotationPlan);
    g_gvdPatched = false;
}

static void write_aim_rotations(uint64_t player, const Quaternion &out) {
    if (!isVaildPtr(player)) return;
    g_awCalls++;

    // Rotation FIRST and unconditional: this is the write the camera follows.
    WriteAddr<Quaternion>(player + kAimRotation, out);        // 0x614
    WriteAddr<Quaternion>(player + kAimRotationAux, out);     // 0x628 ResetAux copy
    WriteAddr<Quaternion>(player + kCurrentAimRotation, out); // 0x1A8C camera source
    g_awWrote++;

    // Input second, paced to the server's sample interval so the stick moves at
    // the rate the report expects a sample stream to move at. Pacing lives here
    // and not in front of the rotation: the stick is what the game reads to
    // produce the rotation, so skipping it is what makes the camera lag.
    const CFTimeInterval now = CACurrentMediaTime();
    const CFTimeInterval minGap = aim_sample_interval();   // 0 = no pacing
    static uint64_t s_lastPlayer = 0;
    static CFTimeInterval s_lastFeed = 0.0;
    if (player != s_lastPlayer) {
        s_lastPlayer = player;
        s_lastFeed = 0.0;
    }
    if (minGap > 0.0 && s_lastFeed != 0.0 && (now - s_lastFeed) < minGap) {
        g_awStarved++;
    } else {
        Quaternion prev = ReadAddr<Quaternion>(player + kAimRotation);
        g_awAng = Quaternion::Angle(prev, out);
        if (isnan(g_awAng)) g_awAng = 0.f;
        const bool fed = drive_look_axis_input(player, prev, out);
        s_lastFeed = now;
        g_awGap = (float)minGap;
        if (fed) {
            // Counter++ is what the report correlates against the sample list.
            // Only when the stick actually moved: "counter advanced, no input" is
            // the exact pattern it looks for.
            uint32_t n = ReadAddr<uint32_t>(player + kCallSetAimRotationCount);
            WriteAddr<uint32_t>(player + kCallSetAimRotationCount, n + 1u);
        } else {
            g_awStuck++;
        }
    }

    if (now - g_awLastLog >= 1.0) {
        g_awLastLog = now;
        NSLog(@"[AIM-WRITE] calls=%u wrote=%u stuck=%u starved=%u gap=%.3f ang=%.2f "
              @"axis=%d tick=%u",
              g_awCalls, g_awWrote, g_awStuck, g_awStarved, (double)g_awGap, (double)g_awAng,
              isVaildPtr(look_axis_for(player)) ? 1 : 0,
              (unsigned)(minGap * 60.0));
        g_awCalls = g_awWrote = g_awStuck = g_awStarved = 0;
    }
    // kCheckBufPending (Player+0x624) is NOT ours to set: MarkGGPVerifyCheckBufPending
    // owns it and is driven by the weapon fire path. Writing it from aim was both
    // a constant-true bug and a machine-perfect rhythm signature.
}

void set_aim(uint64_t player, Quaternion rotation, float speed, int mode, bool forceInstant) {
    if (!isVaildPtr(player)) return;
    Quaternion q = Quaternion::Normalized(rotation);
    if (isnan(q.x) || isnan(q.y) || isnan(q.z) || isnan(q.w)) return;

    // Moving targets need hard writes more often — soft blend is what makes aim feel "tạm tạm".
    const bool hardLock = forceInstant || mode >= 1 || speed >= 0.75f;
    if (hardLock) {
        write_aim_rotations(player, q);
        return;
    }

    Quaternion current = ReadAddr<Quaternion>(player + kAimRotation);
    float n = current.x * current.x + current.y * current.y + current.z * current.z + current.w * current.w;
    if (!(n > 0.0001f) || isnan(n)) {
        write_aim_rotations(player, q);
        return;
    }
    current = Quaternion::Normalized(current);
    float angle = Quaternion::Angle(current, q);
    if (isnan(angle) || angle < 0.0005f) {
        write_aim_rotations(player, q);
        return;
    }

    // Safe mode only: still snappy enough for strafe.
    float s = Clamp01f(speed);
    float base = 0.55f + 0.45f * s;
    if (angle > 0.08f) base = fmaxf(base, 0.90f);
    float t = fminf(1.0f, base);
    Quaternion out = Quaternion::Normalized(Quaternion::Slerp(current, q, t));
    if (isnan(out.x) || isnan(out.y) || isnan(out.z) || isnan(out.w)) return;
    write_aim_rotations(player, out);
}

static float g_aaSavedKnol = 0.f;
static float g_aaSavedNfk  = 0.f;
static bool  g_aaLegitBoostActive = false;

void update_aim_assist_legit_tuning(bool enable) {
    if (enable == g_aaLegitBoostActive) return;
    if (Moudule_Base == (uint64_t)-1 || Moudule_Base == 0 || !isVaildPtr(Moudule_Base)) {
        g_aaLegitBoostActive = false;
        return;
    }
    uint64_t typeInfo = ReadAddr<uint64_t>(Moudule_Base + kAimAssistTypeInfo);
    if (!isVaildPtr(typeInfo)) return;
    uint64_t statics = ReadAddr<uint64_t>(typeInfo + kTypeInfoStatics);
    if (!isVaildPtr(statics)) return;

    if (!enable) {
        // Only restore if we previously applied a boost (avoid writing 0,0 cold).
        if (g_aaLegitBoostActive) {
            WriteAddr<float>(statics + kAaStaticKnolgmjlcef, g_aaSavedKnol);
            WriteAddr<float>(statics + kAaStaticNfkcllpalej, g_aaSavedNfk);
            g_aaLegitBoostActive = false;
        }
        return;
    }

    g_aaSavedKnol = ReadAddr<float>(statics + kAaStaticKnolgmjlcef);
    g_aaSavedNfk  = ReadAddr<float>(statics + kAaStaticNfkcllpalej);
    WriteAddr<float>(statics + kAaStaticKnolgmjlcef, g_aaSavedKnol * 0.88f);
    WriteAddr<float>(statics + kAaStaticNfkcllpalej, g_aaSavedNfk * 1.18f);
    g_aaLegitBoostActive = true;
}

static float esp_aim_delta_time(void) {
    static CFTimeInterval s_last = 0.0;
    const CFTimeInterval now = CACurrentMediaTime();
    float dt = (s_last > 0.0) ? (float)(now - s_last) : (1.f / 60.f);
    s_last = now;
    if (dt <= 0.f || dt > 0.25f) dt = 1.f / 60.f;
    return dt;
}

static float legit_aim_blend_t(float angleRad, float speed01, float targetDistance, float maxAimDistance) {
    const float dt = esp_aim_delta_time();
    const float dtScale = fminf(fmaxf(dt * 60.f, 0.5f), 2.f);

    const float refAngle = 40.f * 3.14159265f / 180.f;
    const float angleNorm = fminf(angleRad / refAngle, 1.f);
    const float angleEase = 0.28f + 0.72f * (1.f - powf(angleNorm, 1.25f));
    const float speedCurve = 0.035f + 0.32f * powf(speed01, 1.2f);

    const float distNorm = Clamp01f(targetDistance / fmaxf(maxAimDistance, 1.f));
    const float distBias = 0.90f + 0.10f * (1.f - distNorm);

    float t = speedCurve * angleEase * distBias * dtScale;

    const float kMicroAngleRad = 1.5f * 3.14159265f / 180.f;
    if (angleRad < kMicroAngleRad) t *= 0.55f;

    const float maxT = (0.10f + 0.22f * speed01) * dtScale;
    const float minT = 0.012f * dtScale;
    if (t < minT) t = minT;
    if (t > maxT) t = maxT;
    return t;
}

void set_aim_legit(uint64_t player, Quaternion rotation, float targetDistance) {
    if (!isVaildPtr(player)) return;
    Quaternion q = Quaternion::Normalized(rotation);
    if (isnan(q.x) || isnan(q.y) || isnan(q.z) || isnan(q.w)) return;

    Quaternion current = ReadAddr<Quaternion>(player + kAimRotation);
    float n = current.x * current.x + current.y * current.y + current.z * current.z + current.w * current.w;
    if (!(n > 0.0001f) || isnan(n)) {
        // Cold / invalid current rotation — snap once so legit has a valid baseline.
        write_aim_rotations(player, q);
        return;
    }
    current = Quaternion::Normalized(current);
    float angle = Quaternion::Angle(current, q);
    if (isnan(angle)) return;
    if (angle < 0.0015f) return; // already on target

    float s = Clamp01f(aimSpeed);
    float t = legit_aim_blend_t(angle, s, targetDistance, aimDistance);
    Quaternion blended = Quaternion::Slerp(current, q, t);
    Quaternion out = Quaternion::Normalized(blended);
    if (isnan(out.x) || isnan(out.y) || isnan(out.z) || isnan(out.w)) return;
    write_aim_rotations(player, out);
}
// ============= END AIM LEGIT =================

static UIFont *LoadCountFont(CGFloat size) {
    static BOOL fontLoaded = NO;
    static NSString *realFontName = @"Arial-BoldMT";
    if (!fontLoaded) {
        NSString *fontPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Font/count.ttf"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:fontPath]) {
            CGDataProviderRef fontDataProvider = CGDataProviderCreateWithFilename([fontPath UTF8String]);
            if (fontDataProvider) {
                CGFontRef customFont = CGFontCreateWithDataProvider(fontDataProvider);
                if (customFont) {
                    CTFontManagerRegisterGraphicsFont(customFont, nil);
                    NSString *postScriptName = (__bridge_transfer NSString *)CGFontCopyPostScriptName(customFont);
                    if (postScriptName) { realFontName = postScriptName; }
                    CGFontRelease(customFont);
                }
                CGDataProviderRelease(fontDataProvider);
            }
        }
        fontLoaded = YES;
    }
    UIFont *font = [UIFont fontWithName:realFontName size:size];
    return font ? font : [UIFont boldSystemFontOfSize:size];
}

// The font name the counter draws with, cached once.
//
// addText: keeps its own static copy of LoadCountFont(10).fontName and so does
// this, and both go through the same loader, so the digits in the corner and the
// nicknames over the boxes are one typeface. Rebuilding the UIFont per player per
// frame just to read a name that never changes is not worth it.
//
// extern "C" on the definition, not just on the declaration in esp.h. espdraw.mm
// calls this, and espdraw.mm is Objective-C++ while this is Objective-C++, so
// without it the symbol is C++ mangled and the two sides do not meet: the header
// promises an unmangled _ESPNameTextFontName and the definition supplies a
// mangled one. That is an undefined symbol at link time, and -fsyntax-only
// cannot see it, so it is checked here by hand every time.
#ifdef __cplusplus
extern "C" {
#endif
CTFontRef ESPNameTextCTFont(CGFloat size) {
    if (size <= 0.0f) size = 10.0f;
    // System faces, in order of preference. Every one of these is in the iOS font
    // registry on every device, which is the whole point.
    //
    // The first version of this asked UIFont for its fontName and handed that to
    // CTFontCreateWithName. UIFont can resolve a face that CoreText's registry
    // has never heard of, and when the lookup misses, CTFontCreateWithName does
    // not fail: it returns a fallback whose glyphs are all 0. The advance sum
    // then comes back 0, the caller concludes there is nothing to draw, and the
    // path comes out empty. That is what was on screen: a plate, no glyphs.
    //
    // Menlo-Bold is first because it is heavy, monospaced and very legible at the
    // small sizes a distant player needs, which is exactly what a name over a dark
    // plate wants. The rest are fallbacks in descending weight.
    static const CFStringRef faces[] = {
        CFSTR("Menlo-Bold"), CFSTR("HelveticaNeue-Bold"),
        CFSTR("Helvetica-Bold"), CFSTR("Arial-BoldMT")
    };
    for (size_t i = 0; i < sizeof(faces) / sizeof(faces[0]); i++) {
        CTFontRef f = CTFontCreateWithName(faces[i], size, NULL);
        if (f) return f;
    }
    return NULL;
}
#ifdef __cplusplus
}   // extern "C"
#endif

static inline CGMutablePathRef ESPCreateMutablePath(void) { return CGPathCreateMutable(); }
static inline void ESPReleasePath(CGMutablePathRef path) { if (path) CGPathRelease(path); }

static inline ESPGeometryBuffers ESPGeometryBuffersCreate(void) {
    ESPGeometryBuffers buffers;
    buffers.boxPath = ESPCreateMutablePath();
    buffers.boxBotPath = ESPCreateMutablePath();
    buffers.boxKnockedPath = ESPCreateMutablePath();
    buffers.bonePath = ESPCreateMutablePath();
    buffers.boneBotPath = ESPCreateMutablePath();
    buffers.boneKnockedPath = ESPCreateMutablePath();
    buffers.snaplinePath = ESPCreateMutablePath();
    buffers.snaplineBotPath = ESPCreateMutablePath();
    buffers.snaplineKnockedPath = ESPCreateMutablePath();
    buffers.hpFillGreenPath = ESPCreateMutablePath();
    buffers.hpFillOrangePath = ESPCreateMutablePath();
    buffers.hpFillRedPath = ESPCreateMutablePath();
    buffers.bgFillBlackPath = ESPCreateMutablePath();
    buffers.alertPath = ESPCreateMutablePath();
    buffers.nameTextPath = ESPCreateMutablePath();
    buffers.nameBgPath = ESPCreateMutablePath();
    
    buffers.boxDirty = buffers.boxBotDirty = buffers.boxKnockedDirty = NO;
    buffers.boneDirty = buffers.boneBotDirty = buffers.boneKnockedDirty = NO;
    buffers.snaplineDirty = buffers.snaplineBotDirty = buffers.snaplineKnockedDirty = NO;
    // These three are what the fan relies on to decide whether its moveTo has been
    // emitted, and they were left out of this initialiser when the fan landed. That
    // is a real bug and it is the worst kind: the struct is a raw local with no
    // memset, so the three bytes came back as stack garbage, and ESPAddFanRay only
    // ever writes them true. So whether a fan got its moveTo depended on whatever
    // the previous frame left in that stack slot, which is exactly a line that
    // appears and disappears on its own while the camera is still. It also meant
    // the commit's own claim that they "reset with the struct" was simply false.
    //
    // Initialising them here rather than in the struct declaration is deliberate:
    // the struct is returned by value from a function and consumed by value, so a
    // member initialiser would be a constructor on a C struct and would not
    // compile the way the rest of this file expects.
    buffers.snaplineFanStarted = buffers.snaplineBotFanStarted = buffers.snaplineKnockedFanStarted = NO;
    buffers.hpFillGreenDirty = buffers.hpFillOrangeDirty = buffers.hpFillRedDirty = NO;
    buffers.bgFillBlackDirty = buffers.alertDirty = NO;
    buffers.nameTextDirty = NO;
    return buffers;
}

// Counts path elements and curve elements for the [APP-LAYER] diagnostic.
// CGPathApply takes a plain C function, not a block.
typedef struct { uint32_t n; uint32_t curves; } ESPPathCountCtx;
static void espCountPathElements(void *info, const CGPathElement *e) {
    ESPPathCountCtx *c = (ESPPathCountCtx *)info;
    if (!c) return;
    c->n++;
    if (e->type == kCGPathElementAddCurveToPoint ||
        e->type == kCGPathElementAddQuadCurveToPoint) c->curves++;
}

static inline void ESPGeometryBuffersRelease(ESPGeometryBuffers *buffers) {
    if (!buffers) return;
    ESPReleasePath(buffers->boxPath); ESPReleasePath(buffers->boxBotPath); ESPReleasePath(buffers->boxKnockedPath);
    ESPReleasePath(buffers->bonePath); ESPReleasePath(buffers->boneBotPath); ESPReleasePath(buffers->boneKnockedPath);
    ESPReleasePath(buffers->snaplinePath); ESPReleasePath(buffers->snaplineBotPath);
    ESPReleasePath(buffers->snaplineKnockedPath); ESPReleasePath(buffers->hpFillGreenPath);
    ESPReleasePath(buffers->hpFillOrangePath); ESPReleasePath(buffers->hpFillRedPath); 
    ESPReleasePath(buffers->bgFillBlackPath); ESPReleasePath(buffers->alertPath);
    ESPReleasePath(buffers->nameTextPath); ESPReleasePath(buffers->nameBgPath);
}

static inline void MenuViewApplyPath(CAShapeLayer *layer, CGMutablePathRef path, bool dirty) {
    if (!layer) return;
    if (dirty && path) { layer.path = path; } 
    else if (layer.path != nil) { layer.path = nil; }
}

static int syncTick = 0;
static bool s_setNameEnabledGlobal = false;
static NSString *s_customNameGlobal = nil;

void ESPSyncFromPrefs(void) {
    // Pick up writes from another process first. The engine runs in
    // SpringBoard now, so this is the only thing standing between a tap in the
    // app and the setting actually taking effect there.
    ESPPrefsReloadIfChanged();
    // Throttle full reload: menu drag/slider used to call this every tick → lag.
    // Still fast enough for toggles (callers also invoke on switch/segment release).
    static CFTimeInterval s_lastFullSync = 0;
    CFTimeInterval nowSync = CACurrentMediaTime();
    if (s_lastFullSync > 0 && (nowSync - s_lastFullSync) < 0.05) {
        return;
    }
    s_lastFullSync = nowSync;
    (void)syncTick;

    isStreamerMode = ESPPrefsBool(@"StreamerMode", NO);

    Norecoil   = ESPPrefsBool(@"Norecoil", NO);
    // Brutal run scale (slider). Default 0.16 = old crawl; adjustable Lite+Pro.
    {
        float bs = ESPPrefsFloat(@"BrutalSpeed", 0.16f);
        if (bs < 0.05f) bs = 0.05f;
        if (bs > 0.80f) bs = 0.80f;
        speedvalue = Norecoil ? bs : 1.0f;
    }
    // Menu Speed only when Brutal OFF (same mutual exclusion as before).
    isSpeed = ESPPrefsBool(@"Speed", NO);
    moveSpeedScale = ESPPrefsFloat(@"SpeedValue", 1.22f);
    if (moveSpeedScale < 1.0f) moveSpeedScale = 1.0f;
    if (moveSpeedScale > 1.45f) moveSpeedScale = 1.45f;
    if (!isSpeed) moveSpeedScale = 1.0f;
    if (Norecoil) {
        if (isSpeed || ESPPrefsBool(@"Speed", NO)) {
            ESPPrefsSetBool(@"Speed", NO);
        }
        isSpeed = NO;
        moveSpeedScale = 1.0f;
    }
    // FOV ring visibility. The aimbot and aimSphereMode are deliberately not in
    // this condition: they used to be, and the effect was that turning the
    // aimbot off deleted the ring, choosing the 180 or 360 sphere deleted it too,
    // and the only way to make the circle smaller was to weaken the aim.
    isShowFovCircle = ESPPrefsBool(@"ShowFovCircle", YES);
    // 10 to 190. Below 5 the ring is a dot and above 190 it is clipped by the
    // short edge of the screen, so both ends are refused rather than passed to
    // cosf and sinf as-is.
    fovSize = ESPPrefsFloat(@"FovSize", 120.0f);
    if (fovSize < 5.0f)  fovSize = 120.0f;
    if (fovSize > 190.0f) fovSize = 190.0f;

    isESP      = ESPPrefsBool(@"EnableESP", YES);
    isESP2     = ESPPrefsBool(@"EnableESP2", NO);
    isBox      = ESPPrefsBool(@"Box", YES);
    boxMode    = (int)ESPPrefsFloat(@"BoxMode", 0.0f);
    isBone     = ESPPrefsBool(@"Bone", YES);
    isHealth   = ESPPrefsBool(@"Health", YES);
    isName     = ESPPrefsBool(@"Name", YES);
    // "Distance" is ESP toggle (bool). Aim range uses dedicated "AimDistance".
    isDis      = ESPPrefsBool(@"Distance", YES);
    isLine     = ESPPrefsBool(@"Line", YES);
    isEspBot   = ESPPrefsBool(@"EspBot", YES);
    isWeapon   = ESPPrefsBool(@"Weapon", NO);
    isCount    = ESPPrefsBool(@"Count", YES);
    isAlert360 = ESPPrefsBool(@"Alert360", NO);
    isAlertNum = ESPPrefsBool(@"AlertNum", NO);

    isEspCheckVisible = ESPPrefsBool(@"EspCheckVisible", NO);
    // AimOnBot = YES means aimbot/assist/silent can target bots.
    // Keep legacy AimIgnoreBot in sync (Ignore = !AimOnBot).
    {
        BOOL aimOnBot = YES;
        id aimOnBotPref = AppSettingsObjectForKey(@"AimOnBot");
        if (aimOnBotPref != nil) {
            aimOnBot = ESPPrefsBool(@"AimOnBot", YES);
        } else {
            // Migrate old builds that only had AimIgnoreBot.
            aimOnBot = !ESPPrefsBool(@"AimIgnoreBot", NO);
            ESPPrefsSetBool(@"AimOnBot", aimOnBot);
        }
        isAimIgnoreBot = !aimOnBot;
        ESPPrefsSetBool(@"AimIgnoreBot", isAimIgnoreBot);
        // When aiming bots, also show bot ESP so you can verify lock on training bots.
        if (aimOnBot) isEspBot = YES;
    }
    isAimIgnoreKnock = ESPPrefsBool(@"AimIgnoreKnock", NO);
    // Aim behind wall only (bom keo feature removed).
    isAimBehindWall = ESPPrefsBool(@"AimBehindWall", NO);
    // Force-clear legacy ice-wall pref so old installs cannot soft-enable it.
    ESPPrefsSetBool(@"AimBehindIceWall", NO);
    isAimRage = ESPPrefsBool(@"AimRage", NO);
    // Aimbot + Aim Assist can run together (share target priority / AimPos).
    // Only Legit is exclusive vs hard LookAt (soft Slerp fights Aimbot).
    isAimbot    = ESPPrefsBool(@"Aimbot", NO);
    isAimAssist = ESPPrefsBool(@"AimAssist", NO);
    isKillGameAA = ESPPrefsBool(@"KillGameAA", YES);
    isAimLegit  = ESPPrefsBool(@"AimLegit", NO);
    if (isAimbot && isAimLegit) {
        ESPPrefsSetBool(@"AimLegit", NO);
        isAimLegit = NO;
    } else if (!isAimbot && isAimAssist && isAimLegit) {
        ESPPrefsSetBool(@"AimLegit", NO);
        isAimLegit = NO;
    }
    // Aim sphere: FOV / 180 / 360. Only active with Aimbot.
    // Migrate legacy Aim360 bool → mode 2.
    {
        int mode = (int)ESPPrefsFloat(@"AimSphereMode", -1.0f);
        if (mode < 0) {
            mode = ESPPrefsBool(@"Aim360", NO) ? 2 : 0;
            ESPPrefsSetFloat(@"AimSphereMode", (float)mode);
        }
        if (mode < 0) mode = 0;
        if (mode > 2) mode = 2;
        aimSphereMode = isAimbot ? mode : 0;
    }
    // Silent / magic bullet — independent of Aimbot (works alone or together).
    // Approach from AimSilent.h: high-freq thread rewrites AimingInfo direction.
    bool wasSilent = isAimSilent;
    isAimSilent = ESPPrefsBool(@"AimSilent", NO);
    if (wasSilent && !isAimSilent) {
        SilentAimStop();
    }
    // Aimbot, Aim Assist, Silent are independent pipelines.

    isFastReload = ESPPrefsBool(@"FastReload", NO);
    fastReloadSpeed = ESPPrefsFloat(@"FastReloadSpeed", 1.0f);
    // Legacy: force-off removed InstantHeal / Fast Weapon Switch prefs.
    ESPPrefsSetBool(@"InstantHeal", NO);
    ESPPrefsSetBool(@"FastWeaponSwitch", NO);
    // CamPC is gone, not just unexposed. It wrote a float at (pawn + 0x628) + 0x70,
    // where 0x628 is read as a pointer by other code in this file and the offset
    // had no provenance of its own — the same shape of guess that wrote
    // quaternions over a pointer and killed the game at match teardown
    // (FreeFire-2026-10-03-082640.ips). Removed rather than defaulted off, so
    // there is nothing left to switch on.

    ESPSyncTickRate();

    aimMode = (int)ESPPrefsFloat(@"AimMode", 1.0f);
    triggerMode = (int)ESPPrefsFloat(@"TriggerMode", 0.0f);
    if (triggerMode < 0) triggerMode = 0;
    if (triggerMode > 3) triggerMode = 3;
    aimPosition = (int)ESPPrefsFloat(@"AimPos", 0.0f);
    if (aimPosition < 0) aimPosition = 0;
    if (aimPosition > 2) aimPosition = 2;
    aimTargetMode = (int)ESPPrefsFloat(@"AimTargetMode", 0.0f);

    // The aim radius and the ring radius are one setting, read from one pref.
    //
    // They were not. The ring read FovSize, which is what the app's ESP/AIM screen
    // writes (ESPAimViewController, "FOV Size"), and the aim read Fov, which that
    // screen never writes. So moving the slider moved the circle and left the aim
    // exactly where it was — reported as "the aim does not take the FOV size".
    // Two keys for one number, and the shipped UI wrote the one the engine ignored.
    //
    // Fov is only a fallback, never a write: it is the old in-game menu's slider,
    // so an install that has it and has never touched the app screen keeps working
    // exactly as before, and nothing here migrates one into the other.
    id sizeVal = AppSettingsObjectForKey(@"FovSize");
    if ([sizeVal isKindOfClass:[NSNumber class]]) {
        aimFov = [(NSNumber *)sizeVal floatValue];
    } else {
        aimFov = ESPPrefsFloat(@"Fov", 120.0f);
    }
    // The ring's own clamp, spelled the same way (fovSize, a few hundred lines
    // up), so the two can never disagree about what the number means.
    if (aimFov < 5.0f)   aimFov = 120.0f;
    if (aimFov > 190.0f) aimFov = 190.0f;

    // Prefer AimDistance. Migrate old builds that stored aim range under "Distance" as a float > 1.
    aimDistance = ESPPrefsFloat(@"AimDistance", -1.0f);
    if (aimDistance < 0.0f) {
        id legacy = AppSettingsObjectForKey(@"Distance");
        if ([legacy isKindOfClass:[NSNumber class]] && [(NSNumber *)legacy floatValue] > 1.5f) {
            aimDistance = [(NSNumber *)legacy floatValue];
            ESPPrefsSetFloat(@"AimDistance", aimDistance);
        } else {
            aimDistance = 200.0f;
        }
    }
    if (aimDistance <= 1.0f) aimDistance = 200.0f;

    aimSpeed = ESPPrefsFloat(@"AimSpeed", 100.0f) / 100.0f;
    if (aimSpeed < 0.01f) aimSpeed = 0.01f;
    if (aimSpeed > 1.0f) aimSpeed = 1.0f;

    espDistanceLimit = ESPPrefsFloat(@"EspDistanceLimit", 150.0f);
    if (espDistanceLimit < 10.0f) espDistanceLimit = 150.0f;

   s_setNameEnabledGlobal = ESPPrefsBool(@"SetName", NO);

    NSString *customDefault = @"@Bolaminhduc";
    NSString *newName = AppSettingsObjectForKey(@"CustomName");
    // Migrate old default names to new brand.
    if (![newName isKindOfClass:[NSString class]] || ((NSString *)newName).length == 0 ||
        [newName containsString:@"thanhhoa"] || [newName containsString:@"Thanhhoa"] ||
        [newName containsString:@"Ng_thanhhoa"] || [newName containsString:@"ng_thanhhoa"]) {
        newName = customDefault;
        AppSettingsSetObject(@"CustomName", customDefault);
    }

    if (![newName isEqualToString:s_customNameGlobal]) {
        s_customNameGlobal = newName;
    }

    int menuStyle = (int)ESPPrefsFloat(@"MenuLayoutStyle", 0.0f);
    if (menuStyle == 1) {
        isEspBot = YES;
        isAimIgnoreBot = NO;
        isAimIgnoreKnock = YES;
        isEspCheckVisible = YES;
    }

    boxThick = ESPPrefsFloat(@"BoxThickness", 1.0f);
    boxR = ESPPrefsFloat(@"BoxColorR", 0.0f); boxG = ESPPrefsFloat(@"BoxColorG", 1.0f); boxB = ESPPrefsFloat(@"BoxColorB", 1.0f);
    boxColorMode = (int)ESPPrefsFloat(@"BoxColorMode", 0.0f);
    if (boxColorMode < 0) boxColorMode = 0;
    if (boxColorMode > 1) boxColorMode = 1;

    boneThick = ESPPrefsFloat(@"BoneThickness", 1.0f);
    boneR = ESPPrefsFloat(@"BoneColorR", 0.0f); boneG = ESPPrefsFloat(@"BoneColorG", 1.0f); boneB = ESPPrefsFloat(@"BoneColorB", 1.0f);
    boneColorMode = (int)ESPPrefsFloat(@"BoneColorMode", 0.0f);
    if (boneColorMode < 0) boneColorMode = 0;
    if (boneColorMode > 1) boneColorMode = 1;

    lineThick = ESPPrefsFloat(@"LineThickness", 1.0f);
    lineR = ESPPrefsFloat(@"LineColorR", 0.0f); lineG = ESPPrefsFloat(@"LineColorG", 1.0f); lineB = ESPPrefsFloat(@"LineColorB", 1.0f);
    lineColorMode = (int)ESPPrefsFloat(@"LineColorMode", 0.0f);
    if (lineColorMode < 0) lineColorMode = 0;
    if (lineColorMode > 1) lineColorMode = 1;

    fovThick = ESPPrefsFloat(@"FovThickness", 0.6f);
    fovR = ESPPrefsFloat(@"FovColorR", 1.0f); fovG = ESPPrefsFloat(@"FovColorG", 1.0f); fovB = ESPPrefsFloat(@"FovColorB", 0.0f);
    fovColorMode = (int)ESPPrefsFloat(@"FovColorMode", 0.0f);
    if (fovColorMode < 0) fovColorMode = 0;
    if (fovColorMode > 1) fovColorMode = 1;

    aimAssistThick = ESPPrefsFloat(@"AimAssistThickness", 1.5f);
    aimAssistR = ESPPrefsFloat(@"AimAssistColorR", 0.0f); aimAssistG = ESPPrefsFloat(@"AimAssistColorG", 1.0f); aimAssistB = ESPPrefsFloat(@"AimAssistColorB", 1.0f);
}

@interface HTHESPSecureWrapper : UITextField
@end
@implementation HTHESPSecureWrapper
- (BOOL)canBecomeFirstResponder { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
@end

@interface ESP_View ()
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) dispatch_source_t frameTimer;

// Implementation lives in the @implementation below. Declared here because
// DirectOverlay.mm calls it across translation units.
@property (nonatomic, strong) HTHESPSecureWrapper *secureTextField; 
@property (nonatomic, strong) UIView *secureCanvas;                  

@property (nonatomic, strong) CAShapeLayer *boxLayer;
@property (nonatomic, strong) CAShapeLayer *boxBotLayer;
@property (nonatomic, strong) CAShapeLayer *boxKnockedLayer;
@property (nonatomic, strong) CAShapeLayer *boneLayer;
@property (nonatomic, strong) CAShapeLayer *boneBotLayer;
@property (nonatomic, strong) CAShapeLayer *boneKnockedLayer;
@property (nonatomic, strong) CAShapeLayer *snaplineLayer;
@property (nonatomic, strong) CAShapeLayer *snaplineBotLayer;
@property (nonatomic, strong) CAShapeLayer *snaplineKnockedLayer;
@property (nonatomic, strong) CAShapeLayer *hpFillGreenLayer;
@property (nonatomic, strong) CAShapeLayer *hpFillOrangeLayer;
@property (nonatomic, strong) CAShapeLayer *hpFillRedLayer;
@property (nonatomic, strong) CAShapeLayer *bgFillBlackLayer; 
@property (nonatomic, strong) CAShapeLayer *alertLayer;
@property (nonatomic, strong) CAShapeLayer *fovLayer;
@property (nonatomic, strong) CAShapeLayer *aimAssistLayer;

@property (nonatomic, strong) CAShapeLayer *alertNumBGLayer;
@property (nonatomic, strong) CAShapeLayer *alertNumGreenLayer;
@property (nonatomic, strong) CAShapeLayer *alertNumOrangeLayer;
@property (nonatomic, strong) CAShapeLayer *alertNumRedLayer;

// The nickname glyphs. Built and filled white in this process and read out of
// this view over KVC, so this layer is never added to the canvas and never has
// a path set on the app side: it exists to be asked for. See ESPGeometryBuffers
// in esp.h for why the plate is geometry and not a CATextLayer.
@property (nonatomic, strong) CAShapeLayer *nameTextLayer;

@property (nonatomic, strong) NSMutableArray<CATextLayer *> *textLayerPool;
@property (nonatomic, assign) NSUInteger activeTextLayerCount;

@property (nonatomic, strong) NSMutableArray<CALayer *> *imageLayerPool;
@property (nonatomic, assign) NSUInteger activeImageLayerCount;

@property (nonatomic, strong) CATextLayer *statusLayer;
@property (nonatomic, copy) NSString *lastStatusString; 

- (void)configureRenderingLayers;
- (void)resetReusableLayers;
- (void)clearAllContent; 
- (void)addText:(NSString *)text frame:(CGRect)frame color:(UIColor *)color fontSize:(CGFloat)fontSize leftAligned:(BOOL)leftAligned;
- (void)addImage:(UIImage *)image frame:(CGRect)frame;
@end

@implementation ESP_View

// Added so the app's Stop button has something to call. Before this the only
// stop in the tree was SetHUDEnabled(NO), which kills the separate -hud
// process; the session that actually draws lives in this process, so the
// button reported success while ESP kept drawing.
//
// Cancelling the timer is what makes the stop stick: it is the 60fps loop that
// keeps mirroring frames into SpringBoard. A dispatch source has to be
// cancelled before it is released, otherwise the cancel is a no-op.
//
// Main thread: the timer was created on the main queue.
- (void)stopRendering {
    if (_frameTimer) {
        dispatch_source_cancel(_frameTimer);
        _frameTimer = nil;
    }
    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
    [self clearAllContent];
    [self hideMenu];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }

static void ESPViewAddTextCallback(void *context, NSString *string, CGRect frame, UIColor *color, CGFloat fontSize, BOOL leftAligned) {
    if (!context || !string) return;
    ESP_View *view = (__bridge ESP_View *)context;
    [view addText:string frame:frame color:color fontSize:fontSize leftAligned:leftAligned];
}

static void ESPViewAddImageCallback(void *context, UIImage *image, CGRect frame) {
    if (!context || !image) return;
    ESP_View *view = (__bridge ESP_View *)context;
    [view addImage:image frame:frame];
}

- (void)hideMenu {}
- (void)showMenu {}
- (void)handlePan:(UIPanGestureRecognizer *)gesture {}
- (void)centerMenu {}

- (void)clearAllContent {
    self.boxLayer.path = nil; 
    self.boxBotLayer.path = nil; self.boxKnockedLayer.path = nil;
    self.boneLayer.path = nil; 
    self.boneBotLayer.path = nil; self.boneKnockedLayer.path = nil;
    self.snaplineLayer.path = nil; 
    self.snaplineBotLayer.path = nil; self.snaplineKnockedLayer.path = nil; 
    self.hpFillGreenLayer.path = nil; self.hpFillOrangeLayer.path = nil;
    self.hpFillRedLayer.path = nil; self.alertLayer.path = nil; self.fovLayer.path = nil;
    self.bgFillBlackLayer.path = nil; self.aimAssistLayer.path = nil;
    self.alertNumBGLayer.path = nil; self.alertNumGreenLayer.path = nil;
    self.alertNumOrangeLayer.path = nil; self.alertNumRedLayer.path = nil;
    self.nameTextLayer.path = nil;
    self.statusLayer.hidden = YES;
    [self resetReusableLayers];
}

static void *gEngine = (void *)1; // DSMemory mode
mach_port_t task;

// Brutal restore must run even when all ESP/aim toggles are off.
// Early-return used to skip the patch block → leave-match "lỗi brutal" + turbo stick.
static std::atomic<bool> g_brutalPatched{false};
static std::atomic<bool> g_brutalHasAddrs{false};

// DIAG_EARLY: rate-limited one-line reason why the render path stopped.
// Shows up in the Home log card so "cheat has no effect" becomes diagnosable
// from the user's screen (no-base = attach failed, lobby = in lobby,
// no-matchGame = offset wrong, ok = apply path reached).
#define DIAG_EARLY(reason) do { \
    static CFTimeInterval s_lastDiagE = 0; \
    CFTimeInterval nowE = CACurrentMediaTime(); \
    if (nowE - s_lastDiagE > 5.0) { \
        s_lastDiagE = nowE; \
        kernel_boot_log_fn logFnE = kernelBootLog; \
        if (logFnE) { \
            NSString *lineE = [NSString stringWithFormat:@"[diag] stop: %@", reason]; \
            dispatch_async(dispatch_get_main_queue(), ^{ logFnE(lineE); }); \
        } \
    } \
} while (0)

// LOBBY diag variant — logs the RAW first TypeInfo read so it can be
// compared with the working TIPA build. If base+0xC012848 returns a
// different pointer here than on TIPA, the remap reads are corrupting data;
// if it matches, the offset chain (statics +0xB8 → matchGame) is what fails.
#define DIAG_EARLY_LOBBY() do { \
    static CFTimeInterval s_lastDiagL = 0; \
    CFTimeInterval nowL = CACurrentMediaTime(); \
    if (nowL - s_lastDiagL > 5.0) { \
        s_lastDiagL = nowL; \
        uint64_t ti = ReadAddr<uint64_t>(Moudule_Base + (uint64_t)kGameFacadeTypeInfo); \
        uint64_t st = isVaildPtr(ti) ? ReadAddr<uint64_t>(ti + 0xB8) : 0; \
        kernel_boot_log_fn logFnL = kernelBootLog; \
        if (logFnL) { \
            NSString *lineL = [NSString stringWithFormat: \
                @"[diag] lobby: base=%@ ti=%@ st=%@", \
                Moudule_Base > 0 ? [NSString stringWithFormat:@"%llx", Moudule_Base] : @"0", \
                isVaildPtr(ti) ? [NSString stringWithFormat:@"%llx", ti] : @"nil", \
                isVaildPtr(st) ? [NSString stringWithFormat:@"%llx", st] : @"nil"]; \
            dispatch_async(dispatch_get_main_queue(), ^{ logFnL(lineL); }); \
        } \
    } \
} while (0)

// ── DIAG heartbeat ────────────────────────────────────────────────────────
// One unconditional line per second, printed from the top of updateFrame
// BEFORE every early return. The previous measurement round buried its DIAGs
// behind the in-match gate, so a log captured during lobby/loading contained
// none of them and proved nothing. This line always prints, so the log says
// which gate is blocking AND what the previous frame actually produced.
//
//   base= pid= at=            attach state (ds_attached / ds_pid / Moudule_Base)
//   ti= st=                  raw kGameFacadeTypeInfo read and *(ti+0xB8) —
//                            the head of the matchGame chain, before any
//                            further indirection
//   mg= cam= mt= pawn= hp=   the pointer chain, one stage at a time; the first
//                            one that is 0 is the gate that stopped us
//   real= bot=               players the LAST completed frame managed to draw
//                            (real=0 ⇒ data/chain, not projection)
//   cache{g= live= stale=}   g = cache generation, stale = slots mapped before
//                            generation g. stale>0 ⇒ the cache crossed a match
//                            boundary and is serving freed memory.
//   VP{ok= m0= m3= m12= m15=} view-projection row terms WorldToScreen uses;
//                            m3/m12 are the w-row constants it divides by.
//                            Identical across samples while the camera turns ⇒
//                            the matrix is frozen, the drawing is innocent.
// Bump this every commit that changes measurement, so a device log identifies
// its own build. Absence of this token = the IPA on the device is older.
#define ESP_DIAG_BUILD "FLUSH1"

static int g_hbLastReal = -1;
static int g_hbLastBot  = -1;

static void ESPDiagHeartbeat(void) {
    static CFTimeInterval s_hb = 0;
    CFTimeInterval nowH = CACurrentMediaTime();
    if (nowH - s_hb < 1.0) return;
    s_hb = nowH;

    const uint64_t base = Moudule_Base;
    const int attached  = ds_attached() ? 1 : 0;
    const int pid       = (int)ds_pid();

    uint64_t ti = 0, st = 0, mg = 0, cam = 0, mt = 0, pawn = 0;
    int   hp   = -1;
    float vp[16];
    int   vpOk = 0;
    memset(vp, 0, sizeof(vp));

    if (isVaildPtr(base)) {
        ti = ReadAddr<uint64_t>(base + (uint64_t)kGameFacadeTypeInfo);
        if (isVaildPtr(ti)) {
            st = ReadAddr<uint64_t>(ti + 0xB8);
        }
        mg = getMatchGame(base);
        if (isVaildPtr(mg)) {
            cam = CameraMain(mg);
            mt  = getMatch(mg);
            if (isVaildPtr(mt)) {
                pawn = getLocalPlayer(mt);
                if (isVaildPtr(pawn)) hp = get_CurHP(pawn);
            }
        }
    }
    if (isVaildPtr(cam)) {
        vpOk = GetViewMatrixInto(cam, vp) ? 1 : 0;
    }

    DSPageCacheDiag cd = ds_page_cache_diag();

    // %s, NOT %@. ESP_DIAG_BUILD is a C string literal, and %@ makes os_log send
    // -objcDescription to it: it dereferences the literal's own bytes ("PUSH1\0")
    // as an isa, follows the garbage, and SIGSEGVs on the main queue.
    // That is the crash in incident 5793D039 (run #198, ddbc6a16), whose stack is
    // NSLog -> ESPDiagHeartbeat -> dispatch block. Fixed here only; no other change.
    NSLog(@"[HB] %s base=0x%llx pid=%d at=%d ti=0x%llx st=0x%llx mg=0x%llx cam=0x%llx "
          @"mt=0x%llx pawn=0x%llx hp=%d real=%d bot=%d "
          @"cache{g=%llu,live=%d,stale=%d} "
          @"VP{ok=%d m0=%.4f m3=%.4f m12=%.4f m15=%.4f}",
          ESP_DIAG_BUILD,
          (unsigned long long)base, pid, attached,
          (unsigned long long)ti, (unsigned long long)st,
          (unsigned long long)mg, (unsigned long long)cam,
          (unsigned long long)mt, (unsigned long long)pawn, hp,
          g_hbLastReal, g_hbLastBot,
          (unsigned long long)cd.generation, cd.liveSlots, cd.staleGen,
          vpOk, vp[0], vp[3], vp[12], vp[15]);
}




- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO; 
        self.backgroundColor = [UIColor clearColor];
        self.textLayerPool = [NSMutableArray arrayWithCapacity:300];
        self.imageLayerPool = [NSMutableArray arrayWithCapacity:80];
        
        // NOTE: no dispatch_once attach here! The game may not be running yet
        // (attach via DSMemory is retried every frame in updateFrame). A once-
        // cached Moudule_Base=0 permanently disabled ESP until app restart.
        InitWeaponTextures();
        gEngine = (void *)1; // DSMemory

        _secureTextField = [[HTHESPSecureWrapper alloc] initWithFrame:self.bounds];
        _secureTextField.userInteractionEnabled = NO; 
        _secureTextField.enabled = NO; 
        _secureTextField.backgroundColor = [UIColor clearColor];
        _secureTextField.text = @"\u200B"; 
        _secureTextField.textColor = [UIColor clearColor];
        [self addSubview:_secureTextField];
        
        _secureTextField.secureTextEntry = ESPPrefsBool(@"StreamerMode", NO);
        [_secureTextField layoutIfNeeded];
        
        _secureCanvas = _secureTextField.subviews.firstObject ?: _secureTextField;
        _secureCanvas.userInteractionEnabled = NO; 
        
        [self configureRenderingLayers];

        // GCD timer — NOT CADisplayLink. CADisplayLink is paused by
        // iOS when the app is backgrounded (game in foreground), so ESP froze.
        // A dispatch_source timer on the main queue keeps firing while the
        // process is alive (audio KeepAlive), so the overlay keeps rendering
        // over the game.
        //
        // The interval comes from the EspTickHz pref, clamped to 30-60 Hz.
        // dispatch_source_set_timer can be called again on a running source,
        // so changing it does not need the view rebuilt.
        self.frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        if (self.frameTimer) {
            uint64_t intervalNS = ESPTickIntervalNS();
            dispatch_source_set_timer(self.frameTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNS),
                                      intervalNS,
                                      2 * NSEC_PER_MSEC);
            __weak ESP_View *wself = self;
            dispatch_source_set_event_handler(self.frameTimer, ^{
                [wself updateFrame];
            });
            dispatch_resume(self.frameTimer);
            s_espViewInstance = self;
            s_espTickAppliedHz = 0; // force the first sync to apply
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _secureTextField.frame = self.bounds;
    _secureCanvas.frame = self.bounds;
}

- (CAShapeLayer *)buildShapeLayerWithStroke:(UIColor *)stroke fill:(UIColor *)fill lineWidth:(CGFloat)lineWidth zPos:(CGFloat)zPos {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.strokeColor = stroke ? stroke.CGColor : nil;
    layer.fillColor = fill ? fill.CGColor : nil;
    layer.lineWidth = lineWidth;
    layer.lineJoin = kCALineJoinRound;
    layer.lineCap = kCALineCapRound;
    layer.opaque = NO;
    layer.contentsScale = UIScreen.mainScreen.scale;
    layer.zPosition = zPos;
    layer.actions = @{ @"path": NSNull.null, @"strokeColor": NSNull.null, @"fillColor": NSNull.null, @"lineWidth": NSNull.null };
    return layer;
}

- (void)configureRenderingLayers {
    CGFloat baseZ = 0; 
    
    self.bgFillBlackLayer = [self buildShapeLayerWithStroke:nil fill:[UIColor colorWithWhite:0.0f alpha:0.65f] lineWidth:0 zPos:baseZ + 4];
    
    self.snaplineLayer = [self buildShapeLayerWithStroke:[UIColor cyanColor] fill:UIColor.clearColor lineWidth:0.6f zPos:baseZ + 1];
    self.boxLayer = [self buildShapeLayerWithStroke:[UIColor cyanColor] fill:UIColor.clearColor lineWidth:0.6f zPos:baseZ + 3];
    self.boneLayer = [self buildShapeLayerWithStroke:[UIColor cyanColor] fill:UIColor.clearColor lineWidth:0.7f zPos:baseZ + 2];
    self.snaplineBotLayer = [self buildShapeLayerWithStroke:[UIColor yellowColor] fill:UIColor.clearColor lineWidth:0.6f zPos:baseZ + 1];
    self.boxBotLayer = [self buildShapeLayerWithStroke:[UIColor yellowColor] fill:UIColor.clearColor lineWidth:0.6f zPos:baseZ + 3];
    self.boneBotLayer = [self buildShapeLayerWithStroke:[UIColor yellowColor] fill:UIColor.clearColor lineWidth:0.7f zPos:baseZ + 2];
    self.snaplineKnockedLayer = [self buildShapeLayerWithStroke:[UIColor redColor] fill:UIColor.clearColor lineWidth:0.6f zPos:baseZ + 1];
    self.boxKnockedLayer = [self buildShapeLayerWithStroke:[UIColor redColor] fill:UIColor.clearColor lineWidth:0.6f zPos:baseZ + 3];
    self.boneKnockedLayer = [self buildShapeLayerWithStroke:[UIColor redColor] fill:UIColor.clearColor lineWidth:0.7f zPos:baseZ + 2]; 
    
    self.fovLayer = [self buildShapeLayerWithStroke:[UIColor yellowColor] fill:UIColor.clearColor lineWidth:0.6f zPos:baseZ];
    self.aimAssistLayer = [self buildShapeLayerWithStroke:[UIColor cyanColor] fill:UIColor.clearColor lineWidth:1.5f zPos:baseZ + 6];
    
    self.hpFillGreenLayer = [self buildShapeLayerWithStroke:nil fill:[UIColor colorWithRed:0.0f green:1.0f blue:0.0f alpha:1.0f] lineWidth:0 zPos:baseZ + 5]; 
    self.hpFillOrangeLayer = [self buildShapeLayerWithStroke:nil fill:[UIColor orangeColor] lineWidth:0 zPos:baseZ + 5];
    self.hpFillRedLayer = [self buildShapeLayerWithStroke:nil fill:[UIColor redColor] lineWidth:0 zPos:baseZ + 5];
    
    self.alertLayer = [self buildShapeLayerWithStroke:nil fill:[UIColor colorWithRed:103.0f/255.0f green:194.0f/255.0f blue:42.0f/255.0f alpha:1.0f] lineWidth:0 zPos:baseZ + 5]; 

    self.alertNumBGLayer = [self buildShapeLayerWithStroke:nil fill:[UIColor colorWithWhite:0.0f alpha:0.65f] lineWidth:0 zPos:baseZ + 7];
    self.alertNumGreenLayer = [self buildShapeLayerWithStroke:[UIColor colorWithRed:0 green:1 blue:0 alpha:1.0f] fill:[UIColor clearColor] lineWidth:4.0f zPos:baseZ + 8];
    self.alertNumOrangeLayer = [self buildShapeLayerWithStroke:[UIColor orangeColor] fill:[UIColor clearColor] lineWidth:4.0f zPos:baseZ + 8];
    self.alertNumRedLayer = [self buildShapeLayerWithStroke:[UIColor redColor] fill:[UIColor clearColor] lineWidth:4.0f zPos:baseZ + 8];

    // Nickname glyphs, white and filled, on top of the dark plate. baseZ + 8 for
    // the same reason the plate is baseZ + 7: the plate has to cover the box and
    // the health bar, which are at baseZ + 3 and baseZ + 5, and the glyphs have to
    // cover the plate.
    //
    // Deliberately not in the layers array below. It is a data source for
    // SpringBoard, not something this process draws: adding it would put a second
    // copy of the name on the app's own canvas over a canvas nobody can see, and
    // it would then need clearing in resetReusableLayers and re-attaching on the
    // streamer-mode toggle for no picture. It stays a bare retained layer whose
    // path is set by MenuViewApplyPath and read back over KVC.
    self.nameTextLayer = [self buildShapeLayerWithStroke:nil fill:[UIColor whiteColor] lineWidth:0 zPos:baseZ + 8];

    NSArray *layers = @[self.bgFillBlackLayer, self.fovLayer, self.snaplineLayer, self.snaplineBotLayer, self.snaplineKnockedLayer, self.boneLayer, self.boneBotLayer, self.boneKnockedLayer, self.boxLayer, self.boxBotLayer, self.boxKnockedLayer, self.hpFillGreenLayer, self.hpFillOrangeLayer, self.hpFillRedLayer, self.alertLayer, self.aimAssistLayer, self.alertNumBGLayer, self.alertNumGreenLayer, self.alertNumOrangeLayer, self.alertNumRedLayer];

    for (CAShapeLayer *layer in layers) {
        [_secureCanvas.layer addSublayer:layer];
    }

    self.statusLayer = [CATextLayer layer];
    self.statusLayer.alignmentMode = kCAAlignmentCenter;
    self.statusLayer.contentsScale = UIScreen.mainScreen.scale;
    self.statusLayer.zPosition = baseZ + 9;
    self.statusLayer.shadowColor = [UIColor blackColor].CGColor;
    self.statusLayer.shadowOffset = CGSizeMake(2.0, 2.0);
    self.statusLayer.shadowOpacity = 0.86f; 
    self.statusLayer.shadowRadius = 0.0;
    self.statusLayer.actions = @{@"string": NSNull.null, @"hidden": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null, @"foregroundColor": NSNull.null};
    
    [_secureCanvas.layer addSublayer:self.statusLayer];
}

- (void)resetReusableLayers {
    for (NSUInteger i = 0; i < self.activeTextLayerCount; i++) {
        CATextLayer *layer = self.textLayerPool[i];
        if (!layer.hidden) layer.hidden = YES;
    }
    self.activeTextLayerCount = 0;
    
    for (NSUInteger i = 0; i < self.activeImageLayerCount; i++) {
        CALayer *layer = self.imageLayerPool[i];
        if (!layer.hidden) layer.hidden = YES;
    }
    self.activeImageLayerCount = 0;
}

- (CATextLayer *)dequeueTextLayer {
    if (self.activeTextLayerCount < self.textLayerPool.count) {
        CATextLayer *layer = self.textLayerPool[self.activeTextLayerCount];
        if (layer.hidden) layer.hidden = NO;
        self.activeTextLayerCount++;
        return layer;
    } 
    if (self.textLayerPool.count < 300) {
        CATextLayer *layer = [CATextLayer layer];
        layer.contentsScale = UIScreen.mainScreen.scale;
        layer.allowsGroupOpacity = NO; 
        layer.zPosition = 8.5; 
        layer.alignmentMode = kCAAlignmentCenter; 
        layer.shadowOpacity = 0.0; 
        layer.actions = @{ @"position": NSNull.null, @"bounds": NSNull.null, @"string": NSNull.null, @"hidden": NSNull.null, @"foregroundColor": NSNull.null, @"fontSize": NSNull.null };
        [self.textLayerPool addObject:layer];
        [_secureCanvas.layer addSublayer:layer];
        self.activeTextLayerCount++;
        return layer;
    }
    return self.textLayerPool.lastObject;
}

- (CALayer *)dequeueImageLayer {
    if (self.activeImageLayerCount < self.imageLayerPool.count) {
        CALayer *layer = self.imageLayerPool[self.activeImageLayerCount];
        if (layer.hidden) layer.hidden = NO;
        self.activeImageLayerCount++;
        return layer;
    } 
    if (self.imageLayerPool.count < 80) {
        CALayer *layer = [CALayer layer];
        layer.contentsScale = UIScreen.mainScreen.scale;
        layer.contentsGravity = kCAGravityResizeAspect;
        layer.zPosition = 15.0;
        layer.name = @"WeaponIconLayer";
        layer.actions = @{ @"position": NSNull.null, @"bounds": NSNull.null, @"contents": NSNull.null, @"hidden": NSNull.null };
        [self.imageLayerPool addObject:layer];
        [_secureCanvas.layer addSublayer:layer];
        self.activeImageLayerCount++;
        return layer;
    }
    return self.imageLayerPool.lastObject;
}

- (void)addText:(NSString *)text frame:(CGRect)frame color:(UIColor *)color fontSize:(CGFloat)fontSize leftAligned:(BOOL)leftAligned {
    if (text.length == 0) return;
    CATextLayer *layer = [self dequeueTextLayer];
    
    static NSString *fontNameStr = nil;
    if (!fontNameStr) {
        fontNameStr = LoadCountFont(10).fontName; 
    }
    
    layer.font = (__bridge CFTypeRef)fontNameStr;
    if (![layer.string isEqualToString:text]) layer.string = text;
    if (!CGRectEqualToRect(layer.frame, frame)) layer.frame = frame;
    if (!CGColorEqualToColor(layer.foregroundColor, color.CGColor)) {
        layer.foregroundColor = color.CGColor;
    }
    if (layer.fontSize != fontSize) layer.fontSize = fontSize;
    NSString *align = leftAligned ? kCAAlignmentLeft : kCAAlignmentCenter;
    if (layer.alignmentMode != align) layer.alignmentMode = align;
}

- (void)addImage:(UIImage *)image frame:(CGRect)frame {
    if (!image) return;
    CALayer *layer = [self dequeueImageLayer];
    CGImageRef cgImg = image.CGImage;
    if (layer.contents != (__bridge id)cgImg) layer.contents = (__bridge id)cgImg;
    if (!CGRectEqualToRect(layer.frame, frame)) layer.frame = frame;
}

// Monotonic microseconds, for the per-phase render breakdown. Local to the
// render loop so the two timers in this project stay independent.
static inline uint64_t ESPPhaseNowUS(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return (mach_absolute_time() * tb.numer / tb.denom) / 1000ULL;
}

- (void)updateFrame {
    // NOTE: no self.window guard — the view may be an OFFSCREEN data source
    // (host window alpha=0, never visible). The GCD frame timer drives the
    // game reads + the SpringBoard mirror; stopping when not on screen
    // would freeze the SB overlay. The timer itself is the lifecycle.

    @autoreleasepool {
        // ✅ FIX FPS DROP: ESPSyncFromPrefs chỉ gọi mỗi 1 giây, không phải mỗi frame
        static CFTimeInterval lastPrefSync = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastPrefSync > 1.0) {
            ESPSyncFromPrefs();
            lastPrefSync = now;
        }
        // Runs before every early return below, so the log always carries the
        // gate state even when the render path bails out immediately.
        ESPDiagHeartbeat();
        
        // Color / thickness: use synced globals most frames. Re-read prefs only while
        // rainbow is on or ~8×/s so RGB picker still feels live without 16 prefs
        // reads every vsync (that hitch made ESP stutter on Pro).
        {
            static CFTimeInterval s_lastColorPref = 0;
            static int s_liveBoxMode = 0, s_liveLineMode = 0, s_liveBoneMode = 0, s_liveFovMode = 0;
            static float s_liveBoxR = 0, s_liveBoxG = 1, s_liveBoxB = 1;
            static float s_liveLineR = 0, s_liveLineG = 1, s_liveLineB = 1;
            static float s_liveBoneR = 0, s_liveBoneG = 1, s_liveBoneB = 1;
            static float s_liveFovR = 1, s_liveFovG = 1, s_liveFovB = 0;
            const bool anyRainbow =
                (boxColorMode == 1) || (lineColorMode == 1) ||
                (boneColorMode == 1) || (fovColorMode == 1) ||
                (s_liveBoxMode == 1) || (s_liveLineMode == 1) ||
                (s_liveBoneMode == 1) || (s_liveFovMode == 1);
            const bool refreshColorPrefs =
                (s_lastColorPref <= 0.0) ||
                (now - s_lastColorPref > (anyRainbow ? 0.033 : 0.12));
            if (refreshColorPrefs) {
                s_lastColorPref = now;
                s_liveBoxMode  = (int)ESPPrefsFloat(@"BoxColorMode",  (float)boxColorMode);
                s_liveLineMode = (int)ESPPrefsFloat(@"LineColorMode", (float)lineColorMode);
                s_liveBoneMode = (int)ESPPrefsFloat(@"BoneColorMode", (float)boneColorMode);
                s_liveFovMode  = (int)ESPPrefsFloat(@"FovColorMode",  (float)fovColorMode);
                s_liveBoxR = ESPPrefsFloat(@"BoxColorR", boxR);
                s_liveBoxG = ESPPrefsFloat(@"BoxColorG", boxG);
                s_liveBoxB = ESPPrefsFloat(@"BoxColorB", boxB);
                s_liveLineR = ESPPrefsFloat(@"LineColorR", lineR);
                s_liveLineG = ESPPrefsFloat(@"LineColorG", lineG);
                s_liveLineB = ESPPrefsFloat(@"LineColorB", lineB);
                s_liveBoneR = ESPPrefsFloat(@"BoneColorR", boneR);
                s_liveBoneG = ESPPrefsFloat(@"BoneColorG", boneG);
                s_liveBoneB = ESPPrefsFloat(@"BoneColorB", boneB);
                s_liveFovR = ESPPrefsFloat(@"FovColorR", fovR);
                s_liveFovG = ESPPrefsFloat(@"FovColorG", fovG);
                s_liveFovB = ESPPrefsFloat(@"FovColorB", fovB);
            }

            if (isESP2) {
                self.boxLayer.lineWidth = 1.0f;
                self.boxLayer.strokeColor = [UIColor whiteColor].CGColor;
                self.snaplineLayer.lineWidth = 1.0f;
                self.snaplineLayer.strokeColor = [UIColor whiteColor].CGColor;
                self.fovLayer.lineWidth = 0.6f;
                self.fovLayer.strokeColor = [UIColor greenColor].CGColor;
            } else {
                float drawBoxR = s_liveBoxR, drawBoxG = s_liveBoxG, drawBoxB = s_liveBoxB;
                float drawLineR = s_liveLineR, drawLineG = s_liveLineG, drawLineB = s_liveLineB;
                float drawBoneR = s_liveBoneR, drawBoneG = s_liveBoneG, drawBoneB = s_liveBoneB;
                float drawFovR = s_liveFovR, drawFovG = s_liveFovG, drawFovB = s_liveFovB;
                ESPResolveDrawColor(s_liveBoxMode, s_liveBoxR, s_liveBoxG, s_liveBoxB, 0.00f, &drawBoxR, &drawBoxG, &drawBoxB);
                ESPResolveDrawColor(s_liveLineMode, s_liveLineR, s_liveLineG, s_liveLineB, 0.25f, &drawLineR, &drawLineG, &drawLineB);
                ESPResolveDrawColor(s_liveBoneMode, s_liveBoneR, s_liveBoneG, s_liveBoneB, 0.50f, &drawBoneR, &drawBoneG, &drawBoneB);
                ESPResolveDrawColor(s_liveFovMode, s_liveFovR, s_liveFovG, s_liveFovB, 0.75f, &drawFovR, &drawFovG, &drawFovB);

                self.boxLayer.lineWidth = boxThick;
                self.boxLayer.strokeColor = [UIColor colorWithRed:drawBoxR green:drawBoxG blue:drawBoxB alpha:1.0f].CGColor;
                self.boneLayer.lineWidth = boneThick;
                self.boneLayer.strokeColor = [UIColor colorWithRed:drawBoneR green:drawBoneG blue:drawBoneB alpha:1.0f].CGColor;
                self.snaplineLayer.lineWidth = lineThick;
                self.snaplineLayer.strokeColor = [UIColor colorWithRed:drawLineR green:drawLineG blue:drawLineB alpha:1.0f].CGColor;
                self.fovLayer.lineWidth = fovThick;
                self.fovLayer.strokeColor = [UIColor colorWithRed:drawFovR green:drawFovG blue:drawFovB alpha:1.0f].CGColor;
            }
        }

        self.aimAssistLayer.lineWidth = aimAssistThick;
        self.aimAssistLayer.strokeColor = [UIColor colorWithRed:aimAssistR green:aimAssistG blue:aimAssistB alpha:1.0f].CGColor;

        // Keep frame alive when Brutal needs work (ON, still patched, or has saved addrs to restore).
        // Critical: user turns Brutal OFF after leave → must NOT early-return before restore.
        const bool brutalNeedsFrame = Norecoil || g_brutalPatched.load() || g_brutalHasAddrs.load();
        if (!isESP && !isESP2 && !isAimbot && !isAimAssist && !isAimSilent && !isSpeed && !brutalNeedsFrame) {
            [self clearAllContent];
            if (!self.hidden) self.hidden = YES;
            return;
        } else {
            if (self.hidden) self.hidden = NO;
        }

        if (_secureTextField.secureTextEntry != isStreamerMode) {
            NSArray *sublayers = [NSArray arrayWithArray:_secureCanvas.layer.sublayers];
            for (CALayer *layer in sublayers) { [layer removeFromSuperlayer]; }
            
            _secureTextField.secureTextEntry = isStreamerMode;
            [_secureTextField setNeedsLayout];
            [_secureTextField layoutIfNeeded];
            
            _secureCanvas = _secureTextField.subviews.firstObject ?: _secureTextField;
            _secureCanvas.userInteractionEnabled = NO; 
            
            NSArray *layers = @[self.bgFillBlackLayer, self.fovLayer, self.snaplineLayer, self.snaplineBotLayer, self.snaplineKnockedLayer, self.boneLayer, self.boneBotLayer, self.boneKnockedLayer, self.boxLayer, self.boxBotLayer, self.boxKnockedLayer, self.hpFillGreenLayer, self.hpFillOrangeLayer, self.hpFillRedLayer, self.alertLayer, self.aimAssistLayer, self.alertNumBGLayer, self.alertNumGreenLayer, self.alertNumOrangeLayer, self.alertNumRedLayer];
            for (CAShapeLayer *layer in layers) {
                [_secureCanvas.layer addSublayer:layer];
            }
            [_secureCanvas.layer addSublayer:self.statusLayer];
            
            for (CATextLayer *layer in self.textLayerPool) { [layer removeFromSuperlayer]; }
            [self.textLayerPool removeAllObjects];
            self.activeTextLayerCount = 0;
            
            for (CALayer *layer in self.imageLayerPool) { [layer removeFromSuperlayer]; }
            [self.imageLayerPool removeAllObjects];
            self.activeImageLayerCount = 0;
        }

        // Re-attach when HUD opened before game, or game restarted (pid change).
        // Do NOT zero Module_Base when GameFacade probe fails — Brutal/pattern
        // write still needs task; ESP just skips until match pointers resolve.
        {
            static pid_t s_attachedPid = -1;
            static int s_reattachCooldown = 0;
            bool needAttach = (Moudule_Base == (uint64_t)-1 || Moudule_Base == 0 ||
                               !ds_attached() || ds_pid() != s_attachedPid);
            if (needAttach) {
                if (s_reattachCooldown > 0) {
                    s_reattachCooldown--;
                } else {
                    GameOffsetsReload();
                    // DSMemory self-detects FF by name + re-walks the vm_map.
                    uintptr_t base = (uintptr_t)GameTargetModuleBase();
                    if (base != 0 && ds_attached()) {
                        Moudule_Base = (uint64_t)base;
                        s_attachedPid = ds_pid();
                        gEngine = (void *)1; // DSMemory
                        NSLog(@"[ESP] Attached to game PID=%d, Moudule_Base=0x%llx", ds_pid(), (unsigned long long)Moudule_Base);
                    } else {
                        Moudule_Base = 0;
                        s_attachedPid = -1;
                        s_reattachCooldown = 30; // ~0.5s at 60fps — poll game launch
                    }
                }
            }
        }

        [CATransaction begin];
        // Per-phase timing for the render loop. The overlay publishes at about
        // 35fps with a frame cost of 8 to 12ms, so the publish is not what
        // limits the rate any more: the loop that produces the geometry is.
        // This splits that loop into the part that reads the game and builds
        // geometry, the part that pushes it into the CAShapeLayers, and the
        // part that serialises and hands it to SpringBoard, so the next change
        // goes where the time actually is rather than where it is assumed to
        // be. Sampled once a second so the log stays readable.
        const uint64_t tPhase0 = ESPPhaseNowUS();
        [self resetReusableLayers];

        // Free Fire renders landscape. This process never rotates, because it
        // is a background app while the game owns the screen, so self.bounds is
        // permanently the portrait pair (390x844). The projection matrix read
        // out of the game, however, was built for the landscape pair
        // (844x390). Handing the portrait pair to WorldToScreenLayer transposes
        // the axes: horizontal edges come out vertical, and boxes no longer sit
        // on the players. That is the "wrong orientation" report, and it is a
        // space mismatch rather than a drawing bug.
        //
        // An earlier attempt swapped only the matrix and kept the draw space
        // portrait, which is why it was reverted: project and draw have to use
        // the same pair. Both now use landscape, and SpringBoardOverlay maps
        // every point into the portrait layer on serialisation, so the two
        // spaces are converted in exactly one place.
        const CGFloat bw = self.bounds.size.width;
        const CGFloat bh = self.bounds.size.height;
        CGFloat viewWidth  = (bw > bh) ? bw : bh;
        CGFloat viewHeight = (bw > bh) ? bh : bw;
        CGFloat matrixVpW = viewWidth;
        CGFloat matrixVpH = viewHeight;
        if (matrixVpW < 1.0) matrixVpW = 1.0;
        if (matrixVpH < 1.0) matrixVpH = 1.0;

        float halfWidth = viewWidth * 0.5f;
        float halfHeight = viewHeight * 0.5f;
        CGPoint screenCenter = CGPointMake(halfWidth, halfHeight);

        ESPGeometryBuffers buffers = ESPGeometryBuffersCreate();
        g_PlayerDrawIndex = 1;
        // Fl0rk DarkSwordMemoryProvider beginReadTransaction / endReadTransaction:
        // keep remapped pages hot across the whole frame (bones/HP/dict).
        ds_begin_read_transaction();
        ESPFrameStats stats = [self renderESPWithBuffers:&buffers viewWidth:viewWidth viewHeight:viewHeight matrixVpWidth:matrixVpW matrixVpHeight:matrixVpH screenCenter:screenCenter];
        const uint64_t tPhase1 = ESPPhaseNowUS();
        ds_end_read_transaction();
        g_hbLastReal = stats.realCount;
        g_hbLastBot  = stats.botCount;

        bool showVisuals = (isESP || isESP2);
        
        MenuViewApplyPath(self.bgFillBlackLayer, showVisuals ? buffers.bgFillBlackPath : nil, buffers.bgFillBlackDirty);
        MenuViewApplyPath(self.boxLayer, showVisuals ? buffers.boxPath : nil, buffers.boxDirty);
        MenuViewApplyPath(self.boxBotLayer, showVisuals ? buffers.boxBotPath : nil, buffers.boxBotDirty);
        MenuViewApplyPath(self.boxKnockedLayer, showVisuals ? buffers.boxKnockedPath : nil, buffers.boxKnockedDirty);
        MenuViewApplyPath(self.boneLayer, showVisuals ? buffers.bonePath : nil, buffers.boneDirty);
        MenuViewApplyPath(self.boneBotLayer, showVisuals ? buffers.boneBotPath : nil, buffers.boneBotDirty);         
        MenuViewApplyPath(self.boneKnockedLayer, showVisuals ? buffers.boneKnockedPath : nil, buffers.boneKnockedDirty); 
        MenuViewApplyPath(self.snaplineLayer, showVisuals ? buffers.snaplinePath : nil, buffers.snaplineDirty);
        MenuViewApplyPath(self.snaplineBotLayer, showVisuals ? buffers.snaplineBotPath : nil, buffers.snaplineBotDirty);
        MenuViewApplyPath(self.snaplineKnockedLayer, showVisuals ? buffers.snaplineKnockedPath : nil, buffers.snaplineKnockedDirty);
        MenuViewApplyPath(self.hpFillGreenLayer, showVisuals ? buffers.hpFillGreenPath : nil, buffers.hpFillGreenDirty);
        MenuViewApplyPath(self.hpFillOrangeLayer, showVisuals ? buffers.hpFillOrangePath : nil, buffers.hpFillOrangeDirty);
        MenuViewApplyPath(self.hpFillRedLayer, showVisuals ? buffers.hpFillRedPath : nil, buffers.hpFillRedDirty);
        MenuViewApplyPath(self.alertLayer, showVisuals ? buffers.alertPath : nil, buffers.alertDirty);
        // The nickname glyphs. Gated on the same showVisuals as everything else,
        // so turning the ESP off stops publishing names as well as boxes, and on
        // the same dirty flag the others use, so a frame that drew no names costs
        // nothing and a frame that did replaces the path.
        MenuViewApplyPath(self.nameTextLayer, showVisuals ? buffers.nameTextPath : nil, buffers.nameTextDirty);

        // The dirty flags are read by the [APP-LAYER] diagnostic further down,
        // which runs after ESPGeometryBuffersRelease has freed the paths, so
        // they are copied here while the buffers are still alive.
        static int s_dirtyBox = 0, s_dirtyBone = 0, s_dirtySnap = 0, s_dirtyHpG = 0;
        s_dirtyBox = buffers.boxDirty;
        s_dirtyBone = buffers.boneDirty;
        s_dirtySnap = buffers.snaplineDirty;
        s_dirtyHpG  = buffers.hpFillGreenDirty;



        if (showVisuals && stats.aimAssistPath) {
            MenuViewApplyPath(self.aimAssistLayer, stats.aimAssistPath, YES);
            CGPathRelease(stats.aimAssistPath);
        } else {
            self.aimAssistLayer.path = nil;
        }

        ESPGeometryBuffersRelease(&buffers);

        CGMutablePathRef fovPath = CGPathCreateMutable();
        // Drawn only where the ring is a true statement, which is exactly where
        // the aim is gated by it: aimFovSq at esp.mm:4067 is (isAimbot &&
        // !useSphereAim) ? aimFov^2 : 0.
        //
        // Everywhere else the circle was a picture of a bound that did not exist,
        // which is what "the aim does not follow the FOV" looks like from the
        // ground: Aim Type on Assist alone gates by assistRadius (12% of the
        // screen height), Aim Range 180 gates by inFront, 360 and silent-sphere
        // gate by nothing at all. A small ring with a big reach reads as the aim
        // ignoring the slider, and it was.
        //
        // ShowFovCircle is still the user's switch; this only refuses to draw a
        // circle for a mode that does not use one. The app's ESP/AIM screen
        // already turns the ring off when Aim Type is switched to Assist, so this
        // is the same rule enforced on the engine side where it cannot be skipped.
        const BOOL fovBoundsAim = isShowFovCircle && isAimbot && aimSphereMode == 0;
        BOOL hasFov = RenderFOVCirclePath(fovPath, viewWidth, viewHeight,
                                          fovBoundsAim, fovSize);
        self.fovLayer.path = hasFov ? fovPath : nil;
        CGPathRelease(fovPath);

        // Every layer has now been assigned, fovLayer and aimAssistLayer
        // included, so this is the first point at which the counts describe
        // the frame on screen rather than the one before it.
        {
            static uint32_t s_layerLogTick = 0;
            if ((++s_layerLogTick % 60u) == 1u) {
                ESPPathCountCtx bx = {0,0}, bn = {0,0}, sn = {0,0}, fv = {0,0}, am = {0,0};
                CGPathApply(self.boxLayer.path, &bx, espCountPathElements);
                CGPathApply(self.boneLayer.path, &bn, espCountPathElements);
                CGPathApply(self.snaplineLayer.path, &sn, espCountPathElements);
                CGPathApply(self.fovLayer.path, &fv, espCountPathElements);
                CGPathApply(self.aimAssistLayer.path, &am, espCountPathElements);
                NSLog(@"[APP-LAYER] esp=%d esp2=%d box=%d line=%d bone=%d hp=%d show=%d | "
                      @"box=%u/%u bone=%u/%u snap=%u/%u fov=%u/%u aim=%u/%u | "
                      @"dirty box=%d bone=%d snap=%d hpG=%d fovNil=%d aimNil=%d",
                      (int)isESP, (int)isESP2, (int)isBox, (int)isLine, (int)isBone, (int)isHealth,
                      (int)showVisuals,
                      bx.n, bx.curves, bn.n, bn.curves, sn.n, sn.curves,
                      fv.n, fv.curves, am.n, am.curves,
                      (int)s_dirtyBox, (int)s_dirtyBone,
                      (int)s_dirtySnap, (int)s_dirtyHpG,
                      (int)(self.fovLayer.path == nil), (int)(self.aimAssistLayer.path == nil));
            }
        }

        if (isCount) {
            NSString *countText;
            UIColor *countColor;
            CGFloat fontSize;

            // Red, and only red, for the count. It used to be green for the
            // number and cyan or green for the word CLEAR, so the one thing on
            // screen whose job is to be read at a glance was the only thing
            // carrying three colours. Red is also the one that survives a bright
            // sky, which is what most of these matches look like.
            UIColor *redText = [UIColor colorWithRed:1.0f green:0.0f blue:0.0f alpha:1.0f];

            if (stats.realCount == 0 && stats.botCount == 0 && !stats.inMatch) {
                // "--" only when there is no match to count, which is a different
                // statement from "in a match with nobody in it". The two shared one
                // branch and printed the same thing, so an empty lobby was
                // indistinguishable from a game that had not loaded. Inside a match
                // this falls through to the number below and prints 0, which is
                // what a count of nobody looks like.
                countText = @"--";
                countColor = redText;
                fontSize = 25.0f;
            } else {
                // Just the number. This used to be "PLAYER [x] | BOT [y]" on the
                // main path and plain "%d" on the Lite path, so the two ESP
                // modes reported the same fact in two different shapes, and the
                // longer one was 220 points wide for six glyphs' worth of
                // information. A count is one number: real and bot are already
                // distinguished on the box, which is what those two figures were
                // for.
                countText = [NSString stringWithFormat:@"%d", stats.realCount + stats.botCount];
                countColor = redText;
                fontSize = 25.0f;
            }

            if (![self.lastStatusString isEqualToString:countText]) {
                self.lastStatusString = countText;
                self.statusLayer.string = countText;
                self.statusLayer.foregroundColor = countColor.CGColor;
                self.statusLayer.fontSize = fontSize;
                self.statusLayer.font = (__bridge CFTypeRef)LoadCountFont(fontSize).fontName;
            }

            // Tight frame around text only (was 200x50) — visual only; CATextLayer
            // never receives touches, but keep bounds small and non-interactive flags set.
            // 90, down from 220. The frame is sized for the string it holds and
            // the string is one or three glyphs now, and CATextLayer centres
            // within it, so the number lands in the same place either way. What
            // changes is the band the overlay derives from it: the quarter turn
            // turns the frame's width into the portrait rect's height, so 220
            // was a 220 point tall band on a 390 point screen for a 25 point
            // number.
            CGFloat countWidth = 90.0f;
            CGFloat countHeight = fontSize + 8.0f;
            CGFloat yPos = isESP2 ? 30.0f : 25.0f;
            CGFloat xPos = halfWidth - (countWidth * 0.5f);

            CGRect newStatusFrame = CGRectMake(xPos, yPos, countWidth, countHeight);
            if (!CGRectEqualToRect(self.statusLayer.frame, newStatusFrame)) {
                self.statusLayer.frame = newStatusFrame;
            }
            self.statusLayer.masksToBounds = NO;
            // CALayer has no userInteraction; ensure parent views stay pass-through.
            if (self.statusLayer.hidden) self.statusLayer.hidden = NO;
        } else {
            if (!self.statusLayer.hidden) self.statusLayer.hidden = YES;
        }

        const uint64_t tPhase2 = ESPPhaseNowUS();

        [CATransaction commit];

        // Mirror this frame to the SpringBoard dedicated overlay (if active).
        extern void SBRemotePushESPFrame(UIView *espView);
        SBRemotePushESPFrame(self);

        {
            const uint64_t tPhase3 = ESPPhaseNowUS();
            static uint64_t s_phUS = 0;
            static uint32_t s_phFrames = 0;
            static uint64_t s_phRender = 0, s_phLayer = 0, s_phPush = 0;
            s_phFrames++;
            s_phRender  += (tPhase1 - tPhase0);
            s_phLayer   += (tPhase2 - tPhase1);
            s_phPush    += (tPhase3 - tPhase2);
            if (tPhase3 > s_phUS + 1000000ULL) {
                const uint32_t n = s_phFrames ? s_phFrames : 1;
                NSLog(@"[PUSH-PHASE] fps=%u read=%.2fms layer=%.2fms push=%.2fms total=%.2fms",
                      (unsigned)s_phFrames,
                      (double)s_phRender / (double)n / 1000.0,
                      (double)s_phLayer / (double)n / 1000.0,
                      (double)s_phPush / (double)n / 1000.0,
                      (double)(s_phRender + s_phLayer + s_phPush) / (double)n / 1000.0);
                s_phUS = tPhase3;
                s_phFrames = 0;
                s_phRender = s_phLayer = s_phPush = 0;
            }
        }
    }
}

// Hysteresis table behind the enemy count. See the tally at the end of the pawn
// loop: a pawn counts if it was drawn recently, not only if it is drawn now.
//
// The keys are user ids where the pawn has one, because the player dictionary
// can name the same pawn twice and two entries for one player is a number that
// disagrees with the boxes beside it. Entries are never removed; they age out,
// and a match restart ages everything out within the hold window on its own.
#define ESP_COUNT_HOLD_FRAMES 3
static uint64_t s_espCountKey[192]  = {0};
static int64_t  s_espCountFrame[192] = {0};
static uint8_t  s_espCountBot[192]   = {0};
static int      s_espCountN = 0;

// The local player's identity, cached.
//
// "Enemy" is decided by comparing a pawn against these, not against a read of
// match->localPlayer taken this frame. The report that sent this in: team of 2,
// both alive, the counter says 3; only I die, it says 4. A counter that moves
// when the local player dies is counting the local player, because
// match->localPlayer stops being usable at exactly that moment.
//
// A field is only ever written from a non-zero read, so a failed read keeps the
// last good value instead of erasing it. Cleared at the match -> lobby edge,
// which is the only place the identity legitimately belongs to a different
// player. See the block in the collect loop.
static uint64_t s_locUid  = 0;
static int64_t  s_locPid  = 0;
static int      s_locTeam = 0;

// Age an entry out of the count on the spot.
//
// The tally is stamped in the draw pass BEFORE the drawing branches, because
// it needs isOnScreen and the frame stamp. Three of those branches can then
// bail out with continue and draw nothing at all, and everything stamped
// before that point still counted. That is the whole of "2 enemies, 2 boxes,
// the counter says 3": the third pawn passes wantDraw, gets stamped, and then
// hits one of these:
//
//   esp.mm, Lite ESP:  head bone unreadable  -> no box at all
//   esp.mm, Pro ESP:   s.curHP <= 0          -> no box at all
//
// and the second one is a permanent +1 rather than a flicker: a knocked player
// is alive with HP 0, wantDraw lets it through, Pro then refuses to draw it,
// and the number sits one above the boxes for as long as that player is down.
//
// Stamping it and then dropping it is not a workaround for the number, it is
// what "the counter counts the boxes" means: a pawn that reaches no drawing
// code has to stop counting the frame it reached none.
//
// The frame is set far enough back that the 3-frame hold skips it now, rather
// than deleting the slot, so the entry is still there to be reused -- and the
// stalest-slot reuse picks exactly this one first.
static void esp_count_drop(uint64_t key) {
    for (int ci = 0; ci < s_espCountN; ci++) {
        if (s_espCountKey[ci] == key) {
            s_espCountFrame[ci] = INT64_MIN / 2;
            return;
        }
    }
}

// Live pawns inside the draw limit whose projection is outside the viewport: not
// drawn, so not counted. Reset per frame where the draw pass runs.
static int      s_countOffScreen = 0;

// Pawns refused because their team has never been read successfully. Non-zero
// means the fail-closed teammate test is withholding pawns, which is the cost of
// it and the thing to watch: if this climbs and stays up, reads are not healthy
// and the counter is under-reporting for that reason rather than over-reporting.
static int      s_countTeamUnknown = 0;

// ---------------------------------------------------------------------------
// The one status line.
//
// Every diagnosable number is published here by whichever stage last touched it, and
// printed once a second on one tag. It was three: [DS-TLB] from the cache, [ESP-COUNT]
// and [ESP-DICT] from the roster walk.
//
// Three tags means three filters, and the device log view had room for one. That is
// not only inconvenient: the fields that answer a single question were on different
// tags. The cache hit rate and the number of players found are the two halves of "is
// the shortfall the cache or the walk", and separating them across two filters is what
// made that question need two screenshots and a judgement call about which screenshot
// was more recent.
//
// Publishing rather than printing at each site is what makes one line possible. The
// walk finishes long after the cache counters were sampled, and the reject paths
// return before any walk happens at all, so whichever site printed would be the one to
// go quiet exactly when the failure is happening -- a reporter that prints on the
// successful path is a reporter that only ever confirms success.
//
// Field meanings, carried over from the log each of these came out of:
//
//   gate     0 = the dictionary was walked. Non-zero = it was not, and the low bits
//            say why: bit 0 capacity read 0, 1 above the plausible maximum, 2 smaller
//            than the live count, 3 too sparse for the live count, 4 the live count
//            itself out of range. 2 = the dictionary held no live entries at all.
//            3 = there is no match yet.
//            While gate != 0 the roster fields are the last successful walk, not this
//            frame. That distinction is the whole match-pickup question: "the
//            dictionary found nobody" and "the dictionary was never consulted" print
//            identical numbers otherwise.
//   cap      Il2CppArray.max_length -- capacity, roughly 1.3-2x the live count
//   dc       dictCount, the live entries the dictionary says it holds
//   walk     slots iterated after the clamp, i.e. min(cap, kMaxWalkSlots)
//   clamped  the walk ended on kMaxWalkSlots rather than on the live count
//   iters    loop iterations performed, i.e. walk minus an early exit on dc
//   read     slots among those iterations that were not free markers
//   live     pawns accepted after the duplicate filter
//   dup      slots naming a pawn an earlier slot already named
//   probe    pawns whose value did not read at the documented entry offset and came
//            from a layout-probe offset instead (0x10/0x18 sit inside the key, so
//            this is the widest remaining phantom surface)
//   stopLive the walk ended on dictCount, which is the NORMAL end of a walk
//   drop     pawns refused because the snapshot buffer was full
//   off      live pawns inside the draw limit whose projection left the viewport
//   team?    pawns refused because their team has never read successfully
//   cache    hit/miss/remap/evict/novictim are per second; stale, orphan and sweeps
//            are cumulative, and sweeps stopping is how you know the dead-mapping
//            check stopped running
//
// The invariant the phantom budget guarantees, and the first thing to check when live
// is short: live <= read <= dc.
// Where the walked pawns went, one counter per exit from the pawn loop.
//
// The status line reports live=47 and snapN=1, and nothing anywhere said why the other
// 46 are not in the snapshot. Fifteen filters sit between those numbers, most gated on
// whether a read landed, and every one of them drops the pawn silently -- the frame is
// simply shorter. That is the hole: "some players have no ESP and cannot be aimed at"
// was indistinguishable from "some players were filtered out for a reason nobody
// recorded", which is why several rounds of fixes have been argued from inference
// rather than from the number.
//
// Each counter is a claim to be checked against the others, not a guess at which filter
// matters. banned high means a tombstone is outliving its pawn. hpUnread high means
// reads are failing where they matter. far high means nobody is in range and there is
// nothing to fix. dead high is a real death and is the one counter that should look
// like a kill feed. The sum is the answer: live minus the sum should be snapN, plus
// whatever the team and distance gates kept out of the count for their own reasons.
struct PawnRejects {
    int banned, hpUnread, dead, hpBad, noUid;
    int noAnchor, collapsed, noBone, noHead, origin, headFar;
    int far, near, hpZero, team, self;
};

struct EspStatusLine {
    uint64_t match, dict, local;
    int slotCap, dictCount, walk, clamped, iters;
    int readSlots, live, dupes, probe, stopLive, snapDrop, snapN;
    int real, bots, offScreen, teamUnknown, selfSkip;
    int gate;
    float dmin, dmax;
    uint64_t aimTarget;
    PawnRejects rej;
};
static EspStatusLine g_st;

static void EspEmitStatusLine(void) {
    static CFTimeInterval s_last = 0;
    const CFTimeInterval now = CACurrentMediaTime();
    if ((now - s_last) < 1.0) return;
    s_last = now;

    DSPageCacheStats cs;
    ds_page_cache_stats(&cs);
    static uint64_t pRemap, pEvict, pHit, pMiss, pNoVictim;
    const uint64_t dRemap  = cs.remaps   - pRemap;
    const uint64_t dEvict  = cs.evicts   - pEvict;
    const uint64_t dHit    = cs.hits     - pHit;
    const uint64_t dMiss   = cs.misses   - pMiss;
    const uint64_t dNoVict = cs.novictim - pNoVictim;
    pRemap = cs.remaps; pEvict = cs.evicts; pHit = cs.hits;
    pMiss = cs.misses; pNoVictim = cs.novictim;

    NSLog(@"[ESP] gate=%d match=0x%llx dict=0x%llx local=0x%llx "
          @"cap=%d dc=%d walk=%d clamped=%d iters=%d read=%d live=%d dup=%d "
          @"probe=%d stopLive=%d drop=%d snapN=%d real=%d bot=%d off=%d team?=0x%x "
          @"self=%d dmin=%.1f dmax=%.1f aim=0x%llx "
          @"rej{self=%d team=%d banned=%d hpUnread=%d dead=%d hpBad=%d noUid=%d "
          @"noAnchor=%d collapsed=%d noBone=%d noHead=%d origin=%d headFar=%d "
          @"far=%d near=%d hpZero=%d} "
          @"cache{slots=%d hit=%llu miss=%llu remap=%llu evict=%llu novictim=%llu "
          @"stale=%llu orphan=%llu blind=%d sweeps=%llu deg=%d blk=%d}",
          g_st.gate,
          (unsigned long long)g_st.match, (unsigned long long)g_st.dict,
          (unsigned long long)g_st.local,
          g_st.slotCap, g_st.dictCount, g_st.walk, g_st.clamped, g_st.iters,
          g_st.readSlots, g_st.live, g_st.dupes, g_st.probe, g_st.stopLive,
          g_st.snapDrop, g_st.snapN, g_st.real, g_st.bots, g_st.offScreen,
          g_st.teamUnknown, g_st.selfSkip,
          (double)g_st.dmin, (double)g_st.dmax,
          (unsigned long long)g_st.aimTarget,
          g_st.rej.self, g_st.rej.team, g_st.rej.banned, g_st.rej.hpUnread,
          g_st.rej.dead, g_st.rej.hpBad, g_st.rej.noUid, g_st.rej.noAnchor,
          g_st.rej.collapsed, g_st.rej.noBone, g_st.rej.noHead, g_st.rej.origin,
          g_st.rej.headFar, g_st.rej.far, g_st.rej.near, g_st.rej.hpZero,
          cs.liveSlots,
          (unsigned long long)dHit, (unsigned long long)dMiss,
          (unsigned long long)dRemap, (unsigned long long)dEvict,
          (unsigned long long)dNoVict,
          (unsigned long long)cs.staleDrops, (unsigned long long)cs.orphanDrops,
          cs.blind, (unsigned long long)cs.sweeps,
          cs.degradeActive, cs.blockedLastSecond);
}

- (ESPFrameStats)renderESPWithBuffers:(ESPGeometryBuffers *)buffers
                            viewWidth:(CGFloat)viewWidth
                           viewHeight:(CGFloat)viewHeight
                        matrixVpWidth:(CGFloat)matrixVpWidth
                       matrixVpHeight:(CGFloat)matrixVpHeight
                         screenCenter:(CGPoint)screenCenter
{
    ESPFrameStats stats = {0, 0, false, NULL};
    stats.aimAssistPath = CGPathCreateMutable();
    // Before anything can return. The reject paths below are precisely the ones worth
    // watching -- they are why a match sometimes is not picked up -- and a reporter
    // sitting after them prints nothing at all while the failure is in progress.
    EspEmitStatusLine();

    g_cacheFrameCounter++;          // Tăng frame counter mỗi lần render (dùng cho cache)

    CGMutablePathRef aNumBGPath = CGPathCreateMutable();
    CGMutablePathRef aNumGPath  = CGPathCreateMutable();
    CGMutablePathRef aNumOPath  = CGPathCreateMutable();
    CGMutablePathRef aNumRPath  = CGPathCreateMutable();

    if (!buffers || Moudule_Base == 0 || Moudule_Base == (uint64_t)-1) {
        DIAG_EARLY(@"no-base");
        return stats;
    }

    uint64_t matchGame = getMatchGame(Moudule_Base);
    uint64_t camera = isVaildPtr(matchGame) ? CameraMain(matchGame) : 0;
    uint64_t match  = isVaildPtr(matchGame) ? getMatch(matchGame) : 0;

    // The end of a match is the mirror image of the start of one, and it was the
    // one the cache never saw.
    //
    // On the way in there is a flush, further down, keyed on `match` becoming
    // valid. On the way out the function returns at the lobby check above, before
    // reaching it, so every page mapping stayed alive across the teardown: the
    // game destroys the scene's vm_objects and DSMemory keeps handing those
    // mappings back on a bare VA match, with no re-validation (ds_page_local).
    // Reading a freed vm_object through a shmem mapping is what gets the process
    // killed on the way out of a match.
    //
    // Once per transition, never per frame — DSMemory.m records that a per-frame
    // flush caused "Taking non-sleepable RW lock" panics.
    static uint64_t s_lastLiveMatch = 0;
    // Declared here rather than inside the flush block below, which runs after
    // this one and is reset by it when a match ends.
    static uint64_t s_lastMatchDiag = 0;
    // The MatchGame pointer, which is what the flush below keys on. `match` is a
    // recycled address and cannot be; see the block that uses this.
    static uint64_t s_lastMatchGame = 0;
    {
        const bool live = isVaildPtr(match);
        if (s_lastLiveMatch != 0 && !live) {
            const uint64_t left = s_lastLiveMatch;
            // First, while the mappings are still good: give the game back the
            // string pointers we replaced, so its teardown does not free memory it
            // never allocated. See RainbowNameDetach.
            RainbowNameDetach();
            ds_flush_page_cache();
            ds_cache_bump_generation();
            // The count is a table of pawn pointers with a frame hold; a pawn from
            // the match that just ended is not a live enemy in the lobby.
            s_espCountN = 0;
            // Same for the cached local identity: it described a player in the
            // match that just ended, and carrying it into the lobby would filter
            // the lobby's first pawns against a stranger's uid and team.
            s_locUid = 0;
            s_locPid = 0;
            s_locTeam = 0;
            memset(s_espCountFrame, 0, sizeof(s_espCountFrame));
            memset(s_espCountBot, 0, sizeof(s_espCountBot));
            gAimLockTarget = 0;
            gAimLockLostFrames = 0;
            s_lockHoldFrames = 0;
            AimLockClear();
            // Reset so the flush on the way into the next match runs again.
            s_lastMatchDiag = 0;
            s_lastMatchGame = 0;
            s_lastLiveMatch = 0;
            // The plate and the names live on CAShapeLayers in SpringBoard that
            // keep whatever path they were last handed, and the publish that
            // clears them stops running the moment the ESP goes silent — which is
            // exactly what a match ending does. Without this the dark plate stays
            // on screen for the rest of the session.
            SBClearESPNameLayers();
            NSLog(@"[PUSH-FLUSH] left match 0x%llx — page cache dropped, locks and names cleared",
                  (unsigned long long)left);
        } else if (live) {
            s_lastLiveMatch = match;
        }
    }

    if (!isVaildPtr(matchGame)) {
        static int s_lobbyLog = 0;
        if (++s_lobbyLog % 300 == 1) {
            NSLog(@"[ESP] Lobby mode: waiting for match...");
        }
        DIAG_EARLY(@"lobby");
        return stats;
    }

    if (!isVaildPtr(camera) || !isVaildPtr(match)) {
        DIAG_EARLY(@"loading-match");
        return stats;
    }

    static int s_okLog = 0;
    if (++s_okLog % 300 == 1) {
        NSLog(@"[ESP] >>> IN-MATCH ACTIVE: matchGame=0x%llx, match=0x%llx, camera=0x%llx <<<",
              (unsigned long long)matchGame, (unsigned long long)match, (unsigned long long)camera);
    }

    // A new match tears the game's address space down and rebuilds it. Every
    // page mapping we hold aliases a vm_object the game has already freed, and
    // nothing else invalidates them (ds_detach only runs on a pid change). The
    // symptom of holding those is ESP frozen on screen: the boxes are the same
    // pixels every frame because the data behind them is the same freed memory.
    // Report it rather than guess: staleGen > 0 means the cache crossed a match.
    {
        // s_lastMatchDiag and s_lastMatchGame are declared above, at the match ->
        // lobby transition, which resets them so this fires again for the next
        // match.
        //
        // The trigger is matchGame, and `match` is the reason it was not before.
        //
        // `match` is a recycled address. When a match ends the game frees the
        // Match object, and the next match's Match can land on the same VA, so
        // `match` compares equal straight across the boundary and the whole block
        // is skipped. That is measured, not guessed: the comment this replaces
        // records that the previous attempt hung the flush off `match` changing
        // and that "the 19:51 log proved it never fires" -- mt=0x13d66e800 was
        // constant for the whole window with zero [PUSH-FLUSH] lines.
        //
        // A skipped flush is the whole bug. A page slot pins one shmem mapping
        // made by the kernel remap, and ds_page_local re-serves that slot on a
        // bare VA match with no re-validation and no age. So every mapping from
        // the finished match keeps answering with the bytes it was taken with,
        // the chain reads the lobby's values, getMatchGame returns 0, the lobby
        // gate below trips, and both this block and the leave-edge detector above
        // become unreachable. The ESP then never picks the next match up, for the
        // rest of the session, and carries it into the match after that.
        //
        // matchGame is the head of that chain and is re-read every frame from the
        // statics block, so it is what actually differs across a boundary.
        //
        // Once per match, never per frame: both keys are written below every frame
        // this block is reached at all -- which is only past the lobby gate and the
        // camera/match check above, so never in a lobby -- and firstMatch goes
        // false the moment the keys are set. The DSMemory.m:410 note about per-frame
        // flushes causing RW-lock panics still applies, and this does not become
        // that: a changed matchGame is one flush, and the keys move immediately.
        const bool firstMatch    = (s_lastMatchDiag == 0);
        const bool newMatchGame  = (s_lastMatchGame != 0 && matchGame != s_lastMatchGame);
        if (firstMatch || newMatchGame) {
            DSPageCacheDiag before = ds_page_cache_diag();
            ds_flush_page_cache();
            DSPageCacheDiag after = ds_page_cache_diag();
            NSLog(@"[PUSH-FLUSH] first=%d match 0x%llx->0x%llx matchGame 0x%llx->0x%llx "
                  @"dropped live=%d stale=%d now live=%d",
                  (int)firstMatch, (unsigned long long)s_lastMatchDiag,
                  (unsigned long long)match,
                  (unsigned long long)s_lastMatchGame,
                  (unsigned long long)matchGame,
                  before.liveSlots, before.staleGen, after.liveSlots);
            ds_cache_bump_generation();
        }
        s_lastMatchDiag = match;
        s_lastMatchGame = matchGame;
        static CFTimeInterval s_cacheLog = 0;
        CFTimeInterval nowC = CACurrentMediaTime();
        if (nowC - s_cacheLog > 5.0) {
            s_cacheLog = nowC;
            DSPageCacheDiag cd = ds_page_cache_diag();
            NSLog(@"[DS] DIAG cache gen=%llu live=%d staleGen=%d",
                  (unsigned long long)cd.generation, cd.liveSlots, cd.staleGen);
        }
    }

    uint64_t myPawnObject = getLocalPlayer(match);

    int curHp = isVaildPtr(myPawnObject) ? get_CurHP(myPawnObject) : 0;
    bool iAmAlive = isVaildPtr(myPawnObject) && (curHp >= 0);

    // Speed — Brutal run scale (slider) + menu Speed.
    // Brutal ON: hold BrutalSpeed (default 0.16). Menu Speed only when Brutal OFF.
    // Jitter fix: do NOT thrash RunSpeed every frame / fight pattern with hard clamps.
    // Only re-write when value drifts; never clamp weapon while Brutal is on.
    if (isVaildPtr(myPawnObject)) {
        static int s_speedTick = 0;
        static float s_lastRunWrite = -1.0f;
        static uint64_t s_lastAttrs = 0;
        const uint64_t attrsOff = kPlayerAttributes ? kPlayerAttributes : 0x700;
        const uint64_t runOff   = kRunSpeedUpScale ? kRunSpeedUpScale : 0x270;
        const uint64_t fallOff  = 0x26C;
        const uint64_t forceOff = 0x340;
        const uint64_t weapOff  = 0x130;
        uint64_t PlayerAttributes = ReadAddr<uint64_t>(myPawnObject + attrsOff);
        if (isVaildPtr(PlayerAttributes) && PlayerAttributes != 0) {
            ++s_speedTick;
            if (PlayerAttributes != s_lastAttrs) {
                s_lastAttrs = PlayerAttributes;
                s_lastRunWrite = -1.0f; // new attrs object → re-seed
            }

            // Brutal: speedvalue from BrutalSpeed pref. Else menu Speed scale / 1.0.
            float writeVal = speedvalue;
            if (!Norecoil && isSpeed && moveSpeedScale > 1.0f) {
                writeVal = moveSpeedScale;
                if (writeVal > 1.28f) writeVal = 1.28f;
            }
            if (writeVal <= 0.0f) writeVal = 1.0f;

            // Hold run scale without per-frame spam (spam = giật khi chạy).
            // Re-assert only when drifted or first write on this attrs.
            float cur = ReadAddr<float>(PlayerAttributes + runOff);
            const bool curBad = isnan(cur) || cur < 0.01f || cur > 80.0f;
            const float drift = (!curBad && s_lastRunWrite > 0.0f) ? fabsf(cur - writeVal) : 999.0f;
            // Brutal: looser hold — game/pattern micro-updates shouldn't thrash us.
            // Menu speed: tighter so boost stays accurate.
            const float reassertEps = Norecoil ? 0.04f : 0.015f;
            const bool needWrite =
                curBad ||
                s_lastRunWrite < 0.0f ||
                fabsf(s_lastRunWrite - writeVal) > 0.001f || // slider changed
                drift > reassertEps ||
                // Soft emergency: only insane turbo, not pattern micro bumps.
                (!curBad && cur > (Norecoil ? 12.0f : 3.0f));

            // Cadence: Brutal re-check every 3 frames max; Speed every frame if needed.
            const int cadence = Norecoil ? 3 : 1;
            if (needWrite && (Norecoil ? ((s_speedTick % cadence) == 0) : true)) {
                WriteAddr<float>(PlayerAttributes + runOff, writeVal);
                s_lastRunWrite = writeVal;
            }

            // Force absolute OFF occasionally — not every frame.
            // IMPORTANT: while Brutal is ON, do NOT clamp weapon scale (0x130).
            // Pattern scan is super-fast fire — resetting weap→1.0 killed it.
            // Also: do NOT touch fall while Brutal ON (fall clamp caused run hitch).
            if ((s_speedTick % 16) == 0) {
                float force = ReadAddr<float>(PlayerAttributes + forceOff);
                if (!isnan(force) && fabsf(force) > 0.001f)
                    WriteAddr<float>(PlayerAttributes + forceOff, 0.0f);

                if (!Norecoil && writeVal <= 1.001f) {
                    // Normal / no-speed only: clean leftover turbo after Brutal OFF.
                    float f = ReadAddr<float>(PlayerAttributes + fallOff);
                    if (!isnan(f) && f > 1.05f && f < 50.0f)
                        WriteAddr<float>(PlayerAttributes + fallOff, 1.0f);
                    float w = ReadAddr<float>(PlayerAttributes + weapOff);
                    if (!isnan(w) && w > 1.05f && w < 50.0f)
                        WriteAddr<float>(PlayerAttributes + weapOff, 1.0f);
                }
            }
            (void)fallOff;
            (void)weapOff;
        }
    }


    if (g_target_task == 0) {
        pid_t pid = (pid_t)GameTargetProcessPid();
        if (pid > 0) task_for_pid(mach_task_self(), pid, &g_target_task);
    }
    
    if (iAmAlive) {
        static uint64_t rainbowPtrs[7] = {0};
        static NSString *cachedCustomName = nil;

        if (s_setNameEnabledGlobal && g_target_task != 0) {
            if (!g_rainbowInit || ![s_customNameGlobal isEqualToString:cachedCustomName]) {
                uint64_t originalStrPtr = ReadAddr<uint64_t>(myPawnObject + kNickname);
                if (isVaildPtr(originalStrPtr)) {
                    // Recorded before the first substitution, so there is
                    // something to put back. See RainbowNameDetach.
                    g_rainbowOrigNick = originalStrPtr;
                    g_rainbowOrigNickDisp = ReadAddr<uint64_t>(myPawnObject + kNicknameDisplay);
                    g_rainbowPawn = myPawnObject;
                    for(int offset = 0; offset < 7; offset++) {
                        NSString *animatedName = GenerateRainbowString(s_customNameGlobal, offset);
                        rainbowPtrs[offset] = AllocateMonoString(g_target_task, originalStrPtr, animatedName);
                    }
                    cachedCustomName = s_customNameGlobal;
                    g_rainbowInit = 1;
                }
            }

            static int colorTick = 0;
            static int colorIndex = 0;
            if (g_rainbowInit) {
                if (colorTick++ % 15 == 0) { colorIndex = (colorIndex + 1) % 7; }
                if (rainbowPtrs[colorIndex] != 0) {
                    WriteAddr<uint64_t>(myPawnObject + kNickname, rainbowPtrs[colorIndex]);
                    WriteAddr<uint64_t>(myPawnObject + kNicknameDisplay, rainbowPtrs[colorIndex]);
                }
            }
        }

        bool actualFastReload = isFastReload && (fastReloadSpeed > 1.0f);
        EnableFastReload(myPawnObject, actualFastReload, fastReloadSpeed);
        // Kill vanilla AA (strength + AllOff). The switch is the whole decision now:
        // ON kills it every frame, OFF leaves the game's magnet alone even while
        // aimbot or assist is firing, which is what "off" has to mean or the switch
        // reads as broken. Aimbot and aim assist are unaffected either way -- they
        // write their own rotations, and this only decides whether the game is also
        // stomping on them at the same moment.
        DisableGameDefaultAimAssist(myPawnObject, isKillGameAA);

        // DIAG (once per 5s): confirm the cheat apply-path is actually running.
        {
            static CFTimeInterval s_lastDiag = 0;
            CFTimeInterval nowD = CACurrentMediaTime();
            if (nowD - s_lastDiag > 5.0) {
                s_lastDiag = nowD;
                NSLog(@"[DIAG] pawn=%llu alive=%d",
                      (unsigned long long)myPawnObject, (int)(isVaildPtr(myPawnObject) && get_CurHP(myPawnObject) > 0));

                // Is the view matrix actually LIVE? Print the first row and the
                // two rows W2S divides by. If these are byte-identical across
                // samples while the camera moves, the matrix is frozen and the
                // projection -- not the drawing -- is what is stuck.
                {
                    float m[16];
                    if (GetViewMatrixInto(camera, m)) {
                        NSLog(@"[DIAG] VP m0=%.4f m1=%.4f m2=%.4f m3=%.4f m12=%.4f m15=%.4f",
                              m[0], m[1], m[2], m[3], m[12], m[15]);
                    } else {
                        NSLog(@"[DIAG] VP FAILED for camera=0x%llx",
                              (unsigned long long)camera);
                    }
                }
                kernel_boot_log_fn logFn = kernelBootLog;
                if (logFn) {
                    NSString *line = [NSString stringWithFormat:
                        @"[diag] pawn=%@",
                        isVaildPtr(myPawnObject) ? @"ok" : @"nil"];
                    dispatch_async(dispatch_get_main_queue(), ^{ logFn(line); });
                }
            }
        }
    }

    // NOTE: stats.inMatch is deliberately NOT set here.
    //
    // It used to be committed at this point, on "camera and match are both valid
    // pointers". That is not the same thing as "there is a match to count", and the
    // gap between them is the loading screen:
    //
    //   esp.mm:4508  playerDict   read; invalid during loading
    //   esp.mm:4534  dictCount    0 during loading
    //
    // Both return early, carrying inMatch = true and a count of 0. The counter
    // prints "--" only when realCount == 0 && botCount == 0 && !inMatch
    // (esp.mm:4000), so it fell through to the number and printed 0 on the
    // loading screen, which is the reported symptom: "0 at loading, -- in the
    // match", the two swapped from what they should say.
    //
    // It is committed further down, once the dictionary has proved it holds live
    // entries. Loading now returns with inMatch false and prints "--", and a real
    // match with nobody in it still prints 0, which is the distinction the field
    // exists for.

    // Camera / local origin for ESP distance + min/max cull.
    // Bug history: when MainCameraTransform failed, myLocation stayed (0,0,0) while
    // iAmAlive=true → Distance(origin, enemy) ~thousands → all real enemies culled.
    // When iAmAlive=false (HP pool read 0), distance was hard-forced to 10m → ghosts.
    Vector3 myLocation = {0, 0, 0};
    if (isVaildPtr(myPawnObject)) {
        uint64_t mainCameraTransform = ReadAddr<uint64_t>(myPawnObject + kMainCameraTransform);
        if (isVaildPtr(mainCameraTransform)) {
            myLocation = getPositionExt(mainCameraTransform);
        }
        if (!looksLikeWorldPos(myLocation)) {
            myLocation = ReadPlayerRootTransform(myPawnObject);
        }
        if (!looksLikeWorldPos(myLocation)) {
            Vector3 lh = tryTransformPos(getHead(myPawnObject));
            if (looksLikeWorldPos(lh)) myLocation = lh;
        }
        if (!looksLikeWorldPos(myLocation)) {
            myLocation = ResolvePawnWorldPosAny(myPawnObject);
        }
    }
    const bool haveLocalPos = looksLikeWorldPos(myLocation);
    // Treat as "alive enough" for distance math if we have a local world anchor
    // (spectator / HP-pool glitch still gets correct culls instead of fake 10m).
    const bool useLocalDistance = haveLocalPos;

    // Simple dump-backed player dict walk (no multi-layout probe every frame).
    // Dictionary<BHGGAEEHJCO,Player> @ match+kMatchPlayerDict
    // Entry: hash+next+key(0x18)+value* => stride 0x28, value @ 0x20
    // Only the main dict @ kMatchPlayerDict (0x128). No probing of 0x130/0x138/0x140/
    // 0x150 as a fallback: those are the lobby and social dictionaries, and picking
    // one of them while the match dict is momentarily unreadable puts a non-match
    // pawn into the player loop, which then draws it and counts it. The symptom is a
    // count one higher than the enemies on screen that does not move when enemies
    // die, because that pawn is not an enemy and never disappears.
    uint64_t playerDict = ReadAddr<uint64_t>(match + kMatchPlayerDict);
    if (!isVaildPtr(playerDict)) {
        return stats;
    }

    int dictCount = ReadAddr<int>(playerDict + kDictCount);
    uint64_t entriesArr = ReadAddr<uint64_t>(playerDict + kDictEntries);
    if (!isVaildPtr(entriesArr)) {
        const uint64_t eOffs[] = { 0x10, 0x20 };
        for (size_t ei = 0; ei < 2 && !isVaildPtr(entriesArr); ei++) {
            entriesArr = ReadAddr<uint64_t>(playerDict + eOffs[ei]);
        }
    }
    if (!isVaildPtr(entriesArr)) {
        return stats;
    }

    // ---- Bad read, or a big match? Today they are one integer, and only one of
    // ---- them should stop the frame.
    //
    // entriesArr+0x18 is an Il2CppArray max_length, so it is the dictionary's
    // CAPACITY, not its player count. This value is handled twice, twenty-odd
    // lines apart, with two opposite answers:
    //
    //   cap > 256  ->  "the frame is bogus, stop"      (here -- before
    //                  stats.inMatch is set and before the pawn loop)
    //   cap > 128  ->  "the walk is clamped, draw what we found"   (below)
    //
    // One number, two opposite answers, and the wrong one runs first. In a 50-100
    // player match the capacity sits one geometric growth step above the player
    // count, so a 256 ceiling does not truncate the match, it deletes the frame: no
    // boxes, counter reading "--", and nothing logged because this return is
    // silent. The 128 clamp would have handled the same value by degrading.
    //
    // 256 was never a player-count ceiling either. It is the corrupt-read ceiling
    // that replaced 2048/512 after a 2048-slot read had been walked for two thousand
    // iterations, each of which could add a phantom. What one integer cannot do is
    // say which of the two situations it is, and the two need opposite answers, so
    // the answer has to come from more than one integer.
    //
    // A dictionary has a second number, and the two are not independent:
    //
    //   1. cap >= dictCount always holds. A capacity below the live count means
    //      the two reads came from different structures or one of them failed.
    //   2. cap is never far above count. Growth is geometric (double, then rounded
    //      up to a prime), so cap stays within a small factor of count at all
    //      times. 16x is outside anything a real Dictionary produces, and it
    //      catches the exact failure the old 256 was standing in for -- cap=2048
    //      with dc=100 -- even though 2048 is under any absolute ceiling.
    //   3. Neither number is absurd alone. 2048 slots is not a player array, so the
    //      original bad-read ceiling is kept as the backstop for when it is
    //      dictCount, not the capacity, that is the corrupt read.
    //
    // Anything surviving all three is a big match, and a big match is clamped
    // below rather than discarded.
    //
    // dictCount was already read a few lines above and used only for the <= 0
    // guard. The discriminator this needed was already in hand.
    const int kMaxPlausibleSlotCap = 2048;
    const int kMaxPlausiblePlayers = 1024;
    int slotCap = ReadAddr<int>(entriesArr + kIl2CppArrayMaxLength);
    const bool capZero      = (slotCap <= 0);
    const bool capTooHuge   = (slotCap > kMaxPlausibleSlotCap);
    const bool capTooSmall  = (slotCap > 0 && dictCount > slotCap);
    const bool capTooSparse = (slotCap > 16 * (dictCount + 1) + 64);
    const bool countGarbage = (dictCount < 0 || dictCount > kMaxPlausiblePlayers);
    const bool capGarbage   = (capZero || capTooHuge || capTooSmall || capTooSparse);
    // One throttle for every capacity outcome, 5s, the same window DIAG_EARLY uses,
    // so a log alternating between two states is still one line per 5s. An NSLog
    // rather than DIAG_EARLY because DIAG_EARLY prints "stop:", which is true of
    // the reject below and false of the clamp further down, and the whole point of
    // the change is that ONE device log can tell the two apart. [ESP-DICT] sits
    // next to [ESP-COUNT], same cadence, greppable.
    static CFTimeInterval s_dictCapLog = 0;
    const CFTimeInterval dictCapNow = CACurrentMediaTime();
    const bool dictCapLogNow = (dictCapNow - s_dictCapLog) > 5.0;
    if (capGarbage || countGarbage) {
        if (dictCapLogNow) {
            s_dictCapLog = dictCapNow;
            g_st.gate = 1 | ((int)capZero) | ((int)capTooHuge << 1) |
                        ((int)capTooSmall << 2) | ((int)capTooSparse << 3) |
                        ((int)countGarbage << 4);
            g_st.dict      = playerDict;
            g_st.slotCap   = slotCap;
            g_st.dictCount = dictCount;
        }
        return stats;
    }
    // dictCount is the number of live entries. When it is zero the backing array is
    // still allocated and full of freed slots, and a freed entry keeps its old hash
    // code, so walking by slotCap alone walks the free list and counts pawns that
    // left the match. Guard here rather than clamp the loop, because the loop is
    // also what finds the players that are live.
    if (dictCount <= 0) {
        if (dictCapLogNow) {
            s_dictCapLog = dictCapNow;
            g_st.gate      = 2;
            g_st.dict      = playerDict;
            g_st.slotCap   = slotCap;
            g_st.dictCount = dictCount;
        }
        return stats;
    }

    // Everything above has to have worked before the counter is allowed to say
    // "in a match": valid camera, valid match, usable dictionary, and live entries
    // in it. This is the first point at which all four are true, so it is where the
    // commitment belongs. See the note above the camera block for what committing
    // it earlier did to the loading screen.
    stats.inMatch = true;

    // View-projection is sampled AFTER world collect (see below). Reading it here
    // made boxes lag behind cam while the player loop did heavy memory I/O.
    float matrixData[16];
    memset(matrixData, 0, sizeof(matrixData));

    // Phase-1 collect buffer (world space only — no W2S yet).
    EspPawnSnap snaps[128];
    int snapN = 0;

    __attribute__((unused)) uint64_t bestTarget = 0;
    __attribute__((unused)) Vector3 bestHeadPos;
    __attribute__((unused)) float bestScore = FLT_MAX;
    __attribute__((unused)) float bestDistance = FLT_MAX;
    __attribute__((unused)) bool isVis = false;

    // Relative LOS buckets MUST live outside the player loop (reset once per frame).
    uint64_t bestAnyTarget = 0, bestLosTarget = 0;
    Vector3 bestAnyHead{}, bestLosHead{};
    float bestAnyScore = FLT_MAX, bestLosScore = FLT_MAX;
    float bestAnyDist = FLT_MAX, bestLosDist = FLT_MAX;
    bool bestAnyVis = false, bestLosVis = false;
    (void)bestLosVis;

    // Pipelines:
    // - Aimbot FOV/180/360: hard LookAt (camera snap) + AimTargetMode priority.
    // - Aim Assist: may stack with Aimbot; alone = near-crosshair magnet, same AimPos.
    // - Silent: magic bullet — independent HitObject spoof while firing.
    isAimBehindWall = AimBehindWallNow();
    // Sample game weapon raycast once/frame for thorough wall-off LOS.
    AimWallOffFrameBegin(myPawnObject, myLocation);
    const bool useAssist = isAimAssist;
    const bool useAssistOnly = isAimAssist && !isAimbot; // assist magnet radius only when solo
    // Silent/360 only with wall-through ON.
    bool useSilent = isAimSilent && AimThroughAnyCoverNow();
    if (isAimSilent && !AimThroughAnyCoverNow()) {
        SilentAimClearTarget();
    }
    bool useAim = (isAimbot || useAssist || useSilent);
    const bool useAim180 = isAimbot && aimSphereMode == 1;
    // 360 only with wall-through ON.
    const bool useAim360 = isAimbot && aimSphereMode == 2 && AimThroughAnyCoverNow();
    const bool useSphereAim = useAim180 || useAim360;
    const bool silentSphereOnly = useSilent && !isAimbot && !useAssist;

    // FOV gate when Aimbot FOV mode; Assist-only uses assist radius; stacked → FOV.
    const float aimFovSq = (isAimbot && !useSphereAim) ? (aimFov * aimFov) : 0.0f;
    const float assistRadius = fminf(fmaxf(viewHeight * 0.12f, 48.f), 140.f);
    const float assistRadiusSq = assistRadius * assistRadius;
    const float safeAimDistance = fmaxf(aimDistance, 1.0f);
    const float safeAimFovSq = fmaxf(aimFovSq, 1.0f);
    const float maxPossibleDistance = fmaxf(espDistanceLimit, aimDistance) + 5.0f;

    const uint64_t entriesBase = entriesArr + kIl2CppArrayItems;
    const uint64_t entryStride = kDictEntryStrideBytePlayer ? kDictEntryStrideBytePlayer : 0x28;
    const uint64_t entryValueOff = kDictEntryValueOffByte ? kDictEntryValueOffByte : 0x20;
    // The clamp: the second of the two places this capacity is handled, and the one
    // that degrades instead of deleting the frame.
    //
    // 512 is what this was before it was lowered to 128, and it clears every mode
    // that exists here -- the capacity only passes 512 in a match with more players
    // than that. Walking 512 is affordable now for the reason the limit was invented
    // for, because that case can no longer reach this line: a corrupt capacity is
    // rejected above, and the walk ends on the dictionary's own live count.
    //
    // 128 was not a player-count decision either. Walking 128 slots of a 163-slot
    // capacity finds about 50*128/163 = 39 of 50 players, because the entries are
    // hash-placed across the whole capacity and not packed at the front -- so the
    // players that go missing are a spread-out 22%, not a tail.
    const int kMaxWalkSlots = 512;
    int loopCount = slotCap;
    if (loopCount > kMaxWalkSlots) loopCount = kMaxWalkSlots;
    // How many dict entries were dropped as "that is me". Printed with the count
    // below because it is the whole question behind "the counter counts me": the
    // self filter needs the local pawn, and getLocalPlayer(match) returns 0 when
    // kMatchLocalPlayer does not resolve, in which case isSamePlayerAsLocal
    // answers false for everything and the local player is counted as an enemy.
    // self=0 with local=0 is that case, and self=0 with a valid local is a
    // different bug entirely. One log line separates them.
    int selfSkipped = 0;

    // Zeroed here rather than at the top of the method, because this is where the walk
    // begins and a frame that returns before it must not publish last frame's
    // arithmetic.
    PawnRejects rej{};

    // ---- What the walk found, and the one bound that is not a constant -------
    //
    // Exactly dictCount slots of this array can hold a live entry, so the first
    // dictCount resolvable pawns are the players and anything past that did not come
    // from this dictionary. That is the phantom budget, and it is the dictionary's
    // own number rather than a constant that has to be chosen small enough to also
    // fit a real match: a corrupt array is cut off here instead of after a thousand
    // iterations of full pawn pipeline, and a real match cannot reach it, because
    // exactly dictCount live entries exist. A slot whose pawn pointer fails to read
    // is skipped without consuming budget, so a late read costs a slot and not a
    // player.
    const int liveBudget = dictCount;
    int dictClamped   = (loopCount < slotCap) ? 1 : 0;
    int dictIters     = 0;  // loop iterations actually performed
    int dictWalkSlots = 0;  // slots whose hash code was not a free marker
    int dictLive      = 0;  // slots that yielded a pawn not already seen
    int dictDupes     = 0;  // slots naming a pawn an earlier slot already named
    int dictValueProbe = 0; // pawns whose value did not read at the documented offset
    int dictStopLive  = 0;  // 1 = the walk ended on the live count
    int snapDrop      = 0;  // pawns refused by the 128-snapshot draw buffer

    // One pawn, one slot. This dictionary can name the same Player under two keys --
    // the count table's own comment above s_espCountKey says so -- and the tally
    // already dedupes by pawn pointer, so a duplicate never inflated the number, but
    // it did cost a second full read pipeline and a second box. Depth matches the
    // count table, which a 100+ player match also fits inside.
    uint64_t seenPawn[192];
    int seenPawnN = 0;

    for (int i = 0; i < loopCount; i++) {
        // The live count is the bound, checked at the top of the iteration so the
        // walk stops without reading one more slot than there are players.
        if (dictLive >= liveBudget) { dictStopLive = 1; break; }
        dictIters++;
        uint64_t ent = entriesBase + entryStride * (uint64_t)i;
        int hc = ReadAddr<int>(ent);
        // Free slots typically 0 or -1.
        if (hc == 0 || hc == -1) continue;
        dictWalkSlots++;

        uint64_t PawnObject = ReadAddr<uint64_t>(ent + entryValueOff);
        // Set when the documented value offset did not answer and a pointer came
        // from the layout-probe list instead. 0x10 and 0x18 sit inside the 0x18-byte
        // key, so this probe can pick up something that was never a Player. Counted
        // rather than removed, because it is also the layout tolerance that
        // kDictEntryValueOffByte exists for, and a count is what tells the two apart.
        bool pawnFromProbe = false;
        if (!isVaildPtr(PawnObject)) {
            const uint64_t vOffs[] = { 0x10, 0x18, 0x20, 0x28 };
            for (size_t vo = 0; vo < 4; vo++) {
                uint64_t cand = ReadAddr<uint64_t>(ent + vOffs[vo]);
                if (isVaildPtr(cand)) {
                    PawnObject = cand;
                    pawnFromProbe = true;
                    break;
                }
            }
        }
        if (!isVaildPtr(PawnObject)) continue;

        // isVaildPtr is a range test and nothing else -- not below 0x100000, not
        // above 0x0000FFFFFFFFFFFF, top bit clear. A freed entry's stale Player*
        // passes it. This is where the alias case is caught: a slot naming a pawn
        // another slot already named is a stale or duplicated entry, and one box
        // per pawn is the right answer whichever of the two slots is the live one.
        {
            bool dupPawn = false;
            for (int pi = 0; pi < seenPawnN; pi++) {
                if (seenPawn[pi] == PawnObject) { dupPawn = true; break; }
            }
            if (dupPawn) { dictDupes++; continue; }
            if (seenPawnN < (int)(sizeof(seenPawn) / sizeof(seenPawn[0]))) {
                seenPawn[seenPawnN++] = PawnObject;
            }
        }
        dictLive++;
        if (pawnFromProbe) dictValueProbe++;

        // Hoisted. The teammate test below needs this pawn's team and the per-pawn
        // cache block further down needs the same slot; declaring it in both places
        // would shadow one with the other. It cannot simply be moved down to that
        // block instead, because the teammate test has to run BEFORE the HP reads:
        // get_CurHP is a DataPool walk costing up to 45 reads, and a teammate should
        // not pay that to be thrown away.
        PlayerCache &c = g_playerCache[PlayerCacheSlot(PawnObject)];

        // ---------------------------------------------------------------------
        // WHO IS AN ENEMY, decided from a cached identity instead of one live read.
        //
        // The report: team of 2, both alive, the counter says 3. Only I die, it
        // says 4. Both die, 3 again. A counter that moves when the local player
        // dies is counting the local player, and a persistent +1 on a team of two
        // is the local team.
        //
        // Both filters below decide "not mine" out of a read that returns 0 when
        // it fails, and 0 means "I do not know":
        //
        //   isSamePlayerAsLocal   localPlayer == 0            -> false for everything
        //                         uid == 0                   -> no match
        //                         PlayerID.m_Value == 0      -> no match
        //   isLocalTeamMate       myTeamID == 0 || TeamID==0 -> false, i.e. "enemy"
        //                         isBot && !isAimIgnoreBot   -> false, before the team is
        //                                                          even looked at
        //
        // So every one of those is fail-open: an unreadable identity is treated as
        // a confirmed enemy. match->localPlayer is read fresh every frame at
        // esp.mm:4284 and goes unusable exactly when the local player dies or the
        // read is late, and that is when the extra entry appears.
        //
        // The identity is cached instead. It is refreshed from the live pawn
        // whenever that pawn is readable, and a field that reads 0 is never
        // allowed to overwrite a good one -- so a transient read failure keeps the
        // last known identity rather than erasing it. Nothing is cleared while the
        // match lives; the match->lobby transition is the only place that drops
        // it, and that is the right place, because it is a different match.
        //
        // This is not "validate more". It is removing the dependency on a read
        // being available at the instant it is needed, which is the same class of
        // bug as the DSMemory degrade latch, and it is what makes the number
        // stop depending on whether the local player happens to be alive.
        // ---------------------------------------------------------------------
        {
            if (isVaildPtr(myPawnObject)) {
                const uint64_t liveUid = ReadAddr<uint64_t>(myPawnObject + kUserID);
                if (liveUid) s_locUid = liveUid;
                const COW_GamePlay_PlayerID_o liveId =
                    ReadAddr<COW_GamePlay_PlayerID_o>(myPawnObject + kPlayerID);
                if (liveId.m_Value) s_locPid = liveId.m_Value;
                if (liveId.m_TeamID) s_locTeam = liveId.m_TeamID;
            }

            // Self: pointer first, then the two stable identities. Any one of the
            // three matching is enough -- that is the same rule as
            // isSamePlayerAsLocal, only fed from values that survive the local
            // pawn becoming unreadable.
            bool isSelf = false;
            if (PawnObject == myPawnObject) {
                isSelf = true;
            } else if (s_locUid) {
                isSelf = (ReadAddr<uint64_t>(PawnObject + kUserID) == s_locUid);
            }
            if (!isSelf && s_locPid) {
                isSelf = (ReadAddr<COW_GamePlay_PlayerID_o>(PawnObject + kPlayerID).m_Value
                          == s_locPid);
            }
            if (isSelf) { selfSkipped++; rej.self++; continue; }

            // Teammate. The bot early-out is gone, because it used to
            // answer "enemy" before the team was ever read: a teammate whose
            // kIsClientBot byte came back non-zero stopped being a teammate, with
            // no other condition involved. A bot on our team is still on our team.
            //
            // The team is cached per pawn now, and an unknown team is NOT counted.
            //
            // It used to be read fresh every frame and treated fail-open:
            //
            //     const int theirTeam =
            //         ReadAddr<COW_GamePlay_PlayerID_o>(PawnObject + kPlayerID).m_TeamID;
            //     if (s_locTeam && theirTeam && s_locTeam == theirTeam) continue;
            //
            // An unreadable team was not a match, so the pawn was counted, and the
            // comment above called that the safe direction. It was the wrong
            // direction, because the failure is not one frame long. Reads degrade
            // for stretches, this pawn is stamped into the count table on every
            // frame it is seen, and an entry only leaves on the 3-frame hold. So a
            // pawn whose team read keeps failing is not "at worst one extra on a
            // frame" -- it is +1 for as long as it lives. That is a persistent
            // over-count, and it is the one being reported.
            //
            // Caching the team is what makes fail-closed affordable here. Without
            // it, refusing to count an unknown team drops every pawn on whichever
            // frame its PlayerID read happens to be late, so the hole moves around
            // instead of closing. With it, a pawn is refused only until its team
            // has been read successfully once, and from then on a late read costs
            // nothing at all -- which is also why this is fewer reads than before.
            const bool teamCacheMiss = (c.pawn != PawnObject);
            if (teamCacheMiss) c.team = 0;
            if (teamCacheMiss || c.team == 0 || ((g_cacheFrameCounter & 7) == 0)) {
                const int t =
                    ReadAddr<COW_GamePlay_PlayerID_o>(PawnObject + kPlayerID).m_TeamID;
                if (t) c.team = t;
            }
            // Unknown team: not counted. The self case, which is the one the
            // original report was about, is decided above from cached identity and
            // does not depend on the team read at all.
            if (c.team == 0) { s_countTeamUnknown++; rej.team++; continue; }
            if (s_locTeam && c.team == s_locTeam) continue;
        }

        // HP/knocked EVERY frame (stale cache was the floating "ghost ESP" after kills).
        // Bot flag can lag 1 frame; vis only when Check Visible is on.
        // Use pawn-stable slot (hash), not walk index — prevents cache thrash when
        // dict walk order changes or pawns leave/re-enter range (the "treo" cause).
        // c is the hoisted reference above; do not redeclare it here.
        const bool cacheMiss = (c.pawn != PawnObject);
        if (cacheMiss) {
            c.pawn = PawnObject;
            c.isBot = get_IsBot(PawnObject);
            c.isTrueVis = false;
            c.isCamVis = false;
            c.isPvsVis = false;
            c.visGoodFrames = 0;
        } else if ((g_cacheFrameCounter & 7) == 0) {
            // Bot bit rarely changes — refresh occasionally.
            c.isBot = get_IsBot(PawnObject);
        }
        c.isKnocked = get_IsKnockedDown(PawnObject);
        // Read both ways: the value, and whether it was a value at all. HP is the
        // only thing this loop uses to decide a player is dead, and a failed read
        // is indistinguishable from a zero HP unless somebody asks.
        bool hpReadOk = get_CurHPOk(PawnObject, &c.curHP);
        const bool maxReadOk = get_MaxHPOk(PawnObject, &c.maxHP);
        if (!hpReadOk) c.curHP = get_CurHP(PawnObject);
        if (!maxReadOk) c.maxHP = get_MaxHP(PawnObject);
        c.frame     = g_cacheFrameCounter;

        if (isEspCheckVisible && (cacheMiss || (g_cacheFrameCounter & 1) == 0)) {
            const uint32_t vflags = get_VisibleFlags(PawnObject);
            c.isCamVis = (vflags & kISVisibleCamera) != 0;
            c.isPvsVis = (vflags & kISVisibleDynamicPVS) != 0;
            c.isFPP = (vflags & kISVisibleFPPMask) == kISVisibleFPPMask;
            c.isTrueVis = c.isFPP;
            c.visGoodFrames = c.isTrueVis ? 1 : 0;
        }

        bool isBot     = c.isBot;
        bool isKnocked = c.isKnocked;
        int CurHP      = c.curHP;
        int MaxHP      = c.maxHP;
        bool isFPP     = c.isFPP;
        bool isCamVis  = c.isCamVis;
        bool isTrueVis = c.isTrueVis;
        (void)isCamVis; (void)isTrueVis;

        // ---- Ghost ESP filter (do not invent alive players) ----
        // Sticky death: once fully dead/unreadable, suppress longer so free-list
        // dict entries + sticky PosTrack cannot reappear as floating ESP/aim.
        static uint64_t s_deadPawn[kPawnSlotCount] = {};
        static int s_deadUntilFrame[kPawnSlotCount] = {};
        const int deadSlot = (int)(PawnObject % kPawnSlotCount);

        // Lift the ban the moment this pawn reads as alive. This is the actual bug,
        // and it is not a collision problem -- the test below compares the pointer,
        // so a colliding live pawn was never suppressed by a colliding tombstone,
        // at 96 slots or at 1024. What does suppress a live pawn is address reuse:
        // a pawn dies, the game frees it, the allocator hands the SAME address to
        // the next player it spawns, and now s_deadPawn[deadSlot] == PawnObject is
        // true again for someone demonstrably alive. It then stays suppressed for
        // the rest of the 120-frame hold, about two seconds, with no table size in
        // the world that changes it.
        //
        // The hold itself is deliberate and stays -- it is what stops a free-list
        // dict entry from reappearing as floating ESP or a floating aim target.
        // What was missing is the way out. The sibling has exactly this, keyed on
        // HP being positive; there was no counterpart here, so a revived address
        // had nothing to lift the ban.
        //
        // Knocked counts as alive here, and it has to, because forty lines below the
        // death test says exactly that:
        //
        //     const bool fullyDead = (!isKnocked && CurHP <= 0 && !hpUnreadable);
        //
        // A knocked player is on HP 0 by definition -- that is what knocked means. So
        // lifting the ban on "HP positive" alone makes the exit unreachable for the
        // one class of player who is provably alive, and the two tests disagree about
        // what alive is: the death test lets a knocked player through, the ban exit
        // keeps them out.
        //
        // The consequence is the reported symptom and nothing else fits it. Any
        // transient filter drops a knocked player -- noBone, headFar, noUid, the anchor
        // test -- and once they are tombstoned the ban can never be lifted, because
        // the only key that opens it reads zero for them by definition. They then stay
        // suppressed for the full 30-to-120 frame hold: no box, not aimable, and it
        // repeats every time a filter catches them again. Knocked players are the ones
        // most worth aiming at, and they are also the ones lying down, which is what
        // makes the root-to-head and head-to-root geometry tests fire on them in the
        // first place. So the filter most likely to catch a knocked player is a
        // geometry test, and the geometry tests are also the ones whose geometry a
        // crawling body violates.
        //
        // Reads that failed are still not treated as alive. hpReadOk is not consulted
        // because an unreadable HP is not a fact about the player, and the hold
        // expires on its own without this test.
        //
        // Lifting on a knocked read does not widen what gets drawn beyond what is
        // already drawn: a garbage-true knocked read already stops fullyDead from
        // firing, so that corpse was already going to be drawn this frame. This makes
        // the ban agree with the drawing instead of adding a new way in.
        if (s_deadPawn[deadSlot] == PawnObject) {
            const bool readsAlive = (CurHP > 0 || isKnocked) && MaxHP > 0;
            if (readsAlive) {
                s_deadUntilFrame[deadSlot] = 0;
                // The hold lives in TWO places and this cleared only one of them, so the
                // lift ended the ban without ending the tombstone.
                //
                // markGhostDead writes g_posTrack[PosTrackSlot(pawn)].deadUntilFrame
                // (above) as well as s_deadUntilFrame[deadSlot]. Three readers consult
                // the PosTrack copy, and all three refuse to produce a position while it
                // stands:
                //
                //   2351  ResolveHeadWorldPosTracked  -> Vector3{0,0,0}
                //   2378  ResolveHipWorldPosTracked   -> Vector3{0,0,0}
                //   2408  EspSmoothDisplayPos          -> Vector3{0,0,0}
                //
                // The last one is called at 5609/5610, which is AFTER this point, so a
                // lifted pawn walked straight into it and had its whole snapshot geometry
                // replaced by the world origin:
                //
                //   5690  !IsZeroVec(bone) is false      -> canAimThisPawn = false
                //   5670  dis is now the distance to {0,0,0} -> exceeds espDrawLimit
                //                                                    -> wantDraw = false
                //
                // So the lift made this WORSE than having no lift. Without it the pawn
                // was cleanly banned for the hold and nothing was emitted. With it the
                // pawn passed the ban and then emitted a garbage snapshot entry for the
                // rest of the hold: no box, not aimable, while provably alive -- which
                // is the exact shape of "a live player is missing from ESP and aim".
                //
                // Which is what 16423b858 introduced. It fixed a real problem -- a
                // knocked pawn could never leave the ban because it reads HP 0 -- and
                // introduced this one by lifting half the state.
                PosTrack &trLift = g_posTrack[PosTrackSlot(PawnObject)];
                if (trLift.pawn == PawnObject) trLift.deadUntilFrame = 0;
            } else if (g_cacheFrameCounter < s_deadUntilFrame[deadSlot]) {
                rej.banned++;
                continue;
            }
        }
        auto markGhostDead = [&](int holdFrames) {
            // Tombstone inside PosTrack by exact pawn (not just the
            // kPawnSlotCount bucket). This prevents the same pawn (or a colliding
            // bucket occupant) from reviving
            // smoothing/track state for a hold window even if dict still yields the pointer.
            PosTrack &trDead = g_posTrack[PosTrackSlot(PawnObject)];
            trDead.pawn = PawnObject;
            trDead.deadUntilFrame = g_cacheFrameCounter + holdFrames;
            // Clear smoothing/velocity but keep tombstone + identity flags
            trDead.headSmoothed = trDead.hipSmoothed = Vector3{};
            trDead.lastHeadRaw = trDead.lastHipRaw = Vector3{};
            trDead.headVel = trDead.hipVel = Vector3{};
            trDead.lastHeadT = trDead.lastHipT = 0;
            trDead.headSrc = trDead.hipSrc = 0;
            trDead.headSrcHold = trDead.hipSrcHold = 0;
            trDead.hasHead = trDead.hasHip = false;
            trDead.frame = g_cacheFrameCounter;
            trDead.bodyLenHold = 0; // force re-learn after death window
            s_deadPawn[deadSlot] = PawnObject;
            s_deadUntilFrame[deadSlot] = g_cacheFrameCounter + holdFrames;
            if (gAimLockTarget == PawnObject) {
                gAimLockTarget = 0;
                gAimLockLostFrames = 0;
            }
            // Drop any lingering box smoothing state for this pawn (prevents stale size bleed to a new occupant).
            ClearBoxScreenForPawn(PawnObject);
            // Also clear Pro box smoother (used by isESP path).
            ClearProBoxScreenForPawn(PawnObject);
        };

        Vector3 liveHead = getPositionExt(getHead(PawnObject));
        Vector3 liveHip  = getPositionExt(getHip(PawnObject));
        bool hasLiveBone = looksLikeWorldPos(liveHead) || looksLikeWorldPos(liveHip);

        // ---- A read that did not land is not a pawn that went away.
        //
        // This is the "some players yes, some players no, and some appear then
        // disappear entirely" report. Its shape here is specific: when none of the
        // four anchors read, the pawn was tombstoned for 60 frames -- a whole second
        // with no box and no aim -- and markGhostDead also wipes headSmoothed and
        // hipSmoothed, so there was nothing left to fall back on afterwards.
        //
        // But the reason the reads failed is that this pawn's transform pages were
        // not resident, which in a crowded match is routine rather than meaningful.
        // The per-pawn working set is far larger than the page cache, so a pawn's
        // pages come and go as the resident window rotates across the roster. A pawn
        // that reads for two seconds, misses for one, then reads again, is not a
        // despawned ghost: it is a cache that cannot hold everyone at once, and the
        // old behaviour turned that shortfall into a visible disappearance every
        // couple of seconds.
        //
        // The pawn's own PosTrack still holds the last position that DID read, so use
        // it. Bounded on purpose, because this must never keep a genuine ghost alive:
        // thirty frames, after which the pawn is tombstoned exactly as before. A
        // remembered position is also never used across a tombstone, since
        // markGhostDead has already cleared it by then -- the two guards below are
        // belt and braces, not redundant.
        const int kRememberedFrames = 30;
        bool pawnRemembered = false;
        if (!hasLiveBone) {
            PosTrack &trMem = g_posTrack[PosTrackSlot(PawnObject)];
            const bool memOwned  = (trMem.pawn == PawnObject);
            const bool memTombed = (trMem.deadUntilFrame > 0 &&
                                    g_cacheFrameCounter < trMem.deadUntilFrame);
            const bool memFresh  = (g_cacheFrameCounter - trMem.frame) < kRememberedFrames;
            if (memOwned && !memTombed && memFresh) {
                if (looksLikeWorldPos(trMem.headSmoothed)) {
                    liveHead = trMem.headSmoothed;
                    pawnRemembered = true;
                } else if (looksLikeWorldPos(trMem.hipSmoothed)) {
                    liveHip = trMem.hipSmoothed;
                    pawnRemembered = true;
                }
                if (pawnRemembered) hasLiveBone = true;
            }
        }

        // Fallback HP if DataPool reads fail/delay but 3D bones exist. Only for a pawn
        // that is knocked or otherwise still in the round. A body left in the world
        // after death keeps readable bones, so inventing 200 HP here is what turned
        // every kill into a permanent extra box and a permanently higher counter.
        // A real dead body has HP 0 and must stay 0; the tests below drop it.
        if (hasLiveBone && !isKnocked) {
            if (CurHP <= 0 && MaxHP <= 0) {
                CurHP = 200;
                MaxHP = 200;
            } else if (MaxHP <= 0) {
                MaxHP = 200;
                if (CurHP <= 0) CurHP = 200;
            }
        }

        // Alive/knocked always have MaxHP > 0.
        const bool hpUnreadable = (CurHP == 0 && MaxHP == 0);

        // HP did not land AND the bones did not land either: this pawn is UNKNOWN,
        // not dead. Tombstoning here is what produced the reported symptom.
        //
        // The death filter writes a 120-frame hold, which is about two seconds at
        // 60Hz. In a crowded match the reads fail often enough that a live player
        // whose HP page and whose bones both failed to map in the same frame landed
        // in that branch, and stayed suppressed for the full hold: no box, not
        // aimable, looking exactly like an ESP that had not loaded yet. It lifted
        // only once a later frame's reads succeeded, which is why it looked
        // intermittent rather than constant.
        //
        // Both halves of the condition are needed. When the bones DO read, the
        // fallback above has already turned the unreadable HP into 200 and the pawn
        // draws, which is the right answer -- a body left in the world keeps
        // readable bones, so bones alone cannot decide death, but they are enough to
        // decide the pawn is not being misread as a corpse. And when HP DID read and
        // said 0, that is a real death and fullyDead below still handles it.
        //
        // Skipping the pawn for this frame is the honest response either way: the
        // next frame retries.
        if (!hpReadOk && !hasLiveBone && !pawnRemembered) {
            rej.hpUnread++;
            continue;
        }
        const bool hpGarbage = (MaxHP < 0 || MaxHP > 2000 || CurHP > 2000 ||
                                (MaxHP > 0 && CurHP > MaxHP + 50));
        // A dead body keeps readable bones for as long as it lies in the world, so
        // hasLiveBone cannot decide this. It is HP that decides, and only after the
        // knocked test: a knocked player is alive on HP 0 and must survive, a body
        // on HP 0 must not. Checking knocked first is the whole point, the other way
        // round the knocked players disappear instead of the dead ones.
        const bool fullyDead = (!isKnocked && CurHP <= 0 && !hpUnreadable);
        if (fullyDead) {
            markGhostDead(120); // longer hold for death
            rej.dead++;
            continue;
        }
        if (!hasLiveBone && (hpGarbage || hpUnreadable || MaxHP <= 0)) {
            markGhostDead((hpUnreadable || MaxHP <= 0) ? 120 : 45);
            rej.hpBad++;
            continue;
        }
        // Despawned/spectator shells often keep a free-list pointer with no identity.
        {
            uint64_t uid = ReadAddr<uint64_t>(PawnObject + kUserID);
            COW_GamePlay_PlayerID_o pid = ReadAddr<COW_GamePlay_PlayerID_o>(PawnObject + kPlayerID);
            if (uid == 0 && pid.m_Value == 0 && pid.m_ID == 0 && !isBot && !hasLiveBone) {
                markGhostDead(90);
                rej.noUid++;
                continue;
            }
        }

        // Use frozen frame matrix only (refreshViewMatrix is a no-op).

        // ---------------------------------------------------------------------
        // ESP MUST use the SAME head aim uses when possible.
        // ---------------------------------------------------------------------
        Vector3 liveRoot = ReadPlayerRootTransform(PawnObject);

        Vector3 mountPos{};
        const bool enemyMounted = IsActivelyMounted(PawnObject, &mountPos);
        if (!enemyMounted) {
            uint64_t vOnly = ReadVehicleIAmIn(PawnObject);
            if (isVaildPtr(vOnly)) {
                Vector3 vp = ResolveVehicleWorldPos(vOnly);
                if (looksLikeWorldPos(vp)) {
                    mountPos = vp;
                    mountPos.y += 0.95f;
                }
            }
        }
        const bool haveMountPos = looksLikeWorldPos(mountPos);

        // Body shape: seat-collapse only meaningful WITH a real vehicle/mount signal.
        float liveBodyLen = 0.f;
        bool haveLiveBody = false;
        if (looksLikeWorldPos(liveHead) && looksLikeWorldPos(liveHip)) {
            liveBodyLen = Vector3::Distance(liveHead, liveHip);
            haveLiveBody = true;
        }
        const bool bodyCollapsed = haveLiveBody && liveBodyLen < 0.35f;
        // CRITICAL: bodyCollapsed alone is NOT vehicle — dead shells often collapse.
        const bool treatAsVehicle = enemyMounted || haveMountPos;

        // No live skeleton AND no mount → despawned ghost (dict still holds pointer).
        const bool anyLiveAnchor =
            looksLikeWorldPos(liveHead) || looksLikeWorldPos(liveHip) ||
            looksLikeWorldPos(liveRoot) || haveMountPos;
        if (!anyLiveAnchor) {
            // Now reached only when the pawn has neither a live anchor nor a recent
            // remembered one, so this really is a despawned shell rather than a frame
            // whose reads happened not to land.
            markGhostDead(60);
            rej.noAnchor++;
            continue;
        }
        // Standing ghost: collapsed body without vehicle → skip (was ESP/aim on empty).
        // Be robust to isKnocked lag: only treat as ghost when we have clear evidence they
        // should be standing tall (root-to-head height looks upright) and bones are collapsed.
        if (!treatAsVehicle && bodyCollapsed) {
            bool expectStanding = !isKnocked;
            bool rootSaysUpright = false;
            if (looksLikeWorldPos(liveRoot) && looksLikeWorldPos(liveHead)) {
                float dy = liveHead.y - liveRoot.y;
                if (dy >= 1.15f) rootSaysUpright = true;
            }
            if (expectStanding && (rootSaysUpright || !looksLikeWorldPos(liveRoot))) {
                markGhostDead(45);
                rej.collapsed++;
                continue;
            }
            // If root indicates low profile (knocked/prone) or isKnocked true, allow collapsed.
        }
        // Bones both missing while not mounted → shell / spectator leftover.
        if (!treatAsVehicle && !looksLikeWorldPos(liveHead) && !looksLikeWorldPos(liveHip) &&
            !looksLikeWorldPos(liveRoot)) {
            markGhostDead(60);
            rej.noBone++;
            continue;
        }

        Vector3 headBonePos{};
        bool headFromLive = false;
        // 1) Live head first — same as aim path.
        if (looksLikeWorldPos(liveHead)) {
            headBonePos = liveHead;
            headFromLive = true;
        } else if (haveMountPos) {
            headBonePos = mountPos;
            headFromLive = true;
        } else if (looksLikeWorldPos(liveRoot)) {
            headBonePos = liveRoot;
            headBonePos.y += treatAsVehicle ? 0.95f : 0.85f;
            headFromLive = true;
        } else if (looksLikeWorldPos(liveHip)) {
            headBonePos = liveHip;
            headBonePos.y += 0.55f;
            headFromLive = true;
        }
        // No ResolveHeadWorldPosTracked fallback here — sticky track invents ghosts.
        if (!headFromLive || IsZeroVec(headBonePos) || !looksLikeWorldPos(headBonePos)) {
            markGhostDead(45);
            rej.noHead++;
            continue;
        }
        // Reject world-origin / near-zero anchors (classic ghost after death).
        if (fabsf(headBonePos.x) < 0.5f && fabsf(headBonePos.z) < 0.5f && fabsf(headBonePos.y) < 2.0f) {
            markGhostDead(45);
            rej.origin++;
            continue;
        }
        // Reject head lagging impossibly far from root (stale free-list transform).
        if (looksLikeWorldPos(liveRoot)) {
            float dx = headBonePos.x - liveRoot.x;
            float dz = headBonePos.z - liveRoot.z;
            float dXZ = sqrtf(dx * dx + dz * dz);
            if (dXZ > (treatAsVehicle ? 8.0f : 4.5f)) {
                markGhostDead(30);
                rej.headFar++;
                continue;
            }
        }

        // ESP hip under head (for box height). Prefer live hip if sane column.
        // Compute source ids so we can detect flips (head/hip/root/mount) and avoid pumping.
        int headSrcNow = 0; // 1=liveHead, 2=mount, 3=root, 4=liveHip
        int hipSrcNow  = 0; // 2=liveHip, 3=root, 4=synth-from-head
        Vector3 espHipPos{};
        if (looksLikeWorldPos(liveHip) &&
            Vector3::Distance(headBonePos, liveHip) >= 0.28f &&
            Vector3::Distance(headBonePos, liveHip) < 2.8f) {
            espHipPos = liveHip;
            hipSrcNow = 2;
        } else {
            espHipPos = headBonePos;
            espHipPos.y -= treatAsVehicle ? 1.05f : 0.85f;
            hipSrcNow = 4;
        }
        if (headFromLive) {
            if (looksLikeWorldPos(liveHead) && Vector3::Distance(headBonePos, liveHead) < 0.01f) headSrcNow = 1;
            else if (haveMountPos && Vector3::Distance(headBonePos, mountPos) < 0.01f) headSrcNow = 2;
            else if (looksLikeWorldPos(liveRoot)) headSrcNow = 3;
            else headSrcNow = 4;
        }

        // World-space EMA on validated live positions only — kills bone micro-jitter
        // without inventing ghosts (markGhostDead already filtered dead shells).
        // If source flipped this frame, bypass smoothing to stop a stretch that box smoother can't hide.
        PosTrack &trDisp = g_posTrack[PosTrackSlot(PawnObject)];
        const bool headSrcFlip = (trDisp.lastHeadSrcDisp != 0 && headSrcNow != 0 && trDisp.lastHeadSrcDisp != headSrcNow);
        const bool hipSrcFlip  = (trDisp.lastHipSrcDisp  != 0 && hipSrcNow  != 0 && trDisp.lastHipSrcDisp  != hipSrcNow);
        Vector3 preSmoothHead = headBonePos;
        Vector3 preSmoothHip  = espHipPos;
        headBonePos = EspSmoothDisplayPos(PawnObject, headBonePos, /*isHead=*/true);
        espHipPos   = EspSmoothDisplayPos(PawnObject, espHipPos,   /*isHead=*/false);
        if (headSrcFlip || hipSrcFlip) {
            if (looksLikeWorldPos(preSmoothHead)) headBonePos = preSmoothHead;
            if (looksLikeWorldPos(preSmoothHip))  espHipPos   = preSmoothHip;
        }
        trDisp.lastHeadSrcDisp = headSrcNow ? headSrcNow : trDisp.lastHeadSrcDisp;
        trDisp.lastHipSrcDisp  = hipSrcNow  ? hipSrcNow  : trDisp.lastHipSrcDisp;

        // Keep hip under smoothed head as a sane body column (no inverted boxes).
        // Use learned stable body length when available to stop size oscillation on stationary pose.
        {
            float bodyLen = Vector3::Distance(headBonePos, espHipPos);
            float dy = headBonePos.y - espHipPos.y;

            // Learn/refresh canonical body length from good live pairs.
            if (looksLikeWorldPos(liveHead) && looksLikeWorldPos(liveHip)) {
                float liveBL = Vector3::Distance(liveHead, liveHip);
                if (liveBL >= 0.45f && liveBL <= 1.25f) {
                    if (trDisp.bodyLenHold <= 0 || trDisp.bodyLen <= 0.f) {
                        trDisp.bodyLen = liveBL;
                        trDisp.bodyLenHold = 45;
                    } else {
                        float rel = fabsf(liveBL - trDisp.bodyLen) / fmaxf(trDisp.bodyLen, 0.1f);
                        if (rel < 0.18f) {
                            trDisp.bodyLen = trDisp.bodyLen * 0.85f + liveBL * 0.15f;
                            trDisp.bodyLenHold = 45;
                        } else if (rel > 0.35f) {
                            trDisp.bodyLen = liveBL;
                            trDisp.bodyLenHold = 30;
                        }
                    }
                }
            }
            if (trDisp.bodyLenHold > 0) trDisp.bodyLenHold--;

            const bool haveStableBL = (trDisp.bodyLen >= 0.45f && trDisp.bodyLen <= 1.25f);
            if (bodyLen < 0.28f || bodyLen > 2.6f || dy < 0.15f || dy > 1.35f) {
                if (haveStableBL) {
                    espHipPos = headBonePos;
                    espHipPos.y -= trDisp.bodyLen;
                } else {
                    espHipPos = headBonePos;
                    espHipPos.y -= treatAsVehicle ? 1.05f : 0.85f;
                }
            } else if (haveStableBL) {
                float want = trDisp.bodyLen;
                float cur  = bodyLen;
                if (fabsf(cur - want) > 0.22f) {
                    espHipPos = headBonePos;
                    espHipPos.y -= want;
                }
            }
        }

        // Always use real local↔enemy distance when we have a local world anchor.
        float tempDisForAim = useLocalDistance
            ? Vector3::Distance(myLocation, headBonePos)
            : 0.0f;
        // On vehicle distance can be noisy; only skip clearly insane ranges.
        // Min-distance cull skipped for vehicle/collapsed (passenger next to you).
        if (useLocalDistance && tempDisForAim > maxPossibleDistance) { rej.far++; continue; }
        if (useLocalDistance && !treatAsVehicle && tempDisForAim < 0.35f) { rej.near++; continue; }

        // Aimbot + Aim Assist + Silent all honor AimPos (Head/Neck/Chest-Body).
        // Prefer GetAimTargetPosMode / ResolveSilentAimWorldPos (live).
        // Ghost: never aim if HP shell is dead (already filtered) or bone not live.
        Vector3 aimPos = headBonePos;
        bool canAimThisPawn = false;
        if (isAimbot || useAssist || useSilent) {
            Vector3 bone = (useSilent && !isAimbot && !useAssist)
                ? ResolveSilentAimWorldPos(PawnObject, aimPosition)
                : GetAimTargetPosMode(PawnObject, aimPosition, tempDisForAim);
            if (IsZeroVec(bone) || !looksLikeWorldPos(bone)) {
                bone = ResolveSilentAimWorldPos(PawnObject, aimPosition);
            }
            if (IsZeroVec(bone) || !looksLikeWorldPos(bone)) bone = headBonePos;
            // Reject aim bone far from our live head (track invent / wrong pawn).
            // Body is lower on torso — allow a bit more distance than pure head.
            const float maxBoneDist = (treatAsVehicle ? 3.5f : 2.6f);
            if (!IsZeroVec(bone) && looksLikeWorldPos(bone) &&
                Vector3::Distance(bone, headBonePos) < maxBoneDist) {
                aimPos = bone;
                if (aimPosition == 0) headBonePos = bone;
                canAimThisPawn = true;
            }
        } else {
            canAimThisPawn = false;
        }

        float dis = useLocalDistance
            ? Vector3::Distance(myLocation, IsZeroVec(aimPos) ? headBonePos : aimPos)
            : tempDisForAim;

        // Check Visible: Camera bit OR vehicle passenger — always draw people in cars.
        const bool mounted = treatAsVehicle;
        bool espVisible = !isEspCheckVisible || isFPP || isCamVis || isKnocked || mounted;

        // Phase-1: store world-space snapshot only. W2S + draw happen AFTER a fresh
        // view matrix sample so overlay tracks cam (no "stick then snap").
        bool wantDraw = false;
        if ((isESP || isESP2) && (espVisible || (isBot && isEspBot) || mounted)) {
            if (!(isBot && !isEspBot && !mounted)) {
                float espDrawLimit = mounted ? fmaxf(espDistanceLimit, 250.0f) : espDistanceLimit;
                if (!useLocalDistance || dis <= espDrawLimit || (mounted && dis < 8.0f)) {
                    wantDraw = true;
                }
            }
        }

        // Belt-and-suspenders: never emit a dead shell into the snapshot (CurHP<=0 is terminal).
        if (CurHP <= 0) { rej.hpZero++; continue; }

        // The tally used to be recorded here, on wantDraw alone. It cannot be:
        // this pass runs before the view matrix is sampled (it is sampled at
        // esp.mm:4663, after this loop, deliberately — a fresher matrix is what
        // stops the overlay lagging the camera), so nothing here knows whether the
        // pawn is on the screen. wantDraw is a distance test, so every live pawn
        // inside the limit counted, including the ones behind you whose boxes land
        // outside the viewport and are never seen. Reported as "4 enemies and it
        // says 5", and 5 with two enemies, and no extra box on screen to account
        // for the difference.
        //
        // It is recorded in the draw pass instead, next to the same isOnScreen the
        // box is drawn from, so the number counts what the picture shows.

        // 128 is the draw buffer's ceiling and is the next ceiling for a 100+ player
        // match, though 99 possible enemies still fits inside it. Not raised here:
        // 128 EspPawnSnap is already ~9KB of stack on the render path and 192 would
        // be ~14KB of the same stack. Counted instead, because a silent drop is
        // invisible boxes and a counted one is a number on the [ESP] status line.
        if (snapN < 128) {
            EspPawnSnap &s = snaps[snapN++];
            s.pawn = PawnObject;
            s.uid = ReadAddr<uint64_t>(PawnObject + kUserID);
            s.head = headBonePos;
            s.hip = espHipPos;
            s.aimPos = aimPos;
            s.dis = dis;
            s.curHP = CurHP;
            s.maxHP = MaxHP > 0 ? MaxHP : 200;
            s.isBot = isBot;
            s.isKnocked = isKnocked;
            s.treatAsVehicle = treatAsVehicle;
            s.canAim = canAimThisPawn;
            s.wantDraw = wantDraw;
        } else {
            snapDrop++;
        }
    }

    // The clamp, announced. This is not a stop -- the frame completed and every
    // player the walk found has been drawn -- so it does not belong under the
    // "stop:" tag. What it says is that a dictionary with more slots than
    // kMaxWalkSlots is being walked in part, and because the entries are
    // hash-placed the slots that were not read are a spread-out subset of the
    // players rather than the ones past a line.
    if (dictClamped) {
        if (dictCapLogNow) {
            s_dictCapLog = dictCapNow;
            NSLog(@"[ESP] !walk-clamped dict=0x%llx cap=%d dc=%d walk=%d live=%d "
                  @"dup=%d snapDrop=%d -- %d of %d slots not read; entries are "
                  @"hash-placed so the players missed are a spread-out subset",
                  (unsigned long long)playerDict, slotCap, dictCount, loopCount,
                  dictLive, dictDupes, snapDrop, slotCap - loopCount, slotCap);
        }
    }

    // The count, with hysteresis.
    //
    // A pawn counts if it was drawn within the last ESP_COUNT_HOLD_FRAMES
    // frames, not only if it is drawn on this one. wantDraw is genuinely
    // jittery at the edges: a player standing on the distance limit, or one
    // whose occlusion bit flips between reads, is drawn on some frames and not
    // on others. Counting that directly made the number change several times a
    // second.
    //
    // That was not cosmetic. Every change is a new string, and a new string is
    // a new NSString built in the other process, a setString: and a setFrame:
    // across the process boundary, and all of it inside the publish that is
    // drawing the boxes, so the boxes were dragged along at the counter's
    // rhythm. The reported symptom was the counter flickering and the ESP
    // stuttering in time with it, and both came from here.
    //
    // Three frames is about 85ms at 35fps. Far shorter than looking away from a
    // player and back, far longer than the jitter.
    // The tally itself lives below the draw pass: it needs isOnScreen, which
    // needs the matrix sampled there. Nothing here counts anything.
    s_countOffScreen = 0;
    s_countTeamUnknown = 0;

    // -------------------------------------------------------------------------
    // Phase-2: sample view matrix as late as possible (after all world reads),
    // then project + draw ESP + pick aim. One matrix for the whole project pass.
    // -------------------------------------------------------------------------
    if (!GetViewMatrixInto(camera, matrixData)) {
        // Paths allocated above — free before early out (matrix unavailable this frame).
        CGPathRelease(aNumBGPath);
        CGPathRelease(aNumGPath);
        CGPathRelease(aNumOPath);
        CGPathRelease(aNumRPath);
        if (stats.aimAssistPath) {
            CGPathRelease(stats.aimAssistPath);
            stats.aimAssistPath = NULL;
        }
        return stats;
    }
    // Crowded-match LOD: when many enemies, skip heavy Pro extras for far targets.
    // Keeps Lite/Pro box lock smooth under 30+ players.
    const int crowdN = snapN;
    const bool crowded = crowdN >= 18;
    const bool veryCrowded = crowdN >= 28;
    // Re-sample matrix once more right before project when many targets — collect
    // pass can take several ms and cam has already moved (stick-then-snap feel).
    if (crowded) {
        float matrixRefresh[16];
        if (GetViewMatrixInto(camera, matrixRefresh)) {
            memcpy(matrixData, matrixRefresh, sizeof(matrixData));
        }
    }

    // Draw pass (Lite + Pro) with the fresh matrix.
    for (int si = 0; si < snapN; si++) {
        const EspPawnSnap &s = snaps[si];
        if (!s.wantDraw || !isVaildPtr(s.pawn)) continue;

        Vector3 aimW = looksLikeWorldPos(s.aimPos) ? s.aimPos : s.head;
        Vector3 w2sAimCheck = WorldToScreenLayer(aimW, matrixData, (float)matrixVpWidth, (float)matrixVpHeight, (float)viewWidth, (float)viewHeight);
        bool isOnScreen = (w2sAimCheck.z > 0.001f && w2sAimCheck.x >= 0 && w2sAimCheck.x <= viewWidth && w2sAimCheck.y >= 0 && w2sAimCheck.y <= viewHeight);

        // The tally. 360 degrees, always: every live enemy inside the draw limit
        // counts, the ones behind you and beside you as much as the ones in
        // front, and no pref turns that off. That is what the counter is for.
        //
        // What was broken was never the 360. It was that "enemy" was decided by
        // two live reads that fail open, so the local player and the local team
        // got counted whenever those reads did not come back. The report says it
        // plainly: team of 2, both alive, it says 3; only I die, it says 4. A
        // number that moves when the local player dies is counting the local
        // player. See the identity cache above.
        //
        // 8d06a6a4a made this on-screen only and 14eda906c put the 360 back --
        // both were treating the symptom. f8cc10c92 gated it on "is it drawn",
        // which matched the picture by throwing away the pawns behind the player,
        // which is the half of a 360 that matters. Reverted; 360 stands.
        //
        // Stamped here, before the drawing branches, and the branches that end
        // up drawing nothing drop it again -- see esp_count_drop.
        {
            // Keyed on the pawn pointer, not on uid.
            //
            // It used to be `s.uid ? s.uid : s.pawn`, which is two different keys
            // for one pawn. kUserID is read three times per pawn per frame -- at
            // the self test, in the collect pass, and again at 5140 where s.uid is
            // filled -- and each read can fail on its own. When the 5140 read fails
            // and the earlier one succeeded, this pawn looksups as a new key, gets
            // a second table slot, and both slots are inside ESP_COUNT_HOLD_FRAMES
            // at once. One pawn, two slots, counted twice.
            //
            // That is intermittent by construction -- it needs one read to fail
            // while another succeeds, which is exactly what a degrading cache does
            // -- and it does not need a failure to persist. A pointer cannot fail
            // to be read, so it cannot produce a second key. The pawn pointer is
            // already the identity everything else in this loop uses
            // (PlayerCacheSlot, g_posTrack), and a recycled pointer landing on an
            // old entry just re-stamps it, which counts once and is correct.
            const uint64_t key = s.pawn;
            int slot = -1;
            for (int ci = 0; ci < s_espCountN; ci++) {
                if (s_espCountKey[ci] == key) { slot = ci; break; }
            }
            if (slot < 0) {
                if (s_espCountN < (int)(sizeof(s_espCountKey) / sizeof(s_espCountKey[0]))) {
                    slot = s_espCountN++;
                } else {
                    // Table full: reuse the stalest entry.
                    //
                    // It used to drop the pawn instead, and that is what broke the
                    // counter a while into a session. The table is append-only and
                    // nothing ever freed a slot, so every pawn that ever appeared
                    // kept its entry for the life of the process — 192 of them,
                    // which a few matches fills — and from then on no new pawn
                    // could get a slot at all, so the number stopped moving while
                    // the boxes kept drawing. The three-frame hold has long since
                    // stopped counting those entries, so the stalest one is free to
                    // take.
                    int64_t oldest = INT64_MAX;
                    for (int ci = 0; ci < s_espCountN; ci++) {
                        if (s_espCountFrame[ci] < oldest) {
                            oldest = s_espCountFrame[ci];
                            slot = ci;
                        }
                    }
                    if (slot < 0) slot = 0;
                }
            }
            if (slot >= 0) {
                s_espCountKey[slot] = key;
                s_espCountFrame[slot] = g_cacheFrameCounter;
                s_espCountBot[slot] = s.isBot ? 1 : 0;
            }
            if (!isOnScreen && s.dis < espDistanceLimit) {
                // Counted under the 360 but outside the viewport, so it has no box
                // on screen. Printed so this is a number in the log rather than an
                // argument.
                s_countOffScreen++;
            }
        }

        // [PUSH] 1 Hz on the first drawn snap: splits "frozen data" from
        // "frozen hand-off". w2sAimCheck is already computed for this pawn and
        // is the SAME world point the ESP box is built around, so this costs
        // nothing extra. Read the decision table in the commit message:
        //   world moves + scr moves          -> data & projection alive
        //   world moves + scr frozen         -> projection stuck (GetViewMatrixInto)
        //   world frozen                     -> bone/node offset wrong (kHeadNode family)
        // Compare [PUSH] scr against [SB-PUSH] p0 to see if the push survived.
        if (si == 0) {
            static int s_pushLog = 0;
            if (++s_pushLog % 60 == 1) {
                uint64_t hn = ReadAddr<uint64_t>(s.pawn + kHeadNode);
                uint64_t hp = ReadAddr<uint64_t>(s.pawn + kHipNode);
                uint64_t h628 = ReadAddr<uint64_t>(s.pawn + 0x628);

                // Cache versus no-cache, same frame, same address. Walks the
                // same chain getPositionExt walks and lands on the same
                // Vector3, then reads those 12 bytes twice: once through the
                // page cache, once through ds_read_uncached, which maps the page
                // from scratch and cannot be the reason a value looks frozen.
                //
                // This settles a question the TTL could not. The device log has
                // world constant for 19 seconds while evicts and remaps run at
                // 25/s, so the page really is being replaced and the number
                // still does not move. Either the cache is handing back bytes
                // the game has already changed, or the game genuinely has that
                // value and the fault is in the offset rather than the cache.
                // agree  -> cache innocent, the constant is the game's data
                // differ -> cache lying, and the TTL is not reaching the page
                uint64_t posVA = 0;
                Vector3 fresh{};
                Vector3 rawCached{};
                bool haveFresh = false;
                bool haveRaw = false;
                {
                    // Start from exactly the object getPositionExt was handed.
                    // Reading pawn + kHeadNode directly and then adding
                    // kTransformInner guesses the branch, and getBoneTrans has
                    // three: it returns the node, node+0x10, or one level
                    // deeper. Guessing left posVA=0 on every line, so ok=0 and
                    // differs=0 said nothing at all.
                    uint64_t node = getHead(s.pawn);
                    uint64_t tObj = isVaildPtr((uintptr_t)node)
                                  ? ReadAddr<uint64_t>(node + kTransformInner) : 0;
                    uint64_t mtx = (isVaildPtr((uintptr_t)tObj))
                                 ? ReadAddr<uint64_t>(tObj + kTransformMatrix) : 0;
                    uint64_t idxU = (isVaildPtr((uintptr_t)tObj))
                                  ? ReadAddr<uint64_t>(tObj + kTransformIndex) : 0;
                    uint64_t mlist = (isVaildPtr((uintptr_t)mtx))
                                   ? ReadAddr<uint64_t>(mtx + kMatrixList) : 0;
                    if (isVaildPtr((uintptr_t)mlist) && idxU <= 8192) {
                        posVA = mlist + sizeof(TMatrix) * (size_t)idxU;
                        // Same twelve bytes, two paths. raw goes through the page
                        // cache, fresh maps the page from scratch. Comparing
                        // these two isolates the cache and nothing else.
                        //
                        // Note it must NOT be compared against s.head: that is
                        // the position after the whole parent transform chain has
                        // been folded in, while this is the raw matrix entry. They
                        // are different quantities and are not expected to match.
                        rawCached = ReadAddr<Vector3>(posVA);
                        haveRaw = true;
                        haveFresh = ds_read_uncached(posVA, &fresh, sizeof(Vector3));
                    }
                }
                const int cacheDiffers = (haveFresh && haveRaw &&
                    (memcmp(&rawCached, &fresh, sizeof(Vector3)) != 0)) ? 1 : 0;

                NSLog(@"[PUSH] pawn=0x%llx headN=0x%llx hipN=0x%llx n628=0x%llx "
                      @"world=(%.2f,%.2f,%.2f) scr=(%.1f,%.1f,%.3f) on=%d frame=%d "
                      @"posVA=0x%llx raw=(%.2f,%.2f,%.2f) fresh=(%.2f,%.2f,%.2f) "
                      @"ok=%d differs=%d",
                      (unsigned long long)s.pawn,
                      (unsigned long long)hn, (unsigned long long)hp,
                      (unsigned long long)h628,
                      s.head.x, s.head.y, s.head.z,
                      w2sAimCheck.x, w2sAimCheck.y, w2sAimCheck.z,
                      (int)isOnScreen, g_cacheFrameCounter,
                      (unsigned long long)posVA,
                      rawCached.x, rawCached.y, rawCached.z,
                      fresh.x, fresh.y, fresh.z,
                      (int)haveFresh, cacheDiffers);
            }
        }

        // Alert only nearer off-screen threats; throttle harder when crowded.
        const float alertMaxDis = veryCrowded ? 70.f : (crowded ? 95.f : 120.f);
        if ((isAlert360 || isAlertNum) && !isOnScreen && s.dis < alertMaxDis) {
            float viewX = aimW.x * matrixData[0] + aimW.y * matrixData[4] + aimW.z * matrixData[8] + matrixData[12];
            float viewY = aimW.x * matrixData[1] + aimW.y * matrixData[5] + aimW.z * matrixData[9] + matrixData[13];
            float viewZ = aimW.x * matrixData[2] + aimW.y * matrixData[6] + aimW.z * matrixData[10] + matrixData[14];

            if (viewZ < 0.0f) { viewX *= -1.0f; viewY *= -1.0f; }
            float angle = atan2(-viewY, viewX);

            if (isAlert360) {
                float alertRadius = (viewHeight < viewWidth ? viewHeight : viewWidth) / 2.0f - 55.0f;
                float tipX = screenCenter.x + cos(angle) * alertRadius;
                float tipY = screenCenter.y + sin(angle) * alertRadius;
                float tailRadius = alertRadius - 18.0f;
                float leftX = screenCenter.x + cos(angle - 0.09f) * tailRadius;
                float leftY = screenCenter.y + sin(angle - 0.09f) * tailRadius;
                float rightX = screenCenter.x + cos(angle + 0.09f) * tailRadius;
                float rightY = screenCenter.y + sin(angle + 0.09f) * tailRadius;

                // Onto the alert layer, not onto a snapline layer.
                //
                // It used to go onto whichever snapline path matched the player,
                // which was two bugs at once. It put a moveTo in the middle of the
                // fan, so the decoder split the run there and the layer that had
                // just become one polyline per layer was back to several, and it
                // meant the off-screen markers cost a remote call each, exactly the
                // term the fan was introduced to remove.
                //
                // It also belongs on alertLayer on its own terms: it is a triangle
                // drawn around a player who is off screen, not a line from the top
                // of the screen, and alertLayer already exists and is already
                // published at kShapeKeys index 13.
                CGMutablePathRef tempTriangle = CGPathCreateMutable();
                CGPathMoveToPoint(tempTriangle, NULL, leftX, leftY);
                CGPathAddLineToPoint(tempTriangle, NULL, tipX, tipY);
                CGPathAddLineToPoint(tempTriangle, NULL, rightX, rightY);
                CGPathAddLineToPoint(tempTriangle, NULL, leftX, leftY);
                CGPathAddPath(buffers->alertPath, NULL, tempTriangle);
                CGPathRelease(tempTriangle);
                buffers->alertDirty = YES;
            }

            if (isAlertNum && !(veryCrowded && s.dis > 55.f)) {
                float dx = cos(angle); float dy = sin(angle); float m = dy / dx;
                float radius = 14.0f; float padding = radius + 6.0f;
                float x_edge, y_edge;
                if (dx > 0) x_edge = screenCenter.x - padding;
                else        x_edge = -(screenCenter.x - padding);
                y_edge = x_edge * m;
                if (fabsf(y_edge) > screenCenter.y - padding) {
                    if (dy > 0) y_edge = screenCenter.y - padding;
                    else        y_edge = -(screenCenter.y - padding);
                    x_edge = y_edge / m;
                }
                float edgeX = screenCenter.x + x_edge;
                float edgeY = screenCenter.y + y_edge;
                CGPathAddEllipseInRect(aNumBGPath, NULL, CGRectMake(edgeX - radius, edgeY - radius, radius * 2.0f, radius * 2.0f));
                float hpPercent = Clamp01f((float)s.curHP / (float)s.maxHP);
                if (hpPercent <= 0.0f) hpPercent = 0.01f;
                float startAngle = -M_PI_2;
                float endAngle = startAngle + (M_PI * 2.0f * hpPercent);
                CGMutablePathRef targetArc = aNumGPath;
                if (hpPercent < 0.35f || s.isKnocked) targetArc = aNumRPath;
                else if (hpPercent < 0.70f) targetArc = aNumOPath;
                CGMutablePathRef tempArc = CGPathCreateMutable();
                CGPathAddArc(tempArc, NULL, edgeX, edgeY, radius, startAngle, endAngle, false);
                CGPathAddPath(targetArc, NULL, tempArc);
                CGPathRelease(tempArc);
                NSData *distTextBytes = [@"[%dM]" dataUsingEncoding:NSUTF8StringEncoding];
                NSString *distTextFormat = [[NSString alloc] initWithData:distTextBytes encoding:NSUTF8StringEncoding];
                NSString *distText = [NSString stringWithFormat:distTextFormat, (int)s.dis];
                CGRect textFrame = CGRectMake(edgeX - radius, edgeY - 4.5f, radius * 2.0f, 10.0f);
                ESPViewAddTextCallback((__bridge void *)self, distText, textFrame, [UIColor whiteColor], 8.0f, NO);
            }
        }

        // Lite ESP — body-ratio height (no ankle pump) + screen-space sticky box.
        if (isESP2) {
            Vector3 HeadPos = s.head;
            if (IsZeroVec(HeadPos) || !looksLikeWorldPos(HeadPos)) {
                // Stamped by the tally above, and nothing drawn below. See
                // esp_count_drop.
                esp_count_drop(s.pawn);
                continue;
            }
            Vector3 HipPos = s.hip;
            // Reject detached / inverted hips — bad bones make giant boxes.
            {
                const float bodyLen = (IsZeroVec(HipPos) || !looksLikeWorldPos(HipPos))
                    ? 0.f : Vector3::Distance(HeadPos, HipPos);
                const float dy = HeadPos.y - HipPos.y;
                const float dxz = sqrtf((HeadPos.x - HipPos.x) * (HeadPos.x - HipPos.x) +
                                       (HeadPos.z - HipPos.z) * (HeadPos.z - HipPos.z));
                const bool hipOk = bodyLen >= 0.30f && bodyLen <= 1.35f &&
                                   dy >= 0.20f && dy <= 1.25f && dxz <= 0.85f;
                if (!hipOk) {
                    HipPos = HeadPos;
                    HipPos.y -= s.treatAsVehicle ? 1.00f : 0.88f;
                }
            }
            // Synthetic feet under hip (world) — stable height, not swinging ankles.
            Vector3 FootPos = HipPos;
            FootPos.y -= s.treatAsVehicle ? 0.55f : 0.92f;
            HeadPos.y += 0.08f; // helmet pad in world, not screen inflate
            Vector3 w2sHead = WorldToScreenLayer(HeadPos, matrixData, (float)matrixVpWidth, (float)matrixVpHeight, (float)viewWidth, (float)viewHeight);
            Vector3 w2sHip = WorldToScreenLayer(HipPos, matrixData, (float)matrixVpWidth, (float)matrixVpHeight, (float)viewWidth, (float)viewHeight);
            Vector3 w2sFoot = WorldToScreenLayer(FootPos, matrixData, (float)matrixVpWidth, (float)matrixVpHeight, (float)viewWidth, (float)viewHeight);
            const float ep = viewWidth * 0.35f;
            if (w2sHead.z > 0.001f) {
                float topY = w2sHead.y;
                // Prefer foot/hip column; never use live ankle (pump while walking).
                float bottomY = topY;
                bool haveBot = false;
                if (w2sFoot.z > 0.001f) { bottomY = w2sFoot.y; haveBot = true; }
                if (w2sHip.z > 0.001f) {
                    float hipY = w2sHip.y;
                    if (!haveBot) { bottomY = hipY; haveBot = true; }
                    else bottomY = fmaxf(bottomY, hipY);
                }
                if (!haveBot) bottomY = topY + fmaxf(viewHeight * 0.055f, 20.f);
                if (bottomY < topY + 6.0f) bottomY = topY + fmaxf(viewHeight * 0.055f, 20.f);

                // Body-ratio lock: head→hip is ~half body; scale to full height.
                float hipH = (w2sHip.z > 0.001f) ? fabsf(w2sHip.y - w2sHead.y) : 0.f;
                float ratioH = (hipH > 3.f)
                    ? (s.treatAsVehicle ? hipH * 1.48f : hipH * 2.02f)
                    : 0.f;
                float rawH = bottomY - topY;
                float boxHeight = (ratioH > 4.f) ? ratioH : rawH;
                // Soft blend raw foot if close to ratio (not a spike).
                if (ratioH > 4.f && rawH > 4.f) {
                    float rel = fabsf(rawH - ratioH) / ratioH;
                    if (rel < 0.18f) boxHeight = ratioH * 0.65f + rawH * 0.35f;
                    else boxHeight = ratioH; // reject foot spike
                }
                float maxH = fminf(
                    (hipH > 3.f) ? (s.treatAsVehicle ? hipH * 1.70f : hipH * 2.25f)
                                 : viewHeight * 0.20f,
                    viewHeight * (s.treatAsVehicle ? 0.20f : 0.34f));
                if (boxHeight > maxH) boxHeight = maxH;
                if (boxHeight < (s.treatAsVehicle ? 14.0f : 7.0f))
                    boxHeight = s.treatAsVehicle ? fmaxf(14.0f, viewHeight * 0.04f) : 7.0f;
                // Aspect hugs torso (was fat 0.38–0.48).
                float boxWidth = fmaxf(4.5f, boxHeight * (s.treatAsVehicle ? 0.48f : 0.34f));
                // Center sticks to hip (body column), slight head blend.
                float centerX = (w2sHip.z > 0.001f)
                    ? (w2sHip.x * 0.82f + w2sHead.x * 0.18f)
                    : w2sHead.x;

                // Screen sticky lock — stops to/nhỏ thất thường + bám người.
                SmoothBoxScreen(s.pawn, topY, centerX, boxHeight, boxWidth);

                float padY = fmaxf(boxHeight * 0.015f, 0.8f);
                float boxY = topY - padY;
                boxHeight += padY * 2.0f;
                float boxX = centerX - boxWidth * 0.5f;
                const float hardM = fmaxf(viewWidth, viewHeight) * 0.9f;
                if (centerX >= -hardM && centerX <= viewWidth + hardM &&
                    boxY >= -hardM && boxY <= viewHeight + hardM) {
                    CGMutablePathRef currentBoxPath = buffers->boxPath;
                    CGMutablePathRef currentLinePath = buffers->snaplinePath;
                    if (s.isKnocked) {
                        currentBoxPath = buffers->boxKnockedPath;
                        currentLinePath = buffers->snaplineKnockedPath;
                        buffers->boxKnockedDirty = YES;
                        buffers->snaplineKnockedDirty = YES;
                    } else if (s.isBot) {
                        currentBoxPath = buffers->boxBotPath;
                        currentLinePath = buffers->snaplineBotPath;
                        buffers->boxBotDirty = YES;
                        buffers->snaplineBotDirty = YES;
                    } else {
                        buffers->boxDirty = YES;
                        buffers->snaplineDirty = YES;
                    }
                    CGPathAddRect(currentBoxPath, NULL, CGRectMake(boxX, boxY, boxWidth, boxHeight));
                    // Snapline stays a real slanted line. It was briefly redrawn as
                    // rectangles to save a remote call, and that was a bad trade:
                    // a slanted line's corners are not its bounding box's corners,
                    // so the decoder's rectangle test rejected it anyway, and the
                    // elbow it drew hid the nearer player behind the farther one.
                    //
                    // What works is the fan. Every ray starts at the same point, so
                    // the layer is one polyline going origin, target, origin, target
                    // and so on: one remote call for the layer rather than one per
                    // player. See ESPAddFanRay in espdraw.mm for why the doubled leg
                    // is what stops CGPathAddLines from stringing a cable between
                    // one player and the next.
                    bool *fanStarted = &buffers->snaplineFanStarted;
                    if (s.isKnocked) fanStarted = &buffers->snaplineKnockedFanStarted;
                    else if (s.isBot) fanStarted = &buffers->snaplineBotFanStarted;
                    ESPAddFanRay(currentLinePath,
                                 CGPointMake(screenCenter.x, 45.0f),
                                 CGPointMake(centerX, boxY),
                                 fanStarted);

                    const bool liteOnScreen = (w2sHead.x >= -ep && w2sHead.x <= viewWidth + ep &&
                                               w2sHead.y >= -ep && w2sHead.y <= viewHeight + ep);
                    if (liteOnScreen && s.maxHP > 0) {
                        float hpPerc = Clamp01f((float)s.curHP / (float)s.maxHP);
                        CGMutablePathRef currentHpPath = buffers->hpFillGreenPath;
                        bool *hpDirtyFlag = &buffers->hpFillGreenDirty;
                        if (hpPerc <= 0.35f) { currentHpPath = buffers->hpFillRedPath; hpDirtyFlag = &buffers->hpFillRedDirty; }
                        else if (hpPerc <= 0.70f) { currentHpPath = buffers->hpFillOrangePath; hpDirtyFlag = &buffers->hpFillOrangeDirty; }
                        float hpBarWidth = fmaxf(1.5f, boxWidth * 0.05f);
                        float hpBarHeight = boxHeight * hpPerc;
                        float hpBarX = boxX + boxWidth;
                        float hpBarY = boxY + (boxHeight - hpBarHeight);
                        CGPathAddRect(buffers->bgFillBlackPath, NULL, CGRectMake(hpBarX, boxY, hpBarWidth, boxHeight));
                        buffers->bgFillBlackDirty = YES;
                        CGPathAddRect(currentHpPath, NULL, CGRectMake(hpBarX, hpBarY, hpBarWidth, hpBarHeight));
                        *hpDirtyFlag = YES;
                    }
                }
            }
        } else if (isESP) {
            // CurHP<=0 is terminal; ignore lagged isKnocked (corpse/transition ghost).
            if (s.curHP <= 0) {
                // Unreachable in practice: the collect pass drops CurHP <= 0
                // before the snapshot is ever built, so no snap can arrive here
                // with a dead HP. Kept as a belt-and-braces guard, and it still
                // drops the tally, because if it ever does fire the pawn is
                // drawn by nothing. See esp_count_drop.
                esp_count_drop(s.pawn);
                continue;
            }
            // Crowded Pro: far off-screen enemies skip full Pro path (still counted/alerted).
            if (crowded && !isOnScreen && s.dis > (veryCrowded ? 80.f : 120.f)) {
                continue;
            }
            Vector3 hipP = s.hip;
            if (IsZeroVec(hipP) || !looksLikeWorldPos(hipP) ||
                Vector3::Distance(s.head, hipP) < 0.25f) {
                hipP = s.head;
                hipP.y -= s.treatAsVehicle ? 1.05f : 0.85f;
            }
            RenderESPForPawnEx(buffers, ESPViewAddTextCallback, ESPViewAddImageCallback,
                               (__bridge void *)self, s.pawn, s.curHP, s.dis, matrixData,
                               (float)viewWidth, (float)viewHeight, (float)matrixVpWidth, (float)matrixVpHeight,
                               s.head.x, s.head.y, s.head.z,
                               hipP.x, hipP.y, hipP.z,
                               s.isBot ? 1 : 0, s.isKnocked ? 1 : 0);
        }
    }

    // The count, with hysteresis, now that the draw pass has stamped it.
    //
    // A pawn counts if it was on screen within the last ESP_COUNT_HOLD_FRAMES
    // frames, not only if it is on screen on this one, because isOnScreen flips on
    // the edges of the viewport with every camera move. Counting that directly made
    // the number change several times a second.
    //
    // That was not cosmetic either. Every change is a new string, and a new string
    // is a new NSString built in the other process, a setString: and a setFrame:
    // across the process boundary, and all of it inside the publish that is drawing
    // the boxes, so the boxes were dragged along at the counter's rhythm.
    //
    // Three frames is about 85ms at 35fps. Far shorter than looking away from a
    // player and back, far longer than the jitter.
    {
        int rc = 0, bc = 0;
        for (int ci = 0; ci < s_espCountN; ci++) {
            if (g_cacheFrameCounter - s_espCountFrame[ci] > ESP_COUNT_HOLD_FRAMES) continue;
            if (s_espCountBot[ci]) bc++; else rc++;
        }
        stats.realCount = rc;
        stats.botCount = bc;
    }

    static int s_countDiagLog = 0;
    if (++s_countDiagLog % 180 == 1) {
        // Distance spread of everything in the tally, in metres from the local
        // player. off= with snapN= says only that nothing landed inside the
        // viewport, and that is the same number whether the pawns are standing in
        // a circle at arm's length or spread across a hundred metres of map. The
        // two need opposite fixes: a tight spread means the world positions are
        // collapsing onto the camera and getPositionExt is folding the wrong
        // chain, a wide spread means the positions are fine and the divisor row
        // of the projection is wrong. s.dis is already on every snapshot for the
        // distance limit, so this reads what the frame already computed.
        float dmin = -1.0f, dmax = -1.0f;
        for (int si = 0; si < snapN; si++) {
            const float d = snaps[si].dis;
            if (d < 0.0f) continue;
            if (dmin < 0.0f || d < dmin) dmin = d;
            if (dmax < 0.0f || d > dmax) dmax = d;
        }
        // cap   = dictionary capacity, an Il2CppArray max_length and NOT a player
        //         count -- see the gate above
        // dc    = dictCount, the live entries the dictionary says it holds
        // walk  = slots iterated after the clamp, i.e. min(cap, kMaxWalkSlots)
        // clamped = the walk ended on kMaxWalkSlots rather than on the live count
        // iter  = loop iterations performed (walk, minus an early exit on the live
        //         count); read = slots among them that were not free markers
        // live  = pawns accepted after the duplicate filter
        // dup   = slots that named a pawn an earlier slot already named
        // probe = pawns whose value did not read at the documented entry offset and
        //         came from a layout-probe offset instead (0x10/0x18 sit inside the
        //         key, so this is the widest remaining phantom surface)
        // stopLive = the walk ended on dictCount, which is the NORMAL end of a walk
        // drop  = pawns refused because the 128-snapshot buffer was full
        g_st.match      = match;
        g_st.dict       = playerDict;
        g_st.local      = myPawnObject;
        g_st.slotCap    = slotCap;
        g_st.dictCount  = dictCount;
        g_st.walk       = loopCount;
        g_st.clamped    = dictClamped;
        g_st.iters      = dictIters;
        g_st.readSlots  = dictWalkSlots;
        g_st.live       = dictLive;
        g_st.dupes      = dictDupes;
        g_st.probe      = dictValueProbe;
        g_st.stopLive   = dictStopLive;
        g_st.snapDrop   = snapDrop;
        g_st.snapN      = snapN;
        g_st.real       = stats.realCount;
        g_st.bots       = stats.botCount;
        g_st.offScreen  = s_countOffScreen;
        g_st.teamUnknown = s_countTeamUnknown;
        g_st.selfSkip   = selfSkipped;
        g_st.dmin       = dmin;
        g_st.dmax       = dmax;
        g_st.gate       = 0;
        g_st.aimTarget  = gAimLockTarget;
        g_st.rej        = rej;
    }

    // Aim target pick on the same fresh matrix as ESP.
    const bool allowThroughWall = AimThroughAnyCoverNow();
    if (iAmAlive && useAim) {
        for (int si = 0; si < snapN; si++) {
            const EspPawnSnap &s = snaps[si];
            if (!s.canAim || s.dis > aimDistance) continue;
            uint64_t PawnObject = s.pawn;
            Vector3 aimPos = s.aimPos;
            Vector3 headBonePos = s.head;
            float dis = s.dis;
            int CurHP = s.curHP;
            bool isBot = s.isBot;
            bool isKnocked = s.isKnocked;

            Vector3 w2sAim = WorldToScreenLayer(aimPos, matrixData, (float)matrixVpWidth, (float)matrixVpHeight, (float)viewWidth, (float)viewHeight);
            BOOL canConsiderForAim = YES;
            // CurHP<=0 is terminal; do not aim ghosts even if isKnocked lags.
            if (CurHP <= 0) canConsiderForAim = NO;
            if (isAimIgnoreKnock && isKnocked) canConsiderForAim = NO;
            if (isAimIgnoreBot && isBot) canConsiderForAim = NO;

            const bool inFront = (w2sAim.z > 0.001f);
            const float pad = 2.0f;
            const bool onScreen = inFront &&
                w2sAim.x >= -pad && w2sAim.x <= viewWidth + pad &&
                w2sAim.y >= -pad && w2sAim.y <= viewHeight + pad;

            if (!allowThroughWall || (!useSphereAim && !silentSphereOnly)) {
                if (!inFront) {
                    canConsiderForAim = NO;
                } else if (!onScreen) {
                    if (!allowThroughWall) {
                        const float wallOffPad = 36.0f;
                        const bool softOn = w2sAim.x >= -wallOffPad && w2sAim.x <= viewWidth + wallOffPad &&
                                           w2sAim.y >= -wallOffPad && w2sAim.y <= viewHeight + wallOffPad;
                        if (!softOn) canConsiderForAim = NO;
                    } else {
                        canConsiderForAim = NO;
                    }
                }
            } else if (useAim180 && !silentSphereOnly) {
                if (!inFront) canConsiderForAim = NO;
            }

            if (!canConsiderForAim) continue;

            // After the early-out, not before it. This is the LOS gate for one
            // candidate, and in wall-off mode it is not a local computation:
            // GameClearLosToEnemy walks the IceWall aim-assist list, up to 31
            // candidate objects times two pointer reads each, plus the
            // last-weapon-target read. Off-screen and behind-camera pawns -- most of
            // them in a fifty to a hundred player match, where the ring is a few
            // dozen pixels on a 390pt-tall viewport -- can never reach posLos: its
            // only consumer is the bucket update further down, which is behind this
            // continue. Nothing between the old and the new position reads it, so
            // moving it is exactly equivalent for every candidate that survives.
            const bool posLos = allowThroughWall
                ? true
                : GameClearLosToEnemy(myPawnObject, PawnObject, aimPos);

            float deltaX = 0.f, deltaY = 0.f, distSq = 0.f;
            if (inFront) {
                deltaX = w2sAim.x - screenCenter.x;
                deltaY = w2sAim.y - screenCenter.y;
                distSq = deltaX * deltaX + deltaY * deltaY;
            }

            bool inRange = false;
            if (!allowThroughWall) {
                if (isAimbot && useAim180) {
                    inRange = inFront;
                } else if (isAimbot) {
                    float fovSq = aimFovSq > 1.f ? aimFovSq : (150.f * 150.f);
                    inRange = inFront && (distSq <= fovSq);
                } else if (useAssistOnly || useSilent || silentSphereOnly) {
                    float rSq = fmaxf(assistRadiusSq, aimFovSq > 1.f ? aimFovSq : (150.f * 150.f));
                    inRange = inFront && (distSq <= rSq);
                }
            } else if (useSilent || (isAimbot && useAim360) || silentSphereOnly) {
                inRange = true;
            } else if (isAimbot && useAim180) {
                inRange = inFront;
            } else if (isAimbot) {
                inRange = inFront && (aimFovSq > 0.f) && (distSq <= aimFovSq);
            } else if (useAssistOnly) {
                inRange = inFront && (distSq <= assistRadiusSq);
            }

            if (!inRange) continue;

            float distanceNorm = dis / safeAimDistance;
            float score = 0.0f;
            const bool scoreAsSphere = allowThroughWall && (useSphereAim || useSilent || silentSphereOnly);
            if (scoreAsSphere) {
                if (aimTargetMode == 1) {
                    float hpNorm = fminf((float)CurHP / 200.0f, 1.5f);
                    score = hpNorm * 0.70f + distanceNorm * 0.30f;
                } else {
                    score = distanceNorm;
                }
                if (inFront) {
                    float screenBias = fminf(distSq / (viewWidth * viewWidth + 1.f), 1.f);
                    score = score * 0.85f + screenBias * 0.15f;
                } else if (useAim360 || silentSphereOnly) {
                    score += 0.05f;
                }
            } else {
                float fovSq = fmaxf(aimFovSq > 1.f ? aimFovSq : safeAimFovSq, 1.f);
                float rangeNorm = isAimbot
                    ? (distSq / fovSq)
                    : (distSq / fmaxf(assistRadiusSq, 1.f));
                if (isAimbot || (useAssist && !useAssistOnly)) {
                    if (aimTargetMode == 0) {
                        score = rangeNorm * 0.85f + distanceNorm * 0.15f;
                    } else if (aimTargetMode == 1) {
                        float hpNorm = fminf((float)CurHP / 200.0f, 1.5f);
                        score = hpNorm * 0.65f + rangeNorm * 0.25f + distanceNorm * 0.10f;
                    } else {
                        score = distanceNorm * 0.75f + rangeNorm * 0.25f;
                    }
                } else if (useAssistOnly) {
                    if (aimTargetMode == 0) {
                        score = rangeNorm * 0.90f + distanceNorm * 0.10f;
                    } else if (aimTargetMode == 1) {
                        float hpNorm = fminf((float)CurHP / 200.0f, 1.5f);
                        score = rangeNorm * 0.55f + hpNorm * 0.35f + distanceNorm * 0.10f;
                    } else {
                        score = rangeNorm * 0.45f + distanceNorm * 0.55f;
                    }
                } else {
                    score = rangeNorm;
                }
            }
            if (PawnObject == gAimLockTarget) score *= 0.18f;
            if (isBot && !isAimIgnoreBot) score *= 0.92f;

            // Always pick with AimPos bone (aimPos already mode-aware for silent/aimbot/assist).
            Vector3 pickHead = aimPos;
            if (allowThroughWall) {
                if (score < bestAnyScore) {
                    bestAnyScore = score;
                    bestAnyDist = dis;
                    bestAnyVis = true;
                    bestAnyTarget = PawnObject;
                    bestAnyHead = pickHead;
                }
            }
            if (posLos && score < bestLosScore) {
                bestLosScore = score;
                bestLosDist = dis;
                bestLosVis = true;
                bestLosTarget = PawnObject;
                bestLosHead = pickHead;
                if (!allowThroughWall && score < bestAnyScore) {
                    bestAnyScore = score;
                    bestAnyDist = dis;
                    bestAnyVis = true;
                    bestAnyTarget = PawnObject;
                    bestAnyHead = pickHead;
                }
            }
        }
    }

    // allowThroughWall already sampled above (aim pick + sticky resolve share it).

    // -------------------------------------------------------------------------
    // Drop stale locks for pawns that left this frame's processed set.
    // If an enemy we were aiming/silently targeting walked out of ESP/aim range
    // (or despawned), it will no longer appear in snaps[]. Carrying the lock
    // causes per-frame re-validation reads + possible thread work on a pawn
    // that is no longer "hot", which manifests as treo/hitch exactly when the
    // target "ra khỏi tầm esp".
    // -------------------------------------------------------------------------
    if (gAimLockTarget != 0) {
        bool stillInFrame = false;
        for (int si = 0; si < snapN; si++) {
            if (snaps[si].pawn == gAimLockTarget) { stillInFrame = true; break; }
        }
        if (!stillInFrame) {
            gAimLockTarget = 0;
            gAimLockLostFrames = 0;
            s_lockHoldFrames = 0;
        }
    }
    if (g_silentLockedEnemy != 0) {
        bool stillInFrame = false;
        for (int si = 0; si < snapN; si++) {
            if (snaps[si].pawn == g_silentLockedEnemy) { stillInFrame = true; break; }
        }
        if (!stillInFrame) {
            SilentAimClearTarget();
        }
    }

    // Also drop s_lastAimPawn (used for fire-stick "keep look while dragging" assist)
    // if its pawn left the processed set this frame.
    if (s_lastAimPawn != 0) {
        bool stillInFrame = false;
        for (int si = 0; si < snapN; si++) {
            if (snaps[si].pawn == s_lastAimPawn) { stillInFrame = true; break; }
        }
        if (!stillInFrame) {
            s_lastAimPawn = 0;
        }
    }

    // Raw "best this frame" before sticky hysteresis.
    uint64_t rawBestTarget = 0;
    Vector3 rawBestHead{};
    float rawBestDist = FLT_MAX;
    float rawBestScore = FLT_MAX;
    bool rawBestVis = false;

    // Resolve best target.
    // Wall-ON: FOV/sphere candidates (bestAny).
    // Wall-OFF: game-clear LOS candidates preferred, fallback to on-screen FOV candidates.
    if (!allowThroughWall) {
        if (bestLosTarget != 0) {
            rawBestTarget = bestLosTarget;
            rawBestHead = bestLosHead;
            rawBestDist = bestLosDist;
            rawBestScore = bestLosScore;
            rawBestVis = true;
        } else if (bestAnyTarget != 0) {
            rawBestTarget = bestAnyTarget;
            rawBestHead = bestAnyHead;
            rawBestDist = bestAnyDist;
            rawBestScore = bestAnyScore;
            rawBestVis = true;
        }
    } else if (bestAnyTarget != 0) {
        rawBestTarget = bestAnyTarget;
        rawBestHead = bestAnyHead;
        rawBestDist = bestAnyDist;
        rawBestScore = bestAnyScore;
        rawBestVis = bestAnyVis;
    }

    // ---- Sticky target hysteresis (cluster fix) ----
    // If we already lock A and B is only slightly "better", keep A.
    // Switch only when challenger is clearly better, or lock is dead/out of range.
    bestTarget = rawBestTarget;
    bestHeadPos = rawBestHead;
    bestDistance = rawBestDist;
    bestScore = rawBestScore;
    isVis = rawBestVis;

    static float s_lockScore = FLT_MAX; (void)s_lockScore;
    // s_lockHoldFrames declared at file scope (above) to allow cleanup on treo fix
    // reuse it here without redeclaring static
    const bool firingNow = isVaildPtr(myPawnObject) && get_IsFiring(myPawnObject);

    if (gAimLockTarget != 0 && isVaildPtr(gAimLockTarget)) {
        // Find locked pawn's score among this frame's candidates (recompute lightly).
        float lockedScore = FLT_MAX;
        Vector3 lockedHead{};
        float lockedDist = FLT_MAX;
        bool lockedFound = false;
        bool lockedLos = false;
        // Prefer already-picked buckets if lock is the raw winner.
        // Wall-off: still re-validate live LOS so sticky cannot keep a covered target.
        if (rawBestTarget == gAimLockTarget) {
            Vector3 lb = rawBestHead;
            if (IsZeroVec(lb) || !looksLikeWorldPos(lb)) {
                lb = GetAimTargetPosModeOnce(gAimLockTarget, aimPosition, aimDistance);
            }
            const bool liveLos = allowThroughWall
                ? true
                : GameClearLosToEnemy(myPawnObject, gAimLockTarget, lb);
            if (liveLos) {
                lockedFound = true;
                lockedScore = rawBestScore;
                lockedHead = rawBestHead;
                lockedDist = rawBestDist;
                lockedLos = true;
            }
        } else if (bestLosTarget == gAimLockTarget) {
            Vector3 lb = bestLosHead;
            if (IsZeroVec(lb) || !looksLikeWorldPos(lb)) {
                lb = GetAimTargetPosModeOnce(gAimLockTarget, aimPosition, aimDistance);
            }
            const bool liveLos = allowThroughWall
                ? true
                : GameClearLosToEnemy(myPawnObject, gAimLockTarget, lb);
            if (liveLos) {
                lockedFound = true;
                lockedScore = bestLosScore;
                lockedHead = bestLosHead;
                lockedDist = bestLosDist;
                lockedLos = true;
            }
        } else if (bestAnyTarget == gAimLockTarget) {
            // Wall-ON FOV set only. Wall-off never uses bestAny without LOS.
            if (allowThroughWall) {
                lockedFound = false; // re-score live below
            } else {
                lockedFound = false;
            }
        }

        if (!lockedFound) {
            // Live re-eval of locked pawn (still in match dict).
            // Ghost: require MaxHP>0 + live bone — never sticky-track invent.
            int lhp = get_CurHP(gAimLockTarget);
            int lmax = get_MaxHP(gAimLockTarget);
            const bool lknock = get_IsKnockedDown(gAimLockTarget);
            Vector3 liveHeadTarget = getPositionExt(getHead(gAimLockTarget));
            const bool hasLiveHead = looksLikeWorldPos(liveHeadTarget);
            if (hasLiveHead && lhp <= 0 && lmax <= 0) { lhp = 200; lmax = 200; }
            const bool lhpBad = !hasLiveHead && (lmax <= 0 || lmax > 2000 || (lhp == 0 && lmax == 0) || (lhp <= 0));
            if (!lhpBad && (lhp > 0) && !(isAimIgnoreKnock && lknock) &&
                !(isAimIgnoreBot && get_IsBot(gAimLockTarget))) {
                Vector3 lb = GetAimTargetPosModeOnce(gAimLockTarget, aimPosition, aimDistance);
                if (IsZeroVec(lb) || !looksLikeWorldPos(lb)) {
                    if (hasLiveHead) lb = liveHeadTarget;
                }
                if (!IsZeroVec(lb) && looksLikeWorldPos(lb)) {
                    float ld = iAmAlive ? Vector3::Distance(myLocation, lb) : 10.f;
                    if (ld <= aimDistance + 5.f && ld >= 0.15f) {
                        Vector3 w2s = WorldToScreenLayer(lb, matrixData, (float)matrixVpWidth, (float)matrixVpHeight,
                                                        (float)viewWidth, (float)viewHeight);
                        const bool inF = w2s.z > 0.001f;
                        float dsq = 0.f;
                        if (inF) {
                            float dx = w2s.x - screenCenter.x, dy = w2s.y - screenCenter.y;
                            dsq = dx*dx + dy*dy;
                        }
                        bool inR = false;
                        const float baseFovSq = aimFovSq > 1.f ? aimFovSq : (150.f * 150.f);
                        // x2.25 on the square while the lock is held, matching the
                        // working reference (tipar-normal esp.mm:4936). 09fbf6da0
                        // made this the ring's own radius after ten frames, which
                        // is what stopped the aim: the target was acquired and then
                        // failed this test on the following frame.
                        const float keepFovSq = baseFovSq * 2.25f;
                        if (!allowThroughWall) {
                            if (isAimbot && useAim180) inR = inF;
                            else if (isAimbot) {
                                inR = inF && (dsq <= keepFovSq);
                            } else {
                                inR = inF && (dsq <= assistRadiusSq * 1.5f);
                            }
                        } else if (useSilent || (isAimbot && useAim360) || silentSphereOnly) {
                            inR = true;
                        } else if (isAimbot && useAim180) {
                            inR = inF;
                        } else if (isAimbot) {
                            inR = inF && (dsq <= keepFovSq);
                        } else {
                            inR = inF && (dsq <= assistRadiusSq * 1.5f);
                        }
                        if (inR) {
                            // Wall/ice-off: FOV alone is NOT enough. Re-check real LOS every
                            // sticky re-eval. Old AimHasPositiveLos() always returned true →
                            // kept locking targets behind bom keo after toggle OFF.
                            const bool liveLos = allowThroughWall
                                ? true
                                : GameClearLosToEnemy(myPawnObject, gAimLockTarget, lb);
                            if (!liveLos) {
                                // Drop sticky candidate this frame (behind wall/bom keo).
                            } else {
                                float distanceNorm = ld / fmaxf(aimDistance, 1.f);
                                float fovSq = fmaxf(aimFovSq > 1.f ? aimFovSq : (150.f * 150.f), 1.f);
                                float rangeNorm = isAimbot ? (dsq / fovSq) : (dsq / fmaxf(assistRadiusSq, 1.f));
                                float sc = rangeNorm * 0.85f + distanceNorm * 0.15f;
                                sc *= 0.18f; // same lock bias
                                lockedScore = sc;
                                lockedHead = lb;
                                lockedDist = ld;
                                lockedLos = true;
                                lockedFound = true;
                            }
                        }
                    }
                }
            }
        }

        if (lockedFound) {
            // Keep lock unless challenger is clearly better.
            // Firing: almost never switch (cluster + stick thrash).
            // Idle: need ~40% better score to switch (lower is better).
            const float switchRatio = firingNow ? 0.45f : 0.62f;
            bool keepLock = true;
            // Wall/bom-keo off: sticky must not keep a no-LOS target (e.g. ducked into ice).
            if (!allowThroughWall && !lockedLos) {
                keepLock = false;
            } else if (rawBestTarget != 0 && rawBestTarget != gAimLockTarget) {
                // rawBestScore already has NO lock bias on challenger.
                // lockedScore has *0.18 bias — compare apples: use unbias approx.
                float lockedUnbias = lockedScore / 0.18f;
                if (rawBestScore < lockedUnbias * switchRatio) {
                    // Challenger much better (closer to crosshair / priority).
                    keepLock = false;
                }
            } else if (rawBestTarget == 0) {
                // No other candidate — keep lock if still valid.
                keepLock = true;
            }
            // Minimum hold frames after acquire (prevents 1-frame flip-flop).
            // Never override a hard no-LOS drop when wall/ice cover aim is off.
            if (keepLock || allowThroughWall || lockedLos) {
                if (s_lockHoldFrames < 8) keepLock = true;
                if (firingNow && s_lockHoldFrames < 14) keepLock = true;
            }
            // Re-assert: wall-off + no LOS never sticky-holds (bom keo OFF).
            if (!allowThroughWall && !lockedLos) keepLock = false;

            if (keepLock) {
                bestTarget = gAimLockTarget;
                bestHeadPos = lockedHead;
                bestDistance = lockedDist;
                bestScore = lockedScore;
                isVis = lockedLos;
                s_lockScore = lockedScore;
                s_lockHoldFrames++;
            } else {
                // Switch to raw best.
                bestTarget = rawBestTarget;
                bestHeadPos = rawBestHead;
                bestDistance = rawBestDist;
                bestScore = rawBestScore;
                isVis = rawBestVis;
                s_lockScore = rawBestScore;
                s_lockHoldFrames = 0;
            }
        } else {
            // Lock invalid this frame.
            gAimLockLostFrames++;
            if (gAimLockLostFrames <= kAimLockMaxLostFrames && rawBestTarget == 0) {
                // Brief miss with no alternative — drop soft (don't invent ghost aim).
                bestTarget = 0;
            } else {
                bestTarget = rawBestTarget;
                bestHeadPos = rawBestHead;
                bestDistance = rawBestDist;
                bestScore = rawBestScore;
                isVis = rawBestVis;
                s_lockHoldFrames = 0;
            }
        }
    } else if (rawBestTarget != 0) {
        bestTarget = rawBestTarget;
        bestHeadPos = rawBestHead;
        bestDistance = rawBestDist;
        bestScore = rawBestScore;
        isVis = rawBestVis;
        s_lockHoldFrames = 0;
        s_lockScore = rawBestScore;
    }

    // The AIM DIAG block that used to sit here is gone. It wrote an [aim] line
    // into the Log tab every five seconds, and that tab is where the user reads
    // session start and stop. Every value it printed is readable somewhere that
    // matters now: the engine runs in another process, and the reason settings
    // appeared to do nothing was that they were never reaching it. That was
    // fixed by reloading the prefs file, not by watching it not arrive.

    // Live target validity: kill / despawn / invalid bone must hard-stop aim immediately.
    // Ghost: MaxHP must be live; bone must be live (no sticky-track invent).
    // Wall-off: FOV geometry + adaptive LOS (Camera when flags work).
    auto AimTargetStillValid = [&](uint64_t pawn) -> bool {
        if (!isVaildPtr(pawn)) return false;
        int hp = get_CurHP(pawn);
        int maxHp = get_MaxHP(pawn);
        const bool knocked = get_IsKnockedDown(pawn);
        Vector3 liveHeadCheck = getPositionExt(getHead(pawn));
        const bool hasLiveHead = looksLikeWorldPos(liveHeadCheck);

        if (hasLiveHead && hp <= 0 && maxHp <= 0) {
            hp = 200; maxHp = 200;
        } else if (hasLiveHead && maxHp <= 0) {
            maxHp = 200; if (hp <= 0) hp = 200;
        }

        // Dead / unreadable / garbage HP shell → drop lock (no ghost aim).
        if (!hasLiveHead && (maxHp <= 0 || maxHp > 2000)) return false;
        if (!hasLiveHead && (hp == 0 && maxHp == 0)) return false;
        if (!hasLiveHead && (hp <= 0)) return false;
        if (hp > 2000 || (maxHp > 0 && hp > maxHp + 50)) return false;
        if (isAimIgnoreKnock && knocked) return false;
        if (isAimIgnoreBot && get_IsBot(pawn)) return false;
        // Memoized. This lambda runs three times per frame on the same pawn (the
        // pre-decision check, the silent branch, the camera branch) and the bone it
        // resolves is the same point all three times. What is NOT memoized, and must
        // not be, is the liveness gate above it: liveHeadCheck is a live
        // getPositionExt(getHead(pawn)) on every call, so a pawn that dies
        // mid-frame is still caught. Only the redundant re-walk of the chain goes.
        Vector3 bone = (useSilent && !isAimbot && !useAssist)
            ? ResolveSilentAimWorldPosOnce(pawn, aimPosition)
            : GetAimTargetPosModeOnce(pawn, aimPosition, bestDistance);
        if (IsZeroVec(bone) || !looksLikeWorldPos(bone)) {
            Vector3 liveHead = getPositionExt(getHead(pawn));
            if (looksLikeWorldPos(liveHead)) bone = liveHead;
            else {
                Vector3 liveRoot = ReadPlayerRootTransform(pawn);
                Vector3 mount{};
                if (IsActivelyMounted(pawn, &mount) && looksLikeWorldPos(mount)) bone = mount;
                else if (looksLikeWorldPos(liveRoot)) {
                    bone = liveRoot;
                    bone.y += 0.85f;
                } else {
                    return false; // no live anchor — ghost shell
                }
            }
        }
        if (IsZeroVec(bone) || !looksLikeWorldPos(bone)) return false;
        // Near world origin = classic despawn ghost
        if (fabsf(bone.x) < 0.5f && fabsf(bone.z) < 0.5f && fabsf(bone.y) < 2.0f) return false;
        // Collapsed standing body without mount → ghost leftover
        {
            Vector3 lh = getPositionExt(getHead(pawn));
            Vector3 lp = getPositionExt(getHip(pawn));
            Vector3 mount{};
            const bool mounted = IsActivelyMounted(pawn, &mount) || looksLikeWorldPos(mount);
            if (!mounted && looksLikeWorldPos(lh) && looksLikeWorldPos(lp) &&
                Vector3::Distance(lh, lp) < 0.35f && !knocked) {
                return false;
            }
        }
        // Wall-off: require live game clear LOS every frame (drop when they duck behind cover).
        if (!allowThroughWall && !GameClearLosToEnemy(myPawnObject, pawn, bone)) return false;
        // Wall-off: stay in front of camera (FOV activation), same matrix as pick.
        if (!allowThroughWall) {
            Vector3 w2s = WorldToScreenLayer(bone, matrixData, (float)matrixVpWidth, (float)matrixVpHeight,
                                            (float)viewWidth, (float)viewHeight);
            const float pad = 48.0f;
            if (w2s.z <= 0.001f ||
                w2s.x < -pad || w2s.x > viewWidth + pad ||
                w2s.y < -pad || w2s.y > viewHeight + pad) {
                return false;
            }
            // FOV gate while locked: much wider slack. Fire-stick drag yanks FOV off target
            // and used to hard-drop the lock every frame (main "giật khi kéo nút bắn").
            // Live fire check here (fireWindow not in scope yet).
            const bool stickFighting = isVaildPtr(myPawnObject) && get_IsFiring(myPawnObject);
            if (isAimbot && !useAim180 && !stickFighting) {
                float dx = w2s.x - screenCenter.x;
                float dy = w2s.y - screenCenter.y;
                float fovSq = aimFovSq > 1.f ? aimFovSq : (150.f * 150.f);
                // Lock-hold slack x1.5 on the square, matching the working
                // reference (tipar-normal esp.mm:5128): enough that dragging the
                // fire stick does not drop the lock every frame, tight enough that
                // it does not hold a target across the screen. 2.25 was too sticky
                // there; 1.0 (what 09fbf6da0 tried) drops the lock mid-aim, which
                // reads as "the aim does nothing" because the target is picked and
                // then thrown away on the next frame.
                const float lim = fovSq * 1.5f;
                if ((dx * dx + dy * dy) > lim) return false;
            }
        }
        if (iAmAlive) {
            float d = Vector3::Distance(myLocation, bone);
            // Allow closer while mounted/passenger; only block true self-range ghosts.
            if (d < 0.15f || d > aimDistance + 5.0f) return false;
        }
        return true;
    };

    if (bestTarget != 0 && !AimTargetStillValid(bestTarget)) {
        bestTarget = 0;
        isVis = false;
    }

    if (!useAim || !iAmAlive) {
        gAimLockTarget = 0; gAimLockLostFrames = 0;
        s_lockHoldFrames = 0;
        update_aim_assist_legit_tuning(false);
    } else if (bestTarget != 0) {
        if (gAimLockTarget != bestTarget) s_lockHoldFrames = 0;
        gAimLockTarget = bestTarget;
        gAimLockLostFrames = 0;
    } else {
        // Target gone/killed: never keep sticky lock.
        gAimLockTarget = 0; gAimLockLostFrames = 0;
        s_lockHoldFrames = 0;
    }

    // Trigger state lives outside the "has target" branch so releasing fire/scope
    // still hard-stops aim immediately even when target just died.
    static uint64_t s_lastAimPawn = 0;

    bool rawScope = isVaildPtr(myPawnObject) ? get_IsScoping(myPawnObject) : false;
    bool rawFire  = isVaildPtr(myPawnObject) ? get_IsFiring(myPawnObject) : false;
    bool isFiring  = rawFire;
    bool isScoping = rawScope;

    int trig = triggerMode;
    if (trig < 0) trig = 0;
    if (trig > 3) trig = 3;
    // Camera aim activation: ONLY live fire/scope state — no "bulletJustFired" lag
    // (that kept LookAt/thread alive after release → cam lắc / aim dính thêm 1 xíu).
    bool shouldActivate = false;
    switch (trig) {
        case 1: shouldActivate = isFiring; break;                 // Fire only
        case 2: shouldActivate = isScoping; break;                // Scope only
        case 3: shouldActivate = (isFiring || isScoping); break;  // Fire OR Scope
        case 0:
        default: shouldActivate = true; break;                    // Auto
    }

    // No override here for Aim Assist. This used to force shouldActivate = true
    // whenever assist ran on its own, which threw the Trigger selection away in
    // exactly the mode where a user is most likely to set one: pick Both, see the
    // camera keep tracking, and conclude the setting does nothing. The trigger is
    // the user's decision about when aim may move the camera, and it is read
    // from the same pref in every mode.
    // Silent (AimSilent.h style): keep a locked target for a high-freq direction-rewrite
    // thread. Camera aim (Aimbot/Assist) stays independent via LookAt.
    const bool cameraAimActive = (isAimbot || useAssist) && shouldActivate;
    const bool silentActive = useSilent && iAmAlive && isVaildPtr(myPawnObject);

    // The two GameVarDef flags that decide whether the rotation we write is
    // allowed to reach the camera, set while the camera aim is live and put back
    // when it is not. See PatchAimDetectionFlags above: without them the stick
    // overwrites 0x614 and the camera never sources 0x1A8C, which is "the aim
    // picks a target and the camera does not move".
    PatchAimDetectionFlags(cameraAimActive);

    static int s_aimDiagLog = 0;
    if ((isAimbot || useAssist) && (++s_aimDiagLog % 120 == 1)) {
        // aimFov, aimSphereMode and stickFighting are here because the FOV slider
        // was reported as having no effect, and there are three ways it can be
        // ignored without any of them being visible from outside:
        //
        //   aimFov read as 0, because the pref is Fov and the Home card writes
        //     FovSize, so the two sliders were editing different variables;
        //   aimSphereMode nonzero, which zeroes aimFovSq at the top of the
        //     frame and every radius then falls back to a hardcoded 150px, and
        //     the menu only hides the slider once the mode is already changed;
        //   stickFighting, which is IsFiring, and the lock gate below skips the
        //     FOV test entirely while it is set. The line already reported
        //     isFiring, and in the sample log it was 1, so this one was live.
        //
        // None of the three can be told apart from the fields that were already
        // printed, so they are printed.
        // gateR is the radius the pick actually used, which is the question behind
        // "the aim does not take the FOV size": it is aimFov only where the FOV
        // gates (isAimbot && !sphere), assistRadius where Assist runs alone, and
        // -1 where nothing gates at all. Read with aimFov and sphere, one line
        // says which of those three the build is in.
        const float gateR = (isAimbot && !useSphereAim) ? aimFov
                          : (useAssistOnly ? assistRadius : -1.0f);
        NSLog(@"[AIM-DIAG] isAimbot=%d useAssist=%d trig=%d isFiring=%d isScoping=%d act=%d target=0x%llx "
              @"aimFov=%.1f aimFovSq=%.0f sphere=%d firing=%d fireSrc=0x%x gateR=%.0f lock=%d",
              (int)isAimbot, (int)useAssist, trig, (int)isFiring, (int)isScoping, (int)shouldActivate,
              (unsigned long long)bestTarget,
              (double)aimFov, (double)aimFovSq, (int)aimSphereMode, (int)isFiring,
              (unsigned)g_fireSrcMask, (double)gateR, (int)s_lockHoldFrames);
    }

    // Hard-stop camera path the instant trigger is off or no aim mode.
    // (Prevents "nhả nút vẫn aim thêm 1 xíu" + cam lắc từ lock thread.)
    if (!cameraAimActive) {
        update_aim_assist_legit_tuning(false);
        AimLockClear();
        gAimLockTarget = 0;
        gAimLockLostFrames = 0;
        s_lastAimPawn = 0;
    }

    // ---- Silent: AimPos bone dir (Head/Neck/Chest) + muzzle origin + zero scatter ----
    // bulletJustFired ONLY for silent bullet rewrite (accuracy), NOT camera hold.
    static float s_lastBulletTrack = 0.f;
    float bulletTrack = 0.f;
    if (isVaildPtr(myPawnObject) && kLastPlayBulletTrackEffectTime) {
        bulletTrack = ReadAddr<float>(myPawnObject + kLastPlayBulletTrackEffectTime);
    }
    const bool bulletJustFired = (bulletTrack > 0.f && bulletTrack != s_lastBulletTrack);
    if (bulletTrack > 0.f) s_lastBulletTrack = bulletTrack;
    // Camera fire window = live fire only. Silent can use bullet edge separately.
    const bool fireWindow = isFiring;
    const bool silentFireWindow = isFiring || bulletJustFired;

    // Zero scatter for Silent OR Aimbot/Assist while firing — far spray was weapon bloom.
    if (isVaildPtr(myPawnObject) &&
        ((silentActive && (silentFireWindow || ((g_cacheFrameCounter & 3) == 0))) ||
         (cameraAimActive && (isFiring || isScoping)))) {
        ZeroWeaponScatterForAim(myPawnObject);
    }

    // Wall-off: silent only if strict LOS; camera aimbot already gated looser + FOV.
    // Honor AimPos — never force head when Neck/Body selected.
    if (silentActive && bestTarget != 0 && AimTargetStillValid(bestTarget) &&
        (allowThroughWall || AimTargetVisibleStrictForSilent(bestTarget))) {
        Vector3 silentBone = ResolveSilentAimWorldPosOnce(bestTarget, aimPosition);
        if (!IsZeroVec(silentBone) && bestDistance >= 0.15f) {
            SilentAimSetTarget(myPawnObject, bestTarget, silentBone, myLocation, aimPosition);
            s_lastAimPawn = bestTarget;
            bestHeadPos = silentBone;

            // Live AimPos bone only (no lead) — prediction was landing a head-width off.
            // One resolve for the frame. This line used to repeat the resolve
            // immediately above it, and the burst loop below used to repeat it
            // another thirty times, for a target that cannot move more than a couple
            // of centimetres while 120 bursts are written.
            Vector3 liveBone = ResolveSilentAimWorldPosOnce(bestTarget, aimPosition);
            if (IsZeroVec(liveBone)) liveBone = silentBone;
            {
                std::lock_guard<std::mutex> lk(g_silentMtx);
                g_silentTargetPos = liveBone;
                g_silentFromLoc = myLocation;
            }
            const int bursts = silentFireWindow ? 120 : 4;
            for (int burst = 0; burst < bursts; burst++) {
                if ((burst & 3) == 0) {
                    Vector3 h2 = ResolveSilentAimWorldPosOnce(bestTarget, aimPosition);
                    if (!IsZeroVec(h2) && looksLikeWorldPos(h2)) {
                        liveBone = h2;
                        std::lock_guard<std::mutex> lk(g_silentMtx);
                        g_silentTargetPos = liveBone;
                    }
                }
                AimSyncFireHit(myPawnObject, myLocation, liveBone);
            }
        } else {
            SilentAimClearTarget();
        }
    } else if (useSilent) {
        SilentAimClearTarget();
    } else {
        if (g_silentKeepRunning.load(std::memory_order_relaxed)) SilentAimStop();
    }

    // ---- Camera Aimbot / Assist LookAt ----
    // Activation = triggerMode only (Auto / Fire / Scope). Wall-off LOS already
    // applied at target pick — do NOT re-veto with thrashy isVis here (that killed FOV aim).
    if (iAmAlive && cameraAimActive && bestTarget != 0) {
        if (!AimTargetStillValid(bestTarget)) {
            // Dead / invalid: hard-stop cam immediately (no residual look).
            bestTarget = 0;
            gAimLockTarget = 0;
            gAimLockLostFrames = 0;
            s_lockHoldFrames = 0;
            s_lastAimPawn = 0;
            AimLockClear();
            update_aim_assist_legit_tuning(false);
        } else {
            // LookAt uses AimPos bone (Head/Neck/Chest) for FOV / 180 / 360.
            Vector3 lookBone = ResolveSilentAimWorldPosOnce(bestTarget, aimPosition);
            if (IsZeroVec(lookBone) || !looksLikeWorldPos(lookBone))
                lookBone = GetAimTargetPosModeOnce(bestTarget, aimPosition, bestDistance);
            if (IsZeroVec(lookBone) || !looksLikeWorldPos(lookBone)) {
                // Last resort only — still prefer mode-aware head drop over pure skull for body.
                lookBone = ResolveAimHeadWorldPos(bestTarget);
                if (!IsZeroVec(lookBone) && aimPosition > 0) {
                    lookBone.y -= (aimPosition == 1) ? 0.14f : 0.34f;
                }
            }
            if (IsZeroVec(lookBone)) lookBone = ResolvePawnWorldPosAny(bestTarget);

            if (IsZeroVec(lookBone) || bestDistance < 0.15f) {
                update_aim_assist_legit_tuning(false);
                AimLockClear();
            } else {
                // Camera mild lead; bullet path uses stronger lead in silent/fire-dir.
                Vector3 aimPoint = AimTrackAndLeadEx(bestTarget, lookBone, bestDistance, true, /*bulletLead=*/false);
                if (IsZeroVec(aimPoint)) aimPoint = lookBone;

                bestHeadPos = aimPoint;
                s_lastAimPawn = bestTarget;

                // Geometry re-check at apply time.
                // Aimbot FOV / wall-off: FOV circle. Aimbot 180: front only.
                // Aim Assist: near crosshair (assist radius), same AimPos bone.
                bool lookOk = true;
                if (isAimbot && useAim180) {
                    Vector3 w2sLook = WorldToScreenLayer(aimPoint, matrixData, (float)matrixVpWidth, (float)matrixVpHeight, (float)viewWidth, (float)viewHeight);
                    lookOk = (w2sLook.z > 0.001f);
                } else if (isAimbot && (!useSphereAim || !allowThroughWall)) {
                    Vector3 w2sLook = WorldToScreenLayer(aimPoint, matrixData, (float)matrixVpWidth, (float)matrixVpHeight, (float)viewWidth, (float)viewHeight);
                    if (w2sLook.z <= 0.001f) {
                        lookOk = false;
                    } else {
                        float dx = w2sLook.x - screenCenter.x;
                        float dy = w2sLook.y - screenCenter.y;
                        float fovSq = aimFovSq > 1.f ? aimFovSq : (150.f * 150.f);
                        // x1.5, matching the sticky pick slack in the working
                        // reference (tipar-normal esp.mm:5311). This was 1.10,
                        // which is inside the ring's own radius in the squared
                        // metric and so rejected targets the lock was holding.
                        lookOk = (dx * dx + dy * dy) <= fovSq * 1.5f;
                    }
                } else if (useAssistOnly) {
                    // Assist solo: near crosshair only. Stacked with Aimbot uses FOV/sphere above.
                    Vector3 w2sLook = WorldToScreenLayer(aimPoint, matrixData, (float)matrixVpWidth, (float)matrixVpHeight, (float)viewWidth, (float)viewHeight);
                    if (w2sLook.z <= 0.001f) {
                        lookOk = false;
                    } else {
                        float dx = w2sLook.x - screenCenter.x;
                        float dy = w2sLook.y - screenCenter.y;
                        // x1.5 to match the sticky gate above (tipar-normal
                        // esp.mm:5322 — "was x1.15, same toggle issue").
                        lookOk = (dx * dx + dy * dy) <= assistRadiusSq * 1.5f;
                    }
                }

                // Fire-stick drag yanks FOV off target → old code dropped LookAt → giật.
                // While firing/scoping with a lock, KEEP aiming (stick must not cancel aim).
                if (!lookOk && bestTarget != 0 && (fireWindow || isScoping) &&
                    (gAimLockTarget == bestTarget || s_lastAimPawn == bestTarget)) {
                    lookOk = true;
                }

                bool didLook = false;
                if (lookOk) {
                    // Aimbot/Assist camera LookAt (FOV already gated). No flag veto.
                    Vector3 fromNow = AimCameraOrigin(myPawnObject, myLocation);
                    Vector3 glued = AimLookAtHeadLive(myPawnObject, bestTarget, aimPosition,
                                                      bestDistance, fromNow, 1, &aimPoint,
                                                      /*freezeOrigin=*/true);
                    if (!IsZeroVec(glued) && looksLikeWorldPos(glued)) {
                        aimPoint = glued;
                        bestHeadPos = glued;
                    } else if (!IsZeroVec(aimPoint) && looksLikeWorldPos(aimPoint)) {
                        bestHeadPos = aimPoint;
                    }
                    // No AimLock thread for Aimbot/Assist — it shook cam after release.
                    AimLockClear();
                    didLook = true;
                } else {
                    AimLockClear();
                }
                // Fire-dir / HitObject spoof (Aimbot/Assist wall helper ONLY — not Silent).
                // Ghost-damage fix: do NOT thrash HitObject every fire frame (was 24×/frame
                // while isFiring → client hit VFX/HP flash without matching server bullets).
                // Keep LookAt / FOV / AimPos / lock logic untouched; only gate spoof to real
                // bullet edges and a tiny write count.
                //   Wall-ON  → allow dir rewrite on real shot.
                //   Wall-OFF → no spoof (camera LookAt still works).
                if (!useSilent && fireWindow && didLook && bestTarget != 0) {
                    ZeroWeaponScatterForAim(myPawnObject);
                    Vector3 fromNow = AimCameraOrigin(myPawnObject, myLocation);
                    // Fire-dir spoof follows AimPos (Head/Neck/Body) — do not force skull.
                    Vector3 hit = ResolveSilentAimWorldPosOnce(bestTarget, aimPosition);
                    if (IsZeroVec(hit) || !looksLikeWorldPos(hit))
                        hit = GetAimTargetPosModeOnce(bestTarget, aimPosition, bestDistance);
                    if (IsZeroVec(hit) || !looksLikeWorldPos(hit))
                        hit = bestHeadPos;
                    bestHeadPos = hit;
                    for (int i = 0; i < 3; i++) {
                        if (i == 0) {
                            Vector3 h2 = ResolveSilentAimWorldPosOnce(bestTarget, aimPosition);
                            if (!IsZeroVec(h2) && looksLikeWorldPos(h2)) hit = h2;
                        }
                        AimSyncFireHit(myPawnObject, fromNow, hit);
                    }
                    Vector3 from2 = AimCameraOrigin(myPawnObject, myLocation);
                    Quaternion tq = Quaternion::Normalized(GetRotationToLocation(hit, 0.0f, from2));
                    if (!(isnan(tq.x) || isnan(tq.y) || isnan(tq.z) || isnan(tq.w))) {
                        write_aim_rotations(myPawnObject, tq);
                    }
                }
            }
        }
    } else {
        // Not in camera aim branch — always kill cam lock thread.
        update_aim_assist_legit_tuning(false);
        AimLockClear();
        if (!silentActive) s_lastAimPawn = 0;
        if (bestTarget == 0) {
            gAimLockTarget = 0;
            gAimLockLostFrames = 0;
        }
    }
    if (!cameraAimActive || bestTarget == 0 || !(isFiring || isScoping)) {
        // Release fire/scope or no target → stop cam override immediately.
        if (!(isFiring || isScoping) || !cameraAimActive || bestTarget == 0)
            AimLockClear();
    }

    // The name plate's rectangles were built in espdraw.mm, which is where the box
    // they line up with is computed, and they belong on the plate layer rather than
    // on a layer of their own: alertNumBGLayer is already the dark fill, already
    // published at kShapeKeys index 17, and already costs one crossing whatever it
    // holds. Merging here rather than adding a second layer is also why the plate
    // does not appear and disappear when the edge counter is switched on.
    if (buffers && buffers->nameBgPath && !CGPathIsEmpty(buffers->nameBgPath)) {
        CGPathAddPath(aNumBGPath, NULL, buffers->nameBgPath);
    }

    self.alertNumBGLayer.path = CGPathIsEmpty(aNumBGPath) ? nil : aNumBGPath;
    self.alertNumGreenLayer.path = CGPathIsEmpty(aNumGPath) ? nil : aNumGPath;
    self.alertNumOrangeLayer.path = CGPathIsEmpty(aNumOPath) ? nil : aNumOPath;
    self.alertNumRedLayer.path = CGPathIsEmpty(aNumRPath) ? nil : aNumRPath;

    CGPathRelease(aNumBGPath);
    CGPathRelease(aNumGPath);
    CGPathRelease(aNumOPath);
    CGPathRelease(aNumRPath);

    return stats;
}

Quaternion GetRotationToLocation(Vector3 targetLocation, float y_bias, Vector3 myLoc) {
    Vector3 direction = (targetLocation + Vector3(0, y_bias, 0)) - myLoc;
    return Quaternion::LookRotation(direction, Vector3(0, 1, 0));
}

bool get_IsBot(uint64_t player) {
    if (!isVaildPtr(player)) return false;
    return ReadAddr<uint8_t>(player + (uint64_t)kIsClientBot) != 0;
}

bool get_IsKnockedDown(uint64_t player) {
    if (!isVaildPtr(player)) return false;
    if (get_CurHP(player) <= 0) return false;
    if (ReadAddr<uint8_t>(player + kKnocked) != 0) return true;

    uint64_t phx = ReadAddr<uint64_t>(player + kMyPhysXData);
    if (!isVaildPtr(phx)) return false;
    uint64_t stateCls = ReadAddr<uint64_t>(phx + (uint64_t)kPhxNpeononogeo);
    if (!isVaildPtr(stateCls)) return false;
    return ReadAddr<int>(stateCls + (uint64_t)kGhgState) == 8;
}

bool get_IsBeingRescued(uint64_t player) {
    if (!isVaildPtr(player)) return false;
    return ReadAddr<uint8_t>(player + kBeingRescuredState) >= 2;
}

static const int kPriVarScope = 12;
static const int kPriVarFire  = 21;

// NMCBIHOOFFF / GetStartFireState values (dump) — backup only
enum {
    kStartFireNone = 0,
    kStartFireReady = 1,
    kStartFireFire = 2,
    kStartFireCharge = 3,
    kStartFireCancel = 4,
    kStartFireWarmup = 5,
    kStartFireCombinedDouble = 6,
    kStartFireCombinedLeft = 7,
    kStartFireAbilityStart = 8,
    kStartFireAbilityEnd = 9,
};

// Real firing / charge. READY alone is NOT fire (would make Both ≈ Auto while ADS).
static inline bool StartFireStateIsActive(int state) {
    switch (state) {
        case kStartFireFire:
        case kStartFireCharge:
        case kStartFireWarmup:
        case kStartFireCombinedDouble:
        case kStartFireCombinedLeft:
        case kStartFireAbilityStart:
            return true;
        default:
            return false;
    }
}

// Which probe said "firing" is kFireSrcMask, declared next to triggerMode above.

bool get_IsFiring(uint64_t player) {
    if (!isVaildPtr(player)) return false;

    // Local, published once at the end. This runs three times a frame and the
    // mask has to describe this call, not accumulate over the session.
    int src = 0;

    // 1) StartFireState enum (when offset is valid).
    int startFire = ReadAddr<int>(player + kIsFiring);
    if (startFire > 0 && startFire <= 9) {
        src |= kFireSrcEnum;
    }
    int startFireAlt = ReadAddr<int>(player + 0x1C14);
    if (startFireAlt > 0 && startFireAlt <= 9) {
        src |= kFireSrcAlt;
    }

    // 2) IsPrepareAttack — true while fire button held (hipfire + ADS fire).
    if (ReadAddr<uint8_t>(player + kIsPrepareAttack) != 0) {
        src |= kFireSrcPrep;
    }
    if (ReadAddr<uint8_t>(player + 0x7D8) != 0) {
        src |= kFireSrcAltB;
    }

    // 3) PRI fire status (var 21).
    if (GetDataUInt16(player, kPriVarFire) != 0) {
        src |= kFireSrcPri;
    }

    g_fireSrcMask = src;

    // Only the table-backed probes decide this, and the reason is the bug that
    // was reported: Trigger = Both kept aiming as if Auto, and StickFighting
    // (the same call) kept the FOV gate switched off.
    //
    // A "fire button is held" signal has to be able to go false. This function
    // OR-ed five probes together, two of which read a fixed offset that appears
    // in neither kOffsetsFF nor kOffsetsFFMax, and a nonzero byte at an offset
    // nobody can name is the normal state of a large object, so either of the
    // two was enough to hold the result true every frame. Once that is true,
    // `shouldActivate = isFiring || isScoping` is permanently true and Both is
    // Auto with an extra step.
    //
    // The two are still read, and still reported, because if fire now reads false
    // the mask says which of the three real ones is wrong instead of leaving that
    // to be guessed at.
    return (src & kFireSrcDecidable) != 0;
}

bool get_IsScoping(uint64_t player) {
    if (!isVaildPtr(player)) return false;
    // SIGHTING_ID: non-zero = ADS. Cap rejects garbage.
    int scopeState = GetDataUInt16(player, kPriVarScope);
    return (scopeState > 0 && scopeState < 100000);
}


static inline uint32_t get_VisibleFlags(uint64_t player) {
    uint64_t bitArray = ReadAddr<uint64_t>(player + kVisibleObj);
    if (!isVaildPtr(bitArray)) return 0;
    return ReadAddr<uint32_t>(bitArray + kVisibleObjFlags);
}

bool get_IsVisible(uint64_t player) {
    if (!isVaildPtr(player)) return false;
    // Dump: ISVISIBLE_CAMERA is the primary "seen" bit used for ESP/aim LOS.
    uint32_t m_Value = get_VisibleFlags(player);
    return (m_Value & 0x1u) != 0; // ISVISIBLE_CAMERA
}

bool get_IsVisibleByFlag(uint64_t player, uint32_t flag) {
    if (!isVaildPtr(player)) return false;
    return (get_VisibleFlags(player) & flag) != 0;
}

bool get_IsFPPVisible(uint64_t player) {
    if (!isVaildPtr(player)) return false;
    // Used by ESP "Check Visible": require Camera (true seen), not full mask.
    // Full 0xFFFBFFFF match is not a real LOS test (includes mode bits).
    uint32_t m_Value = get_VisibleFlags(player);
    if (m_Value == 0) return false;
    return (m_Value & 0x1u) != 0; // ISVISIBLE_CAMERA
}

@end