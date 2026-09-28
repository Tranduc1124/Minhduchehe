//
//  remote_objc.m
//

#import "remote_objc.h"
#import "RemoteCall.h"
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

extern uint64_t remote_read64(uint64_t src);

static useconds_t gSettleUS = 50000;

#define R_OBJC_CACHE_CAP 192
#define R_OBJC_CACHE_NAME_MAX 96

typedef struct {
    int pid;
    char name[R_OBJC_CACHE_NAME_MAX];
    uint64_t value;
} RemoteObjCCacheEntry;

static pthread_mutex_t gObjCCacheLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gRemoteCallLock = PTHREAD_MUTEX_INITIALIZER;
static RemoteObjCCacheEntry gSelCache[R_OBJC_CACHE_CAP];
static RemoteObjCCacheEntry gClassCache[R_OBJC_CACHE_CAP];
static int gSelCacheNext = 0;
static int gClassCacheNext = 0;

static bool r_cacheable_name(const char *name)
{
    return name && name[0] && strlen(name) < R_OBJC_CACHE_NAME_MAX;
}

static uint64_t r_cache_lookup(RemoteObjCCacheEntry *cache, int pid, const char *name)
{
    if (pid <= 0 || !r_cacheable_name(name)) return 0;

    uint64_t value = 0;
    pthread_mutex_lock(&gObjCCacheLock);
    for (int i = 0; i < R_OBJC_CACHE_CAP; i++) {
        if (cache[i].pid == pid && cache[i].value && strcmp(cache[i].name, name) == 0) {
            value = cache[i].value;
            break;
        }
    }
    pthread_mutex_unlock(&gObjCCacheLock);
    return value;
}

static void r_cache_store(RemoteObjCCacheEntry *cache, int *nextSlot, int pid, const char *name, uint64_t value)
{
    if (pid <= 0 || !value || !r_cacheable_name(name)) return;

    pthread_mutex_lock(&gObjCCacheLock);
    for (int i = 0; i < R_OBJC_CACHE_CAP; i++) {
        if (cache[i].pid == pid && strcmp(cache[i].name, name) == 0) {
            cache[i].value = value;
            pthread_mutex_unlock(&gObjCCacheLock);
            return;
        }
    }

    int slot = -1;
    for (int i = 0; i < R_OBJC_CACHE_CAP; i++) {
        if (cache[i].pid == 0 || cache[i].value == 0) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        slot = *nextSlot;
        *nextSlot = (*nextSlot + 1) % R_OBJC_CACHE_CAP;
    }

    cache[slot].pid = pid;
    strncpy(cache[slot].name, name, sizeof(cache[slot].name) - 1);
    cache[slot].name[sizeof(cache[slot].name) - 1] = '\0';
    cache[slot].value = value;
    pthread_mutex_unlock(&gObjCCacheLock);
}

static void r_settle(void)
{
    if (gSettleUS) usleep(gSettleUS);
}

static uint64_t r_call_stable(int timeout, const char *fnName,
                              uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                              uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    pthread_mutex_lock(&gRemoteCallLock);
    uint64_t ret = do_remote_call_stable(timeout, fnName,
                                         a0, a1, a2, a3,
                                         a4, a5, a6, a7);
    pthread_mutex_unlock(&gRemoteCallLock);
    return ret;
}

uint32_t r_settle_us(uint32_t usec)
{
    uint32_t old = (uint32_t)gSettleUS;
    gSettleUS = (useconds_t)usec;
    return old;
}

bool r_is_objc_ptr(uint64_t ptr)
{
    return ptr >= 0x100000000ULL;
}

uint64_t r_dlsym_call(int timeout, const char *fnName,
                      uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                      uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    return r_call_stable(timeout, fnName, a0, a1, a2, a3, a4, a5, a6, a7);
}

// remote_write() goes through the vm_map_entry hijack, so it can silently land
// in a stale alias and leave the target's real page untouched. Nothing about its
// return value tells us that, and a NULL objc_getClass() looks exactly the same
// as "class genuinely not found".
//
// So verify with the target itself: strlen() inside SpringBoard reads the target's
// own memory, and every named remote call in this file is already proven working
// (getpid/malloc/free/memset/memcpy all return sane values in the 10:21 log).
// Expected length is authoritative, so a mismatch localises the fault exactly.
static bool r_str_verify(uint64_t buf, size_t expect)
{
    if (!buf) return false;
    remote_clear_shmem_cache();
    uint64_t got = r_call_stable(R_TIMEOUT, "strlen", buf, 0, 0, 0, 0, 0, 0, 0);
    return got == (uint64_t)expect;
}

