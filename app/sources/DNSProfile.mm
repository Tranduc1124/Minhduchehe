#import "DNSProfile.h"
#import "MDLog.h"
#import "KernelBoot.h"

#import "platformize.h"
#import "kexploit/kutils.h"

#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <sys/time.h>
#import <unistd.h>
#import <UIKit/UIKit.h>

// Payload identifier. The status check greps installed profiles for this, so
// it has to match the identifier baked into MDDNSProfileXML.
static NSString *const kMDDNSPayloadID = @"com.minhduc.dnsprofile";
static NSString *const kMDDNSFileName  = @"MINHDUC-DNS.mobileconfig";

// iOS keeps every installed profile here, and the copy it made of what we
// handed installd is one of these files. Reading the directory back is how the
// screen answers "iOS configuration" without a private API and without
// NetworkExtension, which this build cannot load a config through anyway
// (no entitlement, so NEVPNManager fails with NEConfigurationErrorDomain 10).
static const char *const kMDDNSProfileDirs[] = {
    "/var/mobile/Library/ConfigurationProfiles",
    "/var/mobile/Library/ConfigurationProfiles/Profiles",
    NULL,
};

NSArray<NSString *> *MDDNSServerList(void) {
    // Order matters: iOS tries them in sequence and falls through on timeout.
    return @[ @"1.1.1.1", @"1.0.0.1", @"8.8.8.8", @"8.8.4.4" ];
}

static NSString *MDUUID(void) {
    return [[[NSUUID UUID] UUIDString] uppercaseString];
}

NSString *MDDNSProfileXML(void) {
    NSMutableString *proxies = [NSMutableString string];
    for (NSString *server in MDDNSServerList()) {
        [proxies appendString:
            @"\t\t<dict>\n"
             "\t\t\t<key>Server</key>\n"
             "\t\t\t<string>"];
        [proxies appendString:server];
        [proxies appendString:
            @"</string>\n"
             "\t\t\t<key>Type</key>\n"
             "\t\t\t<string>UDP</string>\n"
             "\t\t</dict>\n"];
    }

    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
         "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
         "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
         "<plist version=\"1.0\">\n"
         "<dict>\n"
         "\t<key>PayloadContent</key>\n"
         "\t<array>\n"
         "\t\t<dict>\n"
         "\t\t\t<key>DNSSettings</key>\n"
         "\t\t\t<dict>\n"
         "\t\t\t\t<key>DNSProxies</key>\n"
         "\t\t\t\t<array>\n"
         "%@"
         "\t\t\t\t</array>\n"
         "\t\t\t\t<key>MatchDomains</key>\n"
         "\t\t\t\t<array/>\n"
         "\t\t\t</dict>\n"
         "\t\t\t<key>PayloadDescription</key>\n"
         "\t\t\t<string>MINHDUC DNS servers</string>\n"
         "\t\t\t<key>PayloadDisplayName</key>\n"
         "\t\t\t<string>MINHDUC DNS</string>\n"
         "\t\t\t<key>PayloadIdentifier</key>\n"
         "\t\t\t<string>%@</string>\n"
         "\t\t\t<key>PayloadType</key>\n"
         "\t\t\t<string>com.apple.dnsproxy.managed</string>\n"
         "\t\t\t<key>PayloadUUID</key>\n"
         "\t\t\t<string>%@</string>\n"
         "\t\t\t<key>PayloadVersion</key>\n"
         "\t\t\t<integer>1</integer>\n"
         "\t\t</dict>\n"
         "\t</array>\n"
         "\t<key>PayloadDescription</key>\n"
         "\t<string>Installs the MINHDUC DNS servers.</string>\n"
         "\t<key>PayloadDisplayName</key>\n"
         "\t<string>MINHDUC DNS</string>\n"
         "\t<key>PayloadIdentifier</key>\n"
         "\t<string>%@</string>\n"
         "\t<key>PayloadOrganization</key>\n"
         "\t<string>MINHDUC</string>\n"
         "\t<key>PayloadRemovalDisallowed</key>\n"
         "\t<false/>\n"
         "\t<key>PayloadType</key>\n"
         "\t<string>Configuration</string>\n"
         "\t<key>PayloadUUID</key>\n"
         "\t<string>%@</string>\n"
         "\t<key>PayloadVersion</key>\n"
         "\t<integer>1</integer>\n"
         "</dict>\n"
         "</plist>\n",
        proxies, kMDDNSPayloadID, MDUUID(), kMDDNSPayloadID, MDUUID()];
}

