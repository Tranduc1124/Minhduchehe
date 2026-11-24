#pragma once
#include "Vector3.h"
#include <cmath>
#include <algorithm>

namespace AimPoint {
inline bool Valid(const Vector3 &v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           (v.x != 0 || v.y != 0 || v.z != 0);
}
inline Vector3 Neck(const Vector3 &head, const Vector3 &hip) {
    if (!Valid(head)) return Vector3(0, 0, 0);
    if (!Valid(hip)) return head;
    const Vector3 upperBody = head - hip;
    const float length = Vector3::Magnitude(upperBody);
    if (!std::isfinite(length) || length < 0.2f || length > 1.5f) return head;
    // Estimate just below the head; never use unverified shoulder nodes or
    // move farther than 10 cm from a valid head position.
    return head - upperBody * (std::min(0.10f, length * 0.12f) / length);
}
} // namespace AimPoint
