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
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat top = insets.top > 0 ? insets.top : 44.0f;
    CGFloat bottom = self.tabBarController ? CGRectGetMinY(self.tabBarController.tabBar.frame)
                                           : CGRectGetHeight(self.view.bounds);
    _logView.frame = CGRectMake(0.0f, top, CGRectGetWidth(self.view.bounds),
                                MAX(0.0f, bottom - top));
}

@end