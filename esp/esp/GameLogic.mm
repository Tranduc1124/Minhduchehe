#import "GameLogic.h"
#import "offset.h"
#import "GameOffsets.h"
#import "Il2CppMatch.h"
#import "../DSMemory.h"
#import "../../app/KernelBoot.h"
#import "../../remote/RemoteCall.h"
#import <Foundation/Foundation.h>
#import <math.h>

extern uint64_t Moudule_Base;

#pragma mark - Function Game

static uint64_t ReadMatchGameFromGameFacadeStatics(uint64_t GameFacade_Static) {
    if (!isVaildPtr(GameFacade_Static)) return 0;
    // Prefer CurrentMatchGame; fall back CurrentGame.
    uint64_t matchGame = ReadAddr<uint64_t>(GameFacade_Static + (uint64_t)kCurrentMatchGame);
    if (isVaildPtr(matchGame)) return matchGame;
    matchGame = ReadAddr<uint64_t>(GameFacade_Static + (uint64_t)kCurrentGame);
    if (isVaildPtr(matchGame)) return matchGame;
    return 0;
}

// Il2CppClass.static_fields offset differs by runtime; try common slots.
static uint64_t ReadGameFacadeStatics(uint64_t typeInfo) {
    if (!isVaildPtr(typeInfo)) return 0;
    const uint64_t staticOffs[] = {
        (uint64_t)kTypeInfoStatics, // configured (0xB8)
        0xB8, 0xB0, 0xC0, 0xA8, 0x90, 0x88
    };
    for (size_t i = 0; i < sizeof(staticOffs) / sizeof(staticOffs[0]); i++) {
        uint64_t st = ReadAddr<uint64_t>(typeInfo + staticOffs[i]);
        if (!isVaildPtr(st)) continue;
        // Valid if either CurrentMatchGame or CurrentGame looks like a heap ptr.
        uint64_t mg = ReadAddr<uint64_t>(st + (uint64_t)kCurrentMatchGame);
        uint64_t cg = ReadAddr<uint64_t>(st + (uint64_t)kCurrentGame);
        if (isVaildPtr(mg) || isVaildPtr(cg)) return st;
    }
    return 0;
}

uint64_t getMatchGame(uint64_t Moudule_Base) {
    if (!isVaildPtr((uintptr_t)Moudule_Base))
        return 0;

    // Primary TypeInfo from offset table + nearby + known dumps.
    // MAX current (offsetmax.h 2026-08): 0xC361EB0 — old 0xC3299C8 kept as fallback.
    uint64_t primary = (uint64_t)kGameFacadeTypeInfo;
    uint64_t candidates[] = {
        primary,
        primary - 0x1000, primary + 0x1000,
        primary - 0x2000, primary + 0x2000,
        0xBFD8978ULL, // known FFTH dump
        0xC361EB0ULL, // current MAX GameFacade_TypeInfo
        0xC3299C8ULL, // older MAX dump
        0xC012848ULL, // FFTH table default
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        uint64_t off = candidates[i];
        if (off == 0 || off > 0x20000000ULL) continue;
        uint64_t typeInfo = ReadAddr<uint64_t>(Moudule_Base + off);
        if (!isVaildPtr(typeInfo)) continue;
        uint64_t statics = ReadGameFacadeStatics(typeInfo);
        if (!isVaildPtr(statics)) continue;
        uint64_t matchGame = ReadMatchGameFromGameFacadeStatics(statics);
        if (isVaildPtr(matchGame)) return matchGame;
    }

    // Il2CppResolveMatchGame needs a FreeFire RemoteCall session. While the
    // SpringBoard overlay owns the global RemoteCall, calling it would dlsym
    // into SB (useless) and add IPC load. Skip here; TypeInfo candidates above
    // cover FF + current MAX.
    return 0;
}

uint64_t getMatch(uint64_t matchgame) {
    if (!isVaildPtr((uintptr_t)matchgame)) return 0;
    return ReadAddr<uint64_t>(matchgame + kMatch);
}

uint64_t getLocalPlayer(uint64_t match) {
    if (!isVaildPtr((uintptr_t)match)) return 0;
    return ReadAddr<uint64_t>(match + kMatchLocalPlayer);
}

uint64_t CameraMain(uint64_t matchgame) {
    if (!isVaildPtr((uintptr_t)matchgame)) return 0;
    uint64_t CameraControllerManager = ReadAddr<uint64_t>(matchgame + kCameraControllerManager);
    if (!isVaildPtr((uintptr_t)CameraControllerManager)) return 0;
    return ReadAddr<uint64_t>(CameraControllerManager + kMainCamera);
}

