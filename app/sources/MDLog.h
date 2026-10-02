#import <Foundation/Foundation.h>

// One log buffer for the whole app process.
//
// KernelBoot owns a single C callback (kernelBootLog), so the sink is
// installed once here at launch instead of per screen. Both log screens read
// the same buffer: the Log tab shows everything, the boot log on the Game tab
// shows whatever has been written since the last MDLogClear().
//
// Writes may come from any thread; the notification is always posted on the
// main queue.

#ifdef __cplusplus
extern "C" {
#endif

extern NSString * const MDLogDidAppendNotification;

@interface MDLog : NSObject

// Points KernelBoot's kernelBootLog at this buffer. Idempotent.
+ (void)attachKernelBoot;

+ (void)appendLine:(NSString *)line;
+ (NSString *)text;
+ (void)clear;

@end

#ifdef __cplusplus
}
#endif