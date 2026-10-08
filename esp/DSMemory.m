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

// Minimum wall-clock gap between two base walks. Long enough that a walk which
// cannot succeed costs a fraction of the main queue instead of all of it, short
// enough that a game which appears is still picked up promptly. Declared here
// rather than with the other cache constants because ds_attach, near the top of
// this file, is what enforces it.
#define DS_ATTACH_RETRY_MS 5000ULL

static uint64_t ds_now_ms(void);      // defined with the cache, below
static uint64_t g_lastBaseWalkMs = 0; // when the last base walk ran

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
    // "Already attached" has to mean "already attached AND usable", not merely
    // "g_ff_task is non-zero".
    //
    // g_ff_task is assigned at the line below that reads proc_ro->pr_task, which
    // is BEFORE the base walk. Every failure from there to the end of the walk --
    // proc_ro, task, map, nentries, first entry, no base -- returns -1 with
    // g_ff_task still set. So one failed attempt left ds_attached() -- a bare
    // K(g_ff_task) -- answering true for the rest of the process, this early-out
    // returned 0 without walking anything, and the ds_detach() reset further down,
    // which exists for exactly this, was unreachable behind it.
    //
    // Requiring g_ff_base is what lets that reset run on the retry.
    //
    // What the latch looks like from outside: the game exits and the ESP keeps the
    // module base it had; a new game starts and this attach finds the process but
    // fails the base walk; g_ff_task is now set, so from here on nothing re-walks
    // anything and Moudule_Base stays pointed at an address space that no longer
    // exists. Every read then returns something that fails isVaildPtr, which is
    // indistinguishable from a broken offset table -- getMatchGame's nine
    // candidates all read invalid and the chain reports a lobby forever. It also
    // matches the only thing that reliably recovered it: toggling the ESP off and
    // on, because that is the one path that re-runs an attach from a clean state.
    if (ds_attached() && g_ff_base) return 0;
    if (!g_kexploit_ready) return -1;

    // The base walk is the expensive part of attaching and it is not affordable at
    // any rate the ESP tick can drive, so it limits itself here, in wall clock,
    // where no call site can bypass it.
    //
    // The call site had a frame counter set to 30, commented "~0.5s at 60fps", which
    // is two full walks a second on the main queue. That is how a walk which used to
    // run once and then latch on failure turned into a repeating hang after
    // ds_attach was allowed to retry at all: MINHDUC was SIGKILLed by the watchdog on
    // the main thread 35 seconds after launch, with the stack in
    // vm_map_iterate_entries -> early_kread -> setsockopt.
    //
    // Gated on g_ff_task being set, so the cheap "game is not running" case still
    // returns immediately and a launch is still picked up promptly. Only a walk that
    // actually ran and failed is worth spacing out.
    const uint64_t nowAttachMs = ds_now_ms();
    if (g_ff_task != 0 && g_ff_base == 0 &&
        nowAttachMs - g_lastBaseWalkMs < DS_ATTACH_RETRY_MS) {
        return -1;
    }
    g_lastBaseWalkMs = nowAttachMs;

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
            // Resolve from the entry this loop is already holding. It used to call
            // vm_map_remote_page, which looks the address up by walking the whole map
            // again -- so this walk was quadratic, with both walks' every step going
            // through the socket kernel-read primitive. On the main queue, twice a
            // second, that is a watchdog kill, and it was measured as one.
            struct VMObject probe =
                vm_get_object_from_entry(e, start & ~0x3FFFULL);
            struct VMShmem page = probe.address
                ? vm_create_shmem_with_object(&probe)
                : (struct VMShmem){0};
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
        // Throttled, not one-shot. It used to fire at most once per process, so a
        // user who hit this saw a single line and then permanent silence for the
        // rest of the session -- which is a large part of why the log never said
        // why. Five seconds apart says "still failing" without becoming a second
        // steady line on top of the [GameOffsets] retry line.
        static uint64_t s_lastBaseLogUS = 0;
        const uint64_t tBaseUS = (uint64_t)(CACurrentMediaTime() * 1000000.0);
        if (tBaseUS - s_lastBaseLogUS >= 5000000ULL) {
            s_lastBaseLogUS = tBaseUS;
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

// Upper bound on mappings the sweep judge tears down in one pass, for the same
// reason one level up. ds_vmo_publish_and_judge runs under g_pageCacheLock, and
// ds_release_page_slot_locked deallocates a memory entry and a port, so a pass
// that surfaced a whole region going away used to hold the lock across up to
// DS_PAGE_CACHE_SLOTS pairs of those. The frame that was reading when the pass
// completed waited the whole batch out, which is a hitch that arrives on the
// sweep's schedule and clears by itself -- the same "freezes for a moment, then
// catches up" the TTL evictor was already bounded against.
//
// A slot past the bound is judged again on the next pass and still dropped
// then, because the mismatch that put it in this set cannot heal: the vmo the
// slot carries is the one that was live when it was mapped, and the map has
// moved on. The pass completes in a couple of hundred milliseconds normally, so
// the surplus costs one more cycle at most and the lock is never held across
// more than this many deallocations.
#define DS_MAX_VMO_DROP_PER_PASS 16

// ---------------------------------------------------------------------------
// The one failure nothing else can see: a mapping of a page the game has freed.
//
// vm_map_remote_page maps the game's own vm_object with copy=FALSE, so the mapping
// is a live alias of that physical frame rather than a snapshot. Worth stating
// plainly because it rules out the theory this work was built on: the game's writes
// to a mapped page are visible immediately, and the resolution chain does resolve on
// its own the moment the game writes the match pointer. Any explanation that has the
// cache serving old bytes while the game writes new ones underneath it is wrong for
// this read path.
//
// The mapping dies exactly one way. The game frees the page, the allocator hands the
// address out again, and our memory entry still maps the old physical frame. Nothing
// about that is observable from here: isVaildPtr is a range check on the VA, the slot
// matches on pageVA, and a mapping of freed memory is still a perfectly good pointer.
// The read then returns whatever now occupies that frame, the chain never resolves,
// and the only thing that recovers it is dropping the cache -- which is why toggling
// the ESP off and on was what made it come back. Whether a given match hit that is
// the allocator's business, which is exactly why it looked arbitrary.
//
// vm_map_entry carries the vm_object a page is backed by, and the game changes that
// pointer when it frees the page. Record it, compare it later, and a leftover from a
// dead address space cannot be served. That is the only check available that does not
// have to guess when a boundary happened.
//
// The first version of this check (401858e9d, reverted) asked the map once per
// second PER SLOT, plus once per remap, and every question was a fresh walk of the
// whole map from entry 0. Its cost scaled with the slot count, which is what mattered:
// five or six slots in a lobby and well over a hundred on entering a match, and at a
// few thousand map entries that is hundreds of thousands of syscalls a second on the
// main queue. That is why it was abandoned rather than the idea.
//
// So the same question is answered once per pass: one walk produces a snapshot of
// (start, end, object) per map entry, spread over frames, and every later question is
// a lookup in that array -- no syscalls. The walk never runs on the read path or the
// insert path. Steady cost is DS_VMO_SWEEP_PER_TICK entries per frame regardless of
// how many slots are live, and the judgement at the end of a pass is arithmetic.
// How many map entries are walked per frame. This is the entire cost of the
// dead-mapping check and it is a constant: it does not scale with the slot count, the
// read rate, or how long a match has run.
//
// It used to be 64 every five seconds instead of 256 continuously, and the device log
// says exactly what that bought:
//
//   sweeps=1..8 over 50s, !vmo dropped 0 dead and 26 orphaned, then 26 dead, then 26
//   orphaned again -- one drop of about 26 mappings every six to seven seconds
//
// Twenty-six mappings is about a tenth of the table, so roughly a tenth of the cache
// was serving a page the game had freed, and the oldest of those was six seconds old.
// A mapping of a freed page is not a failed read: it is a successful read of whatever
// the allocator left behind. Nothing on the read path can see it -- isVaildPtr is a
// range check on the VA, the slot matches on pageVA -- so the frame drew last frame's
// transform, and again the frame after. That is "the ESP stands still and then
// updates" and "the ESP hangs in the air", and the update arriving in six-second
// bursts is the sweep coming round, not the game.
//
// So the pass does not rest. It walks a slice every frame and restarts the instant it
// finishes, which turns the interval between noticing a dead mapping from six seconds
// into one cycle -- a couple of hundred milliseconds -- at a cost that is a few
// hundred kernel reads per frame against the ~17,000 the render loop already makes.
#define DS_VMO_SWEEP_PER_TICK 256
#define DS_VMO_SNAP_MAX       16384
// Backoff before restarting after the map could not be read at all, so a torn or
// absent map does not become a kread per frame.
#define DS_VMO_RESTART_MS     2000ULL

typedef struct { uint64_t start, end, object; } DSVmoRange;

// Two buffers. One is being filled and the other is the one every lookup answers
// from, and they swap when a pass completes.
//
// A single buffer cannot do this. The pass takes several frames, so the array is a
// prefix for those frames, and a prefix answers "not mapped" for every page in the
// unwalked tail. That is not a small error: it looks identical to the thing this
// whole check exists to find, so asking it mid-pass either drops live mappings
// wholesale or, as the first build had it, files every slot with no baseline and the
// blind count climbs. Double buffering removes the question. A lookup only ever sees
// a finished pass.
static DSVmoRange g_vmoSnap[2][DS_VMO_SNAP_MAX];
static int        g_vmoLive       = 0;   // which buffer lookups read
static uint32_t   g_vmoLiveCount  = 0;
static uint32_t   g_vmoLiveEpochMs = 0;  // when the live buffer finished, for the
                                         // "mapped after this pass" guard
static uint32_t   g_vmoFill       = 0;
static uint32_t   g_vmoTotal      = 0;
static uint64_t   g_vmoCursor     = 0;   // 0 means not currently walking
static bool       g_vmoHaveLive   = false;

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
    // Frame stamp of the most recent hit or insert, compared against
    // g_txnFrameStamp to mean "the frame running right now already read it".
    // Free: useCount alone left four bytes of padding in this struct.
    uint32_t touchedFrame;
    // The vm_object this mapping was taken under, and when the snapshot that
    // answered that was built. Zero means not armed yet.
    uint64_t vmo;
    uint64_t vmoEpochMs;
} g_pageCache[DS_PAGE_CACHE_SLOTS];

