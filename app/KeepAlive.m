//
//  KeepAlive.m — silent audio keepalive (Fl0rk-style)
//
//  iOS suspends background apps unless:
//    - AVAudioSession .playback is ACTIVE with a looping player, AND
//    - Info.plist UIBackgroundModes contains "audio" (already set)
//
//  Previous bug: wrote raw PCM bytes as "ka.wav" with NO RIFF/WAVE header
//  → AVAudioPlayer init failed → no audio → process suspended/killed after
//  ~30s background → kexploit state gone → ESP/aim die; SB overlay ghost remains.
//

#import "KeepAlive.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@implementation KeepAlive {
    AVAudioPlayer *_player;
    UIBackgroundTaskIdentifier _bgTask;
    BOOL _running;
    id _interruptObs;
    id _resetObs;
}

+ (instancetype)shared {
    static KeepAlive *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [KeepAlive new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    _bgTask = UIBackgroundTaskInvalid;
    return self;
}

- (BOOL)running { return _running; }

/// Minimal valid 1s mono 8kHz 16-bit silent WAV (44-byte header + PCM zeros).
- (NSData *)silentWavData {
    const uint32_t sampleRate = 8000;
    const uint16_t channels = 1;
    const uint16_t bitsPerSample = 16;
    const uint32_t numSamples = sampleRate; // 1 second
    const uint32_t dataSize = numSamples * channels * (bitsPerSample / 8);
    const uint32_t byteRate = sampleRate * channels * (bitsPerSample / 8);
    const uint16_t blockAlign = channels * (bitsPerSample / 8);
    const uint32_t riffSize = 36 + dataSize;

    NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataSize];
    void (^put4)(const char *, uint32_t) = ^(const char *tag, uint32_t v) {
        [d appendBytes:tag length:4];
        [d appendBytes:&v length:4];
    };
    void (^put2)(uint16_t) = ^(uint16_t v) {
        [d appendBytes:&v length:2];
    };

    [d appendBytes:"RIFF" length:4];
    uint32_t rs = riffSize; [d appendBytes:&rs length:4];
    [d appendBytes:"WAVE" length:4];
    [d appendBytes:"fmt " length:4];
    uint32_t fmtSize = 16; [d appendBytes:&fmtSize length:4];
    put2(1); // PCM
    put2(channels);
    uint32_t sr = sampleRate; [d appendBytes:&sr length:4];
    uint32_t br = byteRate; [d appendBytes:&br length:4];
    put2(blockAlign);
    put2(bitsPerSample);
    [d appendBytes:"data" length:4];
    uint32_t ds = dataSize; [d appendBytes:&ds length:4];
    // silent PCM
    NSMutableData *zeros = [NSMutableData dataWithLength:dataSize];
    [d appendData:zeros];
    (void)put4;
    return d;
}

- (void)startPlayerOnMain {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&err];
    if (err) NSLog(@"[KeepAlive] setCategory: %@", err);
    err = nil;
    [session setActive:YES error:&err];
    if (err) NSLog(@"[KeepAlive] setActive: %@", err);

    NSData *wav = [self silentWavData];
    _player = [[AVAudioPlayer alloc] initWithData:wav error:&err];
    if (!_player) {
        NSLog(@"[KeepAlive] AVAudioPlayer FAILED: %@", err);
    } else {
        _player.numberOfLoops = -1;
        _player.volume = 0.01f;
        BOOL ok = [_player prepareToPlay] && [_player play];
        NSLog(@"[KeepAlive] player play=%d duration=%.2f", ok, _player.duration);
    }
}

- (void)renewBackgroundTask {
    UIApplication *app = [UIApplication sharedApplication];
    UIBackgroundTaskIdentifier old = _bgTask;
    _bgTask = [app beginBackgroundTaskWithName:@"ESPKeepAlive"
                             expirationHandler:^{
        NSLog(@"[KeepAlive] bgTask expiring — renew");
        UIBackgroundTaskIdentifier expiring = self->_bgTask;
        self->_bgTask = UIBackgroundTaskInvalid;
        if (expiring != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:expiring];
        }
        if (self->_running) {
            // Renew + ensure audio still playing
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self->_player.isPlaying) [self->_player play];
                [self renewBackgroundTask];
            });
        }
    }];
    if (old != UIBackgroundTaskInvalid && old != _bgTask) {
        [app endBackgroundTask:old];
    }
}

- (void)installAudioObservers {
    if (_interruptObs) return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    __weak KeepAlive *weakSelf = self;
    _interruptObs = [nc addObserverForName:AVAudioSessionInterruptionNotification
                                    object:nil queue:nil
                                usingBlock:^(NSNotification *note) {
        NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
        if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded) return;
        KeepAlive *s = weakSelf;
        if (!s || !s->_running) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            [s->_player play];
        });
    }];
    _resetObs = [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                                object:nil queue:nil
                            usingBlock:^(NSNotification *note) {
        (void)note;
        KeepAlive *s = weakSelf;
        if (!s || !s->_running) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [s startPlayerOnMain];
        });
    }];
}

- (void)start {
    // Gated here rather than at the call sites. There are four callers — the
    // app delegate on foreground and on background, KernelBoot stage 4, and
    // StartESPHost — and gating each one means a new caller quietly gets a
    // KeepAlive the user turned off.
    extern BOOL ESPPrefsBool(NSString *key, BOOL defaultValue);
    if (!ESPPrefsBool(@"KeepAliveOn", YES)) return;

    if (_running) {
        // Already marked running — still ensure player alive (idempotent).
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_player.isPlaying) [self startPlayerOnMain];
            if (self->_bgTask == UIBackgroundTaskInvalid) [self renewBackgroundTask];
        });
        return;
    }
    _running = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self startPlayerOnMain];
        [self renewBackgroundTask];
        [self installAudioObservers];
        NSLog(@"[KeepAlive] started (valid WAV + bgTask)");
    });
}

- (void)stop {
    if (!_running) return;
    _running = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_player stop];
        self->_player = nil;
        [[AVAudioSession sharedInstance] setActive:NO
            withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                  error:nil];

        if (self->_bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self->_bgTask];
            self->_bgTask = UIBackgroundTaskInvalid;
        }
        if (self->_interruptObs) {
            [[NSNotificationCenter defaultCenter] removeObserver:self->_interruptObs];
            self->_interruptObs = nil;
        }
        if (self->_resetObs) {
            [[NSNotificationCenter defaultCenter] removeObserver:self->_resetObs];
            self->_resetObs = nil;
        }
        NSLog(@"[KeepAlive] stopped");
    });
}

@end
