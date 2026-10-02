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
// (we need to write launchd's slot into ours).
//
// Only the HUD process calls this, and it needs to: platformize is what makes
// AMFI treat that process as a system app, which is what puts its window above
// every other app. The main app process does not, because it draws nothing.
int platformize_self(uint64_t self_proc);

#ifdef __cplusplus
}
#endif

#endif /* platformize_h */