#import "BootLogViewController.h"
#import "MDLogView.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "MDLog.h"

#import <QuartzCore/QuartzCore.h>

// Startup console, presented as a sheet over the Game tab when the user taps
// Activate: a light header bar with the title and Hide, and the shared MDLogView
// filling everything below it.
//
// Nothing else. There was a footer here with a spinner and a one-line state, and
// it was restyled three times before it was removed: coloured by state, then a
// flat grey with a coloured sentence, then a shorter grey. The log already says
// what happened, line by line, and the Game tab behind this sheet says whether
// the ESP is actually drawing.
//
// Hiding it does not stop the boot. kernelBootStart() runs on its own queue
// and keeps writing into MDLog either way, so the Log tab picks the lines up
// whether this sheet is up or not.
@interface BootLogViewController ()
@property (nonatomic, strong) UIView *barTop;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *hideButton;
@property (nonatomic, strong) MDLogView *logView;
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
    // It runs to the bottom of the sheet. There was a footer strip here carrying
    // a spinner and a state sentence, and it was tried three ways -- washed with
    // the state colour, then a fixed grey with a coloured sentence, then grey and
    // shorter -- and it was not wanted in any of them. So it is gone rather than
    // restyled again.
    //
    // The state is not lost with it. The log carries every step of the boot as it
    // happens, the last line of a run says whether the ESP host started, and the
    // Game tab behind this sheet has its own card that only says Active once a
    // frame has actually been drawn.
    _logView = [[MDLogView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_logView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_logView refresh];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
}

- (void)dealloc {
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

    _logView.frame = CGRectMake(0.0f, CGRectGetMaxY(_barTop.frame), w,
                                h - insets.bottom - CGRectGetMaxY(_barTop.frame));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // The header card is the first thing in the log, so make sure nothing is
    // scrolled past it after the sheet settles.
    [_logView refresh];
}

@end