// ---------------------------------------------------------------------------
// installd, through the private MobileInstallation framework
// ---------------------------------------------------------------------------

typedef void (^MDInstallationCopyProfileBlock)(CFErrorRef error);
typedef Boolean (*MDInstallationCopyProfileFn)(CFAllocatorRef,
                                               CFDictionaryRef,
                                               uint32_t,
                                               MDInstallationCopyProfileBlock);

static void *g_miLib = NULL;
static BOOL g_platformized = NO;

static BOOL MDDNGSelfPlatformize(void) {
    if (g_platformized) return YES;
    uint64_t sp = proc_self();
    int r = platformize_self(sp);
    [MDLog appendLine:[NSString stringWithFormat:@"[dns] platformize_self=%d", r]];
    if (r != 0) return NO;
    g_platformized = YES;
    return YES;
}

static MDInstallationCopyProfileFn MDDNGLocateCopyProfile(void) {
    if (g_miLib) {
        return (MDInstallationCopyProfileFn)dlsym(g_miLib, "MCInstallationCopyProfile");
    }
    const char *path =
        "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation";
    g_miLib = dlopen(path, RTLD_LAZY);
    if (!g_miLib) {
        [MDLog appendLine:[NSString stringWithFormat:@"[dns] dlopen failed: %s",
                         dlerror() ? dlerror() : "unknown"]];
        return NULL;
    }
    const char *names[] = { "MCInstallationCopyProfile",
                            "MCInstallationCopyProfileWithResult",
                            "MCInstallationCMD" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        void *sym = dlsym(g_miLib, names[i]);
        [MDLog appendLine:[NSString stringWithFormat:@"[dns] dlsym %s -> %@", names[i],
                         sym ? @"found" : @"missing"]];
        if (sym && i == 0) return (MDInstallationCopyProfileFn)sym;
    }
    return NULL;
}

static NSString *MDDNSDescribeCFError(CFErrorRef err) {
    if (!err) return @"none";
    // There is no CFErrorCopyDomain: CFError is toll-free bridged to NSError,
    // and going through NSError is also what gets the localized description.
    NSError *error = (__bridge NSError *)err;
    CFStringRef desc = CFErrorCopyDescription(err);
    return [NSString stringWithFormat:@"%@ (%@, %ld)",
            (__bridge NSString *)desc ?: error.localizedDescription ?: @"?",
            error.domain ?: @"?",
            (long)error.code];
}

// Returns YES only when installd accepted the profile. Every step logs, so a
// failure says which of the four gates closed: no exploit, no mach-lookup, no
// symbol, or installd refusing.
static BOOL MDDNSInstallViaInstalld(NSString *xml, NSString **why) {
    if (!kernelBootReady()) {
        if (why) *why = @"the exploit has not run yet";
        return NO;
    }
    if (!MDDNGSelfPlatformize()) {
        if (why) *why = @"platformize_self failed, no mach-lookup for installd";
        return NO;
    }

    MDInstallationCopyProfileFn copyProfile = MDDNGLocateCopyProfile();
    if (!copyProfile) {
        if (why) *why = @"MobileInstallation has no MCInstallationCopyProfile";
        return NO;
    }

    NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    // CFPropertyListCreateFromXMLData is deprecated and on this SDK its
    // four-argument form is the only one declared, which is why the extra NULL
    // in the docs is not here.
    CFPropertyListRef plist = CFPropertyListCreateFromXMLData(kCFAllocatorDefault,
                                                              (__bridge CFDataRef)data,
                                                              kCFPropertyListImmutable,
                                                              NULL);
    if (!plist || CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
        if (plist) CFRelease(plist);
        if (why) *why = @"the profile XML did not parse";
        return NO;
    }

    [MDLog appendLine:@"[dns] handing the profile to installd."];
    __block CFErrorRef blockErr = NULL;
    __block BOOL answered = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    Boolean queued = copyProfile(kCFAllocatorDefault,
                                 (CFDictionaryRef)plist,
                                 0,
                                 ^(CFErrorRef e) {
        answered = YES;
        if (e) blockErr = e;
        dispatch_semaphore_signal(sem);
    });
    CFRelease(plist);

    if (!queued) {
        if (why) *why = @"MCInstallationCopyProfile refused to queue the profile";
        return NO;
    }

    // installd answers over XPC. No answer means the call went out and was
    // dropped, which is a different fault from installd saying no.
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                  20 * NSEC_PER_SEC)) != 0) {
        if (why) *why = @"installd did not answer within 20s";
        [MDLog appendLine:@"[dns] timed out waiting for installd."];
        return NO;
    }
    if (!answered) {
        if (why) *why = @"installd returned no completion";
        return NO;
    }
    if (blockErr) {
        if (why) *why = [NSString stringWithFormat:@"installd: %@", MDDNSDescribeCFError(blockErr)];
        return NO;
    }

    [MDLog appendLine:@"[dns] installd accepted the profile."];
    return YES;
}

