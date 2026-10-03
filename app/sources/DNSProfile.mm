#import "DNSProfile.h"
#import "MDLog.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <sys/time.h>
#import <unistd.h>
#import <UIKit/UIKit.h>

// Installs the bundled iOS DNS profile the ordinary way: serve it over loopback
// and let Safari hand it to iOS.
//
// This used to try installd first, through MobileInstallation.framework and
// MCInstallationCopyProfile, which would install silently and then deep link
// into Settings. Both halves are gone, on the evidence rather than on taste:
//
// The silent path never ran. platformize_self fails on device with "our ucred
// not found under proc_ro", so the process never became platform-application,
// so mach-lookup to installd was never available and every install fell to the
// loopback path below. The code that was supposed to save it kept claiming the
// one-tap flow in the UI while doing the opposite.
//
// The deep link was not reachable either. It needs the same platformize, and
// on a process that is not platformized iOS rejects App-prefs: outright.
//
// So the honest version of this screen is the one that always worked: write
// the profile, serve it, open Safari, iOS asks, the user taps Install. One tap
// more than the silent path, and it works on any device.
//
// What the profile does is unchanged. It is the bundled
// ff-fixbanid-dns.mobileconfig, byte for byte, and its two
// com.apple.dnsSettings.managed payloads assign the domains to be blocked to a
// DoH URL that does not resolve, so they do not resolve. That is the whole
// trick and it needs nothing from this file.

static NSString *const kMDDNSPayloadID = @"com.tserver.ff.dns.1in1";
static NSString *const kMDDNSResource   = @"ff-fixbanid-dns";
static NSString *const kMDDNSFileName   = @"ff-fixbanid-dns.mobileconfig";

// iOS keeps installed profiles here. Reading the directory back is how the
// screen answers "iOS configuration" without an entitlement this build does
// not have: NEVPNManager would fail with NEConfigurationErrorDomain code 10
// every time, which is the error the reference app shows on its own screen.
static const char *const kMDDNSProfileDirs[] = {
    "/var/mobile/Library/ConfigurationProfiles",
    "/var/mobile/Library/ConfigurationProfiles/Profiles",
    NULL,
};

// The DoH endpoints the payload names, read out of the file rather than kept
// in step with it by hand.
NSArray<NSString *> *MDDNSServerList(void) {
    NSString *xml = MDDNSProfileXML();
    NSMutableArray *out = [NSMutableArray array];
    NSRegularExpression *server =
        [NSRegularExpression regularExpressionWithPattern:@"<key>ServerURL</key>\\s*<string>([^<]+)</string>"
                                                 options:0
                                                   error:NULL];
    for (NSTextCheckingResult *hit in [server matchesInString:xml
                                                     options:0
                                                       range:NSMakeRange(0, xml.length)]) {
        NSRange r = [hit rangeAtIndex:1];
        if (r.location == NSNotFound) continue;
        [out addObject:[xml substringWithRange:r]];
    }
    return out.count ? out : @[ @"none" ];
}

// Domains the payload sends to the address that does not exist. Counted from
// the file so the screen cannot claim a number the payload does not carry.
NSUInteger MDDNSBlockedDomainCount(void) {
    NSString *xml = MDDNSProfileXML();
    NSRegularExpression *domains =
        [NSRegularExpression regularExpressionWithPattern:@"<string>[^<]*\\.(?:com|net|co|io|now)</string>"
                                                 options:0
                                                   error:NULL];
    return [domains numberOfMatchesInString:xml
                                    options:0
                                      range:NSMakeRange(0, xml.length)];
}

NSString *MDDNSProfileXML(void) {
    NSString *path = [[NSBundle mainBundle] pathForResource:kMDDNSResource
                                                     ofType:@"mobileconfig"];
    if (path) {
        NSString *contents = [NSString stringWithContentsOfFile:path
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
        if (contents.length) return contents;
    }
    // A missing resource must never read as an install that quietly did
    // nothing. The fallback is a valid plist carrying a payload type iOS will
    // reject loudly, so the failure shows up instead of passing as success.
    return @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<plist version=\"1.0\"><dict><key>PayloadType</key>"
            @"<string>com.minhduc.nosuchprofile</string><key>PayloadVersion</key>"
            @"<integer>1</integer></dict></plist>";
}

// ---------------------------------------------------------------------------
// Loopback listener
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
    tv.tv_sec = 8;
    tv.tv_usec = 0;
    setsockopt(listenFD, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    // Bounded: at most ten requests, and accept gives up after eight idle
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

NSString * _Nullable MDDNSStartProfileServer(NSString * _Nullable * _Nullable errOut) {
    NSString *xml = MDDNSProfileXML();
    NSData *body = [xml dataUsingEncoding:NSUTF8StringEncoding];

    // Keep the file in the container as well. The user can pull it out of the
    // Files app if Safari ever refuses to install it.
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

NSString *MDDNSProbeConfiguration(NSString * _Nullable * _Nullable errorOut) {
    if (errorOut) *errorOut = nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *missing = nil;

    for (int i = 0; kMDDNSProfileDirs[i] != NULL; i++) {
        NSString *dir = [NSString stringWithUTF8String:kMDDNSProfileDirs[i]];

        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
            // Not an error: these are candidate locations and most of them do
            // not exist on any given install. Reporting it as one is what put
            // "The folder Profiles doesn't exist" in front of the user in red,
            // which reads like a broken feature rather than a path that was
            // never going to be there.
            if (!missing) missing = dir;
            continue;
        }

        NSError *listErr = nil;
        NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:&listErr];
        if (!entries) {
            if (errorOut) {
                *errorOut = [NSString stringWithFormat:@"cannot read %@: %@",
                             dir.lastPathComponent, listErr.localizedDescription];
            }
            return @"Unknown";
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

    if (errorOut) {
        *errorOut = [NSString stringWithFormat:@"no profile store yet (%@)",
                     missing.lastPathComponent ?: @"unknown path"];
    }
    return @"Unknown";
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------

void MDDNSInstall(MDDNSInstallCompletion completion) {
    [MDLog appendLine:[NSString stringWithFormat:
                       @"[dns] %lu server(s): %@",
                       (unsigned long)MDDNSServerList().count,
                       [MDDNSServerList() componentsJoinedByString:@", "]]];
    [MDLog appendLine:[NSString stringWithFormat:
                       @"[dns] payload names %lu domain(s) across the allow and block groups.",
                       (unsigned long)MDDNSBlockedDomainCount()]];

    NSString *serverErr = nil;
    NSString *url = MDDNSStartProfileServer(&serverErr);
    if (!url) {
        [MDLog appendLine:@"[dns] ERR could not serve the profile."];
        if (completion) completion(MDDNSInstallOutcomeFailed, serverErr, nil);
        return;
    }

    [MDLog appendLine:[NSString stringWithFormat:@"[dns] serving on %@", url]];
    MDDNSOpenProfile(url, ^(BOOL accepted) {
        if (completion) {
            completion(accepted ? MDDNSInstallOutcomeHandedOff : MDDNSInstallOutcomeFailed,
                       accepted ? nil : @"iOS refused the profile URL", url);
        }
    });
}