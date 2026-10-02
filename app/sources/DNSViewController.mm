#import "DNSViewController.h"
#import "DNSProfile.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "MDLog.h"

// Label on the left, value on the right.
static UIView *MDDNSRow(NSString *title, UILabel **valueOut) {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.backgroundColor = MDThemePanel();

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.font = MDThemeFont(16.0f, UIFontWeightRegular);
    label.textColor = MDThemeText();
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];

    UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];
    value.font = MDThemeFont(16.0f, UIFontWeightRegular);
    value.textColor = MDThemeMuted();
    value.textAlignment = NSTextAlignmentRight;
    value.numberOfLines = 2;
    value.lineBreakMode = NSLineBreakByTruncatingTail;
    value.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:value];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0f],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [label.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:11.0f],

        [value.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0f],
        [value.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [value.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:11.0f],
        [value.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:12.0f],

        [row.heightAnchor constraintGreaterThanOrEqualToConstant:46.0f],
    ]];

    if (valueOut) *valueOut = value;
    return row;
}

static UILabel *MDDNSNote(NSString *text, UIFontWeight weight) {
    UILabel *note = [[UILabel alloc] initWithFrame:CGRectZero];
    note.text = text;
    note.font = MDThemeFont(13.0f, weight);
    note.textColor = MDThemeMuted();
    note.numberOfLines = 0;
    return note;
}

static UIView *MDDNSHairline(void) {
    UIView *line = [[UIView alloc] initWithFrame:CGRectZero];
    line.backgroundColor = MDThemeLine();
    [line.heightAnchor constraintEqualToConstant:1.0f / UIScreen.mainScreen.scale].active = YES;
    return line;
}

@interface DNSViewController ()
@property (nonatomic, strong) UILabel *configValue;
@property (nonatomic, strong) UILabel *errorValue;
@property (nonatomic, strong) UIView *errorRow;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) UILabel *outcome;
@end

