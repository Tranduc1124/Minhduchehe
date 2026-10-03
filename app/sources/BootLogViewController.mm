#import "BootLogViewController.h"
#import "MDLogView.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "MDLog.h"
#import "../KernelBoot.h"
#import "../../remote/SpringBoardOverlay.h"

#import <QuartzCore/QuartzCore.h>

// Startup console, presented as a sheet over the Game tab when the user taps
// Activate: light header bar with the title and Hide, the shared MDLogView in
// the middle, a footer that spins until kernelBootReady() says the boot is
// done.
//
// Hiding it does not stop the boot. kernelBootStart() runs on its own queue
// and keeps writing into MDLog either way, so the Log tab picks the lines up
// whether this sheet is up or not.
@interface BootLogViewController ()
@property (nonatomic, strong) UIView *barTop;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *hideButton;
@property (nonatomic, strong) MDLogView *logView;
@property (nonatomic, strong) UIView *barBottom;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSTimer *pollTimer;
@end

@implementation BootLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.043f green:0.055f blue:0.086f alpha:1.0f];

    // ---- Top bar: title + Hide, on the grouped-background grey ----
    _barTop = [[UIView alloc] initWithFrame:CGRectZero];
    _barTop.backgroundColor = MDThemeBg();
    [self.view addSubview:_barTop];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = @"Activity";
    _titleLabel.font = MDThemeFont(17.0f, UIFontWeightSemibold);
    _titleLabel.textColor = MDThemeText();
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_barTop addSubview:_titleLabel];

    _hideButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_hideButton setTitle:@"Hide" forState:UIControlStateNormal];
    _hideButton.titleLabel.font = MDThemeFont(17.0f, UIFontWeightRegular);
    [_hideButton setTitleColor:MDThemeAccent() forState:UIControlStateNormal];
    [_hideButton addTarget:self
                    action:@selector(hideTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [_barTop addSubview:_hideButton];

    UIView *topSep = [[UIView alloc] initWithFrame:CGRectZero];
    topSep.backgroundColor = MDThemeLine();
    topSep.tag = 8101;
    [_barTop addSubview:topSep];

    // ---- Middle: the same console the Log tab shows ----
    _logView = [[MDLogView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_logView];

    // ---- Bottom bar: spinner + status, on the console background ----
    _barBottom = [[UIView alloc] initWithFrame:CGRectZero];
    _barBottom.backgroundColor = BootFooterBackground();
    [self.view addSubview:_barBottom];

    // The footer was the console background over the console background, so the
    // status row had no edge and read as empty space under the log. One line
    // makes it a strip.
    UIView *botSep = [[UIView alloc] initWithFrame:CGRectZero];
    botSep.backgroundColor = MDThemeLine();
    botSep.tag = 8102;
    [_barBottom addSubview:botSep];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.color = [UIColor colorWithWhite:1.0f alpha:0.55f];
    [_spinner startAnimating];
    [_barBottom addSubview:_spinner];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.font = MDThemeFont(13.0f, UIFontWeightRegular);
    _statusLabel.textColor = [UIColor colorWithWhite:1.0f alpha:0.55f];
    _statusLabel.text = @"Running — stay here until complete.";
    [_barBottom addSubview:_statusLabel];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_logView refresh];
    [self updateStatus];
    __weak __typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                   repeats:YES
                                                     block:^(NSTimer *t) {
        [weakSelf updateStatus];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_pollTimer invalidate];
    _pollTimer = nil;
}

- (void)dealloc {
    [_pollTimer invalidate];
}

// The footer strip reports the state; it does not colour itself. It was a 16%
// wash of the state colour over the console background and that read as a solid
// orange slab under the log -- louder than the log it was annotating, and the
// one thing on the sheet that changed appearance. So the bar is a fixed grey and
// only the sentence carries the state.
//
// Nothing is animated. The poll runs four times a second, and the only thing
// that can change in a run is the state itself, which is rare -- animating the
// label on every tick is what makes a status line flicker.
- (void)setFooterLabel:(UIColor *)text {
    _statusLabel.textColor = text;
}

// A flat grey that reads as a strip against the near-black console, darker than
// the header bar above so the sheet has a top and a bottom rather than two
// identical caps.
static UIColor *BootFooterBackground(void) {
    return [UIColor colorWithRed:0.12f green:0.13f blue:0.16f alpha:1.0f];
}

// The sheet's whole point is "it is still working". Spinner and wording stop
// when kernelBootReady() flips, which is KernelBoot's own flag and not a
// guess about how long a boot takes.
//
// Two facts, not one, because they finish at different times. The boot is done
// at stage 6. The ESP is not on screen until a frame has actually reached
// SpringBoard, which is a separate moment, and the log reaches
// "OK ESP host started" well before that. Showing only the boot flag left the
// footer reading "Done" while the picture was still empty, which is the same
// claim-too-early problem the Game tab had.
//
// The log is the evidence and is left alone: it is append-only and every line
// in it is something that actually happened.
- (void)updateStatus {
    const BOOL booted   = kernelBootReady();
    const BOOL painting = (SBoardOverlayHasPublishedFrame() != 0);

    if (painting) {
        [_spinner stopAnimating];
        _statusLabel.text = booted ? @"ESP is drawing — swipe down or tap Hide."
                                   : @"ESP is drawing, kernel still finishing.";
        [self setFooterLabel:MDThemeGreen()];
    } else if (booted) {
        // Kernel up, nothing painted yet. Still spinning, because this is the
        // window where the old wording said the run was complete. Amber for the
        // wait rather than green for a session that is not on screen yet.
        [_spinner startAnimating];
        _statusLabel.text = @"Kernel ready — ESP not on screen yet.";
        [self setFooterLabel:MDThemeOrange()];
    } else {
        [_spinner startAnimating];
        _statusLabel.text = @"Running — stay here until complete.";
        [self setFooterLabel:[UIColor colorWithWhite:0.62f alpha:1.0f]];
    }
}

- (void)hideTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat w = CGRectGetWidth(self.view.bounds);
    CGFloat h = CGRectGetHeight(self.view.bounds);

    CGFloat topH = 52.0f + insets.top;
    _barTop.frame = CGRectMake(0.0f, 0.0f, w, topH);

    UIView *topSep = [_barTop viewWithTag:8101];
    topSep.frame = CGRectMake(0.0f, CGRectGetHeight(_barTop.frame) - 1.0f, w, 1.0f);

    CGFloat hideW = 60.0f;
    _hideButton.frame = CGRectMake(w - hideW - 14.0f, insets.top + 8.0f, hideW, 36.0f);
    _titleLabel.frame = CGRectMake(0.0f, insets.top + 8.0f, w, 36.0f);

    CGFloat botH = 34.0f + insets.bottom;
    _barBottom.frame = CGRectMake(0.0f, h - botH, w, botH);

    UIView *botSep = [_barBottom viewWithTag:8102];
    botSep.frame = CGRectMake(0.0f, 0.0f, w, 1.0f);

    CGSize ss = _spinner.intrinsicContentSize;
    CGFloat sy = CGRectGetMinY(_barBottom.frame) + (botH - insets.bottom - ss.height) * 0.5f;
    _spinner.frame = CGRectMake(16.0f, sy, ss.width, ss.height);
    _statusLabel.frame = CGRectMake(CGRectGetMaxX(_spinner.frame) + 10.0f, sy - 2.0f,
                                    w - CGRectGetMaxX(_spinner.frame) - 26.0f, ss.height + 4.0f);

    _logView.frame = CGRectMake(0.0f, CGRectGetMaxY(_barTop.frame), w,
                                CGRectGetMinY(_barBottom.frame) - CGRectGetMaxY(_barTop.frame));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // The header card is the first thing in the log, so make sure nothing is
    // scrolled past it after the sheet settles.
    [_logView refresh];
}

@end