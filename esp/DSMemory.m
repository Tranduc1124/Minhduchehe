//
//  DSMemory.m — Fl0rk DarkSwordMemoryProvider (remap + lock/cache/breaker)
//
//  Kernel r/w direct — NO task port, NO mach APIs on target.
//
//  Chain:
//    FF proc → task → vm_map → header → entry list
//    entry: links.next, start(0x10), end(0x18), vme_object_or_delta(0x3c)
//    vm_object: vo_un1.vou_size (page tree), ref_count
//
//  Page translation (user VA → kernel data):
//    1. find map entry containing VA
//    2. offset_in_object = VA - entry.start + object.vo_offset
//    3. vm_page lookup in object's memq: page->offset == offset & ~PAGE_MASK
//    4. page → physical address → kernel physmap base + pa
//    5. kreadbuf/kwritebuf at physmap address
//
//  Fallback: if page lookup misses (paged out), return failure — caller retries.
//

#import "DSMemory.h"
#import "../kexploit/kexploit_opa334.h"
#import "../app/KernelBoot.h" // kernelBootLog (diag to Home log card)
#import "../remote/VM.h"      // vm_map_remote_page — Fl0rk DarkSword remap path
#import "../kexploit/krw.h"
#import "../kexploit/kutils.h"
#import "../kexploit/offsets.h"
#import "../kexploit/xpaci.h"

#import <mach/mach.h>
#import <mach/mach_time.h>
#import <sys/sysctl.h>
#import <pthread.h>

// Same declares as remote/VM.m — mach/mach_vm.h is not always public in the SDK.
extern kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr, mach_vm_size_t size);

// xnu page size on arm64 — guard against system header macros
#ifndef PAGE_SHIFT
#define PAGE_SHIFT 14
#endif
#ifndef PAGE_SIZE
#define PAGE_SIZE  (1 << PAGE_SHIFT)
#endif
#ifndef PAGE_MASK
#define PAGE_MASK  (PAGE_SIZE - 1)
#endif

extern uint64_t early_kread64(uint64_t where);

static uint64_t g_ff_proc = 0;
static uint64_t g_ff_task = 0;
static uint64_t g_ff_map  = 0; // target's vm_map — used with vm_map_remote_page
static pid_t    g_ff_pid  = 0;
static uint64_t g_ff_base = 0;

// entry cache — most reads hit same entry repeatedly
static uint64_t g_cached_entry      = 0;
static uint64_t g_cached_start      = 0;
static uint64_t g_cached_end        = 0;
static uint64_t g_cached_object     = 0;
static uint64_t g_cached_obj_offset = 0;

#define S(x) ({ uint64_t _v = xpaci((uint64_t)(x)); \
    ((_v >> 32) > 0xFFFF ? (_v | pac_mask) : _v); })
#define K(x) ((x) > VM_MIN_KERNEL_ADDRESS)

// vm_map_entry field offsets relative to links.next
// xnu: struct vm_map_entry { vm_map_links_t links; ... }
//   links.next   = +0x00
//   links.prev   = +0x08
//   links.start  = +0x10
//   links.end    = +0x18
#define E_START    0x10
#define E_END      0x18
#define E_OBJECT   off_vm_map_entry_vme_object_or_delta
#define E_ALIAS    off_vm_map_entry_vme_alias

// vm_object fields
//   memq.next   = +0x40 (list of resident pages) — per KDK, verify per version
//   vo_offset   = +0x60 — object offset base
//   ref_count   = off_vm_object_ref_count
#define O_MEMQ     0x40
#define O_OFFSET   0x68

// vm_page fields
//   listq.next  = +0x00
//   offset      = +0x18 (offset into object, page-aligned)
//   phys_page   = +0x30 (physical page frame number)
#define P_LISTQ    0x00
#define P_OFFSET   0x18
#define P_PHYS     0x30

// kernel physmap base — where physical memory is direct-mapped
// arm64 xnu: gPhysBase/gPhysSize → physmap window. Compute from kernel base.
static uint64_t g_physmap_base = 0;

static void init_physmap(void) {
    if (g_physmap_base) return;
    // arm64 xnu physmap: PHYSMAP_PTOB / base derived at boot.
    // Practical value on iOS 17-26 arm64: 0xFFFFFFF0F0000000 region.
    // Scan-free heuristic used by DS-class providers:
    //   read id_tprlo / T1SZ region — but the stable anchor is:
    //   kernel text base + fixed slide window.
    g_physmap_base = 0xFFFFFFF000000000ULL; // arm64 physmap base (all versions 17-26)
}

#pragma mark - attach