uint64_t r_alloc_str(const char *s)
{
    if (!s) return 0;
    size_t len = strlen(s);
    uint64_t buf = r_call_stable(R_TIMEOUT, "malloc", len + 1, 0, 0, 0, 0, 0, 0, 0);
    if (!buf) return 0;

    for (int attempt = 0; attempt < 3; attempt++) {
        // Drop any cached alias for this page before writing, so we never write
        // into a mapping that is no longer the target's live page.
        remote_clear_shmem_cache();
        if (remote_writeStr(buf, s) && r_str_verify(buf, len))
            return buf;
    }

    uint64_t got = r_call_stable(R_TIMEOUT, "strlen", buf, 0, 0, 0, 0, 0, 0, 0);
    NSLog(@"[RemoteObjC] r_alloc_str FAILED for \"%s\" buf=0x%llx: target strlen=%llu, expected %zu "
          "— remote_write is not reaching SpringBoard memory",
          s, (unsigned long long)buf, (unsigned long long)got, len);
    r_call_stable(R_TIMEOUT, "free", buf, 0, 0, 0, 0, 0, 0, 0);
    return 0;
}

void r_free(uint64_t ptr)
{
    if (!ptr) return;
    r_call_stable(R_TIMEOUT, "free", ptr, 0, 0, 0, 0, 0, 0, 0);
}

uint64_t r_sel(const char *name)
{
    int pid = remote_call_current_pid();
    uint64_t cached = r_cache_lookup(gSelCache, pid, name);
    if (cached) return cached;

    uint64_t s = r_alloc_str(name);
    if (!s) return 0;
    uint64_t sel = r_call_stable(R_TIMEOUT, "sel_registerName", s, 0, 0, 0, 0, 0, 0, 0);
    r_free(s);
    r_cache_store(gSelCache, &gSelCacheNext, pid, name, sel);
    return sel;
}

uint64_t r_class(const char *name)
{
    int pid = remote_call_current_pid();
    uint64_t cached = r_cache_lookup(gClassCache, pid, name);
    if (cached) return cached;

    uint64_t s = r_alloc_str(name);
    if (!s) return 0;
    uint64_t c = r_call_stable(R_TIMEOUT, "objc_getClass", s, 0, 0, 0, 0, 0, 0, 0);
    r_free(s);
    r_cache_store(gClassCache, &gClassCacheNext, pid, name, c);
    return c;
}

uint64_t r_msg(uint64_t obj, uint64_t sel,
               uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!obj || !sel) return 0;
    return r_call_stable(R_TIMEOUT, "objc_msgSend",
                         obj, sel, a0, a1, a2, a3, 0, 0);
}

static uint64_t r_msg_retained_return(uint64_t obj, uint64_t sel,
                                      uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!obj || !sel) return 0;

    if (remote_call_uses_vphone_bridge()) {
        return r_call_stable(R_TIMEOUT, "objc_msgSend_retain",
                             obj, sel, a0, a1, a2, a3, 0, 0);
    }

    uint64_t ret = r_msg(obj, sel, a0, a1, a2, a3);
    if (r_is_objc_ptr(ret)) {
        uint64_t retained = r_msg(ret, r_sel("retain"), 0, 0, 0, 0);
        if (r_is_objc_ptr(retained)) ret = retained;
    }
    return ret;
}

uint64_t r_msg2(uint64_t obj, const char *selName,
                uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!obj || !selName) return 0;
    uint64_t sel = r_sel(selName);
    if (!sel) return 0;
    r_settle();
    return r_msg(obj, sel, a0, a1, a2, a3);
}

