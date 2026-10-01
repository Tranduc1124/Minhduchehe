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
#import "ESPPrefs.h"
#import <CoreText/CoreText.h>
#import "../../kexploit/kexploit_opa334.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
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

// Startup diagnostics.
//
// Three measurement blocks still run on the way to the first painted frame, and
// between them they cost roughly a hundred and fifteen remote calls: the cost
// probe alone is about ninety, plus two thousand local dlsym lookups and an 8ms
// sleep. They are measurements, not work. The cost probe prints [SB-PROBE], the
// colour probe prints [SB-COLOR] with the components that arrived, and the
// lineWidth read-back proves the stroke call carried its argument. All three
// answered their questions and the answers are written down beside them.
//
// Off by default, which is the only place this kind of thing should ever end up:
// a diagnostic that delays the first frame is a cost with no benefit, and the
// person who needs to re-measure can turn it on and read the same three lines.
#define SB_STARTUP_DIAGNOSTICS 0

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

// Text in SpringBoard, as a fixed pool of CATextLayers.
//
// CATextLayer and not UILabel: the overlay already builds CAShapeLayer this way
// and adds it to a container's layer, a label is a view and would need a
// window of its own, and CATextLayer is what the app side already uses for every
// string it draws, so one mirror routine serves all of them.
//
// A pool rather than one label because the per player text is the obvious next
// thing to want and the mechanism should not have to be rebuilt for it. Slots
// are handed out by index, a layer is built the first time its slot is used, and
// a slot whose string has not changed costs nothing. See sb_text_sync.
#define SB_TEXT_SLOTS 24

// The count, at the top of the screen. The only slot wired up so far: it is the
// one string that changes slowly enough to be affordable.
#define SB_TEXT_SLOT_COUNT 0

typedef struct {
    uint64_t layer;        // CATextLayer in the target, 0 until the slot is used
    uint64_t color;        // CGColor in the target, 0 until one is needed
    float    r, g, b, a;   // components of that colour, -1 until then
    char     last[40];     // what the target is already showing
    int      hidden;
} SbTextSlot;

static SbTextSlot g_sbText[SB_TEXT_SLOTS];

// The counter, drawn as a filled path on a layer of its own.
//
// It was a CATextLayer, and that was the wrong tool. A CATextLayer's string
// setter makes SpringBoard's main thread run CoreText layout and then rasterise
// glyphs at contentsScale 3, and the overlay's calls are
// performSelectorOnMainThread:withObject:waitUntilDone:YES, so every call after it
// queues behind that work. The device log put a number on it: 8 geometry calls
// cost 6 to 12ms, so a crossing is about 1ms, while one counter change cost 391 to
// 822ms, so a change was costing tens of milliseconds per call. The publishes that
// followed a change ran ms=391, 507, 703 and 822 against 6 to 12 for the rest, ups
// fell from 50 a second to 4, and bdrops climbed to 51. One digit cost the ESP
// half a second.
//
// A path has no layout. The main thread is handed geometry and fills it, and the
// glyph outlines are computed here, in this process, where CoreText is free.
//
// This is the second layer in SpringBoard and it is the first thing drawn other
// than the geometry, which is not the same claim as the FOV split that died in
// 75747c3c4: that added a layer, a path, a point buffer, an NSInvocation and a
// string all at once, on a session whose every remote operation can clear
// g_RC_success. This adds a layer, a path and one setPath, all of them lazy, and
// nothing it does can reach g_sbShape: a failure here leaves the geometry exactly
// as it was and the counter simply does not appear.
static uint64_t g_sbTextShape = 0;      // the CAShapeLayer, filled, in the target
static uint64_t g_sbTextPath  = 0;      // its CGMutablePath, in the target
static uint64_t g_sbTextFill  = 0;      // its CGColor, in the target
// The built outline and what it was built from. Both in this process, so there is
// no remote state to lose on a rearm.
static CGPathRef g_sbTextGlyphPath = NULL;
static char      g_sbTextGlyphFor[40];
static double    g_sbTextGlyphSize = 0;
// Set when the glyphs were rebuilt, so the publish knows the target's path is
// stale and has to be replaced. Read and cleared by the publish thread.
static int       g_sbTextPathDirty = 0;
#define SB_TEXT_GLYPH_MAX 40
// The index kShapeKeys does not have. The sixteen CAShapeLayers are the
// geometry's; this one is ours, and it is written into the same op stream after
// them so the decoder's existing marker carries it with no new framing.
#define SB_TEXT_LAYER_INDEX 16

// kCAAlignCenter, built once in the target and shared by every slot.
static uint64_t g_sbAlignStr = 0;
// How often the app's text is read. The counter's string changes about once a
// second, so twice a second is a hard ceiling rather than a target.
//
// The ceiling matters more than the rate. Every change costs about eleven
// process crossings and they run inside the publish that is drawing the boxes,
// because the transport is not safe to drive from two threads at once. So the
// number of text changes per second is the number of times the ESP can be held
// up, and this puts a bound on it no matter what the count does. The count has
// hysteresis of its own, which should keep it near one change a second; this is
// what stops a bad frame from turning into forty.
// A floor between two wakeups, not a gate on reading.
//
// It was 500ms and it wrapped the whole staging block, the semaphore signal
// included, so a change of the count waited on average a quarter of a second
// before anything downstream was even told. Added to the 85ms of hysteresis in the
// app and the retry while a publish holds the transport, that is about a second,
// which is what the device showed: the number fell a second after a kill.
//
// A signal that waits on a timer is not a ceiling, it is a delay. The floor is on
// the wakeup now. Reading is a KVC lookup and a string compare in this process,
// nothing next to the forty preferences the frame already reads, so there was never
// a reason to skip it, and doing it every frame is what makes the number track the
// screen instead of trailing it.
//
// 60ms is sixteen wakeups a second, which bounds the pathological case where the
// count genuinely changes every frame, and is far below anything a person sees.
#define SB_TEXT_SIGNAL_MIN_US 60000ULL
static uint64_t g_sbNextSignalUS = 0;

// Ownership of the transport.
//
// One session, one queue, one set of argument buffers, so two threads must
// never be inside it at once. The geometry publish takes this lock and holds it
// for the whole publish. The text thread takes it with trylock only and gives up
// if a publish is running.
//
// That asymmetry is the whole point. The ESP never waits for the counter, and
// the counter waits for the ESP. Sharing one thread could only ever have been
// the other way round, and that is what made the boxes stutter at the counter's
// rhythm: the counter's eleven process crossings sat inside the publish that was
// drawing them.
static pthread_mutex_t g_sbIoLock = PTHREAD_MUTEX_INITIALIZER;

// The hand-off from the app's thread, which is the only thread allowed to read
// the app's CATextLayer, to the text thread.
//
// A two slot sequence with a mutex rather than atomics because the payload is an
// NSString, and a block captured under ARC does not retain an object pointer
// inside it, so a bare pointer hand-off would be reading a possibly stale
// reference. The lock is held for a handful of assignments and is not the
// transport lock; it never waits on anything.
typedef struct {
    NSString *text;
    double    col[4];
    CGRect    frame;
    CGFloat   fontSize;
    int       on;
    int       changed;
} SbTextReq;

