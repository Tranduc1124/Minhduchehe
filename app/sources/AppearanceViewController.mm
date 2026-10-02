#import "AppearanceViewController.h"
#import "MDUI.h"
#import "MDTheme.h"
#import "ESPPrefs.h"
#import "MDLog.h"

#pragma mark - Spectrum (hue across, value down, white along the top)

static UIImage *MDSpectrumImage(void) {
    static UIImage *img;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int W = 256, H = 160;
        unsigned char *rgba = (unsigned char *)calloc((size_t)(W * H * 4), 1);
        if (!rgba) return;
        for (int y = 0; y < H; y++) {
            float v = (float)y / (float)(H - 1);
            for (int x = 0; x < W; x++) {
                float hue = (float)x / (float)(W - 1);
                float sat = 1.0f;
                float val = 1.0f - v;
                float topBlend = fmaxf(0.f, 1.f - v * 2.2f);
                float s = sat * (1.f - topBlend);
                float hh = hue * 6.f;
                int i = (int)floorf(hh);
                float f = hh - i;
                float p = val * (1.f - s);
                float q = val * (1.f - s * f);
                float t = val * (1.f - s * (1.f - f));
                float rr = 0, gg = 0, bb = 0;
                switch (i % 6) {
                    case 0: rr = val; gg = t; bb = p; break;
                    case 1: rr = q; gg = val; bb = p; break;
                    case 2: rr = p; gg = val; bb = t; break;
                    case 3: rr = p; gg = q; bb = val; break;
                    case 4: rr = t; gg = p; bb = val; break;
                    default: rr = val; gg = p; bb = q; break;
                }
                int idx = (y * W + x) * 4;
                rgba[idx + 0] = (unsigned char)(rr * 255.f);
                rgba[idx + 1] = (unsigned char)(gg * 255.f);
                rgba[idx + 2] = (unsigned char)(bb * 255.f);
                rgba[idx + 3] = 255;
            }
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(rgba, W, H, 8, W * 4, cs,
                                                 kCGImageAlphaPremultipliedLast);
        if (ctx) {
            CGImageRef cg = CGBitmapContextCreateImage(ctx);
            if (cg) {
                img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
                CGImageRelease(cg);
            }
            CGContextRelease(ctx);
        }
        if (cs) CGColorSpaceRelease(cs);
        free(rgba);
    });
    return img;
}

static void MDColorAtUV(float u, float v, float *outR, float *outG, float *outB) {
    if (u < 0) u = 0; if (u > 1) u = 1;
    if (v < 0) v = 0; if (v > 1) v = 1;
    float hue = u;
    float val = 1.0f - v;
    float topBlend = fmaxf(0.f, 1.f - v * 2.2f);
    float s = 1.0f * (1.f - topBlend);
    float hh = hue * 6.f;
    int i = (int)floorf(hh);
    float f = hh - i;
    float p = val * (1.f - s);
    float q = val * (1.f - s * f);
    float t = val * (1.f - s * (1.f - f));
    float rr = 0, gg = 0, bb = 0;
    switch (i % 6) {
        case 0: rr = val; gg = t; bb = p; break;
        case 1: rr = q; gg = val; bb = p; break;
        case 2: rr = p; gg = val; bb = t; break;
        case 3: rr = p; gg = q; bb = val; break;
        case 4: rr = t; gg = p; bb = val; break;
        default: rr = val; gg = p; bb = q; break;
    }
    if (outR) *outR = rr;
    if (outG) *outG = gg;
    if (outB) *outB = bb;
}

static void MDUVFromRGB(float r, float g, float b, float *outU, float *outV) {
    float maxc = fmaxf(r, fmaxf(g, b));
    float minc = fminf(r, fminf(g, b));
    float delta = maxc - minc;
    float hue = 0.f;
    if (delta > 0.0001f) {
        if (maxc == r) hue = fmodf((g - b) / delta, 6.f);
        else if (maxc == g) hue = (b - r) / delta + 2.f;
        else hue = (r - g) / delta + 4.f;
        hue /= 6.f;
        if (hue < 0) hue += 1.f;
    }
    if (outU) *outU = hue;
    if (outV) *outV = 1.f - maxc;
}

