#import "ESPAimViewController.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "ESPPrefs.h"
#import "esp.h"

#pragma mark - Switch row

@interface MDToggleCell : UITableViewCell
@property (nonatomic, strong) UISwitch *toggle;
- (void)applyTitle:(NSString *)title
               key:(NSString *)key
                on:(BOOL)on
          selector:(SEL)sel;
@end

@implementation MDToggleCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)ident {
    self = [super initWithStyle:style reuseIdentifier:ident];
    if (!self) return nil;
    self.backgroundColor = MDThemePanel();

    _toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    // System green, like the reference. MDThemeAccent here would tint every
    // switch mint and the screen stops reading as iOS.
    _toggle.onTintColor = [UIColor colorWithRed:0.20f green:0.78f blue:0.35f alpha:1.0f];
    [self.contentView addSubview:_toggle];
    return self;
}

- (void)applyTitle:(NSString *)title
               key:(NSString *)key
                on:(BOOL)on
          selector:(SEL)sel {
    self.textLabel.text = title;
    self.textLabel.font = MDThemeFont(17.0f, UIFontWeightRegular);
    self.textLabel.textColor = MDThemeText();
    self.detailTextLabel.text = nil;
    _toggle.accessibilityIdentifier = key;
    _toggle.on = on;
    [_toggle removeTarget:self action:NULL forControlEvents:UIControlEventValueChanged];
    [_toggle addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize sz = _toggle.intrinsicContentSize;
    // Keep the native trailing inset regardless of the label.
    CGFloat x = CGRectGetWidth(self.contentView.bounds) - sz.width - 16.0f;
    _toggle.frame = CGRectMake(x, (CGRectGetHeight(self.contentView.bounds) - sz.height) * 0.5f,
                               sz.width, sz.height);
}

@end

#pragma mark - Slider row

@interface MDSliderCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, copy) void (^onLive)(UISlider *slider);
@property (nonatomic, copy) void (^onCommit)(UISlider *slider);
@end

@implementation MDSliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)ident {
    self = [super initWithStyle:style reuseIdentifier:ident];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = MDThemePanel();

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.font = MDThemeFont(15.0f, UIFontWeightMedium);
    _nameLabel.textColor = MDThemeText();
    [self.contentView addSubview:_nameLabel];

    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.font = MDUIMonoFont(13.0f, UIFontWeightSemibold);
    _valueLabel.textColor = MDThemeAccent();
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:_valueLabel];

    _slider = [[UISlider alloc] initWithFrame:CGRectZero];
    _slider.minimumTrackTintColor = MDThemeAccent();
    [_slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(sliderReleased:)
        forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside)];
    [self.contentView addSubview:_slider];
    return self;
}

- (void)sliderMoved:(UISlider *)sender {
    if (_onLive) _onLive(sender);
}

- (void)sliderReleased:(UISlider *)sender {
    if (_onCommit) _onCommit(sender);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.contentView.bounds);
    CGFloat pad = 16.0f;
    _nameLabel.frame = CGRectMake(pad, 10.0f, w - pad * 2.0f - 70.0f, 20.0f);
    _valueLabel.frame = CGRectMake(w - pad - 66.0f, 10.0f, 66.0f, 20.0f);
    _slider.frame = CGRectMake(pad, 36.0f, w - pad * 2.0f, 30.0f);
}

@end

#pragma mark - Controller

typedef NS_ENUM(NSInteger, ESPSection) {
    ESPSectionScreen = 0,
    ESPSectionDraw,
    ESPSectionView,
    ESPSectionAim,
    ESPSectionCount
};

@implementation ESPAimViewController {
    UISegmentedControl *_aimTypeSeg;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"ESP/AIM";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MDThemeBg();
    self.tableView.backgroundColor = MDThemeBg();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 52.0f;
    [self.tableView registerClass:[MDToggleCell class] forCellReuseIdentifier:@"toggle"];
    [self.tableView registerClass:[MDSliderCell class] forCellReuseIdentifier:@"slider"];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    [self reloadSectionRows];
}

