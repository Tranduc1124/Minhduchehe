//
//  HUDSpawn.m — spawn self with "-hud" to create the SpringBoard-hosted
//  overlay process. Runs AFTER kernel exploit (child inherits kernel state
//  through re-exploit being unnecessary — the -hud process runs its own
//  GSInitialize/BKS bootstrap).
//
#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/utsname.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <unistd.h>

extern char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, uid_t);

// PID_PATH same as HUDApp.mm writes
#ifndef PID_PATH
#define PID_PATH @"/var/mobile/Library/Caches/com.garena.ffvn.pid"
#endif

int HUDSpawnChild(void) {
    // kill old HUD if pid file exists
    NSString *pidStr = [NSString stringWithContentsOfFile:PID_PATH
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    if (pidStr.length) {
        pid_t old = (pid_t)[pidStr intValue];
        if (old > 0 && kill(old, 0) == 0) kill(old, SIGKILL);
        unlink(PID_PATH.UTF8String);
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    static char *execPath = NULL;
    uint32_t sz = 0;
    _NSGetExecutablePath(NULL, &sz);
    execPath = (char *)calloc(1, sz);
    _NSGetExecutablePath(execPath, &sz);

    const char *args[] = { execPath, "-hud", NULL };
    pid_t child = 0;
    int rc = posix_spawn(&child, execPath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) return rc;
    return 0;
}
