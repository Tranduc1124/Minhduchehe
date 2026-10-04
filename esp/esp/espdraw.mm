#import "esp.h"
#import "GameLogic.h"
#import "mahoa.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
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

// Snapline rays go through ESPAddFanRay in esp.h, not a per-player subpath
// helper like the circle and rect ones below. The reasoning, including why
// batching them as rectangles was tried and did not work, is written there
// because it is the kind of thing that gets "fixed" back without being read.

static inline void ESPAddCircle(CGMutablePathRef path, CGPoint center, CGFloat radius) {
    if (!path) return;
    CGRect rect = CGRectMake(center.x - radius, center.y - radius, radius * 2.0f, radius * 2.0f);
    CGPathAddEllipseInRect(path, NULL, rect);
}

// ==========================================
// TÊN NGƯỜI CHƠI → GEOMETRY
// ==========================================
// The glyph outlines for a string, appended to dst. Every character becomes its
// own set of subpaths inside the one path, so the whole frame's worth of nicknames
// is a single CAShapeLayer filled once.
//
// Why not a CATextLayer: the ESP host window is created at alpha 0 and never
// raised (StartESPHost in esp/hud/DirectOverlay.mm), so nothing drawn inside this
// process is ever seen. The only thing that reaches the screen is a CGPath handed
// to SpringBoard by SBRemotePushESPFrame, so the name has to be geometry. See the
// name plate section in ESPRenderPawnCore for where the strings come from.
//
// Two things this gets wrong if they are done the obvious way, both of which look
// fine until they do not:
//
// 1. Y axis. Everything else in this file is UIKit: WorldToScreenLayer returns y
//    growing downwards (UnityMath.mm subtracts the projected y from the middle of
//    the viewport), the box's top is the smaller of the head and toe y, and the
//    health bar is at y - barGap, that is, above. CoreText hands back outlines in
//    font space, y growing upwards from the baseline. Placing one into the other
//    unchanged draws every glyph the right way up in a space that runs the other
//    way, which reads as mirrored along the baseline. So one scale of -1 on y and
//    then the translation, which is what CGAffineTransformMake(1, 0, 0, -1, x, y)
//    does. sb_text_glyphs in remote/SpringBoardOverlay.m does the same thing for
//    the counter, and that one is known to draw right way up on the device.
//
// 2. Joining the glyphs. CGPathAddPath per glyph is not tidiness. Each outline is
//    its own closed subpaths, and dropping the moveTo to run the characters
//    together as one polyline leaves zero area between one letter and the next.
//    A filled layer draws zero area as nothing, so on this layer that shortcut
//    would look perfect; on any stroked layer the same path is a cable strung from
//    the last point of one character to the first of the next. This layer is
//    filled, so the bug would sit here looking right until somebody stroked it.
//
// The font is the counter's, resolved by name in esp.mm, so the digits in the
// corner and the nicknames over the boxes are one typeface and not two.
//
// Frame semantics match addText:, which passes kCAAlignmentCenter for every ESP
// label: centred horizontally, and vertically by centring the font's ascent and
// descent in the frame. That is the baseline sb_text_glyphs derives for the
// counter, and it is why the text does not jump when the path replaces the
// CATextLayer it used to be drawn by.
static void ESPAppendTextPath(CGMutablePathRef dst, NSString *s, CGRect frame, CGFloat size) {
    if (!dst || !s.length || size <= 0.5f) return;
    if (frame.size.width <= 0.0 || frame.size.height <= 0.0) return;

    // One CTFont per half-point size, kept for the life of the process.
    //
    // This used to call ESPNameTextCTFont on every string, every player, every
    // frame, and that is CTFontCreateWithName every time: a font database lookup
    // plus a font object built from scratch, then released again straight after.
    // At thirty players and two lines each that is three thousand six hundred
    // creations a second, which is where the two second lag came from. The names
    // were not stale, they were simply being computed three seconds behind the
    // boxes, which are the same frame and do not pay this.
    //
    // dynFontSize runs from 4.5 to 10, so half-point steps put the whole range in
    // a dozen entries. Keyed on the rounded value, so a size that lands on the
    // same half point reuses the font and only the metrics differ by a fraction
    // of a point, which is not visible at these sizes.
    CTFontRef font = NULL;
    {
        static CTFontRef s_font[24] = {NULL};
        static CGFloat s_size[24] = {0};
        // Quarter-point buckets, offset by 15 so the smallest size that actually
        // occurs lands on slot 0.
        //
        // The first version used half-point steps offset by 8, and that offset
        // came from dynFontSize's 4.5 floor rather than from nameSize's. The
        // names are set at 0.86 of dynFontSize, so the real floor is
        // 4.5 * 0.86 = 3.87, and (int)(3.87 * 2) - 8 is -1. Every target at
        // range, which is exactly where dynFontSize sits at its floor, fell out
        // of the table and back to calling CTFontCreateWithName for every string
        // on every frame. The cache did nothing at range, which is the range it
        // was written for.
        const int slot = (int)(size * 4.0) - 15;   // 3.75 -> 0, 8.75 -> 20
        if (slot >= 0 && slot < 24) {
            // fabs and not fabsf: CGFloat is a double on arm64, so the float
            // overload would truncate the argument. The build turns that into an
            // error under -Werror.
            if (s_font[slot] && fabs(s_size[slot] - size) < 0.2) {
                font = s_font[slot];
            } else {
                CTFontRef made = ESPNameTextCTFont(size);
                if (made) {
                    if (s_font[slot]) CFRelease(s_font[slot]);
                    s_font[slot] = made;
                    s_size[slot] = size;
                    font = made;
                }
            }
        } else {
            font = ESPNameTextCTFont(size);
        }
    }
    if (!font) return;

    // Sized for a plate line: a 16 character nickname plus the "[123M]" tag, with
    // room over. Longer input is clipped rather than grown for, because the stack
    // arrays here are the reason this costs nothing per character.
    enum { kMaxGlyphs = 48 };
    if (s.length > (NSUInteger)kMaxGlyphs) s = [s substringToIndex:(NSUInteger)kMaxGlyphs];
    const CFIndex n = (CFIndex)s.length;
    if (n <= 0) return;   // font is cached, not owned here

    UniChar ch[kMaxGlyphs];
    [s getCharacters:ch range:NSMakeRange(0, (NSUInteger)n)];

    CGGlyph glyphs[kMaxGlyphs];
    CGSize advances[kMaxGlyphs];
    if (!CTFontGetGlyphsForCharacters(font, ch, glyphs, n)) {
        // The bulk call is all or nothing: a single character the font has no
        // glyph for, a CJK nickname or an emoji the icon strip did not catch,
        // makes it return false and takes the whole line with it. One at a time
        // leaves the unmapped characters at glyph 0, which is what a missing
        // character renders as everywhere else, and the ASCII part of the name
        // still shows.
        for (CFIndex i = 0; i < n; i++) {
            CGGlyph g = 0;
            CTFontGetGlyphsForCharacters(font, ch + i, &g, 1);
            glyphs[i] = g;
        }
    }

    // The advances come back with the summed width, so there is no second pass to
    // measure the string with. kCTFontOrientationHorizontal is read out of
    // CTFont.h rather than assumed, the same reason sb_text_glyphs reads it out:
    // the obvious argument order is not the real one.
    const double totalW = CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal,
                                                     glyphs, advances, n);
    if (totalW <= 0.0) return;   // font is cached, not owned here

    const double ascent  = CTFontGetAscent(font);
    const double descent = CTFontGetDescent(font);
    const double dx = frame.origin.x + (frame.size.width - totalW) * 0.5;
    const double dy = frame.origin.y + (frame.size.height + ascent + descent) * 0.5 - descent;

    double penX = dx;
    for (CFIndex i = 0; i < n; i++) {
        if (glyphs[i] != 0) {
            CGAffineTransform m = CGAffineTransformMake(1.0, 0.0, 0.0, -1.0, penX, dy);
            // CTFontCreatePathForGlyph, not the Get variant. There is no
            // CTFontGetPathForGlyph in the iOS SDK — CTFont.h only declares the
            // Create form, and the Get form is a macOS one — so the one named in
            // the brief does not exist to call and this is the function that
            // does. It hands back a new path per glyph, hence the release; the
            // borrowed-and-cached form sb_text_glyphs wanted is simply not there
            // to have.
            CGPathRef g = CTFontCreatePathForGlyph(font, glyphs[i], &m);
            if (g) { CGPathAddPath(dst, NULL, g); CGPathRelease(g); }
        }
        penX += advances[i].width;
    }
    // no CFRelease: the font is owned by the cache above and shared across frames
}

