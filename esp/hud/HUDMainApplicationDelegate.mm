#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

#import "HUDMainApplicationDelegate.h"
#import "HUDMainWindow.h"

#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"

#import "../esp/esp/esp.h"
#import "../esp/esp/ESPPrefs.h"
#import "../esp/esp/GameOffsets.h"
#import "../esp/esp/menu.h"
#import "../esp/esp/pid.h"
#import "HUDHelper.h"
#import "UIView+SecureView.h"
#import "../../kexploit/kexploit_opa334.h"
#import "../../kexploit/kutils.h"
#import "../../sandbox_escape.h"
#import "../../platformize.h"

static inline BOOL VNPointIsFinite(CGPoint p) {
    return isfinite(p.x) && isfinite(p.y);
}

// Pass-through root view: empty area returns nil so game receives touches under CLEAR/count.
@interface HUDPassThroughView : UIView
@end
@implementation HUDPassThroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    return hit;
}
@end

@interface HUDLandscapeContainerViewController : UIViewController
@end

@implementation HUDLandscapeContainerViewController

- (void)loadView {
    self.view = [[HUDPassThroughView alloc] initWithFrame:CGRectZero];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    // YES so menu child can receive hits; hitTest returns nil on empty area → game keeps touches.
    self.view.userInteractionEnabled = YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationLandscapeRight;
}

@end

static __weak HUDMainApplicationDelegate *_sharedHUDDelegate = nil;

BOOL HUDFloatButtonHandleTouch(CGPoint screenPoint, UITouchPhase phase, NSInteger pointerId) {
    HUDMainApplicationDelegate *d = _sharedHUDDelegate;
    if (!d) return NO;
    return [d handleTouchAtScreenPoint:screenPoint phase:phase pointerId:pointerId];
}


#pragma mark - HUDMainApplicationDelegate

@implementation HUDMainApplicationDelegate {
    SBSAccessibilityWindowHostingController *_windowHostingController;
    dispatch_source_t _gameCheckTimer;
    MenuView *_menuView;
    NSInteger _gameMissingStreak;
}

- (instancetype)init
{
    if (self = [super init]) {}
    return self;
}

- (void)dealloc {
    if (_gameCheckTimer) {
        dispatch_source_cancel(_gameCheckTimer);
        _gameCheckTimer = nil;
    }
    if (_sharedHUDDelegate == self) _sharedHUDDelegate = nil;
}

// Chuẩn hóa chuyển đổi tọa độ khi Window bị xoay (CGAffineTransform)
- (CGPoint)windowLocalPointFromScreen:(CGPoint)sp {
    CGPoint center = self.window.center;
    if (!VNPointIsFinite(center) || (center.x == 0.0f && center.y == 0.0f)) {
        CGRect screen = [UIScreen mainScreen].bounds;
        center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
    }
    
    // Tịnh tiến về tâm
    CGPoint r = CGPointMake(sp.x - center.x, sp.y - center.y);
    
    // Đảo ngược ma trận xoay của Window để lấy tọa độ phẳng chuẩn
    CGPoint l = CGPointApplyAffineTransform(r, CGAffineTransformInvert(self.window.transform));
    
    // Đưa về góc trái trên hệ tọa độ mới của Window
    l.x += self.window.bounds.size.width / 2.0f;
    l.y += self.window.bounds.size.height / 2.0f;
    return l;
}