int ds_attach(void) {
    if (ds_attached()) return 0;
    if (!g_kexploit_ready) return -1;

    // Drop any half-finished attempt before starting a new one.
    //
    // g_ff_task is set at the line that reads proc_ro->pr_task, which is BEFORE
    // the base walk. Every failure between there and the end of the walk
    // (proc_ro, task, map, nentries, first entry, no base) returns -1 and leaves
    // g_ff_task set, and ds_attached() is a bare pointer test on g_ff_task. So
    // one failed attempt made ds_attached() answer true forever, and the
    // early-out above meant every later ds_attach() returned 0 without walking
    // anything -- the retry could never fix itself.
    //
    // This is what happened on device 2026-10-03 12:56, one boot after the
    // bundle id change:
    //
    //   [DS] base walk: mapped=7 fail=7 best=0x0 size=0x0
    //   [DS] module base not found (nentries walk failed)
    //   [GameOffsets] ds_attach() failed: code -1
    //   [HB] FLUSH1 base=0x0 pid=519 at=1 ...      <- attached, base zero
    //
    // and every [HB] FLUSH1 line after it kept printing base=0x0 at=1 until the
    // process died. Nothing drew, because every offset is module-relative and
    // the module base was zero.
    //
    // ds_detach() is the right reset because it also drops the page cache and
    // the degrade state, which were both populated against the failed attempt.
    if (g_ff_task || g_ff_proc || g_ff_pid || g_ff_base) {
        ds_detach();
    }

    init_physmap();

    // DIAG: kernel read health check — read our own proc. If this returns
    // garbage, the kernel primitives are dead (post-panic) and every later
    // read is noise. Surface it instead of failing silently.
    uint64_t selfCheck = proc_self();
    bool kernelAlive = is_kaddr_valid(selfCheck);
    if (!kernelAlive) {
        static int s_deadLogged = 0;
        if (!s_deadLogged) {
            s_deadLogged = 1;
            NSLog(@"[DS] KERNEL READ DEAD — self proc readback invalid (0x%llx). Re-run the exploit.", selfCheck);
            kernel_boot_log_fn logFn = kernelBootLog;
            if (logFn) {
                NSString *line = @"[diag] kernel DEAD - run the exploit again";
                dispatch_async(dispatch_get_main_queue(), ^{ logFn(line); });
            }
        }
        return -1;
    }

    const char *names[] = { "FreeFire", "FreeFireMAX", "GarenaFreeFire", "Freefire", "freefire" };
    uint64_t p = 0;
    const char *foundName = NULL;
    for (int i = 0; i < 5; i++) {
        p = proc_find_by_name(names[i]);
        // is_kaddr_valid(p + off), not K(p). proc_find_by_name answers "not
        // found" with (uint64_t)-1, and K() is a plain `>` against
        // VM_MIN_KERNEL_ADDRESS, so -1 passes it: 0xFFFFFFFFFFFFFFFF is larger
        // than 0xFFFFFFDC00000000. What actually rejects it is the offset test —
        // the address that gets read next is p + off_proc_p_pid, and for p = -1
        // that wraps to 0x5F on 17.x (off_proc_p_pid = 0x60), which is not a
        // kernel address. RemoteCall.m:1812 already uses this exact test.
        if (p && p != (uint64_t)-1 && K(p) && is_kaddr_valid(p + off_proc_p_pid)) {
            foundName = names[i];
            break;
        }
        p = 0;
    }
    // The post-loop test has to be this and not `if (!p)`. "The game is not
    // running" is the normal state of this app for most of its life, and it is
    // answered by -1, not by 0.
    //
    // MINHDUC-2026-10-02-234403.ips: SIGSEGV, KERN_INVALID_ADDRESS at 0x1,
    // early_kread <- early_kread64 <- kread32 <- ds_attach <- GameTargetModuleBase
    // <- the ESP frame timer, on the main queue. 0x1 is early_kread's own
    // canary, `*(int *)1 = 0` at kexploit_opa334.m:459, which fires when
    // is_kaddr_valid rejects the address. The chain above fed it kread32(0x5F):
    // the loop rejected -1 correctly but left it in p, `if (!p)` is false for -1,
    // and the next line dereferenced it. It happened on the first ESP tick after
    // every boot in which the game was not already running, and never when the
    // game was up, which is exactly the reported symptom.
    if (!p || p == (uint64_t)-1 || !is_kaddr_valid(p + off_proc_p_pid)) {
        static int s_notFoundLogged = 0;
        if (!s_notFoundLogged) {
            s_notFoundLogged = 1;
            NSLog(@"[DS] FF proc not found (kernel alive)");
            kernel_boot_log_fn logFn = kernelBootLog;
            if (logFn) {
                NSString *line = @"[diag] Free Fire not found - open the game and wait";
                dispatch_async(dispatch_get_main_queue(), ^{ logFn(line); });
            }
        }
        return -1;
    }
    g_ff_proc = p;
    g_ff_pid  = (pid_t)kread32(p + off_proc_p_pid);
    // A proc named like the game with no pid is one that is on its way out. Its
    // vm_map is freed as it goes, so the walk below would return a base from a
    // map that no longer describes the process and every later read would be
    // noise. The retry picks the real one up within half a second.
    if (g_ff_pid <= 0) {
        NSLog(@"[DS] FF proc pid=0 — process is exiting, will retry");
        return -1;
    }
    NSLog(@"[DS] attached '%s' pid=%d", foundName ?: "?", g_ff_pid);

    // proc_task() inlined so the intermediate can be checked. A proc that exists
    // but is not usable — the game caught mid-launch, or already exiting — has a
    // proc_ro that is null or not a kernel address, and kread64 of
    // proc_ro + off_proc_ro_pr_task on it lands in early_kread's canary, the
    // same SIGSEGV at 0x1 as above. Attaching is retried for as long as the
    // process lives, so a refusal here is a normal answer, not a failure.
    uint64_t proc_ro = kread64(g_ff_proc + off_proc_p_proc_ro);
    if (!K(proc_ro) || !is_kaddr_valid(proc_ro)) {
        NSLog(@"[DS] FF proc_ro invalid (0x%llx) — game still starting or exiting",
              (unsigned long long)proc_ro);
        return -1;
    }
    g_ff_task = kread64(proc_ro + off_proc_ro_pr_task);
    if (!K(g_ff_task) || !is_kaddr_valid(g_ff_task)) {
        NSLog(@"[DS] FF task invalid (0x%llx)", (unsigned long long)g_ff_task);
        return -1;
    }

    // module base: walk entries, pick the LARGEST Mach-O-backed region above
    // 4GB — the first-match heuristic kept grabbing small system frameworks
    // (0x10ddf7000) whose header IS a valid Mach-O, so the magic check passed
    // while base pointed at the wrong image (ti=nil downstream). UnityFramework
    // is by far the biggest mapped binary in the FF process.
    uint64_t map = kread_ptr(g_ff_task + off_task_map);
    // Same reason as proc_ro above, one step further out: a task can be live
    // while its map is already gone. Every read below is at map + an offset, so
    // an unchecked map is an unchecked address.
    if (!K(map) || !is_kaddr_valid(map + off_vm_map_hdr)) {
        NSLog(@"[DS] FF map invalid (0x%llx)", (unsigned long long)map);
        return -1;
    }
    g_ff_map = map; // saved for ds_read/ds_write remap path
    uint64_t hdr = map + off_vm_map_hdr;
    uint32_t nentries = kread32(hdr + off_vm_map_header_nentries);
    // nentries is a count, not a pointer: a wrong offset reads a plausible
    // 32-bit garbage and the walk below would then follow whatever it finds.
    if (nentries == 0 || nentries > 100000) {
        NSLog(@"[DS] FF vm_map header implausible (nentries=%u) — retry later", nentries);
        return -1;
    }
    uint64_t e = kread_ptr(hdr + off_vm_map_header_links_next);
    if (!K(e) || !is_kaddr_valid(e + E_START)) {
        NSLog(@"[DS] FF vm_map first entry invalid (0x%llx)", (unsigned long long)e);
        return -1;
    }

    uint64_t bestStart = 0, bestSize = 0;
    int mappedCount = 0, failCount = 0;
    // K(e) alone is not enough here for the same reason as the name loop: -1
    // passes `>`. The entry is dereferenced on the next line.
    for (uint32_t i = 0; i < nentries && K(e) && is_kaddr_valid(e + E_START); i++) {
        uint64_t start = kread64(e + E_START);
        uint64_t end   = kread64(e + E_END);
        uint64_t size  = (end > start) ? (end - start) : 0;

        if (start >= 0x100000000 && size > 0x400000 && start < 0x800000000) {
            struct VMShmem page = vm_map_remote_page(map, start & ~0x3FFFULL);
            if (page.localAddress) {
                mappedCount++;
                uint32_t magic = *(uint32_t *)(uintptr_t)(page.localAddress + (start & 0x3FFFULL));
                if (magic == 0xFEEDFACF && size > bestSize) {
                    bestStart = start;
                    bestSize = size;
                }
                // Fl0rk: never keep attach-probe remaps — free mapping + entry port.
                mach_vm_deallocate(mach_task_self_,
                                   (mach_vm_address_t)page.localAddress,
                                   PAGE_SIZE);
                if (page.port) {
                    mach_port_deallocate(mach_task_self_,
                                         (mach_port_name_t)page.port);
                }
            } else {
                if (page.port) {
                    mach_port_deallocate(mach_task_self_,
                                         (mach_port_name_t)page.port);
                }
                if (failCount < 5) {
                    NSLog(@"[DS] remap FAIL region start=0x%llx size=0x%llx", start, size);
                }
                failCount++;
            }
        }
        e = kread_ptr(e + off_vm_map_entry_links_next);
    }
    NSLog(@"[DS] base walk: mapped=%d fail=%d best=0x%llx size=0x%llx",
          mappedCount, failCount, bestStart, bestSize);
    if (bestStart) {
        g_ff_base = bestStart;
    }

    if (!g_ff_base) {
        static int s_baseLogged = 0;
        if (!s_baseLogged) {
            s_baseLogged = 1;
            NSLog(@"[DS] module base not found (nentries walk failed)");
            kernel_boot_log_fn logFn = kernelBootLog;
            if (logFn) {
                NSString *line = @"[diag] found FF but memory is unreadable (vm_map walk failed)";
                dispatch_async(dispatch_get_main_queue(), ^{ logFn(line); });
            }
        }
        return -1;
    }

    NSLog(@"[DS] attached: pid=%d proc=0x%llx task=0x%llx base=0x%llx",
          g_ff_pid, g_ff_proc, g_ff_task, g_ff_base);
    return 0;
}

