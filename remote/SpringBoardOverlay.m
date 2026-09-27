//
//  SpringBoardOverlay.m — Fl0rk DrawView: EXTRA trojan thread + 15fps
//
//  Fl0rk RemoteCallSession initWithProcess: defaults originalThreadOnly=NO
//  → creatingExtraThread=YES. Path mutate (CGPath*) runs on that EXTRA
//  thread; only performSelectorOnMainThread:invoke wait:NO touches SB main.
//
//  Our prior WATCHDOG: originalThreadOnly forced EVERY RemoteCall onto SB
//  main (CGPathClear/AddLines + setArgument + invoke) @20fps → main stuck.
//
//  This build matches Fl0rk:
//    - persistent session on EXTRA thread (not originalThreadOnly)
//    - cached setPath NSInvocation + invoke_cached_main_raw
//    - persistent remote path + pts buf
//    - 15fps gate + hash skip + in-flight drop
//

#import "SpringBoardOverlay.h"
#import "RemoteCall.h"
#import "remote_objc.h"
#import "../../kexploit/kexploit_opa334.h"
#import <UIKit/UIKit.h>
#import <pthread.h>
#import <string.h>
#import <mach/mach_time.h>

#define SB_OVERLAY_WIN_LEVEL 999999.0
// 15fps — Fl0rk-smooth with extra-thread IPC; safer than 20/30 on main.
#define SB_MIN_PUBLISH_INTERVAL_US 66666ULL

// Skeleton limbs are the only ESP element with no batchable CoreGraphics
// primitive: each one needs its own CGPathAddLines call, because the SDK has
// nothing that strokes N disjoint segments at once. 12 players x 12 limbs is
// 144 calls, which is the whole cost the rectangle batching exists to remove.
// Off by default; the limb count is logged either way so the cost of turning
// it on is visible before it is turned on.
#define SB_DRAW_BONES 0

static BOOL g_sbOverlayOn = NO;
static uint64_t g_sbWin = 0;
static uint64_t g_sbShape = 0;
static uint64_t g_sbCanvas = 0;

static uint64_t g_sbPersistentPath = 0;
static uint64_t g_sbMirrorPtsBuf = 0;
static uint32_t g_sbPathHash = 0;
static NSUInteger g_sbLastPathBytes = 0;
static pthread_mutex_t g_sbLock = PTHREAD_MUTEX_INITIALIZER;

// Fl0rk: gDrawViewGeometryPathInvocation + invoke_cached_main_raw
static uint64_t g_sbSetPathInv = 0;
static uint64_t g_sbSetPathArgBuf = 0;
static uint64_t g_sbPerformMainSel = 0;
static uint64_t g_sbInvokeSel = 0;

static uint64_t g_sbSummaryAttempts = 0;
static uint64_t g_sbSummarySkips = 0;
static uint64_t g_sbSummaryUpdates = 0;
static uint64_t g_sbNextPublishUS = 0;
// Last publish cost, so the log says what the subpath fix actually costs.
static uint32_t g_sbLastSubpaths = 0;
static uint64_t g_sbLastCalls = 0;

static const char *kShapeKeys[16] = {
    "boxLayer", "boxBotLayer", "boxKnockedLayer",
    "boneLayer", "boneBotLayer", "boneKnockedLayer",
    "snaplineLayer", "snaplineBotLayer", "snaplineKnockedLayer",
    "hpFillGreenLayer", "hpFillOrangeLayer", "hpFillRedLayer",
    "bgFillBlackLayer", "alertLayer", "fovLayer", "aimAssistLayer"
};

static uint64_t dlsym_remote(const char *fn, uint64_t a0, uint64_t a1, uint64_t a2,
                             uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7) {
    return r_dlsym_call(R_TIMEOUT, fn, a0,a1,a2,a3,a4,a5,a6,a7);
}

static uint64_t now_us(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    uint64_t t = mach_absolute_time();
    return (t * tb.numer / tb.denom) / 1000ULL;
}

typedef struct { NSMutableData *data; } SerCtx;
static uint32_t g_sbSubpathCount = 0;

