//
//  esptext.h
//  The text manifest: what the renderer drew as text this frame, in a form the
//  overlay can read without touching a CATextLayer.
//
//  Kept in its own header, deliberately, and deliberately plain C.
//
//  It was in esp.h first, and esp.h is included by remote/SpringBoardOverlay.m,
//  which is a .m file. esp.h reaches GameLogic.h, which reaches pid.h and
//  UnityMath.h, and those are C++: extern "C" blocks, template specialisations
//  and inline constructors. Compiling them as Objective-C produced twenty errors
//  on the first pass of every build, which is what the workflow reported. This
//  header has no C++ in it and includes nothing that does, so both sides can
//  include it: esp.mm and espdraw.mm from C++, SpringBoardOverlay.m from C.
//
//  The content is in the commit message for 7d6b95a39. In short: the app's own
//  text comes out of a pool by position, textLayerPool[activeTextLayerCount++],
//  so its index is the order the pawns were walked and next frame index zero is
//  a different player. Reading it by index would shuffle the names around, so the
//  renderer records them here instead, keyed by pawn, beside the draw call that
//  already has PawnObject in hand.
//
//  Writing it is a struct assignment in the app's own process. No remote call, no
//  ARC, strings copied as bytes. It is rebuilt from empty each frame, so absence
//  is the delete and the reader reconciles in a single walk.
//

#ifndef esptext_h
#define esptext_h

#include <stdint.h>
#include <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>

// The size is a maximum, not a target. 128 pawns is the snapshot cap the renderer
// already enforces, two labels each, and the headroom past that means a full lobby
// drops nothing: entries past the cap raise overflow instead of disappearing.
#define ESP_TEXT_MANIFEST_MAX 256
#define ESP_TEXT_NAME_MAX 48

typedef enum {
    ESP_TEXT_KIND_NAME     = 1,
    ESP_TEXT_KIND_DISTANCE = 2
} EspTextKind;

typedef struct {
    uint64_t pawn;                        // stable key
    uint32_t kind;
    float    x, y, w, h;                  // the app's own frame, landscape space
    float    size;
    float    r, g, b, a;
    uint16_t len;
    char     text[ESP_TEXT_NAME_MAX];
} EspTextEntry;

typedef struct {
    int32_t  count;                       // entries actually written
    int32_t  overflow;                    // dropped because the cap was hit
    uint32_t frame;                       // 0 before the first frame
    uint32_t reserved;
    EspTextEntry e[ESP_TEXT_MANIFEST_MAX];
} EspTextManifest;

// C linkage, and it has to be explicit.
//
// The definitions live in esp.mm, which theos compiles as Objective-C++, where a
// plain function definition gets C++ linkage and a mangled name. The one reader in
// a .m file, SpringBoardOverlay.m, compiles as Objective-C and asks for the
// unmangled name. Those two do not meet, and the build failed at the link with
//
//    Undefined symbols for architecture arm64:
//      "_ESPTextManifestGet", referenced from:
//          _sb_text_thread_main in SpringBoardOverlay.m.o
//
// on the getter only, because the other two are called from .mm files on both sides
// and matched. The guard is here rather than being left to the C++ rule of picking
// up a prior declaration's linkage, because relying on that is exactly the kind of
// thing that breaks the next time a file moves.
//
// pid.h opens with a bare extern "C" and this does not, and that is deliberate:
// this header is included from a .m file, where extern "C" is a syntax error, which
// is the first error this whole thing produced.
#ifdef __cplusplus
extern "C" {
#endif

// Once per frame, before anything is drawn.
void ESPTextManifestReset(void);
// Returns 1 if the entry was recorded, 0 if the text was empty or the cap was hit.
int32_t  ESPTextManifestAdd(uint64_t pawn, int kind, NSString *text,
                            CGRect frame, CGFloat size, const CGFloat *rgba);
const EspTextManifest *ESPTextManifestGet(void);

#ifdef __cplusplus
}
#endif

#endif /* esptext_h */
