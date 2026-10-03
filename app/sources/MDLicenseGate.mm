//
//  MDLicenseGate.mm — license gate for the MINHDUC app.
//

#import "MDLicenseGate.h"
#import "MDTheme.h"
#import "MDUI.h"

static BOOL gMDLicenseAuthorized = NO;
static dispatch_block_t gAuthorizedHandler = nil;
static void (^gTerminalHandler)(NSString *) = nil;

#pragma mark - Status presentation

static NSString *MDLicenseSymbolForStatus(TserverStatusCode code) {
    switch (code) {
        case TserverStatusCodeValid:
        case TserverStatusCodeOfflineGraceValid:
            return @"checkmark.seal.fill";
        case TserverStatusCodeNeedKey:
            return @"key.fill";
        case TserverStatusCodeNeedUUID:
            return @"qrcode.viewfinder";
        case TserverStatusCodeInvalidKey:
            return @"xmark.octagon.fill";
        case TserverStatusCodeExpired:
        case TserverStatusCodeOfflineGraceExpired:
        case TserverStatusCodeProfileExpired:
            return @"clock.badge.exclamationmark.fill";
        case TserverStatusCodeRevoked:
            return @"xmark.shield.fill";
        case TserverStatusCodeDeviceBlocked:
        case TserverStatusCodeDeviceMismatch:
            return @"iphone.slash";
        case TserverStatusCodeUpdateRequired:
            return @"arrow.down.app.fill";
        case TserverStatusCodeRateLimited:
            return @"hourglass";
        case TserverStatusCodeNetworkError:
            return @"wifi.exclamationmark";
        case TserverStatusCodeServerError:
        case TserverStatusCodeMaintenance:
        case TserverStatusCodeAppDisabled:
        case TserverStatusCodeStoreDisabled:
        case TserverStatusCodePackageDisabled:
        case TserverStatusCodePackageMaintenance:
            return @"exclamationmark.triangle.fill";
        default:
            return @"lock.shield.fill";
    }
}

static UIColor *MDLicenseColorForStatus(TserverStatusCode code) {
    switch (code) {
        case TserverStatusCodeValid:
        case TserverStatusCodeOfflineGraceValid:
            return MDThemeGreen();
        case TserverStatusCodeNeedKey:
            return MDThemeAccent();
        case TserverStatusCodeNeedUUID:
        case TserverStatusCodeExpired:
        case TserverStatusCodeOfflineGraceExpired:
        case TserverStatusCodeProfileExpired:
        case TserverStatusCodeRateLimited:
            return MDThemeOrange();
        case TserverStatusCodeInvalidKey:
        case TserverStatusCodeRevoked:
        case TserverStatusCodeDeviceBlocked:
        case TserverStatusCodeDeviceMismatch:
            return MDThemeRed();
        default:
            return MDThemeBlue();
    }
}

static NSString *MDLicenseMessageForStatus(TserverStatusCode code) {
    switch (code) {
        case TserverStatusCodeValid:
        case TserverStatusCodeOfflineGraceValid:
            return @"Ban quyen hop le.";
        case TserverStatusCodeNeedKey:
            return @"Chua nhap key. Hay nhap key de tiep tuc.";
        case TserverStatusCodeNeedUUID:
            return @"Can thiet bi da duyet profile truoc khi kich hoat key.";
        case TserverStatusCodeInvalidKey:
            return @"Key khong hop le.";
        case TserverStatusCodeExpired:
        case TserverStatusCodeOfflineGraceExpired:
        case TserverStatusCodeProfileExpired:
            return @"Key da het han.";
        case TserverStatusCodeRevoked:
            return @"Key da bi thu hoi.";
        case TserverStatusCodeDeviceBlocked:
            return @"Thiet bi dang bi chan.";
        case TserverStatusCodeDeviceMismatch:
            return @"Key da kich hoat tren thiet bi khac.";
        case TserverStatusCodeUpdateRequired:
            return @"Can cap nhat phien ban moi nhat.";
        case TserverStatusCodeRateLimited:
            return @"Qua nhieu yeu cau. Thu lai sau.";
        case TserverStatusCodeNetworkError:
            return @"Khong ket noi duoc mayy chu.";
        case TserverStatusCodeServerError:
            return @"Loi mayy chu. Thu lai sau.";
        case TserverStatusCodeMaintenance:
        case TserverStatusCodeAppDisabled:
        case TserverStatusCodeStoreDisabled:
        case TserverStatusCodePackageDisabled:
        case TserverStatusCodePackageMaintenance:
            return @"Dich vu dang bao tri. Vui long thu lai sau.";
        case TserverStatusCodeAuthorizationLeaseInvalid:
        case TserverStatusCodeBadResponseSignature:
        case TserverStatusCodeUnsafeEnvironment:
            return @"Khong xac thuc duoc phien ban. Vui long mo lai ung dung.";
        default:
            return @"Chua kiem tra duoc ban quyen. Vui long thu lai.";
    }
}

