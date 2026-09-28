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
#import "PAC.h"
#import "remote_objc.h"
// For ESPTextRole, so the role the app stamps on each string and the role the
// overlay styles it by are the same enum and not two copies of it that can
// drift. ESPRole.h rather than esp.h, because esp.h reaches Vector3.h, which is
// C++, and this file is compiled as Objective-C.
#import "../esp/esp/ESPRole.h"
#import "../../kexploit/kexploit_opa334.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>
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
// Paths handed to setPath: are still owned by SpringBoard's main thread until
// it has run, because the present is asynchronous. A ring this long keeps every
// path alive long after the frame that drew it, and releases it only once no
// queued present can still be holding it.
#define SB_PATH_HOLD_FRAMES 4
static uint64_t g_sbPathRing[SB_PATH_HOLD_FRAMES] = {0};
static int g_sbPathRingAt = 0;
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

// The address of malloc in the target process, looked up once.
//
// dlsym_remote walks the target's symbol tables to answer it, and it was called
// from six places, one of which is inside the cached invocation builder, which
// runs once per label per selector. Thirty invocations at startup meant thirty
// symbol walks to learn an address that cannot change, and each of them goes
// through the settling transport. The size is an argument to malloc, not a part
// of the lookup, so one answer serves every size.
//
// Cleared with the rest of the session state: a respawned SpringBoard is a new
// address space, and a cached function pointer into the old one is worse than
// no pointer at all.
static uint64_t g_sbRemoteMalloc = 0;

static uint64_t dlsym_remote(const char *fn, uint64_t a0, uint64_t a1, uint64_t a2,
                             uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7);

static uint64_t sb_remote_malloc(size_t n) {
    if (!g_sbRemoteMalloc) {
        g_sbRemoteMalloc = dlsym_remote("malloc", n, 0,0,0,0,0,0,0);
    }
    return g_sbRemoteMalloc;
}
// Last publish cost, so the log says what the subpath fix actually costs.
static uint32_t g_sbLastSubpaths = 0;
static uint64_t g_sbLastCalls = 0;

// One publish split into the part that is our work and the part that is waiting
// for SpringBoard's main thread. See sb_invoke_cached_main_raw.
static uint64_t g_sbLastWaitUS = 0;

// Where the microseconds of one publish actually go.
//
// The device log says a publish costs 671 ms over 17 calls and 16 ms over 12
// calls, and that the 671 ms is not spent waiting on SpringBoard's main thread
// (wait=0 ms). So the cost is inside the calls, but "inside the calls" is not
// yet an answer: a publish is five different kinds of remote work and they are
// not remotely similar in cost. dlsym_remote does a symbol lookup each time,
// r_msg2 goes through NSInvocation, and remote_write is a plain memcpy into
// target memory. Without this split, dropping subpath count and fixing the
// symbol cache look like the same intervention and one of them is wasted.
//
// Five groups, in the order a publish does them:
//   probe   persistentPath + ptsBuffer, two remote calls before any drawing
//   pathnew CGPathCreateMutable, and the retired path's CGPathRelease
//   geom    the op loop: CGPathAddLines / CGPathAddRects
//   label   label place, text, and the hide sweep
//   flush   the trailing rect batch and the fill batch
// present is g_sbLastWaitUS and is deliberately not counted again here.
static uint64_t g_sbTProbe = 0;
static uint64_t g_sbTPathNew = 0;
static uint64_t g_sbTGeom = 0;
static uint64_t g_sbTLabel = 0;
static uint64_t g_sbTFlush = 0;
// Publishes completed since the session opened, so the log can cover the first
// few (where the 22x cold/ warm ratio showed up) and then stay quiet.
static uint64_t g_sbPubIndex = 0;
// A publish slower than this is logged whatever its index: the two 671/784 ms
// frames are the ones that stall SpringBoard's main thread, and they are worth
// seeing whenever they happen, not only at session start.
static const uint64_t SB_CALL_SLOW_US = 100000ULL;
// Log the first this many publishes unconditionally.
static const uint64_t SB_CALL_FIRST_N = 3;

// Per call record for the geometry loop, so the question "is a call expensive,
// or is a call with many points expensive" has an answer from the device
// instead of from a guess.
//
// The [SB-CALL] split showed geom is 99.4% of a 718 ms publish, and that both
// slow publishes had calls=23 while a fast one had calls=9. Same count, same
// call kinds, 31021 us per geom call against 657. So cost is not tracking the
// number of calls. What is left is the size of the argument: CGPathAddLines
// takes a count of points, and the log has been reporting maxPts=73 on every
// frame. Each of these records the point count and the wall time of that one
// call.
//
// SB_NP_MAX bounds the recording. The device log has never shown a publish
// above 58 calls, and a publish past this is so far over budget that its
// record is not the thing needing explanation.
#define SB_NP_MAX 96
static uint32_t g_sbNpArg[SB_NP_MAX];
static uint64_t g_sbNpUS[SB_NP_MAX];
static uint8_t  g_sbNpKind[SB_NP_MAX];
static int g_sbNpCount = 0;

// kind: 0 = CGPathAddLines, 1 = CGPathAddRects. arg is the point count for
// AddLines and the rectangle count for AddRects.
static void sb_np_record(int kind, uint32_t arg, uint64_t us) {
    if (g_sbNpCount >= SB_NP_MAX) return;
    g_sbNpKind[g_sbNpCount] = (uint8_t)kind;
    g_sbNpArg[g_sbNpCount] = arg;
    g_sbNpUS[g_sbNpCount] = us;
    g_sbNpCount++;
}

// Timed wrappers. These exist so the timing sits immediately around the remote
// call and cannot drift into the surrounding bookkeeping, which is exactly the
// mistake that would make the measurement agree with whatever I expected.
#define SB_GEOM_LINES(npExpr) \
    do { \
        const uint64_t _sbT0 = now_us(); \
        dlsym_remote("CGPathAddLines", rp, 0, ptsBuf, (npExpr), 0,0,0,0); \
        sb_np_record(0, (uint32_t)(npExpr), now_us() - _sbT0); \
    } while (0)

#define SB_GEOM_RECTS(pathExpr, countExpr) \
    do { \
        const uint64_t _sbT0 = now_us(); \
        dlsym_remote("CGPathAddRects", (pathExpr), 0, ptsBuf, (countExpr), 0,0,0,0); \
        sb_np_record(1, (uint32_t)(countExpr), now_us() - _sbT0); \
    } while (0)

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

// ===========================================================================
// Counter label — a real UILabel living inside SpringBoard.
//
// A CGPath can only be stroked, and a stroke is a colour and a width, so text
// drawn as a path would have to become filled rectangles, one batched call per
// string but hundreds of subpaths, in a bitmap font nobody asked for. The
// reference implementation in 0xjohnnydev/cyanide never does that: typebanner.m
// allocates a UILabel inside SpringBoard, sets a real UIFont on it, and calls
// setText:. No CATextLayer anywhere in that repository. A label is how text
// reaches a process you do not own.
//
// The catch is orientation. The overlay's whole geometry goes through
// px = landH - y, py = x, so a label placed by the same rule would draw its
// text sideways. Giving the label the linear part of that rotation as its own
// CALayer transform puts it back in the app's landscape space, which is the
// same space the path was authored in, so the text ends up oriented exactly the
// way the boxes are. Nothing here is a guess about how the device is held; it
// is the identical map that is already proven on screen.
//
//   CGAffineTransform maps (u,v) to (a*u + c*v, b*u + d*v), and the path
//   rotation minus its translation is (x, y) to (-y, x). So a=0, b=1, c=-1,
//   d=0, and CALayer puts a local point at position + T*(local - anchor*bounds).
//   With the default centred anchor that solves to position =
//   (landH - y - h/2, x + w/2) for a frame of (x, y, w, h).
//
// Position therefore moves per frame, but the text only changes when the count
// does, and setText: is only sent when it changed. A parked camera costs two
// calls. r_perform_main is used for it because it is one remote call and hops to
// the main thread; r_msg2_main is the same call with a 3ms r_settle() sleep in
// front of it, and the settle is the part that costs.
// ===========================================================================
// Longest UTF-8 run a text op may carry. Player names and weapon names go
// through the same field later, and 31 bytes covers a short name without
// letting one label overrun the buffer the decoder copies into.
#define SB_TEXT_MAX 31

// The counter label's own size and offset, in the app's landscape space. The
// label carries the path rotation as its transform, so these are its bounds,
// not its on-screen footprint. They are defined once because the position sent
// per frame is derived from them, and two copies of the same number is how the
// label ends up sized one thing and positioned as another.
#define SB_COUNT_W   90.0
#define SB_COUNT_H   34.0
#define SB_COUNT_TOP 25.0

// One counter plus two labels per pawn, name and distance. Created lazily, so a
// quiet frame costs nothing and a busy one tops out here rather than growing
// without limit inside SpringBoard.
#define SB_LABEL_MAX 25
// How many exist before the first frame. See where they are made.
#define SB_LABEL_PRESPAWN 6

// How many label updates go by between two label position pushes. See the block
// in sb_pooled_label_update.
#define SB_LABEL_MOVE_EVERY 3
static unsigned g_sbLabelFrame = 0;

// Per-pawn labels. A name label is a rounded grey card with white text, which is
// what the request asked for and it costs nothing extra: a UILabel's background
// is its own background, so the card is free once the label exists. The
// distance label sits under the feet with a clear background, so the two look
// different without a second layer or a second path.
// The name font size, shared by the app's measurement and by the label that
// draws the text. It used to be a distance scaled clamp from 4.5 to 10 points,
// which is unreadable at the bottom of that range and is what the overlay and the
// card were each independently scaling around.
#define SB_NAME_FONT_SIZE 11.0
#define SB_CARD_RADIUS 4.0
#define SB_CARD_R      0.16
#define SB_CARD_G      0.16
#define SB_CARD_B      0.16
#define SB_CARD_A      0.72
static uint64_t g_sbCountLabel   = 0;
static uint64_t g_sbCountPosInv  = 0;
static uint64_t g_sbCountPosBuf  = 0;
static double   g_sbCountLastPos[2] = { -1.0, -1.0 };
static char     g_sbCountLastText[SB_TEXT_MAX + 1] = { 0 };
static int      g_sbCountShown   = 0;

// Per-pawn labels. Index 0 is the counter, so the counter keeps its own
// variables and everything else is poolable.
static uint64_t g_sbLabelObj[SB_LABEL_MAX]        = { 0 };
static uint64_t g_sbLabelPosInv[SB_LABEL_MAX]     = { 0 };
static uint64_t g_sbLabelPosBuf[SB_LABEL_MAX]     = { 0 };
// Set while a slot is being used by the frame being decoded, so a slot is never
// handed to two strings and the hide pass knows exactly which slots went unused.
static uint8_t  g_sbLabelClaimed[SB_LABEL_MAX]    = { 0 };
static uint64_t g_sbLabelKey[SB_LABEL_MAX]       = { 0 };
static uint64_t g_sbLabelBoundsInv[SB_LABEL_MAX]  = { 0 };
static uint64_t g_sbLabelTextInv[SB_LABEL_MAX]    = { 0 };
static uint64_t g_sbLabelTextBuf[SB_LABEL_MAX]    = { 0 };
static uint64_t g_sbLabelHideInv[SB_LABEL_MAX]    = { 0 };
static uint64_t g_sbLabelHideBuf[SB_LABEL_MAX]    = { 0 };
static uint64_t g_sbLabelBoundsBuf[SB_LABEL_MAX]  = { 0 };
static double   g_sbLabelLastSize[SB_LABEL_MAX][2] = { { 0.0, 0.0 } };
static double   g_sbLabelLastPos[SB_LABEL_MAX][2] = { { -1.0, -1.0 } };
static char     g_sbLabelLastText[SB_LABEL_MAX][SB_TEXT_MAX + 1] = { { 0 } };
static int      g_sbLabelRole[SB_LABEL_MAX]       = { -1 };
static int      g_sbLabelShown[SB_LABEL_MAX]      = { 0 };
static int      g_sbLabelUsed                    = 0;
static int      g_sbLabelClaimedCount            = 0;
static int      g_sbLabelHigh                    = 0;
static uint64_t g_sbCardColor                     = 0;

