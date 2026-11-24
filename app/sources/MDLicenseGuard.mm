#define APICLIENT_NO_AUTO_SETUP
#import "APIClient.h"

#import "MDLicenseGuard.h"
#import "MDLog.h"
#import "HUDHelper.h"
#import "MainApplicationDelegate.h"
#import "GameViewController.h"
#import "../KernelBoot.h"
#import "DirectOverlay.h"
#import "SpringBoardOverlay.h"
#import "../../kexploit/kexploit_opa334.h"

#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <atomic>
#include <string.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

static constexpr uint64_t kMDTicketMagic = 0xA55A9E3779B97F4AULL;
static std::atomic<uint64_t> g_mdLeaseTicket{0};
static std::atomic<bool> g_mdConfigured{false};
static void (^g_onRevokedHandler)(NSString *reason) = nil;

static inline const void *MDStripCodePtr(const void *ptr) {
    if (!ptr) return nullptr;
    return (const void *)((uintptr_t)ptr & 0x0000007FFFFFFFFFULL);
}

/// Checks if a critical function was patched with an immediate `MOV W0/X0, #1; RET`
/// or redirected via a Dobby/Substrate/Frida `LDR X16/X17, #8; BR X16/X17` stub,
/// or rebound outside the main executable image.
static BOOL MDFunctionIntegrityOK(const void *rawFn, const void *mainHeader) {
    const void *fn = MDStripCodePtr(rawFn);
    if (!fn) return NO;

    Dl_info info{};
    if (dladdr(fn, &info) == 0 || !info.dli_fbase) {
        return NO;
    }
    if (mainHeader && info.dli_fbase != mainHeader) {
        return NO;
    }

    const uint32_t *insns = reinterpret_cast<const uint32_t *>(fn);
    const uint32_t i0 = insns[0];
    const uint32_t i1 = insns[1];

    // Reject `MOVZ W0, #1; RET` (0x52800020, 0xD65F03C0) and `MOVZ X0, #1; RET` (0xD2800020, 0xD65F03C0)
    if ((i0 == 0x52800020u || i0 == 0xD2800020u) && i1 == 0xD65F03C0u) {
        return NO;
    }
    // Reject `RET` as very first instruction on non-trivial functions
    if (i0 == 0xD65F03C0u) {
        return NO;
    }
    // Reject inline trampoline `LDR X16, #8; BR X16` or `LDR X17, #8; BR X17`
    if ((i0 == 0x58000050u && i1 == 0xD61F0200u) ||
        (i0 == 0x58000051u && i1 == 0xD61F0220u)) {
        return NO;
    }
    return YES;
}

/// Scans loaded dyld images for known dynamic instrumentation libraries.
static BOOL MDDyldEnvironmentClean(void) {
    const uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "FridaGadget") != nullptr ||
            strstr(name, "frida-agent") != nullptr ||
            strstr(name, "cynject") != nullptr ||
            strstr(name, "libcycript") != nullptr) {
            return NO;
        }
    }
    return YES;
}

static BOOL MDVerifyBinaryIntegrity(void) {
    if (!MDDyldEnvironmentClean()) {
        return NO;
    }
    // Resolve our own executable's Mach-O header directly via dladdr rather than
    // _dyld_get_image_header(0), because on iOS 17+ image index 0 can be
    // libobjc-trampolines.dylib instead of the main app binary.
    Dl_info selfInfo{};
    const void *selfFn = MDStripCodePtr((const void *)&MDVerifyBinaryIntegrity);
    const void *mainHdr = (dladdr(selfFn, &selfInfo) != 0) ? selfInfo.dli_fbase : nullptr;

    if (!MDFunctionIntegrityOK((const void *)&APIClientValidConfirmed, mainHdr)) return NO;
    if (!MDFunctionIntegrityOK((const void *)&APIClientPerformAuthorized, mainHdr)) return NO;
    if (!MDFunctionIntegrityOK((const void *)&APIClientStartAuthorization, mainHdr)) return NO;
    if (!MDFunctionIntegrityOK((const void *)&APIClientRenderTemplate, mainHdr)) return NO;
    if (!MDFunctionIntegrityOK((const void *)&kernelBootStart, mainHdr)) return NO;
    if (!MDFunctionIntegrityOK((const void *)&StartESPHost, mainHdr)) return NO;
    return YES;
}