#pragma mark - page translation (the DarkSword core)

// translate one page: user_va (page-aligned) → kernel physmap addr
uint64_t ds_translate_page(uint64_t page_va) {
    if (!K(g_ff_task)) return 0;
    page_va &= ~PAGE_MASK;

    // 1. find containing entry (use cache first)
    uint64_t entry = 0, start = 0, __attribute__((unused)) end = 0, object = 0, obj_offset = 0;

    if (g_cached_entry && page_va >= g_cached_start && page_va < g_cached_end) {
        entry = g_cached_entry;
        start = g_cached_start; end = g_cached_end;
        object = g_cached_object; obj_offset = g_cached_obj_offset;
    } else {
        uint64_t map = kread_ptr(g_ff_task + off_task_map);
        uint64_t hdr = map + off_vm_map_hdr;
        uint32_t nentries = kread32(hdr + off_vm_map_header_nentries);
        uint64_t e = kread_ptr(hdr + off_vm_map_header_links_next);

        for (uint32_t i = 0; i < nentries && K(e); i++) {
            uint64_t s = kread64(e + E_START);
            uint64_t t = kread64(e + E_END);
            if (page_va >= s && page_va < t) {
                entry = e; start = s; end = t;
                object = kread_ptr(e + E_OBJECT);
                // vme_object_or_delta: if alias==VM_MEMORY_REAL, object is real;
                // obj_offset stored in object->vo_offset
                obj_offset = object ? kread64(object + O_OFFSET) : 0;
                // cache
                g_cached_entry = entry; g_cached_start = s; g_cached_end = t;
                g_cached_object = object; g_cached_obj_offset = obj_offset;
                break;
            }
            e = kread_ptr(e + off_vm_map_entry_links_next);
        }
    }

    if (!K(entry) || !K(object)) return 0;

    // 2. offset into object
    uint64_t page_offset_in_object = (page_va - start) + obj_offset;
    uint64_t page_index = page_offset_in_object >> PAGE_SHIFT;

    // 3. walk object memq for page with matching offset
    uint64_t page = kread_ptr(object + O_MEMQ);
    // memq is a queue head; iterate listq
    uint64_t first = kread_ptr(object + O_MEMQ + 0x0);
    page = first;
    int steps = 0;
    while (K(page) && steps < 4096) {
        uint64_t poff = kread64(page + P_OFFSET);
        if ((poff & ~PAGE_MASK) == (page_offset_in_object & ~PAGE_MASK)) {
            // found resident page
            uint32_t phys = kread32(page + P_PHYS);
            if (!phys) return 0;
            uint64_t pa = ((uint64_t)phys << PAGE_SHIFT);
            return g_physmap_base + pa;
        }
        page = kread_ptr(page + P_LISTQ);
        steps++;
    }
    return 0; // paged out — caller retries
}

