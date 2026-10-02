#import "MDLog.h"
#import "../KernelBoot.h"

NSString * const MDLogDidAppendNotification = @"MDLogDidAppendNotification";

// 8k characters is roughly 200 lines, enough to hold one full boot plus the
// retries around it, and it is the same cap the old Home log card used.
static const NSUInteger kMDLogMaxChars = 8000;

// Debug tags to keep out of the console. The emitters are left alone on
// purpose: they live in esp.mm and DSMemory.m, are per-frame, and are useful
// in the device log via NSLog.
//
//   [verify] raw addresses from KernelBoot after the exploit
//   [diag]   per-frame state lines. "stop: no-base" alone repeats every frame
//            while no session is up, which filled the buffer and pushed the
//            boot steps off the top of the screen.
//
// This costs nothing to filter here and cannot be done downstream: the buffer
// is the only thing the two log screens read.
static BOOL MDLogIsFiltered(NSString *line) {
    return [line hasPrefix:@"[verify]"] || [line hasPrefix:@"[diag]"];
}

static NSMutableString *g_text = nil;

static void MDEnsureBuffer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_text = [NSMutableString string];
    });
}

static void MDLogSink(NSString *line) {
    [MDLog appendLine:line];
}

@implementation MDLog

+ (void)attachKernelBoot {
    kernelBootLog = MDLogSink;
}

+ (void)appendLine:(NSString *)line {
    if (line.length == 0) return;
    if (MDLogIsFiltered(line)) return;
    MDEnsureBuffer();
    @synchronized (g_text) {
        [g_text appendFormat:@"%@\n", line];
        if (g_text.length > kMDLogMaxChars) {
            [g_text deleteCharactersInRange:NSMakeRange(0, g_text.length - kMDLogMaxChars)];
        }
    }
    // KernelBoot already hops to the main queue before calling the sink, but a
    // UI caller can land here from anywhere, and the notification must not.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MDLogDidAppendNotification
                                                            object:nil];
    });
}

+ (NSString *)text {
    MDEnsureBuffer();
    @synchronized (g_text) {
        return [g_text copy];
    }
}

+ (void)clear {
    MDEnsureBuffer();
    @synchronized (g_text) {
        [g_text setString:@""];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MDLogDidAppendNotification
                                                            object:nil];
    });
}

@end