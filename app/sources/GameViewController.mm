#import "GameViewController.h"
#import "BootLogViewController.h"
#import "MDLog.h"
#import "KernelBoot.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "HUDHelper.h"
#import "ESPPrefs.h"
#import "GameOffsets.h"
#import "roothide/varCleanController.h"
#import "../KernelBoot.h"
#import "../../remote/SpringBoardOverlay.h"

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
        text = @"Keeps the ESP session alive while you play.";
    } else {
        text = @"Starts a new ESP session.";
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

// Three states, not two, and the third one used to be missing.
//
// actionTapped records the session as running before it starts anything:
// markSessionRunning:YES writes App_LocalHUDState and SetHUDEnabled spawns the
// -hud process, and both of those are what IsESPSessionRunning() reads. So the
// instant the row is tapped it answered yes, and the card said "Active" and the
// button said "Stop ESP" while the kernel was still being exploited and not one
// frame had been drawn. It was the truth about a flag and a lie about a picture.
//
// So "asked for" and "drawing" are separate here. A session is live only once a
// frame has actually reached SpringBoard; until then it is starting, and says
// so. That is the whole reason SBoardOverlayHasPublishedFrame exists.
- (BOOL)isESPDrawing {
    return IsESPSessionRunning() && SBoardOverlayHasPublishedFrame() != 0;
}

- (BOOL)isESPStarting {
    return IsESPSessionRunning() && SBoardOverlayHasPublishedFrame() == 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MDIconRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"
                                                        forIndexPath:indexPath];

    BOOL hudOn = [self isESPDrawing];
    // Asked for, not yet drawing. Distinct from both "off" and "live".
    BOOL starting = [self isESPStarting];
    // Kernel-only is a third state, not "off". AutoBootOnLaunch brings the exploit
    // up at launch and deliberately starts nothing that draws, and the row said
    // "Inactive / ESP is off" for a machine that was in fact ready — so the button
    // read like a first start rather than the second half of a session already in
    // progress.
    BOOL kernelOnly = (!hudOn && !starting && kernelBootReady());
    if (indexPath.section == 0) {
        if (starting) {
            // A muted clock rather than the green of a live session: nothing is on
            // screen yet, and a card that claims otherwise is the whole problem.
            [cell applyIconNamed:@"clock" color:MDThemeMuted()];
            [cell applyTitle:@"Starting…"
                     subtitle:@"Nothing is on screen yet. This stays until the ESP draws."
                        value:nil showsChevron:NO tappable:NO];
            cell.titleLabel.textColor = MDThemeMuted();
            return cell;
        }
        [cell applyIconNamed:@"waveform.path.ecg"
                        color:hudOn ? MDThemeGreen() : (kernelOnly ? MDThemeGreen() : MDThemeRed())];
        if (hudOn) {
            [cell applyTitle:@"Active" subtitle:@"ESP is on. Session is live."
                       value:nil showsChevron:NO tappable:NO];
        } else if (kernelOnly) {
            [cell applyTitle:@"Kernel ready" subtitle:@"Kernel only. The ESP is off."
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

    if (starting) {
        // Tappable, and tapping it cancels. A start that never reaches a publish
        // would otherwise sit on this row for the life of the app with no way out
        // of it: the row is the only control on the screen.
        [cell applyIconNamed:@"hourglass" color:MDThemeMuted()];
        [cell applyTitle:@"Starting ESP…"
                 subtitle:@"Not on screen yet. Tap to cancel."
                    value:nil showsChevron:NO tappable:YES];
        cell.titleLabel.textColor = MDThemeMuted();
    } else if (hudOn) {
        [cell applyIconNamed:@"stop.fill" color:MDThemeRed()];
        [cell applyTitle:@"Stop ESP"
                 subtitle:@"Stops ESP and hides the box."
                    value:nil showsChevron:YES tappable:YES];
        cell.titleLabel.textColor = MDThemeRed();
    } else if (pending) {
        [cell applyIconNamed:@"hourglass" color:MDThemeMuted()];
        [cell applyTitle:@"Starting…"
                 subtitle:@"Getting everything ready. This takes a moment."
                    value:nil showsChevron:NO tappable:NO];
        cell.titleLabel.textColor = MDThemeMuted();
    } else {
        // Kernel already up: this is not a fresh boot, it is the second half of
        // one. kernelBootStart() takes its g_ready path and brings up the
        // SpringBoard overlay and the ESP host without re-running the exploit.
        [cell applyIconNamed:@"play.fill" color:MDThemeAccent()];
        if (kernelOnly) {
            [cell applyTitle:@"Start ESP"
                     subtitle:@"Kernel is up. Turns on the overlay and the ESP."
                        value:nil showsChevron:YES tappable:YES];
        } else {
            [cell applyTitle:@"Activate"
                     subtitle:@"Starts a fresh ESP session."
                        value:nil showsChevron:YES tappable:YES];
        }
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

// Stopping is a kill, so there is nothing to confirm on this row: the Game
// tab is the screen the user is already looking at.
- (void)stopSession {
    ++_hudRequestSerial;
    _pendingHUDEnableUntil = 0;
    [MDLog appendLine:@"— Stopping session."];
    StopESPSession();
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
    // How long the row stays on "Starting…". A full boot is the exploit, which
    // either works in a second or does not work at all. Starting from
    // kernel-ready is only the SpringBoard overlay, and boot_start_sb_overlay
    // retries at 3s, 5s, 8s and 12s cumulative — so the old fixed 2.5s put the row
    // back to "Start ESP" while the overlay was still coming up, and the user saw
    // the button flicker through three states.
    _pendingHUDEnableUntil = CACurrentMediaTime() + (kernelBootReady() ? 15.0 : 2.5);
    GameOffsetsReload();
    [MDLog appendLine:@"RUN Starting a new session…"];

    if (!ESPPrefsBool(@"AutoVarCleanBeforeHUD", NO)) {
        [self markSessionRunning:YES];
        SetHUDEnabled(YES);
        kernelBootStart();
        [self refreshStatus];
        return;
    }

    [MDLog appendLine:@"RUN Clearing leftovers before starting…"];
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