#pragma once
#include <cstdint>
#include <cstring>

namespace SilentAimNative {
template<class Point> class ScopedTarget {
    const Point *&slot_;
    const Point *previous_;
public:
    ScopedTarget(const Point *&slot, const Point &target) : slot_(slot), previous_(slot) { slot_ = &target; }
    ~ScopedTarget() { slot_ = previous_; }
    ScopedTarget(const ScopedTarget &) = delete;
    ScopedTarget &operator=(const ScopedTarget &) = delete;
};
// Parent/name/namespace offsets verified against this game's class layout.
template<class Read, class Text>
bool Derives(std::uint64_t klass, const char *name, Read read, Text text) {
    std::uint64_t visited[24]{};
    for (unsigned depth = 0; klass && depth < 24; ++depth) {
        for (unsigned i = 0; i < depth; ++i) if (visited[i] == klass) return false;
        visited[depth] = klass;
        if (text(klass + 0x10, name) && text(klass + 0x18, "COW.GamePlay")) return true;
        std::uint64_t parent = 0;
        if (!read(klass + 0x58, parent)) return false;
        klass = parent;
    }
    return false;
}
} // namespace SilentAimNative
