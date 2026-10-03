#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Public customer header — keep tiny. Secrets/endpoints live sealed inside libAPIClient.a.
//
// This is the ONLY header a customer copies. Typed statuses, observability and
// support diagnostics are declared here on purpose: the release is two files
// (this header + libAPIClient.a) so nothing can break because a third file is
// missing from a download, an upload or a Vendor folder.

#pragma mark - Typed status

/// Typed authorization/UI statuses.
///
/// The server keeps sending status as a string; this enum is the SDK's own
/// vocabulary so integrators can compare a value instead of typing a literal
/// that silently never matches. Use TserverStatusCodeFromString at every boundary.
typedef NS_ENUM(NSInteger, TserverStatusCode) {
    TserverStatusCodeUnknown = 0,
    TserverStatusCodeValid,
    TserverStatusCodeOfflineGraceValid,
    TserverStatusCodeNeedUUID,
    TserverStatusCodeNeedKey,
    TserverStatusCodeInvalidKey,
    TserverStatusCodeExpired,
    TserverStatusCodeOfflineGraceExpired,
    TserverStatusCodeProfileExpired,
    TserverStatusCodeRevoked,
    TserverStatusCodeDeviceBlocked,
    TserverStatusCodeDeviceMismatch,
    TserverStatusCodeUpdateRequired,
    TserverStatusCodeNetworkError,
    TserverStatusCodeServerError,
    TserverStatusCodeRateLimited,
    TserverStatusCodeValidationError,
    TserverStatusCodeBadResponseSignature,
    TserverStatusCodeAuthorizationLeaseInvalid,
    TserverStatusCodeUnsafeEnvironment,
    TserverStatusCodeMaintenance,
    TserverStatusCodeAppDisabled,
    TserverStatusCodeStoreDisabled,
    TserverStatusCodePackageDisabled,
    TserverStatusCodePackageMaintenance,
    TserverStatusCodePackageBundleDenied,
    TserverStatusCodeBadPackageSession,
    TserverStatusCodeInvalidApiKey,
    TserverStatusCodeClientKeyUnavailable,
    TserverStatusCodeMissingAuthConfig,
    TserverStatusCodeReturnSchemeNotRegistered,
    TserverStatusCodeUIFailure,
    /// A package announcement was presented. Presentation only, never authority.
    TserverStatusCodeNotice
};

/// Map a server status string to the enum. Never returns a guess: unknown
/// strings map to TserverStatusCodeUnknown so callers must handle the default case.
FOUNDATION_EXPORT TserverStatusCode TserverStatusCodeFromString(NSString *_Nullable status);

/// Canonical string for a status, identical to what the server sends.
FOUNDATION_EXPORT NSString *TserverStatusCodeString(TserverStatusCode status);

/// Every status string the SDK understands, in declaration order. Lets an
/// integrator build a picker or a switch without reading the implementation.
FOUNDATION_EXPORT NSArray<NSString *> *TserverStatusCodeAllStrings(void);

/// YES when the status means the paid capability is unlocked.
FOUNDATION_EXPORT BOOL TserverStatusCodeIsValid(TserverStatusCode status);

/// YES when the status requires the user to type or confirm a key.
FOUNDATION_EXPORT BOOL TserverStatusCodeNeedsKey(TserverStatusCode status);

#pragma mark - Observability events

/// Observe the SDK with plain NSNotificationCenter instead of polling.
///
/// Nothing here grants authorization: these notifications are presentation and
/// diagnostics only. The live signed lease remains the only authority.
///
///   [[NSNotificationCenter defaultCenter] addObserverForName:TserverStatusDidChangeNotification
///                                                       object:nil
///                                                        queue:[NSOperationQueue mainQueue]
///                                                   usingBlock:^(NSNotification *note) {
///       NSString *status = note.userInfo[TserverStatusStringUserInfoKey];
///       TserverStatusCode typed = TserverStatusCodeFromString(status);
///       if (TserverStatusCodeNeedsKey(typed)) { [self showMyKeyScreen]; }
///   }];

