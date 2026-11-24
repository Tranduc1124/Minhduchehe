#import "UnityMath.h"
#import "offset.h"
#import <QuartzCore/QuartzCore.h>
#include "TransformTraversal.h"
#include <cmath>
#include <unordered_map>

#pragma mark - Function Unity

Vector3 WorldToScreen(Vector3 obj, float *matrix, float screenX, float screenY) {
    Vector3 screen{};
    if (!matrix) return screen;

    float w = matrix[3] * obj.x + matrix[7] * obj.y + matrix[11] * obj.z + matrix[15];
    screen.z = w;
    if (w < 0.001f) {
        screen.x = -1;
        screen.y = -1;
        return screen;
    }

    screen.x = (screenX / 2) + (matrix[0] * obj.x + matrix[4] * obj.y + matrix[8]  * obj.z + matrix[12]) / w * (screenX / 2);
    screen.y = (screenY / 2) - (matrix[1] * obj.x + matrix[5] * obj.y + matrix[9]  * obj.z + matrix[13]) / w * (screenY / 2);

    return screen;
}

Vector3 WorldToScreenLayer(Vector3 obj, float *matrix, float vpW, float vpH, float layerW, float layerH) {
    if (vpW < 1.0f) {
        vpW = layerW;
    }
    if (vpH < 1.0f) {
        vpH = layerH;
    }
    Vector3 v = WorldToScreen(obj, matrix, vpW, vpH);
    if (vpW > 0.5f) {
        v.x *= layerW / vpW;
    }
    if (vpH > 0.5f) {
        v.y *= layerH / vpH;
    }
    return v;
}

