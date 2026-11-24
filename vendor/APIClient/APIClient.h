#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stddef.h>

NS_ASSUME_NONNULL_BEGIN

#define TSERVER_SDK_RELEASE_VERSION @"2.1.0"
#define APICLIENT_HAS_TERMINAL_EVENTS 1

typedef void (^APIClientTerminalEventBlock)(NSDictionary *result);

FOUNDATION_EXTERN void APIClientConfigure(NSString * _Nullable packageToken);

// ---- C Bridge (tương thích style APIKey) ----
FOUNDATION_EXTERN void setTokenC(const char * _Nullable token);
FOUNDATION_EXTERN void setENC(int enable);
FOUNDATION_EXTERN void setVerC(const char * _Nullable ver);
FOUNDATION_EXTERN void loadingC(void (^ _Nullable execute)(void));
FOUNDATION_EXTERN void APIClientStartAuthorization(dispatch_block_t _Nullable onValid,
                                                    dispatch_block_t _Nullable onRevoked);
FOUNDATION_EXTERN void APIClientStartAuthorizationWithEvents(dispatch_block_t _Nullable onValid,
                                                              dispatch_block_t _Nullable onRevoked,
                                                              APIClientTerminalEventBlock _Nullable onTerminal);
FOUNDATION_EXTERN BOOL APIClientPerformAuthorized(NSString * _Nullable capability,
                                                   dispatch_block_t _Nullable work,
                                                   dispatch_block_t _Nullable denied);
FOUNDATION_EXTERN void APIClientOpenPaid(dispatch_block_t _Nullable onPaid);
FOUNDATION_EXTERN void APIClientConfirmKey(NSString * _Nullable key,
                                            APIClientTerminalEventBlock _Nullable success,
                                            APIClientTerminalEventBlock _Nullable failure);
FOUNDATION_EXTERN BOOL APIClientHandleOpenURL(NSURL * _Nullable url);
/// YES only after the user confirmed the VALID/key screen. The paid menu must
/// stay closed until this returns YES (prevents auto-opening after UUID verify).
FOUNDATION_EXTERN BOOL APIClientValidConfirmed(void);
FOUNDATION_EXTERN NSString *APIClientRenderTemplate(NSString * _Nullable text);
// Bảo vệ hàm mở menu của host khỏi bị hook/patch (tuỳ chọn, gọi 1 lần).
FOUNDATION_EXTERN BOOL APIClientProtectHostFunction(const void * _Nullable function);
FOUNDATION_EXTERN BOOL APIClientProtectHostMethod(Class _Nullable cls, SEL _Nullable selector);

@interface APIClient : NSObject
+ (void)startAuthorization:(dispatch_block_t _Nullable)onValid onRevoked:(dispatch_block_t _Nullable)onRevoked;
+ (void)startAuthorization:(dispatch_block_t _Nullable)onValid onRevoked:(dispatch_block_t _Nullable)onRevoked onTerminal:(APIClientTerminalEventBlock _Nullable)onTerminal;
+ (BOOL)performAuthorized:(NSString * _Nullable)capability work:(dispatch_block_t _Nullable)work denied:(dispatch_block_t _Nullable)denied;
+ (void)openPaid:(dispatch_block_t _Nullable)onPaid;
+ (void)confirmKey:(NSString * _Nullable)key success:(APIClientTerminalEventBlock _Nullable)success failure:(APIClientTerminalEventBlock _Nullable)failure;
+ (NSString *)renderTemplate:(NSString * _Nullable)text;
+ (BOOL)protectHostFunction:(const void * _Nullable)function;
+ (BOOL)protectHostMethod:(Class _Nullable)cls selector:(SEL _Nullable)selector;
@end

NS_ASSUME_NONNULL_END

// ============================================================================
// Compile-time token obfuscation (C++ only, for .mm/.xm tweak sources)
// ============================================================================
// Customers only need these 2 files (APIClient.h + libAPIClient.a). Use:
//
//   #define APICLIENT_NO_AUTO_SETUP
//   #import "APIClient/APIClient.h"
//   setTokenC(TS_OBF_STR("pkg_your_token_here"));
//
// The plaintext literal is not present in the built binary; only the XORed
// bytes are embedded. Requires C++14+ (C++17 recommended).
#ifdef __cplusplus
namespace TserverApiClientObf {
template <size_t N, uint8_t K1, uint8_t K2>
struct ObfStr {
    uint8_t data[N];
    constexpr ObfStr(const char (&str)[N]) : data{} {
        for (size_t i = 0; i < N; ++i) {
            uint8_t c = static_cast<uint8_t>(str[i]) ^ static_cast<uint8_t>(K1 + static_cast<uint8_t>(i * K2));
            c = static_cast<uint8_t>((c << 3) | (c >> 5));
            data[i] = static_cast<uint8_t>(c ^ static_cast<uint8_t>(K2 + static_cast<uint8_t>(i * 13)));
        }
    }
    inline void decrypt(char * _Nonnull out) const {
        volatile const uint8_t *vdata = data;
        for (size_t i = 0; i < N; ++i) {
            uint8_t c = static_cast<uint8_t>(vdata[i] ^ static_cast<uint8_t>(K2 + static_cast<uint8_t>(i * 13)));
            c = static_cast<uint8_t>((c >> 3) | (c << 5));
            out[i] = static_cast<char>(c ^ static_cast<uint8_t>(K1 + static_cast<uint8_t>(i * K2)));
        }
    }
};
} // namespace TserverApiClientObf

#ifndef TS_OBF_STR
#define TS_OBF_STR(literal) \
    ([]() -> const char * _Nonnull { \
        constexpr static const TserverApiClientObf::ObfStr<sizeof(literal), \
            static_cast<uint8_t>((__LINE__ * 179 + 89) & 0xFF), \
            static_cast<uint8_t>((((__LINE__ ^ 0x5C) * 37 + 23) | 1) & 0xFF)> _enc(literal); \
        static __thread char _slots[4][512]; \
        static __thread size_t _cursor = 0; \
        char *_slot = _slots[(_cursor++) & 3]; \
        char _tmp[sizeof(literal)]; \
        _enc.decrypt(_tmp); \
        for (size_t _i = 0; _i < sizeof(literal); ++_i) _slot[_i] = _tmp[_i]; \
        return _slot; \
    })()
#endif
#endif // __cplusplus
