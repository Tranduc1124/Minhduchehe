#pragma once
#include <cmath>
#include <cstdint>

namespace SilentAimDirection {
// Plain float triplets keep the shot adapter independent of UIKit and game types.
struct Point {
    float x = 0, y = 0, z = 0;
    bool operator==(const Point &p) const { return x == p.x && y == p.y && z == p.z; }
};
static_assert(sizeof(Point) == 3 * sizeof(float), "Native direction is a float triplet");
inline bool Finite(Point p) {
    return std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z);
}
inline bool Toward(Point origin, Point head, Point &direction) {
    if (!Finite(origin) || !Finite(head)) return false;
    const double x = double(head.x) - origin.x;
    const double y = double(head.y) - origin.y;
    const double z = double(head.z) - origin.z;
    const double length = std::sqrt(x*x + y*y + z*z);
    if (!std::isfinite(length) || length <= 0.01) return false;
    direction = {float(x/length), float(y/length), float(z/length)};
    return Finite(direction);
}
inline bool Fresh(double updated, double now) {
    return std::isfinite(updated) && std::isfinite(now) &&
           now >= updated && now - updated <= 0.15;
}
inline float ViewportRadius(float width, float height) {
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0) return 0;
    return std::nextafter(std::hypot(width * 0.5f, height * 0.5f), INFINITY);
}

// Always run the native handler. Restore only our own value, and only if its
// containing object is still current; pooled aiming results may be replaced.
template <typename Reader, typename Writer, typename Current, typename Handler>
bool Dispatch(Point desired, Reader read, Writer write, Current current, Handler handler) {
    Point original{};
    const bool changed = Finite(desired) && current() && read(original) &&
        Finite(original) && !(original == desired) && write(desired);
    struct Restore {
        bool changed;
        Point original, desired;
        Reader &read;
        Writer &write;
        Current &current;
        ~Restore() {
            Point live{};
            if (changed && current() && read(live) && live == desired) write(original);
        }
    } restore{changed, original, desired, read, write, current};
    handler();
    return changed;
}
} // namespace SilentAimDirection
