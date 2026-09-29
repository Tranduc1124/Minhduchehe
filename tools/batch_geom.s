// Batch geometry interpreter, assembled for aarch64 by clang and embedded into
// remote/BatchGeom.c as a byte array. Do not hand-assemble; regenerate with
// tools/gen_batch_asm.sh if the ABI below changes.
//
// CONTRACT
//   x0 = pointer to a BatchHeader in SpringBoard's address space
//   returns 0 when the whole batch ran
//
// BatchHeader (8-byte aligned, 3 words):
//   +0   fnAddLines   address of CGPathAddLines in SpringBoard
//   +8   fnAddRects   address of CGPathAddRects in SpringBoard
//   +16  count        number of entries that follow
// then `count` entries of 4 words:
//   +0   op           1 = CGPathAddLines, 2 = CGPathAddRects, anything else = skip
//   +8   a            CGMutablePathRef
//   +16  b            pointer to the point / rect array already in SpringBoard
//   +24  c            point count, or rectangle count
//
// WHY BUILT LIKE THIS
// One invocation replaces N remote calls. Each remote call costs four mach_msg
// round trips on the exception port plus two thread_create/thread_terminate
// pairs for the PAC signature, so a frame that issued fifty of them paid for a
// hundred kernel thread lifecycles to move about four kilobytes of numbers.
// Here the numbers go across once with a single remote_write and the fifty
// CGPath calls happen inside SpringBoard, where they cost a memset.
//
// REGISTERS
// x9 to x12 are caller-saved, so the CG functions SpringBoard runs may clobber
// them. x30 is saved and restored because every blr overwrites it, and the
// caller's return path is the signed FAKE_LR that parks the thread again.

        .text
        .globl batch_geom
        .p2align 2
batch_geom:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp

        ldr     x9,  [x0]              // fnAddLines
        ldr     x10, [x0, #8]           // fnAddRects
        ldr     x11, [x0, #16]          // count
        add     x12, x0, #24            // cursor, just past the header
        cbz     x11, .Ldone

.Lnext:
        ldr     x0,  [x12]
        ldr     x1,  [x12, #8]
        ldr     x2,  [x12, #16]
        ldr     x3,  [x12, #24]

        cmp     x0, #1
        b.eq    .Llines
        cmp     x0, #2
        b.eq    .Lrects
        b       .Ladv

.Llines:
        blr     x9
        b       .Ladv

.Lrects:
        blr     x10

.Ladv:
        add     x12, x12, #32
        subs    x11, x11, #1
        b.ne    .Lnext

.Ldone:
        mov     x0, #0
        ldp     x29, x30, [sp], #16
        ret

// No .note.GNU-stack here: the clang on the syntax-check host rejects the
// @progbits variant and the note only suppresses a linker warning that never
// fires for an object file we never link into an image. The code is extracted
// with llvm-objcopy and embedded as data.