// Direct-mapped page -> slot accelerator for the hit path.
//
// ds_page_local scanned all DS_PAGE_CACHE_SLOTS entries on EVERY read, hit or
// miss, to find one whose pageVA matched. A read is ~550,000 per second in a
// survival match, so that is ~140 million slot comparisons per second over an
// 80-byte struct table of 20 KB, which does not stay in L1 -- and all of it
// inside g_pageCacheLock, the lock the render thread on the main queue,
// SilentAimThread and AimLockThreadMain all contend for.
//
// This is an accelerator, NOT a replacement. g_pageIndex only ever names a slot
// that really holds that pageVA; a collision, or an entry cleared by a release
// that missed its probe, simply falls through to the original scan. Behaviour is
// identical either way, and the scan is what keeps it that way.
//
// Direct-mapped rather than open addressing on purpose: 256 entries over a power
// of two, and the fallback already exists, so extra buckets would buy nothing.
//
// -1 means empty. Every read and write of this array is under g_pageCacheLock,
// same as g_pageCache itself.
static int32_t     g_pageIndex[DS_PAGE_CACHE_SLOTS];

static inline int ds_page_index_hash(uint64_t pageVA) {
    // The page offset must be shifted out before any bits are taken, and that is
    // not a style choice. pageVA is masked to a PAGE_SIZE boundary, and PAGE_SIZE
    // is 0x4000 (PAGE_SHIFT 14), so its low fourteen bits are always zero:
    // `pageVA & 0xFF` returned 0 for every page that was ever probed. Every page
    // wrote bucket 0 of g_pageIndex, every entry but the most recently indexed
    // one missed the probe, and the miss fell straight to the 256-slot scan this
    // probe exists to replace -- on every read, under g_pageCacheLock, which the
    // render thread, SilentAimThread and AimLockThreadMain all contend for.
    return (int)((pageVA >> PAGE_SHIFT) & (uint64_t)(DS_PAGE_CACHE_SLOTS - 1));
}

