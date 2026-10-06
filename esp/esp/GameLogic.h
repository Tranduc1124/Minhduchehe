#ifndef GameLogic_h
#define GameLogic_h

#import "pid.h"
#import "UnityMath.h"

#pragma mark - Function Game

uint64_t getMatchGame(uint64_t Moudule_Base);
uint64_t getMatch(uint64_t matchgame);
uint64_t CameraMain(uint64_t matchgame);

float* GetViewMatrix(uint64_t cameraMain);
/** Write P*V into out16[16]. Prefer this under lag (fresh sample per use). */
bool GetViewMatrixInto(uint64_t cameraMain, float *out16);
bool IsAtLobby(uint64_t Moudule_Base);
uint64_t getTransNode(uint64_t BodyPart);
uint64_t getHead(uint64_t player);
uint64_t getHip(uint64_t player);
Vector3 getHeadWorld(uint64_t player);
Vector3 getHipWorld(uint64_t player);
uint64_t getLeftAnkle(uint64_t player);
uint64_t getRightAnkle(uint64_t player);
uint64_t getRightToeNode(uint64_t player);
uint64_t getLeftToeNode(uint64_t player); // Đã bổ sung thêm Node gót chân trái
uint64_t getLeftShoulder(uint64_t player);
uint64_t getRightShoulder(uint64_t player);
uint64_t getLeftElbow(uint64_t player);
uint64_t getRightElbow(uint64_t player);
uint64_t getLeftHand(uint64_t player);
uint64_t getRightHand(uint64_t player);
uint64_t getLocalPlayer(uint64_t match);
int GetDataUInt16(uint64_t player, int varID);

// Report whether HP was actually read. False is "could not tell", which is not 0:
// a dead player really does read 0, and the death filter used to treat a failed
// read as one and wrote a two-second tombstone for a live player.
bool get_CurHPOk(uint64_t player, int *outHp);
bool get_MaxHPOk(uint64_t player, int *outHp);
void SetDataUInt16(uint64_t player, int varID, uint16_t value);
int get_CurHP(uint64_t Player);
int get_MaxHP(uint64_t Player);
bool isLocalTeamMate(uint64_t localPlayer, uint64_t Player);
/** True if pawn is the same person as local (pointer, UserID, or PlayerID). */
bool isSamePlayerAsLocal(uint64_t localPlayer, uint64_t player);

// ==========================================
// CÁC HÀM TÍNH NĂNG MOD
// ==========================================
void EnableFastReload(uint64_t localPlayerPawn, bool isEnabled, float speedMult);

// Kill vanilla game aim-assist (chest magnet) while custom aimbot/assist is active.
void DisableGameDefaultAimAssist(uint64_t localPlayerPawn, bool disable);

#endif