- (BOOL)handleTouchAtScreenPoint:(CGPoint)screenPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId {
    if (!_menuView || !self.window) return NO;
    if (![NSThread isMainThread]) {
        __block BOOL ret = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            ret = [self handleTouchAtScreenPoint:screenPoint phase:phase pointerId:pointerId];
        });
        return ret;
    }
    if (self.window.hidden || self.window.alpha <= 0.01f || !VNPointIsFinite(screenPoint)) return NO;
    
    CGPoint inWindow;
    if (CGAffineTransformIsIdentity(self.window.transform)) {
        // iOS 11+ dùng coordinateSpace, iOS cũ dùng convertPoint từ nil
        if (@available(iOS 11.0, *)) {
            id<UICoordinateSpace> screen = [UIScreen mainScreen].coordinateSpace;
            if (screen) {
                inWindow = [self.window convertPoint:screenPoint fromCoordinateSpace:screen];
            } else {
                inWindow = [self.window convertPoint:screenPoint fromView:nil];
            }
        } else {
            inWindow = [self.window convertPoint:screenPoint fromView:nil];
        }
    } else {
        inWindow = [self windowLocalPointFromScreen:screenPoint];
    }
    
    // Gửi tọa độ chuẩn xác đã fix góc nghiêng vào Menu view xử lý tiếp
    BOOL consumed = [_menuView handleTouchAtWindowPoint:inWindow phase:phase pointerId:pointerId];
    return consumed;
}

