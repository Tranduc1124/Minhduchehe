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
    if (!read(player + (uint64_t)kDataPool, &pool, sizeof(pool)) || !valid(pool)) return false;
    if (!read(pool + (uint64_t)kDataPoolInner, &entries, sizeof(entries)) || !valid(entries)) return false;
    const uint64_t slot = entries + (uint64_t)kDataPoolEntriesBase +
        static_cast<uint64_t>(index) * (uint64_t)kDataPoolEntryStride;
    if (!read(slot, &entry, sizeof(entry)) || !valid(entry)) return false;
    if (!read(entry + (uint64_t)kDataPoolValue, &value, sizeof(value))) return false;
    output = value;
    return true;
}
} // namespace GamePRI
