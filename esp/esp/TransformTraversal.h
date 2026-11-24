#pragma once
#include <cstddef>

namespace TransformTraversal {
constexpr int MaxIndex = 8192;
constexpr size_t MaxDepth = 64;

// Reject incomplete reads, cycles and corrupt parent chains instead of
// returning a partially transformed position or reading index zero repeatedly.
template<class ReadParent, class ApplyParent>
bool Walk(int index, ReadParent readParent, ApplyParent applyParent) {
    if (index < 0 || index > MaxIndex) return false;
    int visited[MaxDepth + 1] = {index};
    size_t size = 1;
    int parent = -1;
    if (!readParent(index, parent)) return false;
    while (parent >= 0) {
        if (parent > MaxIndex || size > MaxDepth) return false;
        for (size_t i = 0; i < size; ++i) if (visited[i] == parent) return false;
        visited[size++] = parent;
        if (!applyParent(parent) || !readParent(parent, parent)) return false;
    }
    return parent == -1;
}
}
