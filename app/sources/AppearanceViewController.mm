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
    self.title = @"Giao diện";
    self.view.backgroundColor = MDThemeBg();
    MDThemeLoadFromPrefs();
    MDUIApplyNavigationBarStyle(self.navigationController.navigationBar);

    // Plain views, not a table: two rows of content and one card, so the
    // inset-grouped machinery would be more code than the screen itself.
    _modeRow = [[UIView alloc] initWithFrame:CGRectZero];
    _modeRow.backgroundColor = MDThemePanel();
    _modeRow.layer.cornerRadius = 14.0f;
    [self.view addSubview:_modeRow];

    _modeSeg = [[UISegmentedControl alloc] initWithItems:@[ @"Mặc định", @"Tùy chỉnh" ]];
    _modeSeg.selectedSegmentIndex = MDThemeAccentMode() == 1 ? 1 : 0;
    [_modeSeg addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [_modeRow addSubview:_modeSeg];

    _modeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _modeLabel.font = MDThemeFont(16.0f, UIFontWeightMedium);
    _modeLabel.textColor = MDThemeText();
    _modeLabel.text = @"Màu chủ đạo";
    [_modeRow addSubview:_modeLabel];

    _swatch = [[UIView alloc] initWithFrame:CGRectZero];
    _swatch.layer.cornerRadius = 8.0f;
    _swatch.layer.borderWidth = 1.0f;
    _swatch.layer.borderColor = MDThemeLine().CGColor;
    [_modeRow addSubview:_swatch];

    _hint = [[UILabel alloc] initWithFrame:CGRectZero];
    _hint.text = @"Dùng cho nút kích hoạt, slider và thanh tab.";
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

    _cursorView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    _cursorView.layer.cornerRadius = 9.0f;
    _cursorView.layer.borderWidth = 2.0f;
    _cursorView.layer.borderColor = [UIColor whiteColor].CGColor;
    _cursorView.userInteractionEnabled = NO;
    [_spectrumView addSubview:_cursorView];

    [self applyMode];
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
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat top = insets.top > 0 ? insets.top : 44.0f;
    CGFloat bottom = insets.bottom > 0 ? insets.bottom : 20.0f;
    CGFloat w = CGRectGetWidth(self.view.bounds);
    CGFloat pad = 16.0f;
    CGFloat cardW = w - pad * 2.0f;

    CGFloat rowH = 54.0f;
    CGFloat y = top + 20.0f;
    _modeRow.frame = CGRectMake(pad, y, cardW, rowH);
    _modeLabel.frame = CGRectMake(pad + 16.0f, y + 14.0f, cardW * 0.42f, 26.0f);
    _modeSeg.frame = CGRectMake(CGRectGetMinX(_modeRow.frame) + cardW - 16.0f - 216.0f,
                                y + 10.0f, 216.0f, 34.0f);
    y += rowH + 10.0f;
    _hint.frame = CGRectMake(pad + 4.0f, y, cardW - 8.0f, 34.0f);
    y += 44.0f;

    if (!_customCard.hidden) {
        CGFloat cardH = MIN(320.0f, CGRectGetHeight(self.view.bounds) - bottom - y);
        _customCard.frame = CGRectMake(pad, y, cardW, cardH);
        _rgbLabel.frame = CGRectMake(14.0f, 12.0f, cardW - 28.0f, 18.0f);
        _spectrumView.frame = CGRectMake(14.0f, 38.0f, cardW - 28.0f, cardH - 52.0f);
        [self updateCursor];
    } else {
        _customCard.frame = CGRectZero;
    }
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