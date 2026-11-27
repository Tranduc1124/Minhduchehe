#pragma once
#include <cstddef>
#include <cstdint>
#include "GameOffsets.h"

namespace GamePRI {
// Player.get_IsFiringFromPRI in the supplied 1.132.1 / 1.134.1 IPA requests index 21
// and compares the UInt16 result with 2.
inline constexpr int FiringIndex = 21;
inline constexpr uint16_t FiringActiveValue = 2;
inline bool Firing(int value) { return value == FiringActiveValue; }

template <typename Reader, typename Validator>
bool TryUInt16(uint64_t player, int index, Reader read, Validator valid,
               uint16_t &output) {
    if (!valid(player) || index < 0 || index > 32) return false;
    uint64_t pool = 0, entries = 0, entry = 0;
    uint16_t value = 0;
    const uint64_t poolOff = kDataPool ? (uint64_t)kDataPool : 0x70ULL;
    const uint64_t innerOff = kDataPoolInner ? (uint64_t)kDataPoolInner : 0x10ULL;
    const uint64_t baseOff = kDataPoolEntriesBase ? (uint64_t)kDataPoolEntriesBase : 0x20ULL;
    const uint64_t stride = kDataPoolEntryStride ? (uint64_t)kDataPoolEntryStride : 0x8ULL;
    const uint64_t valOff = kDataPoolValue ? (uint64_t)kDataPoolValue : 0x18ULL;
    if (!read(player + poolOff, &pool, sizeof(pool)) || !valid(pool)) return false;
    if (!read(pool + innerOff, &entries, sizeof(entries)) || !valid(entries)) return false;
    const uint64_t slot = entries + baseOff + static_cast<uint64_t>(index) * stride;
    if (!read(slot, &entry, sizeof(entry)) || !valid(entry)) return false;
    if (!read(entry + valOff, &value, sizeof(value))) return false;
    output = value;
    return true;
}

// Mizze OverlayHealth::Snapshot parity:
// Read one PRI pool and reject replacement during the snapshot. Never fabricate
// max HP or probe unrelated offsets when the PRI pool is invalid.
template <typename Reader, typename Validator>
bool SnapshotHP(uint64_t player, Reader read, Validator valid,
                int &outCurHP, int &outMaxHP) {
    outCurHP = 0;
    outMaxHP = 0;
    uint64_t pool = 0, entries = 0, current = 0, maximum = 0, check = 0;
    uint16_t hp = 0, maxHP = 0;
    const uint64_t poolOff = kDataPool ? (uint64_t)kDataPool : 0x70ULL;
    const uint64_t innerOff = kDataPoolInner ? (uint64_t)kDataPoolInner : 0x10ULL;
    const uint64_t baseOff = kDataPoolEntriesBase ? (uint64_t)kDataPoolEntriesBase : 0x20ULL;
    const uint64_t stride = kDataPoolEntryStride ? (uint64_t)kDataPoolEntryStride : 0x8ULL;
    const uint64_t valOff = kDataPoolValue ? (uint64_t)kDataPoolValue : 0x18ULL;
    if (!valid(player) ||
        !read(player + poolOff, &pool, 8) || !valid(pool) ||
        !read(pool + innerOff, &entries, 8) || !valid(entries) ||
        !read(entries + baseOff, &current, 8) || !valid(current) ||
        !read(entries + baseOff + stride, &maximum, 8) || !valid(maximum) ||
        !read(current + valOff, &hp, 2) ||
        !read(maximum + valOff, &maxHP, 2) ||
        !maxHP || maxHP > 10000 || hp > maxHP ||
        !read(player + poolOff, &check, 8) || check != pool ||
        !read(pool + innerOff, &check, 8) || check != entries ||
        !read(entries + baseOff, &check, 8) || check != current ||
        !read(entries + baseOff + stride, &check, 8) || check != maximum) {
        return false;
    }
    outCurHP = static_cast<int>(hp);
    outMaxHP = static_cast<int>(maxHP);
    return true;
}
} // namespace GamePRI