static inline void ds_page_index_set(uint64_t pageVA, int slot) {
    if (slot < 0 || slot >= DS_PAGE_CACHE_SLOTS) return;
    g_pageIndex[ds_page_index_hash(pageVA)] = (int32_t)slot;
}

// Drop this slot's index entry if it still names it. The slot's pageVA is read
// BEFORE the caller clears it, so a slot that is being evicted for a different
// page drops the right entry. A collision victim leaves another page's index
// entry pointing at the reused slot; that entry fails its pageVA check and falls
// back to the scan, which is correct.
static inline void ds_page_index_drop(int slot) {
    if (slot < 0 || slot >= DS_PAGE_CACHE_SLOTS) return;
    const uint64_t pva = g_pageCache[slot].pageVA;
    if (pva == 0) return;
    const int h = ds_page_index_hash(pva);
    if (g_pageIndex[h] == (int32_t)slot) g_pageIndex[h] = -1;
}

// Bumped on every match change by the ESP layer; see ds_cache_bump_generation.
static uint64_t g_cacheGeneration = 1;
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
// Bumped once per outermost transaction, i.e. once per ESP frame.
static uint64_t g_txnFrameStamp = 1;
// A read refused because every slot in the table was already read this frame. This
// is the direct measurement of "the working set exceeds the table", and it is what
// would justify a bigger table rather than a bigger read budget.
static uint64_t g_dsNoVictimCount = 0;
// Hits and misses per second. `live` cannot tell a saturated cache from a barely
// read one; these can.
static uint64_t g_dsHitCount = 0;
static uint64_t g_dsMissCount = 0;
// True if some read path was refused this second, sampled by the report so a
// second with no hits and no remaps is attributable.
static bool g_dsBlockedLastSecond = false;
// Sampled once a second, so the status line can report "a read was refused during the
// last second" rather than an instantaneous value that is almost always false.
static int g_dsBlockedLast = 0;
// Mappings dropped because the map now names a different object behind that address.
static uint64_t g_dsStaleDropCount = 0;
// Mappings dropped because the whole map contains nothing at that address, which
// means the game unmapped the page and our own memory entry was the last reference
// holding the physical frame alive.
static uint64_t g_dsOrphanDropCount = 0;
// Live slots with no baseline yet, as a gauge rather than a running total.
static uint32_t g_dsVmoBlindNow = 0;
// Completed passes. If this stops climbing, the check is not running and anything else
// it has to say is void.
static uint64_t g_dsSweepCount = 0;
// When the last pass finished, so the drop line can say how stale anything it did not
// catch is. This is the whole quality measure of the dead-mapping check.
static uint64_t g_dsLastSweepMs = 0;

static void ds_page_cache_lock_init(void) {
    // Every entry starts empty, so a miss is one comparison instead of a scan
    // through slots nobody has ever populated.
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) g_pageIndex[i] = -1;
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

// There used to be a recent-slot ring here, eight entries long, that every hit
// updated and that the eviction victim was chosen from. Choosing the coldest slot
// inside a ring of the most recently touched slots evicts the eighth-hottest page
// in a 256-entry table, which is worse than useless once the table is full, so the
// ring went with it: the scan is now over the whole table and the ring had no
// other reader. Keeping it would have meant a linear scan and an eight-int memmove
// on the hit path for a value nothing looked at.

static void ds_release_page_slot_locked(int i) {
    if (i < 0 || i >= DS_PAGE_CACHE_SLOTS) return;
    // Before the fields are cleared: ds_page_index_drop reads this slot's pageVA.
    ds_page_index_drop(i);
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
    g_pageCache[i].vmo = 0;
    g_pageCache[i].vmoEpochMs = 0;
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

// Clear a degrade whose cooldown has run out. Must be called under the lock.
//
// This exists because clearing the flag inside ds_page_local did not work, and not
// because clearing it twice is nice. Both read paths refused on g_degraded before
// ds_page_local was ever entered, so the recovery branch in there could not be
// reached from a read: the gate made the only code that could release the latch
// unreachable from every caller of it.
//
// The consequence was that g_degraded was written false in exactly two places, that
// dead branch and ds_detach -- which only runs on a pid change. ds_flush_page_cache
// did not clear it either. So three consecutive failed vm_map_remote_page calls
// meant every read in the process returned zero until the app was restarted, while
// the log said "pausing remap for 250ms".
//
// That is the device line this explains. live=37, remaps=0, evicts=16: reads were
// refused, so nothing was mapped, and ds_end_read_transaction is not gated on the
// flag so it kept evicting four per transaction against a table nothing could
// refill. It is not a cache under pressure. It is a cache nobody was allowed to
// fill.
//
// ds_begin_read_transaction is the right place to close it because it is the one
// hook that runs every frame regardless of what the read path decides: esp.mm calls
// it unconditionally at 3925, before it knows whether there is anything to read.
// Latch lifetime becomes the cooldown the log claims.
static void ds_expire_degrade_locked(void) {
    if (!g_degraded) return;
    if (ds_now_ms() < g_degradedUntilMs) return;
    int liveAtResume = 0;
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        if (g_pageCache[i].localAddr) liveAtResume++;
    }
    g_degraded = false;
    g_consecutiveMapFailures = 0;
    g_dsRecoverCount++;
    static uint64_t s_lastRecLogMs = 0;
    const uint64_t tRec = ds_now_ms();
    if (tRec - s_lastRecLogMs >= 1000ULL) {
        s_lastRecLogMs = tRec;
        NSLog(@"[DS] degraded cooldown over — resuming with %d mapping(s) intact, "
              @"recovery #%llu", liveAtResume,
              (unsigned long long)g_dsRecoverCount);
    }
}