@interface AppearanceViewController ()
@property (nonatomic, strong) UIView *modeRow;
@property (nonatomic, strong) UISegmentedControl *modeSeg;
@property (nonatomic, strong) UIView *swatch;
@property (nonatomic, strong) UILabel *modeLabel;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UIImageView *spectrumView;
@property (nonatomic, strong) UIView *cursorView;
@property (nonatomic, strong) UILabel *rgbLabel;
@property (nonatomic, strong) UIView *customCard;
@end

@implementation AppearanceViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Appearance";
    self.view.backgroundColor = MDThemeBg();
    MDThemeLoadFromPrefs();
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);

    // Plain views, not a table: two rows of content and one card, so the
    // inset-grouped machinery would be more code than the screen itself.
    _modeRow = [[UIView alloc] initWithFrame:CGRectZero];
    _modeRow.backgroundColor = MDThemePanel();
    _modeRow.layer.cornerRadius = 14.0f;
    [self.view addSubview:_modeRow];

    _modeSeg = [[UISegmentedControl alloc] initWithItems:@[ @"Default", @"Custom" ]];
    _modeSeg.selectedSegmentIndex = MDThemeAccentMode() == 1 ? 1 : 0;
    [_modeSeg addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [_modeRow addSubview:_modeSeg];

    _modeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _modeLabel.font = MDThemeFont(16.0f, UIFontWeightMedium);
    _modeLabel.textColor = MDThemeText();
    _modeLabel.text = @"Accent Colour";
    [_modeRow addSubview:_modeLabel];

    _swatch = [[UIView alloc] initWithFrame:CGRectZero];
    _swatch.layer.cornerRadius = 8.0f;
    _swatch.layer.borderWidth = 1.0f;
    _swatch.layer.borderColor = MDThemeLine().CGColor;
    [_modeRow addSubview:_swatch];

    _hint = [[UILabel alloc] initWithFrame:CGRectZero];
    _hint.text = @"Used by the start button, sliders and the tab bar.";
    _hint.font = MDThemeFont(13.0f, UIFontWeightRegular);
    _hint.textColor = MDThemeMuted();
    _hint.numberOfLines = 0;
    [self.view addSubview:_hint];

    _customCard = [[UIView alloc] initWithFrame:CGRectZero];
    _customCard.backgroundColor = MDThemePanel();
    _customCard.layer.cornerRadius = 14.0f;
    _customCard.clipsToBounds = YES;
    [self.view addSubview:_customCard];

    _rgbLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _rgbLabel.font = MDUIMonoFont(12.0f, UIFontWeightSemibold);
    _rgbLabel.textColor = MDThemeMuted();
    _rgbLabel.textAlignment = NSTextAlignmentCenter;
    [_customCard addSubview:_rgbLabel];

    _spectrumView = [[UIImageView alloc] initWithImage:MDSpectrumImage()];
    _spectrumView.contentMode = UIViewContentModeScaleToFill;
    _spectrumView.userInteractionEnabled = YES;
    _spectrumView.layer.cornerRadius = 10.0f;
    _spectrumView.clipsToBounds = YES;
    [_customCard addSubview:_spectrumView];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(spectrumGesture:)];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(spectrumGesture:)];
    [_spectrumView addGestureRecognizer:pan];
    [_spectrumView addGestureRecognizer:tap];

    _cursorView = [[UIView alloc] initWithFrame:CGRectZero];
    _cursorView.layer.cornerRadius = 9.0f;
    _cursorView.layer.borderWidth = 2.0f;
    _cursorView.layer.borderColor = [UIColor whiteColor].CGColor;
    _cursorView.userInteractionEnabled = NO;
    _cursorView.translatesAutoresizingMaskIntoConstraints = NO;
    [_spectrumView addSubview:_cursorView];

    [self buildConstraints];
    [self applyMode];
}