#pragma mark - read/write

// DIRECT kernel reads (lara/cyanide pattern): read the TARGET's USER memory
// through its vm_map's translation is what the old physmap walk tried and
// failed (guessed physmap base + hardcoded vm_object offsets never worked on
// 17.5.1/A15). The working path used by lara and cyanide: kernel addresses of
// the target's data CAN be reached with early_kread64 directly when we have
// the virtual kernel mapping — which early_kread64 operates on via the
// corrupted socket's kernel pointer. So: walk NOTHING, read the user-space
// address translated through arm64 TTBR0 by dereferencing with the kernel
// primitive is NOT possible — instead we use the SAME technique cyanide's
// krw uses for game memory: read through the target task's vm_map pages
// resolved ONCE per page via ds_translate_page, BUT with a working fallback:
// if translate fails, read via early_kread64 on the vm_map-entry-backed
// kernel alias. In practice on 17.5.1 the reliable route is a tight 8-byte
// PAGE REMAP reads (the lara/cyanide-proven path) + PAGE CACHE.
// vm_map_remote_page per read is expensive (alloc + memory-entry + kernel
// refcount bump every call) AND flaky under load — that's the "lúc được lúc
// không". Cache mapped pages (128 slots, LRU-ish round-robin) so repeated
// reads of the same page (the common case: HP/positions/TypeInfo) hit the
// cache and cost a memcpy only.
// Fl0rk DarkSwordMemoryProvider cache shape:
//   _pageSlots[256] {VMShmem + lastUse}, _recentPageSlots[8], soft-age on txn end,
//   NSRecursiveLock across map+insert, degraded after 3 consecutive map failures.
#define DS_PAGE_CACHE_SLOTS 256
#define DS_RECENT_SLOTS 8
#define DS_FAIL_DEGRADE_THRESHOLD 3
// How long a degrade pauses remapping before it is retried. Long enough not to
// hammer a kernel that is refusing, short enough that a burst of failures costs
// a quarter of a second of reads instead of the rest of the session.
#define DS_DEGRADE_COOLDOWN_MS 250

