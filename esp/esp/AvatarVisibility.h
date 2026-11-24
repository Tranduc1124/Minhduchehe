#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace AvatarVisibility {
// Renderer visibility only (UmaAvatarSimple.SetVisible writes +0x101 in FFVN 1.134.1).
// Eliminates unspawned pool dummies, hidden corpses, and spectator clones in playerDict.
template<class Reader, class Valid>
bool IsVisible(uint64_t player, Reader read, Valid valid, uint64_t avatarMgrOff = 0x770) {
    uint64_t manager = 0, avatar = 0, klass = 0, name = 0, namespc = 0;
    uint8_t visible = 0;
    auto readField = [&](uint64_t base, uint64_t off, auto &out) -> bool {
        return valid(base) && read(base + off, &out, sizeof(out));
    };
    auto readPtr = [&](uint64_t base, uint64_t off, uint64_t &out) -> bool {
        return valid(base) && read(base + off, &out, sizeof(out)) && valid(out);
    };
    auto nameEquals = [&](uint64_t addr, const char *expected) -> bool {
        if (!valid(addr) || !expected) return false;
        char buf[32] = {};
        const size_t len = std::strlen(expected);
        if (len + 1 > sizeof(buf)) return false;
        return read(addr, buf, len + 1) && std::memcmp(buf, expected, len + 1) == 0;
    };
    return readPtr(player, avatarMgrOff, manager) &&
           readPtr(manager, 0x138, avatar) &&
           readPtr(avatar, 0, klass) &&
           readPtr(klass, 0x10, name) &&
           readPtr(klass, 0x18, namespc) &&
           nameEquals(name, "UmaAvatarSimple") &&
           nameEquals(namespc, "UMA.Simple") &&
           readField(avatar, 0x101, visible) && visible == 1;
}
}