// Binary search for the entry covering this page.
//
// Sorted by start, so this is O(log n). The previous linear scan was O(n) and the
// judgement asks it once per slot, so with a snapshot of a few thousand entries and a
// full 256-slot table this was on the order of a million comparisons every cycle --
// now every 0.2s rather than every 6s. Sorting is what makes asking more often
// affordable; the map is walked in whatever order the kernel keeps it, which is not
// address order.
//
// known distinguishes "no completed pass yet" from "a completed pass covers the whole
// map and nothing covers this address". Those are different claims and the difference
// is the entire orphan case, so they are not collapsed into one zero.
static uint64_t ds_vmo_lookup(uint64_t page_va, bool *known) {
    if (known) *known = g_vmoHaveLive;
    if (!g_vmoHaveLive) return 0;
    const uint64_t p = page_va & ~(uint64_t)(PAGE_SIZE - 1);
    const DSVmoRange *a = g_vmoSnap[g_vmoLive];
    uint32_t lo = 0, hi = g_vmoLiveCount;
    while (lo < hi) {
        const uint32_t mid = lo + (hi - lo) / 2;
        if (a[mid].end <= p) {
            lo = mid + 1;
        } else if (a[mid].start > p) {
            hi = mid;
        } else {
            return a[mid].object;
        }
    }
    return 0;
}

// What may be recorded as a baseline right now. Zero means no completed pass to answer
// from, or that the pass does not cover the page; either way the next one arms it.
static uint64_t ds_vmo_recordable(uint64_t page_va) {
    bool known = false;
    return ds_vmo_lookup(page_va, &known);
}

static int ds_vmo_cmp(const void *a, const void *b) {
    const uint64_t x = ((const DSVmoRange *)a)->start;
    const uint64_t y = ((const DSVmoRange *)b)->start;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}

// One tick of an incremental pass over the game's vm_map, then the judgement.
//
// Called under the lock, from the outermost read transaction, so at most once a frame
// and never inside a read.
//
// The judgement is one-directional on purpose. A snapshot describes one instant and
// can name an object a live page no longer has, and that drops a live mapping and
// costs one remap. The reverse cannot happen: the snapshot is read from the live map,
// so once the game has replaced the object the snapshot names the new one. Being
// wrong here costs a mapping, never a read.
// Walks the next slice of the map and returns true once a whole pass has been
// filled. Deliberately runs WITHOUT g_pageCacheLock.
//
// This is the syscall-heavy half: DS_VMO_SWEEP_PER_TICK map entries at four kernel
// reads each, ~1024 setsockopt calls, once per frame. It touches no cache slot
// whatever -- only the walk cursor, the fill count and g_vmoSnap[build], where
// build is 1 - g_vmoLive, i.e. the buffer that is NOT the live one. Readers search
// g_vmoSnap[g_vmoLive], so the slice being filled is never the slice being read.
//
// Holding g_pageCacheLock across this made every remote read in the process -- the
// render thread on the main queue, SilentAimThread, AimLockThreadMain -- queue
// behind those syscalls once a frame. ds_page_cache_lock_init, the hit scan and the
// judge below all sit inside that same lock, so its hold time is the whole frame
// cost.
//
// Only the outermost ds_end_read_transaction calls this, and exactly one thread
// can be that outermost caller, so the cursor and fill count stay single-writer.
static bool ds_vmo_walk_tick(uint64_t nowMs) {
    // Every path out of here returns false explicitly. A bare `return;` from a
    // bool function is undefined, and true would mean "a whole pass is ready" for a
    // pass holding nothing -- which publishes an empty snapshot and then judges all
    // 256 live slots as unmapped.
    if (!K(g_ff_task)) return false;

    // Start a pass if none is running. g_vmoCursor == 0 is that state, which is why a
    // completed pass clears it and lets the next tick begin another: the walk is
    // continuous by construction rather than by a timer that can be starved.
    if (g_vmoCursor == 0) {
        const uint64_t hdr = kread_ptr(g_ff_task + off_task_map) + off_vm_map_hdr;
        const uint32_t nentries = kread32(hdr + off_vm_map_header_nentries);
        if (nentries == 0 || nentries > DS_VMO_SNAP_MAX) {
            // Cannot hold it. Say so rather than truncating: a partial map reports "not
            // mapped" for everything past the cut and drops live mappings wholesale.
            static uint32_t s_oversizeLogged = 0;
            static uint64_t s_oversizeNextMs = 0;
            if (s_oversizeLogged < 3 && nowMs >= s_oversizeNextMs) {
                s_oversizeLogged++;
                s_oversizeNextMs = nowMs + DS_VMO_RESTART_MS;
                NSLog(@"[ESP] !vmo cannot run: vm_map has %u entries, this build holds %d",
                      nentries, DS_VMO_SNAP_MAX);
            }
            return false;
        }
        g_vmoTotal  = nentries;
        g_vmoFill   = 0;
        g_vmoCursor = kread_ptr(hdr + off_vm_map_header_links_next);
        if (!K(g_vmoCursor)) return false;
    }

    const int build = 1 - g_vmoLive;
    DSVmoRange *a = g_vmoSnap[build];
    for (uint32_t n = 0; n < DS_VMO_SWEEP_PER_TICK; n++) {
        if (g_vmoFill >= g_vmoTotal) break;
        if (!K(g_vmoCursor)) break;
        a[g_vmoFill].start  = kread64(g_vmoCursor + E_START);
        a[g_vmoFill].end    = kread64(g_vmoCursor + E_END);
        a[g_vmoFill].object = kread_ptr(g_vmoCursor + E_OBJECT);
        g_vmoFill++;
        g_vmoCursor = kread_ptr(g_vmoCursor + off_vm_map_entry_links_next);
    }

    if (g_vmoFill < g_vmoTotal) {
        if (!K(g_vmoCursor)) {
            // The list ended early -- the map was rebuilt under us. Half a map is worse
            // than none, so this buffer is discarded and the live one keeps serving.
            g_vmoFill   = 0;
            g_vmoCursor = 0;
        }
        return false;   // mid-pass: the live buffer is untouched and still answering
    }

    return true;
}

