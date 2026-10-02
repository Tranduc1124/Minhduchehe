#import "GamePickerViewController.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "GameOffsets.h"
#import "MDLog.h"
#import "HUDHelper.h"
#import "ESPPrefs.h"

@interface GamePickerViewController ()
@property (nonatomic, copy) NSArray<NSString *> *ids;
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, copy) NSArray<NSString *> *subtitles;
@property (nonatomic, copy) NSArray<NSString *> *icons;
@end

@implementation GamePickerViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Game";
        // Same order as the version cards the app used to have on Home.
        // The icon sits beside the name rather than being chosen from it with a
        // string comparison: `id == @"ffmax"` compares pointers, which is
        // undefined behaviour and can pick the wrong branch, and a literal is
        // not required to be identical across two occurrences.
        _ids = @[ @"ffmax", @"ff" ];
        _titles = @[ @"Free Fire MAX", @"Free Fire THG" ];
        _subtitles = @[ @"com.dts.freefiremax", @"vn.vng.freefireth" ];
        _icons = @[ @"crown.fill", @"flame.fill" ];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MDThemeBg();
    self.tableView.backgroundColor = MDThemeBg();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 74.0f;
    [self.tableView registerClass:[MDIconRowCell class] forCellReuseIdentifier:@"game"];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_ids.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Changing the game reloads the offset table. Start a new session for it to take effect.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MDIconRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"game"
                                                        forIndexPath:indexPath];
    NSInteger i = indexPath.row;
    BOOL selected = GameTargetIsMax() == ([_ids[i] isEqualToString:@"ffmax"]);

    [cell applyIconNamed:_icons[i] color:(selected ? MDThemeAccent() : MDThemePanel2())];
    [cell applyTitle:_titles[i] subtitle:_subtitles[i] value:nil showsChevron:NO tappable:YES];
    cell.titleLabel.textColor = selected ? MDThemeText() : MDThemeMuted();
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = MDThemeAccent();
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *id = _ids[indexPath.row];
    BOOL wasMax = GameTargetIsMax();
    if (wasMax == [id isEqualToString:@"ffmax"]) return;

    GameTargetSetSelectedId(id);
    [MDLog appendLine:[NSString stringWithFormat:@"OK Target set to %@.", _titles[indexPath.row]]];
    [tableView reloadData];

    // A live session is bound to the old process and offset table, so offer
    // the one action that makes the switch real instead of silently doing
    // nothing until the user notices. IsESPSessionRunning, not IsHUDEnabled:
    // the pid file does not cover the session that actually draws.
    if (IsESPSessionRunning()) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Restart session?"
                                                message:@"ESP is running against the previous game. Restart the session to use the one you just picked."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Stop and Restart"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            StopESPSession();
            ESPPrefsSetBool(@"App_LocalHUDState", NO);
            ESPPrefsSync();
            [self.navigationController popViewControllerAnimated:YES];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end