static uint64_t r_method_signature(uint64_t obj, uint64_t sel)
{
    if (!r_is_objc_ptr(obj) || !sel) return 0;

    uint64_t sigSel = r_sel("methodSignatureForSelector:");
    uint64_t sig = r_msg_retained_return(obj, sigSel, sel, 0, 0, 0);
    if (r_is_objc_ptr(sig)) return sig;

    uint64_t cls = r_call_stable(R_TIMEOUT, "object_getClass",
                                 obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return 0;

    uint64_t method = r_call_stable(R_TIMEOUT, "class_getInstanceMethod",
                                    cls, sel, 0, 0, 0, 0, 0, 0);
    if (!method) return 0;

    uint64_t types = r_call_stable(R_TIMEOUT, "method_getTypeEncoding",
                                   method, 0, 0, 0, 0, 0, 0, 0);
    if (!types) return 0;

    uint64_t NSMethodSignature = r_class("NSMethodSignature");
    if (!r_is_objc_ptr(NSMethodSignature)) return 0;
    return r_msg_retained_return(NSMethodSignature,
                                 r_sel("signatureWithObjCTypes:"),
                                 types, 0, 0, 0);
}

bool     r_arg_probe_enabled = false;
uint64_t r_arg_probe_n = 0;
uint64_t r_arg_probe_got[4] = { 0, 0, 0, 0 };

static bool r_write_remote_arg(uint64_t remoteBuf, const void *arg, size_t argSize, size_t remoteSize)
{
    if (!remoteBuf || remoteSize == 0) return false;

    uint8_t stackBuf[64];
    void *localBuf = stackBuf;
    if (remoteSize > sizeof(stackBuf)) {
        localBuf = calloc(1, remoteSize);
        if (!localBuf) return false;
    } else {
        memset(stackBuf, 0, remoteSize);
    }

    if (arg && argSize) {
        size_t copySize = (argSize < remoteSize) ? argSize : remoteSize;
        memcpy(localBuf, arg, copySize);
    }

    // remote_write goes through the vm_map_entry hijack, so it can silently land
    // in a stale alias and leave the target's real page untouched, and the file
    // says so at the top of this one. This function called it exactly once and
    // trusted the return, so a write that went nowhere looked identical to a write
    // that worked.
    //
    // The device log separated the two. A colour built from four doubles for
    // 0,1,0,1 came back as a valid UIColor with a valid CGColor, and reading the
    // components out of SpringBoard gave 0,0,0,0 rather than the -1 the sentinel
    // starts at. A read that fails leaves the sentinel, so remote_read works and
    // the target genuinely holds zeros. The write is the half that never arrived.
    // The argument was then handed to setArgument:atIndex:, which is a pointer to
    // bytes the target never received, so the selector ran on zeroes.
    //
    // r_alloc_str in this same file already had the answer for the string case:
    // clear the cache, retry, and verify by reading the target's own bytes back.
    // This does the same, comparing the value rather than a length, so a CGFloat
    // is checked as well as a C string.
    bool ok = false;
    for (int attempt = 0; attempt < 3; attempt++) {
        remote_clear_shmem_cache();
        if (!remote_write(remoteBuf, localBuf, remoteSize)) continue;

        uint8_t vstack[64];
        void *vbuf = vstack;
        void *vheap = NULL;
        if (remoteSize > sizeof(vstack)) {
            vheap = calloc(1, remoteSize);
            if (!vheap) break;
            vbuf = vheap;
        }
        bool match = remote_read(remoteBuf, vbuf, remoteSize) &&
                     memcmp(vbuf, localBuf, remoteSize) == 0;
        if (vheap) free(vheap);
        if (match) { ok = true; break; }
        // Only reached when the target did not receive the bytes. Logged once
        // per distinct buffer so a persistent failure is visible in the device
        // log instead of showing up later as a colour or a size that silently
        // came out wrong.
        static uint64_t s_lastWarned = 0;
        if (remoteBuf != s_lastWarned) {
            s_lastWarned = remoteBuf;
            NSLog(@"[RemoteObjC] remote_write did not reach target buf=0x%llx size=%zu "
                  "after %d attempts", (unsigned long long)remoteBuf, remoteSize,
                  attempt + 1);
        }
    }

    if (localBuf != stackBuf) free(localBuf);
    return ok;
}

uint64_t r_msg_main_raw(uint64_t obj, uint64_t sel,
                        const void *a0, size_t a0Size,
                        const void *a1, size_t a1Size,
                        const void *a2, size_t a2Size,
                        const void *a3, size_t a3Size)
{
    if (!r_is_objc_ptr(obj) || !sel) return 0;

    uint64_t sig = r_method_signature(obj, sel);
    if (!r_is_objc_ptr(sig)) return 0;

    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return 0;

    uint64_t inv = r_msg_retained_return(NSInvocation,
                                         r_sel("invocationWithMethodSignature:"),
                                         sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return 0;

    uint64_t numArgs = r_msg2(sig, "numberOfArguments", 0, 0, 0, 0);
    uint64_t maxUserArgs = (numArgs > 2) ? (numArgs - 2) : 0;
    if (maxUserArgs > 4) maxUserArgs = 4;

    r_msg2(inv, "setTarget:", obj, 0, 0, 0);
    r_msg2(inv, "setSelector:", sel, 0, 0, 0);

    bool argsOK = true;
    const void *argData[4] = { a0, a1, a2, a3 };
    size_t argSizes[4] = { a0Size, a1Size, a2Size, a3Size };
    // The argument buffers must outlive invoke, see the comment at the free
    // below. Held here so the error paths can release them too.
    uint64_t argBufs[4] = { 0, 0, 0, 0 };
    for (uint64_t i = 0; i < maxUserArgs; i++) {
        size_t argBufLen = (argSizes[i] > 8) ? argSizes[i] : 8;
        uint64_t argBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        argBufLen, 0, 0, 0, 0, 0, 0, 0);
        if (!argBuf) {
            argsOK = false;
            continue;
        }
        argBufs[i] = argBuf;
        if (r_write_remote_arg(argBuf, argData[i], argSizes[i], argBufLen)) {
            r_msg2(inv, "setArgument:atIndex:", argBuf, i + 2, 0, 0);
        } else {
            argsOK = false;
        }
    }

    if (!argsOK) {
        for (uint64_t i = 0; i < maxUserArgs; i++) {
            if (argBufs[i]) r_free(argBufs[i]);
        }
        r_msg2(inv, "release", 0, 0, 0, 0);
        return 0;
    }

    r_msg2(inv, "retainArguments", 0, 0, 0, 0);

    if (r_arg_probe_enabled) {
        r_arg_probe_n = maxUserArgs;
        for (uint64_t i = 0; i < maxUserArgs; i++) {
            r_arg_probe_got[i] = 0;
            if (!argBufs[i]) continue;
            uint64_t outBuf = r_call_stable(R_TIMEOUT, "malloc", 8, 0,0,0,0,0,0,0);
            if (!outBuf) continue;
            // Poison the buffer first, so a getArgument that writes nothing is
            // distinguishable from one that wrote zero.
            remote_write64(outBuf, 0);
            r_msg2(inv, "getArgument:atIndex:", outBuf, i + 2, 0, 0);
            r_arg_probe_got[i] = remote_read64(outBuf);
            r_free(outBuf);
        }
    }

    uint64_t performSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    uint64_t invokeSel = r_sel("invoke");
    if (!performSel || !invokeSel) {
        for (uint64_t i = 0; i < maxUserArgs; i++) {
            if (argBufs[i]) r_free(argBufs[i]);
        }
        r_msg2(inv, "release", 0, 0, 0, 0);
        return 0;
    }
    r_msg(inv, performSel, invokeSel, 0, 1, 0);

    // Only now is it safe to free. setArgument:atIndex: stores the pointer and
    // copies nothing, and retainArguments only retains arguments that are
    // objects, so a CGFloat argument is read straight out of this buffer when
    // invoke runs. Freeing it before invoke is why every number this transport
    // carried arrived as zero.
    //
    // The device log proved it rather than suggesting it. Creating a colour with
    // colorWithRed:green:blue:alpha: and four separate doubles for 0,1,0,1
    // returned a valid object and a valid CGColor, and reading the components
    // back out of SpringBoard gave 0,0,0,0:
    //
    //   [SB-COLOR] want=0.00,1.00,0.00,1.00 got=0.00,0.00,0.00,0.00 col=1 cg=1
    //
    // This also explains a long standing oddity. setLineWidth: was given 1.5 and
    // the overlay looked as though it had been honoured, but a zero line width
    // falls back to the CALayer default of one, which is close enough to 1.5 that
    // nothing ever looked wrong. It was never actually being set.
    for (uint64_t i = 0; i < maxUserArgs; i++) {
        if (argBufs[i]) r_free(argBufs[i]);
    }

    uint64_t ret = 0;
    uint64_t retLen = r_msg2(sig, "methodReturnLength", 0, 0, 0, 0);
    if (retLen > 0) {
        uint64_t retBufLen = (retLen > 8) ? retLen : 8;
        uint64_t retBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        retBufLen, 0, 0, 0, 0, 0, 0, 0);
        if (retBuf) {
            remote_write64(retBuf, 0);
            r_msg2(inv, "getReturnValue:", retBuf, 0, 0, 0);
            ret = remote_read64(retBuf);
            r_free(retBuf);
        }
    }

    r_msg2(inv, "release", 0, 0, 0, 0);
    return ret;
}