// Publishes the finished snapshot and judges every slot against it. Caller holds
// g_pageCacheLock, and must only be reached for the build that ds_vmo_walk_tick
// filled -- which is 1 - g_vmoLive, recomputed here and unchanged, because nothing
// else writes g_vmoLive.
//
// The other half of the old sweep, and free of syscalls: ds_vmo_lookup is a binary
// search over the published snapshot. It is kept under the lock because it reads and
// writes g_pageCache and calls ds_release_page_slot_locked.
static void ds_vmo_publish_and_judge(uint64_t nowMs) {
    const int build = 1 - g_vmoLive;
    DSVmoRange *a = g_vmoSnap[build];

    // Finished. Sort so lookups are binary, publish it, then judge.
    if (g_vmoFill > 1) {
        qsort(a, g_vmoFill, sizeof(DSVmoRange), ds_vmo_cmp);
    }
    g_vmoLive       = build;
    g_vmoLiveCount  = g_vmoFill;
    g_vmoLiveEpochMs = (uint32_t)nowMs;
    g_vmoHaveLive   = true;
    g_vmoFill       = 0;
    g_vmoCursor     = 0;   // next tick starts the following pass

    uint32_t dropped = 0, judged = 0, armed = 0, orphaned = 0, blind = 0;
    uint32_t deferred = 0;
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        if (!g_pageCache[i].localAddr) continue;
        if (g_pageCache[i].vmo == 0) blind++;
        // A slot mapped after the pass that is now live began would be judged against
        // a map that predates it. It waits one cycle, which is a fraction of a second
        // and is the only case where a live mapping is not checked.
        if (g_pageCache[i].vmoEpochMs > g_vmoLiveEpochMs) continue;
        bool known = false;
        const uint64_t now = ds_vmo_lookup(g_pageCache[i].pageVA, &known);
        if (!known) continue;
        if (g_pageCache[i].vmo == 0) {
            if (now != 0) {
                // A whole map is available now, so this can finally be armed. Slots
                // mapped during warm-up get their baseline here.
                g_pageCache[i].vmo = now;
                armed++;
            } else {
                // The whole map was walked and NOTHING covers this address. That is not
                // "cannot tell": the game has unmapped the page and our own memory entry
                // is the only reference still holding that physical frame alive, so the
                // bytes behind it are whatever the allocator put there next. Keeping it
                // is a slot that serves reads forever -- a valid pointer, matching on
                // pageVA, with no timeout on a pointer.
                //
                // Released only while the pass is under its teardown bound; the rest
                // go with a deferral and are judged again next pass. See
                // DS_MAX_VMO_DROP_PER_PASS for why the bound exists and why a
                // deferral is safe here.
                if (dropped + orphaned >= DS_MAX_VMO_DROP_PER_PASS) { deferred++; continue; }
                orphaned++;
                ds_release_page_slot_locked(i);
            }
            continue;
        }
        judged++;
        if (now != g_pageCache[i].vmo) {
            // Either a different object backs the address now, or the map has no entry
            // covering it and the page is gone.
            if (dropped + orphaned >= DS_MAX_VMO_DROP_PER_PASS) { deferred++; continue; }
            dropped++;
            ds_release_page_slot_locked(i);
        }
    }
    uint32_t blindNow = 0;
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        if (g_pageCache[i].localAddr && g_pageCache[i].vmo == 0) blindNow++;
    }
    g_dsVmoBlindNow    = blindNow;
    g_dsStaleDropCount += dropped;
    g_dsOrphanDropCount += orphaned;
    g_dsSweepCount++;
    if (dropped || orphaned) {
        // Cycle time is the number that matters here: it is how long a dead mapping
        // can be served before this notices. sweepMs is how long ago the previous pass
        // finished.
        //
        // deferred is the slots the bound pushed to the next pass. It is printed
        // rather than left implicit because it is the cost of the bound: a deferred
        // slot serves its stale page for one more cycle, so a nonzero deferred with
        // a cycle time that stays in the hundreds of milliseconds is the bound
        // working, and deferred stuck high with a long cycle is the bound set too
        // low for the teardown rate.
        NSLog(@"[ESP] !vmo dropped %u dead and %u orphaned mapping(s) "
              @"(judged %u, armed %u, blind %u, deferred %u, map=%u, cycle=%llums)",
              dropped, orphaned, judged, armed, blindNow, deferred, g_vmoTotal,
              (unsigned long long)(nowMs - g_dsLastSweepMs));
        g_dsLastSweepMs = nowMs;
    } else {
        g_dsLastSweepMs = nowMs;
    }
}


void ds_page_cache_stats(DSPageCacheStats *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        if (!g_pageCache[i].localAddr) continue;
        out->liveSlots++;
        if (g_pageCache[i].vmo == 0) out->blind++;
    }
    out->blockedLastSecond = g_dsBlockedLast;
    out->degradeActive     = g_degraded ? 1 : 0;
    out->remaps      = g_dsRemapCount;
    out->evicts      = g_dsEvictCount;
    out->hits        = g_dsHitCount;
    out->misses      = g_dsMissCount;
    out->novictim    = g_dsNoVictimCount;
    out->staleDrops  = g_dsStaleDropCount;
    out->orphanDrops = g_dsOrphanDropCount;
    out->sweeps      = g_dsSweepCount;
}