// Bulk-read 16 floats (64 bytes) so view/proj don't tear across 16 remote reads
// under lag — torn matrices make ESP boxes "slide with strafe then snap back".
static void TipaReadMatrix16(uint64_t addr, float *out) {
    if (!_read((long)addr, out, 16 * (int)sizeof(float))) {
        for (int i = 0; i < 16; i++)
            out[i] = ReadAddr<float>(addr + (uint64_t)i * 4u);
    }
}

static void TipaMultiply4x4(const float *P, const float *V, float *out) {
    for (int col = 0; col < 4; col++) {
        for (int row = 0; row < 4; row++) {
            float s = 0;
            for (int k = 0; k < 4; k++)
                s += P[k * 4 + row] * V[col * 4 + k];
            out[col * 4 + row] = s;
        }
    }
}

bool GetViewMatrixInto(uint64_t cameraMain, float *out16) {
    if (!out16 || !isVaildPtr((uintptr_t)cameraMain))
        return false;
    uint64_t v1 = ReadAddr<uint64_t>(cameraMain + kCameraInner);
    if (!isVaildPtr((uintptr_t)v1))
        return false;

    float V[16], P[16];
    TipaReadMatrix16(v1 + kViewMatrixOff, V);
    TipaReadMatrix16(v1 + kProjMatrixOff, P);
    TipaMultiply4x4(P, V, out16);
    // Reject NaN / zeroed matrix (common mid-teleport or bad ptr).
    if (isnan(out16[0]) || isnan(out16[15]))
        return false;
    float sumAbs = 0.f;
    for (int i = 0; i < 16; i++) sumAbs += fabsf(out16[i]);
    if (sumAbs < 1e-4f)
        return false;
    return true;
}

float* GetViewMatrix(uint64_t cameraMain) {
    static float matrix[16];
    if (!GetViewMatrixInto(cameraMain, matrix))
        return nullptr;
    return matrix;
}

bool IsAtLobby(uint64_t Moudule_Base) {
    if (!isVaildPtr((uintptr_t)Moudule_Base)) return true;
    // Use shared resolver (multi-offset + multi static_fields) so lobby detect
    // matches getMatchGame and does not false-lobby when TypeInfo moved slightly.
    uint64_t matchGame = getMatchGame(Moudule_Base);
    return !isVaildPtr(matchGame);
}

uint64_t getTransNode(uint64_t BodyPart) {
    if (!isVaildPtr((uintptr_t)BodyPart)) return 0;
    uint64_t node = ReadAddr<uint64_t>(BodyPart + kBodyPartTransNode);
    if (!isVaildPtr((uintptr_t)node)) return 0;
    return node;
}

// Dump stores ITransformNode* on Player. getPositionExt expects a Transform-like
// object and first reads +kTransformInner (0x10). Try:
//  1) node itself (works if node already has transform layout)
//  2) node->+0x10 (common ITransformNode -> Transform)
// Return the pointer that yields a non-zero world position.
static uint64_t getBoneTrans(uint64_t player, uintptr_t nodeOffset) {
    if (!isVaildPtr((uintptr_t)player)) return 0;
    uint64_t node = ReadAddr<uint64_t>(player + nodeOffset);
    if (!isVaildPtr((uintptr_t)node)) return 0;

    Vector3 direct = getPositionExt(node);
    if (!(direct.x == 0.0f && direct.y == 0.0f && direct.z == 0.0f)) {
        return node;
    }

    uint64_t inner = getTransNode(node); // node + 0x10
    if (isVaildPtr((uintptr_t)inner)) {
        Vector3 via = getPositionExt(inner);
        if (!(via.x == 0.0f && via.y == 0.0f && via.z == 0.0f)) {
            return inner;
        }
        // Some wrappers nest one more level.
        uint64_t inner2 = getTransNode(inner);
        if (isVaildPtr((uintptr_t)inner2)) {
            Vector3 via2 = getPositionExt(inner2);
            if (!(via2.x == 0.0f && via2.y == 0.0f && via2.z == 0.0f)) {
                return inner2;
            }
        }
        return inner;
    }
    return node;
}

uint64_t getHead(uint64_t player) {
    // FF dump: HeadNode 0x638, next slot 0x640 is HIP (kHipNode).
    // NEVER fall back to +0x8 — that made aim snap head→hip→head (chest jitter while firing).
    return getBoneTrans(player, kHeadNode);
}

uint64_t getHip(uint64_t player) {
    return getBoneTrans(player, kHipNode);
}