static SbTextReq       g_sbTextReq[2];
static int             g_sbTextSeq = 0;
static pthread_mutex_t g_sbTextHandoff = PTHREAD_MUTEX_INITIALIZER;
static pthread_t       g_sbTextThread = 0;
// Woken by the app's thread when it has something new to send.
//
// Polling was the first version and it was wrong in a way the device showed
// plainly: the counter appeared a beat after the geometry at the start of a
// match, and flipping a switch felt slow. Both are the same 250ms sleep, and
// both are the time between wanting to send and being awake to send. The
// semaphore removes that wait. The thread sleeps until it is signalled, and the
// timeout is only there so that a request staged before the semaphore existed
// is not lost.
static dispatch_semaphore_t g_sbTextWake = NULL;
// The last string staged, on the app's thread only, so the semaphore is posted
// when the value differs rather than on every frame.
static NSString *g_sbTextStaged = nil;
// The app view's bounds, so the text thread can do the landscape to portrait
// conversion without touching the view. Written by the app's thread while it
// stages a request, read by the text thread, and it only ever changes when the
// device rotates, so a stale read costs one frame of a wrong landH.
//
// Spelled out rather than CGRectZero. CGRectZero is not a compile time constant
// in every SDK, and a static initialiser has to be one: the 18.6 SDK that the
// build workflow uses rejects it, while the 17.5 SDK on this machine accepts it.
// The literal is a constant in both.
static CGRect g_sbTextStageBounds = { { 0.0, 0.0 }, { 0.0, 0.0 } };
// Defined next to SBRemotePushESPFrame, which is where the text belongs, and
// called from SBoardStartOverlay, which is above it.
static void sb_text_thread_start(void);

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

// Builds an NSString inside SpringBoard.
//
// +stringWithUTF8String: rather than the alloc and init pair that
// r_nsstr_retained does, for two reasons. The class method autoreleases, so
// there is nothing to leak, and r_nsstr_retained's pair is a +1 retain that
// nothing ever balances. And it is one call instead of two. The cost either way
// is r_alloc_str, which is a malloc, a remote_writeStr and a verification read.
// The text layer's path in the target. Its own CGMutablePath, not the geometry's:
// the counter is filled and the geometry is stroked, and a CAShapeLayer has one
// fill colour, so they cannot share a path without the counter becoming an
// outline or the boxes becoming solid.
//
// Placed here rather than beside the declaration, because it calls dlsym_remote
// and that is defined further down the file.
static uint64_t sb_text_path(void) {
    if (g_sbTextPath) return g_sbTextPath;
    g_sbTextPath = dlsym_remote("CGPathCreateMutable", 0,0,0,0,0,0,0,0);
    return g_sbTextPath;
}

static uint64_t sb_text_make_nsstring(const char *cstr) {
    uint64_t cls = r_class("NSString");
    uint64_t buf = r_alloc_str(cstr);
    if (!r_is_objc_ptr(cls) || !buf) { if (buf) r_free(buf); return 0; }
    uint64_t s = r_msg2_main(cls, "stringWithUTF8String:", buf, 0,0,0);
    r_free(buf);
    return s;
}

static int sb_text_push_string(uint64_t tl, const char *cstr) {
    if (!cstr) return 0;
    uint64_t s = sb_text_make_nsstring(cstr);
    if (!r_is_objc_ptr(s)) return 0;
    r_msg2_main(tl, "setString:", s, 0,0,0);
    return 1;
}

// Creates a colour in SpringBoard, but only when it has actually changed. The
// counter is one of a small number of flat colours, so after the first few
// changes this costs nothing at all.
//
// The components arrive as four doubles rather than a CGColorRef because the
// colour is read on the app's thread and sent across. A CGColorRef captured
// into a block is not retained under ARC, so between the read and the send the
// app's layer could have replaced it and the pointer would be stale. Four
// doubles cannot go stale.
static void sb_text_ensure_color(SbTextSlot *sl, uint64_t tl,
                                double cr, double cg, double cb, double ca) {
    const float r = (float)cr, g = (float)cg, b = (float)cb, a = (float)ca;
    if (sl->color && fabsf(r - sl->r) < 0.004f && fabsf(g - sl->g) < 0.004f &&
        fabsf(b - sl->b) < 0.004f && fabsf(a - sl->a) < 0.004f) return;
    uint64_t cls = r_class("UIColor");
    if (!r_is_objc_ptr(cls)) return;
    double v[4] = { r, g, b, a };
    uint64_t cObj = r_msg2_main_raw(cls, "colorWithRed:green:blue:alpha:",
                                    &v[0], 8, &v[1], 8, &v[2], 8, &v[3], 8);
    uint64_t cCG = r_is_objc_ptr(cObj) ? r_msg2_main(cObj, "CGColor", 0,0,0,0) : 0;
    if (!r_is_objc_ptr(cCG)) return;
    sl->color = cCG; sl->r = r; sl->g = g; sl->b = b; sl->a = a;
    r_msg2_main(tl, "setForegroundColor:", cCG, 0,0,0);
}

// Places the label so that, after the quarter turn, its glyphs occupy exactly
// the portrait rectangle the app's frame maps to.
//
// The arithmetic is written out because getting it wrong is invisible from the
// screen, and the first version of it was wrong.
//
// sbEmit sends landscape (sx, sy) to portrait (landH - sy, sx), so a frame of
// (x, y, w, h) has its corners at
//
//   (x,     y    ) -> (landH - y,     x    )
//   (x + w, y + h) -> (landH - y - h, x + w)
//
// which is the portrait rect x in [landH - y - h, landH - y], y in [x, x + w].
// The two ends of the x range differ by h because the rotation swaps the axes:
// the frame's height is what the portrait rect measures across.
//
// A quarter turn maps the layer's local (u, v) to portrait (-v, u) about the
// anchor, so with the anchor at the top left and bounds (0, 0, w, h) the drawn
// extent at position P is
//
//   x in [P.x - h, P.x]      y in [P.y, P.y + w]
//
// Matching the two ranges gives P.x = landH - y and P.y = x. That is the whole
// formula. The first version added h to P.x, which asked for one frame height
// too much: with the real numbers (x=312, y=25, h=29, landH=390) it wanted
// P.x = 394 instead of 365, so the band covered portrait x in [365, 394] on a
// screen 390 wide. Nine points hung off the edge and the rest of it sat under
// the game's own top HUD, which is why the count was in the wrong place and not
// visible at the same time.
//
// Both rotations have determinant +1, so the glyphs are not mirrored. The
// baseline runs the way the player's does, because landscape +x is portrait +y,
// and the text's up is portrait +x, which is landscape up.
static void sb_text_place(uint64_t tl, const CGRect *appFrame, double landH) {
    const double w = appFrame->size.width, h = appFrame->size.height;
    double bnd[4] = { 0.0, 0.0, w, h };
    r_msg2_main_raw(tl, "setBounds:", bnd, 32, NULL,0,NULL,0,NULL,0);
    double pos[2] = { landH - appFrame->origin.y, appFrame->origin.x };
    r_msg2_main_raw(tl, "setPosition:", pos, 16, NULL,0,NULL,0,NULL,0);
    double t[6] = { 0.0, 1.0, -1.0, 0.0, 0.0, 0.0 };   // +90 degrees
    r_msg2_main_raw(tl, "setAffineTransform:", t, 48, NULL,0,NULL,0,NULL,0);
    NSLog(@"[SB-TEXT] place app=%.0f,%.0f,%.0f,%.0f pos=%.0f,%.0f -> portrait x %.0f..%.0f y %.0f..%.0f (landH=%.0f)",
          appFrame->origin.x, appFrame->origin.y, w, h, pos[0], pos[1],
          pos[0] - h, pos[0], pos[1], pos[1] + w, landH);
}