@implementation DNSViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DNS";
    self.view.backgroundColor = MDThemeBg();

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    UIStackView *page = [[UIStackView alloc] initWithFrame:CGRectZero];
    page.axis = UILayoutConstraintAxisVertical;
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:page];

    // Card. A stack inside it, because a hidden arranged subview collapses
    // while hiding a constrained view only leaves its constraints in place and
    // the row above keeps the gap.
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = MDThemePanel();
    card.layer.cornerRadius = 14.0f;

    UIStackView *rows = [[UIStackView alloc] initWithFrame:CGRectZero];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:rows];

    UILabel *config = nil;
    UIView *configRow = MDDNSRow(@"iOS configuration", &config);
    _configValue = config;

    UILabel *errorLabel = nil;
    UIView *errorRow = MDDNSRow(@"Error", &errorLabel);
    _errorRow = errorRow;
    _errorValue = errorLabel;
    _errorValue.textColor = MDThemeRed();

    UILabel *note = MDDNSNote(@"Selected reflects the iOS DNS preference; it does not "
                             @"confirm routing for every connection.", UIFontWeightRegular);
    // layoutMarginsRelativeArrangement is a UIStackView property, not a UILabel
    // one, so the inset has to come from a container the stack can measure.
    UIView *noteSlot = [[UIView alloc] initWithFrame:CGRectZero];
    noteSlot.backgroundColor = MDThemePanel();
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [noteSlot addSubview:note];
    [NSLayoutConstraint activateConstraints:@[
        [note.leadingAnchor constraintEqualToAnchor:noteSlot.leadingAnchor constant:16.0f],
        [note.trailingAnchor constraintEqualToAnchor:noteSlot.trailingAnchor constant:-16.0f],
        [note.topAnchor constraintEqualToAnchor:noteSlot.topAnchor constant:12.0f],
        [note.bottomAnchor constraintEqualToAnchor:noteSlot.bottomAnchor constant:-14.0f],
    ]];

    for (UIView *view in @[ configRow, MDDNSHairline(), errorRow, MDDNSHairline(), noteSlot ]) {
        [rows addArrangedSubview:view];
    }
    _errorRow.hidden = YES;

    _installButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_installButton setTitle:@"Install DNS" forState:UIControlStateNormal];
    [_installButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_installButton setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.55f]
                         forState:UIControlStateDisabled];
    _installButton.titleLabel.font = MDThemeFont(17.0f, UIFontWeightSemibold);
    _installButton.backgroundColor = MDThemeAccent();
    _installButton.layer.cornerRadius = 14.0f;
    _installButton.clipsToBounds = YES;
    [_installButton.heightAnchor constraintEqualToConstant:50.0f].active = YES;
    [_installButton addTarget:self
                       action:@selector(installTapped)
             forControlEvents:UIControlEventTouchUpInside];

    _outcome = MDDNSNote(@"", UIFontWeightSemibold);
    _outcome.textColor = MDThemeText();
    _outcome.textAlignment = NSTextAlignmentCenter;

    // What the payload does, read from the file. Stating it on the screen is
    // the difference between "a profile is installed" and "these domains now
    // resolve and those do not".
    UILabel *effect = MDDNSNote([NSString stringWithFormat:
                                 @"FF Fix Ban ID (DNS iOS) sends %@ to Cloudflare over "
                                 @"DoH and points %lu other domain(s) at an address "
                                 @"that does not exist, so they do not resolve.",
                                 [MDDNSServerList().firstObject ?: @"its resolver"
                                     stringByReplacingOccurrencesOfString:@"https://"
                                                                   withString:@""],
                                 (unsigned long)MDDNSBlockedDomainCount()],
                                UIFontWeightRegular);
    effect.textAlignment = NSTextAlignmentCenter;

    UILabel *footnote = MDDNSNote(@"After installation, open iOS Settings > General > "
                                  @"VPN & Device Management > FF Fix Ban ID (DNS iOS) "
                                  @"and switch it on. iOS does not let this app open "
                                  @"that page for you.",
                                  UIFontWeightRegular);
    footnote.textAlignment = NSTextAlignmentCenter;

    for (UIView *view in @[ card, _installButton, _outcome, effect, footnote ]) {
        [page addArrangedSubview:view];
        [view setContentHuggingPriority:UILayoutPriorityDefaultLow
                                forAxis:UILayoutConstraintAxisVertical];
    }
    [page setCustomSpacing:14.0f afterView:card];
    [page setCustomSpacing:14.0f afterView:_installButton];
    [page setCustomSpacing:6.0f afterView:_outcome];
    [page setCustomSpacing:14.0f afterView:effect];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [page.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16.0f],
        [page.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [page.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [page.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24.0f],
        [page.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        [rows.topAnchor constraintEqualToAnchor:card.topAnchor],
        [rows.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],

        [_outcome.heightAnchor constraintGreaterThanOrEqualToConstant:18.0f],
    ]];

    [self reload];
}

- (void)reload {
    NSString *why = nil;
    // Reading /var/mobile needs the sandbox gone, which only happens once the
    // exploit has run. Until then the row says so instead of guessing.
    NSString *state = MDDNSProbeConfiguration(&why);
    _configValue.text = state;
    _configValue.textColor = [state isEqualToString:@"Installed"] ? MDThemeGreen() : MDThemeText();

    if (why.length) {
        _errorRow.hidden = NO;
        _errorValue.text = why;
    } else {
        _errorRow.hidden = YES;
        _errorValue.text = @"none";
    }
}

- (void)installTapped {
    _installButton.enabled = NO;
    [_installButton setTitle:@"Working…" forState:UIControlStateNormal];
    _outcome.text = @"";

    [MDLog appendLine:@"RUN Installing DNS."];

    MDDNSInstall(^(MDDNSInstallOutcome outcome, NSString *failure, NSString *url) {
        [MDLog appendLine:(outcome == MDDNSInstallOutcomeFailed)
                    ? @"ERR DNS install failed."
                    : @"OK DNS profile reached iOS."];
        if (failure.length) [MDLog appendLine:failure];

        self.installButton.enabled = YES;
        [self.installButton setTitle:@"Install DNS" forState:UIControlStateNormal];

        switch (outcome) {
            case MDDNSInstallOutcomeInstalled:
                self.outcome.text = @"Installed. Switch it on in iOS Settings.";
                break;
            case MDDNSInstallOutcomeHandedOff:
                self.outcome.text = @"iOS is asking to install it — tap Install.";
                break;
            case MDDNSInstallOutcomeFailed:
                self.outcome.text = @"Could not install. The Log tab has why.";
                break;
        }
        [self reload];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    [self reload];
}

@end