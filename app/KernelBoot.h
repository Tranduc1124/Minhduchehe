//
//  KernelBoot.h — Fl0rk-style 6-step kernel boot, callable from UI
//
#import <Foundation/Foundation.h>

// UI log callback — set this before calling kernelBootStart.
// Called on main thread with each log line ( Fl0rk console style).
typedef void (*kernel_boot_log_fn)(NSString *line);
extern kernel_boot_log_fn kernelBootLog;

// Returns immediately; runs boot on background queue.
// Stages logged: 1/6..6/6 like Fl0rk.
//
// The plain form runs all six and ends with the SpringBoard overlay and the
// ESP host, which is what puts the box on screen. The kernel-only form stops
// after stage 4: exploit, sandbox, KeepAlive, and nothing that draws. It is
// what AutoBootOnLaunch uses, so turning that on gets the exploit ready at
// launch without the ESP appearing on its own.
#ifdef __cplusplus
extern "C" {
#endif
void kernelBootStart(void);
void kernelBootStartKernelOnly(void);
BOOL kernelBootReady(void);
#ifdef __cplusplus
}
#endif