// Hard lifetime for a mapping, counted from the moment it was taken.
//
// Why this cannot be based on lastUse: a stale page is not an idle page. When
// the game hands a recycled VA to new data we keep reading that VA every frame
// and keep getting the old bytes, so the slot is permanently "hot" and any
// idle-based scheme would never touch it. The device log shows world frozen at
// (57.58,12.79,58.47) for 21 s while the camera kept moving. Age therefore has
// to be measured from insertion and must expire even busy pages, which is what
// shmemClock[256] in the reference does and what lastUse here could not.
//
// 2000 ms is a starting value, not a measured one. It is the knob that trades
// tracking accuracy against remap cost, so both rates are logged every second
// (see ds_end_read_transaction) and the value is meant to be tuned from the
// device log, not defended.
#define DS_PAGE_TTL_MS 2000ULL

// Upper bound on mappings torn down in one transaction. Releasing all 256 at
// once is what produced "Taking non-sleepable RW lock with preemption enabled"
// (see the note in ds_end_read_transaction). Spreading the same total over many
// transactions keeps the port deallocations apart in time.
#define DS_MAX_EVICT_PER_TXN 4

static struct {
    uint64_t pageVA;
    uint64_t localAddr;
    uint64_t port;     // memory_entry — MUST mach_port_deallocate on eviction
    uint64_t lastUse;  // Fl0rk lastUse clock
    uint64_t bornMs;   // wall clock at insert
    // Wall clock of the most recent read that hit this slot. The TTL is
    // measured against this, not against bornMs. bornMs made a page the game
    // is reading every single frame expire anyway, once every two seconds, and
    // get remapped on the next frame: a periodic hitch whose size is the whole
    // working set, on a timer. Measuring age since last use keeps what the TTL
    // is actually for, which is a VA the game has stopped touching, and leaves
    // the pages that are demonstrably alive alone.
    uint64_t lastUseMs;
    uint64_t gen;      // match generation this mapping was taken under
    uint32_t useCount;
} g_pageCache[DS_PAGE_CACHE_SLOTS];
// Bumped on every match change by the ESP layer; see ds_cache_bump_generation.
static uint64_t g_cacheGeneration = 1;
static int g_recentPageSlots[DS_RECENT_SLOTS];
static int g_recentCount = 0;
static uint64_t g_pageUseCounter = 1;
static int g_pageCacheNext = 0;
// Lifetime counters, reported once a second as [DS-TLB]. Kept monotonic across
// flushes so a rate never goes negative.
static uint64_t g_dsRemapCount = 0;
static uint64_t g_dsEvictCount = 0;
// Recursive: begin/end txn + ds_page_local nest like Fl0rk NSRecursiveLock.
static pthread_mutex_t g_pageCacheLock;
static pthread_once_t g_pageCacheLockOnce = PTHREAD_ONCE_INIT;
static int g_readTxnDepth = 0;
static uint64_t g_consecutiveMapFailures = 0;
static bool g_degraded = false;
// Wall clock at which the degrade is retried. Zero while not degraded.
static uint64_t g_degradedUntilMs = 0;
// How many times a degrade has been recovered from, reported by the [DS-TLB]
// line so a session that keeps hitting this says so instead of looking stable.
static uint32_t g_dsRecoverCount = 0;

static void ds_page_cache_lock_init(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_pageCacheLock, &attr);
    pthread_mutexattr_destroy(&attr);
}

static void ds_lock(void) {
    pthread_once(&g_pageCacheLockOnce, ds_page_cache_lock_init);
    pthread_mutex_lock(&g_pageCacheLock);
}

static void ds_unlock(void) {
    pthread_mutex_unlock(&g_pageCacheLock);
}

static void ds_note_recent_locked(int slot) {
    for (int i = 0; i < g_recentCount; i++) {
        if (g_recentPageSlots[i] == slot) {
            for (int j = i; j > 0; j--) g_recentPageSlots[j] = g_recentPageSlots[j - 1];
            g_recentPageSlots[0] = slot;
            return;
        }
    }
    if (g_recentCount < DS_RECENT_SLOTS) g_recentCount++;
    for (int j = g_recentCount - 1; j > 0; j--) g_recentPageSlots[j] = g_recentPageSlots[j - 1];
    g_recentPageSlots[0] = slot;
}

static void ds_release_page_slot_locked(int i) {
    if (i < 0 || i >= DS_PAGE_CACHE_SLOTS) return;
    if (g_pageCache[i].localAddr) {
        mach_vm_deallocate(mach_task_self_,
                           (mach_vm_address_t)g_pageCache[i].localAddr,
                           PAGE_SIZE);
    }
    if (g_pageCache[i].port) {
        mach_port_deallocate(mach_task_self_,
                             (mach_port_name_t)g_pageCache[i].port);
    }
    g_pageCache[i].pageVA = 0;
    g_pageCache[i].localAddr = 0;
    g_pageCache[i].port = 0;
    g_pageCache[i].lastUse = 0;
    g_pageCache[i].bornMs = 0;
    g_pageCache[i].lastUseMs = 0;
    g_pageCache[i].gen = 0;
    g_pageCache[i].useCount = 0;
}