void ds_begin_read_transaction(void) {
    ds_lock();
    // Before the depth bump, so a frame that opens during a cooldown is already
    // un-latched by the time its first read lands.
    ds_expire_degrade_locked();
    g_readTxnDepth++;
    // The frame stamp was declared and read and written, but never advanced. It sat
    // at 1 for the life of the process, so every slot that had ever been used
    // carried touchedFrame == 1 and the victim picker -- which skips any slot whose
    // touchedFrame matches the current stamp, to avoid evicting a page this frame
    // has already read -- skipped all 256 of them unconditionally.
    //
    // The consequence is not a slow cache, it is a frozen one. The table fills, the
    // empty-slot loop finds nothing, the LRU loop finds no candidate, and the
    // function returns 0. Every read of a page outside the resident 256 then fails
    // isVaildPtr forever: those pawns do not draw and do not resolve, which is the
    // "nothing happens for a while" half. The only remaining way a slot comes back
    // is the TTL evictor, capped at DS_MAX_EVICT_PER_TXN per transaction, and it
    // cannot touch the hot slots at all because their lastUseMs is always fresh. So
    // recovery is a slow drip of four slots per frame against a set that needs to
    // rotate around fifty to a hundred players -- and each of those four costs a
    // vm_map_remote_page under g_pageCacheLock. That is the "then it lurches" half.
    //
    // Bumped only on the outermost open, so it means "the frame running right now".
    // ds_begin_read_transaction has exactly one call site and it is unconditional
    // once per frame, which is what makes this the frame boundary.
    if (g_readTxnDepth == 1) g_txnFrameStamp++;
    ds_unlock();
}

void ds_end_read_transaction(void) {
    // Whether this is the outermost transaction is decided under the lock and then
    // the lock is dropped, because the map walk between here and the judge is
    // ~1024 kernel reads that touch no cache slot and had no business making every
    // remote read in the process wait for them.
    //
    // Exactly one caller can be the outermost: g_readTxnDepth is only changed under
    // the lock, and the decrement that reaches zero is done by one thread. That
    // thread is the only one that walks, which is what keeps the walk cursor and the
    // fill count single-writer without a second lock.
    bool outer = false;
    ds_lock();
    if (g_readTxnDepth > 0) g_readTxnDepth--;
    outer = (g_readTxnDepth == 0);
    ds_unlock();
    if (!outer) return;

    const uint64_t sweepNowMs = ds_now_ms();

    // Walks the next slice. No lock, no cache-slot access, no reads from the live
    // snapshot. Returns true when a whole pass has been filled.
    const bool passComplete = ds_vmo_walk_tick(sweepNowMs);

    ds_lock();
    // Fl0rk soft-age — never full per-frame flush (that caused RW-lock panics).
    {
        // Belt and braces on a path that already runs every frame: a session that
        // pairs begin/end correctly releases a cooldown here even if it never
        // opened a transaction while latched.
        ds_expire_degrade_locked();
        // Once per outermost transaction, i.e. at most once a frame, and never
        // inside a read. The alternative -- asking the map per slot, per second --
        // is what made the previous version of this check cost more the more slots a
        // match had.
        //
        // Order is unchanged: the walk above ran first, and only now, with the lock
        // held and the pass it completed sitting in the buffer, is it published and
        // judged. The judge needs the lock because it reads and writes g_pageCache
        // and calls ds_release_page_slot_locked; it costs no syscalls, being a binary
        // search per slot over the snapshot.
        if (passComplete) ds_vmo_publish_and_judge(sweepNowMs);
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
            static uint64_t s_lastHitCount = 0;
            static uint64_t s_lastMissCount = 0;
            static uint64_t s_lastNoVictimCount = 0;
            uint64_t remapDelta = g_dsRemapCount - s_lastRemapCount;
            uint64_t evictDelta = g_dsEvictCount - s_lastEvictCount;
            uint64_t hitDelta  = g_dsHitCount - s_lastHitCount;
            uint64_t missDelta = g_dsMissCount - s_lastMissCount;
            uint64_t novictimDelta = g_dsNoVictimCount - s_lastNoVictimCount;
            int live = 0;
            for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
                if (g_pageCache[i].localAddr) live++;
            }
            // hit/miss is what this line was missing. live is a residency count
            // and nothing more: on device it read 37 to 58 while remaps was 0 and
            // evicts was 16, which is neither a saturated 256-slot table nor an
            // idle one, and those two are only separable with a request rate.
            // novictim says whether the table size is the binding ceiling, so a
            // session that genuinely needs 1024 slots will say so itself.
            // This line used to print itself as [DS-TLB]. It is folded into the
            // single [ESP] status line instead: two tags meant two filters, and one
            // filter was all the device log view had room for -- so the two fields
            // that answer a single question together could never be read off the same
            // line. The cache hit rate and the number of players found are the two
            // halves of "is the shortfall the cache or the walk", and separating them
            // across two tags is what made that question need two screenshots.
            //
            // The sampling stays here rather than moving to the caller, because the
            // blocked flag is only meaningful over a window: it is set by whichever
            // read happened to be refused, and its instantaneous value is almost
            // always false.
            //
            // Deltas are still computed here and discarded, deliberately. Keeping the
            // bookkeeping means the counters stay monotonic across a cache flush, so
            // the line's own differencing cannot be fooled by one.
            (void)live; (void)remapDelta; (void)evictDelta;
            (void)hitDelta; (void)missDelta; (void)novictimDelta;
            g_dsBlockedLast = g_dsBlockedLastSecond ? 1 : 0;
            g_dsBlockedLastSecond = false;
            s_lastReportMs = nowMs;
            s_lastRemapCount = g_dsRemapCount;
            s_lastEvictCount = g_dsEvictCount;
            s_lastHitCount = g_dsHitCount;
            s_lastMissCount = g_dsMissCount;
            s_lastNoVictimCount = g_dsNoVictimCount;
        }
    }
    ds_unlock();
}

