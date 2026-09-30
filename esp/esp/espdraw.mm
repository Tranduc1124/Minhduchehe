#import "esp.h"
#import "GameLogic.h"
#import "mahoa.h"
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <cmath>

// Khai báo biến chứa mảng ảnh Súng từ WeaponTextures.mm
extern NSMutableDictionary *gWeaponTextures;

// NOTE: templates (ReadAddr<T>) and C++ types (Vector3) CANNOT be inside
// extern "C" — so the imports stay above; only the ESP entry points that
// esp.h declares with C linkage get wrapped below.

#ifdef __cplusplus
extern "C" {
#endif

static inline float Clamp01f(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

// ==========================================
// TỐI ƯU HÓA BỘ NHỚ FONT
// ==========================================
static UIFont *cachedFonts[40] = {nil};

UIFont *GetCustomFont(CGFloat size) {
    int intSize = (int)roundf(size);
    if (intSize >= 4 && intSize < 40) {
        if (!cachedFonts[intSize]) {
            cachedFonts[intSize] = [UIFont fontWithName:NSSENCRYPT("arialbd") size:(CGFloat)intSize] ?: [UIFont boldSystemFontOfSize:(CGFloat)intSize];
        }
        return cachedFonts[intSize];
    }
    return [UIFont fontWithName:NSSENCRYPT("arialbd") size:size] ?: [UIFont boldSystemFontOfSize:size];
}

static inline void ESPAddLine(CGMutablePathRef path, CGPoint p1, CGPoint p2) {
    if (!path) return;
    CGPathMoveToPoint(path, NULL, p1.x, p1.y);
    CGPathAddLineToPoint(path, NULL, p2.x, p2.y);
}

static inline void ESPAddCircle(CGMutablePathRef path, CGPoint center, CGFloat radius) {
    if (!path) return;
    CGRect rect = CGRectMake(center.x - radius, center.y - radius, radius * 2.0f, radius * 2.0f);
    CGPathAddEllipseInRect(path, NULL, rect);
}

BOOL RenderFOVCirclePath(
    CGMutablePathRef path,
    float viewWidth,
    float viewHeight,
    BOOL aimbotEnabled,
    float fovRadius
) {
    if (!path || !aimbotEnabled || fovRadius <= 0) return NO;
    // FIX "FOV hình vuông": SB mirror serializer (serFunc) flatten curve → line,
    // AddEllipse thành gạch vuông. Vẽ polyline 72 đoạn — giữ nguyên hình tròn
    // qua cả in-app layer lẫn mirror path (chỉ có Move/Line ops).
    const int kSegs = 72;
    const float cx = viewWidth / 2.0f;
    const float cy = viewHeight / 2.0f;
    const float kTwoPi = 6.28318530718f;
    for (int i = 0; i <= kSegs; i++) {
        const float a = (float)i * kTwoPi / (float)kSegs;
        const float px = cx + cosf(a) * fovRadius;
        const float py = cy + sinf(a) * fovRadius;
        if (i == 0) CGPathMoveToPoint(path, NULL, px, py);
        else        CGPathAddLineToPoint(path, NULL, px, py);
    }
    CGPathCloseSubpath(path);
    return YES;
}

void RenderTotalEnemyCount(ESPAddTextCallback textCallback, void *callbackContext, int totalCount, float layerWidth) {
    if (!textCallback || totalCount < 0) return;
    NSString *countStr = [NSString stringWithFormat:@"%d", totalCount];

    // [FIX LAG]: Bỏ tính toán size font, cấp khung rộng và ép tự căn giữa (NO)
    textCallback(callbackContext, countStr, CGRectMake((layerWidth / 2.0f) - 50.0f, 45.0f, 100.0f, 35.0f), [UIColor redColor], 26.0f, NO);
}

// ==========================================
// HÀM ĐỌC ID SÚNG
// ==========================================
uint32_t CurrentWeaponID(uint64_t PawnObject) {
    if (!isVaildPtr(PawnObject)) return UINT32_MAX;

    uint32_t weaponID = ReadAddr<uint32_t>(PawnObject + 0x13C);
    if (weaponID == 0) return 1; // Fallback về 1 (Tay không)

    return weaponID;
}

// ==========================================
// HÀM FALLBACK TÊN SÚNG
// ==========================================
NSString* WeaponNameForPlayerNS(uint64_t PawnObject) {
    uint32_t wid = CurrentWeaponID(PawnObject);
    if (wid == UINT32_MAX) return @"";

    switch(wid) {
        case 0:
        case 1:   return @"Tay không";
        case 2:   return @"M4A1";
        case 4:   return @"AWM";
        case 5:   return @"M1014";
        case 6:   return @"AK47";
        case 7:   return @"UMP";
        case 8:   return @"MP5";
        case 9:   return @"Desert Eagle";
        case 15:  return @"MP40";
        case 16:  return @"Chảo";
        case 21:  return @"Kar98k";
        case 28:  return @"XM8";
        case 30:  return @"M60";
        case 41:  return @"M1887";
        case 45:  return @"M82B";
        case 48:  return @"Woodpecker";
        case 50:  return @"MAG-7";
        case 1204:return @"Bom Keo";
        default:  return [NSString stringWithFormat:@"Súng %d", wid];
    }
}

// ============================================================
// CORE RENDER — dùng cho fast path (RenderESPForPawnEx). Nhận sẵn head/hip/bot/knocked
// từ caller để fast path khỏi đọc lại memory (tránh double reads
// trong trận đông người). Bones/chân vẫn được đọc từ PawnObject.
// ============================================================
static void ESPRenderPawnCore(
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
) {
    if (dis > 400.0f || !buffers || !matrix || !PawnObject || dis < 1.0f) return;
    if (headX == 0.0f && headY == 0.0f && headZ == 0.0f) return;

    int MaxHP = get_MaxHP(PawnObject);
    if (MaxHP <= 0 || MaxHP > 2000) MaxHP = 200;

    const bool isKnocked = (isKnockedFlag != 0);
    const bool isBot = (isBotFlag != 0);
    NSString *Name = GetNickName(PawnObject);
    if (!Name || Name.length == 0) Name = isBot ? @"BOT" : @"Player";

    Vector3 HeadPos; HeadPos.x = headX; HeadPos.y = headY; HeadPos.z = headZ;
    Vector3 HipPos;  HipPos.x = hipX;  HipPos.y = hipY;  HipPos.z = hipZ;
    Vector3 RightToePos = getPositionExt(getRightToeNode(PawnObject));
    Vector3 LeftToePos  = getPositionExt(getLeftAnkle(PawnObject));

    if (fabsf(RightToePos.x) < 0.1f && fabsf(RightToePos.y) < 0.1f && fabsf(RightToePos.z) < 0.1f) {
        RightToePos = HeadPos;
        RightToePos.y -= 1.65f;
    }
    if (fabsf(LeftToePos.x) < 0.1f && fabsf(LeftToePos.y) < 0.1f && fabsf(LeftToePos.z) < 0.1f) {
        LeftToePos = RightToePos;
    }

    float worldHeight = fabsf(HeadPos.y - RightToePos.y);

    Vector3 L_Ankle      = getPositionExt(getLeftAnkle(PawnObject));
    Vector3 R_Ankle      = getPositionExt(getRightAnkle(PawnObject));
    Vector3 L_ForeArm    = getPositionExt(getLeftElbow(PawnObject));
    Vector3 R_ForeArm    = getPositionExt(getRightElbow(PawnObject));
    Vector3 L_Hand       = getPositionExt(getLeftHand(PawnObject));
    Vector3 R_Hand       = getPositionExt(getRightHand(PawnObject));

    Vector3 HeadTop = HeadPos; HeadTop.y += 0.2f;
    Vector3 w2sHead    = WorldToScreenLayer(HeadTop, matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
    Vector3 w2sToe     = WorldToScreenLayer(RightToePos, matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
    Vector3 w2sLeftToe = WorldToScreenLayer(LeftToePos, matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
    Vector3 w2sHip     = WorldToScreenLayer(HipPos, matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);

    if (w2sHead.z < 0.001f) return;
    const float margin = layerWidth * 0.6f;
    if (w2sHead.x < -margin || w2sHead.x > layerWidth + margin || w2sHead.y < -margin || w2sHead.y > layerHeight + margin) return;

    // ==========================================
    // THUẬT TOÁN BOX CHUẨN XÁC
    // ==========================================
    float top = w2sHead.y;
    // Chân nào chạm đất sâu nhất thì lấy chân đó làm đáy Box
    float bottom = fmaxf(w2sToe.y, w2sLeftToe.y);
    if (top > bottom) { float temp = top; top = bottom; bottom = temp; }

    float screenRealHeight = bottom - top;

    Vector3 fakeBasePos = HeadPos;
    fakeBasePos.y -= 1.65f;
    Vector3 w2sFakeBase = WorldToScreenLayer(fakeBasePos, matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
    float stdHeight = fabsf(w2sHead.y - w2sFakeBase.y);

    float boxHeight, boxWidth, x, y;

    if (isKnocked || CurHP <= 0 || worldHeight < 0.7f) {
        // GỤC / CHẾT / NẰM MÓC
        boxHeight = stdHeight * 0.35f;
        boxWidth  = stdHeight * 0.45f;
        x = w2sHip.x - boxWidth * 0.5f;
        y = w2sHip.y - boxHeight * 0.5f;
    } else if (worldHeight < 1.35f) {
        // NGỒI: Box lùn theo thực tế nhưng giữ nguyên bề ngang của Đứng
        boxHeight = screenRealHeight;
        boxWidth  = stdHeight * 0.45f;
        x = w2sHead.x - boxWidth * 0.5f;
        y = top;
    } else {
        // ĐỨNG / CHẠY / NHẢY: Box bao trọn 100%
        boxHeight = screenRealHeight;
        boxWidth  = boxHeight * 0.45f;
        x = w2sHead.x - boxWidth * 0.5f;
        y = top;
    }

    if (boxHeight < 6.0f) boxHeight = 6.0f;
    if (boxWidth < 4.0f) boxWidth = 4.0f;

    CGFloat dynFontSize = fmaxf(4.5f, fminf(10.0f, 350.0f / fmaxf(dis, 1.0f)));
    float centerX = x + boxWidth * 0.5f;

    // ---------------------------------------------------------
    // WEAPON
    // ---------------------------------------------------------
    if (isWeapon) {
        float wCX = centerX + 8.5f;
        float wTY = y - 20.0f;
        uint32_t wid = CurrentWeaponID(PawnObject);

        UIImage *wimg = (wid != UINT32_MAX && gWeaponTextures) ? gWeaponTextures[@(wid)] : nil;
        const float wIconH = 14.0f;

        if (wimg && imageCallback) {
            float wScl = wIconH / wimg.size.height;
            float wIconW = wimg.size.width * wScl;
            imageCallback(callbackContext, wimg, CGRectMake(wCX - wIconW/2, wTY - wIconH - 2, wIconW, wIconH));
        } else if (textCallback) {
            NSString *wname = WeaponNameForPlayerNS(PawnObject);
            if (wname && wname.length > 0) {
                // [FIX LAG]: Cấp khung cố định và căn giữa bằng NO
                textCallback(callbackContext, wname, CGRectMake(wCX - 50.0f, wTY - wIconH - 2, 100.0f, wIconH), [UIColor yellowColor], 6.5f, NO);
            }
        }
    }

    // ---------------------------------------------------------
    // LINE
    // ---------------------------------------------------------
    if (isLine) {
        CGPoint lineStart = CGPointMake(layerWidth / 2.0f, 35.0f);
        CGPoint boxTopCenter = CGPointMake(centerX, y);

        if (isKnocked) { ESPAddLine(buffers->snaplineKnockedPath, lineStart, boxTopCenter); buffers->snaplineKnockedDirty = true; }
        else if (isBot) { ESPAddLine(buffers->snaplineBotPath, lineStart, boxTopCenter); buffers->snaplineBotDirty = true; }
        else { ESPAddLine(buffers->snaplinePath, lineStart, boxTopCenter); buffers->snaplineDirty = true; }
    }

    // ---------------------------------------------------------
    // BOX
    // ---------------------------------------------------------
    if (isBox) {
        CGRect boxRect = CGRectMake(x, y, boxWidth, boxHeight);
        if (isKnocked) { CGPathAddRect(buffers->boxKnockedPath, NULL, boxRect); buffers->boxKnockedDirty = true; }
        else if (isBot) { CGPathAddRect(buffers->boxBotPath, NULL, boxRect); buffers->boxBotDirty = true; }
        else { CGPathAddRect(buffers->boxPath, NULL, boxRect); buffers->boxDirty = true; }
    }

    // ---------------------------------------------------------
    // NAME
    // ---------------------------------------------------------
    if (isName && textCallback) {
        NSString *dispName = (isEspBot && isBot) ? NSSENCRYPT("BOT") : Name;
        if (dispName.length > 0) {
            // [FIX LAG]: Xóa sizeWithAttributes, căn giữa bằng cờ NO
            textCallback(callbackContext, dispName, CGRectMake(centerX - 100.0f, y - dynFontSize - 6.0f, 200.0f, dynFontSize + 4.0f), [UIColor yellowColor], dynFontSize, NO);
        }
    }

    // ---------------------------------------------------------
    // DISTANCE
    // ---------------------------------------------------------
    if (isDis && textCallback) {
        NSString *distString = [NSString stringWithFormat:NSSENCRYPT("[%dM]"), (int)dis];
        // [FIX LAG]: Xóa sizeWithAttributes, căn giữa bằng cờ NO
        textCallback(callbackContext, distString, CGRectMake(centerX - 100.0f, y + boxHeight + 2.0f, 200.0f, dynFontSize + 4.0f), [UIColor whiteColor], dynFontSize, NO);
    }

    // ---------------------------------------------------------
    // THANH MÁU
    // ---------------------------------------------------------
    if (isHealth) {
        float healthRatio = Clamp01f((float)CurHP / (float)fmaxf(MaxHP, 1.0f));
        const CGFloat barWidth = 2.0f;

        CGFloat barX = x - barWidth - 1.0f;
        CGFloat barHeight = boxHeight;
        CGFloat filledTop = y + barHeight - (barHeight * healthRatio);

        CGRect fillRect = CGRectMake(barX, filledTop, barWidth, barHeight * healthRatio);
        if (CurHP >= 150) {
            CGPathAddRect(buffers->hpFillGreenPath, NULL, fillRect);
            buffers->hpFillGreenDirty = true;
        } else if (CurHP >= 75) {
            CGPathAddRect(buffers->hpFillOrangePath, NULL, fillRect);
            buffers->hpFillOrangeDirty = true;
        } else if (CurHP > 0) {
            CGPathAddRect(buffers->hpFillRedPath, NULL, fillRect);
            buffers->hpFillRedDirty = true;
        }
    }
}

// ==========================================
// HÀM VẼ ESP — FAST PATH
// Caller (updateFrame) đã đọc sẵn head/hip/bot/knocked trong snapshot
// (tránh double memory reads khi trận đông người)
// ==========================================
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
) {
    ESPRenderPawnCore(buffers, textCallback, imageCallback, callbackContext,
                      PawnObject, CurHP, dis, matrix,
                      layerWidth, layerHeight, matrixVpWidth, matrixVpHeight,
                      headX, headY, headZ,
                      hipX, hipY, hipZ,
                      isBotFlag, isKnockedFlag);
}

#ifdef __cplusplus
}
#endif
