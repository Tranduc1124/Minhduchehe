#import "LaunchOptionsViewController.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "ESPPrefs.h"
#import "MDLog.h"

@interface LaunchOptionsViewController ()
@property (nonatomic, strong) UISwitch *varCleanSwitch;
@end

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
    self.tableView.rowHeight = 52.0f;
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    _varCleanSwitch.on = ESPPrefsBool(@"AutoVarCleanBeforeHUD", NO);
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"PREPARE" : @"COMING";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Runs VarClean before the kernel boot when activating ESP.";
    }
    return @"More launch options will be added here.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *ident = @"lo";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ident];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:ident];
        cell.backgroundColor = MDThemePanel();
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0) {
        cell.textLabel.text = @"VarClean Before ESP";
        cell.textLabel.font = MDThemeFont(17.0f, UIFontWeightRegular);
        cell.textLabel.textColor = MDThemeText();
        if (!_varCleanSwitch) {
            _varCleanSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
            _varCleanSwitch.onTintColor = MDThemeAccent();
            [_varCleanSwitch addTarget:self
                                 action:@selector(varCleanChanged:)
                       forControlEvents:UIControlEventValueChanged];
        }
        _varCleanSwitch.on = ESPPrefsBool(@"AutoVarCleanBeforeHUD", NO);
        cell.accessoryView = _varCleanSwitch;
        cell.detailTextLabel.text = nil;
    } else {
        cell.textLabel.text = @"Chưa có tuỳ chọn";
        cell.textLabel.font = MDThemeFont(17.0f, UIFontWeightRegular);
        cell.textLabel.textColor = MDThemeMuted();
        cell.accessoryView = nil;
        cell.detailTextLabel.text = nil;
    }
    return cell;
}

- (void)varCleanChanged:(UISwitch *)sender {
    ESPPrefsSetBool(@"AutoVarCleanBeforeHUD", sender.isOn);
    ESPPrefsSync();
    [MDLog appendLine:[NSString stringWithFormat:@"OK AutoVarCleanBeforeHUD = %@",
                       sender.isOn ? @"ON" : @"OFF"]];
}

@end