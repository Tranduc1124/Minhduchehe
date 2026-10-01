#import "HomeViewController.h"
#import "HUDHelper.h"
#import "rootless.h"
#import "pid.h"
#import "ESPPrefs.h"
#import "esp.h"
#import "GameOffsets.h"
#import "roothide/varCleanController.h"
#import "MDTheme.h"
#import "AppSettingsViewController.h"
#import "../KernelBoot.h"

// C function-pointer log sink — defined after class extension (needs selector)
static HomeViewController *g_activeLogVC = nil;
static void HomeVCBootLogSink(NSString *line);

#import <QuartzCore/QuartzCore.h>
#import <SafariServices/SafariServices.h>

// Icon menu cho iPad (không bị kẹt nửa màn hình)
static const CGFloat kMenuButtonSize = 56.0f;

@interface HomeViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;

@property (nonatomic, strong) UILabel *titleLabel;

@property (nonatomic, strong) UIView *controlCard;
@property (nonatomic, strong) UIImageView *controlIconView;
@property (nonatomic, strong) UILabel *controlTitleLabel;
@property (nonatomic, strong) UILabel *controlSubtitleLabel;
@property (nonatomic, strong) UIButton *startButton;

@property (nonatomic, strong) UIView *togglesCard;
@property (nonatomic, strong) UILabel *aimbotLabel;
@property (nonatomic, strong) UISwitch *aimbotSwitch;
@property (nonatomic, strong) UILabel *espLabel;
@property (nonatomic, strong) UISwitch *espSwitch;
@property (nonatomic, strong) UILabel *camLabel;
@property (nonatomic, strong) UISwitch *camSwitch;
@property (nonatomic, strong) UISlider *camSlider;
@property (nonatomic, strong) UILabel *camValueLabel;

@property (nonatomic, strong) UILabel *versionSectionLabel;
@property (nonatomic, strong) UIButton *ffMaxCard;
@property (nonatomic, strong) UIButton *ffCard;
@property (nonatomic, strong) UIImageView *ffMaxIconView;
@property (nonatomic, strong) UIImageView *ffIconView;
@property (nonatomic, strong) UILabel *ffMaxNameLabel;
@property (nonatomic, strong) UILabel *ffNameLabel;

@property (nonatomic, strong) UIView *statusCard;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *openGameButton;

@property (nonatomic, strong) UIView *licenseCard;
@property (nonatomic, strong) UILabel *licenseTitleLabel;
@property (nonatomic, strong) UILabel *licenseValueLabel;

@property (nonatomic, strong) UIView *authCard;
@property (nonatomic, strong) UILabel *authTitleLabel;
@property (nonatomic, strong) UILabel *authValueLabel;

@property (nonatomic, strong) UIView *supportCard;
@property (nonatomic, strong) UILabel *supportTitleLabel;
@property (nonatomic, strong) UILabel *supportSubtitleLabel;
@property (nonatomic, strong) UIButton *joinButton;

@property (nonatomic, strong) UIView *extraCard;
@property (nonatomic, strong) UILabel *autoCleanLabel;
@property (nonatomic, strong) UISwitch *autoCleanSwitch;
@property (nonatomic, strong) UILabel *authorizationLabel;
@property (nonatomic, strong) UIButton *authorizationButton;
@property (nonatomic, strong) UIButton *settingsBtn;
@property (nonatomic, strong) UIView *logCard;
@property (nonatomic, strong) UITextView *logTextView;
- (void)appendBootLog:(NSString *)line;
@property (nonatomic, strong) UIButton *trashBtn;

@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) NSInteger gameMissingStreak;
@property (nonatomic, assign) CFTimeInterval pendingHUDEnableUntil;
@property (nonatomic, assign) NSInteger hudRequestSerial;
@end

@implementation HomeViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    MDThemeLoadFromPrefs();
    [self buildUI];
    _gameMissingStreak = 0;
    _pendingHUDEnableUntil = 0;
    _hudRequestSerial = 0;

    GameOffsetsReload();
    [self updateVersionSelectionUI];
    [self updateAuthorizationPresentation];
    [self refreshHUDState];
    [self applyTheme];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appBecameActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyTheme)
                                                 name:MDThemeDidChangeNotification
                                               object:nil];

    [self startPollingGameState];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_pollTimer invalidate];
}

#pragma mark - Helpers

- (UIColor *)cardBackground {
    return MDThemePanel();
}

- (UIColor *)accentGreen {
    return MDThemeAccent();
}

- (UIColor *)accentBlue {
    return MDThemeBlue();
}

- (UIColor *)accentOrange {
    return MDThemeOrange();
}

