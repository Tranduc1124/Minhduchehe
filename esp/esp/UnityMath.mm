#import "UnityMath.h"
#import "offset.h"

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

Vector3 getPositionExt(uint64_t transObj2) {
    Vector3 result{};
    if (!isVaildPtr((uintptr_t)transObj2)) return result;

    uint64_t transObj = ReadAddr<uint64_t>(transObj2 + kTransformInner);
    if (!isVaildPtr((uintptr_t)transObj)) return result;

    uint64_t matrix = ReadAddr<uint64_t>(transObj + kTransformMatrix);
    if (!isVaildPtr((uintptr_t)matrix)) return result;

    uint64_t indexU = ReadAddr<uint64_t>(transObj + kTransformIndex);
    if (indexU > 8192) return result;
    size_t index = (size_t)indexU;

    uint64_t matrix_list = ReadAddr<uint64_t>(matrix + kMatrixList);
    if (!isVaildPtr((uintptr_t)matrix_list)) return result;
    uint64_t matrix_indices = ReadAddr<uint64_t>(matrix + kMatrixIndices);
    if (!isVaildPtr((uintptr_t)matrix_indices)) return result;

    result = ReadAddr<Vector3>(matrix_list + sizeof(TMatrix) * index);
    int transformIndex = ReadAddr<int>(matrix_indices + sizeof(int) * index);

    static const int kMaxTransformDepth = 64;
    for (int depth = 0; transformIndex >= 0 && depth < kMaxTransformDepth; depth++) {
        if (transformIndex > 8192) break;
        TMatrix tMatrix = ReadAddr<TMatrix>(matrix_list + sizeof(TMatrix) * (size_t)transformIndex);

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

        transformIndex = ReadAddr<int>(matrix_indices + sizeof(int) * (size_t)transformIndex);
    }

    return result;
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
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        if (!NickClusterIsIconOrEmoji(substring))
            [out appendString:substring];
    }];
    NSString *t = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t.length ? t : @"";
}

NSString *GetNickName(uint64_t PawnObject) {
    if (!isVaildPtr(PawnObject)) return @"";
    uint64_t name = ReadAddr<uint64_t>(PawnObject + (uint64_t)kNickname);
    if (!isVaildPtr(name)) return @"";

    const size_t kMaxChars = 16;
    UTF16 buf16[kMaxChars];
    memset(buf16, 0, sizeof(buf16));
    if (!_read((long)(name + (uint64_t)kStringFirstChar), buf16, (int)(kMaxChars * sizeof(UTF16))))
        return @"";

    size_t len = 0;
    while (len < kMaxChars && buf16[len] != 0) len++;
    if (len == 0) return @"";
    NSString *s = [NSString stringWithCharacters:(const unichar *)buf16 length:len];
    if (!s) return @"";
    return NickStringByStrippingIcons(s);
}
