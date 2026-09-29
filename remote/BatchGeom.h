//
//  BatchGeom.h
//  One remote call per frame instead of one per CGPath call.
//
#ifndef BatchGeom_h
#define BatchGeom_h

// Assembly interpreter, generated from tools/batch_geom.s. It runs inside
// SpringBoard and loops over a list of CGPath calls, so the cost of the
// transport is paid once per frame rather than once per shape.
//
// The motivation is arithmetic, not style. A remote call is four mach_msg round
// trips on the exception port plus two thread_create/thread_terminate pairs for
// the PAC signature. A frame that drew six boxes, a snapline set, four health
// bars and a card batch issued around fifty such calls, which is a hundred
// kernel thread lifecycles to move roughly four kilobytes of coordinates. The
// numbers cross once and the fifty CoreGraphics calls happen in place, where
// each is a memset.
extern const unsigned char kBatchGeomCode[];
extern const unsigned kBatchGeomCodeLen;

// Header followed by entries. All words, 8-byte aligned, in the target's address
// space. batch_geom.s is the normative description; this is the same layout.
//
//   header.word[0]  fnAddLines   CGPathAddLines in SpringBoard
//   header.word[1]  fnAddRects   CGPathAddRects in SpringBoard
//   header.word[2]  count        entries that follow
//   entry[0]        op           1 = AddLines, 2 = AddRects, other = skipped
//   entry[1]        a            CGMutablePathRef
//   entry[2]        b            point or rect array, already in SpringBoard
//   entry[3]        c            point count, or rect count
#define SB_BATCH_OP_LINES  1
#define SB_BATCH_OP_RECTS  2
#define SB_BATCH_HEADER_W  3
#define SB_BATCH_ENTRY_W   4

// mmap PROT_EXEC in the target, sized for the code plus the largest command
// list a single frame can produce, rounded to a page.
#define SB_BATCH_PROT      (PROT_READ | PROT_WRITE | PROT_EXEC)

#endif /* BatchGeom_h */
