#import "GameViewController.h"
#import "BootLogViewController.h"
#import "MDLog.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "HUDHelper.h"
#import "ESPPrefs.h"
#import "GameOffsets.h"
#import "roothide/varCleanController.h"
#import "../KernelBoot.h"

#import <QuartzCore/QuartzCore.h>

@interface GameViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) NSInteger hudRequestSerial;
@property (nonatomic, assign) CFTimeInterval pendingHUDEnableUntil;
@end

@implementation GameViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Game";
    self.view.backgroundColor = MDThemeBg();
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);

    _hudRequestSerial = 0;
    _pendingHUDEnableUntil = 0;

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.backgroundColor = MDThemeBg();
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 64.0f;
    [_tableView registerClass:[MDIconRowCell class] forCellReuseIdentifier:@"row"];
    // Pinned to the safe area rather than to a frame worked out from
    // safeAreaInsets. That inset is the status bar alone and stops short of
    // the navigation bar, so the table started underneath it and the top of
    // the first card was hidden.
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_tableView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appBecameActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_pollTimer invalidate];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    GameOffsetsReload();
    [self startPollingGameState];
    [_tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_pollTimer invalidate];
    _pollTimer = nil;
}

- (void)appBecameActive {
    GameOffsetsReload();
    [_tableView reloadData];
}

#pragma mark - Polling

- (void)startPollingGameState {
    [_pollTimer invalidate];
    __weak __typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   repeats:YES
                                                     block:^(NSTimer *timer) {
        [weakSelf refreshStatus];
    }];
    [self refreshStatus];
}

// Reloading the whole table every second would reset any in-flight selection,
// and this screen has no rows that change on their own; only the status and
// the button title move. Reload those two cells and nothing else.
- (void)refreshStatus {
    if (!self.isViewLoaded) return;
    NSIndexPath *statusPath = [NSIndexPath indexPathForRow:0 inSection:0];
    NSIndexPath *actionPath = [NSIndexPath indexPathForRow:0 inSection:1];
    if ([_tableView numberOfRowsInSection:0] > 0) {
        [_tableView reloadRowsAtIndexPaths:@[ statusPath ]
                         withRowAnimation:UITableViewRowAnimationNone];
    }
    if ([_tableView numberOfRowsInSection:1] > 0) {
        [_tableView reloadRowsAtIndexPaths:@[ actionPath ]
                         withRowAnimation:UITableViewRowAnimationNone];
    }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"STATUS" : @"ACTION";
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    NSString *text = nil;
    if (section == 0) {
        text = @"Keeps the ESP session active and updates DrawView.";
    } else {
        text = @"Starts the kernel session and the SpringBoard overlay.";
    }
    if (!text) return nil;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.font = MDThemeFont(13.0f, UIFontWeightRegular);
    l.textColor = MDThemeMuted();
    l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectZero];
    [footer addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:20.0f],
        [l.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-20.0f],
        [l.topAnchor constraintEqualToAnchor:footer.topAnchor constant:6.0f],
        [l.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-8.0f],
    ]];
    return footer;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MDIconRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"
                                                        forIndexPath:indexPath];

    BOOL hudOn = IsESPSessionRunning();
    if (indexPath.section == 0) {
        [cell applyIconNamed:@"waveform.path.ecg"
                        color:hudOn ? MDThemeGreen() : MDThemeRed()];
        if (hudOn) {
            [cell applyTitle:@"Active" subtitle:@"ESP is on. Session is live."
                       value:nil showsChevron:NO tappable:NO];
        } else {
            [cell applyTitle:@"Inactive" subtitle:@"ESP is off. Activate it to start."
                       value:nil showsChevron:NO tappable:NO];
        }
        return cell;
    }

    // One row, two jobs: start a session, or stop the one already running.
    // The label has to follow the state, otherwise the button reads "Activate"
    // while ESP is live and tapping it then kills what the user just started.
    BOOL pending = (!hudOn && _pendingHUDEnableUntil > 0 &&
                    CACurrentMediaTime() < _pendingHUDEnableUntil);

    if (hudOn) {
        [cell applyIconNamed:@"stop.fill" color:MDThemeRed()];
        [cell applyTitle:@"Tắt ESP"
                 subtitle:@"Dừng phiên ESP và lớp phủ."
                    value:nil showsChevron:YES tappable:YES];
        cell.titleLabel.textColor = MDThemeRed();
    } else if (pending) {
        [cell applyIconNamed:@"hourglass" color:MDThemeMuted()];
        [cell applyTitle:@"Đang bật…"
                 subtitle:@"Đang khởi tạo kernel và lớp phủ SpringBoard."
                    value:nil showsChevron:NO tappable:NO];
        cell.titleLabel.textColor = MDThemeMuted();
    } else {
        [cell applyIconNamed:@"play.fill" color:MDThemeAccent()];
        [cell applyTitle:@"Activate"
                 subtitle:@"Kiểm tra quyền và mở phiên mới."
                    value:nil showsChevron:YES tappable:YES];
        cell.titleLabel.textColor = MDThemeAccent();
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    [self actionTapped];
}

