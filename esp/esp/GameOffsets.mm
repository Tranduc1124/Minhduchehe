#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>   // CACurrentMediaTime, the retry log throttle
#import "GameOffsets.h"
#import "ESPPrefs.h"
#import "offsetmax.h"
#import "pid.h"

#include <string.h>

static NSString *const kSelectedGameIdKey = @"SelectedGameId";
static NSString *const kGameIdFF = @"ff";
static NSString *const kGameIdFFMax = @"ffmax";

// Free Fire THG — from D:\Download\dump ff thg (current season)
// TypeInfo (script.json): GameFacade 0xC012848, KBCJOEFJEFJ(AimAssist) 0xC015B80
// NOTE: field offsets often stay same across hotfixes; TypeInfo almost always moves.
static const GameOffsets kOffsetsFF = {
    .GameFacadeTypeInfo = 0xBB46A50, // 1.132.1: DSGames:FF_GAMEFACADE_CLASS
    .TypeInfoStatics = 0xB8,
    .CurrentGame = 0x0,
    .CurrentMatchGame = 0x8,
    .Match = 0x90,
    .MatchLocalPlayer = 0xD8,
    .MatchGameSceneLoaded = 0x140, // MatchGame.m_SceneLoaded
    .CameraControllerManager = 0xD8,
    .MainCamera = 0x20,
    .CameraInner = 0x10,
    .ViewMatrixOff = 0x80,
    .ProjMatrixOff = 0xC0,
    .BodyPartTransNode = 0x10,
    .HeadNode = 0x6A0, // 1.132.1: DSGames:FF_BONE_HEAD
    .HipNode = 0x6A8, // 1.132.1: DSGames:FF_BONE_HIP
    .LeftAnkleNode = 0x6D8, // 1.132.1: DSGames:FF_BONE_LANKLE
    .RightAnkleNode = 0x6E0, // 1.132.1: DSGames:FF_BONE_RANKLE
    .RightToeNode = 0x6F0, // 1.132.1: DSGames:FF_BONE_RTOE
    .LeftToeNode = 0x6E8, // 1.132.1: Player.GMJLIMFHMAE
    .LeftShoulderNode = 0x6C0, // 1.132.1: Player.CFMDINAGALM
    .RightShoulderNode = 0x6C8, // 1.132.1: Player.IIPBIDIBJDK
    .NeckNode = 0x6B0,    // 1.132.1: Player.FFFPCADFFGA — Hip→Shoulder slot
    .ChestNode = 0x6B8,   // 1.132.1: Player.CBHHCCNKOND — Hip→Shoulder slot
    .SpineNode = 0x6D0,   // 1.132.1: Player.EJJBPONNECG — after shoulders
    .LeftHandNode = 0x720, // 1.132.1: DSGames:FF_BONE_LHAND
    .RightHandNode = 0x718, // 1.132.1: DSGames:FF_BONE_RHAND
    .LeftElbowNode = 0x730, // 1.132.1: DSGames:FF_BONE_LFORE
    .RightElbowNode = 0x728, // 1.132.1: DSGames:FF_BONE_RFORE
    .PlayerIDStruct = 0x408, // 1.132.1: Player.MHGFKKALMDK
    .PlayerID = 0x408, // 1.132.1: Player.MHGFKKALMDK
    .UserID = 0x3F8, // 1.132.1: Player.DBGOHLDFABH
    .IsClientBot = 0x4A0, // dump.cs Player.IsClientBot (was stale 0x438)
    .IsDead = 0x7C, // 1.132.1: AttackableEntity.PIKCADEGMOH (get_IsDead)
    .EntityRecycled = 0x28, // 1.132.1: GCommon.Entity.m_Recycle
    .EntityNeedUpdate = 0x20, // 1.132.1: GCommon.Entity.NeedUpdate
    .DataPool = 0x70,
    .DataPoolInner = 0x10,
    .DataPoolEntriesBase = 0x20,
    .DataPoolEntryStride = 0x8,
    .DataPoolValue = 0x18,
    .AimRotation = 0x614, // 1.132.1: DSGames:FF_PLR_AimRot
    .AimRotationAux = 0x628, // 1.132.1: DSGames:FF_PLR_AimRotAlt
    .CurrentAimRotation = 0x1A8C, // 1.132.1: Player.m_CurrentAimRotation
    .CallSetAimRotationCount = 0x810, // 1.132.1: Player.CallSetAimRotationCount (dump.cs:1216954) — bumped only by SetAimRotation, snapshotted by report 0x69 then zeroed
    .UserControlHandler = 0x4D0, // 1.132.1: Player.LBPGBNKABJE (dump.cs:1216779)
    .AimSampleX = 0xA0,          // UserControlHandler.m_aimInputSampleX (dump.cs:1458229)
    .AimSampleY = 0xA8,          // m_aimInputSampleY (1458230)
    .AimSampleHead = 0xB0,       // m_aimInputSampleHead (1458231)
    .AimSampleFilled = 0xB4,     // m_aimInputSampleFilled (1458232)
    .AimSampleTickCounter = 0xB8, // m_aimInputSampleTickCounter (1458233)
    .AimAssistTypeInfo = 0xBB48080, // 1.132.1: IILKFCMKIBG::.cctor ARM64 ADRP/ADD at 0x63B815C/0x63B8160
    .AaStaticKnolgmjlcef = 0x24,
    .AaStaticNfkcllpalej = 0x28,
    .GameVarDefTypeInfo = 0xBB46AF8, // 1.132.1: adrp x22,#0xbb46000 / add x22,#0xaf8 (SampleAimInput 0x6B58518)
    .GvdEnableCheckBuf = 0x458C,       // dump.cs GameVarDef.EnableCheckBuf — AC 0x5632eec ldrb cmp #1
    .GvdEnableAimInputSample = 0x458D, // dump.cs — SampleAimInput 0x6b58534 ldrb cmp #1
    .GvdAimInputSampleCount = 0x4590,  // dump.cs — FillAimInputSamples 0x6b58a28 ldr cmp #1
    .GvdAimInputSampleIntervalTick = 0x4594, // dump.cs:305087 AimInputSampleIntervalTick
    .GvdEnableInternalSetRotation = 0xE4, // dump.cs GameVarDef.EnableInternalSetRotation — CurrentAimWriter 0x5a63bf8 ldrb [x8,#0xe4]
    .GvdRotationPlan = 0x380C, // dump.cs GameVarDef.RotationPlan — HFIKAJMBGJG 0x576c7c8 ldr [x8,#0x380c]
    .CheckBufPending = 0x624,  // dump.cs:1216869 IKCEKAKDFJC bool after AimRot 0x614 — MarkGGPVerifyCheckBufPending
    .AimAssistPtr = 0x638, // 1.132.1: Player.m_AimAssist
    .AimAssistIceWallPtr = 0x640, // 1.132.1: Player.m_AimAssistForIceWall
    .EAimAssistMode = 0x660, // 1.132.1: Player.ADMMKBGOLJL
    .PlayerAnimComponent = 0x760, // 1.132.1: Player.NLENBNNCDMC
    .PlayerAttributes = 0x768, // 1.132.1: Player.IODLOCEJIOK
    .RunSpeedUpScale = 0x2C0, // 1.132.1: PlayerAttributes.RunSpeedUpScale
    .IsFiring = 0x1DF0, // 1.132.1: Player.LOCPKOHLOHE (NDFCBGGDEFP StartFireState enum — NOT a bool)
    .IsPrepareAttack = 0x848, // 1.132.1: ARM64 0x563711c: ldrb w0, [x0, #0x848]
    .LastFireBtnDownTime = 0x183C, // 1.132.1: Player.LastFireBtnDownTime
    .LastPlayBulletTrackEffectTime = 0xE84, // 1.132.1: Player.LastPlayBulletTrackEffectTime
    .LastSmartFireTime = 0xDF0, // 1.132.1: Player.LastSmartFireTime
    .VisibleObj = 0xAD0, // 1.132.1: DSGames:FF_PLR_VisMask
    .VisibleObjFlags = 0x10,
    .ISVisibleCamera = 0x1,
    .ISVisibleDynamicPVS = 0x100000,
    .ISVisibleFPPMask = 0xFFFBFFFF,
    .MainCameraTransform = 0x3E8, // 1.132.1: DSGames:FF_PLR_CamTfm
    .MyPhysXData = 0x1D48, // 1.132.1: Player.GBJCJJNPPEC
    .PhxNpeononogeo = 0x20,
    .GhgState = 0x10,
    .Knocked = 0x1258, // 1.132.1: Player.IsKnockedDownBleed
    .BeingRescuredState = 0x1CA2, // 1.132.1: Player.BBMCPEHJGCM
    .MatchPlayerDict = 0x128,
    .DictEntries = 0x18,
    .DictCount = 0x20,
    .Il2CppArrayMaxLength = 0x18,
    .Il2CppArrayItems = 0x20,
    .DictEntryStrideBytePlayer = 0x28,
    .DictEntryValueOffByte = 0x20,
    .TransformInner = 0x10,
    .TransformMatrix = 0x38,
    .TransformIndex = 0x40,
    .MatrixList = 0x18,
    .MatrixIndices = 0x20,
    .Nickname = 0x490, // 1.132.1: Player.BDHGDLFDHAL
    .StringFirstChar = 0x14,
    .ActiveWeapon = 0x600, // 1.132.1: Player.ActiveUISightingWeapon
    .WeaponID = 0x600,
    .WeaponCategory = 0xC4,
    .WeaponHolder = 0x740, // 1.132.1: DSGames:FF_PLR_InvMgr
    .HolderActiveWeapon = 0xA0,
    .WeaponRepItem = 0x768, // 1.132.1: HBIBDMMOOOK.EPDDDHPMIKO
    .SwitchWeaponTime = 0x284, // 1.132.1: UGCWeaponRepItem.<SwitchWeaponTime>k__BackingField
    .PreSwitchWeaponTime = 0x288, // 1.132.1: UGCWeaponRepItem.<PreSwitchWeaponTime>k__BackingField
    .PostSwitchWeaponTime = 0x28C, // 1.132.1: UGCWeaponRepItem.<PostSwitchWeaponTime>k__BackingField
    .NicknameDisplay = 0x498, // 1.132.1: DSGames:FF_PLR_Nick
    .HitObjectInfo = 0xE50, // dump.cs Player.FDMIEDDNCEC (CGKJLKPMGDJ) — was stale 0xDC8
    .HitObjectInfoAlt = 0xE58, // dump.cs Player.PKIOAMDCOPB (CGKJLKPMGDJ) — was stale 0xDD0
    .HitObjectDir = 0x40, // GMPGMPFNMFP.IKDEGKIICJP
    .HitObjectOrigin = 0x4C, // GMPGMPFNMFP.LMAEGPEAECO
    .FollowCameraObj = 0x690, // dump.cs Player.AHNCPOJPPCL FollowCamera (0x628 is AimRotationAux — do not reuse)
    .FollowCameraDistance = 0x70,
    .VehicleIAmIn = 0x920, // 1.132.1: Player.NABHAGPOHJF
    .LevelStropIAmOn = 0x938, // 1.132.1: Player.DPPMGDFKBLO
    .RootNode = 0x698, // 1.132.1: DSGames:FF_BONE_NECK
    .PlayerTransform = 0x700, // 1.132.1: Player.BDMMCNJOHNI
    .LastAimingTargetFromWeapon = 0xE68, // 1.132.1: Player.<JMPDDMAMFML>k__BackingField
    .BaseGameUIScene = 0x10,
    .UIInGameScenePrepareCtrl = 0x730, // 1.132.1: UIInGameScene.m_PrepareCtrl
    .UIInGameSceneQuickUseMedkit = 0xA40, // 1.132.1: UIInGameScene.m_UIHudQuickUseMedkitController
    .PrepTimerStartTime = 0xB0, // 1.132.1: UIHudPreparationTimerController.m_StartTime
    .PrepTimerTotalTime = 0xB4, // 1.132.1: UIHudPreparationTimerController.m_TotalTime
    .PrepTimerContextType = 0xB8, // 1.132.1: UIHudPreparationTimerController.m_ContextType
    .PrepTimerStage1Time = 0xBC, // 1.132.1: UIHudPreparationTimerController.m_Stage1Time
    .PrepTimerIsFinished = 0x128, // 1.132.1: UIHudPreparationTimerController.m_IsPrepareFinished
    .PrepTimerProgressSpeed = 0x148, // 1.132.1: UIHudPreparationTimerController.m_CurrentProgressSpeed
    .PrepTimerProgressRate = 0x14C, // 1.132.1: UIHudPreparationTimerController.m_CurrentProgressRate
    .PlayerPrepTimerType = 0x4C4, // 1.132.1: Player.NLDHFLPENMC
    .PlayerNetPrepDuration = 0x2510, // 1.132.1: PlayerNetwork.JPDINEAKPLA
    .PlayerNetPrepType = 0x2514, // 1.132.1: PlayerNetwork.PDAHKMAMAFO
    .PlayerNetPrepFloatA = 0x2524, // 1.132.1: PlayerNetwork.GGNLKLLOGMF
    .PlayerNetPrepFloatB = 0x2528, // 1.132.1: PlayerNetwork.GDDPGFNHIKF
    .PlayerIsCuring = 0x4F0, // 1.132.1: ARM64 0x56321ec: ldrb w0, [x19, #0x4f0]
    .PlayerIsPreparing = 0x4F9, // 1.132.1: ARM64 0x5632268: ldrb w0, [x0, #0x4f9]
    .PlayerIsEating = 0x4FA, // 1.132.1: ARM64 0x5632278: ldrb w0, [x0, #0x4fa]
    .PlayerIsRepairing = 0x4FB, // 1.132.1: ARM64 0x5632288: ldrb w0, [x0, #0x4fb]
    .PlayerNetPrepFloatC = 0x252C, // 1.132.1: PlayerNetwork.ALFHOFAMDLH
    .PlayerNetPrepFloatD = 0x2538, // 1.132.1: PlayerNetwork.AMKBOGJODLG
    .WeaponConsumableCsv = 0x68,
    .WeaponConsumableCsvFloatA = 0x24,
    .WeaponConsumableCsvFloatB = 0x28,
    .WeaponConsumableCsvFloatC = 0x40,
    .WeaponRepairRepItem = 0x78,
    .WeaponFirstAidRepItem = 0x80,
    .WeaponInhalerRepItem = 0x88,
    .UGCFirstAidDuration = 0x34,
    .UGCFirstAidPretime = 0x38,
    .UGCRepairPreTime = 0x20,
    .RepFireInterval = 0x1F8, // 1.132.1: UGCWeaponRepItem.<FireInterval>k__BackingField
    .RepRepeatFireInterval = 0x220, // 1.132.1: UGCWeaponRepItem.<RepeatFireInterval>k__BackingField
    .RepScatterNum = 0x214, // 1.132.1: UGCWeaponRepItem.<ScatterNum>k__BackingField
    .RepScatterMax = 0x218, // 1.132.1: UGCWeaponRepItem.<ScatterMax>k__BackingField
    .RepScatterSpeed = 0x260, // 1.132.1: UGCWeaponRepItem.<ScatterSpeed>k__BackingField
    .RepScatterRecoverSpeed = 0x264, // 1.132.1: UGCWeaponRepItem.<ScatterRecoverSpeed>k__BackingField
    .RepScatterMove = 0x26C, // 1.132.1: UGCWeaponRepItem.<ScatterMove>k__BackingField
    .AttrsBuffWeaponScatterScale = 0x118, // 1.132.1: PlayerAttributes.BuffWeaponScatterScale
    .AttrsBuffEcaWeaponScatterScale = 0x120, // 1.132.1: PlayerAttributes.BuffEcaWeaponScatterScale
    .AttrsBuffEcaIgnoreWeaponScatter = 0x350, // 1.132.1: PlayerAttributes.BuffEcaIgnoreWeaponScatter
    .AttrsReloadNoConsumeAmmo = 0x110, // 1.132.1: PlayerAttributes.ReloadNoConsumeAmmoclip (stale 0xD8 = HBMLFJEAEDC float)
    .AttrsShootNoReload = 0x111,       // 1.132.1: PlayerAttributes.ShootNoReload (stale 0xD9 = NELIGHEPBDL int)
    .AttrsFireIntervalScale = 0x258, // 1.132.1: ARM64 0x648781c: ldr s0, [x19, #0x258]
    .AttrsFireIntervalScaleTwo = 0x270, // 1.132.1: ARM64 0x6487a88: ldr s0, [x19, #0x270]
    .AttrsFireIntervalScaleBuffECA = 0x268, // 1.132.1: PlayerAttributes.FireIntervalScaleBuffECA_AccumulateWithBounds
    .ScaleAccumA = 0x18,
    .ScaleAccumB = 0x1C,
    .ScaleAccumC = 0x20,
    .ScaleAccumD = 0x24,
    .ScaleAccumE = 0x28,
    .SafeRefHashSet = 0x10,
    .HashSetBuckets = 0x10,
    .HashSetSlots = 0x18,
    .HashSetCount = 0x20,
    .HashSetLastIndex = 0x24,
    .HashSetFreeList = 0x28,
    .FppGameModeEnable = 0x829, // 1.132.1: GameModeSetting.FPPGameModeEnable
    .FppRecoil = 0x870, // 1.132.1: GameModeSetting.FPPRecoil
    .FppVibrateRotate = 0x871, // 1.132.1: GameModeSetting.FPPVibrateRotate
    .FppVibrateRotateSpeed = 0x874, // 1.132.1: GameModeSetting.FPPVibrateRotateSpeed
    .FppRecoilYCycleTime = 0x880, // 1.132.1: GameModeSetting.FPPRecoilYCycleTime
    .FppRecoilZCycleTime = 0x884, // 1.132.1: GameModeSetting.FPPRecoilZCycleTime
    .FppRecoilYFactor = 0x888, // 1.132.1: GameModeSetting.FPPRecoilYFactor
    .FppRecoilZFactor = 0x88C, // 1.132.1: GameModeSetting.FPPRecoilZFactor
    .FppRecoilBackwardX = 0x890, // 1.132.1: GameModeSetting.FPPRecoilBackwardX
    .FppRecoilBackwardZ = 0x894, // 1.132.1: GameModeSetting.FPPRecoilBackwardZ
    .FppRecoilBackwardSpeed = 0x898, // 1.132.1: GameModeSetting.FPPRecoilBackwardSpeed
    .FppCameraMaxfireRotateAngle = 0x8B4, // 1.132.1: GameModeSetting.FPPCameraMaxfireRotateAngle
    .FppCameraFireRotateTime = 0x8B8, // 1.132.1: GameModeSetting.FPPCameraFireRotateTime
    .RuntimeWeapon = 0x17E8, // 1.132.1: Player.FCKONEHNLHP
};