// op stream: 1 = moveTo (starts a NEW subpath), 2 = lineTo, 3 = subpath break
// marker. The break marker is redundant with moveTo mathematically, but it lets
// the SpringBoard side rebuild subpaths exactly instead of collapsing everything
// into one polyline (see the decode loop in SBRemotePushESPFrame).
static void serFunc(void *info, const CGPathElement *e) {
    SerCtx *ctx = (SerCtx *)info;
    if (e->type == kCGPathElementCloseSubpath) return;
    if (e->type == kCGPathElementMoveToPoint) g_sbSubpathCount++;
    uint8_t op = (e->type == kCGPathElementMoveToPoint) ? 1 : 2;
    [ctx->data appendBytes:&op length:1];
    if (e->type == kCGPathElementMoveToPoint || e->type == kCGPathElementAddLineToPoint) {
        [ctx->data appendBytes:&e->points[0] length:16];
    } else {
        int n = (e->type == kCGPathElementAddQuadCurveToPoint) ? 1 : 2;
        [ctx->data appendBytes:&e->points[n] length:16];
    }
}

static BOOL mergePaths(UIView *espView, NSMutableData *d) {
    [d setLength:0];
    CGMutablePathRef merged = CGPathCreateMutable();
    if (!merged) return NO;
    for (int i = 0; i < 16; i++) {
        id val = [espView valueForKey:[NSString stringWithUTF8String:kShapeKeys[i]]];
        if ([val isKindOfClass:[CAShapeLayer class]]) {
            CGPathRef p = ((CAShapeLayer *)val).path;
            if (p && !CGPathIsEmpty(p)) CGPathAddPath(merged, NULL, p);
        }
    }
    if (CGPathIsEmpty(merged)) { CGPathRelease(merged); return NO; }
    SerCtx ctx = { .data = d };
    g_sbSubpathCount = 0;
    CGPathApply(merged, &ctx, serFunc);
    CGPathRelease(merged);

    uint32_t h = 2166136261u;
    for (NSUInteger i = 0; i < d.length; i++) {
        h ^= ((const uint8_t *)d.bytes)[i]; h *= 16777619u;
    }
    // Skip only if the geometry is genuinely unchanged. The old code compared a
    // single 32-bit hash for the whole frame, so any collision, or any frame
    // whose bytes happened to match, was dropped entirely: SpringBoard never
    // re-rendered and the screen kept showing the previous path. That is the
    // "ESP is static" symptom, and it is independent of the subpath bug below.
    // Require both the hash and the length to match, and keep re-publishing
    // rather than suppressing, because a stale draw is worse than a redundant
    // one.
    if (h == g_sbPathHash && d.length == g_sbLastPathBytes) return NO;
    g_sbPathHash = h;
    g_sbLastPathBytes = d.length;
    return YES;
}

static void sb_forget_local_paint_state(void) {
    // Fl0rk: release_all_cached_main_invocations / forget_remote_state (local side)
    if (r_is_objc_ptr(g_sbSetPathInv) && remote_call_has_local_state()) {
        r_msg2(g_sbSetPathInv, "release", 0,0,0,0);
    }
    if (g_sbSetPathArgBuf && remote_call_has_local_state()) {
        dlsym_remote("free", g_sbSetPathArgBuf, 0,0,0,0,0,0,0);
    }
    g_sbSetPathInv = 0;
    g_sbSetPathArgBuf = 0;
    g_sbPerformMainSel = 0;
    g_sbInvokeSel = 0;
    g_sbPersistentPath = 0;
    g_sbMirrorPtsBuf = 0;
    g_sbPathHash = 0;
    g_sbLastPathBytes = 0;
    g_sbLastSubpaths = 0;
    g_sbLastCalls = 0;
    g_sbNextPublishUS = 0;
}

static void sb_disable_layer_actions(uint64_t layer) {
    if (!r_is_objc_ptr(layer)) return;
    uint64_t NSMutableDictionary = r_class("NSMutableDictionary");
    uint64_t NSNullCls = r_class("NSNull");
    if (!r_is_objc_ptr(NSMutableDictionary) || !r_is_objc_ptr(NSNullCls)) return;
    uint64_t dict = r_msg2_main(NSMutableDictionary, "dictionary", 0,0,0,0);
    uint64_t nullObj = r_msg2_main(NSNullCls, "null", 0,0,0,0);
    uint64_t keyPath = r_nsstr_retained("path");
    if (r_is_objc_ptr(dict) && r_is_objc_ptr(nullObj) && r_is_objc_ptr(keyPath)) {
        r_msg2_main(dict, "setObject:forKey:", nullObj, keyPath, 0, 0);
        r_msg2_main(layer, "setActions:", dict, 0,0,0);
    }
}

