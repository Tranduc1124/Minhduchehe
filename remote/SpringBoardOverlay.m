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
// Publish interval. The measured rate is not set by this number alone but by how
// it lands against the render loop, and that is what made 30fps unreachable.
//
// With a 33.3ms interval and a render loop ticking about every 22.2ms, the
// deadline only ever falls due on every second frame, so the effective period
// stretched to 44.4ms and the overlay ran at 22fps while a frame cost 11ms.
// The budget was two thirds idle and it still looked like lag.
//
// Keeping the interval under one render frame period removes the quantisation
// entirely: every frame qualifies, and the rate becomes the render loop rate,
// bounded by how long a publish actually takes. Frame cost is 9 to 16ms here,
// so 16.6ms asks for 60fps and the loop supplies what it can.
// Keeping the interval under one render frame period removes the quantisation
// entirely: every frame qualifies, and the rate becomes the render loop rate,
// bounded by how long a publish actually takes.
//
// "Under" has to mean clearly under. At 16666us against a measured loop of
// 58 to 63fps, the frame period is about 16.5ms, so the deadline lands between
// frames and only every second frame qualifies. That is the same quantisation
// as before, just on the other side of the boundary, and it held the rate at
// 35fps while the frame cost 10ms and the loop ran at 60. 8000us is roughly
// half a frame, which leaves no boundary to fall on.
#define SB_MIN_PUBLISH_INTERVAL_US 8000ULL

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

// Self-heal state for the overlay. A single transient remote-call failure used
// to clear g_sbOverlayOn for the rest of the process lifetime, and nothing
// re-armed it: boot_start_sb_overlay only retries at 3s, 5s, 8s and 12s. The
// result was exactly one painted frame followed by a frozen overlay, which is
// the report that it "only picks up once when the kernel exploit runs".
//
// Consecutive failures are counted so a hiccup is not fatal, and once the
// overlay has genuinely died it is rebuilt on a backoff instead of staying
// dead. Both log lines carry PUSH so a PUSH filter shows them.
static int g_sbConsecFail = 0;
static int g_sbEverOn = 0;
static uint64_t g_sbRearmAfterUS = 0;

// Counts consecutive frames dropped because the remote session reported itself
// dead. That check sits before g_sbSummaryAttempts++, which is why the device
// log showed skip climbing at 60/s while att stuck at 8: frames were being
// discarded at the very first gate, not rate limited. The previous self-heal
// keyed off g_sbOverlayOn, which is still 1 in that state, so it never fired.
static int g_sbSessionDead = 0;

// Wall clock of the last publish that actually completed. Recovery is driven
// off this rather than off a run of consecutive dead frames, because the
// failure is not steady: the device log shows ok flipping between 0 and 1
// several times a second, which resets any frame counter long before it can
// reach a threshold. A frame counter cannot see "nothing has been drawn for
// three seconds" when frames keep arriving and failing.
static uint64_t g_sbLastPublishUS = 0;

// Retry interval for the rebuild, doubling on each attempt up to a minute, and
// reset whenever a publish succeeds.
static uint64_t g_sbRearmBackoffUS = 5000000ULL;

// Busy-flag instrumentation: how many frames collided with a publish still in
// flight, and the total time the flag has been held. Reported as a per second
// rate so it can be compared against the frame rate.
static uint64_t g_sbBusyDrops = 0;
static uint64_t g_sbHoldUS = 0;
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
    // Name the remote call that kills the session. g_RC_success is cleared by
    // any failed remote operation, and the device log shows a healthy session
    // (ok=1) at 09:14:48, one publish at 09:14:49 costing 166 ms for two calls,
    // and ok=0 from 09:14:50 onward with no further recovery. persistentPath and
    // ptsBuffer both succeeded, since PUSH-PROBE stayed quiet, so the failure is
    // in one of the drawing calls below. This wrapper sees the symbol name of
    // every one of them, so a 1 to 0 transition names the culprit directly.
    const int okBefore = remote_call_current_success() ? 1 : 0;
    uint64_t r = r_dlsym_call(R_TIMEOUT, fn, a0,a1,a2,a3,a4,a5,a6,a7);
    if (okBefore && !remote_call_current_success()) {
        NSLog(@"[PUSH-DLSYM] %s broke the session (fn=%p)", fn, (const void *)fn);
    }
    return r;
}