// Drops every text slot. The layers, the colours and the alignment string are
// all objects inside the target, and the strings the slots remember describe a
// session that is going away. They are dropped, not released: the target's
// allocator and its autorelease pool are not ours to drive from a teardown.
static void sb_text_forget(void) {
    for (int i = 0; i < SB_TEXT_SLOTS; i++) {
        g_sbText[i].layer = 0;
        g_sbText[i].color = 0;
        g_sbText[i].r = g_sbText[i].g = g_sbText[i].b = g_sbText[i].a = -1;
        g_sbText[i].last[0] = 0;
        g_sbText[i].hidden = 1;
    }
    g_sbAlignStr = 0;
}

// Mirrors one CATextLayer from the app into a CATextLayer in SpringBoard.
//
// Slots are fixed and a layer is built the first time its slot is used, so the
// cost of a label that has not changed is zero: the string is compared and the
// function returns. That comparison is the entire design. A name label that
// changes every frame would cost about seven calls every frame, and twenty of
// them would be thousands of calls a second, which is why the pool alone is not
// enough for the per player text and the update rate has to come down too.
//
// The caller supplies the text, the colour components, the frame and the size
// rather than this reading the app's layer. That is not tidiness, it is a race:
// the app writes statusLayer.string on its own thread, and a background thread
// reading it mid write is a torn read waiting to happen. The existing code draws
// the same line by copying the serialised bytes on the calling thread and only
// decoding them on the publish thread, and the text is read the same way.
// Turns CoreAnimation's implicit animation off for one update.
//
// The geometry layer gets a clean repaint because sb_disable_layer_actions
// nulls "path" in its actions dictionary. A CATextLayer also animates bounds
// and position by default, and this label's frame moves every time the string or
// the font size changes, so without this the glyphs ease from the old frame to
// the new one instead of jumping. That is the flicker that was reported, and it
// was not the string changing: the number was changing and each change was being
// animated.
//
// A transaction is three calls and it covers string and hidden as well, where an
// actions dictionary needs three keys at about seven calls each to set up. It
// also replaces the trick of setting the string before addSublayer:, because the
// fade on a newly added sublayer is itself a transaction and this turns those
// off too.
// The glyph outline for a string, as a filled path, built in this process.
//
// Built here, in the app's own process, where CoreText is free. That is the whole
// point: the same characters in a CATextLayer on the far side of the process
// boundary make SpringBoard's main thread lay them out and rasterise them, and the
// device log put that at 391 to 822ms for a two digit number.
//
// CTFontCreatePathForGlyph and not CTLineCreatePath. The latter is a macOS API and
// is not in the iOS SDK at all, so the outline is assembled a glyph at a time and
// the advances are added by hand. CTFontGetGlyphsForCharacters supplies the glyph
// indices and CTFontGetAdvancesForGlyph supplies the widths, which is the same
// arithmetic CTLine would have done.
//
// The result is positioned the way CATextLayer had been positioning it inside the
// app's own frame, centred horizontally, so the counter does not move on screen
// when this replaces it.
static CGPathRef sb_text_glyphs(const char *utf8, CGFloat size, CGRect frame) {
    if (!utf8 || !*utf8) return NULL;
    NSString *s = [NSString stringWithUTF8String:utf8];
    if (!s.length) return NULL;

    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), size, NULL);
    if (!font) return NULL;

    // UTF-8 to unichar. Surrogate pairs are not handled: the counter is digits
    // and a dash, and a name would need a proper decoder rather than a second
    // guess at one.
    UniChar ch[64];
    CFIndex n = 0;
    for (const unsigned char *p = (const unsigned char *)utf8; *p && n < 64; ) {
        unsigned int cp;
        if (*p < 0x80)                { cp = *p++; }
        else if ((*p & 0xE0) == 0xC0) { cp = (*p++ & 0x1F) << 6; cp |= (*p++ & 0x3F); }
        else if ((*p & 0xF0) == 0xE0) { cp = (*p++ & 0x0F) << 12;
                                         cp |= (*p++ & 0x3F) << 6; cp |= (*p++ & 0x3F); }
        else                          { cp = 0xFFFD; p++; }
        if (cp > 0xFFFF) { cp = 0xFFFD; }
        ch[n++] = (UniChar)cp;
    }
    if (n == 0) { CFRelease(font); return NULL; }

    CGGlyph glyphs[64];
    CGSize advances[64];
    if (!CTFontGetGlyphsForCharacters(font, ch, glyphs, n)) { CFRelease(font); return NULL; }

    // Count last, after the arrays, and the orientation second. Read out of
    // CTFont.h rather than assumed: the obvious order is not this one, and the
    // compiler caught the guess twice. It also returns the summed advance, so
    // there is no second pass to measure the width with.
    const double totalW = CTFontGetAdvancesForGlyphs(
            font, kCTFontOrientationHorizontal, glyphs, advances, n);
    if (totalW <= 0.0) { CFRelease(font); return NULL; }

    // CATextLayer centred the string in the frame, so the first glyph starts half
    // the shortfall in, and the baseline sits where the frame's vertical middle
    // puts it.
    const double descent = CTFontGetDescent(font);
    const double ascent  = CTFontGetAscent(font);
    const double dx = frame.origin.x + (frame.size.width - totalW) * 0.5;
    const double dy = frame.origin.y + (frame.size.height + ascent + descent) * 0.5 - descent;

    CGMutablePathRef out = CGPathCreateMutable();
    double penX = dx;
    for (CFIndex i = 0; i < n; i++) {
        if (glyphs[i] != 0) {
            // d = -1, and that is the whole fix for the text reading backwards.
            //
            // CoreText hands back glyph outlines in font space, where y grows
            // upwards from the baseline. Everything else in this file works in the
            // app's space, where y grows downwards: sbEmit's px = landH - sy says
            // so, and the geometry is visibly correct on the device. Placing a
            // font-space path into that space without flipping it puts every glyph
            // the right way up in a coordinate system that runs the other way, so
            // the counter came out mirrored along the baseline.
            //
            // So one scale of -1 on y, then the translation. CGAffineTransformMake
            // builds [a b 0; c d 0; tx ty 1] applied as (u*a + v*c + tx, u*b +
            // v*d + ty), which with c = 0 and d = -1 sends a glyph above the
            // baseline, v positive, to y below the baseline point: above it on a
            // screen.
            CGAffineTransform m = CGAffineTransformMake(1.0, 0.0, 0.0, -1.0, penX, dy);
            CGPathRef g = CTFontCreatePathForGlyph(font, glyphs[i], &m);
            if (g) { CGPathAddPath(out, NULL, g); CGPathRelease(g); }
        }
        penX += advances[i].width;
    }
    CFRelease(font);

    if (CGPathIsEmpty(out)) { CGPathRelease(out); return NULL; }
    return out;
}

static void sb_text_txn_begin(void) {
    uint64_t tx = r_class("CATransaction");
    if (!r_is_objc_ptr(tx)) return;
    r_msg2_main(tx, "begin", 0,0,0,0);
    r_msg2_main(tx, "setDisableActions:", 1, 0,0,0);
}

static void sb_text_txn_end(void) {
    uint64_t tx = r_class("CATransaction");
    if (r_is_objc_ptr(tx)) r_msg2_main(tx, "commit", 0,0,0,0);
}