#pragma mark - Action

- (void)actionTapped {
    if (IsESPSessionRunning()) {
        [self stopSession];
        return;
    }
    [self presentBootLogAndStart];
}

// Stopping is a kill: the HUD process is SIGKILLed, so there is nothing to ask
// the user about and no state to unwind.
- (void)stopSession {
    ++_hudRequestSerial;
    _pendingHUDEnableUntil = 0;
    [MDLog appendLine:@"— Stopping session."];
    SetHUDEnabled(NO);
    [self markSessionRunning:NO];
    [MDLog appendLine:@"OK Session stopped."];
    [self refreshStatus];
}

// The session lives in this process (StartESPHost's window, mirrored into
// SpringBoard), so the pid file of the -hud process is not the answer to
// whether ESP is drawing. IsESPSessionRunning() asks the things that actually
// know. App_LocalHUDState is the app's own record of the user's last tap, and
// it is persisted because the session outlives the process that started it.
static NSString *const kMDGameSessionKey = @"App_LocalHUDState";

- (void)markSessionRunning:(BOOL)running {
    ESPPrefsSetBool(kMDGameSessionKey, running);
    ESPPrefsSync();
}

// Fresh buffer, console on top, boot kicked off behind it. Order matters: the
// clear has to land before KernelBoot writes its first line, or step 1/6 shows
// up above the header and then gets wiped.
- (void)presentBootLogAndStart {
    [MDLog clear];

    BootLogViewController *vc = [[BootLogViewController alloc] init];

    // A sheet, not a full-screen cover: the Game tab's status card has to stay
    // visible behind it so it is obvious the session is starting. iOS 15
    // detents give the tall sheet in the reference; the detent API does not
    // exist before that, hence the respondsToSelector check.
    vc.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        vc.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
        vc.sheetPresentationController.prefersGrabberVisible = NO;
        vc.sheetPresentationController.preferredCornerRadius = 12.0f;
    }

    [self presentViewController:vc animated:YES completion:^{
        [self startHUDForRequest:++self.hudRequestSerial];
    }];
}

- (void)startHUDForRequest:(NSInteger)requestSerial {
    _pendingHUDEnableUntil = CACurrentMediaTime() + 2.5;
    GameOffsetsReload();
    [MDLog appendLine:@"RUN Requesting a fresh session…"];

    if (!ESPPrefsBool(@"AutoVarCleanBeforeHUD", NO)) {
        [self markSessionRunning:YES];
        SetHUDEnabled(YES);
        kernelBootStart();
        [self refreshStatus];
        return;
    }

    [MDLog appendLine:@"RUN VarClean before HUD (AutoVarCleanBeforeHUD)…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[varCleanController sharedInstance] runVarCleanNowWithCompletion:^(BOOL authorized) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (requestSerial != self.hudRequestSerial || !authorized) {
                    self.pendingHUDEnableUntil = 0;
                    [MDLog appendLine:@"ERR VarClean did not authorize — session not started."];
                    [self refreshStatus];
                    return;
                }
                [MDLog appendLine:@"OK VarClean done."];
                [self markSessionRunning:YES];
                SetHUDEnabled(YES);
                kernelBootStart();
                [self refreshStatus];
            });
        }];
    });
}

@end