// Monotonic milliseconds. Not wall clock: a clock jump must not expire the
// whole cache at once.
static uint64_t ds_now_ms(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return (mach_absolute_time() * tb.numer / tb.denom) / 1000000ULL;
}

void ds_begin_read_transaction(void) {
    ds_lock();
    g_readTxnDepth++;
    ds_unlock();
}

void ds_end_read_transaction(void) {
    ds_lock();
    if (g_readTxnDepth > 0) g_readTxnDepth--;
    // Fl0rk soft-age — never full per-frame flush (that caused RW-lock panics).
    if (g_readTxnDepth == 0) {
        for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
            if (g_pageCache[i].useCount > 0) g_pageCache[i].useCount >>= 1;
        }

        // Expire mappings the game has stopped reading. The reference
        // implementation carries a per-slot clock (shmemClock[256]) plus an
        // eviction counter (shmemEvictions); this is the same shape. Without it
        // a recycled VA is served from the same mapping forever, which is the
        // "boxes are pinned to one direction" symptom.
        //
        // The clock is per-slot-last-use, not per-slot-insert. It used to be
        // bornMs, which meant a mapping the game touched every single frame was
        // still dropped the moment it reached two seconds old, and the next read
        // of it went back through vm_map_remote_page. With a working set of any
        // size that is the whole working set being remapped, and it happens on
        // a two second timer, which reads as a hitch that arrives on its own
        // schedule rather than as a cost. The VA the TTL actually needs to catch
        // is one nothing has read for a while, and lastUseMs is that test.
        //
        // Only DS_MAX_EVICT_PER_TXN are dropped per transaction. The total per
        // second is still ample — the render loop runs at ~60 Hz, so 4 per
        // transaction is ~240 per second against a 256 slot cache — but the
        // mach_port_deallocate calls stay spread out in time, which is the part
        // that used to panic.
        uint64_t nowMs = ds_now_ms();
        int evicted = 0;
        for (int i = 0; i < DS_PAGE_CACHE_SLOTS && evicted < DS_MAX_EVICT_PER_TXN; i++) {
            if (!g_pageCache[i].localAddr) continue;
            if (nowMs - g_pageCache[i].lastUseMs < DS_PAGE_TTL_MS) continue;
            ds_release_page_slot_locked(i);
            evicted++;
        }
        g_dsEvictCount += (uint64_t)evicted;

        // 1 Hz. remaps and evictions are the two halves of the TTL trade: a TTL
        // that is too long leaves stale pages in place, one that is too short
        // burns CPU on vm_map_remote_page. These two rates are what tells them
        // apart on device.
        static uint64_t s_lastReportMs = 0;
        if (nowMs > s_lastReportMs + 1000ULL) {
            static uint64_t s_lastRemapCount = 0;
            static uint64_t s_lastEvictCount = 0;
            uint64_t remapDelta = g_dsRemapCount - s_lastRemapCount;
            uint64_t evictDelta = g_dsEvictCount - s_lastEvictCount;
            int live = 0;
            for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
                if (g_pageCache[i].localAddr) live++;
            }
            NSLog(@"[DS-TLB] ttl=%llums live=%d remaps=%llu evicts=%llu",
                  (unsigned long long)DS_PAGE_TTL_MS, live,
                  (unsigned long long)remapDelta,
                  (unsigned long long)evictDelta);
            s_lastReportMs = nowMs;
            s_lastRemapCount = g_dsRemapCount;
            s_lastEvictCount = g_dsEvictCount;
        }
    }
    ds_unlock();
}

