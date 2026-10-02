#import <Foundation/Foundation.h>

// Installs an iOS DNS profile without a kernel.
//
// How it works. A .mobileconfig is an ordinary file that iOS will install from
// any HTTPS URL: Safari downloads it, iOS raises "Profile Downloaded", and the
// user taps Install. No entitlement is involved and nothing in the exploit is
// used. So the profile is written to disk, served over loopback by a one-shot
// HTTP listener bound to 127.0.0.1, and the URL is handed to Safari.
//
// What it cannot do. com.apple.dnsproxy.managed is the only DNS payload type
// iOS accepts, and it holds nothing but DNS server addresses. There is no
// field for "do not resolve these domains", so the reject rules in a
// sing-box style config have nowhere to go in a profile. This installs DNS
// servers and nothing else. MatchDomains scopes which domains use them; it
// does not block anything.
//
// iOS also refuses to deep link into General > VPN & Device Management, so
// after the install prompt the user walks there themselves. The screen says
// so rather than pretending otherwise.

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, MDDNSInstallOutcome) {
    MDDNSInstallOutcomeFailed = 0,
    // installd took the profile. It is in Settings, waiting to be switched on.
    MDDNSInstallOutcomeInstalled,
    // installd was not reachable, so the profile is being served over loopback
    // and iOS is about to ask the user whether to install it.
    MDDNSInstallOutcomeHandedOff,
};

// DNS servers the profile carries, in the order iOS will try them. One
// function so the list is editable in one place.
NSArray<NSString *> *MDDNSServerList(void);

// The profile as XML, for the log and for writing to disk.
NSString *MDDNSProfileXML(void);

// Writes the profile into the app container and starts a loopback listener for
// it. Returns the URL to open, or nil with a reason in errOut.
NSString *_Nullable MDDNSStartProfileServer(NSString *__autoreleasing *_Nullable errOut);

// Opens the URL handed back by MDDNSStartProfileServer. Reports through the
// completion whether iOS accepted the URL; passing nil skips the report.
void MDDNSOpenProfile(NSString *url,
                      void (^_Nullable done)(BOOL accepted));

// Reads the installed iOS configuration through NEVPNManager. Returns what it
// found and, on failure, the reason in errorOut. Without the
// networkextension entitlement this always fails with
// NEConfigurationErrorDomain code 10, which is why the screen shows it rather
// than hiding it: the failure is real and the user should see it.
NSString *MDDNSProbeConfiguration(NSString *__autoreleasing *_Nullable errorOut);

// The whole thing. Tries installd through the private MobileInstallation
// framework first, which needs no URL and no prompt; when any gate on that
// path is closed it falls back to serving the profile over loopback. Logs
// which gate closed rather than failing silently.
//
// Call from the main thread. The installd attempt blocks on an XPC answer, so
// it runs on a background queue; the loopback handoff needs the main thread
// because UIApplication does, and the completion comes back on the main thread.
typedef void (^MDDNSInstallCompletion)(MDDNSInstallOutcome outcome,
                                      NSString *_Nullable failure,
                                      NSString *_Nullable url);
void MDDNSInstall(MDDNSInstallCompletion completion);

#ifdef __cplusplus
}
#endif