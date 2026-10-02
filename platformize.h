//
//  platformize.h — self-platformization via kernel rw
//  Swap our AMFI cred slot (l_perpolicy[0]) with launchd's →
//  proc gets platform-application + full mach-lookup privileges
//  without any entitlements on the binary.
//
#ifndef platformize_h
#define platformize_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns 0 on success. Call AFTER sandbox_elevate_to_root() succeeded
// (we need to write launchd's slot into ours), and BEFORE sandbox_escape():
// sandbox_escape rewrites the sandbox extension chain of the same cred that
// this copies launchd's AMFI slot into, and escaping first leaves the copy
// reading a cred the escape has already rotated. That order was wrong until a
// device log showed platformize_self returning -1 with no reason given.
int platformize_self(uint64_t self_proc);

// Why the last platformize_self returned non-zero, in words. Empty-string safe
// and never NULL; "unknown" before the first call or after a success. Set for
// logging, not for control flow: a bare -1 is what sent a failed DNS install
// silently down its fallback path.
const char *platformize_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* platformize_h */