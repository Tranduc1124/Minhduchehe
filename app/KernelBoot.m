//
//  KernelBoot.m — Fl0rk-style kernel boot
//
//  Main app: kexploit + KeepAlive + hidden ESP host (timer only).
//  Drawing: SpringBoard dedicated UIWindow via RemoteCall (all-apps).
//  No DirectOverlay / SBSAccessibility path.
//

#import "KernelBoot.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/kutils.h"
#import "../sandbox_escape.h"
#import "../esp/DSMemory.h"
#import "../remote/SpringBoardOverlay.h"
#import "../remote/RemoteCall.h"
#import "KeepAlive.h"

kernel_boot_log_fn kernelBootLog = NULL;

static BOOL  g_booting   = NO;
static BOOL  g_ready     = NO;
static dispatch_queue_t g_bootQueue;

static void L(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void L(NSString *fmt, ...) {
    if (!kernelBootLog) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    dispatch_async(dispatch_get_main_queue(), ^{ kernelBootLog(s); });
}

static void boot_start_esp_host(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        extern int StartESPHost(void);
        StartESPHost();
        NSLog(@"[BOOT] ESP host (hidden) — paint via SpringBoard only");
    });
}

static void boot_start_sb_overlay(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Zero on the first attempt, then 1, 2 and 4.
        //
        // This used to be {3, 2, 3, 4}, so the very first attempt slept three
        // seconds before trying anything. That was a three second wait for
        // something that normally works immediately, and it is the whole of the
        // delay the user sees between the ESP host coming up and the overlay
        // appearing. The retries were always there for the case where
        // SpringBoard is not ready yet, and they still are: trying at once and
        // backing off only if it fails is the same behaviour with the wait
        // moved to where it is actually needed.
        static const int delays[] = {0, 1, 2, 4}; // cumulative: 0s, 1s, 3s, 7s
        for (int attempt = 0; attempt < 4; attempt++) {
            sleep(delays[attempt]);
            int sbret = SBoardStartOverlay();
            if (sbret == 0) {
                NSLog(@"[BOOT] SpringBoard overlay OK attempt %d", attempt + 1);
                L(@"OK SpringBoard overlay live (attempt %d).", attempt + 1);
                return;
            }
            RemoteCallInitFailure fail = remote_call_last_init_failure();
            const char *why = remote_call_init_failure_description(fail);
            NSString *whyStr = why ? [NSString stringWithUTF8String:why] : @"?";
            // The measured detail, for the failures that have more than one way to
            // happen. Without it this line said "bootstrap getpid failed (0x101 miss
            // / 0x201?)", which is two guesses about a fork in the road and is all
            // the console had to say about the failure that decides whether the
            // overlay exists at all. The description cannot carry it, being a pure
            // function of the enum, so it is fetched and appended here — in the one
            // place a person can actually read it.
            const char *detail = remote_call_last_init_failure_detail();
            NSString *detailStr = (detail && detail[0])
                                ? [NSString stringWithUTF8String:detail] : @"";
            NSString *full = detailStr.length
                           ? [NSString stringWithFormat:@"%@ — %@", whyStr, detailStr]
                           : whyStr;
            NSLog(@"[BOOT] SpringBoard overlay attempt %d failed rc=%d fail=%@ code=%d",
                  attempt + 1, sbret, whyStr, (int)fail);
            // L() is NSString formatting — must use %@ for NSString*, never %s.
            L(@"WARN SB overlay attempt %d rc=%d (%@)",
              attempt + 1, sbret, full);
        }
        L(@"ERR SpringBoard overlay failed after 4 attempts — ESP will not draw over FF.");
    });
}

void kernelBootStart(void) {
    if (g_booting) return;
    if (g_ready) {
        L(@"OK Already booted — re-establishing SpringBoard overlay + ESP host.");
        [[KeepAlive shared] start];
        boot_start_sb_overlay();
        boot_start_esp_host();
        return;
    }

    g_booting = YES;
    if (!g_bootQueue) {
        g_bootQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    }

    dispatch_async(g_bootQueue, ^{
        L(@"RUN 1/6 Authorizing protected ESP access");
        L(@"OK Device authorized — no key required.");

        L(@"RUN 2/6 Cleaning previous runtime state");
        ds_detach();
        L(@"DONE Cleanup complete.");

        L(@"RUN 3/6 Racing kernel allocator for r/w primitives.");
        L(@"KRW Racing TCP socket zone allocator...");
        int kret = kexploit_opa334();
        extern uint64_t g_dbg_rwSocketPcb;
        extern uint64_t g_dbg_socket;
        extern uint64_t g_dbg_thread;
        L(@"[verify] rwSocketPcb=0x%llx", g_dbg_rwSocketPcb);
        L(@"[verify] socket=0x%llx", g_dbg_socket);
        L(@"[verify] thread=0x%llx", g_dbg_thread);
        if (kret != 0) {
            L(@"ERR Kernel exploit failed (%d)", kret);
            L(@"DONE Boot aborted at stage 3/6.");
            g_booting = NO;
            return;
        }
        L(@"OK Kernel memory r/w acquired.");

        uint64_t self_proc = proc_self();
        int sret = sandbox_escape(self_proc);
        L(sret == 0 ? @"OK Sandbox escaped (R+W filesystem)."
                    : @"WARN sandbox_escape returned %d", sret);

        L(@"RUN 4/6 Initializing Background KeepAlive");
        [[KeepAlive shared] start];
        L(@"OK KeepAlive started.");

        L(@"RUN 5/6 Opening SpringBoard dedicated overlay (staged)");
        boot_start_sb_overlay();
        L(@"OK SpringBoard session pending (background).");

        L(@"RUN 6/6 Starting hidden ESP host (mirror → SpringBoard)");
        boot_start_esp_host();
        L(@"OK ESP host started — draw only via SpringBoard.");
        g_ready = YES;
        g_booting = NO;
    });
}

BOOL kernelBootReady(void) { return g_ready; }