// One constraint set, built once, instead of frames assigned in
// viewDidLayoutSubviews. The old version positioned the row, the hint and the
// card by arithmetic against the view height, so the card landed off-screen on
// a short device and the cursor was placed from a zero-sized spectrum the first
// time through.
- (void)buildConstraints {
    for (UIView *v in @[ _modeRow, _hint, _customCard, _spectrumView, _rgbLabel, _cursorView ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
    }

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [_modeRow setContentCompressionResistancePriority:UILayoutPriorityRequired
                                             forAxis:UILayoutConstraintAxisVertical];
    [_customCard setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisVertical];

    [NSLayoutConstraint activateConstraints:@[
        [_modeRow.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20.0f],
        [_modeRow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16.0f],
        [_modeRow.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0f],
        [_modeRow.heightAnchor constraintEqualToConstant:54.0f],

        [_modeLabel.leadingAnchor constraintEqualToAnchor:_modeRow.leadingAnchor constant:16.0f],
        [_modeLabel.centerYAnchor constraintEqualToAnchor:_modeRow.centerYAnchor],
        [_swatch.leadingAnchor constraintEqualToAnchor:_modeLabel.trailingAnchor constant:10.0f],
        [_swatch.centerYAnchor constraintEqualToAnchor:_modeRow.centerYAnchor],
        [_swatch.widthAnchor constraintEqualToConstant:24.0f],
        [_swatch.heightAnchor constraintEqualToConstant:24.0f],

        [_modeSeg.leadingAnchor constraintGreaterThanOrEqualToAnchor:_swatch.trailingAnchor
                                                            constant:12.0f],
        [_modeSeg.trailingAnchor constraintEqualToAnchor:_modeRow.trailingAnchor constant:-16.0f],
        [_modeSeg.centerYAnchor constraintEqualToAnchor:_modeRow.centerYAnchor],
        [_modeSeg.widthAnchor constraintEqualToConstant:190.0f],
        [_modeSeg.heightAnchor constraintEqualToConstant:34.0f],

        [_hint.topAnchor constraintEqualToAnchor:_modeRow.bottomAnchor constant:10.0f],
        [_hint.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20.0f],
        [_hint.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20.0f],

        [_customCard.topAnchor constraintEqualToAnchor:_hint.bottomAnchor constant:18.0f],
        [_customCard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16.0f],
        [_customCard.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0f],
        // Grows into whatever the device has left, capped so it does not turn
        // into a wall of colour on an iPad.
        [_customCard.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                constant:-20.0f],
        [_customCard.heightAnchor constraintLessThanOrEqualToConstant:320.0f],

        [_rgbLabel.topAnchor constraintEqualToAnchor:_customCard.topAnchor constant:12.0f],
        [_rgbLabel.leadingAnchor constraintEqualToAnchor:_customCard.leadingAnchor constant:14.0f],
        [_rgbLabel.trailingAnchor constraintEqualToAnchor:_customCard.trailingAnchor constant:-14.0f],

        [_spectrumView.topAnchor constraintEqualToAnchor:_rgbLabel.bottomAnchor constant:8.0f],
        [_spectrumView.leadingAnchor constraintEqualToAnchor:_customCard.leadingAnchor constant:14.0f],
        [_spectrumView.trailingAnchor constraintEqualToAnchor:_customCard.trailingAnchor constant:-14.0f],
        [_spectrumView.bottomAnchor constraintEqualToAnchor:_customCard.bottomAnchor constant:-14.0f],

        [_cursorView.centerXAnchor constraintEqualToAnchor:_spectrumView.centerXAnchor],
        [_cursorView.centerYAnchor constraintEqualToAnchor:_spectrumView.centerYAnchor],
        [_cursorView.widthAnchor constraintEqualToConstant:18.0f],
        [_cursorView.heightAnchor constraintEqualToConstant:18.0f],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);
    MDThemeLoadFromPrefs();
    _modeSeg.selectedSegmentIndex = MDThemeAccentMode() == 1 ? 1 : 0;
    [self applyMode];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // The spectrum's frame is what the UV mapping is computed against, so the
    // cursor can only be placed once there is a real size to divide by.
    [self updateCursor];
}

#pragma mark - Accent

- (void)applyMode {
    BOOL custom = (MDThemeAccentMode() == 1);
    _customCard.hidden = !custom;
    _swatch.backgroundColor = MDThemeAccent();
    _swatch.layer.borderColor = MDThemeLine().CGColor;

    float r = kMDThemeDefaultAccentR, g = kMDThemeDefaultAccentG, b = kMDThemeDefaultAccentB;
    if (custom) {
        r = ESPPrefsFloat(@"AppAccentColorR", kMDThemeDefaultAccentR);
        g = ESPPrefsFloat(@"AppAccentColorG", kMDThemeDefaultAccentG);
        b = ESPPrefsFloat(@"AppAccentColorB", kMDThemeDefaultAccentB);
    }
    _rgbLabel.text = [NSString stringWithFormat:@"R %.0f   G %.0f   B %.0f", r * 255.f, g * 255.f, b * 255.f];

    _modeSeg.selectedSegmentTintColor = [MDThemeAccent() colorWithAlphaComponent:0.30f];
    [_modeSeg setTitleTextAttributes:@{ NSForegroundColorAttributeName: MDThemeText() }
                             forState:UIControlStateNormal];
    [self.view setNeedsLayout];
}

- (void)updateCursor {
    float r = kMDThemeDefaultAccentR, g = kMDThemeDefaultAccentG, b = kMDThemeDefaultAccentB;
    if (MDThemeAccentMode() == 1) {
        r = ESPPrefsFloat(@"AppAccentColorR", kMDThemeDefaultAccentR);
        g = ESPPrefsFloat(@"AppAccentColorG", kMDThemeDefaultAccentG);
        b = ESPPrefsFloat(@"AppAccentColorB", kMDThemeDefaultAccentB);
    }
    float u = 0, v = 0;
    MDUVFromRGB(r, g, b, &u, &v);
    CGSize sz = _spectrumView.bounds.size;
    if (sz.width > 1.0f && sz.height > 1.0f) {
        _cursorView.center = CGPointMake(u * sz.width, v * sz.height);
    }
}

- (void)modeChanged {
    int mode = (int)_modeSeg.selectedSegmentIndex;
    ESPPrefsSetFloat(@"AppAccentMode", (float)mode);
    ESPPrefsSetFloat(@"AppAccentColorMode", 0.0f);
    ESPPrefsSync();
    MDThemeNotifyChanged();
    [self applyMode];
    [MDLog appendLine:[NSString stringWithFormat:@"OK Accent mode = %@",
                       mode == 1 ? @"custom" : @"default"]];
}

- (void)spectrumGesture:(UIGestureRecognizer *)gr {
    CGPoint p = [gr locationInView:_spectrumView];
    CGFloat w = _spectrumView.bounds.size.width;
    CGFloat h = _spectrumView.bounds.size.height;
    if (w < 1.0f || h < 1.0f) return;

    float u = (float)(p.x / w);
    float v = (float)(p.y / h);
    float r, g, b;
    MDColorAtUV(u, v, &r, &g, &b);

    // Live writes are memory-only; the disk flush is one ESPPrefsSync on lift.
    ESPPrefsSetFloatLive(@"AppAccentColorR", r);
    ESPPrefsSetFloatLive(@"AppAccentColorG", g);
    ESPPrefsSetFloatLive(@"AppAccentColorB", b);

    _cursorView.center = CGPointMake(MAX(9.0f, MIN(w - 9.0f, p.x)),
                                     MAX(9.0f, MIN(h - 9.0f, p.y)));
    _rgbLabel.text = [NSString stringWithFormat:@"R %.0f   G %.0f   B %.0f",
                      r * 255.f, g * 255.f, b * 255.f];

    // Notify on lift only. MDThemeNotifyChanged re-applies the tab bar
    // appearance, and doing that on every touch-move is what made the old
    // sheet feel heavy.
    if (gr.state == UIGestureRecognizerStateEnded ||
        gr.state == UIGestureRecognizerStateCancelled) {
        ESPPrefsSetFloat(@"AppAccentColorR", r);
        ESPPrefsSetFloat(@"AppAccentColorG", g);
        ESPPrefsSetFloat(@"AppAccentColorB", b);
        ESPPrefsSetFloat(@"AppAccentMode", 1.0f);
        ESPPrefsSync();
        MDThemeNotifyChanged();
        [self applyMode];
    } else {
        MDThemeLoadFromPrefs();
        _swatch.backgroundColor = MDThemeAccent();
        _modeSeg.selectedSegmentTintColor = [MDThemeAccent() colorWithAlphaComponent:0.30f];
    }
}

@end