//
//  DSMemory.h — DarkSword-style memory provider for Free Fire
//  Reads another process's memory through kernel rw (kread64/kreadbuf).
//  No task port needed — works on jailed IPA.
//
//  Architecture:
//    app (this IPA)  --kernel rw-->  FF process vm_map entries
//    1. find FF proc by name (proc_find_by_name)
//    2. proc → proc_ro → pr_task → task → map
//    3. walk vm_map_entry list → find FF's module base (dyld text)
//    4. kread64/kreadbuf anywhere in FF's address space
//

#ifndef DSMemory_h
#define DSMemory_h

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

// returns 0 on success; sets g_ff_proc, g_ff_task, g_ff_map, g_ff_base
int  ds_attach(void);
void ds_detach(void);

bool ds_attached(void);

// --- address space primitives (all through kernel rw) ---

// translate a FF user-space VA to kernel pointer (map entry lookup)
// caches last hit entry for speed
uint64_t ds_va_to_kaddr(uint64_t va);

// raw reads — take FF user-space VA directly
bool     ds_read(uint64_t va, void *buf, size_t len);
uint8_t  ds_read8 (uint64_t va);
uint16_t ds_read16(uint64_t va);
uint32_t ds_read32(uint64_t va);
uint64_t ds_read64(uint64_t va);
float    ds_readf (uint64_t va);

// pointer read + PAC strip (user-space, xpaci enough for arm64e userland)
uint64_t ds_readptr(uint64_t va);

bool     ds_read_str(uint64_t va, char *out, size_t maxlen);

// module base of FF main binary
uint64_t ds_base(void);
pid_t    ds_pid(void);
mach_port_t ds_task_port(void);

// DarkSword core: translate one user page to kernel physmap address
uint64_t ds_translate_page(uint64_t page_va);
bool     ds_write(uint64_t va, const void *buf, size_t len);

// Fl0rk DarkSwordMemoryProvider: nestable read transaction.
// begin bumps depth; end at depth 0 can optionally compact cold page slots.
// Keeps remapped pages hot across one ESP frame (many getPositionExt reads).
void ds_begin_read_transaction(void);
void ds_end_read_transaction(void);

// The target's address space is rebuilt when a match starts: the game frees and
// reallocates its vm_objects, but our cached mappings still alias the pages
// captured at map time, so they keep returning the memory that was just freed.
// ds_detach() only runs on a pid change, so nothing else invalidates them.
// Bumping the generation lets the cache be dropped on exactly that boundary.
void ds_cache_bump_generation(void);
void ds_flush_page_cache(void);

// One-shot read that never consults or touches the page cache: map the page,
// copy, unmap. Exists to tell a lying cache apart from genuinely constant game
// data. Reading the same address twice in the same frame, once through
// ds_read and once through here, isolates the cache as the only variable. If
// they agree while a moving player stays put, the cache is innocent and the
// constant is the game's own data. Single page only.
bool ds_read_uncached(uint64_t va, void *buf, size_t len);

// Diagnostic, throttled by the caller. staleGen is the number of live slots
// mapped BEFORE the current generation, i.e. mappings that survived a match
// transition and are therefore suspect.
typedef struct {
    int liveSlots;
    int staleGen;
    uint64_t generation;
} DSPageCacheDiag;
DSPageCacheDiag ds_page_cache_diag(void);

// Cumulative page-cache counters, published for the single ESP status line.
//
// Cumulative, not per-second: the line's cadence belongs to whoever prints it, so the
// cache is not also deciding when to be sampled. The caller keeps the previous values
// and differences them. Nothing here is reset by reading it.
typedef struct {
    int      liveSlots;         // resident mappings right now
    int      blind;             // resident slots with no dead-mapping baseline yet
    int      blockedLastSecond; // a read path was refused in the previous second
    int      degradeActive;     // the throttle is currently engaged
    uint64_t remaps, evicts, hits, misses, novictim;
    uint64_t staleDrops, orphanDrops, sweeps;
    // Map failures a completed pass proved were dead addresses, excluded from the
    // degrade streak. See the classification in ds_page_local: this is the number
    // that says the exclusion is doing something rather than the streak simply
    // never being reached.
    uint64_t deadAddrMiss;
} DSPageCacheStats;
void ds_page_cache_stats(DSPageCacheStats *out);


#ifdef __cplusplus
}
#endif

#endif /* DSMemory_h */