// Map+cache insert MUST stay under g_pageCacheLock (Fl0rk NSRecursiveLock scope).
// Unlocking before vm_map_remote_page raced kwrite_zone_element →
// "Taking non-sleepable RW lock with preemption enabled".
static uint64_t ds_page_local(uint64_t pageVA) {
    ds_lock();

    if (g_degraded) {
        // A cooldown, not a latch.
        //
        // This used to stay true until something called ds_detach or
        // ds_flush_page_cache, and ds_detach only runs on a pid change. So three
        // failed vm_map_remote_page calls — which is three pages the kernel would
        // not hand over, and under a match's allocation rate that is a normal
        // moment, not an exception — blinded every read in the process: ds_rw_remap
        // and ds_read_uncached both return false on g_degraded, so the player
        // dictionary, the HP pool and the bones all read as zero.
        //
        // That is the reported instability exactly: it works, then after a while
        // in the same match the targets stop being found, and it stays that way
        // until the session is restarted. Nothing in the log said why, because the
        // degrade line is the only trace and it reads like a deliberate decision.
        //
        // Dropping the page cache on the way in is the other half: a mapping the
        // kernel no longer honours is the likeliest reason the remap failed, and
        // keeping it is what made the next attempt fail too.
        if (ds_now_ms() < g_degradedUntilMs) {
            ds_unlock();
            return 0;
        }
        g_degraded = false;
        g_consecutiveMapFailures = 0;
        for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
            ds_release_page_slot_locked(i);
        }
        g_pageCacheNext = 0;
        g_recentCount = 0;
        g_dsRemapCount++;
        g_dsRecoverCount++;
        NSLog(@"[DS] degraded cooldown over — retrying remap with an empty cache");
    }

    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        // The generation test is what makes ds_cache_bump_generation mean
        // anything. It used to increment a counter that nothing consulted on the
        // hit path, so a bump was a diagnostic label rather than an
        // invalidation, and every mapping the previous match left behind kept
        // being handed back: the slot matched on pageVA, the VA was still in
        // range, and the frozen bytes came straight out of a freed vm_object.
        //
        // ds_flush_page_cache releases the slots outright, so it is the stronger
        // of the two and the ESP calls both. This is the belt to that pair: a
        // mapping that slips past the flush still cannot be served once the
        // generation has moved, and a stale slot here is skipped rather than
        // evicted, so the replacement is mapped on the normal miss path.
        if (g_pageCache[i].pageVA == pageVA && g_pageCache[i].localAddr &&
            g_pageCache[i].gen == g_cacheGeneration) {
            if (g_pageCache[i].useCount < 0xFFFFFFFFu) g_pageCache[i].useCount++;
            g_pageCache[i].lastUse = g_pageUseCounter++;
            // Stamped on every hit. This is what the TTL is measured against,
            // so a page the game is reading every frame never ages out.
            g_pageCache[i].lastUseMs = ds_now_ms();
            ds_note_recent_locked(i);
            uint64_t a = g_pageCache[i].localAddr;
            ds_unlock();
            return a;
        }
    }

    // Prefer empty slot; else coldest among recent window then global next.
    int victim = -1;
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        if (g_pageCache[i].localAddr == 0 && g_pageCache[i].port == 0) {
            victim = i;
            break;
        }
    }
    if (victim < 0) {
        uint64_t bestUse = UINT64_MAX;
        int window = g_recentCount > 0 ? g_recentCount : DS_RECENT_SLOTS;
        for (int k = 0; k < window; k++) {
            int i = (g_recentCount > 0)
                ? g_recentPageSlots[k]
                : ((g_pageCacheNext + k) % DS_PAGE_CACHE_SLOTS);
            if (i < 0 || i >= DS_PAGE_CACHE_SLOTS) continue;
            uint64_t score = g_pageCache[i].lastUse;
            if (score < bestUse) { bestUse = score; victim = i; }
        }
        if (victim < 0) victim = g_pageCacheNext % DS_PAGE_CACHE_SLOTS;
    }

    // Hold lock through remap — Fl0rk does not drop lock around map.
    struct VMShmem page = vm_map_remote_page(g_ff_map, pageVA);
    if (!page.localAddress) {
        if (page.port) {
            mach_port_deallocate(mach_task_self_, (mach_port_name_t)page.port);
        }
        g_consecutiveMapFailures++;
        if (g_consecutiveMapFailures >= DS_FAIL_DEGRADE_THRESHOLD) {
            g_degraded = true;
            g_degradedUntilMs = ds_now_ms() + DS_DEGRADE_COOLDOWN_MS;
            NSLog(@"[DS] degraded after %llu consecutive map failures — pausing remap "
                  @"for %dms, cache dropped on the way back in",
                  (unsigned long long)g_consecutiveMapFailures, DS_DEGRADE_COOLDOWN_MS);
        }
        ds_unlock();
        return 0;
    }

    g_consecutiveMapFailures = 0;
    if (g_pageCache[victim].localAddr || g_pageCache[victim].port) {
        ds_release_page_slot_locked(victim);
    }
    g_pageCache[victim].pageVA = pageVA;
    g_pageCache[victim].localAddr = page.localAddress;
    g_pageCache[victim].port = page.port;
    g_pageCache[victim].gen = g_cacheGeneration;
    g_pageCache[victim].useCount = 1;
    g_pageCache[victim].lastUse = g_pageUseCounter++;
    g_pageCache[victim].bornMs = ds_now_ms();
    g_pageCache[victim].lastUseMs = g_pageCache[victim].bornMs;
    g_dsRemapCount++;
    ds_note_recent_locked(victim);
    g_pageCacheNext = (victim + 1) % DS_PAGE_CACHE_SLOTS;
    uint64_t a = page.localAddress;
    ds_unlock();
    return a;
}