// ---------------------------------------------------------------------------
// Loopback fallback: serve the profile and let iOS ask to install it
// ---------------------------------------------------------------------------

static void MDDNSServeLoopback(int listenFD, NSData *body) {
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
         "Content-Type: application/x-apple-aspen-config\r\n"
         "Content-Length: %lu\r\n"
         "Content-Disposition: attachment; filename=\"%@\"\r\n"
         "Cache-Control: no-store\r\n"
         "Connection: close\r\n\r\n",
        (unsigned long)body.length, kMDDNSFileName];
    NSMutableData *response = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:body];

    struct timeval tv;
    tv.tv_sec = 3;
    tv.tv_usec = 0;
    setsockopt(listenFD, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    // Bounded: at most ten requests, and accept gives up after three idle
    // seconds, so the descriptor cannot outlive the tap by much.
    for (int served = 0; served < 10; served++) {
        int fd = accept(listenFD, NULL, NULL);
        if (fd < 0) break;
        char request[1024];
        recv(fd, request, sizeof(request), 0);
        NSUInteger offset = 0;
        while (offset < response.length) {
            ssize_t n = send(fd, (const char *)response.bytes + offset,
                             response.length - offset, 0);
            if (n <= 0) break;
            offset += (NSUInteger)n;
        }
        shutdown(fd, SHUT_WR);
        close(fd);
    }
    close(listenFD);
}

NSString *_Nullable MDDNSStartProfileServer(NSString *__autoreleasing *_Nullable errOut) {
    NSString *xml = MDDNSProfileXML();
    NSData *body = [xml dataUsingEncoding:NSUTF8StringEncoding];

    // Keep the file in the container either way. If installd refuses, this is
    // the copy the user can still hand to something else.
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    if (docs) {
        NSString *path = [docs stringByAppendingPathComponent:kMDDNSFileName];
        NSError *writeErr = nil;
        if ([body writeToFile:path options:NSDataWritingAtomic error:&writeErr]) {
            [MDLog appendLine:[NSString stringWithFormat:@"[dns] wrote %lu bytes to %@",
                             (unsigned long)body.length, path]];
        } else {
            [MDLog appendLine:[NSString stringWithFormat:@"[dns] could not write the file: %@",
                             writeErr.localizedDescription]];
        }
    }

    int listenFD = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFD < 0) {
        if (errOut) *errOut = @"could not open a socket";
        return nil;
    }
    int one = 1;
    setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = 0;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(listenFD, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(listenFD, 8) != 0) {
        close(listenFD);
        if (errOut) *errOut = @"could not bind to loopback";
        return nil;
    }

    socklen_t addrLen = sizeof(addr);
    if (getsockname(listenFD, (struct sockaddr *)&addr, &addrLen) != 0) {
        close(listenFD);
        if (errOut) *errOut = @"the loopback port is unknown";
        return nil;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        MDDNSServeLoopback(listenFD, body);
    });

    return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@",
            (unsigned)ntohs(addr.sin_port), kMDDNSFileName];
}

