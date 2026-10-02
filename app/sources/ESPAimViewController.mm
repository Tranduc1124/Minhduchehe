#import "ESPAimViewController.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "ESPPrefs.h"
#import "esp.h"

#pragma mark - Switch row

@interface MDToggleCell : UITableViewCell

@property (nonatomic, strong) UISwitch *toggle;

// Called when the switch flips.
//
// The cell is its own UIControl target and forwards through here instead of
// taking the controller's selector. The target of addTarget:action: is always
// the object it is called on — here, the cell — so passing in a selector the
// cell does not implement sends the message to a UITableViewCell, which does
// not recognise it and aborts. That is what the crash log shows: the switch
// asks for the action, nothing handles it, and UIResponder raises
// doesNotRecognizeSelector:. Cleared in prepareForReuse so a recycled cell
// cannot fire the previous row's handler.
@property (nonatomic, copy, nullable) void (^onToggle)(BOOL isOn);

- (void)applyTitle:(NSString *)title
               key:(NSString *)key
                on:(BOOL)on;

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
    [_toggle addTarget:self
                  action:@selector(switchFlipped:)
        forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_toggle];
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _onToggle = nil;
}

- (void)switchFlipped:(UISwitch *)sender {
    if (_onToggle) _onToggle(sender.isOn);
}

- (void)applyTitle:(NSString *)title
               key:(NSString *)key
                on:(BOOL)on {
    self.textLabel.text = title;
    self.textLabel.font = MDThemeFont(17.0f, UIFontWeightRegular);
    self.textLabel.textColor = MDThemeText();
    self.detailTextLabel.text = nil;
    _toggle.accessibilityIdentifier = key;
    _toggle.on = on;
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

#pragma mark - Segment row

// Its own cell, not a toggle cell with a segment bolted on as the accessory.
// Reusing one shared UISegmentedControl across reloads leaves UIKit holding a
// view it has already been asked to lay out again, and the toggle underneath
// stays on screen because nothing hid it.
@interface MDSegmentCell : UITableViewCell
@property (nonatomic, strong) UISegmentedControl *segment;
@end

@implementation MDSegmentCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)ident {
    self = [super initWithStyle:style reuseIdentifier:ident];
    if (!self) return nil;
    self.backgroundColor = MDThemePanel();
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.textLabel.font = MDThemeFont(17.0f, UIFontWeightRegular);
    self.textLabel.textColor = MDThemeText();

    _segment = [[UISegmentedControl alloc] initWithItems:@[ @"Aimbot", @"Aim Silent" ]];
    _segment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_segment];

    [NSLayoutConstraint activateConstraints:@[
        [_segment.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0f],
        [_segment.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_segment.widthAnchor constraintEqualToConstant:180.0f],
        [_segment.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.textLabel
                                                           .leadingAnchor constant:8.0f],
    ]];
    return self;
}

@end

#pragma mark - Controller

@implementation ESPAimViewController

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
    [self.tableView registerClass:[MDSegmentCell class] forCellReuseIdentifier:@"segment"];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    [self.tableView reloadData];
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

// Only the section that has a footer implements viewForFooterInSection, and
// only that section implements this. Returning CGFLOAT_MIN here is what iOS
// Settings does to mean "none", but mixing it with the automatic value on a
// different section in the same table is not worth the risk — a section that
// returns a footer view and no height gets measured against the view, and one
// that returns neither is asked for a height anyway.
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (section != ESPSectionScreen) return 0.0f;
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *row = [self rowAtIndexPath:indexPath];
    NSString *key = row[1];
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

    if ([key isEqualToString:@"AimTypeMode"]) {
        MDSegmentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"segment"
                                                             forIndexPath:indexPath];
        cell.textLabel.text = title;
        cell.segment.selectedSegmentIndex = (NSInteger)ESPPrefsFloat(key, 0.0f);
        [cell.segment removeTarget:self action:NULL forControlEvents:UIControlEventValueChanged];
        [cell.segment addTarget:self
                         action:@selector(aimTypeChanged:)
               forControlEvents:UIControlEventValueChanged];
        return cell;
    }

    MDToggleCell *cell = [tableView dequeueReusableCellWithIdentifier:@"toggle"
                                                        forIndexPath:indexPath];
    BOOL def = [row[2] boolValue];
    [cell applyTitle:title key:key on:ESPPrefsBool(key, def)];

    __weak __typeof(self) weakSelf = self;
    cell.onToggle = ^(BOOL isOn) {
        [weakSelf toggleChangedForKey:key isOn:isOn];
    };
    return cell;
}

#pragma mark - Actions

// The row's pref key rides on the cell, so there is no index-path lookup here
// and no way for the handler and the row it belongs to drift apart.
- (void)toggleChangedForKey:(NSString *)key isOn:(BOOL)isOn {
    if (key.length == 0) return;

    ESPPrefsSetBoolLive(key, isOn);
    ESPSyncFromPrefs();

    // Enable Aim is the master: on arms the selected type, off kills every
    // camera aim mode. Same rule the in-game menu applies, kept here so the
    // two screens cannot disagree.
    if ([key isEqualToString:@"AimMaster"]) {
        int type = (int)ESPPrefsFloat(@"AimTypeMode", 0.0f);
        if (type < 0) type = 0;
        if (type > 1) type = 1;
        ESPPrefsSetBool(@"Aimbot", isOn && type == 0);
        ESPPrefsSetBool(@"AimSilent", isOn && type == 1);
        ESPPrefsSetBool(@"AimAssist", NO);
        ESPPrefsSetFloat(@"AimSphereMode", 0.0f);
        ESPPrefsSync();
        ESPSyncFromPrefs();
        // The segment shows the type, so it has to come back into step when
        // the master kills the type.
        [self.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:1 inSection:ESPSectionAim] ]
                              withRowAnimation:UITableViewRowAnimationNone];
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
    // The master switch in this same section has to follow, and the view no
    // longer reloads itself on appear if the user never taps it.
    [self.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:0 inSection:ESPSectionAim] ]
                          withRowAnimation:UITableViewRowAnimationNone];
}

@end