// Map+cache insert MUST stay under g_pageCacheLock (Fl0rk NSRecursiveLock scope).
// Unlocking before vm_map_remote_page raced kwrite_zone_element →
// "Taking non-sleepable RW lock with preemption enabled".
// One place that touches a slot on a hit, so the indexed probe and the scan cannot
// drift apart. Returns the local address, or 0 if this slot is not a live hit FOR
// wantVA.
//
// wantVA is the whole point and must not be dropped. The scan calls this for every
// slot in the table, so a version that only tested pageVA != 0 would touch -- and
// return -- whichever slot happened to be occupied, handing back another page's
// mapping for the address that was asked for. wantVA 0 is never a valid remote page
// and localAddr 0 means unmapped, so 0 is an unambiguous "miss".
static inline uint64_t ds_page_hit(int i, uint64_t wantVA) {
    if (g_pageCache[i].pageVA != wantVA || g_pageCache[i].localAddr == 0) return 0;
    if (g_pageCache[i].useCount < 0xFFFFFFFFu) g_pageCache[i].useCount++;
    g_pageCache[i].lastUse = g_pageUseCounter++;
    g_pageCache[i].lastUseMs = ds_now_ms();
    g_pageCache[i].touchedFrame = (uint32_t)g_txnFrameStamp;
    g_dsHitCount++;
    return g_pageCache[i].localAddr;
}

static uint64_t ds_page_local(uint64_t pageVA) {
    ds_lock();

    // Cache hits are served before the degrade gate is even looked at, and that
    // ordering is the point.
    //
    // A degrade means the kernel is refusing to hand over NEW mappings. Pages we
    // already hold are not new mappings and are unaffected by it. The gate used to
    // sit above this loop, so for the length of the 250ms cooldown every read in
    // the process returned zero -- including the 255 good cached pages sitting in
    // the table. That turned a remap pause into a total blackout: isVaildPtr(0)
    // fails, so every pawn is skipped, every path comes out empty, and the counter
    // prints "--", with nothing on the ESP side to say why. The only trace was the
    // degrade line itself.
    //
    // So the loop moved up. A hit is served, and only a miss has to wait out the
    // cooldown.
    // One indexed probe first, then the scan it replaces. The probe cannot answer
    // wrongly: it only reports a hit when the slot it names really holds this
    // pageVA, so a stale or colliding entry costs one comparison and falls through.
    {
        const int32_t cand = g_pageIndex[ds_page_index_hash(pageVA)];
        if (cand >= 0 && cand < DS_PAGE_CACHE_SLOTS) {
            const uint64_t aIndexed = ds_page_hit((int)cand, pageVA);
            if (aIndexed) {
                ds_unlock();
                return aIndexed;
            }
        }
    }

    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        const uint64_t aHit = ds_page_hit(i, pageVA);
        if (aHit) {
            // Found by scan, so teach the index for next time.
            ds_page_index_set(pageVA, i);
            ds_unlock();
            return aHit;
        }
    }

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
        // The cache is NOT dropped on the way back in. That used to be the stated
        // plan -- "a mapping the kernel no longer honours is the likeliest reason
        // the remap failed, and keeping it is what made the next attempt fail too"
        // -- and it is what turned a pause into a loop.
        //
        // A failed remap is the kernel declining to map an address NOW. It says
        // nothing about the 256 mappings already held, each of which was handed
        // over successfully and is still referenced by a live shmem entry. There
        // is no mechanism by which holding them makes a new mapping of a different
        // address any less likely to succeed, and if the address itself is the
        // problem -- freed, no longer in the map -- then dropping whatever we
        // cached for it would not help either, because the next attempt maps the
        // same dead address and fails the same way.
        //
        // Dropping it anyway cost three things and bought nothing measurable. It
        // forced 256 fresh remaps immediately after, which is more mapping pressure
        // than the state we were escaping, so it drove the next failure and the
        // next latch. It did 512 mach_vm_deallocate and mach_port_deallocate calls
        // while holding g_pageCacheLock, which is the lock the render thread on the
        // main queue and the aim thread both contend for. And it discarded mappings
        // that were fine, so every page of the working set had to be re-fetched
        // while the cache was cold.
        //
        // This is why the failure was mode-dependent. Clash Squad has a handful of
        // players and the kernel rarely refuses, so three consecutive failures never
        // happen and none of this runs. Survival has fifty to a hundred, allocating
        // continuously, and refusals are routine -- so it latched, wiped, burst,
        // and latched again. Same code, same offsets, different memory pressure.
        if (ds_now_ms() < g_degradedUntilMs) {
            // While the cooldown runs a cold read is refused and a warm one was
            // already served above. The release moved to ds_expire_degrade_locked,
            // which both transaction hooks call: it cannot live here, because
            // ds_rw_remap returned false on g_degraded before this function was
            // ever entered.
            g_dsBlockedLastSecond = true;
            ds_unlock();
            return 0;
        }
    }

    // Prefer an empty slot. Otherwise evict the genuinely coldest one.
    //
    // This used to scan only the recent window and pick the coldest within it,
    // which is the opposite of what the comment claimed. g_recentPageSlots holds
    // the DS_RECENT_SLOTS most recently touched slots, most recent first, so
    // "coldest among the recent window" is the eighth-hottest page in the whole
    // table -- hotter than the other 248. Every eviction therefore dropped a page
    // that was in active use, the next read of it missed, and the re-mapped entry
    // became the newest member of the same eight. That is a cascade: the hot set
    // rotates through the victims while the genuinely cold pages stay pinned
    // forever.
    //
    // It only bites once the working set passes DS_PAGE_CACHE_SLOTS, which is also
    // why it looked mode-dependent on top of the degrade loop: Clash Squad fits in
    // 256 pages and never evicts, Survival with fifty to a hundred players does.
    //
    // lastUse is a monotonic counter handed out per touch, so a full scan of 256
    // slots is exact LRU and costs 256 comparisons on the miss path only.
    int victim = -1;
    for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
        if (g_pageCache[i].localAddr == 0 && g_pageCache[i].port == 0) {
            victim = i;
            break;
        }
    }
    if (victim < 0) {
        uint64_t bestUse = UINT64_MAX;
        for (int i = 0; i < DS_PAGE_CACHE_SLOTS; i++) {
            if (g_pageCache[i].localAddr == 0 && g_pageCache[i].port == 0) continue;
            // LRU order is unchanged -- this only removes from the candidate set
            // the pages this frame has already read. Evicting one of those is how a
            // full table becomes a remap storm: the next frame asks for it again,
            // misses, and re-maps it.
            if (g_pageCache[i].touchedFrame == (uint32_t)g_txnFrameStamp) continue;
            if (g_pageCache[i].lastUse < bestUse) { bestUse = g_pageCache[i].lastUse; victim = i; }
        }
        // No empty slot and no slot this frame has not read: all 256 are live work.
        // This used to fall through to g_pageCacheNext and evict one anyway, which
        // is what made a crowded match unfixable by any cache size. Evicting
        // round-robin against a working set larger than the table gives every
        // reference a miss -- each one destroys a mapping the frame still needs,
        // and the same page comes back next frame -- so the table sustains zero
        // hits and the miss rate is the whole working set, every frame. Refusing
        // bounds misses by (working set - table) instead, and the resident window
        // rotates around the working set rather than thrashing inside it.
        if (victim < 0) {
            g_dsNoVictimCount++;
            ds_unlock();
            return 0;
        }
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
            // Throttled. This path can be entered many times a second now that
            // recovery no longer spends 256 releases slowing each lap down, and an
            // NSLog is not free -- on a failing read path it is the difference
            // between a degraded frame and an unusable app.
            {
                static uint64_t s_lastDegLogMs = 0;
                const uint64_t tDeg = ds_now_ms();
                if (tDeg - s_lastDegLogMs >= 1000ULL) {
                    s_lastDegLogMs = tDeg;
                    NSLog(@"[DS] degraded after %llu consecutive map failures — pausing remap "
                          @"for %dms, cache kept intact",
                          (unsigned long long)g_consecutiveMapFailures, DS_DEGRADE_COOLDOWN_MS);
                }
            }
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
    ds_page_index_set(pageVA, victim);
    g_pageCache[victim].gen = g_cacheGeneration;
    g_pageCache[victim].useCount = 1;
    g_pageCache[victim].lastUse = g_pageUseCounter++;
    g_pageCache[victim].bornMs = ds_now_ms();
    g_pageCache[victim].lastUseMs = g_pageCache[victim].bornMs;
    g_pageCache[victim].touchedFrame = (uint32_t)g_txnFrameStamp;
    // From the snapshot, which is free. This used to be a fresh walk of the whole map
    // on every remap -- the other half of the cost that made entering a match
    // unaffordable, since a miss is the common case at match entry and the map is at
    // its largest exactly then.
    g_pageCache[victim].vmo = ds_vmo_recordable(pageVA);
    // Stamped with the LIVE buffer's epoch, not a pass start: that is what decides
    // later whether this slot may be judged against a given pass. A buffer swaps in
    // once per cycle, so an unmapped game page is caught within one cycle of being
    // freed rather than within one sweep interval.
    g_pageCache[victim].vmoEpochMs = g_vmoLiveEpochMs;
    g_dsRemapCount++;
    g_dsMissCount++;
    g_pageCacheNext = (victim + 1) % DS_PAGE_CACHE_SLOTS;
    uint64_t a = page.localAddress;
    ds_unlock();
    return a;
}