uint64_t getLeftAnkle(uint64_t player) {
    return getBoneTrans(player, kLeftAnkleNode);
}

uint64_t getRightAnkle(uint64_t player) {
    return getBoneTrans(player, kRightAnkleNode);
}

uint64_t getRightToeNode(uint64_t player) {
    return getBoneTrans(player, kRightToeNode);
}

uint64_t getLeftToeNode(uint64_t player) {
    return getBoneTrans(player, kLeftToeNode);
}
uint64_t getLeftShoulder(uint64_t player) {
    return getBoneTrans(player, kLeftShoulderNode);
}

uint64_t getLeftElbow(uint64_t player) {
    return getBoneTrans(player, kLeftElbowNode);
}

uint64_t getLeftHand(uint64_t player) {
    return getBoneTrans(player, kLeftHandNode);
}

uint64_t getRightShoulder(uint64_t player) {
    return getBoneTrans(player, kRightShoulderNode);
}

uint64_t getRightElbow(uint64_t player) {
    return getBoneTrans(player, kRightElbowNode);
}

uint64_t getRightHand(uint64_t player) {
    return getBoneTrans(player, kRightHandNode);
}

bool isLocalTeamMate(uint64_t localPlayer, uint64_t Player) {
    if (!isVaildPtr(localPlayer) || !isVaildPtr(Player)) return false;
    if (localPlayer == Player) return true;
    extern bool isAimIgnoreBot;
    const bool isBot = ReadAddr<uint8_t>(Player + (uint64_t)kIsClientBot) != 0;
    if (isBot && !isAimIgnoreBot) return false;
    COW_GamePlay_PlayerID_o myPlayerID = ReadAddr<COW_GamePlay_PlayerID_o>(localPlayer + kPlayerID);
    COW_GamePlay_PlayerID_o PlayerID = ReadAddr<COW_GamePlay_PlayerID_o>(Player + kPlayerID);
    int myTeamID = myPlayerID.m_TeamID;
    int TeamID = PlayerID.m_TeamID;
    if (myTeamID == 0 || TeamID == 0) return false;
    return myTeamID == TeamID;
}

bool isSamePlayerAsLocal(uint64_t localPlayer, uint64_t player) {
    if (!isVaildPtr(player)) return false;
    if (isVaildPtr(localPlayer)) {
        if (localPlayer == player) return true;
        uint64_t myUid = ReadAddr<uint64_t>(localPlayer + kUserID);
        uint64_t uid = ReadAddr<uint64_t>(player + kUserID);
        if (myUid != 0 && uid != 0 && myUid == uid) return true;
        COW_GamePlay_PlayerID_o myId = ReadAddr<COW_GamePlay_PlayerID_o>(localPlayer + kPlayerID);
        COW_GamePlay_PlayerID_o id = ReadAddr<COW_GamePlay_PlayerID_o>(player + kPlayerID);
        if (myId.m_Value != 0 && myId.m_Value == id.m_Value) return true;
    }
    return false;
}

// PRI DataPool on Player (dump-stable): pool @ 0x70, inner @ +0x10,
// entries base +0x20, stride 0x8, value @ +0x18. varID 0=CurHP, 1=MaxHP.
// Some seasons/build paths put a thin wrapper; try pool ptr alts + value size.
static int ReadDataPoolVar(uint64_t player, int varID) {
    if (!isVaildPtr(player) || varID < 0 || varID > 64) return 0;
    const uint64_t poolOff = kDataPool ? kDataPool : 0x70;
    const uint64_t innerOff = kDataPoolInner ? kDataPoolInner : 0x10;
    const uint64_t entriesBase = kDataPoolEntriesBase ? kDataPoolEntriesBase : 0x20;
    const uint64_t stride = kDataPoolEntryStride ? kDataPoolEntryStride : 0x8;
    const uint64_t valueOff = kDataPoolValue ? kDataPoolValue : 0x18;

    // Player.DataPool may be the pool object, or a one-hop wrapper.
    uint64_t pools[3] = {
        ReadAddr<uint64_t>(player + poolOff),
        0, 0
    };
    if (isVaildPtr(pools[0])) {
        pools[1] = ReadAddr<uint64_t>(pools[0] + 0x10);
        pools[2] = ReadAddr<uint64_t>(pools[0] + 0x18);
    }

    for (int pi = 0; pi < 3; pi++) {
        uint64_t pool = pools[pi];
        if (!isVaildPtr(pool)) continue;
        const uint64_t innerOffs[] = { innerOff, 0x10, 0x18, 0x08, 0x00 };
        for (size_t i = 0; i < sizeof(innerOffs) / sizeof(innerOffs[0]); i++) {
            uint64_t inner = (innerOffs[i] == 0) ? pool : ReadAddr<uint64_t>(pool + innerOffs[i]);
            if (!isVaildPtr(inner)) continue;
            uint64_t entry = ReadAddr<uint64_t>(inner + entriesBase + stride * (uint64_t)varID);
            if (!isVaildPtr(entry)) continue;
            // Value may be int32 or uint16 at +0x18 (and rarely +0x10/+0x14).
            const uint64_t valOffs[] = { valueOff, 0x18, 0x14, 0x10 };
            for (size_t v = 0; v < sizeof(valOffs) / sizeof(valOffs[0]); v++) {
                int32_t i32 = ReadAddr<int32_t>(entry + valOffs[v]);
                if (varID <= 1) {
                    // HP / MaxHP: accept uint16 range stored in low word too.
                    if (i32 >= 0 && i32 <= 2000) return i32;
                    uint16_t u16 = ReadAddr<uint16_t>(entry + valOffs[v]);
                    if (u16 > 0 && u16 <= 2000) return (int)u16;
                } else {
                    return i32;
                }
            }
        }
    }
    return 0;
}