uint64_t r_msg_main(uint64_t obj, uint64_t sel,
                    uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (remote_call_uses_vphone_bridge()) {
        return r_call_stable(R_TIMEOUT, "objc_msgSend_main",
                             obj, sel, a0, a1, a2, a3, 0, 0);
    }

    uint64_t args[4] = { a0, a1, a2, a3 };
    return r_msg_main_raw(obj, sel,
                          &args[0], sizeof(args[0]),
                          &args[1], sizeof(args[1]),
                          &args[2], sizeof(args[2]),
                          &args[3], sizeof(args[3]));
}

uint64_t r_msg2_main(uint64_t obj, const char *selName,
                     uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!obj || !selName) return 0;
    uint64_t sel = r_sel(selName);
    if (!sel) return 0;
    r_settle();
    return r_msg_main(obj, sel, a0, a1, a2, a3);
}

// Fire-and-forget variant: dispatches the call to main thread with
// waitUntilDone:NO and skips the return-value plumbing. Use this when the
// selector returns void and we don't need to wait — main thread retains the
// NSInvocation for the duration of the call, so it's safe to release here.
void r_msg2_main_async(uint64_t obj, const char *selName,
                       uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!r_is_objc_ptr(obj) || !selName) return;
    uint64_t sel = r_sel(selName);
    if (!sel) return;
    r_settle();

    uint64_t sig = 0;
    {
        uint64_t sigSel = r_sel("methodSignatureForSelector:");
        sig = r_msg(obj, sigSel, sel, 0, 0, 0);
    }
    if (!r_is_objc_ptr(sig)) return;

    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return;
    uint64_t inv = r_msg_retained_return(NSInvocation,
                                         r_sel("invocationWithMethodSignature:"),
                                         sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return;

    uint64_t numArgs = r_msg2(sig, "numberOfArguments", 0, 0, 0, 0);
    uint64_t maxUserArgs = (numArgs > 2) ? (numArgs - 2) : 0;
    if (maxUserArgs > 4) maxUserArgs = 4;

    r_msg2(inv, "setTarget:", obj, 0, 0, 0);
    r_msg2(inv, "setSelector:", sel, 0, 0, 0);

    bool argsOK = true;
    uint64_t userArgs[4] = { a0, a1, a2, a3 };
    // Held until after invoke. See the comment at the free in r_msg_main_raw.
    uint64_t argBufs[4] = { 0, 0, 0, 0 };
    for (uint64_t i = 0; i < maxUserArgs; i++) {
        uint64_t argBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        8, 0, 0, 0, 0, 0, 0, 0);
        if (!argBuf) {
            argsOK = false;
            continue;
        }
        argBufs[i] = argBuf;
        // Same verified writer as the other two sites, so a stale alias is
        // retried here too rather than becoming a silent zero pointer.
        if (r_write_remote_arg(argBuf, &userArgs[i], sizeof(userArgs[i]), 8)) {
            r_msg2(inv, "setArgument:atIndex:", argBuf, i + 2, 0, 0);
        } else {
            argsOK = false;
        }
    }

    if (!argsOK) {
        for (uint64_t i = 0; i < maxUserArgs; i++) {
            if (argBufs[i]) r_free(argBufs[i]);
        }
        return;
    }

    r_msg2(inv, "retainArguments", 0, 0, 0, 0);

    uint64_t performSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    uint64_t invokeSel = r_sel("invoke");
    if (performSel && invokeSel) {
        // waitUntilDone is 1, not 0. The argument buffers are only valid until
        // the invocation has run, and this function has no way to learn when a
        // queued invocation finished, so it must be told to wait. The previous 0
        // meant the buffers below were freed while the main thread had not yet
        // read them.
        r_msg(inv, performSel, invokeSel, 0, 1, 0);
    }
    // Safe now that invoke has returned. See the comment at the free in
    // r_msg_main_raw.
    for (uint64_t i = 0; i < maxUserArgs; i++) {
        if (argBufs[i]) r_free(argBufs[i]);
    }
}

uint64_t r_msg2_main_raw(uint64_t obj, const char *selName,
                         const void *a0, size_t a0Size,
                         const void *a1, size_t a1Size,
                         const void *a2, size_t a2Size,
                         const void *a3, size_t a3Size)
{
    if (!obj || !selName) return 0;
    uint64_t sel = r_sel(selName);
    if (!sel) return 0;
    r_settle();
    return r_msg_main_raw(obj, sel, a0, a0Size, a1, a1Size, a2, a2Size, a3, a3Size);
}

// Same flow as r_msg_main_raw, but copies the full method return buffer back
// into outBuf instead of truncating to 8 bytes. Used for selectors that return
// a struct larger than a register pair (e.g. CGRect from -convertRect:toView:).
bool r_msg2_main_struct_ret(uint64_t obj, const char *selName,
                            void *outBuf, size_t outSize,
                            const void *a0, size_t a0Size,
                            const void *a1, size_t a1Size,
                            const void *a2, size_t a2Size,
                            const void *a3, size_t a3Size)
{
    if (!r_is_objc_ptr(obj) || !selName || !outBuf || outSize == 0) return false;
    uint64_t sel = r_sel(selName);
    if (!sel) return false;
    r_settle();

    uint64_t sig = r_method_signature(obj, sel);
    if (!r_is_objc_ptr(sig)) return false;

    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return false;

    uint64_t inv = r_msg_retained_return(NSInvocation,
                                         r_sel("invocationWithMethodSignature:"),
                                         sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return false;

    uint64_t numArgs = r_msg2(sig, "numberOfArguments", 0, 0, 0, 0);
    uint64_t maxUserArgs = (numArgs > 2) ? (numArgs - 2) : 0;
    if (maxUserArgs > 4) maxUserArgs = 4;

    r_msg2(inv, "setTarget:", obj, 0, 0, 0);
    r_msg2(inv, "setSelector:", sel, 0, 0, 0);

    bool argsOK = true;
    const void *argData[4] = { a0, a1, a2, a3 };
    size_t argSizes[4] = { a0Size, a1Size, a2Size, a3Size };
    // Held until after invoke. See the comment at the free in r_msg_main_raw.
    uint64_t argBufs[4] = { 0, 0, 0, 0 };
    for (uint64_t i = 0; i < maxUserArgs; i++) {
        size_t argBufLen = (argSizes[i] > 8) ? argSizes[i] : 8;
        uint64_t argBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        argBufLen, 0, 0, 0, 0, 0, 0, 0);
        if (!argBuf) {
            argsOK = false;
            continue;
        }
        argBufs[i] = argBuf;
        if (r_write_remote_arg(argBuf, argData[i], argSizes[i], argBufLen)) {
            r_msg2(inv, "setArgument:atIndex:", argBuf, i + 2, 0, 0);
        } else {
            argsOK = false;
        }
    }

    if (!argsOK) {
        for (uint64_t i = 0; i < maxUserArgs; i++) {
            if (argBufs[i]) r_free(argBufs[i]);
        }
        r_msg2(inv, "release", 0, 0, 0, 0);
        return false;
    }

    r_msg2(inv, "retainArguments", 0, 0, 0, 0);

    uint64_t performSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    uint64_t invokeSel = r_sel("invoke");
    if (!performSel || !invokeSel) {
        for (uint64_t i = 0; i < maxUserArgs; i++) {
            if (argBufs[i]) r_free(argBufs[i]);
        }
        r_msg2(inv, "release", 0, 0, 0, 0);
        return false;
    }
    r_msg(inv, performSel, invokeSel, 0, 1, 0);

    for (uint64_t i = 0; i < maxUserArgs; i++) {
        if (argBufs[i]) r_free(argBufs[i]);
    }

    bool ok = false;
    uint64_t retLen = r_msg2(sig, "methodReturnLength", 0, 0, 0, 0);
    if (retLen >= outSize) {
        uint64_t retBuf = r_call_stable(R_TIMEOUT, "malloc",
                                        retLen, 0, 0, 0, 0, 0, 0, 0);
        if (retBuf) {
            r_msg2(inv, "getReturnValue:", retBuf, 0, 0, 0);
            ok = remote_read(retBuf, outBuf, outSize);
            r_free(retBuf);
        }
    }

    r_msg2(inv, "release", 0, 0, 0, 0);
    return ok;
}

uint64_t r_perform_main(uint64_t obj, uint64_t sel, uint64_t object, bool wait)
{
    if (!r_is_objc_ptr(obj) || !sel) return 0;
    if (remote_call_uses_vphone_bridge()) {
        return r_msg_main(obj, sel, object, 0, 0, 0);
    }

    uint64_t performSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    if (!performSel) return 0;
    return r_msg(obj, performSel, sel, object, wait ? 1 : 0, 0);
}

uint64_t r_cfstr(const char *s)
{
    if (!s) return 0;
    uint64_t buf = r_alloc_str(s);
    if (!buf) return 0;
    // CFStringCreateWithCString(alloc=NULL, cstr, encoding=kCFStringEncodingUTF8=0x08000100)
    uint64_t cf = r_call_stable(R_TIMEOUT, "CFStringCreateWithCString",
                                0, buf, 0x08000100, 0, 0, 0, 0, 0);
    r_free(buf);
    return cf;
}

uint64_t r_nsstr_retained(const char *s)
{
    if (!s) return 0;
    uint64_t buf = r_alloc_str(s);
    if (!buf) return 0;
    uint64_t NSString = r_class("NSString");
    if (!r_is_objc_ptr(NSString)) { r_free(buf); return 0; }
    uint64_t allocated = r_msg2(NSString, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(allocated)) { r_free(buf); return 0; }
    uint64_t ns = r_msg2(allocated, "initWithUTF8String:", buf, 0, 0, 0);
    r_free(buf);
    return ns;
}