- (void)reloadSectionRows {
    NSMutableIndexSet *idx = [NSMutableIndexSet indexSet];
    for (NSInteger s = 0; s < ESPSectionCount; s++) [idx addIndex:s];
    [self.tableView reloadSections:idx withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Rows

// title, pref key, default value (BOOL as NSNumber, float as NSNumber).
- (NSArray<NSArray *> *)rowsInSection:(NSInteger)section {
    switch (section) {
        case ESPSectionScreen:
            return @[ @[ @"Hide Screenshot/Recording", @"StreamerMode", @NO ] ];
        case ESPSectionDraw:
            return @[
                @[ @"Enable ESP",   @"EnableESP", @NO ],
                @[ @"Line",         @"Line",      @NO ],
                @[ @"Box",          @"Box",       @YES ],
                @[ @"Bone",         @"Bone",      @NO ],
                @[ @"Health",       @"Health",    @YES ],
                @[ @"Name",         @"Name",      @YES ],
                @[ @"Distance",     @"Distance",  @YES ],
                @[ @"Player Count", @"Count",     @YES ],
                @[ @"Count on SpringBoard", @"SbCountText", @NO ],
            ];
        case ESPSectionView:
            return @[
                @[ @"FOV Circle",  @"ShowFovCircle", @YES ],
                @[ @"FOV Size",    @"FovSize",       @(120.0f) ],
                @[ @"Camera Xa",   @"CamPC",         @NO ],
                @[ @"Camera Dist", @"CamPCValue",    @(30.0f) ],
            ];
        case ESPSectionAim:
            return @[
                @[ @"Enable Aim", @"AimMaster", @NO ],
                @[ @"Aim Type",   @"AimTypeMode", @(0.0f) ],
                @[ @"Enable Aim Assist (Head)", @"AimAssist", @NO ],
            ];
    }
    return @[];
}

- (NSArray *)rowAtIndexPath:(NSIndexPath *)indexPath {
    return [self rowsInSection:indexPath.section][indexPath.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return ESPSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self rowsInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ESPSectionScreen: return @"SCREEN";
        case ESPSectionDraw:   return @"DRAW";
        case ESPSectionView:   return @"VIEW";
        case ESPSectionAim:    return @"AIM";
    }
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section != ESPSectionScreen) return nil;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = @"Hides overlay views from screenshots and screen recordings.";
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
    return section == ESPSectionScreen ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *key = [self rowAtIndexPath:indexPath][1];
    if ([key isEqualToString:@"FovSize"] || [key isEqualToString:@"CamPCValue"]) return 76.0f;
    if ([key isEqualToString:@"AimTypeMode"]) return 58.0f;
    return 52.0f;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *row = [self rowAtIndexPath:indexPath];
    NSString *title = row[0];
    NSString *key = row[1];

    if ([key isEqualToString:@"FovSize"] || [key isEqualToString:@"CamPCValue"]) {
        MDSliderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"slider"
                                                            forIndexPath:indexPath];
        BOOL isFov = [key isEqualToString:@"FovSize"];
        cell.nameLabel.text = title;
        cell.slider.minimumValue = isFov ? 10.0f : 0.0f;
        cell.slider.maximumValue = isFov ? 190.0f : 150.0f;
        cell.slider.value = ESPPrefsFloat(key, [row[2] floatValue]);
        cell.valueLabel.text = [NSString stringWithFormat:@"%.0f", cell.slider.value];

        __weak MDSliderCell *weakCell = cell;
        cell.onLive = ^(UISlider *s) {
            // Memory-only while the finger is down. The reader in esp.mm
            // re-reads the pref every frame, so disk is irrelevant here and
            // writing it on every move is what made the old menu stutter.
            ESPPrefsSetFloatLive(key, (float)s.value);
            weakCell.valueLabel.text = [NSString stringWithFormat:@"%.0f", s.value];
        };
        cell.onCommit = ^(UISlider *s) {
            ESPPrefsSetFloat(key, (float)s.value);
            ESPPrefsSync();
            ESPSyncFromPrefs();
        };
        return cell;
    }

    MDToggleCell *cell = [tableView dequeueReusableCellWithIdentifier:@"toggle"
                                                        forIndexPath:indexPath];

    if ([key isEqualToString:@"AimTypeMode"]) {
        // One segment control, kept as the cell's accessoryView so a reload
        // reuses it instead of stacking a new one on the content view.
        if (!_aimTypeSeg) {
            _aimTypeSeg = [[UISegmentedControl alloc] initWithItems:@[ @"Aimbot", @"Aim Silent" ]];
            [_aimTypeSeg addTarget:self
                             action:@selector(aimTypeChanged:)
                   forControlEvents:UIControlEventValueChanged];
        }
        _aimTypeSeg.selectedSegmentIndex = (NSInteger)ESPPrefsFloat(key, 0.0f);
        cell.accessoryView = _aimTypeSeg;
        cell.textLabel.text = title;
        cell.textLabel.font = MDThemeFont(17.0f, UIFontWeightRegular);
        cell.textLabel.textColor = MDThemeText();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    BOOL def = [row[2] boolValue];
    [cell applyTitle:title
                 key:key
                  on:ESPPrefsBool(key, def)
            selector:@selector(toggleChanged:)];
    cell.accessoryView = nil;
    return cell;
}

#pragma mark - Actions

// The row's pref key rides on the switch itself, so there is no index-path
// lookup here and no way for the handler and the cell to drift apart.
- (void)toggleChanged:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (key.length == 0) return;

    ESPPrefsSetBoolLive(key, sender.isOn);
    ESPSyncFromPrefs();

    // Enable Aim is the master: on arms the selected type, off kills every
    // camera aim mode. Same rule the in-game menu applies, kept here so the
    // two screens cannot disagree.
    if ([key isEqualToString:@"AimMaster"]) {
        int type = (int)ESPPrefsFloat(@"AimTypeMode", 0.0f);
        if (type < 0) type = 0;
        if (type > 1) type = 1;
        ESPPrefsSetBool(@"Aimbot", sender.isOn && type == 0);
        ESPPrefsSetBool(@"AimSilent", sender.isOn && type == 1);
        ESPPrefsSetBool(@"AimAssist", NO);
        ESPPrefsSetFloat(@"AimSphereMode", 0.0f);
        ESPPrefsSync();
        ESPSyncFromPrefs();
    }
}

- (void)aimTypeChanged:(UISegmentedControl *)sender {
    int idx = (int)sender.selectedSegmentIndex;
    ESPPrefsSetFloat(@"AimTypeMode", (float)idx);
    ESPPrefsSetBool(@"AimMaster", YES);
    ESPPrefsSetBool(@"Aimbot", idx == 0);
    ESPPrefsSetBool(@"AimSilent", idx == 1);
    ESPPrefsSetBool(@"AimAssist", NO);
    ESPPrefsSync();
    ESPSyncFromPrefs();
    [self reloadSectionRows];
}

@end