/// The authorization/UI status changed.
FOUNDATION_EXPORT NSNotificationName const TserverStatusDidChangeNotification;
/// A signed package announcement is being presented to the user.
FOUNDATION_EXPORT NSNotificationName const TserverNoticeDidArriveNotification;
/// Reachability or a request result changed the perceived network state.
FOUNDATION_EXPORT NSNotificationName const TserverNetworkDidChangeNotification;
/// The local authorization lease was installed, refreshed or invalidated.
FOUNDATION_EXPORT NSNotificationName const TserverLeaseDidChangeNotification;
/// A diagnostic entry was appended to the in-memory event ring buffer.
FOUNDATION_EXPORT NSNotificationName const TserverDiagnosticDidAppendNotification;

FOUNDATION_EXPORT NSString * const TserverStatusStringUserInfoKey;   // NSString
FOUNDATION_EXPORT NSString * const TserverStatusEnumUserInfoKey;     // NSNumber(TserverStatus)
FOUNDATION_EXPORT NSString * const TserverResultUserInfoKey;         // NSDictionary (sanitized)
FOUNDATION_EXPORT NSString * const TserverNoticeUserInfoKey;        // NSDictionary
FOUNDATION_EXPORT NSString * const TserverNetworkOnlineUserInfoKey;  // NSNumber(bool)
FOUNDATION_EXPORT NSString * const TserverNetworkLatencyMsUserInfoKey; // NSNumber
FOUNDATION_EXPORT NSString * const TserverLeaseAuthorizedUserInfoKey;   // NSNumber(bool)
FOUNDATION_EXPORT NSString * const TserverLeaseRemainingUserInfoKey;    // NSNumber(seconds)
FOUNDATION_EXPORT NSString * const TserverDiagnosticUserInfoKey;        // NSDictionary

#pragma mark - Support diagnostics

/// Verbosity of the in-memory diagnostics ring buffer. Nothing is ever written
/// to the device log; this only controls what a seller can read back through
/// TserverRecentEvents and copy to a support ticket.
typedef NS_ENUM(NSInteger, TserverLogLevel) {
    TserverLogLevelOff = 0,
    TserverLogLevelError = 1,
    TserverLogLevelInfo = 2,
    TserverLogLevelDebug = 3
};

/// Post TserverStatusDidChangeNotification and append to the ring buffer.
FOUNDATION_EXPORT void TserverDiagnosticsPostStatus(NSString *_Nullable status,
                                                    NSDictionary *_Nullable sanitizedResult);
FOUNDATION_EXPORT void TserverDiagnosticsPostNotice(NSDictionary *_Nullable notice);
FOUNDATION_EXPORT void TserverDiagnosticsPostNetwork(BOOL online, NSTimeInterval latencyMs);
FOUNDATION_EXPORT void TserverDiagnosticsPostLease(BOOL authorized, NSTimeInterval remainingSeconds);

/// Append a custom entry. `kind` is a short machine tag such as "http" or "ui".
FOUNDATION_EXPORT void TserverDiagnosticsRecord(NSString *kind,
                                                NSString *_Nullable message,
                                                NSDictionary *_Nullable fields);

/// State for a "copy diagnostics" support button. Contains no secrets: booleans,
/// counts, timings, host name and the public client kid only.
FOUNDATION_EXPORT NSDictionary *TserverDebugSnapshot(void);

/// Most recent ring-buffer entries, oldest first. `limit` <= 0 returns all.
FOUNDATION_EXPORT NSArray<NSDictionary *> *TserverRecentEvents(NSUInteger limit);

FOUNDATION_EXPORT void TserverSetLogLevel(TserverLogLevel level);
FOUNDATION_EXPORT TserverLogLevel TserverCurrentLogLevel(void);

/// Feed values that only live inside the SDK (endpoints, session flags, lease).
/// Both arguments are optional and are sanitized by the snapshot builder.
FOUNDATION_EXPORT void TserverDiagnosticsUpdateRuntime(NSDictionary *_Nullable fields);