bool r_responds(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj)) return false;
    uint64_t sel = r_sel(selName);
    if (!sel) return false;
    uint64_t respondsSel = r_sel("respondsToSelector:");
    if (!respondsSel) return false;
    r_settle();
    uint64_t r = r_msg(obj, respondsSel, sel, 0, 0, 0);
    return (r & 0xff) != 0;
}

bool r_responds_main(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj)) return false;
    uint64_t sel = r_sel(selName);
    if (!sel) return false;
    uint64_t respondsSel = r_sel("respondsToSelector:");
    if (!respondsSel) return false;
    r_settle();
    uint64_t r = r_msg_main(obj, respondsSel, sel, 0, 0, 0);
    return (r & 0xff) != 0;
}

uint64_t r_ivar_value(uint64_t obj, const char *ivarName)
{
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t cls = r_call_stable(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!cls) return 0;
    uint64_t nameBuf = r_alloc_str(ivarName);
    if (!nameBuf) return 0;
    uint64_t ivar = r_call_stable(R_TIMEOUT, "class_getInstanceVariable",
                                  cls, nameBuf, 0, 0, 0, 0, 0, 0);
    r_free(nameBuf);
    if (!ivar) return 0;
    uint64_t offset = r_call_stable(R_TIMEOUT, "ivar_getOffset",
                                    ivar, 0, 0, 0, 0, 0, 0, 0);
    return remote_read64(obj + offset);
}

bool r_read_nsstring(uint64_t str, char *out, size_t outLen)
{
    if (!r_is_objc_ptr(str) || !out || outLen == 0) return false;
    memset(out, 0, outLen);

    uint64_t buf = r_dlsym_call(R_TIMEOUT, "malloc", outLen, 0, 0, 0, 0, 0, 0, 0);
    if (!buf) return false;
    r_dlsym_call(R_TIMEOUT, "memset", buf, 0, outLen, 0, 0, 0, 0, 0);

    bool copied = false;
    if (r_responds(str, "getCString:maxLength:encoding:")) {
        uint64_t ok = r_msg2(str, "getCString:maxLength:encoding:", buf, outLen, 4, 0);
        if ((ok & 0xff) && remote_read(buf, out, outLen - 1)) {
            out[outLen - 1] = '\0';
            copied = out[0] != '\0';
        }
    }

    r_free(buf);
    return copied;
}

#ifdef __OBJC__
#define R_SESSION_RETURN(session, type, fallback, expr) do { \
    if (!(session)) return (expr); \
    __block type result = (fallback); \
    remote_call_with_session((session), ^{ result = (expr); }); \
    return result; \
} while (0)

#define R_SESSION_VOID(session, expr) do { \
    if (!(session)) { expr; return; } \
    remote_call_with_session((session), ^{ expr; }); \
} while (0)