static bool ds_rw_remap(uint64_t va, void *buf, size_t len, bool isWrite) {
    if (!K(g_ff_map) || !va || !buf || !len) return false;
    // There used to be `if (g_degraded) return false;` here, and it is why
    // reordering the hit loop inside ds_page_local changed nothing.
    //
    // This is the top of the read path. ds_page_local -- where a hit is now
    // served before the flag is looked at -- is called from the loop at the
    // bottom of this function, so a flag tested here returns false before that
    // loop can run at all. The reorder was correct and unreachable.
    //
    // Nothing is lost by dropping it. A degrade is the kernel declining to map an
    // address NOW. The flag is enforced one level down, inside ds_page_local, which
    // is the only place that calls vm_map_remote_page, and this loop resolves
    // pages through that function -- so it inherits the gate where it belongs,
    // together with the hit-first ordering.

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
    g_consecutiveMapFailures = 0;
    g_degraded = false;
    ds_unlock();
    g_ff_proc = g_ff_task = g_ff_base = 0;
    g_lastBaseWalkMs = 0;
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
    // Scoped to the cooldown rather than to the flag, which is the difference
    // between a pause and a latch. This path maps a fresh page on every call and
    // unmaps it again, so it is the one place that genuinely should not add
    // mapping pressure while the kernel is refusing. Gating on the flag meant the
    // [PUSH] cache-versus-uncached cross-check in esp.mm could not run at all once
    // a degrade latched -- which is the only moment it is worth running.
    if (g_degraded && ds_now_ms() < g_degradedUntilMs) {
        g_dsBlockedLastSecond = true;
        return false;
    }

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
    g_pageUseCounter++;
    // Clearing the mappings without clearing the flag was the worst of both: an
    // empty cache and reads still refused. This is called on a match transition,
    // and every mapping it dropped was taken against an address space the game has
    // since torn down, so it is the natural moment to be able to read again.
    g_degraded = false;
    g_consecutiveMapFailures = 0;
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