void MDDNSOpenProfile(NSString *url, void (^_Nullable done)(BOOL accepted)) {
    NSURL *target = [NSURL URLWithString:url];
    UIApplication *app = [UIApplication sharedApplication];
    if (!target || ![app canOpenURL:target]) {
        [MDLog appendLine:@"[dns] iOS would not take the loopback URL."];
        if (done) done(NO);
        return;
    }

    // Safari needs the listener to still be up when it fetches, and the app is
    // about to be suspended. The background task buys the seconds it needs.
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    task = [app beginBackgroundTaskWithName:@"DNS profile handoff"
                         expirationHandler:^{
        if (task != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
    }];

    [app openURL:target options:@{} completionHandler:^(BOOL ok) {
        [MDLog appendLine:[NSString stringWithFormat:@"ok=%d iOS %@ the profile URL.",
                         (int)ok, ok ? @"took" : @"refused"]];
        if (task != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
        if (done) done(ok);
    }];
}

// ---------------------------------------------------------------------------
// What iOS actually holds
// ---------------------------------------------------------------------------

NSString *MDDNSProbeConfiguration(NSString *__autoreleasing *_Nullable errorOut) {
    if (errorOut) *errorOut = nil;

    for (int i = 0; kMDDNSProfileDirs[i] != NULL; i++) {
        NSString *dir = [NSString stringWithUTF8String:kMDDNSProfileDirs[i]];
        NSError *listErr = nil;
        NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir
                                                                                error:&listErr];
        if (!entries) {
            if (errorOut) {
                *errorOut = [NSString stringWithFormat:@"cannot read %@: %@", dir.lastPathComponent,
                             listErr.localizedDescription];
            }
            continue;
        }

        for (NSString *name in entries) {
            if (![name.pathExtension.lowercaseString isEqualToString:@"mobileconfig"]) continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSString *body = [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
            if (!body) continue;
            if ([body rangeOfString:kMDDNSPayloadID].location == NSNotFound) continue;

            [MDLog appendLine:[NSString stringWithFormat:@"[dns] found installed profile %@", name]];
            return @"Installed";
        }
        return @"Not installed";
    }

    return @"Unknown";
}

// ---------------------------------------------------------------------------
// Entry point used by the screen
// ---------------------------------------------------------------------------

// The installd half only. The loopback half is left to the main thread,
// because UIApplication will not take beginBackgroundTask from anywhere else.
static MDDNSInstallOutcome MDDNSInstallViaInstalldStep(NSString *__autoreleasing *whyOut) {
    NSString *xml = MDDNSProfileXML();
    [MDLog appendLine:[NSString stringWithFormat:
                       @"[dns] profile carries %lu server(s): %@",
                       (unsigned long)MDDNSServerList().count,
                       [MDDNSServerList() componentsJoinedByString:@", "]]];

    if (MDDNSInstallViaInstalld(xml, whyOut)) return MDDNSInstallOutcomeInstalled;

    [MDLog appendLine:[NSString stringWithFormat:@"[dns] installd path unavailable: %@",
                     whyOut && *whyOut ? *whyOut : @"unknown"]];
    return MDDNSInstallOutcomeFailed;
}

void MDDNSInstall(MDDNSInstallCompletion completion) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *why = nil;
        MDDNSInstallOutcome outcome = MDDNSInstallViaInstalldStep(&why);

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *failure = nil;
            NSString *url = nil;
            MDDNSInstallOutcome result = outcome;

            if (outcome != MDDNSInstallOutcomeInstalled) {
                NSString *serverErr = nil;
                url = MDDNSStartProfileServer(&serverErr);
                if (url) {
                    [MDLog appendLine:[NSString stringWithFormat:@"[dns] serving on %@", url]];
                    MDDNSOpenProfile(url, nil);
                    result = MDDNSInstallOutcomeHandedOff;
                } else {
                    failure = [NSString stringWithFormat:@"%@; and the fallback failed: %@",
                               why ?: @"installd unavailable", serverErr];
                    result = MDDNSInstallOutcomeFailed;
                }
            }
            if (completion) completion(result, failure, url);
        });
    });
}