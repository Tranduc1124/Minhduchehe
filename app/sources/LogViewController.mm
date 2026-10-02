#import "LogViewController.h"
#import "MDLogView.h"
#import "MDUI.h"
#import "MDTheme.h"

@interface LogViewController ()
@property (nonatomic, strong) MDLogView *logView;
@end

@implementation LogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Log";
    self.view.backgroundColor = MDThemeBg();
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);

    _logView = [[MDLogView alloc] initWithFrame:CGRectZero];
    // Pinned to the safe area, not to a frame worked out from safeAreaInsets.
    // That inset is the status bar on its own and stops short of the
    // navigation bar, so the console started under the bar and the top of the
    // header card was hidden behind it.
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_logView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_logView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    [_logView refresh];
}

@end