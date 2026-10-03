#import <Foundation/Foundation.h>

// Installs the bundled iOS DNS profile the ordinary way: write it, serve it
// over loopback, and hand the URL to Safari. That is the only route that works
// without privileges this build does not have.
//
// The profile is app/layout/Resources/ff-fixbanid-dns.mobileconfig, installed
// byte for byte. Nothing here generates one and nothing here modifies it.
//
// There is no silent install path and no jump into Settings. Both were tried
// and both need the process to be platformized, which it is not, so both were
// code that could never run while the screen claimed otherwise. They are gone
// rather than left looking working.
//
// Installing costs one tap on "Install" in the profile prompt iOS shows, and
// switching the profile on afterwards is another, because iOS does not let any
// app open General > VPN & Device Management for the user.
//
// What the profile does is worth stating, because it is not obvious from the
// file. It carries ONE com.apple.dnsSettings.managed payload, and that payload
// carries both halves of the old two-payload file at once:
//
//   blocked  10 Free Fire domains are sent over DoH to a URL that does not
//            resolve, 192.0.2.1, which is TEST-NET-1 from RFC 5737. iOS queries
//            it, nothing answers, the app never gets an IP. Same observable
//            effect as the "action": "reject" this replaces, and there is no
//            blocking primitive anywhere in the file.
//   allowed  14 login, Google and Garena domains go to an OnDemandRules entry
//            that evaluates the connection and then answers NeverConnect, so
//            they leave the managed resolver alone and keep resolving
//            normally.
//   rest     everything else uses the default DNS.
//
// The OnDemandRules array also carries a ConnectIfNeeded group listing the same
// ten blocked domains, which is what keeps them on the managed path once a
// connection is evaluated.
//
// Do not add AllowFailover to that payload. Apple documents it as defaulting
// to false, and false is the only value that makes the block work: true lets
// every failed DoH query fall back to the system resolver and the blocked
// domains resolve normally, while the profile still reports as installed.
//
// The payload identifier is com.tserver.ff.dns.1in1 and kMDDNSPayloadID in
// DNSProfile.mm has to name the same string. MDDNSProbeConfiguration greps
// installed profiles for it, so a stale constant there does not fail the
// install, it makes the screen report "Not installed" over a profile iOS is
// holding right now.

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MDDNSInstallOutcome) {
    MDDNSInstallOutcomeFailed = 0,
    // iOS took the URL and is asking about the profile.
    MDDNSInstallOutcomeHandedOff,
};

typedef void (^MDDNSInstallCompletion)(MDDNSInstallOutcome outcome,
                                      NSString *_Nullable failure,
                                      NSString *_Nullable url);

// The DoH endpoints the payload names, read out of the file.
NSArray<NSString *> *MDDNSServerList(void);

// The bundled profile, verbatim.
NSString *MDDNSProfileXML(void);

// Domains named in the payload, across the allow group and the block group
// together. Not a blocked count; the two groups split them and this does not.
NSUInteger MDDNSBlockedDomainCount(void);

// Writes the profile into the app container and starts a loopback listener for
// it. Returns the URL to open, or nil with a reason in errOut.
//
// The two pointers are spaced on purpose: written as NSString *__autoreleasing
// *_Nullable, clang reads the two adjacent stars as one pointer and then
// reports it as missing a nullability specifier, which -Werror turns into a
// build failure.
NSString * _Nullable MDDNSStartProfileServer(NSString * _Nullable * _Nullable errOut);

// Opens the URL handed back by MDDNSStartProfileServer. Reports through the
// completion whether iOS accepted the URL; passing nil skips the report.
void MDDNSOpenProfile(NSString *url,
                      void (^_Nullable done)(BOOL accepted));

// What iOS is actually holding, read from the profiles directory rather than
// from NEVPNManager. This build has no networking.networkextension entitlement,
// so NEVPNManager cannot work: loadFromPreferences fails with
// NEConfigurationErrorDomain code 10 every time, which is the error the
// reference app shows on its own screen. Grepping
// /var/mobile/Library/ConfigurationProfiles for the payload identifier we
// install answers the same question with evidence.
//
// Returns "Installed" or "Not installed". errorOut carries the reason when no
// candidate directory could be read, which is the state before the exploit has
// escaped the sandbox.
NSString *MDDNSProbeConfiguration(NSString * _Nullable * _Nullable errorOut);

// Serves the profile and hands the URL to iOS. The completion is on the main
// thread and is always called.
void MDDNSInstall(MDDNSInstallCompletion _Nullable completion);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif