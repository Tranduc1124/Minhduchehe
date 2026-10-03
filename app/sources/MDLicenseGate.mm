//
//  MDLicenseGate.mm — license gate for the MINHDUC app.
//

#import "MDLicenseGate.h"
#import "MDTheme.h"
#import "MDUI.h"
#import "APIClient/APIClient.h"

static BOOL gMDLicenseAuthorized = NO;

@interface MDLicenseLockViewController : UIViewController
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *retryButton;
@end

@implementation MDLicenseLockViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MDThemeBg();
    // Nothing behind this screen is reachable: swallow every touch.
    self.view.userInteractionEnabled = YES;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"MINHDUC";
    title.font = MDThemeFont(28.0, UIFontWeightHeavy);
    title.textColor = MDThemeText();
    [self.view addSubview:title];

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = @"Canh bao quyen — vui long nhap key de mo ung dung.";
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.font = MDThemeFont(15.0, UIFontWeightRegular);
    hint.textColor = MDThemeMuted();
    [self.view addSubview:hint];

    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = @"Dang kiem tra ban quyen...";
    status.numberOfLines = 0;
    status.textAlignment = NSTextAlignmentCenter;
    status.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];
    status.textColor = MDThemeMuted();
    [self.view addSubview:status];
    self.statusLabel = status;

    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    [retry setTitle:@"Kiem tra lai" forState:UIControlStateNormal];
    retry.titleLabel.font = MDThemeFont(16.0, UIFontWeightSemibold);
    retry.tintColor = MDThemeAccent();
    [self.view addSubview:retry];
    self.retryButton = retry;

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:120.0],

        [hint.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [hint.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:14.0],
        [hint.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:32.0],
        [hint.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-32.0],

        [status.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [status.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:28.0],
        [status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32.0],
        [status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32.0],

        [retry.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [retry.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:26.0],
    ]];
}

@end

@implementation MDLicenseGate

+ (BOOL)authorized {
    return gMDLicenseAuthorized;
}

+ (void)setAuthorized:(BOOL)authorized {
    gMDLicenseAuthorized = authorized;
}

+ (UIViewController *)lockViewController {
    return [[MDLicenseLockViewController alloc] init];
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
            return @"Khong kiem tra duoc ban quyen. Vui long thu lai.";
    }
}

+ (void)startWithAuthorized:(dispatch_block_t)onAuthorized
                   terminal:(void (^)(NSString *message))onTerminal {
    // APIClientSetup() must be called explicitly: the header's auto-setup
    // constructor is static and gets dead-stripped under -Wl,-dead_strip, so
    // without this call APIClientConfigure() never runs and no token is set.
    APIClientSetup();

    dispatch_block_t finish = ^{
        self.authorized = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (onAuthorized) onAuthorized();
        });
    };

    APIClientStartAuthorizationWithEvents(finish, ^{
        // Revoked mid-session: drop back to the lock screen.
        self.authorized = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (onTerminal) onTerminal(@"Key da bi thu hoi.");
        });
    }, ^(NSDictionary *result) {
        self.authorized = NO;
        TserverStatusCode code = TserverStatusCodeFromString(result[@"status"]);
        NSString *message = MDLicenseMessageForStatus(code);
        NSString *detail = [result[@"errorCode"] isKindOfClass:NSString.class] ? result[@"errorCode"] : @"";
        if (detail.length > 0) {
            message = [NSString stringWithFormat:@"%@\n(%@)", message, detail];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (onTerminal) onTerminal(message);
        });
    });
}

@end