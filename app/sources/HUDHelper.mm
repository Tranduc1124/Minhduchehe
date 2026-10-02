
#import <cstdint>
#import <spawn.h>
#import <notify.h>
#import "rootless.h"
#import <mach-o/dyld.h>

#import "HUDHelper.h"

// Real headers, not forward declarations. This is a .mm, so anything declared
// here without extern "C" gets C++ linkage and the symbol does not match the
// one the linker found in DirectOverlay.mm / SpringBoardOverlay.m. All three
// headers already wrap their declarations.
#import "ESPPrefs.h"
#import "DirectOverlay.h"
#import "SpringBoardOverlay.h"

extern "C" char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

BOOL IsHUDEnabled(void)
{
    NSString *path = ROOT_PATH_NS(PID_PATH);
    NSString *pidString = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!pidString.length)
        return NO;
    pid_t pid = (pid_t)[pidString intValue];
    int k = kill(pid, 0);
    return (k == 0);
}

void SetHUDEnabled(BOOL isEnabled)
{
    notify_post(NOTIFY_DESTROY_HUD);

    // Jailed: just spawn without persona flags (sandbox already escaped).
    static char *executablePath = NULL;
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(NULL, &executablePathSize);
    executablePath = (char *)calloc(1, executablePathSize);
    _NSGetExecutablePath(executablePath, &executablePathSize);

    if (isEnabled)
    {
        pid_t task_pid;
        const char *args[] = { executablePath, "-hud", NULL };
        posix_spawn(&task_pid, executablePath, NULL, NULL, (char **)args, environ);
    }
    else
    {
        NSString *pidString = [NSString stringWithContentsOfFile:ROOT_PATH_NS(PID_PATH)
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil];

        if (pidString)
        {
            pid_t pid = (pid_t)[pidString intValue];
            kill(pid, SIGKILL);
            unlink([ROOT_PATH_NS(PID_PATH) UTF8String]);
        }
    }
}

void RequestExitHUD(void)
{
    const char *path = [ROOT_PATH_NS(PID_PATH) UTF8String];
    if (path) unlink(path);
    exit(0);
}

BOOL IsESPSessionRunning(void)
{
    if (ESPHostIsRunning()) return YES;
    if (SBoardOverlayIsOn()) return YES;
    if (IsHUDEnabled()) return YES;
    // Last, because it is the only signal that can be stale: it records what
    // the user last asked for, not what is running. It is what makes the row
    // turn into a stop button the moment it is tapped rather than a poll later.
    return ESPPrefsBool(@"App_LocalHUDState", NO);
}