#pragma mark - Lock screen

/// The lock screen. Nothing behind it is reachable: the tab bar is only
/// installed as the window root from the authorized callback, so every touch
/// that does not land on a control lands on empty views here.
@interface MDLicenseLockViewController : UIViewController
- (void)showChecking;
- (void)applyMessage:(NSString *)message status:(TserverStatusCode)status;
@end

@implementation MDLicenseLockViewController {
    UIView *_statusTile;
    UIImageView *_statusIcon;
    UILabel *_statusLabel;
    UILabel *_detailLabel;
    UIActivityIndicatorView *_spinner;
    UIButton *_retryButton;

    BOOL _checking;
    BOOL _pending;
    NSString *_pendingMessage;
    TserverStatusCode _pendingStatus;
}

- (UILabel *)labelWithText:(NSString *)text
                       size:(CGFloat)size
                     weight:(UIFontWeight)weight
                      color:(UIColor *)color
                 alignment:(NSTextAlignment)align {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = MDThemeFont(size, weight);
    label.textColor = color;
    label.textAlignment = align;
    label.numberOfLines = 0;
    return label;
}

- (UIImage *)appIconImage {
    // AppIcon is the asset-catalog name; some builds carry a loose icon.png.
    // Fall back to a glyph so the badge never reads as a broken block.
    UIImage *icon = [UIImage imageNamed:@"AppIcon"];
    if (!icon) icon = MDUIImageNamed(@"icon");
    if (!icon) icon = MDUIImageNamed(@"icon.png");
    return icon;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MDThemeBg();

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:scroll];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    // --- soft accent glow behind the badge ---
    UIView *glow = [[UIView alloc] init];
    glow.translatesAutoresizingMaskIntoConstraints = NO;
    glow.backgroundColor = MDThemeAccentSoft(0.14);
    glow.layer.cornerRadius = 110.0;
    glow.userInteractionEnabled = NO;
    [content addSubview:glow];

    // --- badge: app icon on an accent gradient tile ---
    UIView *badge = [[UIView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.layer.cornerRadius = 34.0;
    badge.layer.shadowColor = MDThemeAccent().CGColor;
    badge.layer.shadowOpacity = 0.26;
    badge.layer.shadowRadius = 18.0;
    badge.layer.shadowOffset = CGSizeMake(0, 10);
    badge.userInteractionEnabled = NO;
    [content addSubview:badge];

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[ (__bridge id)MDThemeAccent().CGColor, (__bridge id)MDThemeTeal().CGColor ];
    gradient.startPoint = CGPointMake(0.0, 0.0);
    gradient.endPoint = CGPointMake(1.0, 1.0);
    gradient.cornerRadius = 34.0;
    gradient.frame = CGRectMake(0, 0, 132, 132);
    [badge.layer addSublayer:gradient];

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.userInteractionEnabled = NO;
    iconView.image = [self appIconImage];
    if (!iconView.image) {
        iconView.image = MDUISymbol(@"shield.lefthalf.filled.badge.checkmark", 56.0, UIFontWeightBold);
        iconView.tintColor = UIColor.whiteColor;
    }
    [badge addSubview:iconView];

    // --- title block ---
    UILabel *title = [self labelWithText:@"MINHDUC"
                                    size:32.0
                                  weight:UIFontWeightHeavy
                                   color:MDThemeText()
                              alignment:NSTextAlignmentCenter];
    [content addSubview:title];

    UILabel *subtitle = [self labelWithText:@"LICENSE GATE"
                                     size:12.0
                                   weight:UIFontWeightBold
                                    color:MDThemeAccent()
                               alignment:NSTextAlignmentCenter];
    [content addSubview:subtitle];

    UILabel *hint = [self labelWithText:@"Ung dung chi mo sau khi key duoc mayy chu xac nhan."
                                   size:15.0
                                 weight:UIFontWeightRegular
                                  color:MDThemeMuted()
                             alignment:NSTextAlignmentCenter];
    [content addSubview:hint];

    // --- status card ---
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = MDThemePanel();
    card.layer.cornerRadius = 20.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = MDThemeLine().CGColor;
    [content addSubview:card];

    UIView *statusTile = [[UIView alloc] init];
    statusTile.translatesAutoresizingMaskIntoConstraints = NO;
    statusTile.layer.cornerRadius = 14.0;
    statusTile.userInteractionEnabled = NO;
    [card addSubview:statusTile];
    _statusTile = statusTile;

    UIImageView *statusGlyph = [[UIImageView alloc] init];
    statusGlyph.translatesAutoresizingMaskIntoConstraints = NO;
    statusGlyph.contentMode = UIViewContentModeScaleAspectFit;
    statusGlyph.tintColor = UIColor.whiteColor;
    statusGlyph.userInteractionEnabled = NO;
    [statusTile addSubview:statusGlyph];
    _statusIcon = statusGlyph;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.color = MDThemeAccent();
    spinner.hidesWhenStopped = YES;
    spinner.userInteractionEnabled = NO;
    [card addSubview:spinner];
    _spinner = spinner;

    UILabel *status = [self labelWithText:@"Dang kiem tra ban quyen..."
                                     size:16.0
                                   weight:UIFontWeightSemibold
                                    color:MDThemeText()
                               alignment:NSTextAlignmentLeft];
    [card addSubview:status];
    _statusLabel = status;

    UILabel *detail = [self labelWithText:@"ket noi mayy chu Tserver de xac thuc"
                                    size:12.0
                                  weight:UIFontWeightRegular
                                   color:MDThemeMuted()
                              alignment:NSTextAlignmentLeft];
    detail.font = MDUIMonoFont(12.0, UIFontWeightRegular);
    [card addSubview:detail];
    _detailLabel = detail;

    // --- retry ---
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    retry.backgroundColor = MDThemeAccent();
    retry.layer.cornerRadius = 16.0;
    retry.titleLabel.font = MDThemeFont(16.0, UIFontWeightBold);
    [retry setTitle:@"Kiem tra lai" forState:UIControlStateNormal];
    [retry setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [retry setImage:MDUISymbol(@"arrow.clockwise", 15.0, UIFontWeightBold)
            forState:UIControlStateNormal];
    retry.tintColor = UIColor.whiteColor;
    retry.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 0);
    retry.hidden = YES;
    [retry addTarget:self action:@selector(onRetry) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:retry];
    _retryButton = retry;

    // --- footer ---
    UIImageView *shield = [[UIImageView alloc] init];
    shield.translatesAutoresizingMaskIntoConstraints = NO;
    shield.image = MDUISymbol(@"lock.shield", 13.0, UIFontWeightSemibold);
    shield.tintColor = MDThemeMuted();
    shield.contentMode = UIViewContentModeScaleAspectFit;
    shield.userInteractionEnabled = NO;
    [content addSubview:shield];

    UILabel *footer = [self labelWithText:@"ES256 lease · transport v3 · TLS pinning"
                                    size:12.0
                                  weight:UIFontWeightRegular
                                   color:MDThemeMuted()
                              alignment:NSTextAlignmentLeft];
    footer.font = MDUIMonoFont(12.0, UIFontWeightRegular);
    [content addSubview:footer];

    // --- layout ---
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        [glow.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [glow.topAnchor constraintEqualToAnchor:content.topAnchor constant:-64.0],
        [glow.widthAnchor constraintEqualToConstant:220.0],
        [glow.heightAnchor constraintEqualToConstant:220.0],

        [badge.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [badge.topAnchor constraintEqualToAnchor:content.topAnchor constant:76.0],
        [badge.widthAnchor constraintEqualToConstant:132.0],
        [badge.heightAnchor constraintEqualToConstant:132.0],

        [iconView.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:76.0],
        [iconView.heightAnchor constraintEqualToConstant:76.0],

        [title.topAnchor constraintEqualToAnchor:badge.bottomAnchor constant:28.0],
        [title.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [title.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor constant:24.0],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-24.0],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6.0],
        [subtitle.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],

        [hint.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:16.0],
        [hint.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:36.0],
        [hint.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-36.0],

        [card.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:32.0],
        [card.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20.0],
        [card.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20.0],

        [statusTile.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [statusTile.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [statusTile.widthAnchor constraintEqualToConstant:48.0],
        [statusTile.heightAnchor constraintEqualToConstant:48.0],

        [statusGlyph.centerXAnchor constraintEqualToAnchor:statusTile.centerXAnchor],
        [statusGlyph.centerYAnchor constraintEqualToAnchor:statusTile.centerYAnchor],
        [statusGlyph.widthAnchor constraintEqualToConstant:24.0],
        [statusGlyph.heightAnchor constraintEqualToConstant:24.0],

        [spinner.centerXAnchor constraintEqualToAnchor:statusTile.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:statusTile.centerYAnchor],

        [status.leadingAnchor constraintEqualToAnchor:statusTile.trailingAnchor constant:14.0],
        [status.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [status.topAnchor constraintEqualToAnchor:card.topAnchor constant:18.0],

        [detail.leadingAnchor constraintEqualToAnchor:status.leadingAnchor],
        [detail.trailingAnchor constraintEqualToAnchor:status.trailingAnchor],
        [detail.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:6.0],

        [card.bottomAnchor constraintEqualToAnchor:detail.bottomAnchor constant:18.0],

        [retry.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:20.0],
        [retry.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [retry.widthAnchor constraintEqualToConstant:200.0],
        [retry.heightAnchor constraintEqualToConstant:52.0],

        [shield.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24.0],
        [shield.topAnchor constraintEqualToAnchor:retry.bottomAnchor constant:26.0],
        [shield.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-32.0],
        [shield.widthAnchor constraintEqualToConstant:16.0],
        [shield.heightAnchor constraintEqualToConstant:16.0],

        [footer.leadingAnchor constraintEqualToAnchor:shield.trailingAnchor constant:8.0],
        [footer.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-24.0],
        [footer.centerYAnchor constraintEqualToAnchor:shield.centerYAnchor],
    ]];

    if (_pending) {
        _pending = NO;
        [self applyMessage:_pendingMessage status:_pendingStatus];
    } else {
        [self applyCheckingState];
    }
}

- (void)showChecking {
    _checking = YES;
    if (!self.isViewLoaded) return;
    [self applyCheckingState];
}

- (void)applyCheckingState {
    _statusTile.backgroundColor = MDThemeAccentSoft(0.18);
    _statusIcon.hidden = YES;
    _retryButton.hidden = YES;
    if (!_spinner.isAnimating) [_spinner startAnimating];
}

- (void)applyMessage:(NSString *)message status:(TserverStatusCode)status {
    if (!self.isViewLoaded) {
        _pendingMessage = [message copy];
        _pendingStatus = status;
        _pending = YES;
        return;
    }
    _checking = NO;
    [_spinner stopAnimating];
    _statusIcon.hidden = NO;
    _statusTile.backgroundColor = MDLicenseColorForStatus(status);
    _statusIcon.image = MDUISymbol(MDLicenseSymbolForStatus(status), 24.0, UIFontWeightSemibold);
    _statusLabel.text = message;
    _detailLabel.text = TserverStatusCodeString(status);
    _retryButton.hidden = (status == TserverStatusCodeValid ||
                           status == TserverStatusCodeOfflineGraceValid);
}

- (void)onRetry {
    [MDLicenseGate startWithAuthorized:gAuthorizedHandler terminal:gTerminalHandler];
}

@end

#pragma mark - Gate

/// The visible lock screen. Held weakly so the gate never keeps a released
/// view controller alive.
static __weak MDLicenseLockViewController *gMDLicenseLockController = nil;

@implementation MDLicenseGate

+ (BOOL)authorized {
    return gMDLicenseAuthorized;
}

+ (void)setAuthorized:(BOOL)authorized {
    gMDLicenseAuthorized = authorized;
}

+ (UIViewController *)lockViewController {
    MDLicenseLockViewController *lock = [[MDLicenseLockViewController alloc] init];
    gMDLicenseLockController = lock;
    return lock;
}

+ (void)showChecking {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gMDLicenseLockController showChecking];
    });
}

+ (void)showMessage:(NSString *)message status:(TserverStatusCode)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gMDLicenseLockController applyMessage:message status:status];
    });
}

