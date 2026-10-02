#import "MDLog.h"
#import "../KernelBoot.h"

NSString * const MDLogDidAppendNotification = @"MDLogDidAppendNotification";

// 8k characters is roughly 200 lines, enough to hold one full boot plus the
// retries around it, and it is the same cap the old Home log card used.
static const NSUInteger kMDLogMaxChars = 8000;

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