// drawRing, not aimbotEnabled. The flag used to be the aimbot's, and the
// argument name still said so after the caller stopped passing it, which is how
// a reader ends up believing the ring belongs to the aimbot. It is a switch in
// its own right now. fovRadius is a screen radius in points, nothing to do with
// aim range.
BOOL RenderFOVCirclePath(
    CGMutablePathRef path,
    float viewWidth,
    float viewHeight,
    BOOL drawRing,
    float fovRadius
) {
    if (!path || !drawRing || fovRadius <= 0) return NO;
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
        case 1:   return @"Bare Hands";
        case 2:   return @"M4A1";
        case 4:   return @"AWM";
        case 5:   return @"M1014";
        case 6:   return @"AK47";
        case 7:   return @"UMP";
        case 8:   return @"MP5";
        case 9:   return @"Desert Eagle";
        case 15:  return @"MP40";
        case 16:  return @"Pan";
        case 21:  return @"Kar98k";
        case 28:  return @"XM8";
        case 30:  return @"M60";
        case 41:  return @"M1887";
        case 45:  return @"M82B";
        case 48:  return @"Woodpecker";
        case 50:  return @"MAG-7";
        case 1204:return @"Grenade";
        default:  return [NSString stringWithFormat:@"Gun %d", wid];
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
    // Only read the nickname if something is going to show it.
    //
    // GetNickName is not cheap. It reads a pointer, reads 32 bytes of the name out
    // of the game, allocates an NSString, then strips the icon characters by
    // enumerating composed character sequences over the whole string and trimming
    // it. Three allocations and a Unicode walk, per player, per frame, for a
    // string that the isName gate below discards.
    //
    // The gate is at the NAME section, well below this line, so the read and the
    // strip were both being paid for with the name display off. Both conditions
    // are checked here: isName covers the real name and isEspBot covers the BOT
    // label, which is the only other place Name reaches an output.
    NSString *Name = nil;
    if (isName || isEspBot) Name = GetNickName(PawnObject);
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

    // The health bar's height and its gap off the top of the box, defined here
    // rather than inside the health bar block because two things have to agree on
    // them: the bar itself, and the name plate, which has to sit on exactly the
    // line the bar's top edge is on so the two do not overlap. A literal written
    // twice is a value that gets changed once.
    const CGFloat barH   = 0.75f;      // bằng nét vẽ, hai cạnh dính khít
    const CGFloat barGap = 3.0f;       // đáy thanh lên khỏi đỉnh box

    // Chiều dài thanh máu ở đầy máu, và chiều cao cố định của card tên.
    //
    // Cả hai đặt ở đây vì ba chỗ phải agree: thanh máu dùng nó làm chiều dài,
    // card tên dùng chính chiều dài đó làm bề rộng, và bề cao card phải giữ
    // đúng con số này. Một số viết ở ba nơi là một số sẽ được sửa một lần.
    //
    // barFullLen dài hơn boxWidth một chút. Trước đây nó bằng đúng boxWidth, tức
    // thanh dài y hệt cạnh box và đọc ra như một đường viền dưới thay vì một
    // thanh. Không có nền sau thanh nên kéo dài ra không vỡ gì: chỉ là rect xanh
    // dài thêm.
    const CGFloat barFullLen = boxWidth * 1.18f;

    // Bề cao card tên: CỐ ĐỊNH, không theo khoảng cách.
    //
    // Trước đây plateH = dynFontSize * 0.86 + 4, và dynFontSize là
    // clamp(350/dis, 4.5, 10) — tức bề cao card tăng lên khi đến gần và nhỏ đi
    // khi lùi xa. Đó là điều không mong muốn: cùng một cái tên thì card phải
    // luôn cao bằng nhau, người đọc không phải nhìn xem thẻ nào to thẻ nào nhỏ.
    // Sửa ở đây chứ không sửa chỗ dùng, vì còn hai chỗ nữa phải theo.
    const CGFloat kPlateHeight = 11.0f;

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

        if (isKnocked) { ESPAddFanRay(buffers->snaplineKnockedPath, lineStart, boxTopCenter, &buffers->snaplineKnockedFanStarted); buffers->snaplineKnockedDirty = true; }
        else if (isBot) { ESPAddFanRay(buffers->snaplineBotPath, lineStart, boxTopCenter, &buffers->snaplineBotFanStarted); buffers->snaplineBotDirty = true; }
        else { ESPAddFanRay(buffers->snaplinePath, lineStart, boxTopCenter, &buffers->snaplineFanStarted); buffers->snaplineDirty = true; }
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
    // NAME PLATE — tên + "[Xm]", chữ trắng trên nền xám.
    //
    // Một plate cho mỗi người, hai path cho cả khung hình: một path chữ cho
    // tất cả tên, một path nền cho tất cả plate. Mỗi path đi qua đúng một
    // lần publish, và số lần đó không nhân với số người — cùng lý do
    // snapline gộp thành một polyline.
    //
    // Vì sao là geometry chứ không phải CATextLayer: cửa sổ host chạy ở
    // alpha 0 (StartESPHost trong esp/hud/DirectOverlay.mm) nên không thứ gì
    // vẽ trong process này được nhìn thấy. Thứ duy nhất ra màn hình là
    // CGPath đưa sang SpringBoard, nên tên phải là path. Cách dựng nét chữ:
    // ESPAppendTextPath ở trên.
    //
    // addText: vẫn được gọi. Nó là lớp trong app nên vô hình, nhưng nó là
    // lớp mà CATextLayer của app từng dùng, và hai cái không vẽ lên cùng
    // một bề mặt: path chỉ đi sang SpringBoard. Bỏ đi là một thay đổi hành
    // vi không ai yêu cầu, nên nó ở lại.
    // ---------------------------------------------------------
    NSString *plateName = nil;
    if (isName) {
        plateName = (isEspBot && isBot) ? NSSENCRYPT("BOT") : Name;
        if (plateName.length == 0) plateName = nil;
    }
    NSString *plateDis = nil;
    if (isDis) {
        plateDis = [NSString stringWithFormat:NSSENCRYPT("[%dM]"), (int)dis];
        if (plateDis.length == 0) plateDis = nil;
    }

    if (plateName && textCallback) {
        // [FIX LAG]: Xóa sizeWithAttributes, căn giữa bằng cờ NO
        textCallback(callbackContext, plateName, CGRectMake(centerX - 100.0f, y - dynFontSize - 6.0f, 200.0f, dynFontSize + 4.0f), [UIColor yellowColor], dynFontSize, NO);
    }
    if (plateDis && textCallback) {
        // [FIX LAG]: Xóa sizeWithAttributes, căn giữa bằng cờ NO
        textCallback(callbackContext, plateDis, CGRectMake(centerX - 100.0f, y + boxHeight + 2.0f, 200.0f, dynFontSize + 4.0f), [UIColor whiteColor], dynFontSize, NO);
    }

    if (plateName || plateDis) {
        // The name and the distance are set a little under the ESP's own type
        // size. dynFontSize also sizes the health bar and the box, so changing
        // it there would move everything for a request that was only about the
        // text. 0.86 is small enough to read as secondary and large enough to
        // stay legible at the far end where dynFontSize is already at its 4.5
        // floor and the whole tag is three characters.
        // Clamped to fit the fixed card. Without the clamp a close target gets
        // nameSize 8.6 against an 11pt card and the glyphs run out through the
        // bottom, which is the overflow the fixed height would otherwise trade in.
        const CGFloat nameSize = fminf(dynFontSize * 0.86f, kPlateHeight - 4.0f);
        const CGFloat lineH = kPlateHeight;

        // The plate covers the NAME only. The distance is not on it and does not
        // have a background at all, because the distance belongs under the feet
        // and the feet are below the box, so a plate that held both would either
        // have to stretch across the box or sit nowhere useful.
        const CGFloat plateH = plateName ? lineH : 0.0f;

        // The name plate's bottom edge is exactly the top edge of the health bar,
        // which is y - barGap - barH. That is the answer to "sit on the top edge
        // of the box without covering the health bar": barGap + barH is precisely
        // the part the bar already occupies, so leaving it clear is not a gap and
        // not an overlap. Both places read the same barGap and barH, so the
        // number cannot drift away from the bar.
        const CGFloat plateBottom = y - barGap - barH;

        // Width is barFullLen -- the health bar's full length, not its health-
        // scaled fill and not boxWidth -- so the card sits exactly as wide as the
        // bar it belongs to. Anchored on the bar's left edge (x) for the same
        // reason, and grown symmetrically so the bar and the card share a centre.
        //
        // The charsW floor stays. It is not a contradiction of "as wide as the
        // bar": at range the bar is a few points long and a name cannot be drawn
        // inside that at any point size, so the card grows only when the name
        // genuinely does not fit and never shrinks below the bar. Estimated from
        // the character count rather than a measured advance, because measuring
        // means laying the string out first and the card has to exist before the
        // glyphs go in.
        const CGFloat charsW = (CGFloat)plateName.length * nameSize * 0.62f + 8.0f;
        const CGFloat plateW = (barFullLen > charsW) ? barFullLen : charsW;
        const CGRect plate = CGRectMake(x - (plateW - barFullLen) * 0.5f,
                                        plateBottom - plateH, plateW, plateH);

        // CGPathAddRect, not CGPathAddEllipseInRect: four distinct corners is
        // what the SpringBoard decoder batches into the shared CGPathAddRects,
        // so every plate in a frame is still one call.
        //
        // Only when there is a name. The plate is the name's background, so
        // switching the name pref off has to take the background with it, and a
        // plate drawn for a player who has no name would be a grey bar over
        // nothing.
        if (plateName && buffers->nameBgPath) {
            CGPathAddRect(buffers->nameBgPath, NULL, plate);
        }

        // The name sits inside its plate. The distance does not: it goes under
        // the feet, y + boxHeight, clear of the box outline, and it has no
        // background because there is no plate there. Same font, same size and
        // the same centring as the CATextLayer path above, so neither line jumps
        // position when the other is switched off.
        if (plateName) {
            ESPAppendTextPath(buffers->nameTextPath, plateName,
                              CGRectMake(plate.origin.x, plate.origin.y,
                                         plate.size.width, lineH), nameSize);
        }
        if (plateDis) {
            const CGFloat disW = (CGFloat)plateDis.length * nameSize * 0.62f + 8.0f;
            ESPAppendTextPath(buffers->nameTextPath, plateDis,
                              CGRectMake(centerX - disW * 0.5f, y + boxHeight + 2.0f,
                                         disW, lineH), nameSize);
        }
        buffers->nameTextDirty = true;
    }

    // ---------------------------------------------------------
    // THANH MÁU — ngang, trên đỉnh đầu, MỘT thanh mảnh.
    //
    // Một hình chữ nhật duy nhất, cao đúng bằng nét vẽ. Cần hiểu vì sao cao
    // đúng bằng nét: SpringBoard chỉ có nét, không có tô, nên nét 0.75 tô đều
    // lên cả bốn cạnh của hình chữ nhật. Một hình chữ nhật cao h chắn cạnh
    // trên che từ -0.375 tới +0.375 và cạnh dưới che từ h-0.375 tới h+0.375,
    // nên giữa lại hở h-1.5pt. h = 0.75 là giá trị duy nhất hai cạnh chồng
    // khít và ra một dải đặc, dày 1.5pt. Mọi h lớn hơn đều ra khung rỗng, và
    // đó là lỗi đo được bằng cách chụp màn hình chứ không phải cảm giác.
    //
    // Trước đây ở đây là ba hình chữ nhật 0.75 chồng nhau để dải đặc dày 3pt,
    // vì lúc đó 1.5pt được cho là quá mảnh để đọc trên một box cao 60px. Người
    // dùng nói nó to quá và chỉ muốn một thanh ngang. Ba rect đó còn tốn ba
    // cạnh vẽ cho một dải, tức là nó đậm lên rồi lại nhòe ở giữa, đúng cái
    // mà câu "to quá" là thanh quay lại đúng một thanh.
    //
    // Hình chữ nhật nên decoder ở SpringBoard nhận ra bốn góc và gom vào
    // CGPathAddRects chung, tức vẫn đúng một lệnh cho toàn bộ thanh máu
    // trên màn hình, không tăng theo số người.
    //
    // barGap là khoảng hở giữa đáy thanh và đỉnh box. Nó là 3 chứ không phải
    // 1.5: ở 1.5 thì dải đặc dính sát mép trên của box và đọc ra như một
    // đường viền dày thêm chứ không phải một thanh. Đây là khoảng cách trông
    // đẹp nhất trong ba giá trị thử; không phải thanh to thêm, chỉ dời lên.
    //
    // barW là chiều dài theo lượng máu nên nó thay đổi mỗi khung, và nó là
    // thứ duy nhất ở đây co lại được: nền xám của tên cố ý dùng barFullLen —
    // chiều dài ĐẦY của thanh — chứ không dùng barW, để card không co theo
    // lượng máu. Xem phần NAME PLATE.
    // ---------------------------------------------------------
    if (isHealth) {
        float healthRatio = Clamp01f((float)CurHP / (float)fmaxf(MaxHP, 1.0f));
        const CGFloat barW = barFullLen * healthRatio;
        const CGFloat barTop = y - barGap - barH;

        CGPathAddRect(buffers->hpFillGreenPath, NULL,
                      CGRectMake(x, barTop, barW, barH));
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
