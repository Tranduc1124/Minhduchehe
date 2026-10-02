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
//
// The items are set per row in cellForRowAtIndexPath, so one class covers Aim
// Range, Aim Mode, Aim Position, Target and Trigger.
@interface MDSegmentCell : UITableViewCell
@property (nonatomic, strong) UISegmentedControl *segment;
- (void)applyTitle:(NSString *)title items:(NSArray<NSString *> *)items selected:(NSInteger)selected;
@end

@implementation MDSegmentCell {
    NSLayoutConstraint *_widthCap;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)ident {
    self = [super initWithStyle:style reuseIdentifier:ident];
    if (!self) return nil;
    self.backgroundColor = MDThemePanel();
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.textLabel.font = MDThemeFont(17.0f, UIFontWeightRegular);
    self.textLabel.textColor = MDThemeText();

    _segment = [[UISegmentedControl alloc] initWithItems:@[ @"A", @"B" ]];
    _segment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_segment];

    // Four-option rows (Trigger) need more room than a two-option row, so the
    // cap is a constraint that moves rather than a fixed width. Held as a
    // property because the alternative is walking the constraints array on
    // every configure.
    _widthCap = [_segment.widthAnchor constraintLessThanOrEqualToConstant:140.0f];

    [NSLayoutConstraint activateConstraints:@[
        [_segment.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0f],
        [_segment.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        _widthCap,
        [_segment.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.textLabel
                                                           .leadingAnchor constant:8.0f],
    ]];
    return self;
}