- (UIInterfaceOrientation)currentInterfaceOrientation {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState == UISceneActivationStateForegroundActive ||
                    ws.activationState == UISceneActivationStateForegroundInactive) {
                    return ws.interfaceOrientation;
                }
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIInterfaceOrientation sb = [UIApplication sharedApplication].statusBarOrientation;
#pragma clang diagnostic pop
    if (sb != UIInterfaceOrientationUnknown) {
        return sb;
    }

    UIDeviceOrientation dev = [UIDevice currentDevice].orientation;
    if (UIDeviceOrientationIsLandscape(dev)) {
        return (dev == UIDeviceOrientationLandscapeLeft) ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationLandscapeLeft;
    }
    return UIInterfaceOrientationLandscapeRight;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    // Load persisted menu/ESP settings before first frame.
    ESPPrefsSync();
    ESPSyncFromPrefs();

    HUDLandscapeContainerViewController *container = [[HUDLandscapeContainerViewController alloc] init];

    // Cấu hình ESP View vẽ khung
    ESP_View *espView = [[ESP_View alloc] initWithFrame:CGRectZero];
    espView.translatesAutoresizingMaskIntoConstraints = NO;
    espView.backgroundColor = [UIColor clearColor];
    espView.userInteractionEnabled = NO; // ESP không nhận touch để tránh chặn game
    [espView hideViewFromCapture:NO];

    UIView *containerView = container.view;
    [containerView addSubview:espView];

    // Cấu hình Menu View
    MenuView *menuView = [[MenuView alloc] initWithFrame:CGRectZero];
    menuView.translatesAutoresizingMaskIntoConstraints = NO;
    menuView.userInteractionEnabled = YES; // Kích hoạt tương tác chuẩn
    
    __weak __typeof__(self) wself = self;
    menuView.onExitHUDRequested = ^{
        RequestExitHUD();
        (void)wself;
    };
    [containerView addSubview:menuView];
    _menuView = menuView;
    _sharedHUDDelegate = self;

    // Auto Layout căn đều toàn màn hình cho cả ESP và Menu
    [NSLayoutConstraint activateConstraints:@[
        [espView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor],
        [espView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor],
        [espView.topAnchor constraintEqualToAnchor:containerView.topAnchor],
        [espView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor],
        [menuView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor],
        [menuView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor],
        [menuView.topAnchor constraintEqualToAnchor:containerView.topAnchor],
        [menuView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor]
    ]];

    self.window = [[HUDMainWindow alloc] initWithFrame:CGRectZero];
    [self.window setRootViewController:container];

    // Tính toán kích thước theo hướng Landscape thực tế
    UIInterfaceOrientation curOrientation = [self currentInterfaceOrientation];
    CGRect physicalBounds = [[UIScreen mainScreen] bounds];
    CGRect screenBounds = physicalBounds;
    
    // Đảm bảo chiều Rộng luôn lớn hơn chiều Cao khi ở chế độ Ngang
    if (UIInterfaceOrientationIsLandscape(curOrientation)) {
        CGFloat maxDim = MAX(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
        CGFloat minDim = MIN(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
        screenBounds = CGRectMake(0, 0, maxDim, minDim);
    }

    [self.window setFrame:physicalBounds];
    self.window.center = CGPointMake(CGRectGetMidX(physicalBounds), CGRectGetMidY(physicalBounds));

    // Ép Window nhận hướng giao diện thông qua hàm ẩn hệ thống
    SEL setOrientSel = NSSelectorFromString(@"_setInterfaceOrientation:");
    if ([self.window respondsToSelector:setOrientSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSMethodSignature *sig = [self.window methodSignatureForSelector:setOrientSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:setOrientSel];
            [inv setTarget:self.window];
            NSInteger orientVal = (NSInteger)curOrientation;
            [inv setArgument:&orientVal atIndex:2];
            [inv invoke];
        }
#pragma clang diagnostic pop
    }

    // Áp dụng góc xoay Transform phù hợp để vẽ đè chuẩn lên game Landscape
    if (UIInterfaceOrientationIsLandscape(curOrientation)) {
        CGAffineTransform rot = (curOrientation == UIInterfaceOrientationLandscapeLeft)
            ? CGAffineTransformMakeRotation(-M_PI_2)
            : CGAffineTransformMakeRotation(M_PI_2);

        self.window.transform = rot;
    } else {
        self.window.transform = CGAffineTransformIdentity;
    }
    
    self.window.bounds = CGRectMake(0, 0, screenBounds.size.width, screenBounds.size.height);
    container.view.frame = self.window.bounds;
    container.view.bounds = self.window.bounds;
    self.window.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [self.window setWindowLevel:10000010.0];
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];

    [containerView setNeedsLayout];
    [containerView layoutIfNeeded];

    espView.frame = containerView.bounds;
    menuView.frame = containerView.bounds;

    // Đăng ký Context ID đè hệ thống (SBSAccessibility)
    Class hostingClass = objc_getClass("SBSAccessibilityWindowHostingController");
    _windowHostingController = hostingClass ? [[hostingClass alloc] init] : nil;
    SEL registerSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    SEL contextSel = NSSelectorFromString(@"_contextId");
    if (_windowHostingController && [_windowHostingController respondsToSelector:registerSel] && [self.window respondsToSelector:contextSel]) {
        unsigned int _contextId = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSMethodSignature *ctxSig = [self.window methodSignatureForSelector:contextSel];
        if (ctxSig) {
            NSInvocation *ctxInv = [NSInvocation invocationWithMethodSignature:ctxSig];
            [ctxInv setTarget:self.window];
            [ctxInv setSelector:contextSel];
            [ctxInv invoke];
            [ctxInv getReturnValue:&_contextId];
        }
#pragma clang diagnostic pop
        double windowLevel = [self.window windowLevel];
        if (_contextId != 0) {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            NSMethodSignature *signature = [_windowHostingController methodSignatureForSelector:registerSel];
            if (signature) {
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                [invocation setTarget:_windowHostingController];
                [invocation setSelector:registerSel];
                [invocation setArgument:&_contextId atIndex:2];
                [invocation setArgument:&windowLevel atIndex:3];
                [invocation invoke];
            }
#pragma clang diagnostic pop
        }
    }

    // Auto-exit HUD when selected game process is gone (tree/ESP overlays must not linger).
    GameOffsetsReload();
    _gameMissingStreak = 0;

    // ---- RUN KERNEL EXPLOIT (Fl0rk-style: HUD child process owns exploit) ----
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Park guard: if a previous HUD already exploited THIS boot session,
        // re-running the race double-corrupts the socket zone → panic.
        NSString *parkPath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                              stringByAppendingPathComponent:@".minhduc_hud_parked"];
        BOOL parked = [[NSFileManager defaultManager] fileExistsAtPath:parkPath];

        if (!parked) {
            // Retried, because one attempt was the difference between working for
            // the rest of the session and not working at all.
            //
            // kexploit_opa334 is a race on the socket zone allocator. It fails on
            // timing, and it failed often enough that the reported symptom was
            // "I have to start the hack while I am already in a match" — which is
            // also when the process is doing enough work for the race to land. The
            // old code ran it once and, on failure, returned from this block: no
            // platformize, no sandbox escape, g_kexploit_ready stays false, and
            // ds_attach() bails on that flag forever. Nothing in the process ever
            // tried again, so the only recovery was killing the app and pressing
            // Activate a second time — which is exactly the manual retry this loop
            // now does by itself.
            //
            // Bounded, and the delays grow, because the park guard above is right
            // that hammering the allocator is not free. Three attempts over about
            // 19 seconds, then it stays dead and says so.
            static const int kAttempts = 3;
            static const NSTimeInterval kBackoff[3] = { 2.0, 5.0, 12.0 };
            BOOL exploited = NO;
            for (int attempt = 0; attempt < kAttempts; attempt++) {
                if (attempt > 0) {
                    NSLog(@"[HUD] kexploit attempt %d failed — retrying in %.0fs",
                          attempt, kBackoff[attempt - 1]);
                    [NSThread sleepForTimeInterval:kBackoff[attempt - 1]];
                }
                NSLog(@"[HUD] Running kexploit (attempt %d, first time this boot)...", attempt + 1);
                int kret = kexploit_opa334();
                if (kret == 0) {
                    exploited = YES;
                    break;
                }
                NSLog(@"[HUD] kexploit failed: %d", kret);
            }
            if (!exploited) {
                NSLog(@"[HUD] kexploit failed %d times — kernel r/w unavailable, "
                      @"ESP will stay off. Stop the hack and start it again.",
                      kAttempts);
                return;
            }
            [@"1" writeToFile:parkPath atomically:YES
                     encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[HUD] exploit OK — parked for this boot.");
        } else {
            NSLog(@"[HUD] Parked state — exploit already ran this boot.");
        }

        // NOJB: platformize FIRST (before sandbox_escape rotates cred) so
        // AMFI treats this process as a system app → GSInitialize +
        // BKSDisplayServicesStart + system UI work. The window then renders
        // above every app.
        uint64_t self_proc = proc_self();
        int pret = platformize_self(self_proc);
        NSLog(@"[HUD] platformize_self=%d", pret);

        int sret = sandbox_escape(self_proc);
        NSLog(@"[HUD] sandbox_escape=%d", sret);

        extern bool g_kexploit_ready;
        NSLog(@"[HUD] g_kexploit_ready=%d (parked=%d)", g_kexploit_ready, parked);

        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[HUD] Kernel r/w + platformized + sandbox OK — overlay over every app");
        });
    });

    _gameCheckTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (_gameCheckTimer) {
        // Wait 10s before first game check (gives user time to switch to FF).
        // Then poll every 2s. Require 15 consecutive misses (~30s) to exit —
        // the user may be in lobby or between matches.
        dispatch_source_set_timer(_gameCheckTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                                  (uint64_t)(2.0 * NSEC_PER_SEC),
                                  (uint64_t)(0.5 * NSEC_PER_SEC));
        const int kHUDExitThreshold = 15;
        __weak __typeof__(self) wself = self;
        dispatch_source_set_event_handler(_gameCheckTimer, ^{
            __strong __typeof__(wself) sself = wself;
            if (!sself) return;
            if (!GameTargetIsRunning()) {
                sself->_gameMissingStreak++;
                if (sself->_gameMissingStreak < kHUDExitThreshold) return;

                // Game gone for too long — exit HUD.
                if (sself.window) {
                    sself.window.hidden = YES;
                    sself.window.alpha = 0.0f;
                }
                if (sself->_menuView) {
                    sself->_menuView.hidden = YES;
                    [sself->_menuView hideMenu];
                }
                if (sself->_gameCheckTimer) {
                    dispatch_source_cancel(sself->_gameCheckTimer);
                    sself->_gameCheckTimer = nil;
                }
                RequestExitHUD();
            } else {
                sself->_gameMissingStreak = 0;
            }
        });
        dispatch_resume(_gameCheckTimer);
    }

    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;
    ESPPrefsSync();
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    ESPPrefsSync();
}

@end