static void MDTriggerRevocationTeardown(NSString *reason) {
    g_mdLeaseTicket.store(0, std::memory_order_release);
    void (^teardown)(void) = ^{
        StopESPSession();
        [MDLog appendLine:[NSString stringWithFormat:@"[LICENSE-GATE] REVOKED reason=%@", reason ?: @"unknown"]];
        if (g_onRevokedHandler) {
            g_onRevokedHandler(reason ?: @"revoked");
        }
    };
    if ([NSThread isMainThread]) {
        teardown();
    } else {
        dispatch_async(dispatch_get_main_queue(), teardown);
    }
}

static void MDConfigureSDKOnce(void) {
    bool expected = false;
    if (!g_mdConfigured.compare_exchange_strong(expected, true)) {
        return;
    }

    setENC(1);

    // Decrypt package token on stack at runtime via compile-time XOR obfuscation,
    // verify prefix/length integrity, configure SDK, then scrub stack bytes.
    const char *obfPtr = TS_OBF_STR("pkg_tYqeAW0RFpdF6vX6HTxA58BaR_eqGFQH");
    char stackToken[64];
    memset(stackToken, 0, sizeof(stackToken));
    strncpy(stackToken, obfPtr, sizeof(stackToken) - 1);

    // Quick structural sanity check on decrypted token ("pkg_" + 32 chars = 36 chars)
    if (strlen(stackToken) == 36 &&
        stackToken[0] == 'p' && stackToken[1] == 'k' &&
        stackToken[2] == 'g' && stackToken[3] == '_') {
        setTokenC(stackToken);
    }

    // Volatile wipe of temporary stack copy and thread-local TS_OBF_STR slot
    volatile char *vp = stackToken;
    for (size_t i = 0; i < sizeof(stackToken); i++) {
        vp[i] = 0;
    }
    if (obfPtr) {
        volatile char *vslot = const_cast<char *>(obfPtr);
        for (size_t i = 0; i < 36; i++) {
            vslot[i] = 0;
        }
    }

    // Register critical host functions & ObjC methods for continuous code-hash checks
    APIClientProtectHostMethod([MainApplicationDelegate class], @selector(buildMainTabController));
    APIClientProtectHostMethod([MainApplicationDelegate class], @selector(application:didFinishLaunchingWithOptions:));
    APIClientProtectHostMethod([GameViewController class], @selector(actionTapped));
    APIClientProtectHostMethod([GameViewController class], @selector(presentBootLogAndStart));
    APIClientProtectHostMethod([GameViewController class], @selector(startHUDForRequest:));

    APIClientProtectHostFunction(MDStripCodePtr((const void *)&kernelBootStart));
    APIClientProtectHostFunction(MDStripCodePtr((const void *)&kernelBootStartKernelOnly));
    APIClientProtectHostFunction(MDStripCodePtr((const void *)&StartESPHost));
    APIClientProtectHostFunction(MDStripCodePtr((const void *)&SBoardStartOverlay));
    APIClientProtectHostFunction(MDStripCodePtr((const void *)&kexploit_opa334));
    APIClientProtectHostFunction(MDStripCodePtr((const void *)&MDLicenseGuardVerifyLive));
    APIClientProtectHostFunction(MDStripCodePtr((const void *)&MDLicenseGuardPerformProtected));
}