static void sb_text_send(int slot, NSString *text,
                         double cr, double cg, double cb, double ca,
                         CGRect frame, CGFloat fontSize, double landH) {
    if (slot < 0 || slot >= SB_TEXT_SLOTS) return;
    SbTextSlot *sl = &g_sbText[slot];

    if (!text || text.length == 0) {
        if (r_is_objc_ptr(sl->layer) && !sl->hidden) {
            sb_text_txn_begin();
            r_msg2_main(sl->layer, "setHidden:", 1, 0,0,0);
            sb_text_txn_end();
            sl->hidden = 1;
        }
        return;
    }
    const char *c = text.UTF8String;
    if (!c) return;
    // The common case. Nothing to say and nothing to do.
    if (r_is_objc_ptr(sl->layer) && !sl->hidden && strcmp(c, sl->last) == 0) return;

    if (!r_is_objc_ptr(sl->layer)) {
        uint64_t tl = r_msg2_main(r_class("CATextLayer"), "layer", 0,0,0,0);
        if (!r_is_objc_ptr(tl)) { NSLog(@"[SB-TEXT] +[CATextLayer layer] nil"); return; }
        sl->layer = tl;
        // Anchor at the top left so position and bounds mean what they say. With
        // the default centre anchor a transform turns about the middle and the
        // frame has to be solved backwards, which is where the first attempt at
        // this went wrong.
        double zero[2] = { 0.0, 0.0 };
        r_msg2_main_raw(tl, "setAnchorPoint:", zero, 16, NULL,0,NULL,0,NULL,0);
        // "center", and not "kCAAlignCenter".
        //
        // alignmentMode takes a string, and kCAAlignCenter is the name of the
        // constant whose value is @"center". Passing the constant's name passes
        // a string the target has never heard of, so the setter keeps the
        // default, the default is natural, and natural puts the glyphs against
        // the leading edge of the bounds. That is a left aligned label in a
        // frame built to be centred, which put the count about 45 points left of
        // the middle on the device. There is no warning for it: a CALayer
        // accepts any string here and simply does not recognise it.
        //
        // Built once and shared by every slot. r_nsstr_retained is about six
        // operations and the value never changes.
        if (!r_is_objc_ptr(g_sbAlignStr)) g_sbAlignStr = r_nsstr_retained("center");
        if (r_is_objc_ptr(g_sbAlignStr)) r_msg2_main(tl, "setAlignmentMode:", g_sbAlignStr, 0,0,0);
        // Without this the glyphs rasterise at scale 1 and are scaled up, which
        // on a 3x panel is the difference between readable and a grey smear.
        double cs = (double)[UIScreen mainScreen].scale;
        r_msg2_main_raw(tl, "setContentsScale:", &cs, 8, NULL,0,NULL,0,NULL,0);
        // Above the geometry layer at 100, so text is not drawn through a box.
        double z = 200.0;
        r_msg2_main_raw(tl, "setZPosition:", &z, 8, NULL,0,NULL,0,NULL,0);
        // No font is set. CATextLayer falls back to Helvetica and a real
        // CFTypeRef would need CGFontCreateWithFontName inside the target. The
        // app draws its text in a loaded font, so the two will not match, and
        // matching is worth less than the calls.
        sl->last[0] = 0;
        sl->color = 0; sl->r = sl->g = sl->b = sl->a = -1;
    }

    double fs = (double)fontSize;
    sb_text_txn_begin();
    r_msg2_main_raw(sl->layer, "setFontSize:", &fs, 8, NULL,0,NULL,0,NULL,0);
    sb_text_ensure_color(sl, sl->layer, cr, cg, cb, ca);
    sb_text_place(sl->layer, &frame, landH);
    if (!sb_text_push_string(sl->layer, c)) { sb_text_txn_end(); return; }
    snprintf(sl->last, sizeof(sl->last), "%s", c);
    if (sl->hidden) {
        r_msg2_main(sl->layer, "setHidden:", 0, 0,0,0);
        sl->hidden = 0;
        uint64_t cl = r_msg2_main(g_sbCanvas, "layer", 0,0,0,0);
        // The string is in before the layer joins the hierarchy, so the implicit
        // fade CoreAnimation puts on a newly added sublayer has nothing to fade
        // from. The transaction above covers it as well, and this ordering is
        // kept because it costs nothing.
        if (r_is_objc_ptr(cl)) r_msg2_main(cl, "addSublayer:", sl->layer, 0,0,0);
        sb_text_txn_end();
        NSLog(@"[SB-TEXT] slot %d live \"%s\" size=%.0f canvas=%d", slot, sl->last, fs,
              (int)r_is_objc_ptr(cl));
        return;
    }
    sb_text_txn_end();
    NSLog(@"[SB-TEXT] slot %d set \"%s\" size=%.0f", slot, sl->last, fs);
}

// The counter's outline as it stands, or NULL when it should not be drawn. Cached
// by string and size, so CoreText runs on a change and not on a frame.
static CGPathRef sb_text_glyph_path_for_frame(UIView *espView) {
    if (!g_sbTextShape) return NULL;
    if (!ESPPrefsBool(@"SbCountText", NO)) return NULL;

    id sl = [espView valueForKey:@"statusLayer"];
    if (![sl isKindOfClass:[CATextLayer class]]) return NULL;
    CATextLayer *src = (CATextLayer *)sl;
    NSString *want = (NSString *)src.string;
    if (!want.length || src.hidden) return NULL;
    const char *c = want.UTF8String;
    if (!c || !*c) return NULL;

    const CGFloat size = src.fontSize;
    if (g_sbTextGlyphPath && g_sbTextGlyphFor[0] != 0 &&
        strcmp(c, g_sbTextGlyphFor) == 0 && g_sbTextGlyphSize == (double)size) {
        return g_sbTextGlyphPath;
    }
    if (g_sbTextGlyphPath) { CGPathRelease(g_sbTextGlyphPath); g_sbTextGlyphPath = NULL; }
    g_sbTextGlyphFor[0] = 0;
    CGPathRef built = sb_text_glyphs(c, size, src.frame);
    if (!built) return NULL;
    g_sbTextGlyphPath = built;
    snprintf(g_sbTextGlyphFor, sizeof(g_sbTextGlyphFor), "%s", c);
    g_sbTextGlyphSize = (double)size;
    // The target's path now holds the previous string's geometry and there is no
    // way to clear it, so it has to be replaced. Set on the thread that hands the
    // geometry over and cleared by the publish that consumes it.
    g_sbTextPathDirty = 1;
    // The bounding box is the measurement this whole thing is missing.
    //
    // Turning the counter on makes the FOV ring come out as a solid red disc and
    // turning it off makes the FOV come back, so the cause is the text layer
    // being drawn over the geometry rather than a run being misrouted: the point
    // counts in [SB-TEXT] present are 81 to 389, which is one or two glyphs, and
    // the FOV's 73 point run is not among them.
    //
    // What is left is that the glyph path is not the size of a digit. A digit at
    // 25pt inside a 90 by 33 frame has a box about 15 by 20 at the frame's corner.
    // A box anywhere near the size of the screen is a broken transform, and a
    // filled path that big is a red screen. Local arithmetic, no remote call, and
    // it settles the question either way.
    const CGRect bb = CGPathGetBoundingBox(g_sbTextGlyphPath);
    NSLog(@"[SB-TEXT] glyphs \"%s\" size=%.0f frame=%.0f,%.0f,%.0f,%.0f "
          @"bbox=%.1f,%.1f,%.1f,%.1f",
          g_sbTextGlyphFor, size, src.frame.origin.x, src.frame.origin.y,
          src.frame.size.width, src.frame.size.height,
          bb.origin.x, bb.origin.y, bb.size.width, bb.size.height);
    return g_sbTextGlyphPath;
}

