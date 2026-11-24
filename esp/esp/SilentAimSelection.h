#pragma once
#include "AimSelection.h"

namespace SilentAimSelection {
// Direction is the hard gate. Distance breaks ties within that cone, rather
// than allowing a nearby player at the screen edge to steal the shot.
inline float Radius(float width, float height, float percent) {
    if (!std::isfinite(percent)) percent = 18;
    return AimSelection::Radius(width, height, percent);
}
struct Selection {
    uint64_t previous = 0, target = 0;
    float bestScore = std::numeric_limits<float>::max();
    void consider(uint64_t id, float x, float y, float depth, float width,
                  float height, float radius, float meters, float maxMeters, bool eligible) {
        AimSelection::Selection gate;
        gate.consider(id, x, y, depth, width, height, radius, eligible);
        if (!gate.target || !std::isfinite(meters) || meters <= 0 ||
            !std::isfinite(maxMeters) || maxMeters <= 0 || meters > maxMeters) return;
        const float direction = std::sqrt(gate.bestDistanceSquared) / radius;
        const float distance = std::fmin(1.0f, meters / maxMeters);
        // Mild hysteresis prevents equal candidates from flickering, but a
        // clearly closer / better-aligned candidate can replace the old one.
        const float score = 0.75f * direction + 0.25f * distance - (id == previous ? 0.025f : 0);
        if (score < bestScore || (score == bestScore && id < target)) {
            bestScore = score;
            target = id;
        }
    }
};
} // namespace SilentAimSelection