- (void)applyTitle:(NSString *)title items:(NSArray<NSString *> *)items selected:(NSInteger)selected {
    self.textLabel.text = title;

    // Rebuild first, select second. Assigning selectedSegmentIndex on a control
    // that does not have that many segments yet is a no-op, so the other order
    // loses the selection on every reuse.
    if (_segment.numberOfSegments != (NSInteger)items.count) {
        [_segment removeAllSegments];
        for (NSString *item in items) {
            [_segment insertSegmentWithTitle:item
                                     atIndex:_segment.numberOfSegments
                                   animated:NO];
        }
        _widthCap.constant = items.count >= 4 ? 230.0f : (items.count == 3 ? 190.0f : 140.0f);
    }
    for (NSUInteger i = 0; i < items.count && i < (NSUInteger)_segment.numberOfSegments; i++) {
        [_segment setTitle:items[i] forSegmentAtIndex:i];
    }

    NSInteger sel = selected;
    if (sel < 0) sel = 0;
    if (sel >= _segment.numberOfSegments) sel = _segment.numberOfSegments - 1;
    _segment.selectedSegmentIndex = sel;

    [_segment setTitleTextAttributes:@{ NSFontAttributeName: MDThemeFont(13.0f, UIFontWeightMedium) }
                           forState:UIControlStateNormal];
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
            return @[ @[ @"s", @"Hide Screenshot/Recording", @"StreamerMode", @NO ] ];
        case ESPSectionDraw:
            // SbCountText used to have a row of its own, directly under this
            // one. Both drive the same counter and read as the same control, so
            // the mirror is left to the in-game menu and the ESP tab carries a
            // single switch.
            return @[
                @[ @"s", @"Enable ESP",   @"EnableESP", @NO ],
                @[ @"s", @"Line",         @"Line",      @NO ],
                @[ @"s", @"Box",          @"Box",       @YES ],
                @[ @"s", @"Bone",         @"Bone",      @NO ],
                @[ @"s", @"Health",       @"Health",    @YES ],
                @[ @"s", @"Name",         @"Name",      @YES ],
                @[ @"s", @"Distance",     @"Distance",  @YES ],
                @[ @"s", @"Player Count", @"Count",     @YES ],
            ];
        case ESPSectionView:
            return @[
                @[ @"s", @"FOV Circle",  @"ShowFovCircle", @YES ],
                @[ @"l", @"FOV Size",    @"FovSize",       @(10.0f), @(190.0f), @(120.0f) ],
                @[ @"s", @"Camera Xa",   @"CamPC",         @NO ],
                @[ @"l", @"Camera Dist", @"CamPCValue",    @(0.0f),  @(150.0f), @(30.0f) ],
            ];
        case ESPSectionAim:
            // Everything here already exists in esp.mm. None of it is new
            // behaviour: every row writes a pref that the renderer and the aim
            // loop already read, which is why this is a UI change and not a
            // port.
            //
            // AimSphereMode and AimBehindWall used to be reachable only from the
            // in-game menu, so 180/360 and wall aim were invisible from the app.
            // AimRange is the segmented control for the former; Behind Wall is a
            // switch for the latter and goes through the live setter so the
            // renderer drops its sticky lock on the same turn.
            return @[
                @[ @"s", @"Enable Aim",       @"AimMaster",    @NO ],
                @[ @"g", @"Aim Range",        @"AimSphereMode", @(0.0f),
                   @[ @"FOV", @"180°", @"360°" ] ],
                @[ @"s", @"Aim Behind Wall",  @"AimBehindWall", @NO ],
                @[ @"g", @"Aim Mode",         @"AimMode",       @(1.0f),
                   @[ @"Safe (PC)", @"Normal", @"Rage" ] ],
                @[ @"g", @"Aim Type",         @"AimTypeMode",   @(0.0f),
                   @[ @"Aimbot", @"Aim Silent" ] ],
                @[ @"s", @"Aim Silent",       @"AimSilent",     @NO ],
                @[ @"g", @"Aim Position",     @"AimPos",        @(0.0f),
                   @[ @"Head", @"Neck", @"Chest" ] ],
                @[ @"g", @"Target",           @"AimTargetMode", @(0.0f),
                   @[ @"Crosshair", @"Low HP", @"Closest" ] ],
                @[ @"g", @"Trigger",          @"TriggerMode",   @(0.0f),
                   @[ @"Auto", @"Fire", @"Scope", @"Both" ] ],
                @[ @"s", @"Aim Assist (Head)", @"AimAssist",    @NO ],
                @[ @"l", @"Aim Distance",     @"AimDistance",   @(1.0f), @(400.0f), @(200.0f) ],
                @[ @"l", @"Aim Speed",        @"AimSpeed",      @(1.0f),  @(100.0f), @(100.0f) ],
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

// Row shape is driven by the leading element: "s" switch, "g" segmented
// control, "l" slider. One table describes all three kinds, so adding a row is
// a line rather than a new branch in three places.
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *kind = [self rowAtIndexPath:indexPath][0];
    if ([kind isEqualToString:@"l"]) return 76.0f;
    if ([kind isEqualToString:@"g"]) return 58.0f;
    return 52.0f;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *row = [self rowAtIndexPath:indexPath];
    NSString *kind = row[0];
    NSString *title = row[1];
    NSString *key = row[2];
    __weak __typeof(self) weakSelf = self;

    if ([kind isEqualToString:@"l"]) {
        MDSliderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"slider"
                                                            forIndexPath:indexPath];
        float min = [row[3] floatValue];
        float max = [row[4] floatValue];
        cell.nameLabel.text = title;
        cell.slider.minimumValue = min;
        cell.slider.maximumValue = max;
        cell.slider.value = ESPPrefsFloat(key, [row[5] floatValue]);
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

    if ([kind isEqualToString:@"g"]) {
        // Row shape: kind, title, key, defaultIndex, items. Items are last so
        // the default sits where the slider rows put their minimum and the two
        // kinds read alike. Getting these two the wrong way round sends
        // floatValue to an NSArray, which is what the last crash was.
        NSArray<NSString *> *items = row[4];
        int sel = (int)ESPPrefsFloat(key, [row[3] floatValue]);
        if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
            // A malformed row must not take the app down; show it disabled.
            MDSegmentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"segment"
                                                                 forIndexPath:indexPath];
            [cell applyTitle:title items:@[ @"-" ] selected:0];
            cell.segment.enabled = NO;
            return cell;
        }
        if (sel < 0) sel = 0;
        if (sel >= (int)items.count) sel = (int)items.count - 1;

        MDSegmentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"segment"
                                                             forIndexPath:indexPath];
        [cell applyTitle:title items:items selected:sel];
        // One action for every segmented row; the pref key rides on the
        // control so nothing has to look the row up again.
        cell.segment.accessibilityIdentifier = key;
        [cell.segment removeTarget:self action:NULL forControlEvents:UIControlEventValueChanged];
        [cell.segment addTarget:self
                         action:@selector(segmentChanged:)
               forControlEvents:UIControlEventValueChanged];
        return cell;
    }

    MDToggleCell *cell = [tableView dequeueReusableCellWithIdentifier:@"toggle"
                                                        forIndexPath:indexPath];
    [cell applyTitle:title key:key on:ESPPrefsBool(key, [row[3] boolValue])];
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

    // Behind Wall has a live setter as well as the pref. esp.mm's
    // ESPSetAimBehindWallLive drops the sticky aim lock on the same call, and
    // writing only the pref would leave the renderer still locked on a target
    // it should have let go of.
    if ([key isEqualToString:@"AimBehindWall"]) {
        ESPSetAimBehindWallLive(isOn);
    }

    // Enable Aim is the master: on arms the selected type, off kills every
    // camera aim mode. Same rule the in-game menu applies, kept here so the
    // two screens cannot disagree.
    if ([key isEqualToString:@"AimMaster"]) {
        int type = (int)ESPPrefsFloat(@"AimTypeMode", 0.0f);
        if (type < 0) type = 0;
        if (type > 1) type = 1;
        ESPPrefsSetBool(@"Aimbot", isOn && type == 0);
        ESPPrefsSetBool(@"AimAssist", NO);
        // Only the camera modes reset. The range and wall switches stand on
        // their own, so a user who set 360 does not lose it every time they
        // flick the master.
        ESPPrefsSetFloat(@"AimSphereMode", 0.0f);
        ESPPrefsSync();
        ESPSyncFromPrefs();
        [self.tableView reloadRowsAtIndexPaths:@[
            [NSIndexPath indexPathForRow:1 inSection:ESPSectionAim],
            [NSIndexPath indexPathForRow:2 inSection:ESPSectionAim],
        ] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }

    ESPSyncFromPrefs();
}

