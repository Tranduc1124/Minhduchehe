#pragma once
#include <cmath>
#include <cstdint>
#include <limits>

namespace AimSelection {
inline float Radius(float width, float height, float percent) {
    if (!std::isfinite(percent)) percent = 40;
    percent = std::fmax(5.0f, std::fmin(48.0f, percent));
    return std::fmin(width, height) * percent / 100.0f;
}
inline bool Triggered(bool fireEnabled, bool scopeEnabled, bool firing, bool scoping) {
    return (fireEnabled && firing) || (scopeEnabled && scoping);
}
inline bool Triggered(bool enabled, bool scopeEnabled, bool firing, bool scoping, bool alwaysHip) {
    if (enabled) return alwaysHip || firing;
    return scopeEnabled && scoping;
}
inline bool BooleanState(uint32_t raw) { return raw == 1; }
inline bool FiringState(int raw) { return raw == 1; }
inline bool ScopeState(uint32_t raw) { return raw != 0; }

struct Selection {
    uint64_t previous = 0;
    uint64_t target = 0;
    float bestDistanceSquared = std::numeric_limits<float>::max();
    bool retained = false;

    void consider(uint64_t id, float x, float y, float depth,
                  float width, float height, float radius, bool eligible) {
        if (!eligible || !id || !std::isfinite(x) || !std::isfinite(y) ||
            !std::isfinite(depth) || depth <= 0.001f ||
            !std::isfinite(width) || !std::isfinite(height) || !std::isfinite(radius) ||
            width <= 0 || height <= 0 || radius <= 0 ||
            x < 0 || x > width || y < 0 || y > height) return;
        const float dx = x - width * 0.5f, dy = y - height * 0.5f;
        const float distanceSquared = dx * dx + dy * dy;
        const bool same = id == previous;
        const float limit = radius;
        if (distanceSquared > limit * limit) return;
        if (same || (!retained && (distanceSquared < bestDistanceSquared ||
            (distanceSquared == bestDistanceSquared && id < target)))) {
            target = id;
            bestDistanceSquared = distanceSquared;
            retained = same;
        }
    }
};
} // namespace AimSelection
