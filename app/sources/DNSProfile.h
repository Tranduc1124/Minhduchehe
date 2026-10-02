#import <Foundation/Foundation.h>

// Installs the bundled iOS DNS profile.
//
// The profile is app/layout/Resources/ff-fixbanid-dns.mobileconfig, installed
// byte for byte. Nothing here generates one.
//
// Two install paths, and the second is a fallback rather than a second choice.
// MDDNSInstall tries installd through the private MobileInstallation
// framework, which needs no URL and no prompt. That is the path that can
// finish in one tap, and it is only reachable because this tree already
// platformizes the process, which is what makes mach-lookup to a system
// daemon pass. When any gate on it is closed the profile is served over
// loopback and handed to Safari instead, which works anywhere but costs a
// prompt.
//
// iOS refuses to deep link into General > VPN & Device Management, so after
// installing, switching the profile on is the user's tap. The screen says so
// rather than implying the app did it.
//
// One thing not to "fix" in the payload: it has no AllowFailover key. Apple
// documents that key as defaulting to false, and false is the only value that
// makes the block group work. Setting it to true lets every failed DoH query
// fall back to the system resolver, and the blocked domains resolve normally.

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MDDNSInstallOutcome) {
    MDDNSInstallOutcomeFailed = 0,
    // installd took the profile. It is in Settings, waiting to be switched on.
    MDDNSInstallOutcomeInstalled,
    // installd was not reachable, so the profile is being served over loopback
    // and iOS is about to ask the user whether to install it.
    MDDNSInstallOutcomeHandedOff,
};

// The DoH endpoints the payload names, read out of the file. Not editable
// here on purpose: a list kept by hand next to a file it describes drifts.
NSArray<NSString *> *MDDNSServerList(void);

// The bundled profile, verbatim.
NSString *MDDNSProfileXML(void);

// Domains named in the payload, across the allow group and the block group
// together. Not a blocked count; the two groups split them and this does not.
NSUInteger MDDNSBlockedDomainCount(void);

// Writes the profile into the app container and starts a loopback listener for
// it. Returns the URL to open, or nil with a reason in errOut.
// Spaced out on purpose. Written as NSString *__autoreleasing *_Nullable clang
// reads the two stars as one pointer and then complains the pointer has no
// nullability, which -Werror turns into a build failure.
NSString * _Nullable MDDNSStartProfileServer(NSString * _Nullable * _Nullable errOut);

// Opens the URL handed back by MDDNSStartProfileServer. Reports through the
// completion whether iOS accepted the URL; passing nil skips the report.
void MDDNSOpenProfile(NSString *url,
                      void (^_Nullable done)(BOOL accepted));

// What iOS is actually holding, read from the profiles directory rather than
// from NEVPNManager. This build has no networking.networkextension
// entitlement, so NEVPNManager cannot work: loadFromPreferences fails with
// NEConfigurationErrorDomain code 10 every time. Grepping
// /var/mobile/Library/ConfigurationProfiles for the payload identifier we
// install answers the same question with evidence, and needs no entitlement
// the binary does not have.
//
// Returns "Installed" or "Not installed". errorOut carries the reason when
// the directory could not be read at all, which is the state before the
// exploit has escaped the sandbox.
NSString *MDDNSProbeConfiguration(NSString * _Nullable * _Nullable errorOut);

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

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif