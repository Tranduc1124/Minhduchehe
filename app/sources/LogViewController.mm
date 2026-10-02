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
    [self.view addSubview:_logView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    [_logView refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // The console runs right up under the navigation bar. Laying it out from
    // safeAreaInsets.top instead left a band of the app's light background
    // between the bar and the top of the console, which read as a second bar.
    // The child view spans the whole screen and the bar is drawn over it, so
    // the bar's bottom edge is the top of the console.
    CGFloat top = self.view.safeAreaInsets.top;
    UIView *barParent = self.navigationController.navigationBar.superview;
    if (barParent) {
        CGRect inSelf = [self.view convertRect:self.navigationController.navigationBar.bounds
                                      fromView:barParent];
        if (CGRectGetHeight(inSelf) > 0.0f) top = CGRectGetMaxY(inSelf);
    }

    CGFloat bottom = self.tabBarController ? CGRectGetMinY(self.tabBarController.tabBar.frame)
                                           : CGRectGetHeight(self.view.bounds);
    _logView.frame = CGRectMake(0.0f, top, CGRectGetWidth(self.view.bounds),
                                MAX(0.0f, bottom - top));
}

@end