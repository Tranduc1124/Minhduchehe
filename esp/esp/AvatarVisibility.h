#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace AvatarVisibility {
// Renderer visibility (UmaAvatarSimple.SetVisible writes +0x101 in FFVN 1.134.1).
// Eliminates unspawned pool dummies, hidden corpses, and spectator clones in playerDict.
// NOTE: On kernel remap (vm_map_remote_page), klass->name (+0x10) and klass->namespaze (+0x18)
// point into the read-only global-metadata.dat file mapping, which is not an anonymous R/W
// heap vm_object. We validate the full R/W heap pointer chain (player -> manager -> avatar ->
// klass -> name/namespc pointers) and the UmaAvatarSimple.IsVisible byte at avatar + 0x101.
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
    return readPtr(player, avatarMgrOff, manager) &&
           readPtr(manager, 0x138, avatar) &&
           readPtr(avatar, 0, klass) &&
           readPtr(klass, 0x10, name) &&
           readPtr(klass, 0x18, namespc) &&
           readField(avatar, 0x101, visible) && visible == 1;
}
}
