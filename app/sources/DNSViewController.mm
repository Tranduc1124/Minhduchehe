#import "DNSViewController.h"
#import "MDUI.h"
#import "MDTheme.h"

@implementation DNSViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DNS";
    self.view.backgroundColor = MDThemeBg();
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = MDThemePanel();
    card.layer.cornerRadius = 14.0f;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    icon.image = MDUISymbol(@"globe", 26.0f, UIFontWeightSemibold);
    icon.tintColor = MDThemeBlue();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:icon];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"No DNS yet";
    title.font = MDThemeFont(17.0f, UIFontWeightSemibold);
    title.textColor = MDThemeText();
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:title];

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectZero];
    body.text = @"This is not ready yet. It will let you change which DNS your device uses when it is.";
    body.font = MDThemeFont(14.0f, UIFontWeightRegular);
    body.textColor = MDThemeMuted();
    body.textAlignment = NSTextAlignmentCenter;
    body.numberOfLines = 0;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:body];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-40.0f],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24.0f],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24.0f],

        [icon.topAnchor constraintEqualToAnchor:card.topAnchor constant:24.0f],
        [icon.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:30.0f],
        [icon.heightAnchor constraintEqualToConstant:30.0f],

        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:14.0f],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0f],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0f],

        [body.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8.0f],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0f],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0f],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-24.0f],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
}

@end