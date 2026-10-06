#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Runtime offset table selected by Home "Lựa chọn phiên bản".
// Edit FF values in GameOffsets.mm (kOffsetsFF).
// Edit Max values in offsetmax.h (included by GameOffsets.mm).

typedef struct GameOffsets {
    uint64_t GameFacadeTypeInfo;
    uint64_t TypeInfoStatics;
    uint64_t CurrentGame;
    uint64_t CurrentMatchGame;
    uint64_t Match;
    uint64_t MatchLocalPlayer;
    uint64_t MatchGameSceneLoaded; // MatchGame.m_SceneLoaded bool — false ở sảnh
    uint64_t CameraControllerManager;
    uint64_t MainCamera;
    uint64_t CameraInner;
    uint64_t ViewMatrixOff;
    uint64_t ProjMatrixOff;
    uint64_t BodyPartTransNode;
    uint64_t HeadNode;
    uint64_t HipNode;
    uint64_t LeftAnkleNode;
    uint64_t RightAnkleNode;
    uint64_t RightToeNode;
    uint64_t LeftToeNode;
    uint64_t LeftShoulderNode;
    uint64_t RightShoulderNode;
    uint64_t NeckNode;                  // Player.FFFPCADFFGA // 0x6B0 (between Hip→Shoulder)
    uint64_t ChestNode;                 // Player.CBHHCCNKOND // 0x6B8 (between Hip→Shoulder)
    uint64_t SpineNode;                 // Player.EJJBPONNECG // 0x6D0 (after shoulders)
    uint64_t LeftHandNode;
    uint64_t RightHandNode;
    uint64_t LeftElbowNode;
    uint64_t RightElbowNode;
    uint64_t PlayerIDStruct;
    uint64_t PlayerID;
    uint64_t UserID;
    uint64_t IsClientBot;
    uint64_t IsDead;                   // AttackableEntity.PIKCADEGMOH / get_IsDead (0x7C)
    uint64_t EntityRecycled;           // GCommon.Entity.m_Recycle (0x28)
    uint64_t EntityNeedUpdate;         // GCommon.Entity.NeedUpdate (0x20)
    uint64_t DataPool;
    uint64_t DataPoolInner;
    uint64_t DataPoolEntriesBase;
    uint64_t DataPoolEntryStride;
    uint64_t DataPoolValue;
    uint64_t AimRotation;
    uint64_t AimRotationAux;
    uint64_t CurrentAimRotation;
    uint64_t CallSetAimRotationCount; // Player.CallSetAimRotationCount — report 0x69 bumps this in SetAimRotation
    // Aim input sample ring (UserControlHandler) — report packs these into GGP
    // while rotation/counter move; -1 samples with counter++ = aimbot flag.
    uint64_t UserControlHandler;      // Player.LBPGBNKABJE // 0x4D0
    uint64_t AimSampleX;              // handler.m_aimInputSampleX float[] // 0xA0
    uint64_t AimSampleY;              // handler.m_aimInputSampleY float[] // 0xA8
    uint64_t AimSampleHead;           // handler.m_aimInputSampleHead // 0xB0
    uint64_t AimSampleFilled;         // handler.m_aimInputSampleFilled // 0xB4
    uint64_t AimSampleTickCounter;    // handler.m_aimInputSampleTickCounter // 0xB8 — dump 1458233; frozen tick = ban sig
    uint64_t AimAssistTypeInfo;
    uint64_t AaStaticKnolgmjlcef;
    uint64_t AaStaticNfkcllpalej;
    // GameVarDef statics — ban vector when Aimbot writes rot/counter without 0xF0
    // and without matching AimInputSample samples.
    uint64_t GameVarDefTypeInfo;       // global TypeInfo ptr (FF 0xBB46AF8)
    uint64_t GvdEnableCheckBuf;        // statics+0x458C — gate ffantihack 0xF0 in SetAimRotation
    uint64_t GvdEnableAimInputSample;  // statics+0x458D — SampleAimInput gate
    uint64_t GvdAimInputSampleCount;   // statics+0x4590 — FillAimInputSamples gate
    uint64_t GvdAimInputSampleIntervalTick; // statics+0x4594 — server-configured sample period
    uint64_t GvdEnableInternalSetRotation; // statics+0xE4 — CurrentAimWriter: !=1 stomps 0x614 with stick
    uint64_t GvdRotationPlan;              // statics+0x380C — HFIKAJMBGJG: only 1/2 apply Current 0x1A8C to camera
    uint64_t CheckBufPending;           // Player+0x624 IKCEKAKDFJC bool — MarkGGPVerifyCheckBufPending sets 1 → Flush 0xF1
    // Game default aim-assist (chest magnet). Dump: EAimAssist AllOff=2
    uint64_t AimAssistPtr;          // Player.m_AimAssist
    uint64_t AimAssistIceWallPtr;   // Player.m_AimAssistForIceWall
    uint64_t EAimAssistMode;        // Player.FGEAKHHPKCC (EAimAssist)
    uint64_t PlayerAnimComponent;   // NewPlayerAnimationSystemComponent
    uint64_t PlayerAttributes;      // Player.KDJHNBAECLM (PlayerAttributes)
    uint64_t RunSpeedUpScale;       // PlayerAttributes.RunSpeedUpScale
    uint64_t IsFiring;              // legacy StartFireState (NMCBIHOOFFF) — backup only
    uint64_t IsPrepareAttack;     // Player.get_IsPrepareAttack bool (primary fire hold)
    uint64_t LastFireBtnDownTime; // Player.LastFireBtnDownTime (hipfire press)
    uint64_t LastPlayBulletTrackEffectTime; // updates per shot
    uint64_t LastSmartFireTime;
    uint64_t VisibleObj;
    uint64_t VisibleObjFlags;
    uint64_t ISVisibleCamera;
    uint64_t ISVisibleDynamicPVS;
    uint64_t ISVisibleFPPMask;
    uint64_t MainCameraTransform;
    uint64_t MyPhysXData;
    uint64_t PhxNpeononogeo;
    uint64_t GhgState;
    uint64_t Knocked;
    uint64_t BeingRescuredState;
    uint64_t MatchPlayerDict;
    uint64_t DictEntries;
    uint64_t DictCount;
    uint64_t Il2CppArrayMaxLength;
    uint64_t Il2CppArrayItems;
    uint64_t DictEntryStrideBytePlayer;
    uint64_t DictEntryValueOffByte;
    uint64_t TransformInner;
    uint64_t TransformMatrix;
    uint64_t TransformIndex;
    uint64_t MatrixList;
    uint64_t MatrixIndices;
    uint64_t Nickname;
    uint64_t StringFirstChar;
    uint64_t ActiveWeapon;
    uint64_t WeaponID;
    uint64_t WeaponCategory;
    uint64_t WeaponHolder;
    uint64_t HolderActiveWeapon;
    // Fast weapon switch (dump-confirmed path):
    // ActiveWeapon(FDAEPHMIEPC) -> UGCWeaponRepItem @ WeaponRepItem
    //   SwitchWeaponTime / PreSwitchWeaponTime / PostSwitchWeaponTime
    uint64_t WeaponRepItem;          // FDAEPHMIEPC.UGCWeaponRepItem
    uint64_t SwitchWeaponTime;       // UGCWeaponRepItem._SwitchWeaponTime
    uint64_t PreSwitchWeaponTime;    // UGCWeaponRepItem._PreSwitchWeaponTime
    uint64_t PostSwitchWeaponTime;   // UGCWeaponRepItem._PostSwitchWeaponTime
    uint64_t NicknameDisplay;
    uint64_t HitObjectInfo;    // player + off → primary bullet hit object (silent)
    uint64_t HitObjectInfoAlt; // secondary GMPGMPFNMFP (often +8)
    uint64_t HitObjectDir;     // GMPGMPFNMFP + 0x40 -> direction Vector3
    uint64_t HitObjectOrigin;  // GMPGMPFNMFP + 0x4C -> origin Vector3
    uint64_t FollowCameraObj;  // Player.FollowCameraObj
    uint64_t FollowCameraDistance; // FollowCameraObj + 0x70 -> float camera distance
    // Vehicle / zipline (cable) — dump Player fields (ESP/aim when skinned bones zero).
    // TH: Vehicle IIPDHPKBDBA @ 0x8A8, LevelStrop JCGPLBAPOLO @ 0x8C0, root bone @ 0x630
    // MAX: +0x8 on these Player mid fields (0x8B0 / 0x8C8 / 0x638)
    uint64_t VehicleIAmIn;     // Player.VehicleIAmIn / GetVehicleIAmIn pointer
    uint64_t LevelStropIAmOn;  // Player.GetStropIAmOn / LevelStrop (cable/zipline)
    uint64_t RootNode;         // Player first ITransformNode (spine/root, not head)
    uint64_t PlayerTransform;  // Player.OKOLMFJKGEC Unity Transform* (TH 0x698) — key for vehicle ESP
    // Wall-off LOS: last weapon raycast attackable target (OKEAMEELLBB*)
    // dump: <JMPDDMAMFML>k__BackingField @ 0xE68; MAX @ 0xE70
    uint64_t LastAimingTargetFromWeapon;
    // Instant consumable wrap (medkit / repair / inhaler / PED / shield):
    // UI path (display + client sim): BaseGame.m_UIScene → PrepareCtrl / QuickUseMedkit
    // Player path (authority-ish client state): Player.KBHMGGLIMLI + PlayerNetwork duration
    // TH≈MAX for scene/timer field offsets; Player prep fields differ (TH 0x45C / MAX 0x464).
    uint64_t BaseGameUIScene;              // BaseGame.m_UIScene (0x10)
    uint64_t UIInGameScenePrepareCtrl;     // UIInGameScene.m_PrepareCtrl (0x698)
    uint64_t UIInGameSceneQuickUseMedkit;  // UIInGameScene.m_UIHudQuickUseMedkitController (0x978)
    uint64_t PrepTimerStartTime;           // UIHudPreparationTimerController.m_StartTime (0xA0)
    uint64_t PrepTimerTotalTime;           // m_TotalTime (0xA4)
    uint64_t PrepTimerContextType;         // m_ContextType EPreparationTimerType (0xA8)
    uint64_t PrepTimerStage1Time;          // m_Stage1Time (0xAC)
    uint64_t PrepTimerIsFinished;          // m_IsPrepareFinished (0x118)
    uint64_t PrepTimerProgressSpeed;       // m_CurrentProgressSpeed (0x138)
    uint64_t PrepTimerProgressRate;        // m_CurrentProgressRate (0x13C)
    uint64_t PlayerPrepTimerType;          // Player.KBHMGGLIMLI EPreparationTimerType
    // PlayerNetwork (local Player subclass) — dump-confirmed next to prep type:
    // TH: PNEEICGMOGG 0x22E0, JOJOJDCFNAK 0x22E4, BBJCHDAJIBC 0x22F4, JFOPDHIHIIC 0x22F8
    // MAX: +0x18 on this block (0x22F8 / 0x22FC / 0x230C / 0x2310)
    uint64_t PlayerNetPrepDuration;        // float next to prep type (likely total / remaining)
    uint64_t PlayerNetPrepType;            // PlayerNetwork.JOJOJDCFNAK EPreparationTimerType
    uint64_t PlayerNetPrepFloatA;          // float after type+uids (start/elapsed candidate)
    uint64_t PlayerNetPrepFloatB;          // second float (progress/remaining candidate)
    // Player curing flags (CompilerGenerated after m_GetInVehicle):
    // TH 0x491..0x494 / MAX 0x499..0x49C — IsCuring, IsPreparing, IsEating, IsRepairing
    uint64_t PlayerIsCuring;
    uint64_t PlayerIsPreparing;
    uint64_t PlayerIsEating;
    uint64_t PlayerIsRepairing;
    // Extra PlayerNetwork floats next to prep block (elapsed/aux candidates).
    // TH: JIABJHJGDKL 0x22FC, EJKGAPAHABD 0x2308; MAX +0x18.
    uint64_t PlayerNetPrepFloatC;
    uint64_t PlayerNetPrepFloatD;
    // Weapon-side consumable duration (OMDPILKGAJF : NAELPAAELNO) — same TH/MAX.
    // Active weapon / holder active may be medkit/repair while curing.
    uint64_t WeaponConsumableCsv;          // OMDPILKGAJF.LFEEICKEBGH @ 0x68
    uint64_t WeaponConsumableCsvFloatA;    // LFEEICKEBGH float @ 0x24 (use/pre candidate)
    uint64_t WeaponConsumableCsvFloatB;    // LFEEICKEBGH float @ 0x28
    uint64_t WeaponConsumableCsvFloatC;    // LFEEICKEBGH float @ 0x40
    uint64_t WeaponRepairRepItem;          // UGCRepairArmorKitRepItem* @ 0x78
    uint64_t WeaponFirstAidRepItem;        // UGCFirstAidKitRepItem* @ 0x80
    uint64_t WeaponInhalerRepItem;         // UGCInhalerRepItem* @ 0x88
    uint64_t UGCFirstAidDuration;          // int Duration @ 0x34 (likely ms)
    uint64_t UGCFirstAidPretime;           // int Pretime @ 0x38 (likely ms)
    uint64_t UGCRepairPreTime;             // float PreTime @ 0x20
    // ===== ĐẠN THẲNG (all guns) — dump.cs UGCWeaponRepItem + PlayerAttributes =====
    // L1 weapon rep: FireInterval sanity @0x178, scatter fields (float):
    uint64_t RepFireInterval;        // rep+0x178 (guard + FastFire write)
    uint64_t RepRepeatFireInterval;  // rep+0x1A0 (burst/auto gap — FastFire)
    uint64_t RepScatterNum;          // rep+0x194
    uint64_t RepScatterMax;          // rep+0x198
    uint64_t RepScatterSpeed;        // rep+0x1E0
    uint64_t RepScatterRecoverSpeed; // rep+0x1E4
    uint64_t RepScatterMove;         // rep+0x1EC
    // L2 PlayerAttributes (attrs = Player+PlayerAttributes):
    uint64_t AttrsBuffWeaponScatterScale;     // +0xE0 (MNIJCDHGGEC iface ptr)
    uint64_t AttrsBuffEcaWeaponScatterScale;  // +0xE8
    uint64_t AttrsBuffEcaIgnoreWeaponScatter; // +0x300 (SafeReference<uint>)
    uint64_t AttrsReloadNoConsumeAmmo;        // +0xD8 (PlayerAttributes.ReloadNoConsumeAmmoclip)
    uint64_t AttrsShootNoReload;              // +0xD9 (PlayerAttributes.ShootNoReload)
    // FastFire player-level scales (dump: get/set FireIntervalScale* around these):
    uint64_t AttrsFireIntervalScale;     // +0x13C <PBJIOFBCJDM>
    uint64_t AttrsFireIntervalScaleTwo;  // +0x140 <KPHEGJPOLFL>
    uint64_t AttrsFireIntervalScaleBuffECA; // +0x218 EBMBEEHGBKP*
    // CDNOIECMFMP<T> accumulator floats (iface + …):
    uint64_t ScaleAccumA;  // +0x18
    uint64_t ScaleAccumB;  // +0x1C
    uint64_t ScaleAccumC;  // +0x20
    uint64_t ScaleAccumD;  // +0x24
    uint64_t ScaleAccumE;  // +0x28
    // SafeReference / HashSet layout:
    uint64_t SafeRefHashSet;   // SafeReference.m_References +0x10
    uint64_t HashSetBuckets;   // HashSet._buckets  +0x10
    uint64_t HashSetSlots;     // HashSet._slots    +0x18
    uint64_t HashSetCount;     // HashSet._count    +0x20
    uint64_t HashSetLastIndex; // +0x24
    uint64_t HashSetFreeList;  // +0x28
    // ===== FPP recoil config (dump.cs MatchConfig block 0x7A0..0x830) =====
    uint64_t FppGameModeEnable;      // +0x7A2 (bool sanity)
    uint64_t FppRecoil;              // +0x7E8 (bool)
    uint64_t FppVibrateRotate;       // +0x7E9 (bool) camera SHAKE khi bắn
    uint64_t FppVibrateRotateSpeed;  // +0x7EC (float)
    uint64_t FppRecoilYCycleTime;    // +0x7F8
    uint64_t FppRecoilZCycleTime;    // +0x7FC
    uint64_t FppRecoilYFactor;       // +0x800
    uint64_t FppRecoilZFactor;       // +0x804
    uint64_t FppRecoilBackwardX;     // +0x808
    uint64_t FppRecoilBackwardZ;     // +0x80C
    uint64_t FppRecoilBackwardSpeed; // +0x810
    uint64_t FppCameraMaxfireRotateAngle; // +0x82C — góc xoay cam khi bắn
    uint64_t FppCameraFireRotateTime;     // +0x830 — thời gian xoay cam khi bắn
    // Runtime firing weapon: Player.GFKMKMIPOPI (dump-verified FDAEPHMIEPC)
    uint64_t RuntimeWeapon;          // +0x1718
} GameOffsets;

