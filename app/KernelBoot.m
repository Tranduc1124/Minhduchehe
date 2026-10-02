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
#import "../esp/esp/ESPPrefs.h"

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
        static const int delays[] = {3, 2, 3, 4}; // cumulative: 3s, 5s, 8s, 12s
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
            NSLog(@"[BOOT] SpringBoard overlay attempt %d failed rc=%d fail=%@ code=%d",
                  attempt + 1, sbret, whyStr, (int)fail);
            // L() is NSString formatting — must use %@ for NSString*, never %s.
            L(@"WARN SB overlay attempt %d rc=%d (%@)",
              attempt + 1, sbret, whyStr);
        }
        L(@"ERR SpringBoard overlay failed after 4 attempts — ESP will not draw over FF.");
    });
}

static void kernelBootStartEx(BOOL kernelOnly) {
    if (g_booting) return;
    if (g_ready) {
        L(@"OK Already booted — re-establishing SpringBoard overlay + ESP host.");
        [[KeepAlive shared] start];
        // A kernel-only boot after the fact must not drag the overlay back up.
        if (kernelOnly) {
            L(@"OK Kernel already ready — nothing else to do.");
            return;
        }
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

        // No platformize here. It was added so the DNS install could reach
        // installd silently, and it returns -1 on this device with "our ucred
        // not found under proc_ro", so nothing depended on it actually
        // succeeding. The HUD process still platformizes and still needs to:
        // that is what puts its window above every other app. This process
        // draws nothing, so it has no reason to pay for the call.
        int sret;
        // Off by default would be wrong: the overlay needs the filesystem write
        // that sandbox_escape sets up, so leaving it on is the default and the
        // switch is there to skip the step when someone wants it off.
        if (ESPPrefsBool(@"SandboxEscapeOn", YES)) {
            sret = sandbox_escape(self_proc);
        } else {
            sret = -1;
        }
        if (sret == 0) {
            L(@"OK Sandbox escaped (R+W filesystem).");
        } else if (ESPPrefsBool(@"SandboxEscapeOn", YES)) {
            L(@"WARN sandbox_escape returned %d", sret);
        } else {
            L(@"SKIP Sandbox escape turned off.");
        }

        L(@"RUN 4/6 Initializing Background KeepAlive");
        [[KeepAlive shared] start];
        L(@"OK KeepAlive started.");

        // Everything below this point is what puts the box on screen. A
        // kernel-only boot stops here: the exploit, the sandbox and KeepAlive
        // are ready, and nothing is drawn until the user asks for it.
        if (kernelOnly) {
            L(@"OK Kernel ready — not starting ESP.");
            g_ready = YES;
            g_booting = NO;
            return;
        }

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

void kernelBootStart(void) { kernelBootStartEx(NO); }
void kernelBootStartKernelOnly(void) { kernelBootStartEx(YES); }

BOOL kernelBootReady(void) { return g_ready; }