uint64_t r_session_dlsym_call(RemoteCallSession *session, int timeout, const char *fnName,
                              uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                              uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    R_SESSION_RETURN(session, uint64_t, 0,
                     r_dlsym_call(timeout, fnName, a0, a1, a2, a3, a4, a5, a6, a7));
}

uint64_t r_session_alloc_str(RemoteCallSession *session, const char *s)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_alloc_str(s));
}

void r_session_free(RemoteCallSession *session, uint64_t ptr)
{
    R_SESSION_VOID(session, r_free(ptr));
}

uint64_t r_session_sel(RemoteCallSession *session, const char *name)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_sel(name));
}

uint64_t r_session_class(RemoteCallSession *session, const char *name)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_class(name));
}

uint64_t r_session_msg(RemoteCallSession *session, uint64_t obj, uint64_t sel,
                       uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_msg(obj, sel, a0, a1, a2, a3));
}

uint64_t r_session_msg2(RemoteCallSession *session, uint64_t obj, const char *selName,
                        uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_msg2(obj, selName, a0, a1, a2, a3));
}

uint64_t r_session_msg_main(RemoteCallSession *session, uint64_t obj, uint64_t sel,
                            uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_msg_main(obj, sel, a0, a1, a2, a3));
}

uint64_t r_session_msg2_main(RemoteCallSession *session, uint64_t obj, const char *selName,
                             uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_msg2_main(obj, selName, a0, a1, a2, a3));
}

void r_session_msg2_main_async(RemoteCallSession *session, uint64_t obj, const char *selName,
                               uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    R_SESSION_VOID(session, r_msg2_main_async(obj, selName, a0, a1, a2, a3));
}

uint64_t r_session_msg_main_raw(RemoteCallSession *session, uint64_t obj, uint64_t sel,
                                const void *a0, size_t a0Size,
                                const void *a1, size_t a1Size,
                                const void *a2, size_t a2Size,
                                const void *a3, size_t a3Size)
{
    R_SESSION_RETURN(session, uint64_t, 0,
                     r_msg_main_raw(obj, sel, a0, a0Size, a1, a1Size, a2, a2Size, a3, a3Size));
}

uint64_t r_session_msg2_main_raw(RemoteCallSession *session, uint64_t obj, const char *selName,
                                 const void *a0, size_t a0Size,
                                 const void *a1, size_t a1Size,
                                 const void *a2, size_t a2Size,
                                 const void *a3, size_t a3Size)
{
    R_SESSION_RETURN(session, uint64_t, 0,
                     r_msg2_main_raw(obj, selName, a0, a0Size, a1, a1Size, a2, a2Size, a3, a3Size));
}

bool r_session_msg2_main_struct_ret(RemoteCallSession *session, uint64_t obj, const char *selName,
                                    void *outBuf, size_t outSize,
                                    const void *a0, size_t a0Size,
                                    const void *a1, size_t a1Size,
                                    const void *a2, size_t a2Size,
                                    const void *a3, size_t a3Size)
{
    R_SESSION_RETURN(session, bool, false,
                     r_msg2_main_struct_ret(obj, selName, outBuf, outSize,
                                            a0, a0Size, a1, a1Size, a2, a2Size, a3, a3Size));
}

uint64_t r_session_perform_main(RemoteCallSession *session, uint64_t obj, uint64_t sel, uint64_t object, bool wait)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_perform_main(obj, sel, object, wait));
}

uint64_t r_session_cfstr(RemoteCallSession *session, const char *s)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_cfstr(s));
}

uint64_t r_session_nsstr_retained(RemoteCallSession *session, const char *s)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_nsstr_retained(s));
}

bool r_session_responds(RemoteCallSession *session, uint64_t obj, const char *selName)
{
    R_SESSION_RETURN(session, bool, false, r_responds(obj, selName));
}

bool r_session_responds_main(RemoteCallSession *session, uint64_t obj, const char *selName)
{
    R_SESSION_RETURN(session, bool, false, r_responds_main(obj, selName));
}

uint64_t r_session_ivar_value(RemoteCallSession *session, uint64_t obj, const char *ivarName)
{
    R_SESSION_RETURN(session, uint64_t, 0, r_ivar_value(obj, ivarName));
}

#undef R_SESSION_VOID
#undef R_SESSION_RETURN
#endif