int GetDataUInt16(uint64_t player, int varID) {
    return ReadDataPoolVar(player, varID);
}

void SetDataUInt16(uint64_t player, int varID, uint16_t value) {
    if (!isVaildPtr(player)) return;
    uint64_t IPRIDataPool = ReadAddr<uint64_t>(player + (kDataPool ? kDataPool : 0x70));
    if (!isVaildPtr(IPRIDataPool)) return;
    uint64_t v2 = ReadAddr<uint64_t>(IPRIDataPool + (kDataPoolInner ? kDataPoolInner : 0x10));
    if (!isVaildPtr(v2)) return;
    uint64_t v4 = ReadAddr<uint64_t>(v2 + (kDataPoolEntryStride ? kDataPoolEntryStride : 0x8) * (uint64_t)varID
                                     + (kDataPoolEntriesBase ? kDataPoolEntriesBase : 0x20));
    if (!isVaildPtr(v4)) return;
    WriteAddr<uint16_t>(v4 + (kDataPoolValue ? kDataPoolValue : 0x18), value);
}

int get_CurHP(uint64_t Player) {
    return ReadDataPoolVar(Player, 0);
}

int get_MaxHP(uint64_t Player) {
    int maxHp = ReadDataPoolVar(Player, 1);
    // Some shells expose only CurHP; treat positive CurHP as alive shell.
    if (maxHp <= 0) {
        int cur = ReadDataPoolVar(Player, 0);
        if (cur > 0 && cur <= 2000) return cur;
    }
    return maxHp;
}

void EnableFastReload(uint64_t localPlayerPawn, bool isEnabled, float speedMult) {
    if (!isVaildPtr(localPlayerPawn)) return;
    // PlayerAttributes: FF 0x700 / MAX 0x708 (kPlayerAttributes)
    uint64_t attrsOff = kPlayerAttributes ? kPlayerAttributes : 0x700;
    uint64_t attrs = ReadAddr<uint64_t>(localPlayerPawn + attrsOff);
    if (!isVaildPtr(attrs)) return;
    WriteAddr<bool>(attrs + 0xD8, isEnabled); // ReloadNoConsumeAmmoclip
    WriteAddr<bool>(attrs + 0xD9, isEnabled); // ShootNoReload
    (void)speedMult;
}

// EAimAssist dump: AllOn=0, OffOnSighting=1, AllOff=2
enum : int32_t {
    kEAimAssistAllOn = 0,
    kEAimAssistOffOnSighting = 1,
    kEAimAssistAllOff = 2,
};

// Soft-zero ONLY the two dump-confirmed chest-magnet static scales.
// Never spray-write AA object instances or unknown static slots — that caused
// FreeFire SIGSEGV (bad ptr ~0x100000000) after writing m_AimAssist+0x10..0x40.
// Save originals so wall-off restore can put vanilla AA back (without this,
// Aim Behind Wall ON zeroed strength forever → aimbot/assist felt broken after OFF).
static float g_savedAaStaticA = 1.0f;
static float g_savedAaStaticB = 1.0f;
static bool g_aaStaticsSaved = false;
static bool g_aaStaticsZeroed = false;