static uint64_t now_us(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    uint64_t t = mach_absolute_time();
    return (t * tb.numer / tb.denom) / 1000ULL;
}

// Chords emitted per cubic or quad curve. A quarter turn split into 12 chords
// sits r*(1-cos(7.5deg)) = r*0.0086 off the true arc, which is a fifth of a
// pixel across a 20pt head, so it is not distinguishable from a real curve.
#define SB_CURVE_CHORDS 12

typedef struct {
    NSMutableData *data;
    double landW, landH;
    double lastX, lastY;    // last point emitted, needed as a curve's start
    int haveLast;
} SerCtx;
static uint32_t g_sbSubpathCount = 0;

// Appends one point, rotated into SpringBoard's portrait space. This is the
// only place the landscape geometry and the portrait display meet.
//
//   px = landH - y,  py = x
//
// is a 90 degree rotation with determinant +1, so handedness survives and
// nothing is mirrored. If the overlay ever shows upside down, the other
// rotation is px = y, py = landW - x, and nothing else moves.
static void sbEmit(SerCtx *ctx, uint8_t op, double sx, double sy) {
    CGPoint p;
    p.x = ctx->landH - sy;
    p.y = sx;
    [ctx->data appendBytes:&op length:1];
    [ctx->data appendBytes:&p length:sizeof(p)];
    ctx->lastX = sx;
    ctx->lastY = sy;
    ctx->haveLast = 1;
}

// op stream: 1 = moveTo (starts a NEW subpath), 2 = lineTo.
//
// Curves are emitted as chords, not as their endpoint. Emitting only the
// endpoint of a cubic curve discards both control points, and four of those
// discard the four corners of a circle, which is why every ellipse in this
// overlay rendered as a diamond. The device log confirms the source: a head
// measured bone=128/16, that is four players at four curve elements each.
//
// The earlier attempt at this failed and the reason is worth keeping. It
// subdivided the whole path, so straight segments were divided too, a subpath
// that was already 73 points became 584, the decoder capped a subpath at 1024
// doubles, and the shape was cut in half mid figure. That drew garbage,
// flickered, and left the overlay swallowing touches until the device needed
// a hard reset. Only curves are divided here, so a straight segment costs
// exactly what it cost before. The FOV ring is 73 straight segments and
// arrives as the same 73 points it always did, and a head ellipse goes from 4
// elements to 49, well under the cap.
static void serFunc(void *info, const CGPathElement *e) {
    SerCtx *ctx = (SerCtx *)info;
    if (e->type == kCGPathElementCloseSubpath) return;

    if (e->type == kCGPathElementAddCurveToPoint && ctx->haveLast) {
        const double p0x = ctx->lastX, p0y = ctx->lastY;
        const double p1x = e->points[0].x, p1y = e->points[0].y;
        const double p2x = e->points[1].x, p2y = e->points[1].y;
        const double p3x = e->points[2].x, p3y = e->points[2].y;
        for (int k = 1; k <= SB_CURVE_CHORDS; k++) {
            const double t  = (double)k / (double)SB_CURVE_CHORDS;
            const double mt = 1.0 - t;
            const double b0 = mt*mt*mt, b1 = 3.0*mt*mt*t, b2 = 3.0*mt*t*t, b3 = t*t*t;
            sbEmit(ctx, 2,
                   b0*p0x + b1*p1x + b2*p2x + b3*p3x,
                   b0*p0y + b1*p1y + b2*p2y + b3*p3y);
        }
        return;
    }

    if (e->type == kCGPathElementAddQuadCurveToPoint && ctx->haveLast) {
        const double p0x = ctx->lastX, p0y = ctx->lastY;
        const double p1x = e->points[0].x, p1y = e->points[0].y;
        const double p2x = e->points[1].x, p2y = e->points[1].y;
        for (int k = 1; k <= SB_CURVE_CHORDS; k++) {
            const double t  = (double)k / (double)SB_CURVE_CHORDS;
            const double mt = 1.0 - t;
            sbEmit(ctx, 2,
                   mt*mt*p0x + 2.0*mt*t*p1x + t*t*p2x,
                   mt*mt*p0y + 2.0*mt*t*p1y + t*t*p2y);
        }
        return;
    }

    if (e->type == kCGPathElementMoveToPoint) g_sbSubpathCount++;
    const CGPoint *src = &e->points[0];
    sbEmit(ctx, (e->type == kCGPathElementMoveToPoint) ? 1 : 2, src->x, src->y);
}