static uint64_t persistentPath(void) {
    if (g_sbPersistentPath) return g_sbPersistentPath;
    g_sbPersistentPath = dlsym_remote("CGPathCreateMutable", 0,0,0,0,0,0,0,0);
    return g_sbPersistentPath;
}

static uint64_t ptsBuffer(void) {
    if (g_sbMirrorPtsBuf) return g_sbMirrorPtsBuf;
    g_sbMirrorPtsBuf = dlsym_remote("malloc", 65536, 0,0,0,0,0,0,0);
    return g_sbMirrorPtsBuf;
}

static BOOL sb_ensure_setpath_invocation(void) {
    if (r_is_objc_ptr(g_sbSetPathInv) && g_sbSetPathArgBuf) return YES;
    if (!r_is_objc_ptr(g_sbShape)) return NO;

    uint64_t rp = persistentPath();
    if (!rp) return NO;

    uint64_t setPathSel = r_sel("setPath:");
    if (!setPathSel) return NO;

    uint64_t sigSel = r_sel("methodSignatureForSelector:");
    uint64_t sig = r_msg(g_sbShape, sigSel, setPathSel, 0, 0, 0);
    if (!r_is_objc_ptr(sig)) return NO;

    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return NO;

    uint64_t inv = r_msg(NSInvocation, r_sel("invocationWithMethodSignature:"), sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return NO;
    r_msg2(inv, "retain", 0, 0, 0, 0);

    r_msg2(inv, "setTarget:", g_sbShape, 0, 0, 0);
    r_msg2(inv, "setSelector:", setPathSel, 0, 0, 0);

    uint64_t argBuf = dlsym_remote("malloc", 8, 0,0,0,0,0,0,0);
    if (!argBuf) {
        r_msg2(inv, "release", 0, 0, 0, 0);
        return NO;
    }
    remote_write64(argBuf, rp);
    r_msg2(inv, "setArgument:atIndex:", argBuf, 2, 0, 0);
    r_msg2(inv, "retainArguments", 0, 0, 0, 0);

    g_sbSetPathInv = inv;
    g_sbSetPathArgBuf = argBuf;
    g_sbPerformMainSel = r_sel("performSelectorOnMainThread:withObject:waitUntilDone:");
    g_sbInvokeSel = r_sel("invoke");
    NSLog(@"[SBOverlay] GeometryPathInvocation=0x%llx path=0x%llx", inv, rp);
    return YES;
}

static void sb_invoke_cached_main_raw(void) {
    if (!sb_ensure_setpath_invocation()) {
        uint64_t rp = persistentPath();
        if (rp) r_msg2_main_async(g_sbShape, "setPath:", rp, 0,0,0);
        return;
    }
    remote_write64(g_sbSetPathArgBuf, persistentPath());
    r_msg2(g_sbSetPathInv, "setArgument:atIndex:", g_sbSetPathArgBuf, 2, 0, 0);
    if (g_sbPerformMainSel && g_sbInvokeSel) {
        r_msg(g_sbSetPathInv, g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
    }
}

static int sb_open_session(void) {
    if (!g_kexploit_ready) return -1;
    if (remote_call_has_local_state()) {
        if (remote_call_current_success()) return 0;
        abandon_remote_call();
    }
    r_settle_us(3000);
    // Fl0rk: EXTRA trojan thread only. Never originalThreadOnly on SpringBoard —
    // that parks com.apple.main-thread at FAKE_PC 0x101 between calls → WATCHDOG
    // (seen IPS: main unresponsive, PC=0x101, 60s checkin timeout).
    int rc = init_remote_call_with_first_exception_timeout("SpringBoard", false, 15000);
    if (rc != 0) {
        NSLog(@"[SBOverlay] extra-thread init failed rc=%d — no originalThreadOnly fallback", rc);
        return -1;
    }
    uint64_t pid = do_remote_call_stable(5000, "getpid", 0,0,0,0,0,0,0,0);
    if (pid == 0) {
        destroy_remote_call();
        return -1;
    }
    return 0;
}

int SBoardStartOverlay(void) {
    pthread_mutex_lock(&g_sbLock);
    if (g_sbOverlayOn) { pthread_mutex_unlock(&g_sbLock); return 0; }
    pthread_mutex_unlock(&g_sbLock);

    if (!g_kexploit_ready) return -1;

    NSLog(@"[SBOverlay] Fl0rk start_esp_renderer_in_session (extra thread, 15fps)...");
    if (sb_open_session() != 0) {
        NSLog(@"[SBOverlay] session open failed");
        return -1;
    }

    uint64_t app = r_msg2_main(r_class("UIApplication"), "sharedApplication", 0,0,0,0);
    if (!r_is_objc_ptr(app)) { destroy_remote_call(); return -1; }

    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0,0,0,0);
    if (!r_is_objc_ptr(keyWin)) {
        uint64_t ws = r_msg2_main(app, "windows", 0,0,0,0);
        uint64_t n = r_is_objc_ptr(ws) ? r_msg2_main(ws, "count", 0,0,0,0) : 0;
        if (n > 0 && n < 64) keyWin = r_msg2_main(ws, "objectAtIndex:", 0,0,0,0);
    }
    if (!r_is_objc_ptr(keyWin)) {
        NSLog(@"[SBOverlay] no SB window");
        destroy_remote_call();
        return -1;
    }

    uint64_t scene = r_msg2_main(keyWin, "windowScene", 0,0,0,0);
    if (!r_is_objc_ptr(scene)) {
        NSLog(@"[SBOverlay] no UIWindowScene");
        destroy_remote_call();
        return -1;
    }

    double bounds[4] = {0, 0, 390, 844};
    uint64_t clsScr = r_class("UIScreen");
    if (r_is_objc_ptr(clsScr)) {
        r_msg2_main_struct_ret(r_msg2_main(clsScr, "mainScreen", 0,0,0,0),
                               "bounds", bounds, 32, NULL,0,NULL,0,NULL,0,NULL,0);
    }

    uint64_t clsCol = r_class("UIColor");
    uint64_t clear = r_is_objc_ptr(clsCol) ? r_msg2_main(clsCol, "clearColor", 0,0,0,0) : 0;
    uint64_t whiteColor = r_is_objc_ptr(clsCol) ? r_msg2_main(clsCol, "whiteColor", 0,0,0,0) : 0;
    uint64_t whiteCGColor = r_is_objc_ptr(whiteColor) ? r_msg2_main(whiteColor, "CGColor", 0,0,0,0) : 0;

    uint64_t winAlloc = r_msg2_main(r_class("UIWindow"), "alloc", 0,0,0,0);
    if (!r_is_objc_ptr(winAlloc)) { destroy_remote_call(); return -1; }

    uint64_t win = r_msg2_main(winAlloc, "initWithWindowScene:", scene, 0,0,0);
    if (!r_is_objc_ptr(win)) {
        NSLog(@"[SBOverlay] initWithWindowScene failed");
        destroy_remote_call();
        return -1;
    }

    r_msg2_main_raw(win, "setFrame:", bounds, 32, NULL,0,NULL,0,NULL,0);
    double winLevel = SB_OVERLAY_WIN_LEVEL;
    r_msg2_main_raw(win, "setWindowLevel:", &winLevel, 8, NULL,0,NULL,0,NULL,0);
    r_msg2_main(win, "setUserInteractionEnabled:", 0, 0,0,0);
    if (r_is_objc_ptr(clear)) r_msg2_main(win, "setBackgroundColor:", clear, 0,0,0);

    uint64_t container = r_msg2_main_raw(r_msg2_main(r_class("UIView"), "alloc", 0,0,0,0),
                                         "initWithFrame:", bounds, 32, NULL,0,NULL,0,NULL,0);
    if (!r_is_objc_ptr(container)) { destroy_remote_call(); return -1; }
    if (r_is_objc_ptr(clear)) r_msg2_main(container, "setBackgroundColor:", clear, 0,0,0);
    r_msg2_main(container, "setUserInteractionEnabled:", 0, 0,0,0);
    r_msg2_main(container, "setOpaque:", 0, 0,0,0);
    r_msg2_main(win, "addSubview:", container, 0,0,0);

    uint64_t shape = r_msg2_main(r_class("CAShapeLayer"), "layer", 0,0,0,0);
    if (!r_is_objc_ptr(shape)) { destroy_remote_call(); return -1; }
    r_msg2_main_raw(shape, "setFrame:", bounds, 32, NULL,0,NULL,0,NULL,0);
    if (r_is_objc_ptr(whiteCGColor)) r_msg2_main(shape, "setStrokeColor:", whiteCGColor, 0,0,0);
    r_msg2_main(shape, "setFillColor:", 0, 0,0,0);
    double lw = 1.5;
    r_msg2_main_raw(shape, "setLineWidth:", &lw, 8, NULL,0,NULL,0,NULL,0);
    r_msg2_main(shape, "setOpaque:", 0, 0,0,0);
    double z = 100;
    r_msg2_main_raw(shape, "setZPosition:", &z, 8, NULL,0,NULL,0,NULL,0);
    sb_disable_layer_actions(shape);

    uint64_t cLayer = r_msg2_main(container, "layer", 0,0,0,0);
    if (r_is_objc_ptr(cLayer)) r_msg2_main(cLayer, "addSublayer:", shape, 0,0,0);

    r_msg2_main(win, "setHidden:", 0, 0,0,0);

    uint64_t key = r_sel("fl0rkffESPMenuWindow");
    if (r_is_objc_ptr(key)) {
        dlsym_remote("objc_setAssociatedObject", app, key, win, 1, 0,0,0,0);
    }

    pthread_mutex_lock(&g_sbLock);
    g_sbWin = win;
    g_sbShape = shape;
    g_sbCanvas = container;
    g_sbOverlayOn = YES;
    pthread_mutex_unlock(&g_sbLock);

    sb_forget_local_paint_state();
    (void)persistentPath();
    (void)ptsBuffer();
    (void)sb_ensure_setpath_invocation();

    // Session STAYS OPEN — Fl0rk start_in_session until stop_in_session.
    NSLog(@"[SBOverlay] Fl0rk session LIVE win=0x%llx geom=0x%llx inv=%s @15fps extraThread",
          win, shape, r_is_objc_ptr(g_sbSetPathInv) ? "OK" : "NO");
    return 0;
}

void SBRemotePushESPFrame(UIView *espView) {
    if (!g_sbOverlayOn || !espView) return;
    if (!remote_call_has_local_state() || !remote_call_current_success()) {
        // Session died (SB respawn?). Drop until restart.
        g_sbSummarySkips++;
        return;
    }

    g_sbSummaryAttempts++;

    uint64_t t = now_us();
    if (t < g_sbNextPublishUS) {
        g_sbSummarySkips++;
        return;
    }

    static NSMutableData *ops = nil;
    if (!ops) ops = [NSMutableData dataWithCapacity:8192];

    if (!mergePaths(espView, ops)) {
        g_sbSummarySkips++;
        return;
    }

    static int s_remoteBusy = 0;
    if (__sync_lock_test_and_set(&s_remoteBusy, 1)) {
        g_sbSummarySkips++;
        return;
    }

    g_sbNextPublishUS = t + SB_MIN_PUBLISH_INTERVAL_US;
    NSData *frameBytes = [ops copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t tPubStart = now_us();
        @try {
            if (!remote_call_has_local_state() || !remote_call_current_success()) return;
            if (!r_is_objc_ptr(g_sbShape)) return;

            uint64_t rp = persistentPath();
            uint64_t ptsBuf = ptsBuffer();
            if (!rp || !ptsBuf || !remote_call_current_success()) {
                // PAC/exception failure mid-publish — stop hammering SB.
                if (remote_call_has_local_state() && !remote_call_current_success()) {
                    NSLog(@"[SBOverlay] RemoteCall failed — abandon session (avoid 0x401)");
                    abandon_remote_call();
                    pthread_mutex_lock(&g_sbLock);
                    g_sbOverlayOn = NO;
                    pthread_mutex_unlock(&g_sbLock);
                }
                return;
            }

            size_t len = frameBytes.length;
            const uint8_t *b = (const uint8_t *)frameBytes.bytes;

            // Every CoreGraphics call below crosses the process boundary into
            // SpringBoard, so a frame costs (number of calls) x (cost of one
            // remote call). The previous loop spent 2 calls per subpath over 137
            // subpaths and measured 387 calls per publish, which is 0.05 fps on
            // screen: one repaint every 21 seconds, which is the "ESP does not
            // move" symptom.
            //
            // The batchable primitive is CGPathAddRects, which appends N
            // rectangles as N independent subpaths in a single call. It is the
            // only one that exists: CGContextStrokeLines and CGContextStrokeRects
            // are absent from CoreGraphics.tbd on iOS 17.5, not even privately,
            // so there is no way to stroke N disjoint segments in one call.
            //
            // Rule: anything geometrically a rectangle is batched. Boxes,
            // snaplines and HP bars are all rectangles and together they are
            // nearly the whole frame. Skeleton limbs are the one shape that
            // cannot be batched, so they are counted and dropped unless
            // SB_DRAW_BONES is set; keeping them would put the frame back at
            // 150+ calls, and the user has accepted losing them.
            uint32_t subpaths = 0;
            uint32_t rectCount = 0;
            uint32_t limbCount = 0;
            uint64_t calls = 0;
            uint32_t drawn = 0;

            dlsym_remote("CGPathClear", rp, 0,0,0,0,0,0,0);
            calls++;

            // Scratch for the rectangle batch. ptsBuffer() holds 1024 doubles,
            // so 128 rectangles (4 doubles each) is a safe chunk; larger frames
            // are flushed in several CGPathAddRects calls rather than overrun it.
            double rectBuf[512];
            int rectDoubles = 0;

            size_t i = 0;
            while (i < len) {
                double run[1024];
                int rn = 0;
                while (i < len) {
                    uint8_t op = b[i++];
                    if (i + 16 > len) { i = len; break; }
                    double x, y; memcpy(&x, b+i, 8); memcpy(&y, b+i+8, 8); i += 16;
                    if (op == 1) {
                        if (rn > 0) break;      // next subpath starts
                        run[rn++] = x; run[rn++] = y;
                        continue;
                    }
                    run[rn++] = x; run[rn++] = y;
                    if (rn >= 1024) break;
                }
                // Two doubles is a single point. It cannot be drawn, and the old
                // code spent 3 calls on it (a remote_write plus moveTo plus
                // addLines with count=1, which renders nothing).
                if (rn < 4) continue;
                subpaths++;

                const int np = rn / 2;
                int isRect = 0;
                double rx = 0, ry = 0, rw = 0, rh = 0;

                if (np == 4) {
                    // Rectangle test: the subpath is closed and all four corners
                    // lie on the bounding box. CGPathAddRect emits exactly this,
                    // so boxes and HP bars match and everything else falls
                    // through to the polyline branch below.
                    double minX = run[0], maxX = run[0];
                    double minY = run[1], maxY = run[1];
                    for (int k = 1; k < 4; k++) {
                        double px = run[k*2], py = run[k*2+1];
                        if (px < minX) minX = px;
                        if (px > maxX) maxX = px;
                        if (py < minY) minY = py;
                        if (py > maxY) maxY = py;
                    }
                    const double w = maxX - minX, h = maxY - minY;
                    if (w > 0.5 && h > 0.5 &&
                        fabs(run[0] - run[6]) < 0.5 && fabs(run[1] - run[7]) < 0.5) {
                        isRect = 1;
                        for (int k = 0; k < 4 && isRect; k++) {
                            double px = run[k*2], py = run[k*2+1];
                            if ((fabs(px - minX) > 0.5 && fabs(px - maxX) > 0.5) ||
                                (fabs(py - minY) > 0.5 && fabs(py - maxY) > 0.5)) {
                                isRect = 0;
                            }
                        }
                        if (isRect) { rx = minX; ry = minY; rw = w; rh = h; }
                    }
                } else if (np == 2) {
                    // A lone segment. Axis-aligned ones are snaplines, which are
                    // rectangles in disguise; anything else is a skeleton limb.
                    const double x0 = run[0], y0 = run[1];
                    const double x1 = run[2], y1 = run[3];
                    const double dx = fabs(x1 - x0), dy = fabs(y1 - y0);
                    const double th = 1.0;
                    if (dx < 0.5 || dy < 0.5) {
                        isRect = 1;
                        if (dx < 0.5) { rx = fmin(x0,x1) - th; ry = fmin(y0,y1); rw = th*2; rh = dy; }
                        else           { rx = fmin(x0,x1);      ry = fmin(y0,y1) - th; rw = dx; rh = th*2; }
                    } else {
                        limbCount++;
#if SB_DRAW_BONES
                        remote_write(ptsBuf, run, (size_t)rn * 8);
                        dlsym_remote("CGPathAddLines", rp, 0, ptsBuf, 2, 0,0,0,0);
                        calls++; drawn++;
#endif
                    }
                }

                if (isRect) {
                    if (rectDoubles + 4 > (int)(sizeof(rectBuf)/sizeof(rectBuf[0]))) {
                        remote_write(ptsBuf, rectBuf, (size_t)rectDoubles * 8);
                        dlsym_remote("CGPathAddRects", rp, 0, ptsBuf,
                                     rectDoubles / 4, 0, 0,0,0);
                        calls++; drawn++;
                        rectDoubles = 0;
                    }
                    rectBuf[rectDoubles++] = rx;
                    rectBuf[rectDoubles++] = ry;
                    rectBuf[rectDoubles++] = rw;
                    rectBuf[rectDoubles++] = rh;
                    rectCount++;
                    continue;
                }

                // Everything else is one polyline in one call. CGPathAddLines
                // begins a new subpath at its first point, so separate calls
                // never join: that is what the old single-polyline version got
                // wrong and produced chords across the screen.
                remote_write(ptsBuf, run, (size_t)rn * 8);
                dlsym_remote("CGPathAddLines", rp, 0, ptsBuf, np, 0,0,0,0);
                calls++; drawn++;
            }

            if (rectDoubles >= 4) {
                remote_write(ptsBuf, rectBuf, (size_t)rectDoubles * 8);
                dlsym_remote("CGPathAddRects", rp, 0, ptsBuf, rectDoubles / 4, 0,0,0,0);
                calls++; drawn++;
            }

            if (drawn > 0) {
                sb_invoke_cached_main_raw();
                g_sbSummaryUpdates++;
                g_sbLastSubpaths = subpaths;
                g_sbLastCalls = calls;
                // [SB-PUSH] 1 Hz: what SpringBoard actually received this publish.
                // Compare p0/p1 against the app-side [PUSH] scr values. If app scr
                // moves but these do not, the hand-off is dropping frames; if both
                // move and the screen is still static, the CAShapeLayer is not
                // presenting the new path.
                {
                    static uint64_t s_sbLogUS = 0;
                    uint64_t nowS = now_us();
                    if (nowS > s_sbLogUS) {
                        s_sbLogUS = nowS + 1000000ULL;
                        // ms = wall time of one whole publish. Divided by calls it
                        // gives the per-remote-call cost, which is the number that
                        // decides the drawing design:
                        //   ~4 ms/call  -> a remote call is the bottleneck, the
                        //                   subpath count must fall to ~15.
                        //   ~0.05 ms    -> calls are cheap, keep every subpath and
                        //                   only fix the geometry.
                        // Until this is measured, both are guesses.
                        uint64_t pubMS = (now_us() - tPubStart) / 1000ULL;
                        NSLog(@"[SB-PUSH] sub=%u rect=%u limb=%u calls=%llu ms=%llu hash=%u "
                              @"upd=%llu att=%llu skip=%llu mergedSub=%u",
                              g_sbLastSubpaths, rectCount, limbCount,
                              (unsigned long long)g_sbLastCalls,
                              (unsigned long long)pubMS,
                              g_sbPathHash,
                              (unsigned long long)g_sbSummaryUpdates,
                              (unsigned long long)g_sbSummaryAttempts,
                              (unsigned long long)g_sbSummarySkips,
                              g_sbSubpathCount);
                    }
                }
                if ((g_sbSummaryUpdates & 0x3f) == 0) {
                    NSLog(@"[SBOverlay] 15fps updates=%llu skips=%llu attempts=%llu",
                          g_sbSummaryUpdates, g_sbSummarySkips, g_sbSummaryAttempts);
                }
            }
        } @finally {
            __sync_lock_release(&s_remoteBusy);
        }
    });
}

void SBoardOverlaySetStatus(const char *utf8) { (void)utf8; }

void SBoardStopOverlay(void) {
    pthread_mutex_lock(&g_sbLock);
    if (!g_sbOverlayOn) { pthread_mutex_unlock(&g_sbLock); return; }
    uint64_t win = g_sbWin;
    g_sbOverlayOn = NO;
    g_sbWin = 0;
    g_sbShape = 0;
    g_sbCanvas = 0;
    pthread_mutex_unlock(&g_sbLock);

    // Fl0rk stop_in_session
    if (remote_call_has_local_state()) {
        if (r_is_objc_ptr(win)) r_msg2_main(win, "setHidden:", 1, 0,0,0);
        if (g_sbPersistentPath) dlsym_remote("CGPathRelease", g_sbPersistentPath, 0,0,0,0,0,0,0);
        sb_forget_local_paint_state();
        destroy_remote_call();
    } else {
        sb_forget_local_paint_state();
    }
}