static uint64_t ResolveAimAssistStatics(void) {
    if (Moudule_Base == 0 || Moudule_Base == (uint64_t)-1) return 0;
    uint64_t typeInfo = ReadAddr<uint64_t>(Moudule_Base + kAimAssistTypeInfo);
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

static void SoftZeroAimAssistStrength(void) {
    uint64_t statics = ResolveAimAssistStatics();
    if (!statics) return;

    float a = ReadAddr<float>(statics + kAaStaticKnolgmjlcef);
    float b = ReadAddr<float>(statics + kAaStaticNfkcllpalej);
    // Save first non-zero values we see in a disable session.
    if (!g_aaStaticsSaved) {
        if (a > 0.001f && a < 100.0f) g_savedAaStaticA = a;
        if (b > 0.001f && b < 100.0f) g_savedAaStaticB = b;
        // Fallback if already zeroed by a previous session without restore.
        if (g_savedAaStaticA <= 0.001f) g_savedAaStaticA = 1.0f;
        if (g_savedAaStaticB <= 0.001f) g_savedAaStaticB = 1.0f;
        g_aaStaticsSaved = true;
    }

    WriteAddr<float>(statics + kAaStaticKnolgmjlcef, 0.0f);
    WriteAddr<float>(statics + kAaStaticNfkcllpalej, 0.0f);
    g_aaStaticsZeroed = true;
}

static void SoftRestoreAimAssistStrength(void) {
    if (!g_aaStaticsZeroed && !g_aaStaticsSaved) return;
    uint64_t statics = ResolveAimAssistStatics();
    if (!statics) return;

    float a = g_aaStaticsSaved ? g_savedAaStaticA : 1.0f;
    float b = g_aaStaticsSaved ? g_savedAaStaticB : 1.0f;
    if (a <= 0.001f || a > 100.0f) a = 1.0f;
    if (b <= 0.001f || b > 100.0f) b = 1.0f;
    WriteAddr<float>(statics + kAaStaticKnolgmjlcef, a);
    WriteAddr<float>(statics + kAaStaticNfkcllpalej, b);
    g_aaStaticsZeroed = false;
    g_aaStaticsSaved = false;
}

// Player.FGEAKHHPKCC (EAimAssist) dump: AllOn=0, OffOnSighting=1, AllOff=2.
// Writing the enum kills default chest magnet without stomping m_AimAssist object layout
// (object float spray crashed at 0x100000000). Keep pointers non-null.
static int32_t g_savedEAimAssistMode = kEAimAssistAllOn;
static bool g_eAimAssistModeSaved = false;
static bool g_defaultAADisabled = false;

void DisableGameDefaultAimAssist(uint64_t localPlayerPawn, bool disable) {
    if (!isVaildPtr(localPlayerPawn)) return;

    if (disable) {
        // Kill vanilla AA fully while custom aimbot/assist is on (wall ON or OFF):
        // 1) zero magnet static scales
        // 2) force EAimAssist AllOff so fire-stick / ADS chest magnet cannot re-pull
        // Wall-OFF LOS is geometric (cover raycast), NOT AA-list dependent — safe to AllOff.
        SoftZeroAimAssistStrength();

        int32_t cur = ReadAddr<int32_t>(localPlayerPawn + kEAimAssistMode);
        if (!g_eAimAssistModeSaved) {
            if (cur == kEAimAssistAllOn || cur == kEAimAssistOffOnSighting || cur == kEAimAssistAllOff) {
                g_savedEAimAssistMode = cur;
            } else {
                g_savedEAimAssistMode = kEAimAssistAllOn;
            }
            g_eAimAssistModeSaved = true;
        }
        if (cur != kEAimAssistAllOff) {
            WriteAddr<int32_t>(localPlayerPawn + kEAimAssistMode, kEAimAssistAllOff);
        }
        g_defaultAADisabled = true;
        return;
    }

    // Restore when custom aimbot/assist is fully off.
    if (g_defaultAADisabled || g_aaStaticsZeroed || g_aaStaticsSaved) {
        SoftRestoreAimAssistStrength();
        if (g_eAimAssistModeSaved) {
            int32_t restore = g_savedEAimAssistMode;
            if (restore != kEAimAssistAllOn && restore != kEAimAssistOffOnSighting && restore != kEAimAssistAllOff) {
                restore = kEAimAssistAllOn;
            }
            // Never restore AllOff as "original" when user turned custom aim off.
            if (restore == kEAimAssistAllOff) restore = kEAimAssistAllOn;
            WriteAddr<int32_t>(localPlayerPawn + kEAimAssistMode, restore);
        }
    }
    g_defaultAADisabled = false;
    g_eAimAssistModeSaved = false;
}