// Every segmented row lands here. Only two of them need a side effect; the
// rest are a straight pref write, and treating them all the same is what keeps
// a new row from needing its own handler.
- (void)segmentChanged:(UISegmentedControl *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (key.length == 0) return;

    int idx = (int)sender.selectedSegmentIndex;
    ESPPrefsSetFloat(key, (float)idx);

    if ([key isEqualToString:@"AimTypeMode"]) {
        ESPPrefsSetBool(@"AimMaster", YES);
        ESPPrefsSetBool(@"Aimbot", idx == 0);
        ESPPrefsSetBool(@"AimSilent", idx == 1);
        ESPPrefsSetBool(@"AimAssist", NO);
        // Legacy mirror the in-game menu still reads.
        if (idx == 2) ESPPrefsSetBool(@"Aim360", YES); else ESPPrefsSetBool(@"Aim360", NO);
    } else if ([key isEqualToString:@"AimPos"]) {
        // MenuView listens for this to relabel its floating HEAD/NECK/BODY
        // button, and that menu lives in this same process, so the post lands.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"AimPosChangedNotification" object:nil];
    } else if ([key isEqualToString:@"AimSphereMode"]) {
        ESPPrefsSetBool(@"Aim360", idx == 2);
    }

    ESPPrefsSync();
    ESPSyncFromPrefs();

    if ([key isEqualToString:@"AimTypeMode"]) {
        [self.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:0 inSection:ESPSectionAim] ]
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

@end