- (void)openSettings {
    AppSettingsViewController *vc = [[AppSettingsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)openVarClean {
    varCleanController *vc = [varCleanController sharedInstance];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)applyTheme {
    MDThemeLoadFromPrefs();
    self.view.backgroundColor = MDThemeBg();
    _titleLabel.textColor = MDThemeText();
    _titleLabel.font = MDThemeFont(30, UIFontWeightBold);
    _controlCard.backgroundColor = MDThemePanel();
    _controlCard.layer.borderColor = MDThemeLine().CGColor;
    _controlCard.layer.borderWidth = 1.0f;
    _controlTitleLabel.textColor = MDThemeText();
    _controlSubtitleLabel.textColor = MDThemeMuted();
    _startButton.backgroundColor = MDThemeAccent();
    _versionSectionLabel.textColor = MDThemeMuted();
    _ffMaxCard.backgroundColor = MDThemePanel();
    _ffCard.backgroundColor = MDThemePanel();
    _ffMaxNameLabel.textColor = MDThemeText();
    _ffNameLabel.textColor = MDThemeText();
    _statusCard.backgroundColor = MDThemePanel();
    _statusCard.layer.borderColor = MDThemeLine().CGColor;
    _statusCard.layer.borderWidth = 1.0f;
    _statusLabel.textColor = MDThemeText();
    _openGameButton.backgroundColor = MDThemeOrange();
    _licenseCard.backgroundColor = MDThemePanel();
    _licenseCard.layer.borderColor = MDThemeLine().CGColor;
    _licenseCard.layer.borderWidth = 1.0f;
    _authCard.backgroundColor = MDThemePanel();
    _authCard.layer.borderColor = MDThemeLine().CGColor;
    _authCard.layer.borderWidth = 1.0f;
    _licenseTitleLabel.textColor = MDThemeMuted();
    _licenseValueLabel.textColor = MDThemeText();
    _authTitleLabel.textColor = MDThemeMuted();
    _supportCard.backgroundColor = MDThemePanel();
    _supportCard.layer.borderColor = MDThemeLine().CGColor;
    _supportCard.layer.borderWidth = 1.0f;
    _supportTitleLabel.textColor = MDThemeText();
    _supportSubtitleLabel.textColor = MDThemeMuted();
    _joinButton.backgroundColor = MDThemeBlue();
    _extraCard.backgroundColor = MDThemePanel();
    _extraCard.layer.borderColor = MDThemeLine().CGColor;
    _extraCard.layer.borderWidth = 1.0f;
    _autoCleanLabel.textColor = MDThemeText();
    _autoCleanSwitch.onTintColor = MDThemeAccent();
    [_authorizationButton setTitleColor:MDThemeAccent() forState:UIControlStateNormal];
    _settingsBtn.backgroundColor = MDThemePanel2();
    _settingsBtn.layer.borderColor = MDThemeLine().CGColor;
    _settingsBtn.tintColor = MDThemeText();
    _trashBtn.backgroundColor = MDThemePanel2();
    _trashBtn.layer.borderColor = MDThemeLine().CGColor;
    _trashBtn.tintColor = MDThemeText();
    if (self.tabBarController) MDThemeApplyToTabBar(self.tabBarController.tabBar);
    [self updateVersionSelectionUI];
    [self updateAuthorizationPresentation];
    [self refreshHUDState];
}

- (UIImage *)imageNamedWebPOrPNG:(NSString *)baseName {
    UIImage *img = [UIImage imageNamed:baseName];
    if (img) return img;
    NSString *path = [[NSBundle mainBundle] pathForResource:baseName ofType:@"webp"];
    if (path.length) {
        img = [UIImage imageWithContentsOfFile:path];
        if (img) return img;
    }
    path = [[NSBundle mainBundle] pathForResource:baseName ofType:@"png"];
    if (path.length) {
        img = [UIImage imageWithContentsOfFile:path];
    }
    return img;
}

- (UIView *)makeCard {
    UIView *card = MDThemeMakeCard();
    return card;
}

- (UIButton *)makeVersionCardCapturingIcon:(UIImageView * __strong *)outIcon
                                 nameLabel:(UILabel * __strong *)outName {
    UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.backgroundColor = [self cardBackground];
    card.layer.cornerRadius = 14.0f;
    card.clipsToBounds = YES;
    card.layer.borderWidth = 2.0f;
    card.layer.borderColor = [UIColor clearColor].CGColor;
    card.adjustsImageWhenHighlighted = NO;

    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    icon.contentMode = UIViewContentModeScaleAspectFill;
    icon.clipsToBounds = YES;
    icon.layer.cornerRadius = 10.0f;
    icon.userInteractionEnabled = NO;
    [card addSubview:icon];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    name.textColor = [UIColor whiteColor];
    name.textAlignment = NSTextAlignmentCenter;
    name.userInteractionEnabled = NO;
    [card addSubview:name];

    if (outIcon) *outIcon = icon;
    if (outName) *outName = name;
    return card;
}

#pragma mark - Authorization

- (void)beginAuthorization {
    [self updateAuthorizationPresentation];
    [self refreshHUDState];
}

- (void)retryAuthorization:(id)sender {
    (void)sender;
    [self beginAuthorization];
}

- (void)revokeAuthorization {
    SetHUDEnabled(NO);
    [self updateAuthorizationPresentation];
    [self refreshHUDState];
}

- (void)updateAuthorizationPresentation {
    if (!self.isViewLoaded) {
        return;
    }

    _authorizationLabel.text = @"No key required";
    [_authorizationButton setTitle:@"Unlocked" forState:UIControlStateNormal];
    _authorizationButton.enabled = NO;
    _licenseValueLabel.text = @"Unlimited";
    _authValueLabel.text = @"Hoạt động";
    _authValueLabel.textColor = MDThemeAccent();
    _authorizationLabel.textColor = MDThemeText();
    _autoCleanSwitch.enabled = YES;
    _autoCleanLabel.alpha = 1.0;
    _startButton.alpha = 1.0;
}

#pragma mark - UI

- (void)buildUI {
    self.view.backgroundColor = MDThemeBg();

    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:_scrollView];

    _contentView = [[UIView alloc] initWithFrame:CGRectZero];
    [_scrollView addSubview:_contentView];

    _settingsBtn = MDThemeMakeSettingsButton(self, @selector(openSettings));
    _trashBtn = MDThemeMakeTrashButton(self, @selector(openVarClean));
    [self.view addSubview:_settingsBtn];
    [self.view addSubview:_trashBtn];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = @"Trang chủ";
    _titleLabel.font = MDThemeFont(30, UIFontWeightBold);
    _titleLabel.textColor = MDThemeText();
    [_contentView addSubview:_titleLabel];

    // Control card
    _controlCard = [self makeCard];
    [_contentView addSubview:_controlCard];

    _controlIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _controlIconView.contentMode = UIViewContentModeScaleAspectFill;
    _controlIconView.clipsToBounds = YES;
    _controlIconView.layer.cornerRadius = 12.0f;
    _controlIconView.image = [self imageNamedWebPOrPNG:@"ff"] ?: [UIImage imageNamed:@"logo"];
    _controlIconView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    [_controlCard addSubview:_controlIconView];

    _controlTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _controlTitleLabel.text = @"Điều khiển HUD";
    _controlTitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _controlTitleLabel.textColor = [UIColor whiteColor];
    [_controlCard addSubview:_controlTitleLabel];

    _controlSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _controlSubtitleLabel.text = @"Nhấn Bắt đầu khi game đã mở";
    _controlSubtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _controlSubtitleLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _controlSubtitleLabel.numberOfLines = 2;
    [_controlCard addSubview:_controlSubtitleLabel];

    _startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _startButton.backgroundColor = [self accentGreen];
    _startButton.layer.cornerRadius = 16.0f;
    _startButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [_startButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_startButton setTitle:@"Bắt đầu" forState:UIControlStateNormal];
    [_startButton addTarget:self action:@selector(startButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_controlCard addSubview:_startButton];

    // Quick toggles card — Aimbot + ESP on/off right from Home (no HUD draw
    // needed to flip the cheat; ESP_View reads prefs every frame).
    _togglesCard = [self makeCard];
    [_contentView addSubview:_togglesCard];

    _aimbotLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _aimbotLabel.text = @"Aimbot";
    _aimbotLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _aimbotLabel.textColor = [UIColor whiteColor];
    [_togglesCard addSubview:_aimbotLabel];

    _aimbotSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _aimbotSwitch.onTintColor = [self accentGreen];
    _aimbotSwitch.on = ESPPrefsBool(@"Aimbot", NO);
    [_aimbotSwitch addTarget:self action:@selector(aimbotSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [_togglesCard addSubview:_aimbotSwitch];

    _espLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _espLabel.text = @"ESP";
    _espLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _espLabel.textColor = [UIColor whiteColor];
    [_togglesCard addSubview:_espLabel];

    _espSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _espSwitch.onTintColor = [self accentGreen];
    _espSwitch.on = ESPPrefsBool(@"EnableESP", YES);
    [_espSwitch addTarget:self action:@selector(espSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [_togglesCard addSubview:_espSwitch];

    _camLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _camLabel.text = @"Camera Xa (CamPC)";
    _camLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _camLabel.textColor = [UIColor whiteColor];
    [_togglesCard addSubview:_camLabel];

    _camSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _camSwitch.onTintColor = [self accentGreen];
    _camSwitch.on = ESPPrefsBool(@"CamPC", NO);
    [_camSwitch addTarget:self action:@selector(camSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [_togglesCard addSubview:_camSwitch];

    // CamPC distance slider (0-150, default 30 — matches ESPPrefs default)
    _camSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _camSlider.minimumValue = 0.0f;
    _camSlider.maximumValue = 150.0f;
    _camSlider.value = ESPPrefsFloat(@"CamPCValue", 30.0f);
    _camSlider.minimumTrackTintColor = [self accentGreen];
    [_camSlider addTarget:self action:@selector(camSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_togglesCard addSubview:_camSlider];

    _camValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _camValueLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _camValueLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    _camValueLabel.text = [NSString stringWithFormat:@"%.0f", _camSlider.value];
    [_togglesCard addSubview:_camValueLabel];

    // Boot log card (Fl0rk-style console)
    _logCard = [self makeCard];
    [_contentView addSubview:_logCard];

    _logTextView = [[UITextView alloc] initWithFrame:CGRectZero];
    _logTextView.editable = NO;
    _logTextView.scrollEnabled = YES;
    _logTextView.showsHorizontalScrollIndicator = NO;
    _logTextView.backgroundColor = [UIColor colorWithRed:0.02 green:0.05 blue:0.03 alpha:1.0];
    _logTextView.layer.cornerRadius = 10.0f;
    _logTextView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _logTextView.textColor = [UIColor colorWithRed:0.55 green:0.95 blue:0.6 alpha:1.0];
    _logTextView.text = @"[MINHDUC] ready.\nPress Bắt đầu to boot kernel.";
    [_logCard addSubview:_logTextView];

    // Version section
    _versionSectionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _versionSectionLabel.text = @"Lựa chọn phiên bản:";
    _versionSectionLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _versionSectionLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [_contentView addSubview:_versionSectionLabel];

    UIImageView *ffMaxIcon = nil;
    UILabel *ffMaxName = nil;
    _ffMaxCard = [self makeVersionCardCapturingIcon:&ffMaxIcon nameLabel:&ffMaxName];
    _ffMaxIconView = ffMaxIcon;
    _ffMaxNameLabel = ffMaxName;
    _ffMaxIconView.image = [self imageNamedWebPOrPNG:@"ffmax"] ?: [UIImage imageNamed:@"logo"];
    _ffMaxNameLabel.text = @"Free Fire MAX";
    _ffMaxCard.tag = 2;
    [_ffMaxCard addTarget:self action:@selector(versionCardTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:_ffMaxCard];

    UIImageView *ffIcon = nil;
    UILabel *ffName = nil;
    _ffCard = [self makeVersionCardCapturingIcon:&ffIcon nameLabel:&ffName];
    _ffIconView = ffIcon;
    _ffNameLabel = ffName;
    _ffIconView.image = [self imageNamedWebPOrPNG:@"ff"] ?: [UIImage imageNamed:@"logo"];
    _ffNameLabel.text = @"Free Fire";
    _ffCard.tag = 1;
    [_ffCard addTarget:self action:@selector(versionCardTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_contentView addSubview:_ffCard];

    // Status card
    _statusCard = [self makeCard];
    [_contentView addSubview:_statusCard];

    _statusDot = [[UIView alloc] initWithFrame:CGRectZero];
    _statusDot.layer.cornerRadius = 5.0f;
    _statusDot.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1.0];
    [_statusCard addSubview:_statusDot];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.text = @"Trạng thái · Game chưa chạy";
    [_statusCard addSubview:_statusLabel];

    _openGameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _openGameButton.backgroundColor = [self accentOrange];
    _openGameButton.layer.cornerRadius = 14.0f;
    _openGameButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [_openGameButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_openGameButton setTitle:@"Vào Game" forState:UIControlStateNormal];
    [_openGameButton addTarget:self action:@selector(openGameTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_statusCard addSubview:_openGameButton];

    // License + auth side cards
    _licenseCard = [self makeCard];
    [_contentView addSubview:_licenseCard];
    _licenseTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _licenseTitleLabel.text = @"Giấy phép";
    _licenseTitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _licenseTitleLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [_licenseCard addSubview:_licenseTitleLabel];
    _licenseValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _licenseValueLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _licenseValueLabel.textColor = [UIColor whiteColor];
    _licenseValueLabel.numberOfLines = 3;
    _licenseValueLabel.text = @"—";
    [_licenseCard addSubview:_licenseValueLabel];

    _authCard = [self makeCard];
    [_contentView addSubview:_authCard];
    _authTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _authTitleLabel.text = @"Trạng thái";
    _authTitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _authTitleLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [_authCard addSubview:_authTitleLabel];
    _authValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _authValueLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _authValueLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    _authValueLabel.numberOfLines = 2;
    _authValueLabel.text = @"—";
    [_authCard addSubview:_authValueLabel];

    // Support
    _supportCard = [self makeCard];
    [_contentView addSubview:_supportCard];
    _supportTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _supportTitleLabel.text = @"Liên hệ hỗ trợ";
    _supportTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _supportTitleLabel.textColor = [UIColor whiteColor];
    [_supportCard addSubview:_supportTitleLabel];
    _supportSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _supportSubtitleLabel.text = @"Nhấn Join để nhận hỗ trợ";
    _supportSubtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _supportSubtitleLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [_supportCard addSubview:_supportSubtitleLabel];
    _joinButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _joinButton.backgroundColor = [self accentBlue];
    _joinButton.layer.cornerRadius = 14.0f;
    _joinButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [_joinButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_joinButton setTitle:@"Join" forState:UIControlStateNormal];
    [_joinButton addTarget:self action:@selector(joinSupportTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_supportCard addSubview:_joinButton];

    // Extra: VarClean + auth retry (kept features)
    _extraCard = [self makeCard];
    [_contentView addSubview:_extraCard];

    _autoCleanLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _autoCleanLabel.text = @"VarClean before HUD";
    _autoCleanLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _autoCleanLabel.textColor = [UIColor colorWithWhite:0.9f alpha:1.0f];
    [_extraCard addSubview:_autoCleanLabel];

    _autoCleanSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _autoCleanSwitch.onTintColor = MDThemeAccent();
    _autoCleanSwitch.on = ESPPrefsBool(@"AutoVarCleanBeforeHUD", NO);
    [_autoCleanSwitch addTarget:self action:@selector(autoCleanSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [_extraCard addSubview:_autoCleanSwitch];

    _authorizationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _authorizationLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _authorizationLabel.textAlignment = NSTextAlignmentLeft;
    [_extraCard addSubview:_authorizationLabel];

    _authorizationButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _authorizationButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [_authorizationButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_authorizationButton addTarget:self action:@selector(retryAuthorization:) forControlEvents:UIControlEventTouchUpInside];
    [_extraCard addSubview:_authorizationButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    _scrollView.frame = self.view.bounds;

    CGFloat gear = 36.0f;
    _settingsBtn.frame = CGRectMake(width - insets.right - 16 - gear, insets.top + 8, gear, gear);
    _trashBtn.frame = CGRectMake(CGRectGetMinX(_settingsBtn.frame) - 10 - gear, insets.top + 8, gear, gear);

    CGFloat contentW = width;
    CGFloat xPad = 16.0f;
    CGFloat cardW = contentW - xPad * 2.0f;
    CGFloat y = insets.top + 52.0f;

    _titleLabel.frame = CGRectMake(xPad + 6, y, cardW - 12 - 80, 40);
    y = CGRectGetMaxY(_titleLabel.frame) + 14;

    // Control card
    CGFloat controlH = 86.0f;
    _controlCard.frame = CGRectMake(xPad, y, cardW, controlH);

    // === FIX ICON MENU CHO IPAD ===
    // Trên iPad (safeArea + notch) icon cũ 54x54 bị "chôn" nửa màn hình.
    // Resize động theo card + clamp 48..56 để luôn hiện đủ.
    CGFloat iconSize = MIN(kMenuButtonSize, MIN(cardW * 0.42f, controlH * 0.85f));
    iconSize = MAX(48.0f, iconSize);
    _controlIconView.frame = CGRectMake(14, (controlH - iconSize) * 0.5f, iconSize, iconSize);

    _startButton.frame = CGRectMake(cardW - 108, 26, 94, 34);
    CGFloat textX = 80;
    CGFloat textW = cardW - 108 - textX - 8;
    _controlTitleLabel.frame = CGRectMake(textX, 20, textW, 22);
    _controlSubtitleLabel.frame = CGRectMake(textX, 44, textW, 28);
    y = CGRectGetMaxY(_controlCard.frame) + 12;

    // Quick toggles card (Aimbot / ESP / CamPC + slider)
    CGFloat togglesH = 176.0f;
    _togglesCard.frame = CGRectMake(xPad, y, cardW, togglesH);
    _aimbotLabel.frame = CGRectMake(16, 14, 200, 24);
    _aimbotSwitch.frame = CGRectMake(cardW - 68, 10, 51, 31);
    _espLabel.frame = CGRectMake(16, 54, 200, 24);
    _espSwitch.frame = CGRectMake(cardW - 68, 50, 51, 31);
    _camLabel.frame = CGRectMake(16, 94, 200, 24);
    _camSwitch.frame = CGRectMake(cardW - 68, 90, 51, 31);
    _camSlider.frame = CGRectMake(16, 128, cardW - 90, 30);
    _camValueLabel.frame = CGRectMake(cardW - 64, 130, 48, 24);
    y = CGRectGetMaxY(_togglesCard.frame) + 12;

    // Boot log card
    CGFloat logH = 210.0f;
    _logCard.frame = CGRectMake(xPad, y, cardW, logH);
    _logTextView.frame = CGRectMake(10, 8, cardW - 20, logH - 16);
    y = CGRectGetMaxY(_logCard.frame) + 16;

    _versionSectionLabel.frame = CGRectMake(xPad + 4, y, cardW - 8, 20);
    y = CGRectGetMaxY(_versionSectionLabel.frame) + 10;

    CGFloat gap = 12.0f;
    CGFloat versionW = (cardW - gap) * 0.5f;
    CGFloat versionH = 128.0f;
    _ffMaxCard.frame = CGRectMake(xPad, y, versionW, versionH);
    _ffCard.frame = CGRectMake(xPad + versionW + gap, y, versionW, versionH);

    CGFloat iconSide = 64.0f;
    _ffMaxIconView.frame = CGRectMake((versionW - iconSide) * 0.5f, 18, iconSide, iconSide);
    _ffIconView.frame = CGRectMake((versionW - iconSide) * 0.5f, 18, iconSide, iconSide);
    _ffMaxNameLabel.frame = CGRectMake(8, 90, versionW - 16, 24);
    _ffNameLabel.frame = CGRectMake(8, 90, versionW - 16, 24);
    y = CGRectGetMaxY(_ffMaxCard.frame) + 14;

    // Status
    CGFloat statusH = 64.0f;
    _statusCard.frame = CGRectMake(xPad, y, cardW, statusH);
    _statusDot.frame = CGRectMake(16, 27, 10, 10);
    _openGameButton.frame = CGRectMake(cardW - 112, 15, 98, 34);
    _statusLabel.frame = CGRectMake(36, 18, cardW - 112 - 44, 28);
    y = CGRectGetMaxY(_statusCard.frame) + 12;

    // License / auth pair
    CGFloat halfW = (cardW - gap) * 0.5f;
    CGFloat halfH = 92.0f;
    _licenseCard.frame = CGRectMake(xPad, y, halfW, halfH);
    _authCard.frame = CGRectMake(xPad + halfW + gap, y, halfW, halfH);
    _licenseTitleLabel.frame = CGRectMake(14, 12, halfW - 28, 18);
    _licenseValueLabel.frame = CGRectMake(14, 36, halfW - 28, 46);
    _authTitleLabel.frame = CGRectMake(14, 12, halfW - 28, 18);
    _authValueLabel.frame = CGRectMake(14, 40, halfW - 28, 36);
    y = CGRectGetMaxY(_licenseCard.frame) + 12;

    // Support
    CGFloat supportH = 72.0f;
    _supportCard.frame = CGRectMake(xPad, y, cardW, supportH);
    _joinButton.frame = CGRectMake(cardW - 92, 19, 78, 34);
    _supportTitleLabel.frame = CGRectMake(16, 16, cardW - 120, 22);
    _supportSubtitleLabel.frame = CGRectMake(16, 40, cardW - 120, 18);
    y = CGRectGetMaxY(_supportCard.frame) + 12;

    // Extra
    CGFloat extraH = 96.0f;
    _extraCard.frame = CGRectMake(xPad, y, cardW, extraH);
    _autoCleanLabel.frame = CGRectMake(16, 16, cardW - 90, 22);
    CGSize sw = _autoCleanSwitch.intrinsicContentSize;
    _autoCleanSwitch.frame = CGRectMake(cardW - sw.width - 16, 14, sw.width, sw.height);
    _authorizationLabel.frame = CGRectMake(16, 52, cardW - 150, 28);
    _authorizationButton.frame = CGRectMake(cardW - 132, 52, 116, 28);
    y = CGRectGetMaxY(_extraCard.frame) + 24 + insets.bottom;

    _contentView.frame = CGRectMake(0, 0, contentW, MAX(y, height));
    _scrollView.contentSize = _contentView.bounds.size;
}

#pragma mark - Version selection

- (void)versionCardTapped:(UIButton *)sender {
    BOOL pickMax = (sender.tag == 2);
    NSString *gameId = pickMax ? @"ffmax" : @"ff";
    GameTargetSetSelectedId(gameId);
    [self updateVersionSelectionUI];
    [self refreshHUDState];
}

- (void)updateVersionSelectionUI {
    BOOL isMax = GameTargetIsMax();
    UIColor *selected = MDThemeAccent();
    UIColor *clear = [UIColor clearColor];

    _ffMaxCard.layer.borderWidth = 2.0f;
    _ffCard.layer.borderWidth = 2.0f;
    _ffMaxCard.layer.borderColor = (isMax ? selected : MDThemeLine()).CGColor;
    _ffCard.layer.borderColor = (!isMax ? selected : MDThemeLine()).CGColor;
    _ffMaxCard.backgroundColor = isMax ? MDThemePanel2() : MDThemePanel();
    _ffCard.backgroundColor = !isMax ? MDThemePanel2() : MDThemePanel();

    UIImage *icon = [self imageNamedWebPOrPNG:isMax ? @"ffmax" : @"ff"];
    if (icon) {
        _controlIconView.image = icon;
    }
}

#pragma mark - App lifecycle

- (void)appBecameActive {
    GameOffsetsReload();
    [self updateVersionSelectionUI];
    [self refreshHUDState];

}

#pragma mark - HUD / game

- (BOOL)isGameRunning {
    return GameTargetIsRunning();
}

- (void)startPollingGameState {
    __weak __typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   repeats:YES
                                                     block:^(NSTimer *timer) {
        [weakSelf refreshHUDState];
    }];
}

- (void)autoCleanSwitchChanged:(UISwitch *)sender {
    BOOL selectedValue = sender.on;
    ESPPrefsSetBool(@"AutoVarCleanBeforeHUD", selectedValue);
}

// Quick toggles — write pref + sync live ESP globals immediately.
// ESP_View's frame loop re-reads prefs every 1s, but ESPSyncFromPrefs
// makes the change land on the next frame without waiting.
- (void)aimbotSwitchChanged:(UISwitch *)sender {
    ESPPrefsSetBoolLive(@"Aimbot", sender.on);
    ESPSyncFromPrefs(); // declared in esp.h (extern "C")
}

- (void)espSwitchChanged:(UISwitch *)sender {
    ESPPrefsSetBoolLive(@"EnableESP", sender.on);
    ESPSyncFromPrefs();
}

- (void)camSwitchChanged:(UISwitch *)sender {
    ESPPrefsSetBoolLive(@"CamPC", sender.on);
    ESPSyncFromPrefs();
}

- (void)camSliderChanged:(UISlider *)sender {
    float v = sender.value;
    _camValueLabel.text = [NSString stringWithFormat:@"%.0f", v];
    ESPPrefsSetFloat(@"CamPCValue", v);
    ESPSyncFromPrefs();
}

- (void)startButtonTapped:(UIButton *)sender {
    (void)sender;
    BOOL hudOn = IsHUDEnabled();
    if (hudOn) {
        ++_hudRequestSerial;
        _pendingHUDEnableUntil = 0;
        SetHUDEnabled(NO);
        [self refreshHUDState];
        return;
    }

    // Cho phép bấm Bắt đầu dù game chưa chạy — HUD tự chờ FF.
    NSInteger requestSerial = ++_hudRequestSerial;
    _startButton.enabled = NO;
    [self startHUDForRequest:requestSerial];
}

- (void)startHUDForRequest:(NSInteger)requestSerial {
    _pendingHUDEnableUntil = CACurrentMediaTime() + 2.5;
    GameOffsetsReload();
    BOOL autoClean = ESPPrefsBool(@"AutoVarCleanBeforeHUD", NO);
    if (!autoClean) {
        // Fl0rk-style: run kernel boot, log vào card dưới nút Bắt đầu
        g_activeLogVC = self;
        kernelBootLog = HomeVCBootLogSink;
        kernelBootStart();
        self.startButton.enabled = YES;
        [self refreshHUDState];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[varCleanController sharedInstance] runVarCleanNowWithCompletion:^(BOOL authorized) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (requestSerial != self.hudRequestSerial ||
                    NO || !authorized) {
                    self.pendingHUDEnableUntil = 0;
                    [self refreshHUDState];
                    return;
                }
                SetHUDEnabled(YES);
                self.startButton.enabled = YES;
                [self refreshHUDState];
            });
        }];
    });
}

- (void)openGameTapped:(id)sender {
    (void)sender;
    // iOS Free Fire TH / Max common bundle IDs (best-effort open).
    NSString *bundleId = GameTargetIsMax() ? @"com.dts.freefiremax" : @"vn.vng.freefireth";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", bundleId]];
    UIApplication *app = [UIApplication sharedApplication];
    if ([app canOpenURL:url]) {
        [app openURL:url options:@{} completionHandler:nil];
        return;
    }
    // Fallback schemes sometimes used on sideload/jailbreak installs.
    NSArray<NSString *> *fallbacks = GameTargetIsMax()
        ? @[ @"freefiremax://", @"ffmax://" ]
        : @[ @"freefireth://", @"freefire://" ];
    for (NSString *scheme in fallbacks) {
        NSURL *u = [NSURL URLWithString:scheme];
        if ([app canOpenURL:u]) {
            [app openURL:u options:@{} completionHandler:nil];
            return;
        }
    }
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Không mở được game"
                                            message:@"Hãy mở Free Fire / Free Fire MAX thủ công, rồi quay lại nhấn Bắt đầu."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)joinSupportTapped:(id)sender {
    (void)sender;
    NSURL *url = [NSURL URLWithString:@"https://t.me/"];
    if (!url) return;
    if (@available(iOS 9.0, *)) {
        SFSafariViewController *svc = [[SFSafariViewController alloc] initWithURL:url];
        [self presentViewController:svc animated:YES completion:nil];
    } else {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

// C function-pointer log sink — KernelBoot calls this from background queue.
// Logs vào card dưới nút Bắt đầu (không popup).
static void HomeVCBootLogSink(NSString *line) {
    dispatch_async(dispatch_get_main_queue(), ^{
        HomeViewController *vc = g_activeLogVC;
        if (!vc) return;
        [vc appendBootLog:line];
    });
}

- (void)appendBootLog:(NSString *)line {
    static NSMutableString *bootText;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bootText = [NSMutableString new]; });
    [bootText appendFormat:@"%@\n", line];
    if (bootText.length > 8000) [bootText deleteCharactersInRange:NSMakeRange(0, bootText.length - 8000)];
    NSString *snap = [bootText copy];
    self.logTextView.text = snap;
    [self.logTextView scrollRangeToVisible:NSMakeRange(snap.length, 0)];
}

- (void)refreshHUDState {
    if (!self.isViewLoaded) {
        return;
    }

    GameOffsetsReload();

    if (NO) {
        [_startButton setTitle:@"Bắt đầu" forState:UIControlStateNormal];
        _startButton.enabled = NO;
        _startButton.alpha = 0.55;
        _controlSubtitleLabel.alpha = 0.55;
        _statusDot.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1.0];
        _statusLabel.text = @"Trạng thái · Cần authorization";
        return;
    }

    BOOL gameIsRunning = [self isGameRunning];
    BOOL hudIsEnabled = IsHUDEnabled();
    // sysctl pid can blip for a few polls when game is foregrounding — don't kill HUD so fast.
    _gameMissingStreak = gameIsRunning ? 0 : _gameMissingStreak + 1;
    BOOL gameIsAvailable = gameIsRunning || _gameMissingStreak < 8;

    if (gameIsRunning) {
        _statusDot.backgroundColor = [self accentGreen];
        NSString *name = GameTargetIsMax() ? @"Free Fire MAX" : @"Free Fire";
        _statusLabel.text = [NSString stringWithFormat:@"Trạng thái · %@ đang chạy", name];
    } else {
        _statusDot.backgroundColor = [UIColor colorWithRed:0.9 green:0.25 blue:0.25 alpha:1.0];
        _statusLabel.text = @"Trạng thái · Game chưa chạy";
    }

    if (!gameIsAvailable) {
        // KHÔNG kill HUD + KHÔNG khóa nút theo game state — bấm Bắt đầu bất cứ lúc nào.
        [_startButton setTitle:@"Bắt đầu" forState:UIControlStateNormal];
        _startButton.enabled = YES;
        _startButton.alpha = 1.0;
        _controlSubtitleLabel.alpha = 1.0;
        _pendingHUDEnableUntil = 0;
        return;
    }

    _startButton.enabled = YES;
    _startButton.alpha = 1.0;
    _controlSubtitleLabel.alpha = 1.0;

    CFTimeInterval now = CACurrentMediaTime();
    BOOL isWithinEnableGracePeriod = _pendingHUDEnableUntil > 0 && now < _pendingHUDEnableUntil;
    if (!hudIsEnabled && isWithinEnableGracePeriod) {
        [_startButton setTitle:@"Đang bật…" forState:UIControlStateNormal];
        return;
    }

    if (hudIsEnabled) {
        _pendingHUDEnableUntil = 0;
        [_startButton setTitle:@"Tắt HUD" forState:UIControlStateNormal];
        _startButton.backgroundColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    } else {
        [_startButton setTitle:@"Bắt đầu" forState:UIControlStateNormal];
        _startButton.backgroundColor = [self accentGreen];
    }
}

@end