/** Active offset table for selected game (never NULL). */
const GameOffsets *GameOffsetsCurrent(void);

/** Re-read SelectedGameId prefs and switch table + process name. Call on Home select and HUD/ESP start. */
void GameOffsetsReload(void);

/** "ff" or "ffmax" (default "ff"). */
#ifdef __OBJC__
NSString *GameTargetSelectedId(void);
void GameTargetSetSelectedId(NSString *gameId);
#endif

/** Process p_comm: FreeFire | FreeFireMAX */
const char *GameTargetProcessName(void);
bool GameTargetIsMax(void);
bool GameTargetIsRunning(void);
int GameTargetProcessPid(void);
uintptr_t GameTargetModuleBase(void);

#ifdef __cplusplus
}
#endif

// Compatibility macros: existing code keeps using kFoo.
// Each expands to the active table field.
#define kGameFacadeTypeInfo           (GameOffsetsCurrent()->GameFacadeTypeInfo)
#define kTypeInfoStatics              (GameOffsetsCurrent()->TypeInfoStatics)
#define kCurrentGame                  (GameOffsetsCurrent()->CurrentGame)
#define kCurrentMatchGame             (GameOffsetsCurrent()->CurrentMatchGame)
#define kMatch                        (GameOffsetsCurrent()->Match)
#define kMatchLocalPlayer             (GameOffsetsCurrent()->MatchLocalPlayer)
#define kMatchGameSceneLoaded         (GameOffsetsCurrent()->MatchGameSceneLoaded)
#define kCameraControllerManager      (GameOffsetsCurrent()->CameraControllerManager)
#define kMainCamera                   (GameOffsetsCurrent()->MainCamera)
#define kCameraInner                  (GameOffsetsCurrent()->CameraInner)
#define kViewMatrixOff                (GameOffsetsCurrent()->ViewMatrixOff)
#define kProjMatrixOff                (GameOffsetsCurrent()->ProjMatrixOff)
#define kBodyPartTransNode            (GameOffsetsCurrent()->BodyPartTransNode)
#define kHeadNode                     (GameOffsetsCurrent()->HeadNode)
#define kHipNode                      (GameOffsetsCurrent()->HipNode)
#define kLeftAnkleNode                (GameOffsetsCurrent()->LeftAnkleNode)
#define kRightAnkleNode               (GameOffsetsCurrent()->RightAnkleNode)
#define kRightToeNode                 (GameOffsetsCurrent()->RightToeNode)
#define kLeftToeNode                  (GameOffsetsCurrent()->LeftToeNode)
#define kLeftShoulderNode             (GameOffsetsCurrent()->LeftShoulderNode)
#define kRightShoulderNode            (GameOffsetsCurrent()->RightShoulderNode)
#define kNeckNode                     (GameOffsetsCurrent()->NeckNode)
#define kChestNode                    (GameOffsetsCurrent()->ChestNode)
#define kSpineNode                    (GameOffsetsCurrent()->SpineNode)
#define kLeftHandNode                (GameOffsetsCurrent()->LeftHandNode)
#define kRightHandNode                (GameOffsetsCurrent()->RightHandNode)
#define kLeftElbowNode                (GameOffsetsCurrent()->LeftElbowNode)
#define kRightElbowNode               (GameOffsetsCurrent()->RightElbowNode)
#define kPlayerIDStruct               (GameOffsetsCurrent()->PlayerIDStruct)
#define kPlayerID                     (GameOffsetsCurrent()->PlayerID)
#define kUserID                       (GameOffsetsCurrent()->UserID)
#define kIsClientBot                  (GameOffsetsCurrent()->IsClientBot)
#define kIsDead                       (GameOffsetsCurrent()->IsDead)
#define kEntityRecycled               (GameOffsetsCurrent()->EntityRecycled)
#define kEntityNeedUpdate             (GameOffsetsCurrent()->EntityNeedUpdate)
#define kDataPool                     (GameOffsetsCurrent()->DataPool)
#define kDataPoolInner                (GameOffsetsCurrent()->DataPoolInner)
#define kDataPoolEntriesBase          (GameOffsetsCurrent()->DataPoolEntriesBase)
#define kDataPoolEntryStride          (GameOffsetsCurrent()->DataPoolEntryStride)
#define kDataPoolValue                (GameOffsetsCurrent()->DataPoolValue)
#define kAimRotation                  (GameOffsetsCurrent()->AimRotation)
#define kAimRotationAux               (GameOffsetsCurrent()->AimRotationAux)
#define kCurrentAimRotation           (GameOffsetsCurrent()->CurrentAimRotation)
#define kCallSetAimRotationCount      (GameOffsetsCurrent()->CallSetAimRotationCount)
#define kUserControlHandler           (GameOffsetsCurrent()->UserControlHandler)
#define kAimSampleX                   (GameOffsetsCurrent()->AimSampleX)
#define kAimSampleY                   (GameOffsetsCurrent()->AimSampleY)
#define kAimSampleHead                (GameOffsetsCurrent()->AimSampleHead)
#define kAimSampleFilled              (GameOffsetsCurrent()->AimSampleFilled)
#define kAimSampleTickCounter         (GameOffsetsCurrent()->AimSampleTickCounter)
#define kAimAssistTypeInfo            (GameOffsetsCurrent()->AimAssistTypeInfo)
#define kAaStaticKnolgmjlcef          (GameOffsetsCurrent()->AaStaticKnolgmjlcef)
#define kAaStaticNfkcllpalej          (GameOffsetsCurrent()->AaStaticNfkcllpalej)
#define kGameVarDefTypeInfo           (GameOffsetsCurrent()->GameVarDefTypeInfo)
#define kGvdEnableCheckBuf            (GameOffsetsCurrent()->GvdEnableCheckBuf)
#define kGvdEnableAimInputSample      (GameOffsetsCurrent()->GvdEnableAimInputSample)
#define kGvdAimInputSampleCount       (GameOffsetsCurrent()->GvdAimInputSampleCount)
#define kGvdAimInputSampleIntervalTick (GameOffsetsCurrent()->GvdAimInputSampleIntervalTick)
#define kGvdEnableInternalSetRotation (GameOffsetsCurrent()->GvdEnableInternalSetRotation)
#define kGvdRotationPlan              (GameOffsetsCurrent()->GvdRotationPlan)
#define kCheckBufPending              (GameOffsetsCurrent()->CheckBufPending)
#define kAimAssistPtr                 (GameOffsetsCurrent()->AimAssistPtr)
#define kAimAssistIceWallPtr          (GameOffsetsCurrent()->AimAssistIceWallPtr)
#define kEAimAssistMode               (GameOffsetsCurrent()->EAimAssistMode)
#define kPlayerAnimComponent          (GameOffsetsCurrent()->PlayerAnimComponent)
#define kPlayerAttributes             (GameOffsetsCurrent()->PlayerAttributes)
#define kRunSpeedUpScale              (GameOffsetsCurrent()->RunSpeedUpScale)
#define kIsFiring                     (GameOffsetsCurrent()->IsFiring)
#define kIsPrepareAttack              (GameOffsetsCurrent()->IsPrepareAttack)
#define kLastFireBtnDownTime          (GameOffsetsCurrent()->LastFireBtnDownTime)
#define kLastPlayBulletTrackEffectTime (GameOffsetsCurrent()->LastPlayBulletTrackEffectTime)
#define kLastSmartFireTime            (GameOffsetsCurrent()->LastSmartFireTime)
#define kVisibleObj                   (GameOffsetsCurrent()->VisibleObj)
#define kVisibleObjFlags              (GameOffsetsCurrent()->VisibleObjFlags)
#define kISVisibleCamera              (GameOffsetsCurrent()->ISVisibleCamera)
#define kISVisibleDynamicPVS          (GameOffsetsCurrent()->ISVisibleDynamicPVS)
#define kISVisibleFPPMask             (GameOffsetsCurrent()->ISVisibleFPPMask)
#define kMainCameraTransform          (GameOffsetsCurrent()->MainCameraTransform)
#define kMyPhysXData                  (GameOffsetsCurrent()->MyPhysXData)
#define kPhxNpeononogeo               (GameOffsetsCurrent()->PhxNpeononogeo)
#define kGhgState                     (GameOffsetsCurrent()->GhgState)
#define kKnocked                      (GameOffsetsCurrent()->Knocked)
#define kBeingRescuredState           (GameOffsetsCurrent()->BeingRescuredState)
#define kMatchPlayerDict              (GameOffsetsCurrent()->MatchPlayerDict)
#define kDictEntries                  (GameOffsetsCurrent()->DictEntries)
#define kDictCount                    (GameOffsetsCurrent()->DictCount)
#define kIl2CppArrayMaxLength         (GameOffsetsCurrent()->Il2CppArrayMaxLength)
#define kIl2CppArrayItems             (GameOffsetsCurrent()->Il2CppArrayItems)
#define kDictEntryStrideBytePlayer    (GameOffsetsCurrent()->DictEntryStrideBytePlayer)
#define kDictEntryValueOffByte        (GameOffsetsCurrent()->DictEntryValueOffByte)
#define kTransformInner               (GameOffsetsCurrent()->TransformInner)
#define kTransformMatrix              (GameOffsetsCurrent()->TransformMatrix)
#define kTransformIndex               (GameOffsetsCurrent()->TransformIndex)
#define kMatrixList                   (GameOffsetsCurrent()->MatrixList)
#define kMatrixIndices                (GameOffsetsCurrent()->MatrixIndices)
#define kNickname                     (GameOffsetsCurrent()->Nickname)
#define kStringFirstChar              (GameOffsetsCurrent()->StringFirstChar)
#define kActiveWeapon                 (GameOffsetsCurrent()->ActiveWeapon)
#define kWeaponID                     (GameOffsetsCurrent()->WeaponID)
#define kWeaponCategory               (GameOffsetsCurrent()->WeaponCategory)
#define kWeaponHolder                 (GameOffsetsCurrent()->WeaponHolder)
#define kHolderActiveWeapon           (GameOffsetsCurrent()->HolderActiveWeapon)
#define kWeaponRepItem                (GameOffsetsCurrent()->WeaponRepItem)
#define kSwitchWeaponTime             (GameOffsetsCurrent()->SwitchWeaponTime)
#define kPreSwitchWeaponTime          (GameOffsetsCurrent()->PreSwitchWeaponTime)
#define kPostSwitchWeaponTime         (GameOffsetsCurrent()->PostSwitchWeaponTime)
#define kNicknameDisplay              (GameOffsetsCurrent()->NicknameDisplay)
#define kHitObjectInfo                (GameOffsetsCurrent()->HitObjectInfo)
#define kHitObjectInfoAlt             (GameOffsetsCurrent()->HitObjectInfoAlt)
#define kHitObjectDir                 (GameOffsetsCurrent()->HitObjectDir)
#define kHitObjectOrigin              (GameOffsetsCurrent()->HitObjectOrigin)
#define kFollowCameraObj              (GameOffsetsCurrent()->FollowCameraObj)
#define kFollowCameraDistance         (GameOffsetsCurrent()->FollowCameraDistance)
#define kVehicleIAmIn                 (GameOffsetsCurrent()->VehicleIAmIn)
#define kLevelStropIAmOn              (GameOffsetsCurrent()->LevelStropIAmOn)
#define kRootNode                     (GameOffsetsCurrent()->RootNode)
#define kPlayerTransform              (GameOffsetsCurrent()->PlayerTransform)
#define kLastAimingTargetFromWeapon   (GameOffsetsCurrent()->LastAimingTargetFromWeapon)
#define kBaseGameUIScene              (GameOffsetsCurrent()->BaseGameUIScene)
#define kUIInGameScenePrepareCtrl     (GameOffsetsCurrent()->UIInGameScenePrepareCtrl)
#define kUIInGameSceneQuickUseMedkit  (GameOffsetsCurrent()->UIInGameSceneQuickUseMedkit)
#define kPrepTimerStartTime           (GameOffsetsCurrent()->PrepTimerStartTime)
#define kPrepTimerTotalTime           (GameOffsetsCurrent()->PrepTimerTotalTime)
#define kPrepTimerContextType         (GameOffsetsCurrent()->PrepTimerContextType)
#define kPrepTimerStage1Time          (GameOffsetsCurrent()->PrepTimerStage1Time)
#define kPrepTimerIsFinished          (GameOffsetsCurrent()->PrepTimerIsFinished)
#define kPrepTimerProgressSpeed       (GameOffsetsCurrent()->PrepTimerProgressSpeed)
#define kPrepTimerProgressRate        (GameOffsetsCurrent()->PrepTimerProgressRate)
#define kPlayerPrepTimerType          (GameOffsetsCurrent()->PlayerPrepTimerType)
#define kPlayerNetPrepDuration        (GameOffsetsCurrent()->PlayerNetPrepDuration)
#define kPlayerNetPrepType            (GameOffsetsCurrent()->PlayerNetPrepType)
#define kPlayerNetPrepFloatA          (GameOffsetsCurrent()->PlayerNetPrepFloatA)
#define kPlayerNetPrepFloatB          (GameOffsetsCurrent()->PlayerNetPrepFloatB)
#define kPlayerIsCuring               (GameOffsetsCurrent()->PlayerIsCuring)
#define kPlayerIsPreparing            (GameOffsetsCurrent()->PlayerIsPreparing)
#define kPlayerIsEating               (GameOffsetsCurrent()->PlayerIsEating)
#define kPlayerIsRepairing            (GameOffsetsCurrent()->PlayerIsRepairing)
#define kPlayerNetPrepFloatC          (GameOffsetsCurrent()->PlayerNetPrepFloatC)
#define kPlayerNetPrepFloatD          (GameOffsetsCurrent()->PlayerNetPrepFloatD)
#define kWeaponConsumableCsv          (GameOffsetsCurrent()->WeaponConsumableCsv)
#define kWeaponConsumableCsvFloatA    (GameOffsetsCurrent()->WeaponConsumableCsvFloatA)
#define kWeaponConsumableCsvFloatB    (GameOffsetsCurrent()->WeaponConsumableCsvFloatB)
#define kWeaponConsumableCsvFloatC    (GameOffsetsCurrent()->WeaponConsumableCsvFloatC)
#define kWeaponRepairRepItem          (GameOffsetsCurrent()->WeaponRepairRepItem)
#define kWeaponFirstAidRepItem        (GameOffsetsCurrent()->WeaponFirstAidRepItem)
#define kWeaponInhalerRepItem         (GameOffsetsCurrent()->WeaponInhalerRepItem)
#define kUGCFirstAidDuration          (GameOffsetsCurrent()->UGCFirstAidDuration)
#define kUGCFirstAidPretime           (GameOffsetsCurrent()->UGCFirstAidPretime)
#define kUGCRepairPreTime             (GameOffsetsCurrent()->UGCRepairPreTime)
// ===== ĐẠN THẲNG + FPP RECOIL (all in one table — update mỗi season ở GameOffsets.mm / offsetmax.h) =====
#define kRepFireInterval              (GameOffsetsCurrent()->RepFireInterval)
#define kRepRepeatFireInterval        (GameOffsetsCurrent()->RepRepeatFireInterval)
#define kRepScatterNum                (GameOffsetsCurrent()->RepScatterNum)
#define kRepScatterMax                (GameOffsetsCurrent()->RepScatterMax)
#define kRepScatterSpeed              (GameOffsetsCurrent()->RepScatterSpeed)
#define kRepScatterRecoverSpeed       (GameOffsetsCurrent()->RepScatterRecoverSpeed)
#define kRepScatterMove               (GameOffsetsCurrent()->RepScatterMove)
#define kAttrsBuffWeaponScatterScale  (GameOffsetsCurrent()->AttrsBuffWeaponScatterScale)
#define kAttrsBuffEcaWeaponScatterScale (GameOffsetsCurrent()->AttrsBuffEcaWeaponScatterScale)
#define kAttrsBuffEcaIgnoreWeaponScatter (GameOffsetsCurrent()->AttrsBuffEcaIgnoreWeaponScatter)
#define kAttrsReloadNoConsumeAmmo     (GameOffsetsCurrent()->AttrsReloadNoConsumeAmmo)
#define kAttrsShootNoReload           (GameOffsetsCurrent()->AttrsShootNoReload)
#define kAttrsFireIntervalScale       (GameOffsetsCurrent()->AttrsFireIntervalScale)
#define kAttrsFireIntervalScaleTwo    (GameOffsetsCurrent()->AttrsFireIntervalScaleTwo)
#define kAttrsFireIntervalScaleBuffECA (GameOffsetsCurrent()->AttrsFireIntervalScaleBuffECA)
#define kScaleAccumA                  (GameOffsetsCurrent()->ScaleAccumA)
#define kScaleAccumB                  (GameOffsetsCurrent()->ScaleAccumB)
#define kScaleAccumC                  (GameOffsetsCurrent()->ScaleAccumC)
#define kScaleAccumD                  (GameOffsetsCurrent()->ScaleAccumD)
#define kScaleAccumE                  (GameOffsetsCurrent()->ScaleAccumE)
#define kSafeRefHashSet               (GameOffsetsCurrent()->SafeRefHashSet)
#define kHashSetBuckets               (GameOffsetsCurrent()->HashSetBuckets)
#define kHashSetSlots                 (GameOffsetsCurrent()->HashSetSlots)
#define kHashSetCount                 (GameOffsetsCurrent()->HashSetCount)
#define kHashSetLastIndex             (GameOffsetsCurrent()->HashSetLastIndex)
#define kHashSetFreeList              (GameOffsetsCurrent()->HashSetFreeList)
#define kFppGameModeEnable            (GameOffsetsCurrent()->FppGameModeEnable)
#define kFppRecoil                    (GameOffsetsCurrent()->FppRecoil)
#define kFppVibrateRotate             (GameOffsetsCurrent()->FppVibrateRotate)
#define kFppVibrateRotateSpeed        (GameOffsetsCurrent()->FppVibrateRotateSpeed)
#define kFppRecoilYCycleTime          (GameOffsetsCurrent()->FppRecoilYCycleTime)
#define kFppRecoilZCycleTime          (GameOffsetsCurrent()->FppRecoilZCycleTime)
#define kFppRecoilYFactor             (GameOffsetsCurrent()->FppRecoilYFactor)
#define kFppRecoilZFactor             (GameOffsetsCurrent()->FppRecoilZFactor)
#define kFppRecoilBackwardX           (GameOffsetsCurrent()->FppRecoilBackwardX)
#define kFppRecoilBackwardZ           (GameOffsetsCurrent()->FppRecoilBackwardZ)
#define kFppRecoilBackwardSpeed       (GameOffsetsCurrent()->FppRecoilBackwardSpeed)
#define kFppCameraMaxfireRotateAngle  (GameOffsetsCurrent()->FppCameraMaxfireRotateAngle)
#define kFppCameraFireRotateTime      (GameOffsetsCurrent()->FppCameraFireRotateTime)
#define kRuntimeWeapon                (GameOffsetsCurrent()->RuntimeWeapon)