// textPath is the counter's outline, or NULL. Passed in rather than fetched, so
// the caller decides when a glyph rebuild happens.
static BOOL mergePaths(UIView *espView, CGPathRef textPath, NSMutableData *d) {
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
    // The counter's glyphs go into the same stream, after the sixteen, with a
    // marker of their own. Not a second stream: the decoder already reads one
    // layer marker per run and already switches on it, so one more index costs a
    // compare and rides the existing framing.
    if (textPath) {
        uint8_t ttag = 4;
        uint8_t tidx = SB_TEXT_LAYER_INDEX;
        [d appendBytes:&ttag length:1];
        [d appendBytes:&tidx length:1];
        CGPathApply(textPath, &ctx, serFunc);
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
    sb_text_forget();
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

#if SB_STARTUP_DIAGNOSTICS
    // [SB-COLOR] proves whether a multi argument selector can carry its
    // arguments at all, before any second shape layer is attempted.
    //
    // The previous six layer attempt drew nothing, and its colour call was
    // written as r_msg2_main_raw(clsCol, "colorWithRed:green:blue:alpha:",
    // rgba, 32, ...), that is one 32 byte pointer. Reading r_msg_main_raw shows
    // why that cannot work. It does not marshal through the x0..x7 injector at
    // all: it asks the real method signature for numberOfArguments, allocates a
    // buffer per argument and calls setArgument:atIndex: once for each. Passing
    // only a0 meant the remaining three arguments were never written, so the
    // selector ran with three uninitialised CGFloats and every group got a
    // colour nobody chose.
    //
    // The right call passes four separate eight byte doubles, which is what this
    // does. The colour is then read back through CGColor and its components
    // printed, so the device says what actually arrived instead of the log
    // claiming success on a call that may have produced anything.
    //
    //   rgba matching the request -> the transport is fine, a second layer for
    //                                fill is safe to build
    //   rgba wrong                 -> the marshalling is still wrong and the
    //                                number printed here says which part
    {
        // Everything is printed under one prefix because the device log filter
        // takes a single term, and splitting this across two prefixes cost a round.
        //
        // What is already established, by the log and not by reasoning:
        //   got=0.00,0.00,0.00,0.00 while col=1 and cg=1
        // col being non zero means r_write_remote_arg returned true, because a
        // false there sets argsOK false and the function returns 0. So the four
        // doubles were written to SpringBoard and read back matching. The read
        // side is sound too, because got starts at minus one and the sentinel
        // never appears. The write is confirmed good and the read is confirmed
        // good, and the value is still zero, so the argument is lost between the
        // buffer and the selector reading it.
        //
        // That leaves one untested step in r_msg_main_raw: maxUserArgs comes
        // from numberOfArguments on the signature, and if that is wrong then no
        // setArgument:atIndex: is ever issued and the selector reads whatever
        // happens to be in d0 to d3. So numArgs is printed here. The expectation
        // for a four argument selector plus self and _cmd is six.
        const uint64_t colSel = r_sel("colorWithRed:green:blue:alpha:");
        uint64_t sig = r_is_objc_ptr(colSel)
                      ? r_msg(clsCol, r_sel("methodSignatureForSelector:"), colSel, 0, 0, 0)
                      : 0;
        uint64_t numArgs = r_is_objc_ptr(sig)
                         ? r_msg2(sig, "numberOfArguments", 0, 0, 0, 0) : 0;

        double want[4] = { 0.0, 1.0, 0.0, 1.0 };   // opaque green, the health bar
        // Probe on for this one call only, so r_msg_main_raw reads the arguments
        // back out of the invocation just before invoking. That is the one step
        // between "the bytes are in the target's buffer", which is proven, and
        // "the selector used them", which is not.
        r_arg_probe_enabled = true;
        uint64_t col = r_msg2_main_raw(clsCol, "colorWithRed:green:blue:alpha:",
                                       &want[0], 8, &want[1], 8,
                                       &want[2], 8, &want[3], 8);
        r_arg_probe_enabled = false;
        double invGot[4] = { 0, 0, 0, 0 };
        for (int i = 0; i < 4 && i < (int)r_arg_probe_n; i++) {
            uint64_t bits = r_arg_probe_got[i];
            memcpy(&invGot[i], &bits, 8);
        }
        uint64_t cg  = r_is_objc_ptr(col) ? r_msg2_main(col, "CGColor", 0,0,0,0) : 0;

        // Number of components the target's colour actually has. A colour made
        // from red, green, blue and alpha is normally four or five depending on
        // whether the space is extended, and the out buffer is sized for that
        // rather than assuming four.
        uint64_t ncomp = 0;
        if (r_is_objc_ptr(cg)) {
            ncomp = dlsym_remote("CGColorGetNumberOfComponents", cg, 0,0,0,0,0,0,0);
        }

        // The out buffer is poisoned with a sentinel before the call. This is the
        // measurement that was missing for four rounds: the buffer came from malloc
        // and was never written to, and a fresh page reads as sixteen zero bytes,
        // which is exactly what was logged. A printed zero in a buffer nobody
        // wrote is not a measurement, and treating it as one is what sent the last
        // three rounds chasing a colour that may never have been black.
        double got[8] = { -1, -1, -1, -1, -1, -1, -1, -1 };
        uint64_t raw[4] = { 0, 0, 0, 0 };
        bool wrote = false;
        if (r_is_objc_ptr(cg) && ncomp >= 1 && ncomp <= 8) {
            uint64_t outBuf = dlsym_remote("malloc", 64, 0,0,0,0,0,0,0);
            if (outBuf) {
                double sentinel[8] = { -7, -7, -7, -7, -7, -7, -7, -7 };
                for (int k = 0; k < 3; k++) {
                    remote_write(outBuf, sentinel, sizeof(sentinel));
                    dlsym_remote("CGColorGetComponents", cg, outBuf, 0,0,0,0,0,0);
                    remote_read(outBuf, got, sizeof(got));
                    remote_read(outBuf, raw, 16);
                    if (got[0] != -7.0) { wrote = true; break; }
                }
                dlsym_remote("free", outBuf, 0,0,0,0,0,0,0);
            }
        }

        // The float layout theory is dead and the raw bytes say so: raw was
        // sixteen zero bytes, so the out buffer really was zero, and both dbl and
        // flt read the same zeros. The colour is black, not misread.
        //
        // The second invocation told us nothing. It returned the value 1, and
        // r_is_objc_ptr accepts any pointer above 0x100000000, so asking address 1
        // for CGColor gave nil and noRet was never measured. That result is dropped
        // rather than reinterpreted, because reading a conclusion out of a garbage
        // pointer is how the last two rounds went wrong.
        //
        // The measurement moves to a channel that returns text.
        // +[NSNumber numberWithDouble:] takes one CGFloat through exactly the same
        // path and hands back an object, and -description on that object prints the
        // number as characters. The colour test spent three rounds proving that a
        // printed zero was a real zero and not a misread layout, and every one of
        // those rounds was spent on the reading rather than on the transport. A
        // string has no such ambiguity: 1.5 and 0.0 are different strings, and no
        // byte layout turns one into the other.
        //
        // The integer case is the control. It travels through identical code with a
        // different register class, so T1 alone says whether the difference is
        // specifically about a floating point value, and T2 alone says whether the
        // path works at all. If T2 prints 7 then arguments arrive and a double is
        // the only thing that does not, which is a far narrower fault to fix than
        // arguments do not arrive.
        char t1[48] = { 0 };
        char t2[48] = { 0 };
        double wantInt = 7.0;
        double wantDbl = 1.5;

        uint64_t NSNum = r_class("NSNumber");
        uint64_t nDbl = r_is_objc_ptr(NSNum)
                      ? r_msg2_main_raw(NSNum, "numberWithDouble:", &wantDbl, 8,
                                        NULL, 0, NULL, 0, NULL, 0) : 0;
        uint64_t nInt = r_is_objc_ptr(NSNum)
                      ? r_msg2_main_raw(NSNum, "numberWithDouble:", &wantInt, 8,
                                        NULL, 0, NULL, 0, NULL, 0) : 0;
        if (r_is_objc_ptr(nDbl)) {
            uint64_t ds = r_msg2_main(nDbl, "description", 0, 0, 0, 0);
            if (r_is_objc_ptr(ds)) r_read_nsstring(ds, t1, sizeof(t1));
        }
        if (r_is_objc_ptr(nInt)) {
            uint64_t is = r_msg2_main(nInt, "description", 0, 0, 0, 0);
            if (r_is_objc_ptr(is)) r_read_nsstring(is, t2, sizeof(t2));
        }

        NSLog(@"[SB-COLOR] numArgs=%llu col=%d cg=%d ncomp=%llu wrote=%d "
              @"want=%.2f,%.2f,%.2f,%.2f inv=%.2f,%.2f,%.2f,%.2f "
              @"ret=%.2f,%.2f,%.2f,%.2f dbl=<%s> int=<%s>",
              (unsigned long long)numArgs,
              (int)r_is_objc_ptr(col), (int)r_is_objc_ptr(cg),
              (unsigned long long)ncomp, (int)wrote,
              want[0], want[1], want[2], want[3],
              invGot[0], invGot[1], invGot[2], invGot[3],
              got[0], got[1], got[2], got[3],
              t1, t2);
    }

#endif

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
    NSLog(@"[SB-COLOR] white=%d cg=%d", (int)r_is_objc_ptr(whiteColor),
          (int)r_is_objc_ptr(whiteCGColor));
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
#if SB_STARTUP_DIAGNOSTICS
    double lwBack = -1.0;
    bool lwOK = r_msg2_main_struct_ret(shape, "lineWidth", &lwBack, 8,
                                       NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    NSLog(@"[SB-COLOR] lw want=%.2f got=%.2f ok=%d", lw, lwBack, (int)lwOK);
#endif
    r_msg2_main(shape, "setOpaque:", 0, 0,0,0);
    double z = 100;
    r_msg2_main_raw(shape, "setZPosition:", &z, 8, NULL,0,NULL,0,NULL,0);
    sb_disable_layer_actions(shape);

    // The counter's layer. Filled, where the geometry's is stroked, and at the
    // geometry's zPos plus one so the digits are not drawn under a box outline.
    // Its path is the only thing ever handed to it.
    uint64_t tShape = r_msg2_main(r_class("CAShapeLayer"), "layer", 0,0,0,0);
    if (r_is_objc_ptr(tShape)) {
        r_msg2_main_raw(tShape, "setFrame:", bounds, 32, NULL,0,NULL,0,NULL,0);
        // Red, matching the app's counter. Built here rather than mirrored,
        // because a CGColor is an object in the target and the app's is in this
        // process, and the counter has been red for every version of it.
        // Blue, deliberately, and not red.
        //
        // The device ruled out both of my theories and left a contradiction. The
        // glyph is 12.4 by 17.6 at 415.7, which is 377 plus half of 90 minus the
        // width, so the transform is right. The text path carried L16 and nothing
        // else, so the FOV's 73 points never arrived there. And a filled path that
        // small cannot be a red disc the size of the FOV ring. So something is
        // being filled that is not the glyph path, and a red fill cannot tell me
        // whether the text layer is the thing drawing it.
        //
        // Blue answers that in one build. If the FOV turns blue, the text layer is
        // drawing it and the path in the target is not the path that was sent. If
        // it stays red, the text layer is innocent and the geometry layer is being
        // recoloured, which is a different line of enquiry entirely.
        double tc[4] = { 0.0, 0.0, 1.0, 1.0 };
        uint64_t tCol = r_msg2_main_raw(r_class("UIColor"),
                                        "colorWithRed:green:blue:alpha:",
                                        &tc[0], 8, &tc[1], 8, &tc[2], 8, &tc[3], 8);
        uint64_t tCG = r_is_objc_ptr(tCol) ? r_msg2_main(tCol, "CGColor", 0,0,0,0) : 0;
        if (r_is_objc_ptr(tCG)) {
            r_msg2_main(tShape, "setFillColor:", tCG, 0,0,0);
            g_sbTextFill = tCG;
        }
        r_msg2_main(tShape, "setStrokeColor:", 0, 0,0,0);
        double tzw = 0.0;   // a filled path with no stroke
        r_msg2_main_raw(tShape, "setLineWidth:", &tzw, 8, NULL,0,NULL,0,NULL,0);
        r_msg2_main(tShape, "setOpaque:", 0, 0,0,0);
        double tz = 101.0;
        r_msg2_main_raw(tShape, "setZPosition:", &tz, 8, NULL,0,NULL,0,NULL,0);
        sb_disable_layer_actions(tShape);
        g_sbTextShape = tShape;
        uint64_t cLayer = r_msg2_main(container, "layer", 0,0,0,0);
        if (r_is_objc_ptr(cLayer)) {
            r_msg2_main(cLayer, "addSublayer:", shape, 0,0,0);
            r_msg2_main(cLayer, "addSublayer:", tShape, 0,0,0);
        }
        NSLog(@"[SB-TEXT] layer=0x%llx fill=%d", (unsigned long long)tShape,
              (int)r_is_objc_ptr(tCG));
    } else {
        uint64_t cLayer = r_msg2_main(container, "layer", 0,0,0,0);
        if (r_is_objc_ptr(cLayer)) r_msg2_main(cLayer, "addSublayer:", shape, 0,0,0);
    }

    r_msg2_main(win, "setHidden:", 0, 0,0,0);

    uint64_t key = r_sel("fl0rkffESPMenuWindow");
    if (r_is_objc_ptr(key)) {
        dlsym_remote("objc_setAssociatedObject", app, key, win, 1, 0,0,0,0);
    }

    pthread_mutex_lock(&g_sbLock);
    g_sbWin = win;
    g_sbShape = shape;
    g_sbCanvas = container;
    // A new session means every text slot and the alignment string are dangling.
    // Dropped here as well as in the teardown, because a rearm builds a fresh
    // window while the old pointers are still live in these globals.
    sb_text_forget();
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
    // The cost probe, the colour probe and the lineWidth read-back are all behind
    // SB_STARTUP_DIAGNOSTICS. They used to run here, before the first frame, and
    // between them they were about a hundred and fifteen remote calls of
    // measurement in front of the first painted frame.
#if SB_STARTUP_DIAGNOSTICS
    sb_cost_probe();
#endif

    // Session STAYS OPEN — Fl0rk start_in_session until stop_in_session.
    // The text thread outlives any single session: it wakes, finds no session or
    // a busy transport, and does nothing. Restarting it per session would mean a
    // thread per rearm, and a rearm loop is exactly what must not accumulate.
    sb_text_thread_start();
    NSLog(@"[SBOverlay] Fl0rk session LIVE win=0x%llx geom=0x%llx inv=%s @15fps extraThread",
          win, shape, r_is_objc_ptr(g_sbSetPathInv) ? "OK" : "NO");
    return 0;
}

// The text thread.
//
// Its whole job is to be somewhere else. Every version that ran the counter
// inside the publish made the boxes stutter at the counter's rhythm, because the
// two shared a thread and the shared thread was the one drawing the boxes.
//
// It wakes four times a second, takes the transport only if it is free, applies
// whatever the app's thread last staged, and gives the lock straight back. It
// never blocks on a publish and a publish never blocks on it, so neither can
// change the other's pace. If a publish is running the tick is dropped, and the
// next one picks up the same staged request, because staging is a snapshot and
// not a queue of events.
//
// Dropped ticks are not lost work: sb_text_send compares the string against what
// the target already shows and returns without a single call, so a tick that has
// nothing new to say is free.
static void sb_text_drain(void) {
    SbTextReq r;
    pthread_mutex_lock(&g_sbTextHandoff);
    r = g_sbTextReq[(g_sbTextSeq - 1) & 1];      // struct copy retains the string
    pthread_mutex_unlock(&g_sbTextHandoff);

    if (!r.on && !r.changed) return;
    if (!remote_call_has_local_state() || !remote_call_current_success()) return;

    const CGRect vb = g_sbTextStageBounds;
    if (CGRectIsEmpty(vb)) return;
    const double landH = (vb.size.width > vb.size.height) ? vb.size.height : vb.size.width;

    if (r.on && r.text) {
        sb_text_send(SB_TEXT_SLOT_COUNT, r.text, r.col[0], r.col[1], r.col[2], r.col[3],
                     r.frame, r.fontSize, landH);
    } else if (!r.on && r.changed) {
        // The switch was turned off. Stopping the updates is not taking the text
        // away: the label is already a layer over there and stays for the life of
        // the session, which is what was reported. One setHidden: and then
        // nothing, because the slot remembers it is hidden.
        sb_text_send(SB_TEXT_SLOT_COUNT, nil, 0, 0, 0, 0, CGRectZero, 0, landH);
    }
}

static void *sb_text_thread_main(void *arg) {
    (void)arg;
    // Nothing to do, and that is the point. The counter used to be sent from
    // here, as a CATextLayer's string, and that was costing 391 to 822ms of
    // SpringBoard main thread work per change, which stalled the publish that
    // draws the boxes: ms=391, 507, 703 and 822 against 6 to 12 for an ordinary
    // frame, ups down from 50 a second to 4, bdrops to 51.
    //
    // The counter is a filled path now, produced by sb_text_glyph_path_for_frame
    // and carried in the same op stream as the geometry, so it costs a few extra
    // CGPath calls inside a publish that was happening anyway and it needs no
    // thread of its own. What this thread would do now is race the publish for
    // the transport, which is the whole failure mode again.
    //
    // Left in place rather than deleted so the removal is one line in one place
    // if a future caller needs a per frame remote operation of its own.
    return NULL;
}

static void sb_text_thread_start(void) {
    if (g_sbTextThread) return;
    if (!g_sbTextWake) g_sbTextWake = dispatch_semaphore_create(0);
    if (pthread_create(&g_sbTextThread, NULL, sb_text_thread_main, NULL) == 0) {
        NSLog(@"[SB-TEXT] counter is a path in the geometry stream; no text thread needed");
    } else {
        g_sbTextThread = 0;
    }
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

    // Text sampling lives here, above every publish gate, and that placement is
    // the fix rather than a detail. It used to sit after the interval gate, after
    // mergePaths and after the in flight check, which meant the counter was only
    // ever looked at on the frames where geometry was about to be drawn.
    //
    // With nothing on screen mergePaths reports nothing to send and this function
    // returned before reaching it, so the pref was never read, so the switch had
    // no effect for as long as the screen was empty. That is what was reported:
    // the toggle did nothing. And at the start of a match the counter could not
    // appear until the first publish that had something to draw, which is why it
    // came up behind the ESP rather than with it.
    //
    // The counter is not a shape and shares none of the geometry's conditions, so
    // its sampling must not sit behind them. The 500ms ceiling below is the only
    // thing that limits how often it reads, and that is a ceiling on work, not a
    // dependency on the drawing.
    // Text is sampled here, on the thread that writes it, and sent by the text
    // thread. Three things forced that split.
    //
    // The race. The app assigns statusLayer.string on its own thread, so reading
    // it from the text thread can catch it mid write. The geometry already draws
    // this line, copying the serialised bytes on the calling thread and only
    // decoding them on the publish thread, and the text is sampled the same way.
    //
    // The rhythm. This used to be sent from inside the publish, which is the one
    // place that must not be delayed: eleven crossings inside a publish that is
    // drawing the boxes is what made the ESP stutter in time with the counter.
    // Now the publish does not touch text at all, and the text thread skips its
    // turn whenever a publish holds the transport. The two run at their own
    // rates and the geometry is never the one waiting.
    //
    // The cost. This is the frame path, so the read happens every frame: a KVC
    // lookup and a string compare, both local. The floor on how often the text
    // thread is woken lives on the signal, not here, because a signal that waits
    // on a timer is a delay rather than a ceiling.
    static int s_textPrev = -1;
    const int textOn = ESPPrefsBool(@"SbCountText", NO) ? 1 : 0;
    const int textChanged = (s_textPrev != textOn);
    s_textPrev = textOn;
    g_sbTextStageBounds = espView.bounds;
    {
        {
            SbTextReq r;
            // Field by field, not memset. The struct holds an NSString, so it is
            // not trivially default initialisable and memset on it is rejected
            // under the warning the build workflow turns into an error. Assigning
            // the fields is also what lets ARC release the previous string.
            r.text = nil;
            r.col[0] = 1.0; r.col[1] = 0.0; r.col[2] = 0.0; r.col[3] = 1.0;
            r.frame = CGRectMake(0, 0, 0, 0);
            r.fontSize = 0.0;
            r.on = textOn;
            r.changed = textChanged;
            if (textOn) {
                id obj = [espView valueForKey:@"statusLayer"];
                if ([obj isKindOfClass:[CATextLayer class]]) {
                    CATextLayer *src = (CATextLayer *)obj;
                    // CATextLayer declares string as id in this SDK.
                    NSString *s = (NSString *)src.string;
                    if (s.length > 0 && !src.hidden) {
                        r.text = s;
                        r.frame = src.frame;
                        r.fontSize = src.fontSize;
                        CGColorRef c = src.foregroundColor;
                        const size_t nc = c ? CGColorGetNumberOfComponents(c) : 0;
                        const CGFloat *cc = c ? CGColorGetComponents(c) : NULL;
                        r.col[0] = 1.0; r.col[1] = 0.0; r.col[2] = 0.0; r.col[3] = 1.0;
                        if (nc >= 3 && cc) {
                            r.col[0] = cc[0]; r.col[1] = cc[1]; r.col[2] = cc[2];
                            r.col[3] = (nc >= 4) ? cc[nc - 1] : 1.0;
                        }
                    }
                }
            }
            pthread_mutex_lock(&g_sbTextHandoff);
            g_sbTextReq[g_sbTextSeq & 1] = r;    // retains the string
            __sync_synchronize();
            g_sbTextSeq++;
            pthread_mutex_unlock(&g_sbTextHandoff);

            // Wake the text thread only when the value it would send is actually
            // different from the last one staged. Posting on every frame would
            // turn a 4Hz poll into a 60Hz wakeup, and posting only on a toggle
            // would miss a count that changed on its own.
            //
            // isEqualToString: rather than pointer equality, because the app
            // builds a fresh NSString for the number whenever the count moves
            // and two equal strings are still one thing to send.
            NSString *prev = g_sbTextStaged;
            BOOL differs = (r.text == nil || prev == nil)
                         ? (r.text != prev)
                         : ![r.text isEqualToString:prev];
            if (textChanged || differs) {
                g_sbTextStaged = r.text;
                const uint64_t tSig = now_us();
                if (g_sbTextWake && (textChanged || tSig >= g_sbNextSignalUS)) {
                    g_sbNextSignalUS = tSig + SB_TEXT_SIGNAL_MIN_US;
                    dispatch_semaphore_signal(g_sbTextWake);
                }
            }
        }
    }


    g_sbSummaryAttempts++;

    uint64_t t = now_us();
    if (t < g_sbNextPublishUS) {
        g_sbSummarySkips++;
        return;
    }

    static NSMutableData *ops = nil;
    if (!ops) ops = [NSMutableData dataWithCapacity:8192];

    if (!mergePaths(espView, sb_text_glyph_path_for_frame(espView), ops)) {
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
        // The transport for the whole publish, and for the text thread when it
        // gets a turn. @finally rather than a pair of unlocks on the error paths,
        // because this body has several returns and a lock left held on any of
        // them would freeze the text thread permanently.
        pthread_mutex_lock(&g_sbIoLock);
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
            // The counter's path, in the target. Separate from the geometry's
            // because a CAShapeLayer has one fill colour and the digits are filled
            // while the boxes are stroked; sharing a path would make the digits
            // outlines or the boxes solid, and neither is wanted.
            uint64_t rpT = r_is_objc_ptr(g_sbTextShape) ? sb_text_path() : 0;
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
            // Where this run's points go. The counter is layer 16, it is filled,
            // and the geometry is stroked, and one CAShapeLayer has one fill
            // colour, so the two cannot share a path. Switching on the layer
            // marker is a compare per run; a second decode loop would be the
            // shape of code that has broken here before.
            uint64_t dstPath = rp;
            int dstLayer = -1;
            // The counter's path is replaced rather than emptied: CGPathClear and
            // CGPathReset are both absent from CoreGraphics.tbd on this OS, so
            // there is no way to clear a CGMutablePathRef in place.
            //
            // The previous version of this allocated a fresh one on every publish
            // and let the old one go. At the 50 publishes a second the overlay
            // reaches, that is 50 CGMutablePaths a second accumulating in
            // SpringBoard, which is a leak measured in objects per second in
            // somebody else's process and is not a thing to leave running.
            //
            // It is replaced only when there is something to put in it. The
            // publish still ends up handing the same path over unchanged when the
            // counter has not moved, and handing the same path to setPath: again
            // is one call that changes nothing, which is cheaper than allocating.
            if (r_is_objc_ptr(rpT) && g_sbTextPathDirty) {
                g_sbTextPath = 0;
                rpT = dlsym_remote("CGPathCreateMutable", 0,0,0,0,0,0,0,0);
            }
            uint32_t dstCount = 0;                 // runs sent to the text path
            uint32_t tCount = 0;                   // and their shapes
            uint8_t  tPts[64];
            uint32_t tPtsN[64];
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
                        if (curLayer != dstLayer) {
                            // The pending rectangle batch is flushed before the
                            // switch, or a batch begun on one layer would finish
                            // into the next one's path.
                            if (rectDoubles >= 4) {
                                remote_write(ptsBuf, rectBuf, (size_t)rectDoubles * 8);
                                dlsym_remote("CGPathAddRects", dstPath, 0, ptsBuf,
                                             rectDoubles / 4, 0, 0,0,0);
                                calls++; drawn++;
                                rectDoubles = 0;
                            }
                            dstLayer = curLayer;
                            dstPath = (curLayer == SB_TEXT_LAYER_INDEX && r_is_objc_ptr(rpT))
                                    ? rpT : rp;
                            if (dstPath == rpT && tCount < 64) {
                                // Which run went to the text path, so a wrong
                                // destination is readable off the device instead
                                // of guessed at. The FOV arriving here is a 73
                                // point run and would say so.
                                tPts[tCount] = (uint8_t)curLayer;
                                tPtsN[tCount] = 0;
                                tCount++;
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
                if (tCount > 0 && dstPath == rpT) tPtsN[tCount - 1] += (uint32_t)np;
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
dlsym_remote("CGPathAddRects", dstPath, 0, ptsBuf,
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
dlsym_remote("CGPathAddLines", dstPath, 0, ptsBuf, np, 0,0,0,0);
                calls++; drawn++;
            }

            if (rectDoubles >= 4) {
                remote_write(ptsBuf, rectBuf, (size_t)rectDoubles * 8);
dlsym_remote("CGPathAddRects", dstPath, 0, ptsBuf, rectDoubles / 4, 0,0,0,0);
                calls++; drawn++;
            }

            // The counter's path goes to its own layer. One call, and the main
            // thread fills a path instead of laying out a string, which is the
            // whole reason for the change: ms=391 to 822 for a two digit number
            // before, against 6 to 12 for an ordinary frame.
            if (r_is_objc_ptr(rpT) && r_is_objc_ptr(g_sbTextShape)) {
                r_msg2_main(g_sbTextShape, "setPath:", rpT, 0,0,0);
                calls++;
                g_sbTextPath = rpT;
                g_sbTextPathDirty = 0;   // consumed; the next change sets it again
                // What actually went on the text layer. The FOV ring came out as a
                // solid red disc, which is what a filled closed circle looks like,
                // so either a geometry run reached this path or the glyphs did. The
                // two numbers settle it without a guess: subpaths and points are
                // the count for a layer of one or two glyphs, and a FOV ring is 73
                // points on its own.
                {
                    static uint64_t s_txtLogUS = 0;
                    const uint64_t tL = now_us();
                    if (tL >= s_txtLogUS) {
                        s_txtLogUS = tL + 1000000ULL;
                        uint32_t tp = 0, tn = 0;
                        for (uint32_t k = 0; k < tCount; k++) {
                            if (tPts[k] == SB_TEXT_LAYER_INDEX) { tn++; tp += tPtsN[k]; }
                        }
                        // The layers, not just the total. A single glyph is 80 to
                        // 130 points once the curves are chorded, and the FOV ring
                        // is 73 on its own, so a total near 73 means a geometry run
                        // arrived here and a total of several hundred means more
                        // than one did. The layer numbers say which.
                        NSMutableString *ls = [NSMutableString string];
                        for (uint32_t k = 0; k < tCount; k++) {
                            [ls appendFormat:@"L%u/%u ",
                                  (unsigned)tPts[k], (unsigned)tPtsN[k]];
                        }
                        NSLog(@"[SB-TEXT] present text=%llx runs=%u points=%u [%@]",
                              (unsigned long long)rpT, tn, tp, ls);
                    }
                }
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
            // The transport goes back before the busy flag, so the text thread
            // can take it the instant this publish is done with it. The order
            // matters: releasing the other way round would let a text tick start
            // while this publish was still unwinding, and the two would
            // interleave inside the transport.
            pthread_mutex_unlock(&g_sbIoLock);
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