static bool FinitePosition(const Vector3 &v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

static Vector3 ReadPosition(uint64_t transObj2) {
    Vector3 result{};
    if (!isVaildPtr((uintptr_t)transObj2)) return result;

    uint64_t transObj = ReadAddr<uint64_t>(transObj2 + kTransformInner);
    if (!isVaildPtr((uintptr_t)transObj)) return result;

    uint64_t matrix = ReadAddr<uint64_t>(transObj + kTransformMatrix);
    if (!isVaildPtr((uintptr_t)matrix)) return result;

    int32_t index = -1;
    if (!_read((long)(transObj + kTransformIndex), &index, sizeof(index)) ||
        index < 0 || index > TransformTraversal::MaxIndex) return result;

    uint64_t matrix_list = ReadAddr<uint64_t>(matrix + kMatrixList);
    if (!isVaildPtr((uintptr_t)matrix_list)) return result;
    uint64_t matrix_indices = ReadAddr<uint64_t>(matrix + kMatrixIndices);
    if (!isVaildPtr((uintptr_t)matrix_indices)) return result;

    if (!_read((long)(matrix_list + sizeof(TMatrix) * (size_t)index), &result, sizeof(result)) ||
        !FinitePosition(result)) return Vector3();
    auto readParent = [&](int child, int &parent) {
        return _read((long)(matrix_indices + sizeof(int) * (size_t)child), &parent, sizeof(parent));
    };
    auto applyParent = [&](int transformIndex) {
        TMatrix tMatrix{};
        if (!_read((long)(matrix_list + sizeof(TMatrix) * (size_t)transformIndex), &tMatrix, sizeof(tMatrix))) return false;

        float rotX = tMatrix.rotation.x;
        float rotY = tMatrix.rotation.y;
        float rotZ = tMatrix.rotation.z;
        float rotW = tMatrix.rotation.w;

        float scaleX = result.x * tMatrix.scale.x;
        float scaleY = result.y * tMatrix.scale.y;
        float scaleZ = result.z * tMatrix.scale.z;

        result.x = tMatrix.position.x + scaleX +
                    (scaleX * ((rotY * rotY * -2.0) - (rotZ * rotZ * 2.0))) +
                    (scaleY * ((rotW * rotZ * -2.0) - (rotY * rotX * -2.0))) +
                    (scaleZ * ((rotZ * rotX * 2.0) - (rotW * rotY * -2.0)));
        result.y = tMatrix.position.y + scaleY +
                    (scaleX * ((rotX * rotY * 2.0) - (rotW * rotZ * -2.0))) +
                    (scaleY * ((rotZ * rotZ * -2.0) - (rotX * rotX * 2.0))) +
                    (scaleZ * ((rotW * rotX * -2.0) - (rotZ * rotY * -2.0)));
        result.z = tMatrix.position.z + scaleZ +
                    (scaleX * ((rotW * rotY * -2.0) - (rotX * rotZ * -2.0))) +
                    (scaleY * ((rotY * rotZ * 2.0) - (rotW * rotX * -2.0))) +
                    (scaleZ * ((rotX * rotX * -2.0) - (rotY * rotY * 2.0)));

        return FinitePosition(result);
    };
    return TransformTraversal::Walk(index, readParent, applyParent) ? result : Vector3();
}

struct TransformCacheEntry { uint64_t key = 0, frame = 0; Vector3 position; };
static TransformCacheEntry positionCache[1024];
static uint64_t positionFrame = 0;

void BeginTransformFrame(void) { ++positionFrame; }

Vector3 getPositionExt(uint64_t transform) {
    if (!positionFrame) return ReadPosition(transform);
    auto &entry = positionCache[(transform >> 4) % 1024];
    if (entry.frame == positionFrame && entry.key == transform) return entry.position;
    Vector3 value = ReadPosition(transform);
    entry.key = transform;
    entry.frame = positionFrame;
    entry.position = value;
    return value;
}

static BOOL NickClusterIsIconOrEmoji(NSString *cluster) {
    if (cluster.length == 0) return YES;
    unichar h0 = [cluster characterAtIndex:0];
    if (h0 >= 0xD800 && h0 <= 0xDBFF)
        return YES;
    uint32_t u = (uint32_t)h0;
    if (u >= 0xE000 && u <= 0xF8FF)
        return YES;
    if (u >= 0x2300 && u <= 0x23FF)
        return YES;
    if (u >= 0x2600 && u <= 0x27BF)
        return YES;
    if (u == 0xFE0F || u == 0xFE0E)
        return YES;
    return NO;
}

static NSString *NickStringByStrippingIcons(NSString *s) {
    if (s.length == 0) return s;
    @try {
        NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
        [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            if (substring && !NickClusterIsIconOrEmoji(substring))
                [out appendString:substring];
        }];
        NSString *t = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return t.length ? t : @"";
    } @catch (id exception) {
        return @"Player";
    }
}

struct CachedPlayerNick {
    NSString *nick;
    CFTimeInterval expiresAt;
};
static std::unordered_map<uint64_t, CachedPlayerNick> gNickCache;

NSString *GetNickName(uint64_t PawnObject) {
    if (!isVaildPtr(PawnObject)) return @"";
    CFTimeInterval now = CACurrentMediaTime();
    auto it = gNickCache.find(PawnObject);
    if (it != gNickCache.end() && now < it->second.expiresAt && it->second.nick) {
        return it->second.nick;
    }
    if (gNickCache.size() > 256) {
        gNickCache.clear();
    }

    @try {
        uint64_t name = ReadAddr<uint64_t>(PawnObject + (uint64_t)kNickname);
        if (!isVaildPtr(name)) return @"";

        const size_t kMaxChars = 32;
        UTF16 buf16[kMaxChars];
        memset(buf16, 0, sizeof(buf16));
        if (!_read((long)(name + (uint64_t)kStringFirstChar), buf16, (int)(kMaxChars * sizeof(UTF16))))
            return @"";

        size_t len = 0;
        while (len < kMaxChars && buf16[len] != 0) len++;
        if (len == 0) return @"";
        NSString *s = [NSString stringWithCharacters:(const unichar *)buf16 length:len];
        if (!s) return @"";
        NSString *result = NickStringByStrippingIcons(s);
        gNickCache[PawnObject] = {result, now + 3.0};
        return result;
    } @catch (id exception) {
        return @"Player";
    }
}