// Layout inside Vehicle / LevelStrop (stable MonoBehaviour-ish fields from dump).
// Vehicle: Rigidbody @ 0x128, cached pos candidates @ 0x178/0x184/0x190, LevelVehicle @ 0x120
// LevelStrop: StartPoint Transform @ 0x138, EndPoint @ 0x140 (BaseLevelObject GameObject @ 0x98)
#define kVehicleRigidBody             0x128
#define kVehicleCachedPosA            0x178
#define kVehicleCachedPosB            0x184
#define kVehicleCachedPosC            0x190
#define kVehicleLevelVehicle          0x120
#define kLevelStropStartPoint         0x138
#define kLevelStropEndPoint           0x140
#define kBaseLevelObjectGameObject    0x98

// ---------------------------------------------------------------------------
// Look-axis input (anti-cheat evidence source).
//
// Season 1.132.1 added an aim-input evidence pipeline that did not exist in
// 1.130.1:
//   GCommon.UserControlHandler.SampleAimInput      RVA 0x6B584F8 (len 0x290)
//   GCommon.UserControlHandler.FillAimInputSamples RVA 0x6B589D8 (len 0x454)
//
// SampleAimInput samples the REAL look-stick position from
// UserControlHandler.m_AxisData[] and appends it to a ring buffer; the ring is
// shipped to the server inside the GGP report. Unwritten ring slots are packed
// as -1.0f (0xBF800000, materialised twice in FillAimInputSamples) — and
// "-1 samples while CallSetAimRotationCount increments" is the aimbot signal.
//
// So we feed the game the input it samples instead of forging the evidence.
// Verified against UserControlHandler / UserControlAxisData in dump.cs.
// ---------------------------------------------------------------------------
#define kUCHandlerAxisData            0x68   // UserControlAxisData[] m_AxisData
#define kUCHandlerCurrentTouchData    0x80   // UserControlTouchData
#define kUCHandlerLastRawDataCache    0x70   // float[] m_LastRawDataCache
#define kUCHandlerIsUserControlChange 0x78   // bool m_IsUserControlChanged