BOOL MDLicenseGuardVerifyLive(const char *siteTag) {
    const char *tag = siteTag ? siteTag : "unspecified";

    if (!MDVerifyBinaryIntegrity()) {
        NSLog(@"[LICENSE-GATE] REJECT site=%s reason=integrity_tamper", tag);
        MDTriggerRevocationTeardown(@"integrity_tamper");
        return NO;
    }

    if (!APIClientValidConfirmed()) {
        g_mdLeaseTicket.store(0, std::memory_order_release);
        NSLog(@"[LICENSE-GATE] REJECT site=%s reason=unconfirmed", tag);
        return NO;
    }

    // Synchronously verify the ES256 signed lease and "paid" capability.
    // Do NOT attach a destructive teardown to the async `denied` block here,
    // because TserverAuthorizationLeasePerformCapability's async main-queue
    // callback enforces `gLeaseGeneration == generation` and fires `denied`
    // benignly whenever the 25s background heartbeat rotates to a fresh lease
    // generation. True revocations are delivered via APIClientStartAuthorization's
    // revocation handler.
    BOOL gateOK = APIClientPerformAuthorized(@"paid", nil, nil);
    if (!gateOK) {
        g_mdLeaseTicket.store(0, std::memory_order_release);
        NSLog(@"[LICENSE-GATE] REJECT site=%s reason=perform_authorized_denied", tag);
        return NO;
    }

    uint64_t computedTicket = (((uint64_t)tag[0] << 32) ^ kMDTicketMagic) | 1ULL;
    g_mdLeaseTicket.store(computedTicket, std::memory_order_release);
    NSLog(@"[LICENSE-GATE] OK site=%s", tag);
    return YES;
}

BOOL MDLicenseGuardPerformProtected(const char *siteTag,
                                    dispatch_block_t workBlock) {
    if (!workBlock) return NO;
    if (!MDLicenseGuardVerifyLive(siteTag)) {
        return NO;
    }
    if (!APIClientValidConfirmed() ||
        g_mdLeaseTicket.load(std::memory_order_acquire) == 0) {
        g_mdLeaseTicket.store(0, std::memory_order_release);
        return NO;
    }
    workBlock();
    return YES;
}

BOOL MDLicenseGuardVerifyRenderTick(void) {
    // If called inside the child `-hud` helper process (spawned with argv[1] == "-hud"),
    // MDLicenseGuardBootstrap is not run in that helper process; allow render tick
    // while the main app process enforces the lease and tears down `-hud` on revocation.
    if (!g_mdConfigured.load(std::memory_order_acquire)) {
        return YES;
    }
    if (g_mdLeaseTicket.load(std::memory_order_acquire) == 0) {
        return NO;
    }
    if (!APIClientValidConfirmed()) {
        return NO;
    }
    static CFTimeInterval s_lastVerifyTime = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - s_lastVerifyTime >= 15.0) {
        s_lastVerifyTime = now;
        if (!MDVerifyBinaryIntegrity() || !APIClientPerformAuthorized(@"paid", nil, nil)) {
            MDTriggerRevocationTeardown(@"render_tick_expired");
            return NO;
        }
    }
    return YES;
}

void MDLicenseGuardBootstrap(void (^onAuthorized)(void),
                             void (^onRevoked)(NSString *reason)) {
    g_onRevokedHandler = [onRevoked copy];
    MDConfigureSDKOnce();

    APIClientStartAuthorization(^{
        // Only unlock if live multi-layer verification and signed lease execution succeed
        BOOL verified = MDLicenseGuardPerformProtected("launch_gate", ^{
            if (onAuthorized) {
                onAuthorized();
            }
        });
        if (!verified) {
            MDTriggerRevocationTeardown(@"launch_gate_failed");
        }
    }, ^{
        MDTriggerRevocationTeardown(@"auth_revoked");
    });
}

BOOL MDLicenseGuardHandleOpenURL(NSURL *url) {
    if (!url) return NO;
    return APIClientHandleOpenURL(url);
}

NSString *MDLicenseGuardStatusSummary(void) {
    if (!APIClientValidConfirmed() || g_mdLeaseTicket.load(std::memory_order_acquire) == 0) {
        return @"License: Locked (Chưa kích hoạt key)";
    }
    NSString *rendered = APIClientRenderTemplate(@"Key: %tserver_key% · Hạn: %tserver_timekeyt%");
    if (rendered.length > 0) {
        return rendered;
    }
    return @"License: Active";
}