static bool ds_rw_remap(uint64_t va, void *buf, size_t len, bool isWrite) {
    if (!K(g_ff_map) || !va || !buf || !len) return false;
    if (g_degraded) return false;

    uint8_t *p = (uint8_t *)buf;
    uint64_t cur = va;
    size_t remain = len;

    while (remain > 0) {
        uint64_t page_va  = cur & ~PAGE_MASK;
        uint64_t page_off = cur & PAGE_MASK;
        size_t chunk = PAGE_SIZE - page_off;
        if (chunk > remain) chunk = remain;

        uint64_t localAddr = ds_page_local(page_va);
        if (!localAddr) return false;

        void *local = (void *)(uintptr_t)(localAddr + page_off);
        if (isWrite) memcpy(local, p, chunk);
        else memcpy(p, local, chunk);

        p += chunk; cur += chunk; remain -= chunk;
    }
    return true;
}

bool ds_read(uint64_t va, void *buf, size_t len) {
    return ds_rw_remap(va, buf, len, false);
}

bool ds_write(uint64_t va, const void *buf, size_t len) {
    return ds_rw_remap(va, buf, len, true);
}

uint8_t  ds_read8(uint64_t va)  { uint8_t v=0;  ds_read(va,&v,1); return v; }
uint16_t ds_read16(uint64_t va) { uint16_t v=0; ds_read(va,&v,2); return v; }
uint32_t ds_read32(uint64_t va) { uint32_t v=0; ds_read(va,&v,4); return v; }
uint64_t ds_read64(uint64_t va) { uint64_t v=0; ds_read(va,&v,8); return v; }
float    ds_readf(uint64_t va)  { float v=0;    ds_read(va,&v,4); return v; }

uint64_t ds_readptr(uint64_t va) { return xpaci(ds_read64(va)); }

bool ds_read_str(uint64_t va, char *out, size_t maxlen) {
    if (!ds_read(va, out, maxlen)) return false;
    out[maxlen-1] = 0;
    return true;
}

#pragma mark - accessors

void ds_detach(void) {
    ds_lock();
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        ds_release_page_slot_locked(i);
    }
    g_pageCacheNext = 0;
    g_recentCount = 0;
    g_consecutiveMapFailures = 0;
    g_degraded = false;
    ds_unlock();
    g_ff_proc = g_ff_task = g_ff_base = 0;
    g_ff_map = 0;
    g_ff_pid = 0;
    g_cached_entry = 0;
}


// Deliberately outside the page cache. It maps, copies and unmaps, so it can
// never be the reason a value looks frozen, and it never consumes a cache slot.
// Holding the lock across the map is the same rule ds_page_local follows:
// dropping it around the remap raced kwrite_zone_element.
bool ds_read_uncached(uint64_t va, void *buf, size_t len) {
    if (!K(g_ff_map) || !va || !buf || !len) return false;
    if (g_degraded) return false;

    const uint64_t pageVA = va & ~((uint64_t)PAGE_SIZE - 1);
    const size_t off = (size_t)(va - pageVA);
    if (off + len > (size_t)PAGE_SIZE) return false;

    ds_lock();
    struct VMShmem page = vm_map_remote_page(g_ff_map, pageVA);
    bool ok = false;
    if (page.localAddress) {
        memcpy(buf, (const void *)(page.localAddress + off), len);
        ok = true;
    }
    if (page.localAddress) {
        mach_vm_deallocate(mach_task_self_,
                           (mach_vm_address_t)page.localAddress, PAGE_SIZE);
    }
    if (page.port) {
        mach_port_deallocate(mach_task_self(), (mach_port_name_t)page.port);
    }
    ds_unlock();
    return ok;
}

void ds_flush_page_cache(void) {
    ds_lock();
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        ds_release_page_slot_locked(i);
    }
    g_pageCacheNext = 0;
    g_recentCount = 0;
    g_pageUseCounter++;
    ds_unlock();
    // The single-entry cache holds a raw vm_map_entry pointer. After the map is
    // rebuilt that entry is freed, and the [start,end) range it cached will
    // still be hit by ds_translate_page() on the new map -- serving a dangling
    // object pointer. It has to go too, and it is touched outside ds_lock().
    g_cached_entry = 0;
    g_cached_start = 0;
    g_cached_end = 0;
    g_cached_object = 0;
    g_cached_obj_offset = 0;
}

// Bumped by the ESP layer the moment the match pointer changes. A new match
// means the game tore down and rebuilt its address space, so every mapping
// taken before that point is pointing at memory the game has already freed.
void ds_cache_bump_generation(void) {
    ds_lock();
    g_cacheGeneration++;
    ds_unlock();
}

DSPageCacheDiag ds_page_cache_diag(void) {
    DSPageCacheDiag d = {0, 0, 0};
    ds_lock();
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        if (!g_pageCache[i].localAddr) continue;
        d.liveSlots++;
        if (g_pageCache[i].gen < g_cacheGeneration) d.staleGen++;
    }
    d.generation = g_cacheGeneration;
    ds_unlock();
    return d;
}

bool ds_attached(void) { return K(g_ff_task); }
uint64_t ds_base(void) { return g_ff_base; }
pid_t    ds_pid(void)  { return g_ff_pid; }
mach_port_t ds_task_port(void) { return MACH_PORT_NULL; } // unused in DS mode