#define TSERVER_SDK_RELEASE_VERSION @"2.1.0"
#define APICLIENT_HAS_TERMINAL_EVENTS 1

// Điền package token đúng MỘT LẦN tại đây. UI pack được chọn trên web và
// chỉ hiển thị sau khi signed server config trả về; customer source không cần cấu hình thêm.
static NSString * const kAPIClientPackageToken = @"pkg_kPoe_0Dj9r7V__OanehW5toQA0Mfhja2";

FOUNDATION_EXTERN void APIClientConfigure(NSString * _Nullable packageToken);
/// Frida guard: terminate the process when Frida is attached. Enabled by
/// default. A plain jailbroken device is never terminated — only Frida.
FOUNDATION_EXTERN void APIClientSetFridaGuardEnabled(BOOL enabled);
/// Current state of the guard, for a support snapshot.
FOUNDATION_EXTERN BOOL APIClientFridaGuardEnabled(void);

FOUNDATION_EXTERN void APIClientStartAuthorization(dispatch_block_t _Nullable onAuthorized,
                                                    dispatch_block_t _Nullable onRevoked);
/// Public terminal events are sanitized; bearer/session fields are omitted.
typedef void (^APIClientTerminalEventBlock)(NSDictionary *result);

// Clean-room compatibility surface for Logos integrations.
// The callback is never treated as proof by itself; paid work is still gated
// by the live signed authorization lease.
typedef void (^apiclient_callback)(void);
typedef void (^apiclient_dict_callback)(const char *json);

FOUNDATION_EXTERN void APIClientStartAuthorizationWithEvents(
    dispatch_block_t _Nullable onAuthorized,
    dispatch_block_t _Nullable onRevoked,
    APIClientTerminalEventBlock _Nullable onTerminal
);
FOUNDATION_EXTERN BOOL APIClientPerformAuthorized(NSString * _Nullable capability,
                                                   dispatch_block_t _Nullable work,
                                                   dispatch_block_t _Nullable denied);
/// Starts the normal gate and invokes onPaid only after a fresh paid-capability
/// check on the signed authorization lease.
FOUNDATION_EXTERN void APIClientOpenPaid(dispatch_block_t _Nullable onPaid);
/// Activates a user-entered key through the signed package flow. Completion
/// dictionaries are public, sanitized metadata only; raw key/session material
/// is never returned.
FOUNDATION_EXTERN void APIClientConfirmKey(NSString * _Nullable key,
                                             APIClientTerminalEventBlock _Nullable success,
                                             APIClientTerminalEventBlock _Nullable failure);
/// Logos-compatible spelling. JSON strings are ephemeral and sanitized.
FOUNDATION_EXTERN void apiclient_paid(apiclient_callback _Nullable callback);
FOUNDATION_EXTERN void apiclient_on_login(const char * _Nullable inputKey,
                                          apiclient_dict_callback _Nullable success,
                                          apiclient_dict_callback _Nullable failure);
FOUNDATION_EXTERN BOOL APIClientHandleOpenURL(NSURL * _Nullable url);
FOUNDATION_EXTERN NSString *APIClientRenderTemplate(NSString * _Nullable templateText);

