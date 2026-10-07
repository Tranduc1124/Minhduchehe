#import "button.h"
#import "ESPPrefs.h" // Thêm để đọc trạng thái Streamer Mode

// --- BỔ SUNG CÁC KHAI BÁO THIẾU ĐỂ HẾT LỖI BIÊN DỊCH ---
#ifndef NSSENCRYPT
#define NSSENCRYPT(str) (str) // Fallback nếu project chưa định nghĩa macro mã hóa
#endif

extern "C" void ESPSyncFromPrefs(void); // Khai báo hàm đồng bộ từ prefs bị thiếu
// --------------------------------------------------------


@interface HTHButtonSecureWrapper : UITextField
@end

@implementation HTHButtonSecureWrapper
- (BOOL)canBecomeFirstResponder { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { 
    return YES;  // ✅ FIX: Cho phép button nhận touch event
}
@end
// =======================================================

@interface CustomToggleView ()
@property (nonatomic, assign) NSInteger trackingPointerId;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) CGPoint dragStartCenter;
@property (nonatomic, assign) CGPoint dragStartPoint;

// CÁC BIẾN CHO STREAMER MODE
@property (nonatomic, strong) CADisplayLink *displayLink;

// What we last pushed into the secure field, NOT what we read back out of it.
//
// updateVisibility runs on a CADisplayLink, so it runs every frame, and its old
// guard was `_secureTextField.secureTextEntry != isStreamer` -- reading back a
// field UIKit owns and rebuilds internally whenever secureTextEntry changes. The
// moment those two disagree, the guard stays true forever and every single frame
// does removeFromSuperview, flips secureTextEntry, forces layoutIfNeeded on the
// field, re-derives the canvas and re-adds the whole content view.
//
// That is an unbounded per-frame re-parent of the entire menu, and it is reached
// by touching any setting, which is why the UI and the overlay came apart after a
// toggle rather than the toggle simply not taking.
//
// Tracking the intent makes the loop impossible: at most one re-parent per real
// state change.
@property (nonatomic, assign) BOOL appliedStreamerMode;
@property (nonatomic, strong) HTHButtonSecureWrapper *secureTextField;
@property (nonatomic, strong) UIView *secureCanvas;
@property (nonatomic, strong) UIView *contentView; // Gói nút vào view này
@end

@implementation CustomToggleView

// --- 1. QUẢN LÝ KHỞI TẠO SINGLETON ---
+ (instancetype)shared {
    static CustomToggleView *sharedBtn = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGFloat savedX = ESPPrefsFloat(@"CustomToggleBtnX", 0.0f);
        CGFloat savedY = ESPPrefsFloat(@"CustomToggleBtnY", 0.0f);
        if (savedX <= 0) savedX = 100;
        if (savedY <= 0) savedY = 200;
        
        sharedBtn = [[self alloc] initWithFrame:CGRectMake(savedX, savedY, 55, 55) title:@"Dù 3s" action:nil];
    });
    return sharedBtn;
}

+ (void)showSpeedButton:(BOOL)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        CustomToggleView *btn = [self shared];
        if (show) {
            UIWindow *window = [UIApplication sharedApplication].keyWindow;
            if (!window) window = [[UIApplication sharedApplication].windows firstObject];
            
            if (window && btn.superview != window) {
                [window addSubview:btn];
            }
            [window bringSubviewToFront:btn];
            btn.hidden = NO;
        } else {
            btn.hidden = YES;
            [btn removeFromSuperview];
        }
    });
}

- (void)showMenu {
    self.hidden = NO;
}

- (void)hideMenu {
    self.hidden = YES;
}

// --- 2. GIAO DIỆN NÚT ---
- (instancetype)initWithFrame:(CGRect)frame title:(NSString *)title action:(ToggleActionBlock)action {
    self = [super initWithFrame:frame];
    if (self) {
        self.actionBlock = action;
        _trackingPointerId = -1;
        
        self.backgroundColor = [UIColor clearColor];
        _secureTextField = [[HTHButtonSecureWrapper alloc] initWithFrame:self.bounds];
        _secureTextField.userInteractionEnabled = NO;
        _secureTextField.backgroundColor = [UIColor clearColor];
        _secureTextField.text = @"\u200B"; 
        _secureTextField.textColor = [UIColor clearColor];
        _secureTextField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_secureTextField];
        
        // Recorded, not re-derived: init already applies this value, so if
        // updateVisibility's intent were left unset it would immediately redo the
        // whole re-parent once on the first display-link tick.
        self.appliedStreamerMode = ESPPrefsBool(@"StreamerMode", NO);
        _secureTextField.secureTextEntry = self.appliedStreamerMode;
        [_secureTextField layoutIfNeeded];
        
        _secureCanvas = _secureTextField.subviews.firstObject ?: _secureTextField;
        _secureCanvas.userInteractionEnabled = NO;
        
        // Gói toàn bộ giao diện nút vào Content View
        _contentView = [[UIView alloc] initWithFrame:self.bounds];
        _contentView.backgroundColor = [UIColor clearColor];
        _contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_secureCanvas addSubview:_contentView];

        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(5, 0, frame.size.width, 20)];
        self.titleLabel.text = title;
        self.titleLabel.textColor = [UIColor blackColor];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:13]; 
        [_contentView addSubview:self.titleLabel];

        self.toggleSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(0, 22, 50, 30)];
        self.toggleSwitch.thumbTintColor = [UIColor blackColor]; 
        self.toggleSwitch.onTintColor = [UIColor colorWithRed:0.39 green:0.80 blue:0.18 alpha:1.0];
        self.toggleSwitch.backgroundColor = [UIColor redColor];
        self.toggleSwitch.layer.cornerRadius = 15.5; 
        self.toggleSwitch.tintColor = [UIColor redColor]; 
        
        self.toggleSwitch.userInteractionEnabled = NO;
        
        BOOL isSpeedOn = ESPPrefsBool(@"CustomToggleBtnState", NO);
        self.toggleSwitch.on = isSpeedOn;

        if (isSpeedOn) {
            ESPPrefsSetBool(@"Norecoil", YES);
            // Old Brutal uses run scale 0.16 — don't stack menu Speed.
            ESPPrefsSetBool(@"Speed", NO);
            ESPSyncFromPrefs();
        }
        
        [_contentView addSubview:self.toggleSwitch];
        
        // Vòng lặp kiểm tra trạng thái Streamer Mode liên tục
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateVisibility)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)updateVisibility {
    BOOL isStreamer = ESPPrefsBool(@"StreamerMode", NO);
    if (_appliedStreamerMode == isStreamer) return;
    _appliedStreamerMode = isStreamer;

    [_contentView removeFromSuperview];

    _secureTextField.secureTextEntry = isStreamer;
    [_secureTextField setNeedsLayout];
    [_secureTextField layoutIfNeeded];

    _secureCanvas = _secureTextField.subviews.firstObject ?: _secureTextField;
    _secureCanvas.userInteractionEnabled = NO;

    [_secureCanvas addSubview:_contentView];
}

