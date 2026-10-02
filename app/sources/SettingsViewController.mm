#import "SettingsViewController.h"
#import "GamePickerViewController.h"
#import "ESPAimViewController.h"
#import "LaunchOptionsViewController.h"
#import "DNSViewController.h"
#import "AppearanceViewController.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "MDLog.h"
#import "GameOffsets.h"
#import "HUDHelper.h"

#import <SafariServices/SafariServices.h>

typedef NS_ENUM(NSInteger, SettingsSection) {
    SectionGame = 0,
    SectionQuickActions,
    SectionTweaks,
    SectionDNS,
    SectionAbout,
    SettingsSectionCount
};

@interface SettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = MDThemeBg();
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.backgroundColor = MDThemeBg();
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    // The cells lay themselves out, so the table must be allowed to ask for a
    // height. The old version of this screen passed a fixed estimate plus a
    // delegate height computed against a guessed text width, which clipped the
    // Vietnamese subtitles and let rows overlap.
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 64.0f;
    [_tableView registerClass:[MDIconRowCell class] forCellReuseIdentifier:@"row"];
    // Pinned to the safe area, not to a frame derived from safeAreaInsets.
    // That inset covers the status bar and stops short of the navigation bar,
    // so the table started underneath it and the last section could not be
    // scrolled clear of it.
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_tableView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    [_tableView reloadData];
}

#pragma mark - Table shape

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return SettingsSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case SectionGame:        return 1;
        case SectionQuickActions:return 2;
        case SectionTweaks:      return 3;
        case SectionDNS:         return 1;
        case SectionAbout:       return 3;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case SectionGame:        return @"GAME";
        case SectionQuickActions:return @"QUICK ACTIONS";
        case SectionTweaks:      return @"TWEAKS";
        case SectionDNS:         return @"DNS";
        case SectionAbout:       return @"ABOUT";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MDIconRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"
                                                        forIndexPath:indexPath];
    NSInteger row = indexPath.row;

    switch (indexPath.section) {
        case SectionGame:
            [cell applyIconNamed:@"gamecontroller.fill" color:MDThemeAccent()];
            [cell applyTitle:@"Chọn game"
                     subtitle:@"Đích ESP và bảng offset"
                        value:GameTargetIsMax() ? @"Free Fire MAX" : @"Free Fire THG"
                 showsChevron:YES
                     tappable:YES];
            break;

        case SectionQuickActions:
            if (row == 0) {
                // Same job as the Game tab's action row when a session is
                // live, so the icon and the colour follow that state.
                BOOL hudOn = IsESPSessionRunning();
                [cell applyIconNamed:(hudOn ? @"stop.fill" : @"trash.fill")
                               color:(hudOn ? MDThemeRed() : MDThemeMuted())];
                [cell applyTitle:@"Tắt ESP"
                         subtitle:(hudOn ? @"ESP đang chạy." : @"ESP không chạy.")
                            value:nil showsChevron:YES tappable:YES];
            } else {
                [cell applyIconNamed:@"paperplane.fill" color:MDThemeBlue()];
                [cell applyTitle:@"Contact" subtitle:nil value:nil showsChevron:YES tappable:YES];
            }
            break;

        case SectionTweaks:
            if (row == 0) {
                [cell applyIconNamed:@"bolt.fill" color:MDThemeOrange()];
                [cell applyTitle:@"Launch Options"
                         subtitle:@"Startup and background behavior."
                            value:nil showsChevron:YES tappable:YES];
            } else if (row == 1) {
                [cell applyIconNamed:@"waveform.path.ecg" color:MDThemeTeal()];
                [cell applyTitle:@"ESP/AIM"
                         subtitle:@"Count overlay read and publish behavior."
                            value:nil showsChevron:YES tappable:YES];
            } else {
                [cell applyIconNamed:@"paintbrush.fill" color:MDThemePurple()];
                [cell applyTitle:@"Giao diện"
                         subtitle:@"Màu chủ đạo của app."
                            value:nil showsChevron:YES tappable:YES];
            }
            break;

        case SectionDNS:
            [cell applyIconNamed:@"globe" color:MDThemeBlue()];
            [cell applyTitle:@"DNS"
                     subtitle:@"Cài hoặc cập nhật cấu hình DNS."
                        value:nil showsChevron:YES tappable:YES];
            break;

        case SectionAbout: {
            NSDictionary *info = [NSBundle mainBundle].infoDictionary ?: @{};
            if (row == 0) {
                [cell applyIconNamed:@"number" color:MDThemeBlue()];
                [cell applyTitle:@"Version"
                         subtitle:nil
                            value:(info[@"CFBundleShortVersionString"] ?: @"—")
                     showsChevron:NO
                         tappable:NO];
            } else if (row == 1) {
                [cell applyIconNamed:@"hammer.fill" color:MDThemePurple()];
                [cell applyTitle:@"Build"
                         subtitle:nil
                            value:(info[@"CFBundleVersion"] ?: @"—")
                     showsChevron:NO
                         tappable:NO];
            } else {
                [cell applyIconNamed:@"shippingbox.fill" color:MDThemeMuted()];
                [cell applyTitle:@"Bundle"
                         subtitle:nil
                            value:(info[@"CFBundleIdentifier"] ?: @"—")
                     showsChevron:NO
                         tappable:NO];
            }
            break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case SectionGame:
            [self push:[[GamePickerViewController alloc] init]];
            break;
        case SectionQuickActions:
            if (indexPath.row == 0) {
                [self confirmStopESP];
            } else {
                [self contact];
            }
            break;
        case SectionTweaks:
            if (indexPath.row == 0) {
                [self push:[[LaunchOptionsViewController alloc] init]];
            } else if (indexPath.row == 1) {
                [self push:[[ESPAimViewController alloc] init]];
            } else {
                [self push:[[AppearanceViewController alloc] init]];
            }
            break;
        case SectionDNS:
            [self push:[[DNSViewController alloc] init]];
            break;
        default:
            break;
    }
}

- (void)push:(UIViewController *)vc {
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Stop ESP

// Two-step because it kills a process. The default alert is the right control
// here: it is what the system uses for a destructive choice, it gets the
// button order and the cancel semantics right on its own, and it handles the
// outside-tap dismissal without code.
- (void)confirmStopESP {
    if (!IsESPSessionRunning()) {
        [MDLog appendLine:@"— Nothing to stop, no session is running."];
        [_tableView reloadData];
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Tắt ESP?"
                                            message:@"ESP đang chạy. Dừng phiên và đóng lớp phủ?"
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak __typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Tắt ESP"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [weakSelf stopESP];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)stopESP {
    [MDLog appendLine:@"— Stopping session (from Settings)."];
    SetHUDEnabled(NO);
    [MDLog appendLine:@"OK Session stopped."];
    [_tableView reloadData];
}

#pragma mark - Contact

- (void)contact {
    NSString *handle = @"BoLaMinhDuc";
    // The tg:// form opens the installed app, which is what people actually
    // want; the https link is the fallback for a device without Telegram.
    NSURL *appURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"tg://resolve?domain=%@", handle]];
    if (appURL && [[UIApplication sharedApplication] canOpenURL:appURL]) {
        [[UIApplication sharedApplication] openURL:appURL options:@{} completionHandler:nil];
        return;
    }

    NSURL *webURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://t.me/%@", handle]];
    if (!webURL) return;
    if (@available(iOS 15.0, *)) {
        [self presentViewController:[[SFSafariViewController alloc] initWithURL:webURL]
                           animated:YES
                         completion:nil];
    } else {
        [[UIApplication sharedApplication] openURL:webURL options:@{} completionHandler:nil];
    }
}

@end