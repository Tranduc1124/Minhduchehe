#ifdef __cplusplus
extern "C" {
#endif
//
//  RemoteCall.h
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#ifndef RemoteCall_h
#define RemoteCall_h

#import <mach/mach.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

struct VMShmem {
    uint64_t port;
    uint64_t remoteAddress;
    uint64_t localAddress;
    bool     used;
};

// from Duy Tran's TaskPortHaxxApp
// https://github.com/khanhduytran0/TaskPortHaxxApp/blob/pacbypass/TaskPortHaxxApp/Header.h#L83
typedef struct {
    uint64_t __x[29];       /* General purpose registers x0-x28 */
    uint64_t __fp; /* Frame pointer x29 */
    uint64_t __lr; /* Link register x30 */
    uint64_t __sp; /* Stack pointer x31 */
    uint64_t __pc; /* Program counter */
    uint32_t __cpsr;        /* Current program status register */
    uint32_t __flags; /* Flags describing structure format */
} arm_thread_state64_internal;

typedef enum {
    RemoteCallInitFailureNone = 0,
    RemoteCallInitFailureKRWUnavailable,
    RemoteCallInitFailureProcessMissing,
    RemoteCallInitFailureInvalidTask,
    RemoteCallInitFailureExceptionPort,
    RemoteCallInitFailureTaskGuard,
    RemoteCallInitFailureLocalThread,
    RemoteCallInitFailureNoTargetThreads,
    RemoteCallInitFailureFirstExceptionTimeout,
    RemoteCallInitFailureBootstrapGetpid,
    RemoteCallInitFailurePthreadCreate,
    RemoteCallInitFailureCallThread,
    RemoteCallInitFailureThreadResume,
    // The first call on the call thread after the hijacked thread has been restored.
    // It was reported as RemoteCallInitFailureCallThread, which is a different stage
    // entirely and is how a session that had parked both threads correctly still read
    // "synthetic call thread kobject invalid".
    RemoteCallInitFailureFirstStableCall,
    RemoteCallInitFailureRestoreOriginal,
    RemoteCallInitFailureOther,
} RemoteCallInitFailure;

mach_port_t create_exception_port(void);
int disable_excguard_kill(uint64_t task);
// One-shot override consumed by the next call to init_remote_call. When
// non-zero, init_remote_call skips its proc_find_by_name lookup and uses
// this kernel proc address directly. Useful when there are multiple
// processes with the same name (e.g. system vs per-user cfprefsd) and we
// need to target a specific one. Reset to 0 by init_remote_call.
extern uint64_t g_RC_targetProcOverride;
int init_remote_call(const char* process, bool useMigFilterBypass);
int init_remote_call_with_first_exception_timeout(const char* process, bool useMigFilterBypass, int firstExceptionTimeoutMS);
int init_remote_call_original_thread_only_with_first_exception_timeout(const char* process, bool useMigFilterBypass, int firstExceptionTimeoutMS);
uint64_t do_remote_call_stable(int timeout, const char *name, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
uint64_t do_remote_call_stable_addr(int timeout, uint64_t pcAddr, const char *name, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);

// Set x8, the arm64 INDIRECT_RESULT register, for the next call. A function
// returning a struct wider than 16 bytes writes the struct to the address in
// x8 rather than returning it in a register. Zero means no struct return.
void remote_call_set_indirect_result_ptr(uint64_t p);
// Measurement for the SpringBoard main-thread watchdog kill. See the block
// above rc_ipc_lock_measuring in RemoteCall.m for what each number means.
// Any out pointer may be NULL.
void remote_call_main_thread_diag(uint64_t *onMain, uint64_t *holdMaxUS,
                                 uint64_t *holdTotalUS, uint64_t *waitMaxUS,
                                 uint64_t *waitSlow, uint64_t *calls,
                                 uint32_t *lastHolderTid, uint32_t *lastWaiterTid);
// The slowest remote call seen so far, and how many have been slow. A call is
// slow at 500ms, which a healthy one never reaches here. Any out pointer may be
// NULL; the name returns "(none)" until the first slow call.
const char *remote_call_slowest_call_name(void);
void remote_call_slowest_call(uint64_t *maxUS, uint64_t *count, uint32_t *tid);
// Splits the time of a remote call into its two exception waits. wait1 is the
// target thread picking the call up, wait2 is it coming back with the result.
// A timeout count on one side rather than the other says whether the thread
// never took the call or never returned from it, and those are different bugs.
// Any out pointer may be NULL.
void remote_call_wait_split_diag(uint64_t *wait1US, uint64_t *wait2US,
                                 uint64_t *wait1TO, uint64_t *wait2TO,
                                 uint64_t *wait1MaxUS, uint64_t *wait2MaxUS,
                                 int *w2stray, uint32_t *w1sender, uint64_t *w1pc,
                                 uint64_t *borrowed, uint64_t *released,
                                 uint64_t *kept);
// Returns false when the state could not be signed. A false return means the
// state was NOT modified with a signed pc/lr and must not be replied to the
// target: replying an unsigned or zero pc hands the target's thread a jump to
// nowhere.
bool sign_state(uint64_t signingThread, arm_thread_state64_internal *state, uint64_t pc, uint64_t lr);
uint64_t remote_pac(uint64_t remoteThreadAddr, uint64_t address, uint64_t modifier);
bool remote_read(uint64_t src, void *dst, uint64_t size);
uint64_t remote_read64(uint64_t src);
void remote_hexdump(uint64_t remoteAddr, size_t size);
bool remote_write(uint64_t dst, const void *src, uint64_t size);
bool remote_write64(uint64_t dst, uint64_t val);
bool remote_writeStr(uint64_t dst, const char *str);
// Drop every cached page alias. remote_write() can otherwise write through a
// mapping that is no longer the target's live page, silently losing the write.
void remote_clear_shmem_cache(void);
uint64_t remote_call_trojan_mem(void);
int destroy_remote_call(void);
// Drop every piece of local RemoteCall state without trying to IPC the remote
// task. Use this when the remote task is known dead (e.g. SpringBoard just
// crashed and respawned) — destroy_remote_call would otherwise hang for
// 100s on its munmap/pthread_exit calls into a vanished trojan thread.
void abandon_remote_call(void);
bool remote_call_has_local_state(void);
bool remote_call_current_success(void);
int remote_call_current_pid(void);
bool remote_call_uses_vphone_bridge(void);
// True when the thread running a remote call is the target's main thread, which
// is the normal case after init. Callers that want the main thread to do
// something must not then wait on the main thread: that deadlocks SpringBoard
// and backboardd kills it at the 60 second checkin. See the comment on the
// definition for the report that proves it.
bool remote_call_runs_on_target_main_thread(void);
int remote_call_set_stable_timeout_floor_ms(int timeoutMS);
RemoteCallInitFailure remote_call_last_init_failure(void);
uint32_t remote_call_last_init_failure_pid(void);
const char *remote_call_init_failure_description(RemoteCallInitFailure failure);
// A measured detail for the failures that have more than one way to happen, and an
// empty string for the ones that do not. Print it next to the description, which on
// its own cannot distinguish a fork in the road. See the note at its definition.
const char *remote_call_last_init_failure_detail(void);

// How many times the pacia signer produced no result in time on this thread.
//
// Not static, and not in RemoteCall.m, because remote_pac lives in PAC.m and this is
// where the failure it causes is reported from. The count rather than a flag because
// the difference between a signer that timed out once on a busy device and a signer
// that timed out on every attempt is the difference between a budget and a bug, and
// only the count says which.
extern __thread int g_RC_pacWaitTimeouts;

// What the bootstrap getpid came back with, kept only so a failure can report it.
//
// Deliberately not used to decide success. The bootstrap getpid is a proof that the
// parked thread can be driven, and a pid is not that; see the note at the call site.
extern __thread uint64_t g_RC_bootstrapPid;

// Which branch of the synthetic call thread construction gave up, so that
// "synthetic call thread kobject invalid" stops being one sentence for nine different
// failures. Read by remote_call_last_init_failure_detail; the values are listed at
// its definition.
extern __thread int g_RC_callThreadStep;

#ifdef __OBJC__
@class RemotePointer;

@interface RemoteCallSession : NSObject

@property(nonatomic, readonly) uint64_t taskAddr;
@property(nonatomic, readonly) uint64_t trojanMem;
@property(nonatomic, readonly) int pid;

- (instancetype)initWithProcess:(NSString *)process useMigFilterBypass:(BOOL)useMigFilterBypass;
- (instancetype)initWithProcess:(NSString *)process
              useMigFilterBypass:(BOOL)useMigFilterBypass
         firstExceptionTimeoutMS:(int)firstExceptionTimeoutMS;
- (instancetype)initWithProcess:(NSString *)process
              useMigFilterBypass:(BOOL)useMigFilterBypass
         firstExceptionTimeoutMS:(int)firstExceptionTimeoutMS
              originalThreadOnly:(BOOL)originalThreadOnly;
- (uint64_t)doRemoteCallStableWithTimeout:(int)timeout
                             functionName:(const char *)name
                                       x0:(uint64_t)x0
                                       x1:(uint64_t)x1
                                       x2:(uint64_t)x2
                                       x3:(uint64_t)x3
                                       x4:(uint64_t)x4
                                       x5:(uint64_t)x5
                                       x6:(uint64_t)x6
                                       x7:(uint64_t)x7;
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
                                       x7:(uint64_t)x7;
- (BOOL)remoteRead:(uint64_t)src to:(void *)dst size:(uint64_t)size;
- (uint64_t)remoteRead64:(uint64_t)src;
- (BOOL)remoteWrite:(uint64_t)dst from:(const void *)src size:(uint64_t)size;
- (BOOL)remoteWrite64:(uint64_t)dst value:(uint64_t)val;
- (BOOL)remoteWriteString:(uint64_t)dst value:(const char *)str;
- (int)destroyRemoteCall;
- (void)abandonRemoteCall;
- (BOOL)hasLocalState;
- (RemotePointer *)objectAtIndexedSubscript:(NSUInteger)address;

@end

@interface RemotePointer : NSObject

@property(nonatomic, strong, readonly) RemoteCallSession *session;
@property(nonatomic, readonly) uint64_t address;

@property(nonatomic, copy) NSString *string;
@property(nonatomic) uint8_t value8;
@property(nonatomic) uint16_t value16;
@property(nonatomic) uint32_t value32;
@property(nonatomic) uint64_t value64;

- (instancetype)initWithSession:(RemoteCallSession *)session address:(uint64_t)address;
- (BOOL)writeCString:(const char *)string;
- (BOOL)readTo:(void *)dst size:(uint64_t)size;
- (BOOL)writeFrom:(const void *)src size:(uint64_t)size;
- (NSString *)stringWithMaxLength:(size_t)maxLength;

@end

void remote_call_with_session(RemoteCallSession *session, void (^block)(void));
#endif

#ifdef __cplusplus
}
#endif

#endif /* RemoteCall_h */