NS_INLINE void APIClientSetup(void) {
    NSString *token = [kAPIClientPackageToken stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (token.length >= 24 && [token rangeOfString:@"REPLACE" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        APIClientConfigure(token);
    }
}

#ifndef APICLIENT_NO_AUTO_SETUP
__attribute__((constructor)) static void APIClientHeaderAutoSetup(void) {
    APIClientSetup();
}
#endif

@interface APIClient : NSObject
+ (void)startAuthorization:(dispatch_block_t _Nullable)onAuthorized
                 onRevoked:(dispatch_block_t _Nullable)onRevoked;
+ (void)startAuthorization:(dispatch_block_t _Nullable)onAuthorized
                 onRevoked:(dispatch_block_t _Nullable)onRevoked
                onTerminal:(APIClientTerminalEventBlock _Nullable)onTerminal;
+ (BOOL)performAuthorized:(NSString * _Nullable)capability
                     work:(dispatch_block_t _Nullable)work
                   denied:(dispatch_block_t _Nullable)denied;
+ (void)openPaid:(dispatch_block_t _Nullable)onPaid;
+ (void)confirmKey:(NSString * _Nullable)key
           success:(APIClientTerminalEventBlock _Nullable)success
           failure:(APIClientTerminalEventBlock _Nullable)failure;
+ (NSString *)renderTemplate:(NSString * _Nullable)templateText;
/// Last status the SDK reached, typed. Safe to call at any time, including
/// before authorization starts: it returns TserverStatusUnknown.
+ (TserverStatusCode)currentStatus;

/// Support snapshot for a "copy diagnostics" button. Contains no secrets:
/// counts, timings, host name, build id and log level only.
+ (NSDictionary * _Nullable)debugSnapshot;

/// Recent diagnostics entries, oldest first, for a support ticket.
+ (NSArray<NSDictionary *> * _Nullable)recentEvents:(NSUInteger)limit;

+ (NSDictionary * _Nullable)currentKeyInfo;
+ (NSString *)currentKeyText;
+ (NSString *)currentKeyRemainingText;
+ (NSInteger)currentKeyMaxDevices;

// Compatibility shims (still linked in .a; not advertised).
+ (void)start:(dispatch_block_t _Nullable)onPaid
    __attribute__((deprecated("Use startAuthorization:onRevoked:")));
+ (BOOL)isValid
    __attribute__((deprecated("Use performAuthorized:work:denied:")));
+ (void)paid:(dispatch_block_t _Nullable)onPaid
    __attribute__((deprecated("Use startAuthorization:onRevoked:")));
@end

#pragma mark - Optional key-information helper

// Declared here so a customer needs only this one header. See
// docs/CUSTOMER_INTEGRATION.md and DYLIB_MEMBER_INFO_PLACEHOLDERS.md.
typedef void (^TserverMemberInfoCompletion)(NSDictionary *result);
typedef void (^TserverMemberInfoTemplateCompletion)(NSString *text, NSDictionary *result);

/// Renders key/package information into labels you build yourself. It never adds
/// UI on its own. Requires configureWithMemberApiKey:packageId: first when using
/// the prebuilt libAPIClient.a.
@interface TserverMemberInfo : NSObject
+ (void)configureWithMemberApiKey:(NSString *)memberApiKey packageId:(NSString *)packageId;
+ (BOOL)isConfigured;
+ (NSString *)configuredPackageId;
+ (void)loadPackageInfoWithCompletion:(TserverMemberInfoCompletion)completion;
+ (void)loadOnlineWithCompletion:(TserverMemberInfoCompletion)completion;
+ (void)listKeysWithCompletion:(TserverMemberInfoCompletion)completion;
+ (void)checkKey:(NSString *)licenseKey completion:(TserverMemberInfoCompletion)completion;
+ (void)loadInfoForKey:(NSString *)licenseKey completion:(TserverMemberInfoCompletion)completion;
+ (NSString *)renderTemplate:(NSString *)templateText withInfo:(NSDictionary *)info;
+ (void)renderTemplate:(NSString *)templateText
            licenseKey:(NSString *)licenseKey
           completion:(TserverMemberInfoTemplateCompletion)completion;
+ (NSString *)formatRemainingSeconds:(NSNumber *)seconds
                          isLifetime:(BOOL)isLifetime
                   startsOnActivation:(BOOL)startsOnActivation;
@end

// Keep C shims available for older Logos sources.
FOUNDATION_EXTERN void APIClientStart(dispatch_block_t _Nullable onPaid)
    __attribute__((deprecated("Use APIClientStartAuthorization")));
FOUNDATION_EXTERN BOOL APIClientIsValid(void)
    __attribute__((deprecated("Use APIClientPerformAuthorized")));

NS_ASSUME_NONNULL_END