// UserControlAxisData (class instance)
#define kAxisDirection                0x10   // Vector3
#define kAxisDeltaPos                 0x1C   // Vector3
#define kAxisLastDirection            0x28   // Vector3
#define kAxisCurrentDeltaValue        0x54   // Vector3
#define kAxisStartScreenPos           0x60   // Vector3
#define kAxisCurrentScreenPos         0x6C   // Vector3  <-- what the game samples
// Gate on the sampling path. SampleAimInput reads m_CurrentScreenPos only when this
// is 1, and samples a constant when it is not -- see esp.mm drive_look_axis_input.
#define kAxisTouched                  0x4B   // bool m_IsTouched
#define kAxisActuallyMovedDistance    0x88   // float
#define kAxisType                     0x98   // EAxisDataType (int): Right == 1

// UserControlTouchData (class instance)
#define kTouchCurrentScreenPos        0x30   // Vector3
#define kTouchActuallyMovedDistance   0x3C   // float
#define kTouchCachedScreenPos         0x40   // Vector3

// GameVarDef statics used by the evidence pipeline
#define kGvdAimSampleEnabled          0x458D // bool  EnableAimInputSample
#define kGvdAimSampleCount            0x4590 // int   AimInputSampleCount
#define kGvdAimSampleIntervalTick     0x4594 // int   AimInputSampleIntervalTick