- (void)switchChanged:(UISwitch *)sender {
    ESPPrefsSetBool(@"CustomToggleBtnState", sender.isOn);

    if (self.actionBlock) self.actionBlock(sender.isOn);

    ESPPrefsSetBool(@"Norecoil", sender.isOn);
    if (sender.isOn) {
        ESPPrefsSetBool(@"Speed", NO);
    }
    ESPSyncFromPrefs();
}

- (BOOL)handleTouchAtWindowPoint:(CGPoint)windowPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId {
    if (self.hidden || !self.superview) return NO;
    
    CGPoint local = self.window ? [self convertPoint:windowPoint fromView:self.window] : windowPoint;
    
    CGRect viewHit = CGRectInset(self.bounds, -10, -10);
    BOOL insideView = CGRectContainsPoint(viewHit, local);
    
    CGRect switchHit = CGRectInset(self.toggleSwitch.frame, -5, -5);
    BOOL insideSwitch = CGRectContainsPoint(switchHit, local);

    switch (phase) {
        case UITouchPhaseBegan: {
            if (_trackingPointerId != -1 && pointerId != _trackingPointerId) {
                [self resetTouchTrackingState];
            }
            
            if (insideSwitch) {
                _trackingPointerId = pointerId;
                _isDragging = NO;
                
                [self.toggleSwitch setOn:!self.toggleSwitch.isOn animated:YES];
                [self switchChanged:self.toggleSwitch];
                return YES;
            }
            
            if (insideView) {
                _trackingPointerId = pointerId;
                _isDragging = NO;
                _dragStartCenter = self.center;
                _dragStartPoint = windowPoint;
                [self.superview bringSubviewToFront:self]; 
                return YES;
            }
            return NO;
        }
            
        case UITouchPhaseMoved: {
            if (pointerId == _trackingPointerId) {
                CGFloat dx = windowPoint.x - _dragStartPoint.x;
                CGFloat dy = windowPoint.y - _dragStartPoint.y;
                
                if (!_isDragging && (fabs(dx) + fabs(dy) > 10.0f)) {
                    _isDragging = YES;
                }
                
                if (_isDragging) {
                    self.center = CGPointMake(_dragStartCenter.x + dx, _dragStartCenter.y + dy);
                    
                    if (self.superview) {
                        CGRect frame = self.frame;
                        CGFloat w = CGRectGetWidth(self.superview.bounds);
                        CGFloat h = CGRectGetHeight(self.superview.bounds);
                        
                        if (frame.origin.x < 0.0f) frame.origin.x = 0.0f;
                        if (frame.origin.y < 0.0f) frame.origin.y = 0.0f;
                        if (CGRectGetMaxX(frame) > w) frame.origin.x = w - CGRectGetWidth(frame);
                        if (CGRectGetMaxY(frame) > h) frame.origin.y = h - CGRectGetHeight(frame);
                        self.frame = frame;
                    }
                }
                return YES;
            }
            return NO;
        }
            
        case UITouchPhaseEnded:
        case UITouchPhaseCancelled: {
            if (pointerId == _trackingPointerId) {
                if (_isDragging) {
                    ESPPrefsSetFloat(@"CustomToggleBtnX", self.frame.origin.x);
                    ESPPrefsSetFloat(@"CustomToggleBtnY", self.frame.origin.y);
                }
                [self resetTouchTrackingState];
                return YES;
            }
            return NO;
        }
        default: return NO;
    }
}

- (BOOL)handleTouchAtLocalPoint:(CGPoint)localPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId {
    if (self.window) {
        return [self handleTouchAtWindowPoint:[self convertPoint:localPoint toView:self.window] phase:phase pointerId:pointerId];
    }
    return [self handleTouchAtWindowPoint:localPoint phase:phase pointerId:pointerId];
}

- (void)resetTouchTrackingState {
    _isDragging = NO;
    _trackingPointerId = -1;
}

- (void)dealloc {
    [_displayLink invalidate];
    _displayLink = nil;
}

@end