// Free Fire MAX — values from offsetmax.h (clone of FF until user patches)
static const GameOffsets kOffsetsFFMax = {
    .GameFacadeTypeInfo = MAX_kGameFacadeTypeInfo,
    .TypeInfoStatics = MAX_kTypeInfoStatics,
    .CurrentGame = MAX_kCurrentGame,
    .CurrentMatchGame = MAX_kCurrentMatchGame,
    .Match = MAX_kMatch,
    .MatchLocalPlayer = MAX_kMatchLocalPlayer,
    .MatchGameSceneLoaded = MAX_kMatchGameSceneLoaded,
    .CameraControllerManager = MAX_kCameraControllerManager,
    .MainCamera = MAX_kMainCamera,
    .CameraInner = MAX_kCameraInner,
    .ViewMatrixOff = MAX_kViewMatrixOff,
    .ProjMatrixOff = MAX_kProjMatrixOff,
    .BodyPartTransNode = MAX_kBodyPartTransNode,
    .HeadNode = MAX_kHeadNode,
    .HipNode = MAX_kHipNode,
    .LeftAnkleNode = MAX_kLeftAnkleNode,
    .RightAnkleNode = MAX_kRightAnkleNode,
    .RightToeNode = MAX_kRightToeNode,
    .LeftToeNode = MAX_kLeftToeNode,
    .LeftShoulderNode = MAX_kLeftShoulderNode,
    .RightShoulderNode = MAX_kRightShoulderNode,
    .NeckNode = MAX_kNeckNode,
    .ChestNode = MAX_kChestNode,
    .SpineNode = MAX_kSpineNode,
    .LeftHandNode = MAX_kLeftHandNode,
    .RightHandNode = MAX_kRightHandNode,
    .LeftElbowNode = MAX_kLeftElbowNode,
    .RightElbowNode = MAX_kRightElbowNode,
    .PlayerIDStruct = MAX_kPlayerIDStruct,
    .PlayerID = MAX_kPlayerID,
    .UserID = MAX_kUserID,
    .IsClientBot = MAX_kIsClientBot,
    .IsDead = MAX_kIsDead,
    .EntityRecycled = MAX_kEntityRecycled,
    .EntityNeedUpdate = MAX_kEntityNeedUpdate,
    .DataPool = MAX_kDataPool,
    .DataPoolInner = MAX_kDataPoolInner,
    .DataPoolEntriesBase = MAX_kDataPoolEntriesBase,
    .DataPoolEntryStride = MAX_kDataPoolEntryStride,
    .DataPoolValue = MAX_kDataPoolValue,
    .AimRotation = MAX_kAimRotation,
    .AimRotationAux = MAX_kAimRotationAux,
    .CurrentAimRotation = MAX_kCurrentAimRotation,
    .CallSetAimRotationCount = MAX_kCallSetAimRotationCount,
    .UserControlHandler = MAX_kUserControlHandler, // TH 0x4D0 + 8 = 0x4D8
    .AimSampleX = 0xA0, // UserControlHandler object layout — same as TH
    .AimSampleY = 0xA8,
    .AimSampleHead = 0xB0,
    .AimSampleFilled = 0xB4,
    .AimSampleTickCounter = 0xB8,
    .AimAssistTypeInfo = MAX_kAimAssistTypeInfo,
    .AaStaticKnolgmjlcef = MAX_kAaStaticKnolgmjlcef,
    .AaStaticNfkcllpalej = MAX_kAaStaticNfkcllpalej,
    .GameVarDefTypeInfo = MAX_kGameVarDefTypeInfo,
    .GvdEnableCheckBuf = MAX_kGvdEnableCheckBuf,
    .GvdEnableAimInputSample = MAX_kGvdEnableAimInputSample,
    .GvdAimInputSampleCount = MAX_kGvdAimInputSampleCount,
    .GvdAimInputSampleIntervalTick = MAX_kGvdAimInputSampleIntervalTick,
    .GvdEnableInternalSetRotation = MAX_kGvdEnableInternalSetRotation,
    .GvdRotationPlan = MAX_kGvdRotationPlan,
    .CheckBufPending = 0x62C, // TH 0x624 + MAX mid-field +8 (AimRot 0x61c→0x624 bool, Aux 0x630)
    .AimAssistPtr = MAX_kAimAssistPtr,
    .AimAssistIceWallPtr = MAX_kAimAssistIceWallPtr,
    .EAimAssistMode = MAX_kEAimAssistMode,
    .PlayerAnimComponent = MAX_kPlayerAnimComponent,
    .PlayerAttributes = MAX_kPlayerAttributes,
    .RunSpeedUpScale = MAX_kRunSpeedUpScale,
    .IsFiring = MAX_kIsFiring,
    .IsPrepareAttack = MAX_kIsPrepareAttack,
    .LastFireBtnDownTime = MAX_kLastFireBtnDownTime,
    .LastPlayBulletTrackEffectTime = MAX_kLastPlayBulletTrackEffectTime,
    .LastSmartFireTime = MAX_kLastSmartFireTime,
    .VisibleObj = MAX_kVisibleObj,
    .VisibleObjFlags = MAX_kVisibleObjFlags,
    .ISVisibleCamera = MAX_kISVisibleCamera,
    .ISVisibleDynamicPVS = MAX_kISVisibleDynamicPVS,
    .ISVisibleFPPMask = MAX_kISVisibleFPPMask,
    .MainCameraTransform = MAX_kMainCameraTransform,
    .MyPhysXData = MAX_kMyPhysXData,
    .PhxNpeononogeo = MAX_kPhxNpeononogeo,
    .GhgState = MAX_kGhgState,
    .Knocked = MAX_kKnocked,
    .BeingRescuredState = MAX_kBeingRescuredState,
    .MatchPlayerDict = MAX_kMatchPlayerDict,
    .DictEntries = MAX_kDictEntries,
    .DictCount = MAX_kDictCount,
    .Il2CppArrayMaxLength = MAX_kIl2CppArrayMaxLength,
    .Il2CppArrayItems = MAX_kIl2CppArrayItems,
    .DictEntryStrideBytePlayer = MAX_kDictEntryStrideBytePlayer,
    .DictEntryValueOffByte = MAX_kDictEntryValueOffByte,
    .TransformInner = MAX_kTransformInner,
    .TransformMatrix = MAX_kTransformMatrix,
    .TransformIndex = MAX_kTransformIndex,
    .MatrixList = MAX_kMatrixList,
    .MatrixIndices = MAX_kMatrixIndices,
    .Nickname = MAX_kNickname,
    .StringFirstChar = MAX_kStringFirstChar,
    .ActiveWeapon = MAX_kActiveWeapon,
    .WeaponID = MAX_kWeaponID,
    .WeaponCategory = MAX_kWeaponCategory,
    .WeaponHolder = MAX_kWeaponHolder,
    .HolderActiveWeapon = MAX_kHolderActiveWeapon,
    .WeaponRepItem = MAX_kWeaponRepItem,
    .SwitchWeaponTime = MAX_kSwitchWeaponTime,
    .PreSwitchWeaponTime = MAX_kPreSwitchWeaponTime,
    .PostSwitchWeaponTime = MAX_kPostSwitchWeaponTime,
    .NicknameDisplay = MAX_kNicknameDisplay,
    .HitObjectInfo = MAX_kHitObjectInfo,
    .HitObjectInfoAlt = MAX_kHitObjectInfoAlt,
    .HitObjectDir = MAX_kHitObjectDir,
    .HitObjectOrigin = MAX_kHitObjectOrigin,
    .FollowCameraObj = MAX_kFollowCameraObj,
    .FollowCameraDistance = MAX_kFollowCameraDistance,
    .VehicleIAmIn = MAX_kVehicleIAmIn,
    .LevelStropIAmOn = MAX_kLevelStropIAmOn,
    .RootNode = MAX_kRootNode,
    .PlayerTransform = MAX_kPlayerTransform,
    .LastAimingTargetFromWeapon = MAX_kLastAimingTargetFromWeapon,
    .BaseGameUIScene = MAX_kBaseGameUIScene,
    .UIInGameScenePrepareCtrl = MAX_kUIInGameScenePrepareCtrl,
    .UIInGameSceneQuickUseMedkit = MAX_kUIInGameSceneQuickUseMedkit,
    .PrepTimerStartTime = MAX_kPrepTimerStartTime,
    .PrepTimerTotalTime = MAX_kPrepTimerTotalTime,
    .PrepTimerContextType = MAX_kPrepTimerContextType,
    .PrepTimerStage1Time = MAX_kPrepTimerStage1Time,
    .PrepTimerIsFinished = MAX_kPrepTimerIsFinished,
    .PrepTimerProgressSpeed = MAX_kPrepTimerProgressSpeed,
    .PrepTimerProgressRate = MAX_kPrepTimerProgressRate,
    .PlayerPrepTimerType = MAX_kPlayerPrepTimerType,
    .PlayerNetPrepDuration = MAX_kPlayerNetPrepDuration,
    .PlayerNetPrepType = MAX_kPlayerNetPrepType,
    .PlayerNetPrepFloatA = MAX_kPlayerNetPrepFloatA,
    .PlayerNetPrepFloatB = MAX_kPlayerNetPrepFloatB,
    .PlayerIsCuring = MAX_kPlayerIsCuring,
    .PlayerIsPreparing = MAX_kPlayerIsPreparing,
    .PlayerIsEating = MAX_kPlayerIsEating,
    .PlayerIsRepairing = MAX_kPlayerIsRepairing,
    .PlayerNetPrepFloatC = MAX_kPlayerNetPrepFloatC,
    .PlayerNetPrepFloatD = MAX_kPlayerNetPrepFloatD,
    .WeaponConsumableCsv = MAX_kWeaponConsumableCsv,
    .WeaponConsumableCsvFloatA = MAX_kWeaponConsumableCsvFloatA,
    .WeaponConsumableCsvFloatB = MAX_kWeaponConsumableCsvFloatB,
    .WeaponConsumableCsvFloatC = MAX_kWeaponConsumableCsvFloatC,
    .WeaponRepairRepItem = MAX_kWeaponRepairRepItem,
    .WeaponFirstAidRepItem = MAX_kWeaponFirstAidRepItem,
    .WeaponInhalerRepItem = MAX_kWeaponInhalerRepItem,
    .UGCFirstAidDuration = MAX_kUGCFirstAidDuration,
    .UGCFirstAidPretime = MAX_kUGCFirstAidPretime,
    .UGCRepairPreTime = MAX_kUGCRepairPreTime,
    .RepFireInterval = MAX_kRepFireInterval,
    .RepRepeatFireInterval = MAX_kRepRepeatFireInterval,
    .RepScatterNum = MAX_kRepScatterNum,
    .RepScatterMax = MAX_kRepScatterMax,
    .RepScatterSpeed = MAX_kRepScatterSpeed,
    .RepScatterRecoverSpeed = MAX_kRepScatterRecoverSpeed,
    .RepScatterMove = MAX_kRepScatterMove,
    .AttrsBuffWeaponScatterScale = MAX_kAttrsBuffWeaponScatterScale,
    .AttrsBuffEcaWeaponScatterScale = MAX_kAttrsBuffEcaWeaponScatterScale,
    .AttrsBuffEcaIgnoreWeaponScatter = MAX_kAttrsBuffEcaIgnoreWeaponScatter,
    .AttrsReloadNoConsumeAmmo = MAX_kAttrsReloadNoConsumeAmmo,
    .AttrsShootNoReload = MAX_kAttrsShootNoReload,
    .AttrsFireIntervalScale = MAX_kAttrsFireIntervalScale,
    .AttrsFireIntervalScaleTwo = MAX_kAttrsFireIntervalScaleTwo,
    .AttrsFireIntervalScaleBuffECA = MAX_kAttrsFireIntervalScaleBuffECA,
    .ScaleAccumA = MAX_kScaleAccumA,
    .ScaleAccumB = MAX_kScaleAccumB,
    .ScaleAccumC = MAX_kScaleAccumC,
    .ScaleAccumD = MAX_kScaleAccumD,
    .ScaleAccumE = MAX_kScaleAccumE,
    .SafeRefHashSet = MAX_kSafeRefHashSet,
    .HashSetBuckets = MAX_kHashSetBuckets,
    .HashSetSlots = MAX_kHashSetSlots,
    .HashSetCount = MAX_kHashSetCount,
    .HashSetLastIndex = MAX_kHashSetLastIndex,
    .HashSetFreeList = MAX_kHashSetFreeList,
    .FppGameModeEnable = MAX_kFppGameModeEnable,
    .FppRecoil = MAX_kFppRecoil,
    .FppVibrateRotate = MAX_kFppVibrateRotate,
    .FppVibrateRotateSpeed = MAX_kFppVibrateRotateSpeed,
    .FppRecoilYCycleTime = MAX_kFppRecoilYCycleTime,
    .FppRecoilZCycleTime = MAX_kFppRecoilZCycleTime,
    .FppRecoilYFactor = MAX_kFppRecoilYFactor,
    .FppRecoilZFactor = MAX_kFppRecoilZFactor,
    .FppRecoilBackwardX = MAX_kFppRecoilBackwardX,
    .FppRecoilBackwardZ = MAX_kFppRecoilBackwardZ,
    .FppRecoilBackwardSpeed = MAX_kFppRecoilBackwardSpeed,
    .FppCameraMaxfireRotateAngle = MAX_kFppCameraMaxfireRotateAngle,
    .FppCameraFireRotateTime = MAX_kFppCameraFireRotateTime,
    .RuntimeWeapon = MAX_kRuntimeWeapon,
};