// The fill layer. A CGPath carries geometry and a CALayer carries paint, so
// there is no way to fill part of a path and stroke the rest: a filled shape
// needs a layer whose fill is set. One extra layer draws every card in the frame,
// because CGPathAddRects is a single call for any number of rectangles, which the
// cost probe confirmed at sixteen rectangles for the price of one.
static uint64_t g_sbFillShape   = 0;
static uint64_t g_sbFillPath    = 0;
static uint64_t g_sbFillRing[SB_PATH_HOLD_FRAMES] = { 0 };
static int      g_sbFillRingAt  = 0;
static uint64_t g_sbFillInv     = 0;
static uint64_t g_sbFillArgBuf  = 0;
static uint32_t g_sbFillSubpaths = 0;
static int      g_sbFillWasDrawn = 0;
static uint64_t g_sbNameFont     = 0;
static uint64_t g_sbFontSmall                     = 0;
static uint64_t g_sbFontBig                       = 0;

static BOOL sb_cached_pos_invocation(void) {
    if (r_is_objc_ptr(g_sbCountPosInv) && g_sbCountPosBuf) return YES;
    if (!r_is_objc_ptr(g_sbCountLabel)) return NO;
    // The present selectors are built by sb_ensure_setpath_invocation. Without
    // them the invocation can be prepared but never run, and lastPos must not be
    // advanced, so they are required here rather than checked at the call site.
    if (!g_sbPerformMainSel || !g_sbInvokeSel) return NO;

    uint64_t setPosSel = r_sel("setPosition:");
    if (!setPosSel) return NO;
    uint64_t sig = r_msg(g_sbCountLabel, r_sel("methodSignatureForSelector:"), setPosSel, 0, 0, 0);
    if (!r_is_objc_ptr(sig)) return NO;
    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return NO;
    uint64_t inv = r_msg(NSInvocation, r_sel("invocationWithMethodSignature:"), sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return NO;
    r_msg2(inv, "retain", 0, 0, 0, 0);
    r_msg2(inv, "setTarget:", g_sbCountLabel, 0, 0, 0);
    r_msg2(inv, "setSelector:", setPosSel, 0, 0, 0);

    // 16 bytes, not 8: setPosition: takes a CGPoint. The buffer is never freed,
    // it is rewritten in place every frame, which is what lets the present run
    // with waitUntilDone:NO and still see the newest value.
    uint64_t buf = sb_remote_malloc(16);
    if (!buf) { r_msg2(inv, "release", 0, 0, 0, 0); return NO; }
    r_msg2(inv, "setArgument:atIndex:", buf, 2, 0, 0);

    g_sbCountPosInv = inv;
    g_sbCountPosBuf = buf;
    return YES;
}

// Returns the number of remote calls made, so the publish log counts them.
static uint64_t sb_count_label_place(double px, double py) {
    if (!r_is_objc_ptr(g_sbCountLabel)) return 0;
    if (!sb_cached_pos_invocation()) return 0;
    if (px == g_sbCountLastPos[0] && py == g_sbCountLastPos[1]) return 0;

    double p[2] = { px, py };
    remote_write(g_sbCountPosBuf, p, sizeof(p));
    r_msg2(g_sbCountPosInv, "setArgument:atIndex:", g_sbCountPosBuf, 2, 0, 0);
    // Only remember the position once the present that carries it has actually
    // been queued. Marking it before the queue would mean a frame that arrives
    // before the invocation is ready silently never draws the label again, which
    // is exactly the class of bug where the overlay works once and then freezes.
    r_msg(g_sbCountPosInv, g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
    g_sbCountLastPos[0] = px;
    g_sbCountLastPos[1] = py;
    return 2;
}

static uint64_t sb_count_label_text(const char *utf8) {
    if (!r_is_objc_ptr(g_sbCountLabel) || !utf8) return 0;
    if (strcmp(g_sbCountLastText, utf8) == 0) return 0;

    uint64_t nsbuf = r_alloc_str(utf8);
    if (!nsbuf) return 0;
    uint64_t NSStringCls = r_class("NSString");
    uint64_t alloc = r_is_objc_ptr(NSStringCls) ? r_msg2(NSStringCls, "alloc", 0, 0, 0, 0) : 0;
    uint64_t ns = r_is_objc_ptr(alloc) ? r_msg2(alloc, "initWithUTF8String:", nsbuf, 0, 0, 0) : 0;
    r_free(nsbuf);
    if (!r_is_objc_ptr(ns)) return 0;

    uint64_t calls = 4;   // malloc, memcpy, alloc, initWithUTF8String
    r_perform_main(g_sbCountLabel, r_sel("setText:"), ns, false);
    calls++;
    dlsym_remote("CFRelease", ns, 0,0,0,0,0,0,0);
    calls++;

    strncpy(g_sbCountLastText, utf8, sizeof(g_sbCountLastText) - 1);
    g_sbCountLastText[sizeof(g_sbCountLastText) - 1] = 0;
    return calls;
}

static uint64_t sb_count_label_hide(int hidden) {
    if (!r_is_objc_ptr(g_sbCountLabel)) return 0;
    if (g_sbCountShown == !hidden) return 0;
    g_sbCountShown = !hidden;
    r_perform_main(g_sbCountLabel, r_sel("setHidden:"), (hidden ? 1 : 0), false);
    return 1;
}

// A pooled label, for the per-pawn name and distance text.
//
// Built the same way as the counter: a real UILabel added to the same
// container, carrying the path rotation as its transform so its text is
// oriented the way the boxes are. The difference is the background, which is
// what makes the grey card. A UILabel's background is the label's own, so the
// card costs nothing beyond the label existing: no second CAShapeLayer, no
// second path, no extra present per frame.
//
// Set once per role change, not per frame, because a UILabel's background,
// corner radius, font and colour are all fixed once chosen.
// The rotation, and the invocation that carries it, are needed by
// sb_make_pooled_label, which is below the label pool's other helpers.
static uint64_t g_sbLabelTransInv[SB_LABEL_MAX] = { 0 };
static uint64_t g_sbLabelTransBuf[SB_LABEL_MAX] = { 0 };

static BOOL sb_cached_invocation(uint64_t label, const char *selName,
                                 uint64_t *invOut, uint64_t *bufOut, size_t bufSize);

static uint64_t sb_make_pooled_label(uint64_t container, int role, int slot) {
    if (!r_is_objc_ptr(container)) return 0;

    uint64_t UILabel = r_class("UILabel");
    if (!r_is_objc_ptr(UILabel)) return 0;
    uint64_t alloc = r_msg2_main(UILabel, "alloc", 0, 0, 0, 0);
    uint64_t label = r_is_objc_ptr(alloc) ? r_msg2_main(alloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(label)) return 0;

    r_msg2_main(label, "setUserInteractionEnabled:", 0, 0, 0, 0);
    r_msg2_main(label, "setTextAlignment:", 1, 0, 0, 0);      // centre
    r_msg2_main(label, "setNumberOfLines:", 1, 0, 0, 0);

    // The font, which this label was never given.
    //
    // Without it a UILabel draws at the system default, around seventeen points,
    // whatever size the app measured the name at. The app measures with an eight
    // point font, the card is drawn to that measurement, and the label then paints
    // twice the size inside it, so the text spills out sideways and reads as a
    // wide banner stuck to the pawn. The counter label has always set its own font
    // explicitly and has always looked right, which is why only the names did it.
    //
    // One font for every pooled label, set once at creation, because every pooled
    // label is a name now that the distance is held back. The app uses the same
    // size for its measurement, so card and text agree by construction.
    if (r_is_objc_ptr(g_sbNameFont)) r_msg2_main(label, "setFont:", g_sbNameFont, 0, 0, 0);
    r_msg2_main(label, "setAdjustsFontSizeToFitWidth:", 0, 0, 0, 0);

    uint64_t UIColor = r_class("UIColor");
    // No background here any more. The card is a filled rectangle in the fill
    // layer, drawn from the same measurement, and giving the label a background
    // as well would put a second grey box behind the first one. What is left is
    // white text on the card the geometry drew.
    const bool isCard = false;
    if (r_is_objc_ptr(UIColor)) {
        uint64_t clear = r_msg2_main(UIColor, "clearColor", 0, 0, 0, 0);
        uint64_t white = r_msg2_main(UIColor, "whiteColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(clear)) r_msg2_main(label, "setBackgroundColor:", clear, 0, 0, 0);
        if (r_is_objc_ptr(white)) r_msg2_main(label, "setTextColor:", white, 0, 0, 0);
        if (isCard) {
            double rgba[4] = { SB_CARD_R, SB_CARD_G, SB_CARD_B, SB_CARD_A };
            if (!r_is_objc_ptr(g_sbCardColor)) {
                g_sbCardColor = r_msg2_main_raw(UIColor, "colorWithRed:green:blue:alpha:",
                                                &rgba[0], 8, &rgba[1], 8,
                                                &rgba[2], 8, &rgba[3], 8);
            }
            if (r_is_objc_ptr(g_sbCardColor)) {
                r_msg2_main(label, "setBackgroundColor:", g_sbCardColor, 0, 0, 0);
            }
        }
    }

    // Rounded card. CALayer has no cornerRadius of its own worth touching here;
    // a UIView's own layer does, and masksToBounds is what clips the fill to it.
    uint64_t layer = r_msg2_main(label, "layer", 0, 0, 0, 0);
    if (r_is_objc_ptr(layer)) {
        // The corner radius is not set. setCornerRadius: takes a CGFloat, and
        // every route to a scalar argument here is r_msg_main_raw, which is
        // thirteen blocking remote calls. A square card is what a card needs to
        // be; rounded corners were never asked for and are not worth a
        // thousandfold of the per frame budget at nine labels.
    }

    // No size here on purpose. setFrame: takes a CGRect, so it can only go
    // through r_msg_main_raw, which is around thirteen blocking remote calls per
    // label, and the size arrives with the first frame anyway through the cached
    // setBounds: invocation, which is two calls and does not block. The one size
    // set that must happen here is the transform, because it is what orients the
    // text and it is set exactly once per label.
    // The rotation, through a cached invocation: two calls and it does not wait,
    // where r_msg_main_raw is around thirteen calls and does, because it presents
    // with waitUntilDone:YES.
    //
    // One per label, not one shared. A cached invocation is bound to its target
    // when it is built, so a single shared one meant the first label got the
    // rotation and every later label kept the default: their text drew along the
    // screen's short axis and came out sideways, which is what was reported. The
    // counter was unaffected because it sets its own transform separately.
    if (slot >= 0 && slot < SB_LABEL_MAX &&
        sb_cached_invocation(label, "setTransform:",
                             &g_sbLabelTransInv[slot], &g_sbLabelTransBuf[slot], 48)) {
        double tr[6] = { 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 };
        remote_write(g_sbLabelTransBuf[slot], tr, sizeof(tr));
        r_msg2(g_sbLabelTransInv[slot], "setArgument:atIndex:", g_sbLabelTransBuf[slot], 2, 0, 0);
        r_msg(g_sbLabelTransInv[slot], g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
    }

    r_msg2_main(container, "addSubview:", label, 0, 0, 0);
    // A pooled label is born hidden. A UILabel is visible by default, and the
    // pool is made before the first frame, so a label that has not been given a
    // position yet would be sitting at the origin waiting for one. It has no
    // bounds and no text at that point so it draws nothing, but it is one more
    // thing that has to be true rather than one fewer.
    r_msg2_main(label, "setHidden:", 1, 0, 0, 0);

    // A new object has no bounds, so any size remembered for the slot is void.
    // The caller does not know whether this label replaced an earlier one.
    if (slot >= 0 && slot < SB_LABEL_MAX) {
        g_sbLabelLastSize[slot][0] = 0.0;
        g_sbLabelLastSize[slot][1] = 0.0;
    }
    return label;
}

// A cached NSInvocation with one persistent 16 or 32 byte argument buffer,
// exactly as the setPath: present already does. The alternative,
// r_msg_main_raw, builds a fresh invocation per call: methodSignatureForSelector:
// plus invocationWithMethodSignature: plus a malloc per argument plus
// retainArguments plus performSelectorOnMainThread with waitUntilDone:YES plus
// getReturnValue: plus a free. That is around thirteen remote calls for one
// setter, and it blocks until SpringBoard's main thread runs it. Measured cost
// of ignoring that here was calls=186 and ms=6046 on the first frame, a six
// second stall, with hold=6892ms behind it.
static BOOL sb_cached_invocation(uint64_t label, const char *selName,
                                 uint64_t *invOut, uint64_t *bufOut, size_t bufSize) {
    if (r_is_objc_ptr(*invOut) && *bufOut) return YES;
    if (!r_is_objc_ptr(label)) return NO;
    if (!g_sbPerformMainSel || !g_sbInvokeSel) return NO;

    uint64_t sel = r_sel(selName);
    if (!sel) return NO;
    uint64_t sig = r_msg(label, r_sel("methodSignatureForSelector:"), sel, 0, 0, 0);
    if (!r_is_objc_ptr(sig)) return NO;
    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return NO;
    uint64_t inv = r_msg(NSInvocation, r_sel("invocationWithMethodSignature:"), sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return NO;
    r_msg2(inv, "retain", 0, 0, 0, 0);
    r_msg2(inv, "setTarget:", label, 0, 0, 0);
    r_msg2(inv, "setSelector:", sel, 0, 0, 0);
    uint64_t buf = sb_remote_malloc(bufSize);
    if (!buf) { r_msg2(inv, "release", 0, 0, 0, 0); return NO; }
    r_msg2(inv, "setArgument:atIndex:", buf, 2, 0, 0);
    *invOut = inv;
    *bufOut = buf;
    return YES;
}

static BOOL sb_pooled_pos_invocation(int idx) {
    if (idx < 0 || idx >= SB_LABEL_MAX) return NO;
    if (r_is_objc_ptr(g_sbLabelPosInv[idx]) && g_sbLabelPosBuf[idx]) return YES;
    uint64_t label = g_sbLabelObj[idx];
    if (!r_is_objc_ptr(label)) return NO;
    if (!g_sbPerformMainSel || !g_sbInvokeSel) return NO;

    uint64_t setPosSel = r_sel("setPosition:");
    if (!setPosSel) return NO;
    uint64_t sig = r_msg(label, r_sel("methodSignatureForSelector:"), setPosSel, 0, 0, 0);
    if (!r_is_objc_ptr(sig)) return NO;
    uint64_t NSInvocation = r_class("NSInvocation");
    if (!r_is_objc_ptr(NSInvocation)) return NO;
    uint64_t inv = r_msg(NSInvocation, r_sel("invocationWithMethodSignature:"), sig, 0, 0, 0);
    if (!r_is_objc_ptr(inv)) return NO;
    r_msg2(inv, "retain", 0, 0, 0, 0);
    r_msg2(inv, "setTarget:", label, 0, 0, 0);
    r_msg2(inv, "setSelector:", setPosSel, 0, 0, 0);
    uint64_t buf = sb_remote_malloc(16);
    if (!buf) { r_msg2(inv, "release", 0, 0, 0, 0); return NO; }
    r_msg2(inv, "setArgument:atIndex:", buf, 2, 0, 0);
    g_sbLabelPosInv[idx] = inv;
    g_sbLabelPosBuf[idx] = buf;
    return YES;
}

// Two calls, and only when the size actually changed. r_msg_main_raw would be
// about thirteen and would block.
static uint64_t sb_pooled_label_resize(int idx, double w, double h) {
    if (idx < 0 || idx >= SB_LABEL_MAX) return 0;
    uint64_t label = g_sbLabelObj[idx];
    if (!r_is_objc_ptr(label)) return 0;
    if (!sb_cached_invocation(label, "setBounds:",
                              &g_sbLabelBoundsInv[idx], &g_sbLabelBoundsBuf[idx], 32)) {
        return 0;
    }
    if (w == g_sbLabelLastSize[idx][0] && h == g_sbLabelLastSize[idx][1]) return 0;
    double r[4] = { 0.0, 0.0, w, h };
    remote_write(g_sbLabelBoundsBuf[idx], r, sizeof(r));
    r_msg2(g_sbLabelBoundsInv[idx], "setArgument:atIndex:", g_sbLabelBoundsBuf[idx], 2, 0, 0);
    r_msg(g_sbLabelBoundsInv[idx], g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
    g_sbLabelLastSize[idx][0] = w;
    g_sbLabelLastSize[idx][1] = h;
    return 2;
}

// Returns the number of remote calls made, so the publish log counts them.
static uint64_t sb_pooled_label_update(int idx, int role, double px, double py,
                                       double w, double h, const char *utf8) {
    if (idx < 0 || idx >= SB_LABEL_MAX) return 0;
    uint64_t label = g_sbLabelObj[idx];
    if (!r_is_objc_ptr(label)) return 0;
    uint64_t calls = 0;

    // A role change means a different look, and the look is not per frame.
    if (g_sbLabelRole[idx] != role) {
        g_sbLabelRole[idx] = role;
        g_sbLabelLastText[idx][0] = 0;   // force the text to be re-sent
    }

    // Rounded before comparing. A camera that is nearly still nudges every
    // position by a fraction of a point, and at a compare on exact doubles that
    // is a present per label per frame for a move nobody can see.
    px = floor(px * 2.0) * 0.5;
    py = floor(py * 2.0) * 0.5;
    w  = floor(w + 0.5);
    h  = floor(h + 0.5);
    calls += sb_pooled_label_resize(idx, w, h);

    if (px == g_sbLabelLastPos[idx][0] && py == g_sbLabelLastPos[idx][1]) {
        // Position unchanged, which is the common case when the camera is parked.
    } else if (++g_sbLabelFrame % SB_LABEL_MOVE_EVERY != 0) {
        // A moving pawn changes its label position on every single frame, and
        // each of those is a block queued onto SpringBoard's main thread. Four
        // labels at thirty publishes a second is three hundred and sixty blocks a
        // second to drain for text that is static, only anchored to a head that
        // is already moving on screen.
        //
        // One in three is twenty label positions a second for a name tag, which
        // is not a thing anyone can see, and it takes the pressure off the one
        // queue that can no longer be drained by waiting.
    } else if (sb_pooled_pos_invocation(idx)) {
        double p[2] = { px, py };
        remote_write(g_sbLabelPosBuf[idx], p, sizeof(p));
        r_msg2(g_sbLabelPosInv[idx], "setArgument:atIndex:", g_sbLabelPosBuf[idx], 2, 0, 0);
        r_msg(g_sbLabelPosInv[idx], g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
        g_sbLabelLastPos[idx][0] = px;
        g_sbLabelLastPos[idx][1] = py;
        calls += 2;
    }

    if (utf8 && strcmp(g_sbLabelLastText[idx], utf8) != 0) {
        uint64_t nsbuf = r_alloc_str(utf8);
        if (nsbuf) {
            uint64_t NSStringCls = r_class("NSString");
            uint64_t alloc = r_is_objc_ptr(NSStringCls) ? r_msg2(NSStringCls, "alloc", 0, 0, 0, 0) : 0;
            uint64_t ns = r_is_objc_ptr(alloc) ? r_msg2(alloc, "initWithUTF8String:", nsbuf, 0, 0, 0) : 0;
            r_free(nsbuf);
            if (r_is_objc_ptr(ns)) {
                // Through a cached invocation, not r_perform_main.
                //
                // Everything known to work here goes through one: setPath: for the
                // boxes, setBounds:, setPosition: and setTransform: for the labels.
                // setText: and setHidden: were the only two left on r_perform_main,
                // and they were the only two misbehaving, which is not a
                // coincidence to keep ignoring. The argument is the NSString's
                // address written into a persistent buffer, exactly as the path
                // pointer is written for setPath:.
                if (sb_cached_invocation(label, "setText:",
                                         &g_sbLabelTextInv[idx], &g_sbLabelTextBuf[idx], 8)) {
                    remote_write64(g_sbLabelTextBuf[idx], ns);
                    r_msg2(g_sbLabelTextInv[idx], "setArgument:atIndex:", g_sbLabelTextBuf[idx], 2, 0, 0);
                    r_msg(g_sbLabelTextInv[idx], g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
                }
                dlsym_remote("CFRelease", ns, 0,0,0,0,0,0,0);
                calls += 6;
                strncpy(g_sbLabelLastText[idx], utf8, SB_TEXT_MAX);
                g_sbLabelLastText[idx][SB_TEXT_MAX] = 0;
            }
        }
    }

    if (!g_sbLabelShown[idx]) {
        if (sb_cached_invocation(label, "setHidden:",
                                 &g_sbLabelHideInv[idx], &g_sbLabelHideBuf[idx], 8)) {
            remote_write64(g_sbLabelHideBuf[idx], 0);
            r_msg2(g_sbLabelHideInv[idx], "setArgument:atIndex:", g_sbLabelHideBuf[idx], 2, 0, 0);
            r_msg(g_sbLabelHideInv[idx], g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
        }
        g_sbLabelShown[idx] = 1;
        calls += 1;
    }
    return calls;
}

static void sb_make_count_label(uint64_t container) {
    if (g_sbCountLabel || !r_is_objc_ptr(container)) return;

    uint64_t UILabel = r_class("UILabel");
    if (!r_is_objc_ptr(UILabel)) return;
    uint64_t alloc = r_msg2_main(UILabel, "alloc", 0, 0, 0, 0);
    uint64_t label = r_is_objc_ptr(alloc) ? r_msg2_main(alloc, "init", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(label)) return;

    // A label is not interactive by default, but the overlay window is
    // already non-interactive and this is the property that would matter if
    // that ever changed: a label that eats a tap is the bug the old overlay
    // had.
    r_msg2_main(label, "setUserInteractionEnabled:", 0, 0, 0, 0);
    r_msg2_main(label, "setTextAlignment:", 1, 0, 0, 0);   // centre
    r_msg2_main(label, "setNumberOfLines:", 1, 0, 0, 0);

    uint64_t UIColor = r_class("UIColor");
    uint64_t clear = r_is_objc_ptr(UIColor) ? r_msg2_main(UIColor, "clearColor", 0, 0, 0, 0) : 0;
    uint64_t red   = r_is_objc_ptr(UIColor) ? r_msg2_main(UIColor, "redColor",   0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(clear)) r_msg2_main(label, "setBackgroundColor:", clear, 0, 0, 0);
    if (r_is_objc_ptr(red))   r_msg2_main(label, "setTextColor:", red, 0, 0, 0);

    uint64_t UIFont = r_class("UIFont");
    if (r_is_objc_ptr(UIFont)) {
        double fs = 26.0;
        uint64_t font = r_msg_main_raw(UIFont, r_sel("systemFontOfSize:"),
                                       &fs, 8, NULL, 0, NULL, 0, NULL, 0);
        if (r_is_objc_ptr(font)) r_msg2_main(label, "setFont:", font, 0, 0, 0);
    }

    // Size first, while the transform is still identity, so setFrame: means what
    // it says.
    //
    // This is the whole reason nothing appeared. A CALayer draws nothing at all
    // with zero bounds, and setPosition: alone never gives it any: position is
    // where the layer is, bounds is how big it is, and only bounds was ever set
    // on this label. The frame log confirmed the mechanism was running, txt=1 on
    // every publish and calls unchanged at 2 and 10, so the text was being set
    // into a label with no area to draw it in.
    double frame[4] = { 0.0, 0.0, SB_COUNT_W, SB_COUNT_H };
    r_msg_main_raw(label, r_sel("setFrame:"), frame, sizeof(frame),
                   NULL, 0, NULL, 0, NULL, 0);

    // The rotation that puts the label in the same space the path is in.
    double tr[6] = { 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 };
    r_msg_main_raw(label, r_sel("setTransform:"), tr, sizeof(tr),
                   NULL, 0, NULL, 0, NULL, 0);

    r_msg2_main(container, "addSubview:", label, 0, 0, 0);

    // Read the size straight back out of SpringBoard's own CALayer, the same way
    // lineWidth was verified, so "the label has an area" is a measured fact and
    // not an assumption. The sentinel is minus one, so a real zero is
    // distinguishable from a read that did not happen.
    double bBack[4] = { -1.0, -1.0, -1.0, -1.0 };
    const bool bOK = r_msg2_main_struct_ret(label, "bounds", bBack, sizeof(bBack),
                                            NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    NSLog(@"[SB-LABEL] counter label=0x%llx created bounds=%.1f,%.1f %.1fx%.1f ok=%d",
          label, bBack[0], bBack[1], bBack[2], bBack[3], (int)bOK);

    g_sbCountLabel = label;
}

static BOOL mergePaths(UIView *espView, NSMutableData *d, int enemyCount) {
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
    // Text runs ride alongside the geometry as op 5.
    //
    //   op 5, len, x, y, w, h, utf8[len]
    //
    // The count arrives as an argument rather than being read back off
    // statusLayer, so nothing here depends on a layer being hidden, on its
    // string being current, or on it being in the pool. Two rounds of scraping
    // produced txt=0 on every publish.
    //
    // The position is the same one the app used: an 80pt wide field centred on
    // the landscape width, 25pt from the top. It never moves, so the label
    // costs two calls once and then nothing, however long the match runs.
    //
    // px and py are the label's own centre, because it carries the path
    // rotation as its CALayer transform. Swapping w and h as well would rotate
    // the text twice.
    if (r_is_objc_ptr(g_sbCountLabel) && enemyCount >= 0) {
        char num[8];
        const int n = snprintf(num, sizeof(num), "%d", enemyCount);
        if (n > 0 && n <= SB_TEXT_MAX) {
            const double w = SB_COUNT_W, h = SB_COUNT_H;
            const double px = ctx.landH - SB_COUNT_TOP - h * 0.5;
            const double py = ctx.landW * 0.5;
            uint8_t top = 5;
            uint8_t role = 3;                       // counter
            uint8_t slen = (uint8_t)n;
            // The identity field, eight zero bytes. The record layout is the same
            // for every text run, so the counter carries one too.
            //
            // It did not, and the reader had already moved on. Every run is read
            // with a fixed layout, so a short record is not detected as short: the
            // reader simply took the first eight bytes of the next record as the
            // missing field, which is the start of the first name, and from there
            // the whole frame was offset. The symptom was txt=1 instead of five,
            // subpath counts over ninety points when the largest real shape is
            // seventy three, and rectangles assembled from the bytes of player
            // names, which is what was flashing white across the screen.
            uint64_t lkey = 0;
            [d appendBytes:&top length:1];
            [d appendBytes:&role length:1];
            [d appendBytes:&slen length:1];
            [d appendBytes:&lkey length:8];
            [d appendBytes:&px length:8];
            [d appendBytes:&py length:8];
            [d appendBytes:&w length:8];
            [d appendBytes:&h length:8];
            [d appendBytes:num length:(size_t)n];
            emitted = 1;
        }
    }

    // Every other piece of text the app drew this frame.
    //
    // The role comes from the pool the app fills in, not from a guess. Four
    // builds went into guessing: the counter was hunted for in this pool by font
    // size when it does not live here at all, then read back off statusLayer,
    // and the name and distance labels were going to be told apart by frame
    // width. The producer knows what each string is and now says so.
    {
        NSArray *layers = [espView valueForKey:@"textLayerPool"];
        NSArray *roles  = [espView valueForKey:@"textRolePool"];
        NSArray *keys   = [espView valueForKey:@"textKeyPool"];
        NSNumber *active = [espView valueForKey:@"activeTextLayerCount"];
        if ([layers isKindOfClass:[NSArray class]] &&
            [roles  isKindOfClass:[NSArray class]] &&
            [active isKindOfClass:[NSNumber class]]) {
            const NSUInteger n = MIN((NSUInteger)[active unsignedIntegerValue], layers.count);
            for (NSUInteger i = 0; i < n; i++) {
                CATextLayer *tl = layers[i];
                if (![tl isKindOfClass:[CATextLayer class]] || tl.hidden) continue;
                if (i >= roles.count) break;
                const int role = [roles[i] intValue];
                // The weapon name and the distance are not sent. The distance was
                // asked to come back later, after the card is settled.
                if (role == 1 || role == 2) continue;
                NSString *str = tl.string;
                if (![str isKindOfClass:[NSString class]] || str.length == 0) continue;
                const char *utf8 = str.UTF8String;
                if (!utf8) continue;
                const size_t slen = strlen(utf8);
                if (slen == 0 || slen > SB_TEXT_MAX) continue;

                const CGRect r = tl.frame;
                const double w = r.size.width, h = r.size.height;
                if (w < 4.0 || h < 4.0) continue;
                const double px = ctx.landH - r.origin.y - h * 0.5;
                const double py = r.origin.x + w * 0.5;
                uint8_t top = 5;
                uint8_t rr = (uint8_t)role;
                uint8_t sl = (uint8_t)slen;
                // Identity of whatever the text belongs to, so the overlay keys
                // its labels on the pawn rather than on the string.
                id keyObj = (i < keys.count) ? keys[i] : nil;
                const uint64_t lk = [keyObj isKindOfClass:[NSNumber class]]
                                  ? (uint64_t)[keyObj unsignedLongLongValue] : 0ULL;
                [d appendBytes:&top length:1];
                [d appendBytes:&rr length:1];
                [d appendBytes:&sl length:1];
                [d appendBytes:&lk length:8];
                [d appendBytes:&px length:8];
                [d appendBytes:&py length:8];
                [d appendBytes:&w length:8];
                [d appendBytes:&h length:8];
                [d appendBytes:utf8 length:slen];
                emitted = 1;
            }
        }
    }

    // What the text block above actually saw. Three rounds of txt=0 were spent
    // guessing which of its four conditions was false, none of which was in the
    // log. bytes is the decisive one: if the op had been appended the stream
    // would be twenty bytes longer than the same frame without a counter.
    {
        static uint64_t s_txtLogUS = 0;
        const uint64_t nowS = now_us();
        if (nowS > s_txtLogUS) {
            s_txtLogUS = nowS + 1000000ULL;
            // A label that is shown but not claimed is a label whose pawn is
            // gone and whose hide has not happened, which is the stuck name. It is
            // named here, with the pawn it still thinks it belongs to and the last
            // position it was given, so the two cases can be told apart: a key that
            // belongs to nobody, or a key that belongs to a pawn which is somehow
            // still sending names.
            int shownNow = 0;
            for (int k = 0; k < SB_LABEL_MAX; k++) {
                if (!g_sbLabelShown[k]) continue;
                shownNow++;
                if (g_sbLabelClaimed[k]) continue;
                NSLog(@"[SB-STUCK] slot=%d key=0x%llx pos=%.1f,%.1f text=%s",
                      k, (unsigned long long)g_sbLabelKey[k],
                      g_sbLabelLastPos[k][0], g_sbLabelLastPos[k][1],
                      g_sbLabelLastText[k]);
            }
            NSLog(@"[SB-TXT] lbl=%d cnt=%d fill=%d made=%d claimed=%d shown=%d high=%d "
                  @"landW=%.0f landH=%.0f bytes=%lu emitted=%d",
                  (int)r_is_objc_ptr(g_sbCountLabel), enemyCount,
                  (int)r_is_objc_ptr(g_sbFillShape),
                  g_sbLabelUsed, g_sbLabelClaimedCount, shownNow, g_sbLabelHigh,
                  ctx.landW, ctx.landH, (unsigned long)d.length, emitted);
        }
    }

    // Op 6 marks a filled layer. Only the card uses it. It is a separate stream
    // from the stroked geometry because the two go to different layers with
    // different paint, and a path cannot say which part of it is which.
    {
        id cardL = [espView valueForKey:@"cardLayer"];
        if ([cardL isKindOfClass:[CAShapeLayer class]]) {
            CGPathRef cp = ((CAShapeLayer *)cardL).path;
            if (cp && !CGPathIsEmpty(cp)) {
                uint8_t tag = 6;
                [d appendBytes:&tag length:1];
                SerCtx cctx = { .data = d, .landW = ctx.landW, .landH = ctx.landH,
                                 .lastX = 0, .lastY = 0, .haveLast = 0 };
                CGPathApply(cp, &cctx, serFunc);
                emitted = 1;
            }
        }
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
    // The label itself is left alone. It is a subview of the overlay window, so
    // the window going away takes it with it, and the session that is about to
    // be rebuilt creates a fresh one. Only the local pointers and the cached
    // last text are cleared, because those refer to a process that no longer
    // exists and reading them would be a use after free.
    g_sbCountPosInv = 0;
    g_sbCountPosBuf = 0;
    g_sbCountLabel = 0;
    g_sbCountLastPos[0] = -1.0;
    g_sbCountLastPos[1] = -1.0;
    g_sbCountLastText[0] = 0;
    g_sbCountShown = 0;
    // Pooled labels are subviews of the overlay window, so the window taking them
    // down takes them with it. Only the local pointers are cleared, because those
    // refer to a process that no longer exists.
    for (int k = 0; k < SB_LABEL_MAX; k++) {
        g_sbLabelObj[k] = 0;
        g_sbLabelPosInv[k] = 0;
        g_sbLabelPosBuf[k] = 0;
        g_sbLabelTextInv[k] = 0;
        g_sbLabelTextBuf[k] = 0;
        g_sbLabelHideInv[k] = 0;
        g_sbLabelHideBuf[k] = 0;
        g_sbLabelBoundsInv[k] = 0;
        g_sbLabelBoundsBuf[k] = 0;
        g_sbLabelLastPos[k][0] = -1.0;
        g_sbLabelLastPos[k][1] = -1.0;
        g_sbLabelLastText[k][0] = 0;
        g_sbLabelRole[k] = -1;
        g_sbLabelShown[k] = 0;
        // The remembered size goes with them. A fresh label starts with zero
        // bounds, so a cache that still holds the old size makes
        // sb_pooled_label_resize decide the bounds are already right, and the
        // label stays zero sized and draws nothing. That is why two names out of
        // four appeared: the two whose measurements happened to match the
        // figures left over from the previous session.
        g_sbLabelLastSize[k][0] = 0.0;
        g_sbLabelLastSize[k][1] = 0.0;
        g_sbLabelClaimed[k] = 0;
        g_sbLabelKey[k] = 0;
    }
    g_sbLabelUsed = 0;
    g_sbLabelHigh = 0;
    g_sbCardColor = 0;
    g_sbFillShape = 0;
    g_sbFillPath = 0;
    g_sbFillInv = 0;
    g_sbFillArgBuf = 0;
    g_sbFillSubpaths = 0;
    g_sbFillWasDrawn = 0;
    g_sbNameFont = 0;
    // malloc's address belongs to the process the session pointed at. A
    // respawned SpringBoard is a new address space, so a cached one is a call
    // through a stale pointer rather than a slow one.
    g_sbRemoteMalloc = 0;
    for (int t = 0; t < SB_LABEL_MAX; t++) { g_sbLabelTransInv[t] = 0; g_sbLabelTransBuf[t] = 0; }
    g_sbFillRingAt = 0;
    for (int k = 0; k < SB_PATH_HOLD_FRAMES; k++) g_sbFillRing[k] = 0;
    g_sbPathHash = 0;
    g_sbLastPathBytes = 0;
    g_sbLastSubpaths = 0;
    g_sbLastCalls = 0;
    g_sbNextPublishUS = 0;
    // The [SB-CALL] split is only interesting while a session is warming up,
    // and "warm up" is per session. Without this reset the first-N budget is
    // spent on the first session the process ever runs and every later session,
    // which is where the 671 ms frames were seen, logs nothing until one of
    // them is slow enough to trip SB_CALL_SLOW_US.
    g_sbPubIndex = 0;
    // The hold ring outlives the session pointer, so it is emptied here rather
    // than left for the next SBoardStartOverlay to overwrite.
    for (int k = 0; k < SB_PATH_HOLD_FRAMES; k++) g_sbPathRing[k] = 0;
    g_sbPathRingAt = 0;
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
    g_sbMirrorPtsBuf = sb_remote_malloc(65536);
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

    uint64_t argBuf = sb_remote_malloc(8);
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
    // waitUntilDone:NO, always, and never wait on the main thread again.
    //
    // It was YES, and that is what killed the device. The watchdog report is
    // unambiguous: com.apple.main-thread unresponsive, sixty seconds without a
    // successful checkin, and the main thread parked in a mach_msg receive with
    // a turnstile block on the app's task. A hang, not a slow frame.
    //
    // The deadlock is ours. do_remote_call hijacks a thread from the target to
    // run a call, and the main thread is the thread it is most willing to take.
    // Code running on a hijacked main thread that then performs on the main
    // thread waits for a message that only the main thread could deliver, and
    // the main thread is busy being the thing that is waiting. The result is a
    // main thread that never returns to its runloop, and backboardd kills
    // SpringBoard.
    //
    // A growing queue is a slow overlay. A deadlocked main thread is no system.
    // When both were on the table the queue won and the device restarted, so the
    // queue is bounded the other way instead: nothing waits, and the per frame
    // label updates are decimated so there are far fewer blocks to drain.
    if (g_sbPerformMainSel && g_sbInvokeSel) {
        const uint64_t tWait = now_us();
        r_msg(g_sbSetPathInv, g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
        g_sbLastWaitUS = now_us() - tWait;
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

// One-shot cost probe.
//
// The two numbers that decide the whole drawing design have never been measured
// apart. [SB-PUSH] puts every CoreGraphics call and the present into one wall
// clock, and the only samples the device log has are calls=2 ms=6 and
// calls=67 ms=27. Those two are only compatible with a fixed cost near 5.4ms
// per publish on top of near 0.32ms per remote call, and nothing in the log
// says which call the 5.4ms belongs to. Guessing at that produced four wrong
// designs today, so it is measured instead.
//
// This runs once, at overlay start, and draws nothing. The only layer call is
// the same setPath: present every publish makes, and the path it hands over is
// replaced by the first real frame. Every remote call below is one the publish
// loop already makes, so the numbers are the numbers the design needs.
static uint64_t sb_now_ns(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return mach_absolute_time() * tb.numer / tb.denom;
}

static void sb_cost_probe(void) {
    static int s_done = 0;
    if (s_done) return;
    s_done = 1;
    if (!remote_call_has_local_state() || !remote_call_current_success()) return;

    // A. Local symbol lookup, nothing crosses the process boundary.
    // do_remote_call_stable runs exactly this on every single call, so this is
    // the per-call cost that resolving the address once would remove.
    uint64_t tA = sb_now_ns();
    for (int i = 0; i < 2000; i++) dlsym(RTLD_DEFAULT, "getpid");
    uint64_t aDlsym = (sb_now_ns() - tA) / 2000ULL;

    // B. One bare remote call, looked up by name every time. This is what the
    // publish loop pays per CGPath call today.
    uint64_t tB = sb_now_ns();
    for (int i = 0; i < 20; i++) r_dlsym_call(R_TIMEOUT, "getpid", 0,0,0,0,0,0,0,0);
    uint64_t bByName = (sb_now_ns() - tB) / 20ULL;

    // C. The identical call with the address resolved once. B minus C is the
    // whole value of never looking the name up again.
    uint64_t getpidAddr = native_strip((uint64_t)dlsym(RTLD_DEFAULT, "getpid"));
    uint64_t pidCheck = do_remote_call_stable_addr(R_TIMEOUT, getpidAddr, "getpid", 0,0,0,0,0,0,0,0);
    uint64_t tC = sb_now_ns();
    for (int i = 0; i < 20; i++) do_remote_call_stable_addr(R_TIMEOUT, getpidAddr, "getpid", 0,0,0,0,0,0,0,0);
    uint64_t cByAddr = (sb_now_ns() - tC) / 20ULL;

    // D. Cold call. If the fixed cost is a re-arm, the first call after an idle
    // gap is the expensive one and the rest are cheap, and that shows up here
    // as a large number sitting next to C.
    usleep(SB_MIN_PUBLISH_INTERVAL_US);
    uint64_t tD = sb_now_ns();
    do_remote_call_stable_addr(R_TIMEOUT, getpidAddr, "getpid", 0,0,0,0,0,0,0,0);
    uint64_t dCold = sb_now_ns() - tD;

    // E. Path creation, once per publish, because CGPathClear and CGPathReset
    // are both absent from CoreGraphics.tbd on iOS 17.5 and a fresh path is the
    // only way to empty one.
    uint64_t made[8] = {0};
    uint64_t tE = sb_now_ns();
    for (int i = 0; i < 8; i++) made[i] = dlsym_remote("CGPathCreateMutable", 0,0,0,0,0,0,0,0);
    uint64_t eCreate = (sb_now_ns() - tE) / 8ULL;

    // F. Two point polyline, the smallest thing a publish can draw.
    double seg2[4] = {10.0, 10.0, 40.0, 40.0};
    remote_write(ptsBuffer(), seg2, sizeof(seg2));
    uint64_t tF = sb_now_ns();
    for (int i = 0; i < 8; i++) dlsym_remote("CGPathAddLines", made[i], 0, ptsBuffer(), 2, 0,0,0,0);
    uint64_t fLines = (sb_now_ns() - tF) / 8ULL;

    // G. CGPathAddRects is the only primitive that loops inside SpringBoard,
    // which is the only reason the rectangle batch is cheap at all. One call
    // and sixteen calls' worth of rectangles, to separate the per-call cost from
    // the per-rectangle cost. If the per-rectangle cost is negligible then
    // every shape that is a rectangle is free and the design stops having to
    // care about call counts, which is the whole question here.
    double rects16[64];
    for (int i = 0; i < 16; i++) {
        rects16[i*4+0] = 10.0 + (double)i;
        rects16[i*4+1] = 10.0 + (double)i;
        rects16[i*4+2] = 6.0;
        rects16[i*4+3] = 4.0;
    }
    remote_write(ptsBuffer(), rects16, sizeof(rects16));
    uint64_t tG1 = sb_now_ns();
    for (int i = 0; i < 8; i++) dlsym_remote("CGPathAddRects", made[i], 0, ptsBuffer(), 1, 0,0,0,0);
    uint64_t gRect1 = (sb_now_ns() - tG1) / 8ULL;
    uint64_t tG16 = sb_now_ns();
    for (int i = 0; i < 8; i++) dlsym_remote("CGPathAddRects", made[i], 0, ptsBuffer(), 16, 0,0,0,0);
    uint64_t gRect16 = (sb_now_ns() - tG16) / 8ULL;

    // H. remote_write. It is a memcpy into a page already shared with
    // SpringBoard, so it should cost nothing next to a call. If it does not,
    // then the transport is not the one RemoteCall.m says it is.
    uint64_t tH = sb_now_ns();
    for (int i = 0; i < 8; i++) remote_write(ptsBuffer(), rects16, sizeof(rects16));
    uint64_t hWrite = (sb_now_ns() - tH) / 8ULL;

    // I. The present, once per layer. This is the number that decides how many
    // colours the overlay can afford at all.
    uint64_t tI = sb_now_ns();
    for (int i = 0; i < 4; i++) sb_invoke_cached_main_raw();
    uint64_t iPresent = (sb_now_ns() - tI) / 4ULL;

    for (int i = 0; i < 8; i++) {
        if (made[i]) dlsym_remote("CGPathRelease", made[i], 0,0,0,0,0,0,0);
    }

    NSLog(@"[SB-PROBE] n=20 dlsymLocal=%.1fus callByName=%.1fus callByAddr=%.1fus "
          @"cold=%.1fus create=%.1fus addLines2=%.1fus addRects1=%.1fus "
          @"addRects16=%.1fus write512B=%.1fus present=%.1fus pidOk=%d",
          aDlsym / 1000.0, bByName / 1000.0, cByAddr / 1000.0, dCold / 1000.0,
          eCreate / 1000.0, fLines / 1000.0, gRect1 / 1000.0, gRect16 / 1000.0,
          hWrite / 1000.0, iPresent / 1000.0, (int)(pidCheck != 0));

    // A probe that breaks the session must not take the overlay down with it.
    if (remote_call_has_local_state() && !remote_call_current_success()) {
        NSLog(@"[SB-PROBE] session unhealthy after probe — dropping it so the rearm path rebuilds clean");
        abandon_remote_call();
        pthread_mutex_lock(&g_sbLock);
        g_sbOverlayOn = NO;
        pthread_mutex_unlock(&g_sbLock);
        g_sbRearmAfterUS = now_us() + 2000000ULL;
    }
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

    // Forget the previous session's objects here, once, with the session open
    // and before anything in this session exists.
    //
    // It used to be at the end of this function, and this function creates the
    // shape, the fill layer, the counter label and the label pool. Every one of
    // them was assigned to a global and then cleared by this same call before the
    // first publish could see it. The fill layer is the third casualty after the
    // counter label: each worked on the first try, each was dead on arrival, and
    // each time the symptom was a feature that produced nothing.
    //
    // A reset that runs between creation and use is not a reset. It is a race
    // with a fixed outcome. It runs here, where its purpose is served, which is
    // invalidating pointers into a process that is no longer there.
    sb_forget_local_paint_state();

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

    // Built with four separate CGFloats, which is the call the diagnostic proved
    // carries its arguments: numberWithDouble: on the same path came back
    // describing itself as 1.5, and setLineWidth: read straight back out of the
    // CALayer as 1.50. So four doubles in one call is not the open question it
    // was three rounds ago.
    double greenRGBA[4] = { 0.0, 1.0, 0.0, 1.0 };
    uint64_t greenColor = r_is_objc_ptr(clsCol)
                        ? r_msg2_main_raw(clsCol, "colorWithRed:green:blue:alpha:",
                                          &greenRGBA[0], 8, &greenRGBA[1], 8,
                                          &greenRGBA[2], 8, &greenRGBA[3], 8)
                        : 0;
    uint64_t greenCGColor = r_is_objc_ptr(greenColor)
                          ? r_msg2_main(greenColor, "CGColor", 0,0,0,0) : 0;
    if (!r_is_objc_ptr(greenCGColor)) greenCGColor = whiteCGColor;

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

    // The multi argument colour test that used to live here is gone. It was
    // written to answer whether four separate CGFloat arguments survive the
    // crossing, the device answered it, and the answer is in this file's history:
    // they do. [SB-COLOR] lw want=0.75 got=0.75 ok=1 on every boot is the same
    // read path and still is worth having, because lineWidth is a call this
    // overlay depends on. Everything else it printed was three lines of noise per
    // overlay start and several remote calls to produce a conclusion that has not
    // changed in a dozen builds.

    uint64_t shape = r_msg2_main(r_class("CAShapeLayer"), "layer", 0,0,0,0);
    if (!r_is_objc_ptr(shape)) { destroy_remote_call(); return -1; }
    r_msg2_main_raw(shape, "setFrame:", bounds, 32, NULL,0,NULL,0,NULL,0);
    // White. It was green, and that was deliberate: commit 69cab125 set the
    // stroke to green as a one-round proof that four CGFloat arguments survive
    // the crossing, so the colour could be read off the screen instead of off a
    // log line that had already been wrong four times. The proof was made and
    // the diagnostic was never taken back down, so the overlay has been drawing
    // green ever since. The requested ESP is monochrome white.
    if (r_is_objc_ptr(whiteCGColor)) r_msg2_main(shape, "setStrokeColor:", whiteCGColor, 0,0,0);
    r_msg2_main(shape, "setFillColor:", 0, 0,0,0);
    // 0.75, down from 1.5. At 1.5 the box reads as a thick slab on a phone
    // screen and the horizontal health bar 2.5pt tall disappears into its own
    // outline. Half a point is the thinnest CAShapeLayer stroke that still
    // rasterises to a full pixel row on this display.
    double lw = 0.75;
    r_msg2_main_raw(shape, "setLineWidth:", &lw, 8, NULL,0,NULL,0,NULL,0);

    // Read the width straight back out of SpringBoard's own CALayer. This is the
    // most direct measurement available: it is the exact call the overlay depends
    // on for its stroke weight, and the read uses getReturnValue: into a target
    // buffer followed by remote_read, which is the same read path already proven
    // good by the colour test. No reinterpretation and no colour space involved.
    //
    // The sentinel is minus one, so a value of 0.00 is a real zero and minus one
    // means the read did not happen.
    double lwBack = -1.0;
    bool lwOK = r_msg2_main_struct_ret(shape, "lineWidth", &lwBack, 8,
                                       NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    NSLog(@"[SB-LW] want=%.2f got=%.2f ok=%d", lw, lwBack, (int)lwOK);
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

    // The filled layer for the cards: no stroke at all, grey fill, and it sits
    // under the stroke layer so a card never draws over a box edge.
    uint64_t fillShape = r_msg2_main(r_class("CAShapeLayer"), "layer", 0,0,0,0);
    if (r_is_objc_ptr(fillShape)) {
        r_msg2_main_raw(fillShape, "setFrame:", bounds, 32, NULL,0,NULL,0,NULL,0);
        if (r_is_objc_ptr(whiteCGColor)) r_msg2_main(fillShape, "setStrokeColor:", 0, 0,0,0);
        // Darker and more opaque than it was. The card sits over a game whose
        // background is not a fixed colour, and at 0.16 grey and 0.72 the white
        // name lost against a bright part of the scene. The text was never the
        // wrong colour: white text on a card that is too light reads as dim, and
        // the card is what the contrast lives on.
        double gray[4] = { 0.10, 0.10, 0.10, 0.82 };
        uint64_t grayColor = r_msg2_main_raw(r_class("UIColor"),
                                             "colorWithRed:green:blue:alpha:",
                                             &gray[0], 8, &gray[1], 8,
                                             &gray[2], 8, &gray[3], 8);
        if (r_is_objc_ptr(grayColor)) {
            uint64_t gcg = r_msg2_main(grayColor, "CGColor", 0,0,0,0);
            if (r_is_objc_ptr(gcg)) r_msg2_main(fillShape, "setFillColor:", gcg, 0,0,0);
        }
        r_msg2_main(fillShape, "setOpaque:", 0, 0,0,0);
        double zf = 99.0;
        r_msg2_main_raw(fillShape, "setZPosition:", &zf, 8, NULL,0,NULL,0,NULL,0);
        sb_disable_layer_actions(fillShape);
        if (r_is_objc_ptr(cLayer)) r_msg2_main(cLayer, "addSublayer:", fillShape, 0,0,0);
        g_sbFillShape = fillShape;
        g_sbFillPath = dlsym_remote("CGPathCreateMutable", 0,0,0,0,0,0,0,0);
        NSLog(@"[SB-FILL] fill layer=0x%llx path=0x%llx", fillShape, g_sbFillPath);
    }

    // The filled layer first, before anything that is slow.
    //
    // The card only exists on this layer, and it was being made last, after the
    // font, the counter label and six pre-spawned labels, each of which settles
    // three milliseconds per call. The device log had fill=0 for the first eight
    // seconds of a session, and the report matches it exactly: pawns already
    // alive when the overlay came up had boxes and names but no card at all, and
    // a card only appeared for a pawn that spawned afterwards. Everything the
    // card needs exists by the time this returns, so there is no reason for it
    // not to be here.

    (void)persistentPath();
    (void)ptsBuffer();
    (void)sb_ensure_setpath_invocation();
    // A real UILabel, added as a subview of the same container, so the counter
    // can be a number in a real font instead of a path that can only be
    // stroked. The frame moves per publish, the text only when the count
    // changes.
    //
    // It has to be created after sb_forget_local_paint_state, not before. That
    // function clears g_sbCountLabel, because on a dead session the pointer
    // refers to a process that no longer exists and must not be reused. It is
    // also called at the end of this very function, so a label made earlier in
    // this function was cleared again before the first publish could see it.
    // The device log agreed and named it exactly: [SB-LABEL] counter label
    // created, then [SB-TXT] lbl=0 on every frame, four builds after the label
    // was known to work.
    // One font for every label, made once. Making it inside the per label
    // creation meant an r_msg_main_raw per label, and that call waits for
    // SpringBoard's main thread, which is two blocking main thread turns for
    // something that does not change.
    {
        uint64_t UIFont = r_class("UIFont");
        if (r_is_objc_ptr(UIFont) && !r_is_objc_ptr(g_sbNameFont)) {
            double fs = SB_NAME_FONT_SIZE;
            g_sbNameFont = r_msg_main_raw(UIFont, r_sel("boldSystemFontOfSize:"),
                                          &fs, 8, NULL, 0, NULL, 0, NULL, 0);
        }
    }
    sb_make_count_label(container);

    // The label pool is made now rather than during the match.
    //
    // A frame that makes a label costs six hundred to eight hundred milliseconds
    // and drops the rate to two, and the frames that did it always followed a
    // pawn appearing. Making a label is a dozen setters, and every one of them
    // goes through r_msg2 or r_msg2_main, and r_settle is a three millisecond
    // sleep in front of all of them, so a class selector, an instance, a font, a
    // transform and a cached invocation for that transform together are well over
    // a hundred milliseconds of sleeping before anything is drawn.
    //
    // Spreading them one per frame did not fix it, it moved the cost onto whichever
    // frame happened to be on screen, and a pawn appearing is exactly when the
    // player is moving the camera, which is when a stall shows.
    //
    // So they are made here, before the first publish, where a slower start costs
    // nothing. Six covers three pawns with room. The request was twenty, and
    // twenty labels at this cost is a five second start, which is the very wait
    // this build was supposed to be removing; the on demand path stays for
    // anything beyond six.
    for (int i = 0; i < SB_LABEL_PRESPAWN; i++) {
        const uint64_t pre = sb_make_pooled_label(container, ESPTextRoleName, i);
        if (!r_is_objc_ptr(pre)) break;
        g_sbLabelObj[i] = pre;
        g_sbLabelUsed++;

        // Build its invocations now, not when the label is first used.
        //
        // A cached invocation costs a method signature lookup, an
        // invocationWithMethodSignature: and a remote malloc the first time, and
        // each of those goes through r_msg2, which settles three milliseconds
        // before it runs. A label needs five: position, bounds, text, hidden and
        // transform. Built on demand that is about six hundred milliseconds of
        // construction spread over the first seconds of a match, one label at a
        // time, and the device log shows it as frames of sixty to a hundred and
        // seventy milliseconds with the label count climbing from zero across
        // them. Nineteen remote calls do not cost a hundred and seventeen
        // milliseconds; a constructor does, and from the outside it looks exactly
        // like a slow frame.
        (void)sb_cached_invocation(pre, "setPosition:",
                                   &g_sbLabelPosInv[i], &g_sbLabelPosBuf[i], 16);
        (void)sb_cached_invocation(pre, "setBounds:",
                                   &g_sbLabelBoundsInv[i], &g_sbLabelBoundsBuf[i], 32);
        (void)sb_cached_invocation(pre, "setText:",
                                   &g_sbLabelTextInv[i], &g_sbLabelTextBuf[i], 8);
        (void)sb_cached_invocation(pre, "setHidden:",
                                   &g_sbLabelHideInv[i], &g_sbLabelHideBuf[i], 8);
        (void)sb_cached_invocation(pre, "setTransform:",
                                   &g_sbLabelTransInv[i], &g_sbLabelTransBuf[i], 48);
    }
    NSLog(@"[SB-LABEL] pre-spawned pool=%d of %d", g_sbLabelUsed, SB_LABEL_PRESPAWN);

    // Created after sb_forget_local_paint_state for the same reason the counter
    // label is: that function clears every pointer into the previous session, and
    // it also runs at the end of this function, so anything made before it is
    // cleared again before the first publish can see it. It cost one round on the
    // label and one round here, both times silently, and both times the symptom
    // was a feature that produced nothing.

    // Measures what one call and one present actually cost, once, before any
    // frame depends on the answer. See sb_cost_probe.
    sb_cost_probe();

    // Session STAYS OPEN — Fl0rk start_in_session until stop_in_session.
    NSLog(@"[SBOverlay] Fl0rk session LIVE win=0x%llx geom=0x%llx inv=%s @15fps extraThread",
          win, shape, r_is_objc_ptr(g_sbSetPathInv) ? "OK" : "NO");
    return 0;
}

void SBRemotePushESPFrame(UIView *espView, int enemyCount) {
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

    if (!mergePaths(espView, ops, enemyCount)) {
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
            const uint64_t tProbeStart = now_us();
            uint64_t rp = persistentPath();
            const int okAfterPath = remote_call_current_success() ? 1 : 0;
            uint64_t ptsBuf = ptsBuffer();
            const int okAfterBuf = remote_call_current_success() ? 1 : 0;
            const uint64_t tProbeEnd = now_us();
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
            // Text runs seen this frame. Zero means the app drew no counter, and
            // the label is hidden rather than left showing the last number.
            uint32_t txtOps = 0;
            // Pooled label slot handed to this frame's first name, and how many
            // slots exist so far. Labels are made on demand, so a frame with one
            // enemy makes two and a frame with none makes nothing.
            //
            // g_sbLabelHigh is deliberately not cleared here. It is the high
            // water mark from the previous frame, and the loop at the end of this
            // one walks from txtSlot up to it to hide the labels a shorter frame
            // no longer used. Zeroing it here meant that loop always compared
            // against zero and never ran, so a name stuck on screen after the
            // pawn behind it died. That was a line of mine, added in the same
            // commit as the pool, and it defeated the pool's own cleanup.
            int txtSlot = 0;
            uint32_t cardOps = 0;
            // One new label per frame, for the reason given at the allocation.
            static int sb_labelsMadeThisFrame = 0;
            sb_labelsMadeThisFrame = 0;
            g_sbLabelClaimedCount = 0;
            for (int k = 0; k < SB_LABEL_MAX; k++) g_sbLabelClaimed[k] = 0;

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
            //
            // But the old path must not be released in the same breath. The
            // present is asynchronous: performSelectorOnMainThread is called
            // with no boolean, so waitUntilDone is NO and SpringBoard's main
            // thread runs setPath: on a later turn of its run loop, at least one
            // frame behind this thread. Releasing here freed the path out from
            // under that queued call. retainArguments does not save it either,
            // because that is only called once when the invocation is built; the
            // argument is overwritten with setArgument:atIndex: every frame and
            // the new value is never retained.
            //
            // The symptom was one snapline becoming two while the camera stood
            // still, and collapsing to one as soon as it moved. The device log
            // rules out a duplicate in the data: one player measures pts2=14,
            // which is thirteen bone segments plus exactly one snapline, so a
            // second line is not in the stream. A parked camera produces frames
            // that are byte identical, they queue faster than the main thread
            // drains them, and the stale path is what the layer still holds.
            // Moving the camera changes every frame, the queue drains, and the
            // count is right again.
            //
            // So the path is kept alive for SB_PATH_HOLD_FRAMES frames. At the
            // 8000us publish interval that is about 130ms, far longer than a
            // main thread turn.
            const uint64_t tPathNewStart = now_us();
            uint64_t freshPath = dlsym_remote("CGPathCreateMutable", 0,0,0,0,0,0,0,0);
            calls++;
            if (!freshPath) {
                NSLog(@"[PUSH-PATH] CGPathCreateMutable returned 0 — skipping frame");
                return;
            }
            // Retire the path that fell out of the hold window, not the one the
            // previous present used.
            if (g_sbPathRing[g_sbPathRingAt]) {
                dlsym_remote("CGPathRelease", g_sbPathRing[g_sbPathRingAt], 0,0,0,0,0,0,0);
                g_sbPathRing[g_sbPathRingAt] = 0;
            }
            g_sbPathRing[g_sbPathRingAt] = freshPath;
            g_sbPathRingAt = (g_sbPathRingAt + 1) % SB_PATH_HOLD_FRAMES;
            rp = freshPath;
            g_sbPersistentPath = freshPath;

            // Scratch for the card batch, same buffer and same primitive as the
            // stroke batch, kept separate so one flush of each is one call.
            double fillDoubles[256];
            int fillN = 0;
            uint32_t fillDrawn = 0;
            uint64_t fillPath = 0;
            if (r_is_objc_ptr(g_sbFillShape)) {
                uint64_t fp = dlsym_remote("CGPathCreateMutable", 0,0,0,0,0,0,0,0);
                calls++;
                if (fp) {
                    if (g_sbFillRing[g_sbFillRingAt]) {
                        dlsym_remote("CGPathRelease", g_sbFillRing[g_sbFillRingAt], 0,0,0,0,0,0,0);
                        g_sbFillRing[g_sbFillRingAt] = 0;
                    }
                    g_sbFillRing[g_sbFillRingAt] = fp;
                    g_sbFillRingAt = (g_sbFillRingAt + 1) % SB_PATH_HOLD_FRAMES;
                    fillPath = fp;
                    g_sbFillPath = fp;
                }
            }
            // End of pathnew. Taken here because the fill path is created in
            // the same breath as the stroke path and is the same kind of work:
            // a dlsym_remote for CGPathCreateMutable plus a CGPathRelease of the
            // path that aged out of the hold window.
            const uint64_t tGeomStart = now_us();
            // Per call records start here, so they cover the geometry loop and
            // the two trailing batches and nothing before them.
            g_sbNpCount = 0;

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
                    // Op 6 opens a filled subpath: the cards. They go to the
                    // second layer, which has a grey fill and no stroke, and they
                    // are all rectangles, so the whole set is one
                    // CGPathAddRects. That is the cost probe's sixteen
                    // rectangles for the price of one, applied to the one shape
                    // that genuinely needs a fill.
                    // Text run: one byte of length, two doubles of already
                    // rotated centre, then the UTF-8. Handled before the
                    // coordinate branch because it has a different shape, and
                    // it is not a subpath so it must not fall into one.
                    //
                    // Op 6 opens the filled section: the cards. It is a marker
                    // and nothing else, because the points after it are in the
                    // same format as every other point in the stream, one op byte
                    // and two doubles each. The reader that used to be here
                    // tried to take four bare doubles per rectangle, which is not
                    // what serFunc emits: a rectangle is four points, so sixty
                    // eight bytes, not thirty two. It read past the end of its own
                    // data, which is why one card sometimes drew, four cards never
                    // did, and frames with four took six hundred milliseconds.
                    //
                    // Op 6 is the cards. Read here and read completely, rather
                    // than through the shared subpath reader: a card is four
                    // points, so four op bytes and four coordinate pairs, and a
                    // reader that has to also decide where the section ends is a
                    // reader that can decide wrongly and then take the rest of
                    // the frame with it. That is what happened twice.
                    if (op == 6) {
                        // Every card in the frame, not one.
                        //
                        // Op 6 is a marker for the whole filled section: the app
                        // emits it once and then every card's four points, so a
                        // reader that takes four points and returns leaves the
                        // rest to the stroke reader. That is where three of the
                        // four cards went: they arrived as ordinary white
                        // rectangles on the stroke layer, which is the empty
                        // outline the device showed, and cards=1 against
                        // cardOps=1 is consistent with exactly that.
                        //
                        // Four points is seventeen bytes each, so a card is
                        // sixty eight. Anything left over that is not a whole card
                        // is dropped rather than guessed at.
                        while (i + 4 * 17 <= len) {
                            double cfx0 = 0, cfy0 = 0, cfx1 = 0, cfy1 = 0;
                            int got = 0;
                            while (got < 4 && i + 17 <= len) {
                                i++;                              // the op byte
                                double px2, py2;
                                memcpy(&px2, b + i, 8); memcpy(&py2, b + i + 8, 8);
                                i += 16;
                                if (got == 0) { cfx0 = cfx1 = px2; cfy0 = cfy1 = py2; }
                                else {
                                    if (px2 < cfx0) cfx0 = px2; else if (px2 > cfx1) cfx1 = px2;
                                    if (py2 < cfy0) cfy0 = py2; else if (py2 > cfy1) cfy1 = py2;
                                }
                                got++;
                            }
                            if (got < 4) break;
                            const double cw = cfx1 - cfx0, ch = cfy1 - cfy0;
                            if (cw > 0.5 && ch > 0.5) {
                                fillDoubles[fillN * 4 + 0] = cfx0;
                                fillDoubles[fillN * 4 + 1] = cfy0;
                                fillDoubles[fillN * 4 + 2] = cw;
                                fillDoubles[fillN * 4 + 3] = ch;
                                fillN++;
                            }
                            cardOps++;
                        }
                        i = len;
                        continue;
                    }
                    if (op == 5) {
                        // op 5, role, len, key(8), px, py, w, h, utf8[len]
                        if (i + 42 > len) { i = len; break; }
                        const uint8_t role = b[i++];
                        const uint8_t slen = b[i++];
                        if (slen > SB_TEXT_MAX) { i = len; break; }
                        uint64_t lkey = 0;
                        memcpy(&lkey, b + i, 8); i += 8;
                        double tpx, tpy, tw, th;
                        memcpy(&tpx, b + i, 8);      memcpy(&tpy, b + i + 8, 8);
                        memcpy(&tw,  b + i + 16, 8);  memcpy(&th,  b + i + 24, 8);
                        i += 32;
                        if (i + slen > len) { i = len; break; }
                        char txt[SB_TEXT_MAX + 1];
                        memcpy(txt, b + i, slen);
                        txt[slen] = 0;
                        i += slen;
                        txtOps++;
                        if (role == 3) {
                            // The counter has its own label and its own cached
                            // position, and it never moves.
                            calls += sb_count_label_place(tpx, tpy);
                            calls += sb_count_label_text(txt);
                            calls += sb_count_label_hide(0);
                        } else {
                            // Find the slot that already holds this role and this
                            // text, rather than taking the next free index.
                            //
                            // Taking the next free index is what made the frame
                            // cost calls=64 and ms=150, and it was structural
                            // rather than a tuning problem: the app emits the
                            // pool in the order it walks the pawns, so the moment
                            // one pawn leaves, every label after it shifts down
                            // two slots. A shifted label has the wrong role, the
                            // role change forces the text to be re-sent at six
                            // calls and the size to be re-sent at two, and eight
                            // labels doing that is sixty-four calls of re-sending
                            // text that was already on screen and already correct.
                            //
                            // Matching on content instead makes a name keep its
                            // slot for as long as that name is on screen. A steady
                            // frame then costs two calls per label, the position,
                            // and nothing else.
                            //
                            // Distance labels are matched on their text too, so
                            // two pawns at the same distance may trade slots. That
                            // is harmless: identical role, identical text, and the
                            // position is written either way.
                            int idx = -1;
                            for (int k = 0; k < SB_LABEL_MAX; k++) {
                                if (g_sbLabelClaimed[k]) continue;
                                if (!r_is_objc_ptr(g_sbLabelObj[k])) continue;
                                // Matched on the pawn's identity, never on the
                                // string. Every bot in this game is called BOT, so
                                // matching on text gave all of them one slot: they
                                // took turns writing it, the position flipped
                                // between pawns every frame, and the names of the
                                // other three never appeared at all. That is the
                                // text that would not stay with its card.
                                if (g_sbLabelRole[k] != role) continue;
                                if (g_sbLabelKey[k] != lkey) continue;
                                idx = k;
                                break;
                            }
                            if (idx < 0) {
                                // No slot holds this pawn, so take one that is free.
                                // Free means unclaimed and unowned, not empty: a
                                // pre-spawned label has an object and no key, and
                                // skipping anything with an object meant the six
                                // labels made at overlay start were never used.
                                // The pool stayed at zero, every pawn went through
                                // the make-one-per-frame path, and every one of
                                // those frames cost eight hundred milliseconds.
                                // [SB-LABEL] pre-spawned pool=6 of 6 was printed and
                                // then made=0 on every publish, which is the whole
                                // thing in two lines of the log.
                                for (int k = 0; k < SB_LABEL_MAX; k++) {
                                    if (g_sbLabelClaimed[k]) continue;
                                    if (g_sbLabelKey[k] != 0) continue;
                                    idx = k;
                                    break;
                                }
                                if (idx >= 0 && !r_is_objc_ptr(g_sbLabelObj[idx]) &&
                                    sb_labelsMadeThisFrame >= 1) {
                                    // Nothing pre-spawned was free and this frame
                                    // has already made one, so leave it for the
                                    // next frame rather than stalling this one.
                                    idx = -1;
                                }
                                if (idx >= 0 && !r_is_objc_ptr(g_sbLabelObj[idx])) {
                                    g_sbLabelObj[idx] = sb_make_pooled_label(g_sbCanvas, role, idx);
                                    sb_labelsMadeThisFrame++;
                                    if (!r_is_objc_ptr(g_sbLabelObj[idx])) idx = -1;
                                }
                            }
                            if (idx >= 0) {
                                g_sbLabelClaimed[idx] = 1;
                                g_sbLabelKey[idx] = lkey;
                                g_sbLabelClaimedCount++;
                                if (idx >= txtSlot) txtSlot = idx + 1;
                                calls += sb_pooled_label_update(idx, role, tpx, tpy, tw, th, txt);
                            }
                        }
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
                    // A rectangle is accepted when the four points are the four
                    // distinct corners of the bounding box.
                    //
                    // The previous test also required run[0] equal run[6], that
                    // is, the first and last point of the subpath to be the same
                    // point. CGPathAddRect does not emit that. It emits moveTo
                    // (x,y), lineTo (x+w,y), lineTo (x+w,y+h), lineTo (x,y+h) and
                    // then a closeSubpath element, and serFunc drops closeSubpath
                    // because it carries no point. So the last point is (x,y+h)
                    // and the check was false for every rectangle more than half
                    // a pixel tall.
                    //
                    // That silently did two things. The shape fell through to the
                    // generic polyline branch, where CGPathAddLines draws an open
                    // three segment path, so the left edge was never stroked and a
                    // box was not a box. And it missed the CGPathAddRects batch
                    // entirely, so every box and every health bar cost a remote
                    // call of its own instead of being batched.
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
                    if (w > 0.5 && h > 0.5) {
                        int c00 = 0, c01 = 0, c11 = 0, c10 = 0;
                        for (int k = 0; k < 4; k++) {
                            const double px = run[k*2], py = run[k*2+1];
                            const int lo  = fabs(px - minX) <= 0.5;
                            const int hi  = fabs(px - maxX) <= 0.5;
                            const int loY = fabs(py - minY) <= 0.5;
                            const int hiY = fabs(py - maxY) <= 0.5;
                            if (lo && loY) c00++;
                            else if (hi && loY) c01++;
                            else if (hi && hiY) c11++;
                            else if (lo && hiY) c10++;
                        }
                        if (c00 == 1 && c01 == 1 && c11 == 1 && c10 == 1) {
                            isRect = 1;
                            rx = minX; ry = minY; rw = w; rh = h;
                        }
                    }
                } else if (np == 2) {
                    // A lone segment. It used to be flattened into a two pixel
                    // thick rectangle whenever it was axis aligned, on the
                    // theory that a snapline is a rectangle in disguise so it
                    // could join the CGPathAddRects batch. That theory is wrong
                    // in the space the decoder actually works in.
                    //
                    // serFunc rotates every point by ninety degrees, so in the
                    // decoder's coordinates the snapline runs from
                    // (landH - 45, landW/2) to (landH - boxY, centerX). Its
                    // vertical extent is centerX - landW/2, which goes to zero
                    // precisely when the target is at the horizontal centre of
                    // the screen. A player being looked at is at the centre. So
                    // the snapline for the player under the crosshair is the one
                    // that gets caught, because its dy drops below half a pixel
                    // and it is rebuilt as a wide flat bar instead of a line.
                    //
                    // The device log confirms it. One player measures pts2=14,
                    // which is thirteen bone segments plus one snapline, and
                    // limb=13, so the snapline is not being counted as a limb;
                    // limbCount only counts non axis aligned segments. The
                    // remaining one was converted, and rect=3 accounts for it as
                    // the box, the health bar, and the squashed snapline.
                    //
                    // It is also why the count changed with the camera. Off
                    // centre, dy is large, the segment is drawn as the slanted
                    // line it is, and the player shows one line. On centre it
                    // becomes a bar, and the player shows the bar plus the
                    // neighbouring line.
                    //
                    // Two point subpaths are never rectangles. They are now
                    // always drawn as segments. This costs one remote call per
                    // player per frame, which the rectangle batching from b2cf77e2
                    // more than pays for.
                    {
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
                            SB_GEOM_LINES(2);
                            calls++; drawn++;
                        }
#if SB_DRAW_BONES
                        else if (curLayer >= 3 && curLayer <= 5) {
                            remote_write(ptsBuf, run, (size_t)rn * 8);
                            SB_GEOM_LINES(2);
                            calls++; drawn++;
                        }
#endif
                    }
                }

                if (isRect) {
                    if (rectDoubles + 4 > (int)(sizeof(rectBuf)/sizeof(rectBuf[0]))) {
                        remote_write(ptsBuf, rectBuf, (size_t)rectDoubles * 8);
                        SB_GEOM_RECTS(rp, rectDoubles / 4);
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
                SB_GEOM_LINES(np);
                calls++; drawn++;
            }

            if (rectDoubles >= 4) {
                remote_write(ptsBuf, rectBuf, (size_t)rectDoubles * 8);
                SB_GEOM_RECTS(rp, rectDoubles / 4);
                calls++; drawn++;
            }
            // End of geom. The loop above is every CGPathAddLines and every
            // mid-loop CGPathAddRects, so this group is the one that scales
            // with the number of things on screen.
            const uint64_t tLabelStart = now_us();

            // Remember whether the last frame drew anything on the fill layer.
            //
            // A layer that is not given a new path keeps drawing the one it has.
            // A card that has left the screen therefore stays on screen until
            // some other card happens to be published over it, and the layer
            // itself, sized to the window, is what the user saw flash across the
            // screen. Presenting the empty path every frame is one extra call and
            // is the only way to clear it.
            const int fillWasDrawn = g_sbFillWasDrawn;
            g_sbFillWasDrawn = 0;

            // Hide the labels this frame did not use, and hand their keys back.
            //
            // Outside the block above on purpose. That block only runs when
            // something was drawn, so a frame that drew nothing skipped the hide
            // entirely and left a name on screen with nothing to move it. The log
            // caught it directly: a frame reporting shown=1 with claimed=0, that
            // is, a label nobody was using and nothing hid it.
            //
            // A slot being unclaimed is the definition of free. An unclaimed slot
            // that keeps its key is also a pool that only shrinks, one dead pawn
            // at a time.
            for (int hi = 0; hi < g_sbLabelHigh; hi++) {
                if (g_sbLabelClaimed[hi]) continue;
                if (g_sbLabelShown[hi] && r_is_objc_ptr(g_sbLabelObj[hi])) {
                    g_sbLabelShown[hi] = 0;
                    if (sb_cached_invocation(g_sbLabelObj[hi], "setHidden:",
                                             &g_sbLabelHideInv[hi], &g_sbLabelHideBuf[hi], 8)) {
                        remote_write64(g_sbLabelHideBuf[hi], 1);
                        r_msg2(g_sbLabelHideInv[hi], "setArgument:atIndex:", g_sbLabelHideBuf[hi], 2, 0, 0);
                        r_msg(g_sbLabelHideInv[hi], g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
                    }
                    calls += 1;
                }
                g_sbLabelKey[hi] = 0;
            }
            if (txtSlot > g_sbLabelHigh) g_sbLabelHigh = txtSlot;
            // End of label.
            const uint64_t tFlushStart = now_us();

            if (fillN > 0 && fillPath) {
                remote_write(ptsBuf, fillDoubles, (size_t)fillN * 32);
                SB_GEOM_RECTS(fillPath, fillN);
                calls++;
                fillDrawn++;
                fillN = 0;
            }
            // End of flush. The group boundary here is after the fill batch, so
            // the card present and the stroke present below are not in it: the
            // stroke present is g_sbLastWaitUS and the card present is one
            // r_msg2 that always runs. Both are counted in total, neither is
            // double counted here.

            if (drawn > 0 || txtOps > 0 || fillDrawn > 0 || fillWasDrawn) {
                // No text run this frame means the app is not in a match, and a
                // stale count left on screen is worse than no count.
                if (txtOps == 0) calls += sb_count_label_hide(1);
                // Present the cards. Its own cached invocation, for the same
                // reason the stroke layer has one: r_msg_main_raw rebuilds an
                // invocation per call and waits for the main thread.
                if ((fillDrawn > 0 || fillWasDrawn) && r_is_objc_ptr(g_sbFillShape)) {
                    g_sbFillWasDrawn = fillDrawn > 0;
                    if (!r_is_objc_ptr(g_sbFillInv) && g_sbPerformMainSel && g_sbInvokeSel) {
                        uint64_t setPathSel = r_sel("setPath:");
                        uint64_t sig = r_msg(g_sbFillShape, r_sel("methodSignatureForSelector:"), setPathSel, 0, 0, 0);
                        uint64_t NSInvocation = r_class("NSInvocation");
                        if (r_is_objc_ptr(sig) && r_is_objc_ptr(NSInvocation)) {
                            uint64_t inv = r_msg(NSInvocation, r_sel("invocationWithMethodSignature:"), sig, 0, 0, 0);
                            if (r_is_objc_ptr(inv)) {
                                r_msg2(inv, "retain", 0, 0, 0, 0);
                                r_msg2(inv, "setTarget:", g_sbFillShape, 0, 0, 0);
                                r_msg2(inv, "setSelector:", setPathSel, 0, 0, 0);
                                uint64_t ab = sb_remote_malloc(8);
                                if (ab) {
                                    r_msg2(inv, "setArgument:atIndex:", ab, 2, 0, 0);
                                    g_sbFillInv = inv;
                                    g_sbFillArgBuf = ab;
                                } else {
                                    r_msg2(inv, "release", 0, 0, 0, 0);
                                }
                            }
                        }
                    }
                    if (r_is_objc_ptr(g_sbFillInv) && g_sbFillArgBuf) {
                        remote_write64(g_sbFillArgBuf, fillPath);
                        r_msg2(g_sbFillInv, "setArgument:atIndex:", g_sbFillArgBuf, 2, 0, 0);
                        r_msg(g_sbFillInv, g_sbPerformMainSel, g_sbInvokeSel, 0, 0, 0);
                        calls += 2;
                    }
                }
                sb_invoke_cached_main_raw();
                g_sbSummaryUpdates++;
                const uint64_t tPubEnd = now_us();
                g_sbLastPublishUS = tPubEnd;
                g_sbRearmBackoffUS = 5000000ULL;   // healthy again, reset backoff
                g_sbLastSubpaths = subpaths;
                g_sbLastCalls = calls;
                // [SB-CALL] which of the five groups ate this publish.
                //
                // Only the first few publishes and any publish over 100 ms. The
                // device log measured 671 ms over 17 calls at session start and
                // 16 ms over 12 calls once warm, so the question is which group
                // has the 22x. Logging every frame would bury the answer in the
                // frames that are already known to be cheap.
                {
                    g_sbPubIndex++;
                    const uint64_t total = tPubEnd - tPubStart;
                    if (g_sbPubIndex <= SB_CALL_FIRST_N || total > SB_CALL_SLOW_US) {
                        g_sbTProbe = tProbeEnd - tProbeStart;
                        g_sbTPathNew = tGeomStart - tPathNewStart;
                        g_sbTGeom = tLabelStart - tGeomStart;
                        g_sbTLabel = tFlushStart - tLabelStart;
                        g_sbTFlush = tFlushStart ? (tPubEnd - tFlushStart) : 0;
                        // The sum of the five plus the present should account for
                        // the whole publish. rest is the difference, and it is
                        // the card present and the bookkeeping in between. A rest
                        // that is large is itself a finding: it means time is
                        // being spent somewhere this split does not name.
                        const uint64_t named = g_sbTProbe + g_sbTPathNew + g_sbTGeom
                                             + g_sbTLabel + g_sbTFlush
                                             + g_sbLastWaitUS;
                        NSLog(@"[SB-CALL] pub=%llu total=%lluus probe=%lluus "
                              @"pathnew=%lluus geom=%lluus label=%lluus flush=%lluus "
                              @"present=%lluus rest=%lluus calls=%llu",
                              (unsigned long long)g_sbPubIndex,
                              (unsigned long long)total,
                              (unsigned long long)g_sbTProbe,
                              (unsigned long long)g_sbTPathNew,
                              (unsigned long long)g_sbTGeom,
                              (unsigned long long)g_sbTLabel,
                              (unsigned long long)g_sbTFlush,
                              (unsigned long long)g_sbLastWaitUS,
                              (unsigned long long)(total > named ? total - named : 0),
                              (unsigned long long)calls);
                        // [SB-NP] the per call breakdown of geom, so "one call
                        // is expensive" can be separated from "one call with
                        // many points is expensive". kind 0 is CGPathAddLines
                        // and 1 is CGPathAddRects; arg is the point count or
                        // the rectangle count.
                        //
                        // Only on a slow publish, and only the calls that
                        // actually cost something: a whole frame of 23 records
                        // is 23 lines, and the cheap ones answer nothing.
                        for (int i = 0; i < g_sbNpCount; i++) {
                            if (g_sbNpUS[i] < 1000ULL) continue;   // under 1 ms
                            NSLog(@"[SB-NP] pub=%llu i=%d kind=%d arg=%u us=%llu "
                                  @"bytes=%llu",
                                  (unsigned long long)g_sbPubIndex, i,
                                  (int)g_sbNpKind[i],
                                  (unsigned int)g_sbNpArg[i],
                                  (unsigned long long)g_sbNpUS[i],
                                  (unsigned long long)((g_sbNpKind[i] == 0
                                      ? (uint64_t)g_sbNpArg[i] * 16ULL
                                      : (uint64_t)g_sbNpArg[i] * 32ULL)));
                        }
                    }
                }
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
                        // tid is the thread that actually runs the publish. The
                        // 21:08:39 stackshot shows two SpringBoard threads
                        // turnstile-blocked on the app task; without this the
                        // publish log cannot be tied to either of them.
                        const uint32_t sbPubTid =
                            (uint32_t)pthread_mach_thread_np(pthread_self());
                        NSLog(@"[SB-PUSH] tid=%u sub=%u rect=%u limb=%u calls=%llu ms=%llu "
                              @"maxPts=%d nBig=%d r0=%.1f,%.1f,%.1f,%.1f ups=%llu "
                              @"bdrops=%llu hold=%llums pts2=%d pts3=%d pts4=%d "
                              @"pts58=%d pts932=%d pts33=%d hash=%u upd=%llu att=%llu skip=%llu "
                              @"mergedSub=%u trunc=%u txt=%u cards=%u cardOps=%u "
                              @"wait=%llums work=%llums",
                              sbPubTid,
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
                              g_sbSubpathCount, nTrunc, txtOps, fillDrawn, cardOps,
                              (unsigned long long)(g_sbLastWaitUS / 1000ULL),
                              (unsigned long long)(pubMS - g_sbLastWaitUS / 1000ULL));
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
        // The hold ring still holds paths handed to a queued setPath: that the
        // main thread has not run yet, so they are freed with the session rather
        // than left for the next one to overwrite the slots of.
        for (int k = 0; k < SB_PATH_HOLD_FRAMES; k++) {
            if (g_sbPathRing[k] && g_sbPathRing[k] != g_sbPersistentPath) {
                dlsym_remote("CGPathRelease", g_sbPathRing[k], 0,0,0,0,0,0,0);
            }
            g_sbPathRing[k] = 0;
        }
        g_sbPathRingAt = 0;
        sb_forget_local_paint_state();
        destroy_remote_call();
    } else {
        sb_forget_local_paint_state();
    }
}
