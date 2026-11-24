#pragma once
#include <cstdint>
#include <cstring>
#include "GameOffsets.h"
#include "SilentAimNativePolicy.h"

namespace SilentAimWeapon {
// GetWeaponOnHand -> GMOCOOEIFMK getter, from the supplied 1.132.1 / 1.134.1 native image.
inline constexpr uint64_t WeaponOwner   = 0x60;
inline constexpr uint64_t WeaponHandler = 0x80;
inline constexpr uint64_t HandlerWeapon = 0x10;
inline constexpr uint64_t HandlerInfo   = 0x28;
inline constexpr uint64_t InfoDirection = 0x40;
inline constexpr uint64_t InfoOrigin    = 0x4C;

template <typename Reader, typename Validator>
uint64_t OnHand(uint64_t local, Reader read, Validator valid) {
    uint64_t manager = 0, owner = 0, weapon = 0;
    uint8_t combined = 0;
    const uint64_t holderOff = kWeaponHolder ? (uint64_t)kWeaponHolder : 0x740ULL;
    if (!valid(local) || !read(local + holderOff, manager) || !valid(manager) ||
        !read(manager + 0x30, owner) || owner != local ||
        !read(manager + 0x148, combined) || combined > 1 ||
        !read(manager + (combined ? 0xA8 : 0xA0), weapon) || !valid(weapon) ||
        !read(weapon + WeaponOwner, owner) || owner != local) return 0;
    return weapon;
}

template <typename Reader, typename TextCheck, typename Validator>
uint64_t ResolveHandlerInfo(uint64_t local, Reader read, TextCheck textEq, Validator valid,
                            uint64_t *outWeapon = nullptr, uint64_t *outHandler = nullptr) {
    if (outWeapon) *outWeapon = 0;
    if (outHandler) *outHandler = 0;
    if (!valid(local)) return 0;

    uint64_t weapon = OnHand(local, read, valid);
    if (!valid(weapon) && kActiveWeapon) {
        uint64_t cand = 0, owner = 0;
        if (read(local + (uint64_t)kActiveWeapon, cand) && valid(cand) &&
            read(cand + WeaponOwner, owner) && owner == local) {
            weapon = cand;
        }
    }
    if (!valid(weapon)) return 0;
    if (outWeapon) *outWeapon = weapon;

    uint64_t handler = 0, hWeapon = 0, hKlass = 0;
    if (!read(weapon + WeaponHandler, handler) || !valid(handler) ||
        !read(handler + HandlerWeapon, hWeapon) || hWeapon != weapon ||
        !read(handler, hKlass) || !valid(hKlass)) {
        return 0;
    }
    if (!SilentAimNative::Derives(hKlass, "MDPBNKPCGNG", read, textEq)) {
        return 0;
    }
    if (outHandler) *outHandler = handler;

    uint64_t info = 0, infoKlass = 0;
    if (!read(handler + HandlerInfo, info) || !valid(info) ||
        !read(info, infoKlass) || !valid(infoKlass)) {
        return 0;
    }
    if (!textEq(infoKlass + 0x10, "CGKJLKPMGDJ")) {
        return 0;
    }
    return info;
}
} // namespace SilentAimWeapon