static BOOL mergePaths(UIView *espView, NSMutableData *d) {
    [d setLength:0];

    SerCtx ctx = { .data = d, .landW = 0, .landH = 0, .lastX = 0, .lastY = 0, .haveLast = 0 };
    {
        const CGRect vb = espView.bounds;
        ctx.landW = (vb.size.width  > vb.size.height) ? vb.size.width  : vb.size.height;
        ctx.landH = (vb.size.width  > vb.size.height) ? vb.size.height : vb.size.width;
    }
    g_sbSubpathCount = 0;

    // Each layer is serialised separately and preceded by a layer marker, rather
    // than all sixteen being merged into one path first. The merge destroyed the
    // only information that told the decoder what a shape was, and without it a
    // two point subpath is ambiguous: a snapline, the head diamond, a bone, an
    // alert tick. Guessing that wrong cost twice. Dropping the bucket deleted the
    // snaplines and the user saw none. Admitting the whole bucket brought the
    // head diamonds back, so one player showed two lines, and it cost two remote
    // calls each which took the frame from 15 calls to 115.
    //
    // The marker is what makes the bucket decidable: draw the snapline layers,
    // drop the rest.
    int emitted = 0;
    for (int i = 0; i < 16; i++) {
        id val = [espView valueForKey:[NSString stringWithUTF8String:kShapeKeys[i]]];
        if (![val isKindOfClass:[CAShapeLayer class]]) continue;
        CGPathRef p = ((CAShapeLayer *)val).path;
        if (!p || CGPathIsEmpty(p)) continue;
        uint8_t tag = 4;                       // op 4 = start of a layer
        uint8_t idx = (uint8_t)i;
        [d appendBytes:&tag length:1];
        [d appendBytes:&idx length:1];
        CGPathApply(p, &ctx, serFunc);
        emitted = 1;
    }
    if (!emitted) return NO;

    uint32_t h = 2166136261u;
    for (NSUInteger i = 0; i < d.length; i++) {
        h ^= ((const uint8_t *)d.bytes)[i]; h *= 16777619u;
    }
    // Never suppress a frame. The hash comparison is gone.
    //
    // It looked safe because it required the hash and the length to both match,
    // but identical geometry across consecutive frames is the normal case
    // whenever the camera is still, which is most of the time. The device log
    // made the symptom exact: with the camera parked the screen showed two
    // lines for one player, and nudging the camera dropped it back to one. Both
    // were correct frames, but only one was being sent, so the other stayed on
    // screen indefinitely.
    //
    // A redundant repaint costs a handful of remote calls in a budget that has
    // room for them. A stale frame is what the user is looking at instead.
    (void)h;
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
    g_sbEverOn = 1;
    g_sbConsecFail = 0;
    // Arm the recovery clock here rather than waiting for a publish that may
    // never come, so a session that starts already broken still recovers.
    g_sbLastPublishUS = now_us();
    g_sbRearmAfterUS = 0;
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
    if (!g_sbOverlayOn) {
        // Rebuild it instead of staying dead. This is the whole fix for the
        // "ESP paints once and then freezes" report: the old code cleared
        // g_sbOverlayOn on a single failure and had no path back, so the one
        // frame that did land stayed on screen for the rest of the session no
        // matter what happened in the match.
        if (g_sbEverOn && now_us() > g_sbRearmAfterUS) {
            g_sbRearmAfterUS = now_us() + 3000000ULL;   // 3s between attempts
            g_sbConsecFail = 0;
            if (SBoardStartOverlay() == 0) {
                NSLog(@"[PUSH-REARM] overlay rebuilt — ESP is live again");
            } else {
                NSLog(@"[PUSH-REARM] rebuild failed, retrying");
            }
        }
        return;
    }
    if (!espView) return;

    // Unconditional 1 Hz state dump. Every other [SB-PUSH] line sits inside the
    // success path, so a publish loop that never completes logs nothing at all
    // and the overlay state becomes invisible. That is exactly what happened:
    // thirty seconds of device log with no [SB-PUSH], no [PUSH-DEAD] and no
    // [PUSH-REARM], because a dead overlay returns before reaching any of them.
    // This line prints regardless of whether a publish happens, and says which
    // gate is holding it.
    const uint64_t tGate = now_us();
    {
        static uint64_t s_hbUS = 0;
        if (tGate > s_hbUS) {
            s_hbUS = tGate + 1000000ULL;
            const int64_t nextIn = (int64_t)g_sbNextPublishUS - (int64_t)tGate;
            const int64_t sinceDraw = (g_sbLastPublishUS == 0)
                                   ? -1 : (int64_t)(tGate - g_sbLastPublishUS);
            NSLog(@"[PUSH-HB] on=%d ever=%d fail=%d sdead=%d ls=%d ok=%d "
                  @"upd=%llu att=%llu skip=%llu next=%lldms since=%lldms",
                  (int)g_sbOverlayOn, g_sbEverOn, g_sbConsecFail, g_sbSessionDead,
                  (int)remote_call_has_local_state(),
                  (int)remote_call_current_success(),
                  (unsigned long long)g_sbSummaryUpdates,
                  (unsigned long long)g_sbSummaryAttempts,
                  (unsigned long long)g_sbSummarySkips,
                  (long long)(nextIn / 1000),
                  (long long)(sinceDraw / 1000));
        }
    }

    // Recovery lives here, above every gate, because a frame that never
    // reaches a publish can fail in several different places and the symptom
    // is the same in all of them: nothing has been drawn for a long time.
    //
    // Time based, not frame based. The failure is not steady, ok flickers
    // between 0 and 1 several times a second, so a run of consecutive dead
    // frames never reaches any threshold. Only a clock can see that three
    // seconds have passed with no completed publish while frames kept coming.
    if (g_sbEverOn && g_sbLastPublishUS != 0 && tGate > g_sbRearmAfterUS) {
        if (tGate - g_sbLastPublishUS > 3000000ULL) {      // 3s
            // Backoff grows, because SBoardStartOverlay builds a fresh window
            // and layer in SpringBoard every time. A fixed 5 second retry turns
            // a session that cannot be repaired into a loop that keeps adding
            // overlays to SpringBoard, which is a second way to break it.
            uint64_t wait = g_sbRearmBackoffUS;
            g_sbRearmAfterUS = tGate + wait;
            g_sbRearmBackoffUS = (wait < 60000000ULL) ? (wait * 2) : 60000000ULL;
            g_sbConsecFail = 0;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                const char *why =
                    remote_call_init_failure_description(remote_call_last_init_failure());
                NSLog(@"[PUSH-REARM] nothing drawn for 3s (ls=%d ok=%d init=%s pid=%d) "
                      @"— re-initialising against SpringBoard",
                      (int)remote_call_has_local_state(),
                      (int)remote_call_current_success(),
                      why ? why : "?", remote_call_current_pid());
                if (SBoardStartOverlay() == 0) {
                    NSLog(@"[PUSH-REARM] session re-initialised, overlay live");
                } else {
                    NSLog(@"[PUSH-REARM] re-init failed, will retry in 5s");
                }
            });
        }
    }
    if (!remote_call_has_local_state() || !remote_call_current_success()) {
        // Session died (SB respawn?). Drop until restart.
        g_sbSummarySkips++;
        return;
    }
    g_sbSessionDead = 0;

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
        // How long one publish holds the flag, and how often a frame arrives
        // while it is still held. The interval gate lets frames through
        // non-blockingly, so a drop here is not a wait, it is a collision with
        // the publish still in flight. With a frame cost of 10ms and a frame
        // period of 16.6ms the flag should be free again in time, and a
        // bdrops that climbs says it is not.
        g_sbBusyDrops++;
        g_sbSummarySkips++;
        return;
    }
    const uint64_t tAcquire = now_us();

    g_sbNextPublishUS = t + SB_MIN_PUBLISH_INTERVAL_US;
    NSData *frameBytes = [ops copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t tPubStart = now_us();
        @try {
            if (!remote_call_has_local_state() || !remote_call_current_success()) return;
            if (!r_is_objc_ptr(g_sbShape)) return;

            // Which operation poisons the session. g_RC_success is cleared by
            // every failed remote operation, and init_remote_call reporting
            // success does not mean the session works: the device log shows
            // "session re-initialised" immediately followed by ok=0 three
            // seconds later, so something in the first publish after a re-init
            // fails. persistentPath and ptsBuffer are the only remote work a
            // publish does before drawing, so they are probed either side of the
            // flag. Sampled only when something is actually wrong, to keep this
            // off the hot path.
            const int okBefore = remote_call_current_success() ? 1 : 0;
            uint64_t rp = persistentPath();
            const int okAfterPath = remote_call_current_success() ? 1 : 0;
            uint64_t ptsBuf = ptsBuffer();
            const int okAfterBuf = remote_call_current_success() ? 1 : 0;
            if (!okBefore || !rp || !ptsBuf || !okAfterBuf || !okAfterPath) {
                static uint64_t s_probeUS = 0;
                uint64_t tP = now_us();
                if (tP > s_probeUS) {
                    s_probeUS = tP + 2000000ULL;   // 2s
                    NSLog(@"[PUSH-PROBE] before=%d path=0x%llx afterPath=%d "
                          @"buf=0x%llx afterBuf=%d",
                          okBefore, (unsigned long long)rp, okAfterPath,
                          (unsigned long long)ptsBuf, okAfterBuf);
                }
            }
            if (!rp || !ptsBuf || !remote_call_current_success()) {
                // One failure is not a dead session. persistentPath() and
                // ptsBuffer() each make remote calls, and those are occasionally
                // flaky, so giving up here is what turned a hiccup into a
                // permanently frozen overlay. Three in a row is treated as real.
                if (remote_call_has_local_state() && !remote_call_current_success()) {
                    if (++g_sbConsecFail < 3) {
                        g_sbSummarySkips++;
                        return;   // keep the session, drop this frame
                    }
                    NSLog(@"[PUSH-DEAD] RemoteCall failed %d times in a row — overlay down, will rebuild",
                          g_sbConsecFail);
                    abandon_remote_call();
                    pthread_mutex_lock(&g_sbLock);
                    g_sbOverlayOn = NO;
                    pthread_mutex_unlock(&g_sbLock);
                    g_sbRearmAfterUS = now_us() + 2000000ULL;   // 2s
                }
                return;
            }
            g_sbConsecFail = 0;

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

            // CGPathClear does not exist. It is absent from CoreGraphics.tbd on
            // iOS 17.5, and so is CGPathReset, so there is no way to empty a
            // CGMutablePathRef in place. Every dlsym for CGPathClear therefore
            // failed, and because a failed remote operation clears
            // g_RC_success, that one nonexistent symbol poisoned the session on
            // the very first publish of every session. That is what
            // [PUSH-DLSYM] CGPathClear broke the session was reporting, and it
            // is why the overlay painted once and then stayed frozen.
            //
            // Replace it the only way CoreGraphics allows: build a new path and
            // release the old one. sb_invoke_cached_main_raw writes
            // persistentPath() into the argument buffer on every present, so
            // the path is not baked into the cached invocation and a fresh one
            // per frame is correct.
            uint64_t freshPath = dlsym_remote("CGPathCreateMutable", 0,0,0,0,0,0,0,0);
            calls++;
            if (!freshPath) {
                NSLog(@"[PUSH-PATH] CGPathCreateMutable returned 0 — skipping frame");
                return;
            }
            if (rp) dlsym_remote("CGPathRelease", rp, 0,0,0,0,0,0,0);
            rp = freshPath;
            g_sbPersistentPath = freshPath;

            // Scratch for the rectangle batch. ptsBuffer() holds 1024 doubles,
            // so 128 rectangles (4 doubles each) is a safe chunk; larger frames
            // are flushed in several CGPathAddRects calls rather than overrun it.
            double rectBuf[512];
            int rectDoubles = 0;
            // A subpath far larger than any real shape means the stream handed
            // us points belonging to more than one shape, which is what draws a
            // line across the screen. Recorded rather than assumed.
            int maxPts = 0;
            int nBig = 0;
            // Shape census. limb=47 against rect=9 does not say what those 47
            // are, and guessing is what produced three wrong fixes today. A
            // subpath is classified by its point count alone, so counting the
            // counts names every category without changing any drawing.
            int c2 = 0, c3 = 0, c4 = 0, c5to8 = 0, c9to32 = 0, c33p = 0;
            // First rectangle exactly as it is written into the remote buffer,
            // so it can be compared against the app side scr= for the same
            // player. If the two disagree the fault is in the hand-off; if they
            // agree, the fault is in the geometry upstream of the hand-off.
            double firstRect[4] = {0, 0, 0, 0};
            int haveFirstRect = 0;

            size_t i = 0;
            int curLayer = -1;
            uint32_t nTrunc = 0;     // subpaths cut at the point cap
            while (i < len) {
                // 2048 doubles is 1024 points per subpath. The largest shape in
                // this overlay is the FOV ring at 73 straight points; a head
                // ellipse is 49 after the curve chords. The previous cap of 512
                // points was cut in half mid figure in an earlier attempt and
                // that is what left the overlay swallowing touches, so the head
                // room is deliberate and nTrunc reports if it is ever used.
                double run[2048];
                int rn = 0;
                while (i < len) {
                    uint8_t op = b[i++];
                    if (op == 4) {                 // layer marker, no coordinates
                        if (i >= len) { i = len; break; }
                        curLayer = b[i++];
                        continue;
                    }
                    if (i + 16 > len) { i = len; break; }
                    double x, y; memcpy(&x, b+i, 8); memcpy(&y, b+i+8, 8); i += 16;
                    if (op == 1) {
                        // Rewind the 17 bytes just consumed (1 op + 2 doubles).
                        // Breaking here without rewinding threw away the first
                        // point of every subpath after the first, so a rectangle
                        // arrived with 3 points instead of 4 and failed the
                        // rectangle test: the device log showed rect=0 against
                        // mergedSub=69, and the subpath count collapsed from 69
                        // to 13. The next outer pass needs to see this moveTo
                        // with rn==0 in order to start the new subpath.
                        if (rn > 0) { i -= 17; break; }
                        run[rn++] = x; run[rn++] = y;
                        continue;
                    }
                    if (rn >= 2046) { nTrunc++; i = len; break; }
                    run[rn++] = x; run[rn++] = y;
                }
                // Two doubles is a single point. It cannot be drawn, and the old
                // code spent 3 calls on it (a remote_write plus moveTo plus
                // addLines with count=1, which renders nothing).
                if (rn < 4) continue;
                subpaths++;

                const int np = rn / 2;
                if (np > maxPts) maxPts = np;
                if (np > 8) nBig++;
                if (np == 2) c2++;
                else if (np == 3) c3++;
                else if (np == 4) c4++;
                else if (np <= 8) c5to8++;
                else if (np <= 32) c9to32++;
                else c33p++;
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
                        // Skeleton limb. It must be skipped explicitly: falling
                        // through to the generic polyline branch below would draw
                        // it anyway and cost one remote call each, which is
                        // exactly what SB_DRAW_BONES=0 is meant to avoid. That
                        // fall-through is why the device log reported
                        // calls=58 against limb=43, with 1+1+13 = 15 expected.
                        limbCount++;
                        // Only the snapline layers, now that the stream says
                        // which layer a subpath came from. Layers 6, 7 and 8 are
                        // snaplineLayer, snaplineBotLayer and
                        // snaplineKnockedLayer in kShapeKeys.
                        //
                        // Everything else in this bucket is a segment that is
                        // not a snapline, and drawing them is what put two lines
                        // on one player: the head diamond is drawn as segments
                        // too, so allowing the whole bucket brought the diamonds
                        // back alongside the snapline. It also cost two remote
                        // calls each and took the frame from 15 calls to 115.
                        if (curLayer >= 6 && curLayer <= 8) {
                            remote_write(ptsBuf, run, (size_t)rn * 8);
                            dlsym_remote("CGPathAddLines", rp, 0, ptsBuf, 2, 0,0,0,0);
                            calls++; drawn++;
                        }
#if SB_DRAW_BONES
                        else if (curLayer >= 3 && curLayer <= 5) {
                            remote_write(ptsBuf, run, (size_t)rn * 8);
                            dlsym_remote("CGPathAddLines", rp, 0, ptsBuf, 2, 0,0,0,0);
                            calls++; drawn++;
                        }
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
                    if (!haveFirstRect) {
                        firstRect[0] = rx; firstRect[1] = ry;
                        firstRect[2] = rw; firstRect[3] = rh;
                        haveFirstRect = 1;
                    }
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
                g_sbLastPublishUS = now_us();
                g_sbRearmBackoffUS = 5000000ULL;   // healthy again, reset backoff
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
                        // ups = publishes completed in the previous second, which
                        // is the frame rate actually achieved rather than the one
                        // the cap allows.
                        static uint64_t s_prevUpd = 0, s_prevUpdUS = 0;
                        static uint64_t s_prevDrops = 0, s_prevHold = 0;
                        uint64_t ups = 0, bdropRate = 0, holdMS = 0;
                        {
                            uint64_t tU = now_us();
                            if (tU > s_prevUpdUS + 1000000ULL) {
                                ups = g_sbSummaryUpdates - s_prevUpd;
                                bdropRate = g_sbBusyDrops - s_prevDrops;
                                holdMS = (g_sbHoldUS - s_prevHold) / 1000ULL;
                                s_prevUpd = g_sbSummaryUpdates;
                                s_prevDrops = g_sbBusyDrops;
                                s_prevHold = g_sbHoldUS;
                                s_prevUpdUS = tU;
                            }
                        }
                        NSLog(@"[SB-PUSH] sub=%u rect=%u limb=%u calls=%llu ms=%llu "
                              @"maxPts=%d nBig=%d r0=%.1f,%.1f,%.1f,%.1f ups=%llu "
                              @"bdrops=%llu hold=%llums pts2=%d pts3=%d pts4=%d "
                              @"pts58=%d pts932=%d pts33=%d hash=%u upd=%llu att=%llu skip=%llu "
                              @"mergedSub=%u trunc=%u",
                              g_sbLastSubpaths, rectCount, limbCount,
                              (unsigned long long)g_sbLastCalls,
                              (unsigned long long)pubMS,
                              maxPts, nBig,
                              firstRect[0], firstRect[1], firstRect[2], firstRect[3],
                              (unsigned long long)ups,
                              (unsigned long long)bdropRate,
                              (unsigned long long)holdMS,
                              c2, c3, c4, c5to8, c9to32, c33p,
                              g_sbPathHash,
                              (unsigned long long)g_sbSummaryUpdates,
                              (unsigned long long)g_sbSummaryAttempts,
                              (unsigned long long)g_sbSummarySkips,
                              g_sbSubpathCount, nTrunc);
                    }
                }
                if ((g_sbSummaryUpdates & 0x3f) == 0) {
                    NSLog(@"[SBOverlay] 15fps updates=%llu skips=%llu attempts=%llu",
                          g_sbSummaryUpdates, g_sbSummarySkips, g_sbSummaryAttempts);
                }
            }
        } @finally {
            // hold = how long the busy flag was held, which is the delay a
            // frame arriving right now would have to wait.
            g_sbHoldUS += now_us() - tAcquire;
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
