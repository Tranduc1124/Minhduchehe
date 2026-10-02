#import "LaunchOptionsViewController.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "ESPPrefs.h"

// title, pref key, default. Each of these does something today; none of them is
// a placeholder.
//
// The first row used to read "Start ESP automatically on launch", which is not
// what it does. It calls kernelBootStartKernelOnly, which runs the exploit, the
// sandbox and KeepAlive and stops before the overlay and the ESP host, so no
// ESP appears by itself. The label now says what the key actually does rather
// than what it used to do.
static NSArray<NSArray *> *LORows(void) {
    return @[
        @[ @"Run the exploit on launch",     @"AutoBootOnLaunch", @NO ],
        @[ @"SandboxEscapeOn",               @"SandboxEscapeOn",  @YES ],
        @[ @"Keep app alive in background",   @"KeepAliveOn",      @YES ],
    ];
}

@implementation LaunchOptionsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"Launch Options";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MDThemeBg();
    self.tableView.backgroundColor = MDThemeBg();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 56.0f;
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)LORows().count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"LAUNCH OPTIONS";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Run the exploit on launch prepares the kernel at startup. It does not start the ESP: that still takes a tap on Activate. Keeping the app alive in the background is what lets ESP keep working while you play, and turning it off may let iOS close the app.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *ident = @"lo";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ident];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:ident];
        cell.backgroundColor = MDThemePanel();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        sw.onTintColor = MDThemeAccent();
        [sw addTarget:self
                action:@selector(switchChanged:)
      forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }

    NSArray *row = LORows()[indexPath.row];
    cell.textLabel.text = row[0];
    cell.textLabel.font = MDThemeFont(17.0f, UIFontWeightRegular);
    cell.textLabel.textColor = MDThemeText();
    cell.detailTextLabel.text = nil;

    // The pref key rides on the switch: the handler never has to look the row
    // up, so a row added later cannot be wired to the wrong pref.
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    sw.accessibilityIdentifier = row[1];
    sw.on = ESPPrefsBool(row[1], [row[2] boolValue]);
    return cell;
}

// No log line. Every switch here writes a pref the user just set and can
// confirm by looking at the switch; a line per flip buried the boot steps
// that are the reason the Log tab exists.
- (void)switchChanged:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (key.length == 0) return;
    ESPPrefsSetBool(key, sender.isOn);
    ESPPrefsSync();
}

@end