+ (void)startWithAuthorized:(dispatch_block_t)onAuthorized
                   terminal:(void (^)(NSString *message))onTerminal {
    // Keep the handlers so the lock screen's retry button re-runs the same flow
    // and still reaches the delegate that installs the tab bar.
    gAuthorizedHandler = [onAuthorized copy];
    gTerminalHandler = [onTerminal copy];

    // APIClientSetup() must be called explicitly: the header's auto-setup
    // constructor is static and gets dead-stripped under -Wl,-dead_strip, so
    // without this call APIClientConfigure() never runs and no token is set.
    APIClientSetup();
    [self showChecking];

    APIClientStartAuthorizationWithEvents(^{
        self.authorized = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gAuthorizedHandler) gAuthorizedHandler();
        });
    }, ^{
        // Revoked mid-session: stay locked and say so.
        self.authorized = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showMessage:@"Key da bi thu hoi." status:TserverStatusCodeRevoked];
            if (gTerminalHandler) gTerminalHandler(@"Key da bi thu hoi.");
        });
    }, ^(NSDictionary *result) {
        self.authorized = NO;
        TserverStatusCode code = TserverStatusCodeFromString(result[@"status"]);
        NSString *message = MDLicenseMessageForStatus(code);
        NSString *detail = [result[@"errorCode"] isKindOfClass:NSString.class] ? result[@"errorCode"] : @"";
        if (detail.length > 0) {
            message = [NSString stringWithFormat:@"%@ (%@)", message, detail];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showMessage:message status:code];
            if (gTerminalHandler) gTerminalHandler(message);
        });
    });
}

@end