static const GameOffsets *gActiveOffsets = &kOffsetsFF;
static bool gIsMax = false;

static bool GameIdIsMax(NSString *gameId) {
    if (![gameId isKindOfClass:[NSString class]]) return false;
    NSString *normalized = gameId.lowercaseString;
    return [normalized isEqualToString:kGameIdFFMax] ||
           [normalized isEqualToString:@"max"] ||
           [normalized isEqualToString:@"freefiremax"];
}

NSString *GameTargetSelectedId(void) {
    id raw = AppSettingsObjectForKey(kSelectedGameIdKey);
    if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length] > 0) {
        return GameIdIsMax((NSString *)raw) ? kGameIdFFMax : kGameIdFF;
    }
    return kGameIdFF;
}

void GameTargetSetSelectedId(NSString *gameId) {
    NSString *resolved = GameIdIsMax(gameId) ? kGameIdFFMax : kGameIdFF;
    AppSettingsSetObject(kSelectedGameIdKey, resolved);
    GameOffsetsReload();
}

void GameOffsetsReload(void) {
    gIsMax = GameIdIsMax(GameTargetSelectedId());
    gActiveOffsets = gIsMax ? &kOffsetsFFMax : &kOffsetsFF;
}

const GameOffsets *GameOffsetsCurrent(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        GameOffsetsReload();
    });
    if (!gActiveOffsets) {
        gActiveOffsets = &kOffsetsFF;
    }
    return gActiveOffsets;
}

