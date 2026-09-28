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
    textCallback(callbackContext, countStr, ESPTextRoleCounter, CGRectMake((layerWidth / 2.0f) - 50.0f, 45.0f, 100.0f, 35.0f), [UIColor redColor], 26.0f, NO);
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
    // BONE — bỏ hẳn.
    //
    // Một người là 13 đoạn xương, mỗi đoạn là một CGPathAddLines riêng vì
    // các đoạn không liền nhau. Đó là 13 remote call cho mỗi người, và log
    // 13:32 ghi rõ sub=69 limb=56 calls=67: gần như toàn bộ khung hình là
    // xương. Bỏ xương không chỉ cho đúng ngoại hình, nó cắt số call mà
    // không thay đổi bất cứ thứ gì khác.
    //
    // Sáu lần đọc bộ nhớ lấy khớp tay chân cũng đi cùng, vì chúng chỉ tồn
    // tại cho hình xương. Không có chúng thì khung hình đọc ít đi sáu địa
    // chỉ mỗi người mỗi lần vẽ, ở một vòng lặp đang chạy 30 lần giây.
    // ---------------------------------------------------------

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
                textCallback(callbackContext, wname, ESPTextRoleWeapon, CGRectMake(wCX - 50.0f, wTY - wIconH - 2, 100.0f, wIconH), [UIColor yellowColor], 6.5f, NO);
            }
        }
    }

    // ---------------------------------------------------------
    // LINE
    // ---------------------------------------------------------
    if (isLine) {
        // The line starts below the red counter, not through the middle of it.
        //
        // The counter is a real UILabel in SpringBoard, 34pt tall and 25pt from
        // the top of the landscape view, and this used to start at 35. The device
        // screenshot showed the two overlapping, the line leaving from the middle
        // of the number. 25 + 34 is the bottom of the label, and four points of
        // clearance puts the line clear of it.
        //
        // SB_COUNT_TOP and SB_COUNT_H are the overlay's numbers and live in
        // SpringBoardOverlay.m. They are repeated here rather than shared because
        // the two files do not include each other. If the counter ever moves, this
        // has to move with it.
        const float kCounterBottom = 25.0f + 34.0f;
        CGPoint lineStart = CGPointMake(layerWidth / 2.0f, kCounterBottom + 4.0f);
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
    if (isName) {
        NSString *dispName = (isEspBot && isBot) ? NSSENCRYPT("BOT") : Name;
        if (dispName.length > 0) {
            // The card is a filled rectangle drawn here, not a UILabel's
            // background, and the two have to agree exactly or the text sits off
            // the edge of its own card.
            //
            // It cannot stay a label background. A UILabel's background is the
            // label's bounds, and the name is measured, so the bounds would have
            // to follow the text. More to the point a filled shape is the one
            // thing a CGPath cannot express: the path carries geometry and the
            // layer carries the paint, so a filled shape needs a layer whose fill
            // is set. That is one extra layer, and CGPathAddRects draws every
            // card in the frame in a single call however many there are.
            // One size, and the same font the overlay's label uses: the
            // SpringBoard label sets boldSystemFontOfSize:11, so measuring with
            // anything else makes the card and the text disagree.
            const CGFloat nameFS = 11.0f;
            const CGFloat padX = 6.0f;
            const CGFloat cardH = nameFS + 6.0f;
            const CGFloat cardTop = y - nameFS - 8.0f;

            UIFont *f = [UIFont boldSystemFontOfSize:nameFS];
            CGFloat nameW = 0.0f;
            if (f) {
                nameW = ceil([dispName sizeWithAttributes:@{NSFontAttributeName: f}].width);
            }
            if (nameW < 1.0f) nameW = nameFS * 4.0f;

            CGPathAddRect(buffers->cardPath, NULL,
                          CGRectMake(centerX - nameW * 0.5f - padX, cardTop,
                                     nameW + padX * 2.0f, cardH));
            buffers->cardDirty = true;

            if (textCallback) {
                textCallback(callbackContext, dispName, ESPTextRoleName,
                             CGRectMake(centerX - 100.0f, cardTop, 200.0f, cardH),
                             [UIColor whiteColor], nameFS, NO);
            }
        }
    }

    // ---------------------------------------------------------
    // DISTANCE
    // ---------------------------------------------------------
    // The distance label is not built. It came out as a wide grey banner across
    // the feet rather than a small figure, and a distance is also the one piece
    // of text that can be re-derived from the box the moment it is wanted back,
    // so it is held out of the per frame path until the card is right. The
    // in-app layer below the game still gets it, which is what it was drawn on
    // before the overlay mirror existed.
    (void)dis;

    // ---------------------------------------------------------
    // THANH MÁU — ngang, nằm trên đỉnh đầu, một màu.
    //
    // Trước đây là một thanh dọc 2pt bám bên trái box, chia ba đoạn màu
    // theo lượng máu. Cả ba điều đó sai với yêu cầu: nó dọc chứ không
    // ngang, nó không nằm trên đầu, và ba màu là ba layer riêng trong khi
    // SpringBoard chỉ có một CAShapeLayer nên tất cả đều bị gộp về một màu
    // viền duy nhất. Ba layer cho ba màu là ba lần present để rồi không
    // thấy màu nào cả.
    //
    // Nên còn một đường, một màu. Thanh là hình chữ nhật nên decoder ở
    // SpringBoard nhận ra bốn góc và gom vào CGPathAddRects, tức nó tốn
    // đúng một call bất kể có bao nhiêu người trên màn hình.
    //
    // Cao 2.5pt thì nó ra một khung rỗng, và đó là lỗi đo được chứ không phải
    // cảm giác. SpringBoard chỉ có nét vẽ, không có tô: nét 0.75 tô đều lên
    // cả bốn cạnh, nên một hình chữ nhật cao 2.5 có cạnh trên che từ -0.375
    // tới +0.375 và cạnh dưới che từ +2.125 tới +2.875, giữa lại hở 1.75pt.
    // Máy chụp màn hình cho thấy đúng cái khung rỗng đó.
    //
    // Muốn nó đặc thì chiều cao phải nhỏ hơn hoặc bằng nét vẽ, để hai cạnh
    // chồng lên nhau. Một hình chữ nhật cao đúng 0.75 cho dải đặc 1.5pt, quá
    // mảnh để đọc trên một box cao 60px. Nên khoẻ theo chiều dọc: ba hình
    // chữ nhật cao 0.75 chồng lên nhau, dải đặc 3pt, vẫn gom trong cùng một
    // lệnh CGPathAddRects, không tốn thêm call nào.
    // ---------------------------------------------------------
    if (isHealth) {
        float healthRatio = Clamp01f((float)CurHP / (float)fmaxf(MaxHP, 1.0f));
        const CGFloat barH = 0.75f;      // bằng nét vẽ, để hai cạnh dính nhau
        const CGFloat barGap = 1.5f;
        const CGFloat barW = boxWidth * healthRatio;
        const CGFloat barTop = y - barGap - 3.0f * barH;

        for (int seg = 0; seg < 3; seg++) {
            CGPathAddRect(buffers->hpFillGreenPath, NULL,
                          CGRectMake(x, barTop + seg * barH, barW, barH));
        }
        buffers->hpFillGreenDirty = true;
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