bool GameTargetIsMax(void) {
    (void)GameOffsetsCurrent();
    return gIsMax;
}

const char *GameTargetProcessName(void) {
    return GameTargetIsMax() ? "FreeFireMAX" : "FreeFire";
}

// Jailed IPA path: kernel-rw provider instead of task_for_pid.
// DSMemory handles attach + module base + reads, all through kexploit.
#import "../DSMemory.h"
#import "pid.h"

int GameTargetProcessPid(void) {
    if (ds_attached()) {
        pid_t p = ds_pid();
        if (p > 0) return p;
    }
    const char *pName = GameTargetProcessName();
    pid_t sysctlPid = GetGameProcesspidExact(pName);
    if (sysctlPid > 0) {
        static pid_t s_lastLogPid = -1;
        if (sysctlPid != s_lastLogPid) {
            s_lastLogPid = sysctlPid;
            NSLog(@"[GameOffsets] Game '%s' detected via sysctl: PID=%d", pName, sysctlPid);
        }
    }
    return sysctlPid;
}

bool GameTargetIsRunning(void) {
    if (ds_attached()) return true;
    return (GameTargetProcessPid() > 0);
}

uintptr_t GameTargetModuleBase(void) {
    if (!ds_attached()) {
        // Throttled, not removed. The game not running is the normal state of
        // this app for most of its life, the ESP tick retries every 30 frames,
        // and an unthrottled NSLog here put two lines a second into the device
        // log for as long as the game stayed closed.
        static uint64_t s_lastTryLogUS = 0;
        uint64_t tUS = (uint64_t)(CACurrentMediaTime() * 1000000.0);
        if (tUS - s_lastTryLogUS >= 1000000) {
            s_lastTryLogUS = tUS;
            NSLog(@"[GameOffsets] GameTargetModuleBase: Attaching to '%s' via ds_attach()...", GameTargetProcessName());
        }
        int ret = ds_attach();
        if (ret != 0) {
            static int s_failCount = 0;
            if (++s_failCount % 30 == 1) {
                NSLog(@"[GameOffsets] ds_attach() failed: code %d", ret);
            }
            return 0;
        }
        NSLog(@"[GameOffsets] ds_attach() SUCCESS: PID=%d, base=0x%llx", ds_pid(), ds_base());
    }
    return (uintptr_t)ds_base();
}
