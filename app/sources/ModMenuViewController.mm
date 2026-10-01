#import "ModMenuViewController.h"
#import "esp.h"
#import "ESPPrefs.h"
#import "menu.h"
#import "mahoa.h"
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#include "../oxorany/oxorany_include.h"

extern "C" void ToggleSpeedX50(bool enable);

// Wide horizontal panel + left side navigation (ported from minhduc-menu-ui-upgraded)
static const CGFloat kPanelWidth = 600.0f;
static const CGFloat kPanelHeight = 340.0f;
static const CGFloat kHeaderHeight = 56.0f;
static const CGFloat kSideNavWidth = 118.0f;
static const CGFloat kFooterHeight = 30.0f;
static const CGFloat kContentWidth = kPanelWidth - kSideNavWidth;
static const CGFloat kContentHeight = kPanelHeight - kHeaderHeight - kFooterHeight;
static const CGFloat kRowHeight = 44.0f;

// Theme tokens — dynamic dark/light + accent (default mint or custom picker).
// AppThemeMode: 0=Dark, 1=Light (bool prefs historically treated YES as light).
// AppAccentMode: 0=Default mint, 1=Custom RGB (AppAccentColorR/G/B).
static BOOL g_mdLight = NO;
static int g_mdAccentMode = 0; // 0 default, 1 custom
static float g_mdAR = 0.208f, g_mdAG = 0.827f, g_mdAB = 0.604f; // mint default

static const float kMDDefaultAccentR = 0.208f;
static const float kMDDefaultAccentG = 0.827f;
static const float kMDDefaultAccentB = 0.604f;

static void MDLoadThemeFromPrefs(void) {
    g_mdLight = ESPPrefsBool(@(oxorany("AppThemeMode")), NO) ? YES : NO;
    g_mdAccentMode = (int)ESPPrefsFloat(@(oxorany("AppAccentMode")), 0.0f);
    if (g_mdAccentMode < 0) g_mdAccentMode = 0;
    if (g_mdAccentMode > 1) g_mdAccentMode = 1;
    if (g_mdAccentMode == 0) {
        g_mdAR = kMDDefaultAccentR;
        g_mdAG = kMDDefaultAccentG;
        g_mdAB = kMDDefaultAccentB;
    } else {
        g_mdAR = ESPPrefsFloat(@(oxorany("AppAccentColorR")), kMDDefaultAccentR);
        g_mdAG = ESPPrefsFloat(@(oxorany("AppAccentColorG")), kMDDefaultAccentG);
        g_mdAB = ESPPrefsFloat(@(oxorany("AppAccentColorB")), kMDDefaultAccentB);
        if (g_mdAR < 0) g_mdAR = 0; if (g_mdAR > 1) g_mdAR = 1;
        if (g_mdAG < 0) g_mdAG = 0; if (g_mdAG > 1) g_mdAG = 1;
        if (g_mdAB < 0) g_mdAB = 0; if (g_mdAB > 1) g_mdAB = 1;
    }
}

static inline UIColor *MDBg(void) {
    return g_mdLight
        ? [UIColor colorWithRed:0.945f green:0.953f blue:0.965f alpha:1.0f]
        : [UIColor colorWithRed:0.027f green:0.067f blue:0.114f alpha:1.0f];
}
static inline UIColor *MDPanel(void) {
    return g_mdLight
        ? [UIColor colorWithRed:1.0f green:1.0f blue:1.0f alpha:0.98f]
        : [UIColor colorWithRed:0.047f green:0.090f blue:0.145f alpha:0.98f];
}
static inline UIColor *MDPanel2(void) {
    return g_mdLight
        ? [UIColor colorWithRed:0.945f green:0.953f blue:0.965f alpha:0.98f]
        : [UIColor colorWithRed:0.071f green:0.122f blue:0.188f alpha:0.95f];
}
static inline UIColor *MDLine(void) {
    return g_mdLight
        ? [UIColor colorWithWhite:0.0f alpha:0.10f]
        : [UIColor colorWithWhite:1.0f alpha:0.085f];
}
static inline UIColor *MDText(void) {
    return g_mdLight
        ? [UIColor colorWithRed:0.08f green:0.10f blue:0.14f alpha:1.0f]
        : [UIColor colorWithRed:0.969f green:0.976f blue:1.0f alpha:1.0f];
}
static inline UIColor *MDMuted(void) {
    return g_mdLight
        ? [UIColor colorWithRed:0.40f green:0.45f blue:0.52f alpha:1.0f]
        : [UIColor colorWithRed:0.533f green:0.580f blue:0.659f alpha:1.0f];
}
static inline UIColor *MDAccent(void) {
    return [UIColor colorWithRed:g_mdAR green:g_mdAG blue:g_mdAB alpha:1.0f];
}
static inline UIColor *MDAccentSoft(CGFloat a) {
    return [UIColor colorWithRed:g_mdAR green:g_mdAG blue:g_mdAB alpha:a];
}
static inline UIColor *MDBlue(void) { return [UIColor colorWithRed:0.220f green:0.741f blue:0.973f alpha:1.0f]; }
static inline UIColor *MDRed(void) { return [UIColor colorWithRed:0.984f green:0.443f blue:0.522f alpha:1.0f]; }
static inline UIColor *MDPurple(void) { return [UIColor colorWithRed:0.545f green:0.486f blue:0.965f alpha:1.0f]; }
static inline UIColor *MDOrange(void) { return [UIColor colorWithRed:0.984f green:0.573f blue:0.235f alpha:1.0f]; }
static inline UIColor *MDCyan(void) { return [UIColor colorWithRed:0.133f green:0.827f blue:0.933f alpha:1.0f]; }

// Register bundled Inter + Font Awesome once (offline, no CDN).
static void MDRegisterMenuFontsOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Theos RESOURCE_DIRS flattens Font/ into app root.
        NSArray *files = @[
            @"Inter-Regular.ttf",
            @"Inter-Medium.ttf",
            @"Inter-SemiBold.ttf",
            @"Inter-Bold.ttf",
            @"fa-solid-900.ttf",
            @"fa-regular-400.ttf",
            @"Font/Inter-Regular.ttf",
            @"Font/Inter-Medium.ttf",
            @"Font/Inter-SemiBold.ttf",
            @"Font/Inter-Bold.ttf",
            @"Font/fa-solid-900.ttf",
            @"Font/fa-regular-400.ttf"
        ];
        NSString *base = [[NSBundle mainBundle] bundlePath];
        for (NSString *rel in files) {
            NSString *path = [base stringByAppendingPathComponent:rel];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data.length) continue;
            CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
            if (!provider) continue;
            CGFontRef font = CGFontCreateWithDataProvider(provider);
            if (font) {
                CTFontManagerRegisterGraphicsFont(font, NULL);
                CGFontRelease(font);
            }
            CGDataProviderRelease(provider);
        }
    });
}

static UIFont *MDFont(CGFloat size, UIFontWeight weight) {
    MDRegisterMenuFontsOnce();
    NSString *name = @"Inter-Regular";
    if (weight >= UIFontWeightBold) name = @"Inter-Bold";
    else if (weight >= UIFontWeightSemibold) name = @"Inter-SemiBold";
    else if (weight >= UIFontWeightMedium) name = @"Inter-Medium";
    UIFont *f = [UIFont fontWithName:name size:size];
    if (f) return f;
    // Variable/PostScript name fallbacks
    NSArray *alts = @[@"Inter", @"Inter Regular", @"Inter-Regular"];
    if (weight >= UIFontWeightBold) alts = @[@"Inter-Bold", @"Inter Bold", @"Inter"];
    else if (weight >= UIFontWeightSemibold) alts = @[@"Inter-SemiBold", @"Inter SemiBold", @"Inter"];
    else if (weight >= UIFontWeightMedium) alts = @[@"Inter-Medium", @"Inter Medium", @"Inter"];
    for (NSString *n in alts) {
        f = [UIFont fontWithName:n size:size];
        if (f) return f;
    }
    return [UIFont systemFontOfSize:size weight:weight];
}

// Font Awesome 6 Free codepoints (solid unless noted)
static NSString *MDFA(NSString *key) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Use FA6 Free Solid desktop codepoints (fxxx). Newer e-range PUA
        // glyphs (e.g. sparkles e28e) often render blank/tofu in fa-solid-900.
        map = @{
            @"bolt": @"",
            @"xmark": @"",
            @"eye": @"",
            @"crosshairs": @"",
            @"sparkles": @"",                 // fa-sparkles
            @"sliders": @"",
            @"info": @"",
            @"check": @"",
            @"user": @"",
            @"circle-dot": @"",
            @"bullseye": @"",
            @"shield": @"",
            @"gear": @"",
            @"moon": @"",
            @"sun": @"",
            @"code": @"",
            @"palette": @"",
            @"layer": @"",
            @"language": @"",
            @"wand": @"",                     // fa-wand-magic-sparkles
            @"volume": @"",
            @"save": @"",
            @"filter": @"",
            @"circle": @"",
        };
    });
    NSString *v = map[key];
    return v ?: @"";
}


static UIFont *MDFAFont(CGFloat size, BOOL regular) {
    MDRegisterMenuFontsOnce();
    NSString *name = regular ? @"FontAwesome6Free-Regular" : @"FontAwesome6Free-Solid";
    UIFont *f = [UIFont fontWithName:name size:size];
    if (f) return f;
    // Common PostScript names
    NSArray *alts = regular
        ? @[@"FontAwesome6Free-Regular", @"Font Awesome 6 Free", @"FontAwesome6Free-Regular"]
        : @[@"FontAwesome6Free-Solid", @"Font Awesome 6 Free Solid", @"FontAwesome6Free-Solid"];
    for (NSString *n in alts) {
        f = [UIFont fontWithName:n size:size];
        if (f) return f;
    }
    // Last resort: try listing by family
    for (NSString *fam in [UIFont familyNames]) {
        if ([fam.lowercaseString containsString:@"awesome"] || [fam.lowercaseString containsString:@"font awesome"]) {
            for (NSString *fn in [UIFont fontNamesForFamilyName:fam]) {
                BOOL isReg = [fn.lowercaseString containsString:@"regular"];
                if ((regular && isReg) || (!regular && !isReg)) {
                    f = [UIFont fontWithName:fn size:size];
                    if (f) return f;
                }
            }
            NSArray *names = [UIFont fontNamesForFamilyName:fam];
            if (names.count) {
                f = [UIFont fontWithName:names.firstObject size:size];
                if (f) return f;
            }
        }
    }
    return [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
}

static UILabel *MDFALabel(NSString *key, CGFloat size, UIColor *color) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = MDFA(key);
    l.font = MDFAFont(size, NO);
    l.textColor = color ?: MDAccent();
    l.textAlignment = NSTextAlignmentCenter;
    return l;
}

// Keep SF Symbol helper as fallback image API used by older code paths.
static UIImage *MDSymbol(NSString *name, CGFloat pointSize) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
        return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}
static const CGFloat kSegmentTrackTag = 9101;
static const CGFloat kSegmentLabelTag = 9201;
static const NSInteger kMultiSelectTrackTag = 9111;
static const NSInteger kTabCount = 4;

static const void *kSegCellsKey = &kSegCellsKey;
static const void *kSegComboPrefsKey = &kSegComboPrefsKey;
static const void *kSegTypeKey = &kSegTypeKey;
static const void *kMultiSelectKeysKey = &kMultiSelectKeysKey;
static const void *kKeyKey = &kKeyKey;
static const void *kLabelKey = &kLabelKey;
static const void *kColorPrefixKey = &kColorPrefixKey;
static const void *kColorPreviewKey = &kColorPreviewKey;
static const void *kColorCursorKey = &kColorCursorKey;
static const void *kColorSpectrumKey = &kColorSpectrumKey;
static const NSInteger kColorSwatchBaseTag = 8800;
static const NSInteger kColorBoardTag = 8701;
static const NSInteger kColorSpectrumTag = 8702;

// Quick presets under spectrum (like screenshot chips)
static const float kESPColorPresets[][3] = {
    {0.00f, 0.00f, 0.00f}, // Black
    {0.15f, 0.45f, 1.00f}, // Blue
    {0.20f, 0.85f, 0.30f}, // Green
    {1.00f, 0.90f, 0.10f}, // Yellow
    {1.00f, 0.25f, 0.25f}, // Red
    {1.00f, 0.40f, 0.90f}, // Magenta
    {0.00f, 1.00f, 1.00f}, // Cyan
};
static const NSInteger kESPColorPresetCount = 7;

// Cached spectrum image (hue vertical, white→color→black horizontal)
static UIImage *ESPSpectrumImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const NSInteger W = 256, H = 256;
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(W * H * 4)];
        uint8_t *px = (uint8_t *)data.mutableBytes;
        for (NSInteger y = 0; y < H; y++) {
            CGFloat hue = (CGFloat)y / (CGFloat)(H - 1); // top→bottom hue
            for (NSInteger x = 0; x < W; x++) {
                CGFloat t = (CGFloat)x / (CGFloat)(W - 1); // left white → mid pure → right black
                CGFloat sat, val;
                if (t <= 0.5) {
                    sat = t * 2.0;
                    val = 1.0;
                } else {
                    sat = 1.0;
                    val = 1.0 - (t - 0.5) * 2.0;
                }
                UIColor *c = [UIColor colorWithHue:hue saturation:sat brightness:val alpha:1.0];
                CGFloat r, g, b, a;
                [c getRed:&r green:&g blue:&b alpha:&a];
                NSInteger i = (y * W + x) * 4;
                px[i + 0] = (uint8_t)(r * 255.0);
                px[i + 1] = (uint8_t)(g * 255.0);
                px[i + 2] = (uint8_t)(b * 255.0);
                px[i + 3] = 255;
            }
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, W, H, 8, W * 4, cs,
                                                 kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast);
        CGImageRef cg = CGBitmapContextCreateImage(ctx);
        img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
        CGImageRelease(cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
    });
    return img;
}

static void ESPRGBtoSpectrumUV(float r, float g, float b, CGFloat *outU, CGFloat *outV) {
    CGFloat h = 0, s = 0, v = 0;
    UIColor *c = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
    [c getHue:&h saturation:&s brightness:&v alpha:NULL];
    // Inverse of spectrum mapping
    CGFloat u;
    if (v >= 0.999f) {
        u = s * 0.5;
    } else if (s >= 0.999f) {
        u = 0.5 + (1.0 - v) * 0.5;
    } else {
        // Approximate: prefer sat/val blend
        u = (s * 0.5) * v + (0.5 + (1.0 - v) * 0.5) * (1.0 - v);
        if (u < 0) u = 0;
        if (u > 1) u = 1;
    }
    *outU = u;
    *outV = h;
}

static void ESPSpectrumUVtoRGB(CGFloat u, CGFloat v, float *outR, float *outG, float *outB) {
    if (u < 0) u = 0; if (u > 1) u = 1;
    if (v < 0) v = 0; if (v > 1) v = 1;
    CGFloat sat, val;
    if (u <= 0.5) {
        sat = u * 2.0;
        val = 1.0;
    } else {
        sat = 1.0;
        val = 1.0 - (u - 0.5) * 2.0;
    }
    UIColor *c = [UIColor colorWithHue:v saturation:sat brightness:val alpha:1.0];
    CGFloat r, g, b, a;
    [c getRed:&r green:&g blue:&b alpha:&a];
    *outR = (float)r;
    *outG = (float)g;
    *outB = (float)b;
}

typedef NS_ENUM(NSInteger, MenuTab) {
    MenuTabESP = 0,
    MenuTabAimbot = 1,
    MenuTabOther = 2,
    MenuTabSettings = 3
};

@interface HTHMenuSecureWrapper : UITextField
@end

@implementation HTHMenuSecureWrapper
- (BOOL)canBecomeFirstResponder { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
@end
// =======================================================

@interface ModMenuViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) CADisplayLink *displayLink; 
@property (nonatomic, assign) MenuTab currentTab;

@property (nonatomic, strong) HTHMenuSecureWrapper *secureTextField;
@property (nonatomic, strong) UIView *secureContainer;

@property (nonatomic, strong) UIView *floatingPanel;
@property (nonatomic, strong) UIView *containerView; 
@property (nonatomic, strong) UIView *headerBar;
@property (nonatomic, strong) UIScrollView *contentScrollView;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIView *sideNavBar;
@property (nonatomic, strong) UIScrollView *sideNavScrollView;
@property (nonatomic, strong) UIView *sideNavContent;
@property (nonatomic, strong) UIView *footerBar;
@property (nonatomic, strong) UIView *contentClipView;

@property (nonatomic, strong) UILabel *footerLeftLabel;
@property (nonatomic, strong) UILabel *footerRightLabel;

@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;

@property (nonatomic, assign) BOOL isVietnamese;
@property (nonatomic, assign) BOOL isLightMode;

@property (nonatomic, assign) NSInteger trackingPointerId;
@property (nonatomic, assign) BOOL touchOnClose;
@property (nonatomic, assign) BOOL menuDragging;
@property (nonatomic, assign) CGPoint menuDragStartCenter;
@property (nonatomic, assign) CGPoint menuDragStartPoint;

@property (nonatomic, assign) BOOL isContentDragging;
@property (nonatomic, assign) BOOL isSideNavDragging;
@property (nonatomic, assign) CGPoint touchStartPoint;
@property (nonatomic, assign) CGFloat startScrollOffsetY;
@property (nonatomic, assign) CGFloat startSideNavOffsetY;
@property (nonatomic, assign) NSInteger pendingTabIdx;

@property (nonatomic, weak) UISwitch *pendingSwitch;
@property (nonatomic, weak) UISlider *activeSlider;
@property (nonatomic, weak) UIView *pendingSegment;
@property (nonatomic, weak) UIView *pendingColorSwatch;
@property (nonatomic, weak) UIView *activeSpectrumBoard; // spectrum drag target
@end

@implementation ModMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad]; 
    self.view.backgroundColor = [UIColor clearColor];
    self.view.multipleTouchEnabled = YES;
    self.view.exclusiveTouch = YES; 

    self.isVietnamese = ESPPrefsBool(@(oxorany("AppLanguage")), NO);
    MDLoadThemeFromPrefs();
    self.isLightMode = g_mdLight;

    // Restore last tab so closing/reopening menu keeps Aimbot/Other/Settings.
    {
        int savedTab = (int)ESPPrefsFloat(@(oxorany("MenuLastTab")), (float)MenuTabESP);
        if (savedTab < (int)MenuTabESP || savedTab > (int)MenuTabSettings) savedTab = (int)MenuTabESP;
        _currentTab = (MenuTab)savedTab;
    }
    _tabButtons = [NSMutableArray array];

    [self setupFloatingPanel];
    [self setupHeaderBar];
    [self setupSideNavBar];
    [self setupFooterBar];
    [self setupContentArea];

    [self refreshThemeColors];
    [self updateSidebarForTab:_currentTab];
    [self loadTabContent:_currentTab];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleOutsideTap:)];
    tap.cancelsTouchesInView = NO;
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateVisibility)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)dealloc {
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)handleOutsideTap:(UITapGestureRecognizer *)tap { }

- (void)hideExternalAimButton {
    // Intentionally a no-op.
    // Old implementation walked UIApplication.keyWindow and hid ANY button titled
    // AIM/HEAD/NECK/BODY. That also hit MenuView's floating HUD buttons, often
    // AFTER dismiss (0.15s delay) so icons/AIM/HEAD vanished after tapping menu.
    // Lite mode already hides aux buttons via MenuView refreshButtonVisibility.
}

- (void)updateVisibility {
    BOOL isStreamer = ESPPrefsBool(@(oxorany("StreamerMode")), NO);
    BOOL isHiddenByInApp = ESPPrefsBool(@(oxorany("HideMenu1")), NO); 
    
    if (_secureTextField.secureTextEntry != isStreamer) {
        [_floatingPanel removeFromSuperview];
        _secureTextField.secureTextEntry = isStreamer;
        [_secureTextField layoutIfNeeded];
        _secureContainer = _secureTextField.subviews.firstObject ?: _secureTextField;
        [_secureContainer addSubview:_floatingPanel];
    }
    
    if (isHiddenByInApp) {
        if (!self.view.hidden) self.view.hidden = YES; 
    } else {
        if (self.view.hidden) self.view.hidden = NO;
    }
}

- (CGPoint)loadPanelPosition {
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat x = ESPPrefsFloat(@(oxorany("FloatingPanelX")), 0.0f);
    CGFloat y = ESPPrefsFloat(@(oxorany("FloatingPanelY")), 0.0f);
    if (x <= 0 && y <= 0) {
        // Center-ish for the wider horizontal panel
        x = MAX(12.0f, (scr.width - kPanelWidth) * 0.5f);
        y = MAX(40.0f, (scr.height - kPanelHeight) * 0.22f);
    }
    // Clamp so wider panel stays mostly on-screen after layout change
    if (x + kPanelWidth > scr.width - 8.0f) x = scr.width - kPanelWidth - 8.0f;
    if (y + kPanelHeight > scr.height - 8.0f) y = scr.height - kPanelHeight - 8.0f;
    if (x < 8.0f) x = 8.0f;
    if (y < 20.0f) y = 20.0f;
    return CGPointMake(x, y);
}

- (void)setupFloatingPanel {
    CGPoint saved = [self loadPanelPosition];
    
    _secureTextField = [[HTHMenuSecureWrapper alloc] initWithFrame:self.view.bounds];
    _secureTextField.userInteractionEnabled = NO; 
    _secureTextField.backgroundColor = [UIColor clearColor];
    _secureTextField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_secureTextField];
    
    _secureTextField.secureTextEntry = ESPPrefsBool(@(oxorany("StreamerMode")), NO);
    [_secureTextField layoutIfNeeded];
    _secureContainer = _secureTextField.subviews.firstObject ?: _secureTextField;
    
    _floatingPanel = [[UIView alloc] initWithFrame:CGRectMake(saved.x, saved.y, kPanelWidth, kPanelHeight)];
    _floatingPanel.backgroundColor = [UIColor clearColor];
    _floatingPanel.layer.shadowColor = [UIColor blackColor].CGColor;
    _floatingPanel.layer.shadowOpacity = 0.55f;
    _floatingPanel.layer.shadowRadius = 28.0f;
    _floatingPanel.layer.shadowOffset = CGSizeMake(0, 14);

    [_secureContainer addSubview:_floatingPanel];

    _containerView = [[UIView alloc] initWithFrame:_floatingPanel.bounds];
    _containerView.backgroundColor = MDPanel();
    _containerView.layer.cornerRadius = 22.0f;
    _containerView.layer.borderWidth = 1.0f;
    _containerView.layer.borderColor = MDLine().CGColor;
    _containerView.clipsToBounds = YES;
    
    _containerView.layer.shouldRasterize = YES;
    _containerView.layer.rasterizationScale = [UIScreen mainScreen].scale;
    
    [_floatingPanel addSubview:_containerView];
}

- (void)setupHeaderBar {
    _headerBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidth, kHeaderHeight)];
    _headerBar.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.02f];
    [_containerView addSubview:_headerBar];

    UIView *headerSep = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderHeight - 1.0f, kPanelWidth, 1.0f)];
    headerSep.backgroundColor = MDLine();
    headerSep.tag = 7001;
    [_headerBar addSubview:headerSep];

    UIView *brandMark = [[UIView alloc] initWithFrame:CGRectMake(14, (kHeaderHeight - 34) * 0.5f, 34, 34)];
    brandMark.backgroundColor = MDAccent();
    brandMark.layer.cornerRadius = 10.0f;
    brandMark.tag = 7101;
    [_headerBar addSubview:brandMark];
    UILabel *bolt = MDFALabel(@"bolt", 14, [UIColor colorWithRed:0.02f green:0.07f blue:0.05f alpha:1.0f]);
    bolt.frame = CGRectMake(0, 0, 34, 34);
    bolt.tag = 7102;
    [brandMark addSubview:bolt];

    _headerTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(56, 8, kPanelWidth - 150, 22)];
    _headerTitleLabel.text = @(oxorany("MINHDUC-FF V2"));
    _headerTitleLabel.font = MDFont(14, UIFontWeightHeavy);
    _headerTitleLabel.textColor = MDText();
    _headerTitleLabel.textAlignment = NSTextAlignmentLeft;
    [_headerBar addSubview:_headerTitleLabel];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(56, 28, kPanelWidth - 150, 16)];
    sub.text = @(oxorany("External Interface"));
    sub.font = MDFont(10, UIFontWeightMedium);
    sub.textColor = MDMuted();
    sub.tag = 7103;
    [_headerBar addSubview:sub];

    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(kPanelWidth - 132, (kHeaderHeight - 28) * 0.5f, 72, 28)];
    pill.backgroundColor = MDAccentSoft(0.08f);
    pill.layer.cornerRadius = 14.0f;
    pill.layer.borderWidth = 1.0f;
    pill.layer.borderColor = MDAccentSoft(0.25f).CGColor;
    pill.tag = 7104;
    [_headerBar addSubview:pill];
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(10, 11, 6, 6)];
    dot.backgroundColor = MDAccent();
    dot.layer.cornerRadius = 3.0f;
    [pill addSubview:dot];
    UILabel *ready = [[UILabel alloc] initWithFrame:CGRectMake(22, 0, 46, 28)];
    ready.text = @(oxorany("READY"));
    ready.font = MDFont(9, UIFontWeightHeavy);
    ready.textColor = MDAccent();
    [pill addSubview:ready];

    CGFloat btnSize = 30.0f;
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeButton.frame = CGRectMake(kPanelWidth - 42, (kHeaderHeight - btnSize) / 2.0f, btnSize, btnSize);
    _closeButton.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.04f];
    _closeButton.layer.cornerRadius = 9.0f;
    _closeButton.layer.borderWidth = 1.0f;
    _closeButton.layer.borderColor = MDLine().CGColor;
    [_closeButton setTitle:MDFA(@"xmark") forState:UIControlStateNormal];
    _closeButton.titleLabel.font = MDFAFont(14, NO);
    [_closeButton setTitleColor:MDMuted() forState:UIControlStateNormal];
    [_closeButton setImage:nil forState:UIControlStateNormal];
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_headerBar addSubview:_closeButton];
}

- (void)setupSideNavBar {
    _sideNavBar = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderHeight, kSideNavWidth, kContentHeight)];
    _sideNavBar.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.02f];
    _sideNavBar.clipsToBounds = YES;
    [_containerView addSubview:_sideNavBar];

    UIView *sideSep = [[UIView alloc] initWithFrame:CGRectMake(kSideNavWidth - 1.0f, 0, 1.0f, kContentHeight)];
    sideSep.backgroundColor = MDLine();
    sideSep.tag = 7002;
    [_sideNavBar addSubview:sideSep];

    // Profile card pinned at TOP so Settings tab never covers it.
    CGFloat profH = 54.0f;
    CGFloat profTop = 10.0f;
    UIView *prof = [[UIView alloc] initWithFrame:CGRectMake(8, profTop, kSideNavWidth - 16, profH)];
    prof.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.035f];
    prof.layer.cornerRadius = 12.0f;
    prof.layer.borderWidth = 1.0f;
    prof.layer.borderColor = MDLine().CGColor;
    prof.tag = 7201;
    [_sideNavBar addSubview:prof];

    UILabel *av = [[UILabel alloc] initWithFrame:CGRectMake(8, 10, 34, 34)];
    av.text = @(oxorany("MD"));
    av.textAlignment = NSTextAlignmentCenter;
    av.font = MDFont(11, UIFontWeightHeavy);
    av.textColor = MDAccent();
    av.backgroundColor = MDAccentSoft(0.12f);
    av.layer.cornerRadius = 10.0f;
    av.clipsToBounds = YES;
    [prof addSubview:av];

    UILabel *pn = [[UILabel alloc] initWithFrame:CGRectMake(48, 10, kSideNavWidth - 72, 16)];
    pn.text = @(oxorany("MinhDuc-FF"));
    pn.font = MDFont(11, UIFontWeightBold);
    pn.textColor = MDText();
    pn.adjustsFontSizeToFitWidth = YES;
    pn.minimumScaleFactor = 0.75f;
    [prof addSubview:pn];
    UILabel *pd = [[UILabel alloc] initWithFrame:CGRectMake(48, 28, kSideNavWidth - 72, 14)];
    pd.text = @(oxorany("@Bolaminhduc"));
    pd.font = MDFont(9, UIFontWeightMedium);
    pd.textColor = MDMuted();
    pd.adjustsFontSizeToFitWidth = YES;
    pd.minimumScaleFactor = 0.75f;
    [prof addSubview:pd];

    // Scrollable tab list under the profile card.
    CGFloat scrollTop = CGRectGetMaxY(prof.frame) + 8.0f;
    CGFloat scrollH = MAX(0.0f, kContentHeight - scrollTop);
    _sideNavScrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, scrollTop, kSideNavWidth - 1.0f, scrollH)];
    _sideNavScrollView.backgroundColor = [UIColor clearColor];
    _sideNavScrollView.showsVerticalScrollIndicator = YES;
    _sideNavScrollView.showsHorizontalScrollIndicator = NO;
    _sideNavScrollView.bounces = YES;
    _sideNavScrollView.alwaysBounceVertical = YES;
    _sideNavScrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _sideNavScrollView.scrollEnabled = NO; // custom HUD touch path drives offset
    _sideNavScrollView.delaysContentTouches = NO;
    _sideNavScrollView.canCancelContentTouches = NO;
    [_sideNavBar addSubview:_sideNavScrollView];

    _sideNavContent = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kSideNavWidth - 1.0f, scrollH)];
    _sideNavContent.backgroundColor = [UIColor clearColor];
    [_sideNavScrollView addSubview:_sideNavContent];

    NSArray *tabTitles = @[
        @(oxorany("ESP")),
        @(oxorany("Aimbot")),
        @(oxorany("Other")),
        @(oxorany("Settings"))
    ];
    // Match HTML demo: eye / crosshairs / wand-magic-sparkles / sliders
    NSArray *tabFA = @[ @"eye", @"crosshairs", @"wand", @"sliders" ];
    CGFloat tabH = 48.0f;
    CGFloat tabGap = 6.0f;
    CGFloat topPad = 4.0f;
    CGFloat bottomPad = 12.0f;

    for (NSInteger i = 0; i < kTabCount; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(8.0f, topPad + i * (tabH + tabGap), kSideNavWidth - 16.0f, tabH);
        btn.tag = i;
        btn.layer.cornerRadius = 12.0f;
        btn.clipsToBounds = YES;
        btn.userInteractionEnabled = NO; // handled by custom touch path

        // Icon
        UILabel *ico = MDFALabel(tabFA[i], 14, MDMuted());
        ico.frame = CGRectMake(10, 0, 20, tabH);
        ico.tag = 7401;
        [btn addSubview:ico];

        // Title
        UILabel *ttl = [[UILabel alloc] initWithFrame:CGRectMake(34, 0, kSideNavWidth - 58, tabH)];
        ttl.text = tabTitles[i];
        ttl.font = MDFont(12, UIFontWeightSemibold);
        ttl.textColor = MDMuted();
        ttl.tag = 7402;
        [btn addSubview:ttl];

        [btn setTitle:@"" forState:UIControlStateNormal];
        [btn setImage:nil forState:UIControlStateNormal];
        [_sideNavContent addSubview:btn];
        [_tabButtons addObject:btn];
    }

    CGFloat contentH = topPad + kTabCount * tabH + MAX(0, kTabCount - 1) * tabGap + bottomPad;
    if (contentH < scrollH) contentH = scrollH;
    _sideNavContent.frame = CGRectMake(0, 0, kSideNavWidth - 1.0f, contentH);
    _sideNavScrollView.contentSize = CGSizeMake(kSideNavWidth - 1.0f, contentH);
}

- (void)setupFooterBar {
    _footerBar = [[UIView alloc] initWithFrame:CGRectMake(0, kPanelHeight - kFooterHeight, kPanelWidth, kFooterHeight)];
    _footerBar.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.015f];
    [_containerView addSubview:_footerBar];

    UIView *footerSep = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidth, 1.0f)];
    footerSep.backgroundColor = MDLine();
    footerSep.tag = 7003;
    [_footerBar addSubview:footerSep];

    _footerLeftLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, 220, kFooterHeight)];
    _footerLeftLabel.text = @(oxorany("BoLaMinhDuc • External"));
    _footerLeftLabel.font = MDFont(10, UIFontWeightMedium);
    _footerLeftLabel.textColor = MDMuted();
    [_footerBar addSubview:_footerLeftLabel];

    _footerRightLabel = [[UILabel alloc] initWithFrame:CGRectMake(kPanelWidth - 220, 0, 204, kFooterHeight)];
    _footerRightLabel.text = @(oxorany("dev: @Bolaminhduc"));
    _footerRightLabel.font = MDFont(10, UIFontWeightMedium);
    _footerRightLabel.textColor = MDMuted();
    _footerRightLabel.textAlignment = NSTextAlignmentRight;
    [_footerBar addSubview:_footerRightLabel];
}

- (void)setupContentArea {
    // Content sits to the right of side nav
    _contentClipView = [[UIView alloc] initWithFrame:CGRectMake(kSideNavWidth, kHeaderHeight, kContentWidth, kContentHeight)];
    _contentClipView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12f];
    _contentClipView.clipsToBounds = YES;
    [_containerView addSubview:_contentClipView];

    _contentScrollView = [[UIScrollView alloc] initWithFrame:_contentClipView.bounds];
    _contentScrollView.backgroundColor = [UIColor clearColor];
    _contentScrollView.showsVerticalScrollIndicator = YES;
    _contentScrollView.showsHorizontalScrollIndicator = NO;
    _contentScrollView.bounces = YES;
    [_contentClipView addSubview:_contentScrollView];

    _contentContainer = [[UIView alloc] initWithFrame:_contentClipView.bounds];
    _contentContainer.backgroundColor = [UIColor clearColor];
    [_contentScrollView addSubview:_contentContainer];
}

- (NSString *)localized:(NSString *)enText viText:(NSString *)viText {
    return self.isVietnamese ? viText : enText;
}

- (void)refreshThemeColors {
    MDLoadThemeFromPrefs();
    self.isLightMode = g_mdLight;

    _containerView.backgroundColor = MDPanel();
    if (g_mdLight) {
        _headerBar.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.03f];
        _sideNavBar.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.025f];
        _footerBar.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.02f];
        _contentClipView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04f];
        _containerView.layer.borderColor = MDLine().CGColor;
        _containerView.layer.borderWidth = 1.0f;
    } else {
        _headerBar.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.02f];
        _sideNavBar.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.02f];
        _footerBar.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.015f];
        _contentClipView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12f];
        _containerView.layer.borderColor = MDLine().CGColor;
        _containerView.layer.borderWidth = 1.0f;
    }
    _contentScrollView.backgroundColor = [UIColor clearColor];
    _contentContainer.backgroundColor = [UIColor clearColor];

    _headerTitleLabel.textColor = MDText();
    _closeButton.tintColor = MDMuted();
    [_closeButton setTitleColor:MDMuted() forState:UIControlStateNormal];
    _footerLeftLabel.textColor = MDMuted();
    _footerRightLabel.textColor = MDMuted();

    // Header accent bits (brand mark / READY pill)
    for (UIView *v in _headerBar.subviews) {
        if (v.tag == 7101) {
            v.backgroundColor = MDAccent(); // brand mark square
            for (UIView *c in v.subviews) {
                if ([c isKindOfClass:[UILabel class]]) {
                    // bolt glyph on brand — keep dark ink for contrast on bright accents
                    ((UILabel *)c).textColor = g_mdLight
                        ? [UIColor colorWithWhite:1.0f alpha:0.95f]
                        : [UIColor colorWithRed:0.02f green:0.07f blue:0.05f alpha:1.0f];
                }
            }
        }
        if (v.tag == 7103) ((UILabel *)v).textColor = MDMuted(); // subtitle
        if (v.tag == 7104) { // READY pill
            v.backgroundColor = MDAccentSoft(0.12f);
            v.layer.borderColor = MDAccentSoft(0.30f).CGColor;
            for (UIView *c in v.subviews) {
                if (c.tag == 0 && c.bounds.size.width <= 8) c.backgroundColor = MDAccent();
                if ([c isKindOfClass:[UILabel class]]) ((UILabel *)c).textColor = MDAccent();
            }
        }
        if (v.tag == 7001) v.backgroundColor = MDLine(); // header separator
    }
    _closeButton.backgroundColor = g_mdLight
        ? [UIColor colorWithWhite:0.0f alpha:0.04f]
        : [UIColor colorWithWhite:1.0f alpha:0.04f];
    _closeButton.layer.borderColor = MDLine().CGColor;

    [self updateSidebarForTab:self.currentTab];
}

- (void)styleCustomSwitch:(UISwitch *)sw {
    sw.onTintColor = MDAccent();
    sw.transform = CGAffineTransformMakeScale(0.8, 0.8); 
}

- (void)loadTabContent:(MenuTab)tab {
    for (UIView *v in _contentContainer.subviews) { [v removeFromSuperview]; }
    CGFloat contentWidth = _contentContainer.bounds.size.width;
    __block CGFloat y = 0.0f;
    
    UIColor *textColor = MDText();
    int menuStyle = (int)ESPPrefsFloat(@(oxorany("MenuLayoutStyle")), 0); 
    
    if (menuStyle == 1) {
        [self hideExternalAimButton];
    }
    
    void (^addSectionHeader)(NSString*) = ^(NSString *title) {
        UIView *headerBg = [[UIView alloc] initWithFrame:CGRectMake(10, y + 4, contentWidth - 20, 30)];
        headerBg.backgroundColor = [UIColor clearColor];
        [self->_contentContainer addSubview:headerBg];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(6, 0, contentWidth - 32, 30)];
        lbl.text = [title uppercaseString];
        lbl.font = MDFont(10, UIFontWeightHeavy);
        lbl.textColor = MDAccent();
        [headerBg addSubview:lbl];
        y += 38.0f;
    };

    void (^addSwitchRow)(NSString*, NSString*, BOOL) = ^(NSString *title, NSString *key, BOOL defVal) {
        UIView *rowView = [[UIView alloc] initWithFrame:CGRectMake(10, y, contentWidth - 20, kRowHeight)];
        rowView.backgroundColor = MDPanel2();
        rowView.layer.cornerRadius = 12.0f;
        rowView.layer.borderWidth = 1.0f;
        rowView.layer.borderColor = MDLine().CGColor;
        rowView.clipsToBounds = YES;

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, contentWidth - 100, kRowHeight)];
        lbl.text = title;
        lbl.font = MDFont(13, UIFontWeightMedium);
        lbl.textColor = MDText();
        [rowView addSubview:lbl];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(contentWidth - 86, (kRowHeight - 31) / 2, 51, 31)];
        [self styleCustomSwitch:sw];
        sw.on = ESPPrefsBool(key, defVal);
        objc_setAssociatedObject(sw, kKeyKey, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sw.userInteractionEnabled = NO;
        [rowView addSubview:sw];

        [self->_contentContainer addSubview:rowView];
        y += kRowHeight + 8.0f;
    };

    if (tab == MenuTabESP) {
        addSectionHeader(@(oxorany("Switch")));
        if (menuStyle == 0) {
            addSwitchRow([self localized:@(oxorany("Enable Esp")) viText:@(oxorany("Bật ESP"))], @(oxorany("EnableESP")), NO);
            addSwitchRow([self localized:@(oxorany("Line Esp")) viText:@(oxorany("Đường kẻ"))], @(oxorany("Line")), NO);
            addSwitchRow([self localized:@(oxorany("Box Esp")) viText:@(oxorany("Khung ESP"))], @(oxorany("Box")), YES);
            addSwitchRow([self localized:@(oxorany("Info Esp")) viText:@(oxorany("Thông tin"))], @(oxorany("Name")), YES);
            addSwitchRow([self localized:@(oxorany("Bone Esp")) viText:@(oxorany("Xương ESP"))], @(oxorany("Bone")), NO);
            addSwitchRow([self localized:@(oxorany("Health Esp")) viText:@(oxorany("Thanh Máu"))], @(oxorany("Health")), NO);
            addSwitchRow([self localized:@(oxorany("Distance Esp")) viText:@(oxorany("Cự ly"))], @(oxorany("Distance")), YES);
            addSwitchRow([self localized:@(oxorany("Weapon Esp")) viText:@(oxorany("Vũ khí"))], @(oxorany("Weapon")), NO);
            addSwitchRow([self localized:@(oxorany("ESP Bot")) viText:@(oxorany("Bật vẽ BOT"))], @(oxorany("EspBot")), NO);
            addSwitchRow([self localized:@(oxorany("Check Visible")) viText:@(oxorany("Kiểm tra tầm nhìn"))], @(oxorany("EspCheckVisible")), NO);
            addSwitchRow([self localized:@(oxorany("Show Count")) viText:@(oxorany("Đếm Người"))], @(oxorany("Count")), YES);
            addSwitchRow([self localized:@(oxorany("Alert 360°")) viText:@(oxorany("Cảnh báo 360°"))], @(oxorany("Alert360")), NO);
            addSwitchRow([self localized:@(oxorany("Alert Num")) viText:@(oxorany("Số hiệu cảnh báo"))], @(oxorany("AlertNum")), NO);

            addSectionHeader(@(oxorany("Modes & Setting")));

            CGFloat espDist = ESPPrefsFloat(@(oxorany("EspDistanceLimit")), 150.0f);
            UILabel *espDistLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y+5, contentWidth - 32, 20)];
            espDistLbl.text = [NSString stringWithFormat:[self localized:@(oxorany("ESP Distance: %.0fm")) viText:@(oxorany("Tầm xa ESP: %.0fm"))], espDist];
            espDistLbl.font = MDFont(14, UIFontWeightMedium);
            espDistLbl.textColor = textColor;
            [_contentContainer addSubview:espDistLbl];
            y += 25;
            UISlider *espDistSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, contentWidth - 32, 30)];
            espDistSlider.minimumValue = 10.0f; espDistSlider.maximumValue = 500.0f; espDistSlider.value = espDist;
            espDistSlider.minimumTrackTintColor = MDAccent();
            objc_setAssociatedObject(espDistSlider, kKeyKey, @(oxorany("EspDistanceLimit")), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(espDistSlider, kLabelKey, espDistLbl, OBJC_ASSOCIATION_ASSIGN);
            [espDistSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [_contentContainer addSubview:espDistSlider];
            y += 40;

            NSArray *boxOpts = @[@(oxorany("2D Box")), @(oxorany("Corner")), @(oxorany("3D Box"))];
            UIView *boxRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Box Style")) viText:@(oxorany("Kiểu Box"))]
                                                     options:boxOpts
                                               selectedIndex:(int)ESPPrefsFloat(@(oxorany("BoxMode")), 0.0f)
                                                           y:y width:contentWidth key:@(oxorany("BoxMode"))];
            [_contentContainer addSubview:boxRow];
            y += boxRow.frame.size.height;
        }
        else {
            addSwitchRow([self localized:@(oxorany("Enable Esp")) viText:@(oxorany("Bật ESP 2 (Lite)"))], @(oxorany("EnableESP2")), NO);
            addSwitchRow([self localized:@(oxorany("Line Esp")) viText:@(oxorany("Đường kẻ"))], @(oxorany("Line")), NO);
            addSwitchRow([self localized:@(oxorany("Box Esp")) viText:@(oxorany("Khung ESP"))], @(oxorany("Box")), YES);
            addSwitchRow([self localized:@(oxorany("Health Esp")) viText:@(oxorany("Thanh Máu"))], @(oxorany("Health")), NO);
            addSwitchRow([self localized:@(oxorany("Show Count")) viText:@(oxorany("Đếm Người"))], @(oxorany("Count")), YES);
        }

        // ESP Preview card (HTML demo layout: checklist + dashed preview stage)
        if (menuStyle == 0) {
            addSectionHeader([self localized:@(oxorany("ESP Preview")) viText:@(oxorany("ESP Preview"))]);

            BOOL showBox = ESPPrefsBool(@(oxorany("Box")), YES);
            BOOL showName = ESPPrefsBool(@(oxorany("Name")), YES);
            BOOL showDist = ESPPrefsBool(@(oxorany("Distance")), YES);
            BOOL showHealth = ESPPrefsBool(@(oxorany("Health")), YES);
            BOOL showBone = ESPPrefsBool(@(oxorany("Bone")), NO);
            BOOL showLine = ESPPrefsBool(@(oxorany("Line")), NO);

            CGFloat cardH = 230.0f;
            UIView *previewCard = [[UIView alloc] initWithFrame:CGRectMake(10, y, contentWidth - 20, cardH)];
            previewCard.backgroundColor = MDPanel2();
            previewCard.layer.cornerRadius = 15.0f;
            previewCard.layer.borderWidth = 1.0f;
            previewCard.layer.borderColor = MDLine().CGColor;
            previewCard.clipsToBounds = YES;
            [_contentContainer addSubview:previewCard];

            // Title row
            UILabel *eye = MDFALabel(@"eye", 13, MDBlue());
            eye.frame = CGRectMake(14, 12, 28, 28);
            eye.backgroundColor = [UIColor colorWithRed:0.22f green:0.74f blue:0.97f alpha:0.12f];
            eye.layer.cornerRadius = 8.0f;
            eye.clipsToBounds = YES;
            [previewCard addSubview:eye];
            UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(50, 10, contentWidth - 90, 16)];
            pt.text = [self localized:@(oxorany("ESP Preview")) viText:@(oxorany("ESP Preview"))];
            pt.font = MDFont(13, UIFontWeightBold);
            pt.textColor = MDText();
            [previewCard addSubview:pt];
            UILabel *ps = [[UILabel alloc] initWithFrame:CGRectMake(50, 28, contentWidth - 90, 14)];
            ps.text = [self localized:@(oxorany("Reflects current ESP toggles")) viText:@(oxorany("Theo toggle ESP hiện tại"))];
            ps.font = MDFont(10, UIFontWeightMedium);
            ps.textColor = MDMuted();
            [previewCard addSubview:ps];

            // Left checklist
            CGFloat leftW = (contentWidth - 48) * 0.48f;
            CGFloat rightW = (contentWidth - 48) - leftW - 12;
            CGFloat listY = 50;
            NSArray *rows = @[
                @[ @"Box", @(showBox) ],
                @[ @"Name", @(showName) ],
                @[ @"Distance", @(showDist) ],
                @[ @"Health", @(showHealth) ],
                @[ @"Bone", @(showBone) ],
                @[ @"Line", @(showLine) ],
            ];
            for (NSArray *row in rows) {
                BOOL on = [row[1] boolValue];
                UIView *r = [[UIView alloc] initWithFrame:CGRectMake(14, listY, leftW, 24)];
                r.backgroundColor = [UIColor colorWithWhite:1 alpha:0.025f];
                r.layer.cornerRadius = 8.0f;
                [previewCard addSubview:r];
                UILabel *ck = MDFALabel(@"check", 9, on ? [UIColor colorWithRed:0.02f green:0.07f blue:0.05f alpha:1] : [UIColor clearColor]);
                ck.frame = CGRectMake(6, 3, 18, 18);
                ck.backgroundColor = on ? MDAccent() : [UIColor colorWithRed:0.09f green:0.14f blue:0.22f alpha:1];
                ck.layer.cornerRadius = 6.0f;
                ck.layer.borderWidth = 1.0f;
                ck.layer.borderColor = on ? MDAccentSoft(0.35f).CGColor : MDLine().CGColor;
                ck.clipsToBounds = YES;
                [r addSubview:ck];
                UILabel *tx = [[UILabel alloc] initWithFrame:CGRectMake(30, 0, leftW - 36, 24)];
                tx.text = row[0];
                tx.font = MDFont(10, UIFontWeightBold);
                tx.textColor = MDText();
                [r addSubview:tx];
                listY += 28;
            }

            // Right dashed preview stage (HTML .preview-box)
            UIView *stage = [[UIView alloc] initWithFrame:CGRectMake(14 + leftW + 12, 50, rightW, 164)];
            stage.backgroundColor = [UIColor colorWithWhite:0 alpha:0.13f];
            stage.layer.cornerRadius = 14.0f;
            stage.layer.borderWidth = 1.0f;
            stage.layer.borderColor = MDAccentSoft(0.38f).CGColor;
            // dashed border approximation
            stage.layer.borderColor = [UIColor colorWithRed:0.208f green:0.827f blue:0.604f alpha:0.38f].CGColor;
            stage.clipsToBounds = YES;
            [previewCard addSubview:stage];

            CGFloat scx = stage.bounds.size.width * 0.5f;
            // player shape
            UIView *head = [[UIView alloc] initWithFrame:CGRectMake(scx - 11, 42, 22, 22)];
            head.backgroundColor = [UIColor colorWithRed:0.376f green:0.439f blue:0.525f alpha:1];
            head.layer.cornerRadius = 11;
            [stage addSubview:head];
            UIView *body = [[UIView alloc] initWithFrame:CGRectMake(scx - 17, 68, 34, 72)];
            body.backgroundColor = [UIColor colorWithRed:0.325f green:0.388f blue:0.475f alpha:1];
            body.layer.cornerRadius = 12;
            [stage addSubview:body];

            if (showBox) {
                UIView *box = [[UIView alloc] initWithFrame:CGRectMake(scx - 28, 34, 56, 112)];
                box.backgroundColor = [UIColor clearColor];
                box.layer.borderWidth = 1.2f;
                box.layer.borderColor = MDAccent().CGColor;
                box.layer.shadowColor = MDAccent().CGColor;
                box.layer.shadowOpacity = 0.25f;
                box.layer.shadowRadius = 8;
                [stage addSubview:box];
            }
            if (showName) {
                UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake((stage.bounds.size.width - 78) * 0.5f, 10, 78, 16)];
                name.text = @(oxorany("PLAYER_DEMO"));
                name.font = MDFont(8, UIFontWeightHeavy);
                name.textColor = [UIColor colorWithRed:0.02f green:0.07f blue:0.05f alpha:1];
                name.backgroundColor = MDAccent();
                name.textAlignment = NSTextAlignmentCenter;
                name.layer.cornerRadius = 5;
                name.clipsToBounds = YES;
                [stage addSubview:name];
            }
            if (showHealth) {
                UIView *hpBg = [[UIView alloc] initWithFrame:CGRectMake(18, 24, 5, 120)];
                hpBg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13f];
                hpBg.layer.cornerRadius = 3;
                [stage addSubview:hpBg];
                UIView *hp = [[UIView alloc] initWithFrame:CGRectMake(0, 32, 5, 88)];
                hp.backgroundColor = MDAccent();
                hp.layer.cornerRadius = 3;
                [hpBg addSubview:hp];
            }
            if (showDist) {
                UILabel *dist = [[UILabel alloc] initWithFrame:CGRectMake(stage.bounds.size.width - 40, stage.bounds.size.height - 18, 32, 12)];
                dist.text = @(oxorany("12 m"));
                dist.font = MDFont(8, UIFontWeightMedium);
                dist.textColor = MDMuted();
                dist.textAlignment = NSTextAlignmentRight;
                [stage addSubview:dist];
            }
            if (showLine) {
                UIView *line = [[UIView alloc] initWithFrame:CGRectMake(scx - 0.75f, 0, 1.5f, 34)];
                line.backgroundColor = MDAccentSoft(0.8f);
                [stage addSubview:line];
            }
            if (showBone) {
                UIView *bone = [[UIView alloc] initWithFrame:CGRectMake(scx - 1, 64, 2, 70)];
                bone.backgroundColor = [UIColor colorWithWhite:0.9 alpha:0.7];
                [stage addSubview:bone];
            }

            y += cardH + 12.0f;
        }

        // Colors: Pro menu only (Lite keeps UI light — no spectrum boards).
        if (menuStyle == 0) {
            addSectionHeader([self localized:@(oxorany("ESP Colors")) viText:@(oxorany("Màu ESP"))]);
            y = [self appendColorControlSectionWithTitle:[self localized:@(oxorany("Box Color")) viText:@(oxorany("Màu Box"))]
                                                  prefix:@(oxorany("Box"))
                                              defaultRGB:0.0f :1.0f :1.0f
                                                       y:y width:contentWidth textColor:textColor];
            y = [self appendColorControlSectionWithTitle:[self localized:@(oxorany("Line Color")) viText:@(oxorany("Màu Line"))]
                                                  prefix:@(oxorany("Line"))
                                              defaultRGB:0.0f :1.0f :1.0f
                                                       y:y width:contentWidth textColor:textColor];
            y = [self appendColorControlSectionWithTitle:[self localized:@(oxorany("Bone Color")) viText:@(oxorany("Màu Bone"))]
                                                  prefix:@(oxorany("Bone"))
                                              defaultRGB:0.0f :1.0f :1.0f
                                                       y:y width:contentWidth textColor:textColor];
            y = [self appendColorControlSectionWithTitle:[self localized:@(oxorany("FOV Color")) viText:@(oxorany("Màu FOV"))]
                                                  prefix:@(oxorany("Fov"))
                                              defaultRGB:1.0f :1.0f :0.0f
                                                       y:y width:contentWidth textColor:textColor];
        }

    } else if (tab == MenuTabAimbot) {
        addSectionHeader(@(oxorany("Switch")));

        // Master aim enable + exclusive mode dropdown (Aimbot / Assist / Legit).
        BOOL aimbotOn = ESPPrefsBool(@(oxorany("Aimbot")), NO);
        BOOL aimAssistOn = ESPPrefsBool(@(oxorany("AimAssist")), NO);
        BOOL aimLegitOn = ESPPrefsBool(@(oxorany("AimLegit")), NO);
        // Prefer one active hard mode; Legit wins if somehow multi-on from old prefs.
        int aimTypeSel = 0; // 0 Aimbot, 1 Assist, 2 Legit
        if (aimLegitOn && !aimbotOn && !aimAssistOn) aimTypeSel = 2;
        else if (aimAssistOn && !aimbotOn) aimTypeSel = 1;
        else aimTypeSel = 0;
        BOOL aimMasterOn = aimbotOn || aimAssistOn || aimLegitOn;
        // Keep prefs exclusive when opening tab (old builds could stack).
        if (aimMasterOn) {
            if (aimTypeSel == 0) {
                if (!aimbotOn) ESPPrefsSetBool(@(oxorany("Aimbot")), YES);
                if (aimAssistOn) ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
                if (aimLegitOn) ESPPrefsSetBool(@(oxorany("AimLegit")), NO);
                aimbotOn = YES; aimAssistOn = NO; aimLegitOn = NO;
            } else if (aimTypeSel == 1) {
                if (aimbotOn) ESPPrefsSetBool(@(oxorany("Aimbot")), NO);
                if (!aimAssistOn) ESPPrefsSetBool(@(oxorany("AimAssist")), YES);
                if (aimLegitOn) ESPPrefsSetBool(@(oxorany("AimLegit")), NO);
                aimbotOn = NO; aimAssistOn = YES; aimLegitOn = NO;
            } else {
                if (aimbotOn) ESPPrefsSetBool(@(oxorany("Aimbot")), NO);
                if (aimAssistOn) ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
                if (!aimLegitOn) ESPPrefsSetBool(@(oxorany("AimLegit")), YES);
                aimbotOn = NO; aimAssistOn = NO; aimLegitOn = YES;
            }
        }

        // AimSphereMode: 0=FOV, 1=180, 2=360. Migrate legacy Aim360 bool.
        int sphereMode = (int)ESPPrefsFloat(@(oxorany("AimSphereMode")), -1.0f);
        if (sphereMode < 0) {
            sphereMode = ESPPrefsBool(@(oxorany("Aim360")), NO) ? 2 : 0;
            ESPPrefsSetFloat(@(oxorany("AimSphereMode")), (float)sphereMode);
        }
        if (sphereMode < 0) sphereMode = 0;
        if (sphereMode > 2) sphereMode = 2;
        if (!aimbotOn) sphereMode = 0; // sphere modes require Aimbot
        BOOL hideFovSlider = aimbotOn && sphereMode != 0;

        addSwitchRow([self localized:@(oxorany("Enable Aim")) viText:@(oxorany("Bật Aim"))], @(oxorany("AimMaster")), aimMasterOn);
        if (aimMasterOn) {
            NSArray *typeOpts = self.isVietnamese
                ? @[@(oxorany("Aimbot")), @(oxorany("Assist")), @(oxorany("Legit"))]
                : @[@(oxorany("Aimbot")), @(oxorany("Assist")), @(oxorany("Legit"))];
            UIView *typeRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Aim Type")) viText:@(oxorany("Chế độ Aim"))]
                                                      options:typeOpts
                                                selectedIndex:aimTypeSel
                                                            y:y width:contentWidth key:@(oxorany("AimTypeMode"))];
            [_contentContainer addSubview:typeRow];
            y += typeRow.frame.size.height + 8.0f;
        }

        if (menuStyle == 0) {
            // Floating on-screen AIM quick toggle (MenuView AIM button)
            addSwitchRow([self localized:@(oxorany("Show AIM Quick Button")) viText:@(oxorany("Hiện nút tắt/bật Aim nhanh"))], @(oxorany("FloatAimBtn")), YES);
        }

        // Always show bot toggle so training vs real players is one switch away.
        addSwitchRow([self localized:@(oxorany("Aim Bot")) viText:@(oxorany("Aim vào Bot"))], @(oxorany("AimOnBot")), YES);
        if (menuStyle == 0) {
            addSwitchRow([self localized:@(oxorany("Ignore Knock")) viText:@(oxorany("Bỏ qua Knock"))], @(oxorany("AimIgnoreKnock")), NO);
        }

        // Silent / magic bullet — independent of camera aim type.
        addSwitchRow([self localized:@(oxorany("Aim Silent (Magic)")) viText:@(oxorany("Aim Silent (Đạn ma)"))], @(oxorany("AimSilent")), NO);

        if (menuStyle == 0) {
            // Single wall-through toggle (bom keo / ice wall removed).
            addSwitchRow([self localized:@(oxorany("Aim Behind Wall")) viText:@(oxorany("Aim sau tường"))],
                         @(oxorany("AimBehindWall")), NO);
        }

        addSectionHeader(@(oxorany("Config")));

        // Aim range mode (requires Aimbot): FOV circle / 180 front / 360 full.
        if (aimbotOn) {
            NSArray *sphereOpts = self.isVietnamese
                ? @[@(oxorany("FOV")), @(oxorany("180°")), @(oxorany("360°"))]
                : @[@(oxorany("FOV")), @(oxorany("180°")), @(oxorany("360°"))];
            UIView *sphereRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Aim Range")) viText:@(oxorany("Phạm vi Aim"))]
                                                        options:sphereOpts
                                                  selectedIndex:sphereMode
                                                              y:y width:contentWidth key:@(oxorany("AimSphereMode"))];
            [_contentContainer addSubview:sphereRow];
            y += sphereRow.frame.size.height;
        }

        // Trigger always shown (Lite + Pro). Lite previously hid it → TriggerMode stayed 0 (Auto) → cam locked.
        {
            NSArray *triggerOpts = self.isVietnamese
                ? @[@(oxorany("Tự động")), @(oxorany("Bắn")), @(oxorany("Ngắm")), @(oxorany("Bắn&Ngắm"))]
                : @[@(oxorany("Auto")), @(oxorany("Fire")), @(oxorany("Scope")), @(oxorany("Both"))];
            int trigSel = (int)ESPPrefsFloat(@(oxorany("TriggerMode")), (menuStyle == 1) ? 3.0f : 0.0f);
            if (trigSel < 0) trigSel = 0;
            if (trigSel > 3) trigSel = 3;
            UIView *triggerRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Trigger Mode")) viText:@(oxorany("Kích hoạt"))]
                                                     options:triggerOpts
                                               selectedIndex:trigSel
                                                           y:y width:contentWidth key:@(oxorany("TriggerMode"))];
            [_contentContainer addSubview:triggerRow];
            y += triggerRow.frame.size.height;
        }

        if (menuStyle == 0) {
            NSArray *aimModeOpts = @[@(oxorany("Safe (PC)")), @(oxorany("Normal")), @(oxorany("Rage"))];
            UIView *aimModeRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Aim Mode")) viText:@(oxorany("Chế độ ngắm"))]
                                                     options:aimModeOpts
                                               selectedIndex:(int)ESPPrefsFloat(@(oxorany("AimMode")), 1.0f)
                                                           y:y width:contentWidth key:@(oxorany("AimMode"))];
            [_contentContainer addSubview:aimModeRow];
            y += aimModeRow.frame.size.height;

            NSArray *targetOpts = self.isVietnamese ? @[@(oxorany("Gần tâm")), @(oxorany("Thấp HP")), @(oxorany("Gần nhất"))] : @[@(oxorany("Crosshair")), @(oxorany("Low HP")), @(oxorany("Closest"))];
            UIView *targetRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Target")) viText:@(oxorany("Ưu tiên Mục tiêu"))]
                                                     options:targetOpts
                                               selectedIndex:(int)ESPPrefsFloat(@(oxorany("AimTargetMode")), 0.0f)
                                                           y:y width:contentWidth key:@(oxorany("AimTargetMode"))];
            [_contentContainer addSubview:targetRow];
            y += targetRow.frame.size.height;
        }

        NSArray *posOpts = (menuStyle == 0) ? @[@(oxorany("Head")), @(oxorany("Neck")), @(oxorany("Chest"))] : @[@(oxorany("Head")), @(oxorany("Neck"))];
        int currentPos = (int)ESPPrefsFloat(@(oxorany("AimPos")), 0.0f);
        if (menuStyle == 1 && currentPos > 1) { 
            currentPos = 1; 
            ESPPrefsSetFloat(@(oxorany("AimPos")), 1.0f); 
        }
        
        UIView *posRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Position")) viText:@(oxorany("Vị trí"))]
                                                 options:posOpts
                                           selectedIndex:currentPos
                                                       y:y width:contentWidth key:@(oxorany("AimPos"))];
        [_contentContainer addSubview:posRow];
        y += posRow.frame.size.height;
        if (menuStyle == 0) {
            addSwitchRow([self localized:@(oxorany("Show Aim Mode Quick Button")) viText:@(oxorany("Hiện nút chế độ Aim nhanh"))], @(oxorany("FloatAimPosBtn")), YES);
        }


        // FOV slider only in FOV mode. 180/360 hide FOV (sphere modes).
        if (!hideFovSlider) {
            // Show/hide the on-screen FOV ring (Lite + Pro) when Aim range = FOV.
            addSwitchRow([self localized:@(oxorany("Show FOV Circle")) viText:@(oxorany("Hiện vòng FOV"))],
                         @(oxorany("ShowFovCircle")), YES);
            CGFloat fov = ESPPrefsFloat(@(oxorany("Fov")), 150.0f);
            UILabel *fovLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y+5, contentWidth - 32, 20)];
            fovLbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Aim FOV: %.0f")) viText:@(oxorany("Vòng FOV: %.0f"))], fov];
            fovLbl.font = MDFont(14, UIFontWeightMedium);
            fovLbl.textColor = textColor;
            [_contentContainer addSubview:fovLbl];
            y += 25;
            UISlider *fovSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, contentWidth - 32, 30)];
            fovSlider.minimumValue = 10.0f; fovSlider.maximumValue = 500.0f; fovSlider.value = fov;
            fovSlider.minimumTrackTintColor = MDAccent();
            objc_setAssociatedObject(fovSlider, kKeyKey, @(oxorany("Fov")), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(fovSlider, kLabelKey, fovLbl, OBJC_ASSOCIATION_ASSIGN);
            [fovSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [_contentContainer addSubview:fovSlider];
            y += 40;
        } else {
            UILabel *fovOffLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y+5, contentWidth - 32, 20)];
            NSString *modeName = (sphereMode == 1)
                ? [self localized:@(oxorany("180° front")) viText:@(oxorany("180° phía trước"))]
                : [self localized:@(oxorany("360° full")) viText:@(oxorany("360° toàn hướng"))];
            fovOffLbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Aim FOV: OFF (%@)")) viText:@(oxorany("Vòng FOV: TẮT (%@)"))], modeName];
            fovOffLbl.font = MDFont(13, UIFontWeightMedium);
            fovOffLbl.textColor = MDMuted();
            [_contentContainer addSubview:fovOffLbl];
            y += 30;
        }

        if (menuStyle == 0) {
            CGFloat aimDist = ESPPrefsFloat(@(oxorany("AimDistance")), -1.0f);
            if (aimDist < 0.0f) {
                // Migrate legacy float accidentally stored under bool key "Distance"
                id legacy = AppSettingsObjectForKey(@(oxorany("Distance")));
                if ([legacy isKindOfClass:[NSNumber class]] && [(NSNumber *)legacy floatValue] > 1.5f) {
                    aimDist = [(NSNumber *)legacy floatValue];
                } else {
                    aimDist = 200.0f;
                }
            }
            UILabel *distLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y+5, contentWidth - 32, 20)];
            distLbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Distance: %.0fm")) viText:@(oxorany("Cự ly Aim: %.0fm"))], aimDist];
            distLbl.font = MDFont(14, UIFontWeightMedium);
            distLbl.textColor = textColor;
            [_contentContainer addSubview:distLbl];
            y += 25;
            UISlider *distSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, contentWidth - 32, 30)];
            distSlider.minimumValue = 1.0f; distSlider.maximumValue = 400.0f; distSlider.value = aimDist;
            distSlider.minimumTrackTintColor = MDAccent();
            objc_setAssociatedObject(distSlider, kKeyKey, @(oxorany("AimDistance")), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(distSlider, kLabelKey, distLbl, OBJC_ASSOCIATION_ASSIGN);
            [distSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [_contentContainer addSubview:distSlider];
            y += 40;

            CGFloat speedPct = ESPPrefsFloat(@(oxorany("AimSpeed")), 100.0f);
            UILabel *spdLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y+5, contentWidth - 32, 20)];
            spdLbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Aim Speed: %.0f%%")) viText:@(oxorany("Tốc độ kéo: %.0f%%"))], speedPct];
            spdLbl.font = MDFont(14, UIFontWeightMedium);
            spdLbl.textColor = textColor;
            [_contentContainer addSubview:spdLbl];
            y += 25;
            UISlider *spdSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, contentWidth - 32, 30)];
            spdSlider.minimumValue = 1.0f; spdSlider.maximumValue = 100.0f; spdSlider.value = speedPct;
            spdSlider.minimumTrackTintColor = MDAccent();
            objc_setAssociatedObject(spdSlider, kKeyKey, @(oxorany("AimSpeed")), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(spdSlider, kLabelKey, spdLbl, OBJC_ASSOCIATION_ASSIGN);
            [spdSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [_contentContainer addSubview:spdSlider];
            y += 40;
        }

    } else if (tab == MenuTabOther) {
        // Functions only — menu style / language moved to Settings tab
        addSectionHeader(@(oxorany("Streamer Mode")));
        addSwitchRow([self localized:@(oxorany("Hide Hack")) viText:@(oxorany("Ẩn Menu khi Quay Video"))], @(oxorany("StreamerMode")), NO);

        addSectionHeader(@(oxorany("Function")));
        addSwitchRow([self localized:@(oxorany("Brutal")) viText:@(oxorany("Brutal"))], @(oxorany("Norecoil")), NO);
        // Menu Speed OFF while Brutal. Brutal has its own run-scale slider (Lite + Pro).
        BOOL brutalOn = ESPPrefsBool(@(oxorany("Norecoil")), NO);
        BOOL speedOn = ESPPrefsBool(@(oxorany("Speed")), NO) && !brutalOn;
        if (brutalOn) {
            CGFloat brutalSpd = ESPPrefsFloat(@(oxorany("BrutalSpeed")), 0.16f);
            if (brutalSpd < 0.05f) brutalSpd = 0.05f;
            if (brutalSpd > 0.80f) brutalSpd = 0.80f;
            UILabel *brutalSpdLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y+5, contentWidth - 32, 20)];
            brutalSpdLbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Brutal Run Speed: %.2f")) viText:@(oxorany("Tốc độ chạy Brutal: %.2f"))], brutalSpd];
            brutalSpdLbl.font = MDFont(14, UIFontWeightMedium);
            brutalSpdLbl.textColor = textColor;
            [_contentContainer addSubview:brutalSpdLbl];
            y += 25;
            UISlider *brutalSpdSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, contentWidth - 32, 30)];
            brutalSpdSlider.minimumValue = 0.05f;
            brutalSpdSlider.maximumValue = 0.80f;
            brutalSpdSlider.value = brutalSpd;
            brutalSpdSlider.minimumTrackTintColor = MDAccent();
            objc_setAssociatedObject(brutalSpdSlider, kKeyKey, @(oxorany("BrutalSpeed")), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(brutalSpdSlider, kLabelKey, brutalSpdLbl, OBJC_ASSOCIATION_ASSIGN);
            [brutalSpdSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [_contentContainer addSubview:brutalSpdSlider];
            y += 40;
            UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(16, y+2, contentWidth - 32, 18)];
            note.text = [self localized:@(oxorany("Brutal on → menu Speed locked")) viText:@(oxorany("Brutal bật → khóa Speed menu"))];
            note.font = MDFont(12, UIFontWeightMedium);
            note.textColor = MDMuted();
            [_contentContainer addSubview:note];
            y += 26;
        }
        addSwitchRow([self localized:@(oxorany("Speed")) viText:@(oxorany("Tăng tốc chạy"))], @(oxorany("Speed")), NO);
        if (speedOn) {
            CGFloat spdVal = ESPPrefsFloat(@(oxorany("SpeedValue")), 1.22f);
            if (spdVal < 1.0f) spdVal = 1.0f;
            if (spdVal > 1.45f) spdVal = 1.45f;
            UILabel *runSpdLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y+5, contentWidth - 32, 20)];
            runSpdLbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Run Speed: %.2fx (online ≤1.28)")) viText:@(oxorany("Tốc độ chạy: %.2fx (online ≤1.28)"))], spdVal];
            runSpdLbl.font = MDFont(14, UIFontWeightMedium);
            runSpdLbl.textColor = textColor;
            [_contentContainer addSubview:runSpdLbl];
            y += 25;
            UISlider *runSpdSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, contentWidth - 32, 30)];
            runSpdSlider.minimumValue = 1.0f;
            runSpdSlider.maximumValue = 1.45f;
            runSpdSlider.value = spdVal;
            runSpdSlider.minimumTrackTintColor = MDAccent();
            objc_setAssociatedObject(runSpdSlider, kKeyKey, @(oxorany("SpeedValue")), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(runSpdSlider, kLabelKey, runSpdLbl, OBJC_ASSOCIATION_ASSIGN);
            [runSpdSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [_contentContainer addSubview:runSpdSlider];
            y += 40;
        }
        addSwitchRow([self localized:@(oxorany("Fast Reload")) viText:@(oxorany("Thay đạn nhanh"))], @(oxorany("FastReload")), NO);
        if (menuStyle == 0) {
            addSwitchRow([self localized:@(oxorany("FakeName")) viText:@(oxorany("Đổi Tên"))], @(oxorany("SetName")), NO);
        }

        CGFloat reloadSpd = ESPPrefsFloat(@(oxorany("FastReloadSpeed")), 1.0f);
        UILabel *reloadLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y+5, contentWidth - 32, 20)];
        reloadLbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Reload Speed: %.1fx")) viText:@(oxorany("Tốc độ nạp đạn: %.1fx"))], reloadSpd];
        reloadLbl.font = MDFont(14, UIFontWeightMedium);
        reloadLbl.textColor = textColor;
        [_contentContainer addSubview:reloadLbl];
        y += 25;
        UISlider *reloadSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, contentWidth - 32, 30)];
        reloadSlider.minimumValue = 1.0f; reloadSlider.maximumValue = 10.0f; reloadSlider.value = reloadSpd;
        reloadSlider.minimumTrackTintColor = MDAccent();
        objc_setAssociatedObject(reloadSlider, kKeyKey, @(oxorany("FastReloadSpeed")), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(reloadSlider, kLabelKey, reloadLbl, OBJC_ASSOCIATION_ASSIGN);
        [reloadSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [_contentContainer addSubview:reloadSlider];
        y += 40;

        addSwitchRow([self localized:@(oxorany("Enable Camera iPad")) viText:@(oxorany("Bật Cam xa"))], @(oxorany("CamPC")), NO);

        CGFloat camPCVal = ESPPrefsFloat(@(oxorany("CamPCValue")), 30.0f);
        UILabel *camLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, y+5, contentWidth - 32, 20)];
        camLbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Camera iPad Dist: %.1f")) viText:@(oxorany("Độ xa Camera: %.1f"))], camPCVal];
        camLbl.font = MDFont(14, UIFontWeightMedium);
        camLbl.textColor = textColor;
        [_contentContainer addSubview:camLbl];
        y += 25;
        UISlider *camSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, contentWidth - 32, 30)];
        camSlider.minimumValue = 0.0f; camSlider.maximumValue = 150.0f; camSlider.value = camPCVal;
        camSlider.minimumTrackTintColor = MDAccent();
        objc_setAssociatedObject(camSlider, kKeyKey, @(oxorany("CamPCValue")), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(camSlider, kLabelKey, camLbl, OBJC_ASSOCIATION_ASSIGN);
        [camSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [_contentContainer addSubview:camSlider];
        y += 40;

    } else if (tab == MenuTabSettings) {
        addSectionHeader([self localized:@(oxorany("Menu Mode")) viText:@(oxorany("Chế Độ Menu"))]);
        NSArray *menuOpts = @[@(oxorany("Menu Pro ( Lag ) ")), @(oxorany("Menu Lite ( No Lag )"))];
        UIView *menuRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Version")) viText:@(oxorany("Phiên bản"))]
                                                  options:menuOpts
                                            selectedIndex:menuStyle
                                                        y:y width:contentWidth key:@(oxorany("MenuLayoutStyle"))];
        [_contentContainer addSubview:menuRow];
        y += menuRow.frame.size.height;

        addSectionHeader([self localized:@(oxorany("Language")) viText:@(oxorany("Ngôn ngữ"))]);
        NSArray *langOpts = @[ @(oxorany("Tiếng Việt")), @(oxorany("English")) ];
        UIView *langRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Language")) viText:@(oxorany("Ngôn ngữ"))]
                                                  options:langOpts
                                            selectedIndex:self.isVietnamese ? 0 : 1
                                                        y:y width:contentWidth key:nil];
        objc_setAssociatedObject(langRow, kSegTypeKey, @(oxorany("Language")), OBJC_ASSOCIATION_COPY_NONATOMIC);
        [_contentContainer addSubview:langRow];
        y += langRow.frame.size.height;

        // ---- Appearance: Dark / Light + Accent (default mint or custom picker) ----
        addSectionHeader([self localized:@(oxorany("Appearance")) viText:@(oxorany("Giao diện"))]);
        NSArray *themeOpts = self.isVietnamese
            ? @[@(oxorany("Tối")), @(oxorany("Sáng"))]
            : @[@(oxorany("Dark")), @(oxorany("Light"))];
        int themeSel = ESPPrefsBool(@(oxorany("AppThemeMode")), NO) ? 1 : 0;
        UIView *themeRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Theme")) viText:@(oxorany("Chủ đề"))]
                                                   options:themeOpts
                                             selectedIndex:themeSel
                                                         y:y width:contentWidth key:nil];
        objc_setAssociatedObject(themeRow, kSegTypeKey, @(oxorany("AppTheme")), OBJC_ASSOCIATION_COPY_NONATOMIC);
        [_contentContainer addSubview:themeRow];
        y += themeRow.frame.size.height;

        NSArray *accentOpts = self.isVietnamese
            ? @[@(oxorany("Mặc định")), @(oxorany("Tùy chỉnh"))]
            : @[@(oxorany("Default")), @(oxorany("Custom"))];
        int accentSel = (int)ESPPrefsFloat(@(oxorany("AppAccentMode")), 0.0f);
        if (accentSel < 0) accentSel = 0;
        if (accentSel > 1) accentSel = 1;
        UIView *accentRow = [self createSegmentRowWithTitle:[self localized:@(oxorany("Accent Color")) viText:@(oxorany("Màu chủ đạo"))]
                                                    options:accentOpts
                                              selectedIndex:accentSel
                                                          y:y width:contentWidth key:@(oxorany("AppAccentMode"))];
        [_contentContainer addSubview:accentRow];
        y += accentRow.frame.size.height;

        if (accentSel == 0) {
            // Default mint chip preview
            UIView *defCard = [[UIView alloc] initWithFrame:CGRectMake(10, y, contentWidth - 20, 44)];
            defCard.backgroundColor = MDPanel2();
            defCard.layer.cornerRadius = 12.0f;
            defCard.layer.borderWidth = 1.0f;
            defCard.layer.borderColor = MDLine().CGColor;
            [_contentContainer addSubview:defCard];
            UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(14, 10, 24, 24)];
            sw.backgroundColor = [UIColor colorWithRed:kMDDefaultAccentR green:kMDDefaultAccentG blue:kMDDefaultAccentB alpha:1.0f];
            sw.layer.cornerRadius = 6.0f;
            sw.layer.borderWidth = 1.0f;
            sw.layer.borderColor = MDLine().CGColor;
            [defCard addSubview:sw];
            UILabel *defLbl = [[UILabel alloc] initWithFrame:CGRectMake(48, 0, contentWidth - 90, 44)];
            defLbl.text = [self localized:@(oxorany("Mint green (default)")) viText:@(oxorany("Xanh mint (mặc định)"))];
            defLbl.font = MDFont(13, UIFontWeightMedium);
            defLbl.textColor = MDText();
            [defCard addSubview:defLbl];
            y += 52.0f;
        } else {
            // Custom accent: spectrum only (no Rainbow mode for menu chrome).
            // Force ColorMode=0 so appendColorControlSection shows the board.
            ESPPrefsSetFloat(@(oxorany("AppAccentColorMode")), 0.0f);
            y = [self appendColorControlSectionWithTitle:[self localized:@(oxorany("Custom Accent")) viText:@(oxorany("Màu tùy chỉnh"))]
                                                  prefix:@(oxorany("AppAccent"))
                                              defaultRGB:kMDDefaultAccentR :kMDDefaultAccentG :kMDDefaultAccentB
                                                       y:y
                                                   width:contentWidth
                                               textColor:textColor];
        }

        addSectionHeader([self localized:@(oxorany("Menu Icon")) viText:@(oxorany("Icon Menu"))]);
        addSwitchRow([self localized:@(oxorany("Lock Menu Icon")) viText:@(oxorany("Khóa vị trí icon"))], @(oxorany("LockMenuIcon")), NO);

        addSectionHeader([self localized:@(oxorany("About")) viText:@(oxorany("Thông tin"))]);
        UIView *aboutCard = [[UIView alloc] initWithFrame:CGRectMake(10, y, contentWidth - 20, 56)];
        aboutCard.backgroundColor = MDPanel2();
        aboutCard.layer.cornerRadius = 12.0f;
        aboutCard.layer.borderWidth = 1.0f;
        aboutCard.layer.borderColor = MDLine().CGColor;
        [_contentContainer addSubview:aboutCard];
        UILabel *aboutLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, contentWidth - 48, 40)];
        aboutLbl.text = @(oxorany("MinhDuc-FF External\ndev: @Bolaminhduc"));
        aboutLbl.numberOfLines = 2;
        aboutLbl.font = MDFont(13, UIFontWeightMedium);
        aboutLbl.textColor = MDMuted();
        [aboutCard addSubview:aboutLbl];
        y += 64.0f;
    }

    _contentContainer.frame = CGRectMake(0, 0, contentWidth, y + 20);
    _contentScrollView.contentSize = CGSizeMake(contentWidth, y + 20);
}

// Color section: mode dropdown (Color Picker / Rainbow).
// Mode 1 (Color Picker) shows spectrum board like screenshot: hue grid + cursor + presets.
- (CGFloat)appendColorControlSectionWithTitle:(NSString *)title
                                       prefix:(NSString *)prefix
                                   defaultRGB:(float)defR :(float)defG :(float)defB
                                            y:(CGFloat)y
                                        width:(CGFloat)contentWidth
                                    textColor:(UIColor *)textColor {
    NSString *modeKey = [NSString stringWithFormat:@"%@ColorMode", prefix];
    NSString *rKey = [NSString stringWithFormat:@"%@ColorR", prefix];
    NSString *gKey = [NSString stringWithFormat:@"%@ColorG", prefix];
    NSString *bKey = [NSString stringWithFormat:@"%@ColorB", prefix];

    int mode = (int)ESPPrefsFloat(modeKey, 0.0f);
    if (mode < 0) mode = 0;
    if (mode > 1) mode = 1;

    float r = ESPPrefsFloat(rKey, defR);
    float g = ESPPrefsFloat(gKey, defG);
    float b = ESPPrefsFloat(bKey, defB);

    NSArray *modeOpts = self.isVietnamese
        ? @[@(oxorany("Chọn màu")), @(oxorany("Rainbow"))]
        : @[@(oxorany("Color Picker")), @(oxorany("Rainbow"))];
    UIView *modeRow = [self createSegmentRowWithTitle:title
                                              options:modeOpts
                                        selectedIndex:mode
                                                    y:y width:contentWidth key:modeKey];
    [_contentContainer addSubview:modeRow];
    y += modeRow.frame.size.height;

    // Rainbow mode: hide the board.
    if (mode != 0) {
        return y;
    }

    UIView *board = [[UIView alloc] initWithFrame:CGRectMake(10, y, contentWidth - 20, 0)];
    board.backgroundColor = MDPanel2();
    board.layer.cornerRadius = 12.0f;
    board.layer.borderWidth = 1.0f;
    board.layer.borderColor = MDLine().CGColor;
    board.clipsToBounds = YES;
    board.tag = kColorBoardTag;
    objc_setAssociatedObject(board, kColorPrefixKey, prefix, OBJC_ASSOCIATION_COPY_NONATOMIC);

    CGFloat pad = 14.0f;
    CGFloat curY = 12.0f;
    CGFloat innerW = board.bounds.size.width - pad * 2;

    // Preview square + RGB label
    UIView *preview = [[UIView alloc] initWithFrame:CGRectMake(pad, curY, 44, 44)];
    preview.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0f];
    preview.layer.cornerRadius = 10.0f;
    preview.layer.borderWidth = 1.5f;
    preview.layer.borderColor = MDLine().CGColor;
    preview.userInteractionEnabled = NO;
    [board addSubview:preview];
    objc_setAssociatedObject(board, kColorPreviewKey, preview, OBJC_ASSOCIATION_ASSIGN);

    UILabel *infoLbl = [[UILabel alloc] initWithFrame:CGRectMake(pad + 54, curY + 4, innerW - 54, 36)];
    infoLbl.numberOfLines = 2;
    infoLbl.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    infoLbl.textColor = MDMuted();
    infoLbl.text = [NSString stringWithFormat:@"R %.0f  G %.0f  B %.0f", r * 255.f, g * 255.f, b * 255.f];
    infoLbl.tag = 8710;
    [board addSubview:infoLbl];
    curY += 54.0f;

    // Spectrum (Quang phổ) image
    CGFloat spectrumH = 150.0f;
    UIImageView *spectrum = [[UIImageView alloc] initWithFrame:CGRectMake(pad, curY, innerW, spectrumH)];
    spectrum.image = ESPSpectrumImage();
    spectrum.contentMode = UIViewContentModeScaleToFill;
    spectrum.layer.cornerRadius = 10.0f;
    spectrum.clipsToBounds = YES;
    spectrum.tag = kColorSpectrumTag;
    spectrum.userInteractionEnabled = NO;
    spectrum.layer.borderWidth = 1.0f;
    spectrum.layer.borderColor = MDLine().CGColor;
    [board addSubview:spectrum];
    objc_setAssociatedObject(board, kColorSpectrumKey, spectrum, OBJC_ASSOCIATION_ASSIGN);

    // Cursor ring on spectrum
    CGFloat cursorSize = 22.0f;
    UIView *cursor = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cursorSize, cursorSize)];
    cursor.backgroundColor = [UIColor clearColor];
    cursor.layer.cornerRadius = cursorSize * 0.5f;
    cursor.layer.borderWidth = 2.5f;
    cursor.layer.borderColor = [UIColor whiteColor].CGColor;
    cursor.layer.shadowColor = [UIColor blackColor].CGColor;
    cursor.layer.shadowOpacity = 0.45f;
    cursor.layer.shadowRadius = 2.0f;
    cursor.layer.shadowOffset = CGSizeMake(0, 1);
    cursor.userInteractionEnabled = NO;
    [board addSubview:cursor];
    objc_setAssociatedObject(board, kColorCursorKey, cursor, OBJC_ASSOCIATION_ASSIGN);

    CGFloat u = 0, v = 0;
    ESPRGBtoSpectrumUV(r, g, b, &u, &v);
    cursor.center = CGPointMake(pad + u * innerW, curY + v * spectrumH);

    curY += spectrumH + 12.0f;

    // Preset chips under spectrum
    CGFloat gap = 8.0f;
    CGFloat chip = 28.0f;
    CGFloat chipsW = chip * kESPColorPresetCount + gap * (kESPColorPresetCount - 1);
    CGFloat chipsX = pad + MAX(0, (innerW - chipsW) * 0.5f);
    for (NSInteger i = 0; i < kESPColorPresetCount; i++) {
        UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(chipsX + i * (chip + gap), curY, chip, chip)];
        sw.backgroundColor = [UIColor colorWithRed:kESPColorPresets[i][0]
                                             green:kESPColorPresets[i][1]
                                              blue:kESPColorPresets[i][2]
                                             alpha:1.0f];
        sw.layer.cornerRadius = chip * 0.5f;
        sw.layer.borderWidth = 1.5f;
        sw.layer.borderColor = MDLine().CGColor;
        sw.tag = kColorSwatchBaseTag + i;
        sw.userInteractionEnabled = NO;
        objc_setAssociatedObject(sw, kColorPrefixKey, prefix, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [board addSubview:sw];
    }
    curY += chip + 12.0f;

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(pad, curY, board.bounds.size.width - pad * 2.0f, 0.5)];
    sep.backgroundColor = MDLine();
    [board addSubview:sep];
    curY += 10.0f;

    CGRect bf = board.frame;
    bf.size.height = curY;
    board.frame = bf;
    [_contentContainer addSubview:board];
    return y + curY + 8.0f;
}

- (void)applyRGB:(float)r g:(float)g b:(float)b forPrefix:(NSString *)prefix board:(UIView *)board {
    if (prefix.length == 0) return;
    if (r < 0) r = 0; if (r > 1) r = 1;
    if (g < 0) g = 0; if (g > 1) g = 1;
    if (b < 0) b = 0; if (b > 1) b = 1;

    ESPPrefsSetFloatLive([NSString stringWithFormat:@"%@ColorR", prefix], r);
    ESPPrefsSetFloatLive([NSString stringWithFormat:@"%@ColorG", prefix], g);
    ESPPrefsSetFloatLive([NSString stringWithFormat:@"%@ColorB", prefix], b);

    UIView *preview = objc_getAssociatedObject(board, kColorPreviewKey);
    if (preview) preview.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0f];

    UILabel *info = (UILabel *)[board viewWithTag:8710];
    if (info) {
        info.text = [NSString stringWithFormat:@"R %.0f  G %.0f  B %.0f", r * 255.f, g * 255.f, b * 255.f];
    }

    UIView *cursor = objc_getAssociatedObject(board, kColorCursorKey);
    UIView *spectrum = objc_getAssociatedObject(board, kColorSpectrumKey);
    if (cursor && spectrum) {
        CGFloat u = 0, v = 0;
        ESPRGBtoSpectrumUV(r, g, b, &u, &v);
        cursor.center = CGPointMake(CGRectGetMinX(spectrum.frame) + u * spectrum.bounds.size.width,
                                    CGRectGetMinY(spectrum.frame) + v * spectrum.bounds.size.height);
    }

    // Menu accent chrome: live-update switches / headers while dragging.
    if ([prefix isEqualToString:@(oxorany("AppAccent"))]) {
        g_mdAccentMode = 1;
        g_mdAR = r; g_mdAG = g; g_mdAB = b;
        [self refreshThemeColors];
    }
}

- (void)handleSpectrumTouchOnBoard:(UIView *)board atPointInBoard:(CGPoint)p commit:(BOOL)commit {
    UIView *spectrum = objc_getAssociatedObject(board, kColorSpectrumKey);
    NSString *prefix = objc_getAssociatedObject(board, kColorPrefixKey);
    if (!spectrum || prefix.length == 0) return;

    CGRect sf = spectrum.frame;
    CGFloat u = (p.x - sf.origin.x) / MAX(1.0, sf.size.width);
    CGFloat v = (p.y - sf.origin.y) / MAX(1.0, sf.size.height);
    if (u < 0) u = 0; if (u > 1) u = 1;
    if (v < 0) v = 0; if (v > 1) v = 1;

    float r = 0, g = 0, b = 0;
    ESPSpectrumUVtoRGB(u, v, &r, &g, &b);

    UIView *cursor = objc_getAssociatedObject(board, kColorCursorKey);
    if (cursor) {
        cursor.center = CGPointMake(sf.origin.x + u * sf.size.width,
                                    sf.origin.y + v * sf.size.height);
    }
    UIView *preview = objc_getAssociatedObject(board, kColorPreviewKey);
    if (preview) preview.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0f];
    UILabel *info = (UILabel *)[board viewWithTag:8710];
    if (info) {
        info.text = [NSString stringWithFormat:@"R %.0f  G %.0f  B %.0f", r * 255.f, g * 255.f, b * 255.f];
    }

    ESPPrefsSetFloatLive([NSString stringWithFormat:@"%@ColorR", prefix], r);
    ESPPrefsSetFloatLive([NSString stringWithFormat:@"%@ColorG", prefix], g);
    ESPPrefsSetFloatLive([NSString stringWithFormat:@"%@ColorB", prefix], b);

    if ([prefix isEqualToString:@(oxorany("AppAccent"))]) {
        g_mdAccentMode = 1;
        g_mdAR = r; g_mdAG = g; g_mdAB = b;
        [self refreshThemeColors];
    }

    if (commit) {
        ESPPrefsSetFloat([NSString stringWithFormat:@"%@ColorR", prefix], r);
        ESPPrefsSetFloat([NSString stringWithFormat:@"%@ColorG", prefix], g);
        ESPPrefsSetFloat([NSString stringWithFormat:@"%@ColorB", prefix], b);
        ESPPrefsSetFloat([NSString stringWithFormat:@"%@ColorMode", prefix], 0.0f);
        if ([prefix isEqualToString:@(oxorany("AppAccent"))]) {
            ESPPrefsSetFloat(@(oxorany("AppAccentMode")), 1.0f);
        }
        ESPPrefsSync();
        ESPSyncFromPrefs();
        if ([prefix isEqualToString:@(oxorany("AppAccent"))]) {
            MDLoadThemeFromPrefs();
            [self refreshThemeColors];
        }
    }
}

- (void)applyColorPreset:(NSInteger)presetIndex forPrefix:(NSString *)prefix {
    if (presetIndex < 0 || presetIndex >= kESPColorPresetCount || prefix.length == 0) return;
    float r = kESPColorPresets[presetIndex][0];
    float g = kESPColorPresets[presetIndex][1];
    float b = kESPColorPresets[presetIndex][2];
    ESPPrefsSetFloat([NSString stringWithFormat:@"%@ColorR", prefix], r);
    ESPPrefsSetFloat([NSString stringWithFormat:@"%@ColorG", prefix], g);
    ESPPrefsSetFloat([NSString stringWithFormat:@"%@ColorB", prefix], b);
    // Force Color Picker mode when picking a preset.
    ESPPrefsSetFloat([NSString stringWithFormat:@"%@ColorMode", prefix], 0.0f);
    if ([prefix isEqualToString:@(oxorany("AppAccent"))]) {
        ESPPrefsSetFloat(@(oxorany("AppAccentMode")), 1.0f);
        g_mdAccentMode = 1;
        g_mdAR = r; g_mdAG = g; g_mdAB = b;
    }
    ESPPrefsSync();
    ESPSyncFromPrefs();
    if ([prefix isEqualToString:@(oxorany("AppAccent"))]) {
        MDLoadThemeFromPrefs();
        [self refreshThemeColors];
    }
    [self loadTabContent:self.currentTab];
}

- (UIView *)createSegmentRowWithTitle:(NSString *)title
                              options:(NSArray *)options
                        selectedIndex:(NSInteger)sel
                                    y:(CGFloat)y
                                width:(CGFloat)rowW
                                  key:(NSString *)prefsKey {
    const CGFloat titleH = 20.0f;
    const CGFloat pillH = 34.0f;
    const CGFloat vGap = 8.0f;
    const CGFloat hPad = 10.0f;
    CGFloat rowH = titleH + vGap + pillH + 14.0f;

    // Match switch-row card style (dark panel + border).
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(hPad, y, rowW - hPad * 2.0f, rowH)];
    row.backgroundColor = MDPanel2();
    row.layer.cornerRadius = 12.0f;
    row.layer.borderWidth = 1.0f;
    row.layer.borderColor = MDLine().CGColor;
    row.clipsToBounds = YES;

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, row.bounds.size.width - 28, titleH)];
    titleLbl.text = title;
    titleLbl.font = MDFont(13, UIFontWeightMedium);
    titleLbl.textColor = MDText();
    titleLbl.tag = 9301;
    [row addSubview:titleLbl];

    CGFloat trackX = 14.0f;
    CGFloat trackW = row.bounds.size.width - 28.0f;
    UIView *track = [[UIView alloc] initWithFrame:CGRectMake(trackX, titleH + vGap + 6.0f, trackW, pillH)];
    track.tag = kSegmentTrackTag;
    track.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.045f];
    track.layer.cornerRadius = 10.0f;
    track.layer.borderWidth = 1.0f;
    track.layer.borderColor = MDLine().CGColor;
    track.clipsToBounds = YES;
    [row addSubview:track];

    CGFloat segW = trackW / (CGFloat)MAX(1, (NSInteger)options.count);
    NSMutableArray *cells = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(segW * (CGFloat)i, 0, segW, pillH)];
        cell.userInteractionEnabled = NO;
        cell.layer.cornerRadius = 9.0f;
        cell.clipsToBounds = YES;
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectInset(cell.bounds, 4, 0)];
        lab.tag = kSegmentLabelTag;
        lab.text = options[i];
        lab.font = MDFont(11, UIFontWeightBold);
        lab.textAlignment = NSTextAlignmentCenter;
        lab.textColor = MDMuted();
        lab.adjustsFontSizeToFitWidth = YES;
        lab.minimumScaleFactor = 0.5f;
        [cell addSubview:lab];
        [track addSubview:cell];
        [cells addObject:cell];
    }
    objc_setAssociatedObject(row, kSegCellsKey, cells, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self updateSegmentedRowVisual:row selectedIndex:(int)sel];

    if (prefsKey) {
        objc_setAssociatedObject(row, kSegComboPrefsKey, prefsKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return row;
}

// Multi-select chip row (independent toggles, e.g. Wall + Ice). Looks like segment dropdown.
- (UIView *)createMultiSelectRowWithTitle:(NSString *)title
                                  options:(NSArray *)options
                                     keys:(NSArray *)keys
                                 selected:(NSArray *)selected
                                        y:(CGFloat)y
                                    width:(CGFloat)rowW {
    const CGFloat titleH = 20.0f;
    const CGFloat pillH = 34.0f;
    const CGFloat vGap = 8.0f;
    const CGFloat hPad = 10.0f;
    CGFloat rowH = titleH + vGap + pillH + 14.0f;

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(hPad, y, rowW - hPad * 2.0f, rowH)];
    row.backgroundColor = MDPanel2();
    row.layer.cornerRadius = 12.0f;
    row.layer.borderWidth = 1.0f;
    row.layer.borderColor = MDLine().CGColor;
    row.clipsToBounds = YES;

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, row.bounds.size.width - 28, titleH)];
    titleLbl.text = title;
    titleLbl.font = MDFont(13, UIFontWeightMedium);
    titleLbl.textColor = MDText();
    titleLbl.tag = 9301;
    [row addSubview:titleLbl];

    CGFloat trackX = 14.0f;
    CGFloat trackW = row.bounds.size.width - 28.0f;
    UIView *track = [[UIView alloc] initWithFrame:CGRectMake(trackX, titleH + vGap + 6.0f, trackW, pillH)];
    track.tag = kMultiSelectTrackTag;
    track.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.045f];
    track.layer.cornerRadius = 10.0f;
    track.layer.borderWidth = 1.0f;
    track.layer.borderColor = MDLine().CGColor;
    track.clipsToBounds = YES;
    [row addSubview:track];

    NSInteger n = (NSInteger)options.count;
    if (n < 1) n = 1;
    CGFloat segW = trackW / (CGFloat)n;
    NSMutableArray *cells = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(segW * (CGFloat)i, 0, segW, pillH)];
        cell.userInteractionEnabled = NO;
        cell.layer.cornerRadius = 9.0f;
        cell.clipsToBounds = YES;
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectInset(cell.bounds, 4, 0)];
        lab.tag = kSegmentLabelTag;
        lab.text = (i < (NSInteger)options.count) ? options[i] : @"";
        lab.font = MDFont(11, UIFontWeightBold);
        lab.textAlignment = NSTextAlignmentCenter;
        lab.textColor = MDMuted();
        lab.adjustsFontSizeToFitWidth = YES;
        lab.minimumScaleFactor = 0.5f;
        [cell addSubview:lab];
        [track addSubview:cell];
        [cells addObject:cell];
    }
    objc_setAssociatedObject(row, kSegCellsKey, cells, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, kMultiSelectKeysKey, keys, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, kSegTypeKey, @(oxorany("MultiSelect")), OBJC_ASSOCIATION_COPY_NONATOMIC);

    // Visual from selected BOOL array.
    for (NSInteger i = 0; i < (NSInteger)cells.count; i++) {
        BOOL on = (i < (NSInteger)selected.count) ? [selected[i] boolValue] : NO;
        UIView *cell = cells[i];
        UILabel *lab = [cell viewWithTag:kSegmentLabelTag];
        if (on) {
            cell.backgroundColor = MDAccentSoft(0.18f);
            cell.layer.borderWidth = 1.0f;
            cell.layer.borderColor = MDAccentSoft(0.45f).CGColor;
            if (lab) { lab.textColor = MDText(); lab.font = MDFont(11, UIFontWeightHeavy); }
        } else {
            cell.backgroundColor = [UIColor clearColor];
            cell.layer.borderWidth = 0.0f;
            if (lab) { lab.textColor = MDMuted(); lab.font = MDFont(11, UIFontWeightBold); }
        }
    }
    return row;
}

- (void)updateMultiSelectRowVisual:(UIView *)row {
    NSArray<UIView *> *cells = objc_getAssociatedObject(row, kSegCellsKey);
    NSArray *keys = objc_getAssociatedObject(row, kMultiSelectKeysKey);
    if (!cells.count || !keys.count) return;
    for (NSInteger i = 0; i < (NSInteger)cells.count; i++) {
        BOOL on = NO;
        if (i < (NSInteger)keys.count) on = ESPPrefsBool(keys[i], NO);
        UIView *cell = cells[i];
        UILabel *lab = [cell viewWithTag:kSegmentLabelTag];
        if (on) {
            cell.backgroundColor = MDAccentSoft(0.18f);
            cell.layer.borderWidth = 1.0f;
            cell.layer.borderColor = MDAccentSoft(0.45f).CGColor;
            if (lab) { lab.textColor = MDText(); lab.font = MDFont(11, UIFontWeightHeavy); }
        } else {
            cell.backgroundColor = [UIColor clearColor];
            cell.layer.borderWidth = 0.0f;
            cell.layer.borderColor = [UIColor clearColor].CGColor;
            if (lab) { lab.textColor = MDMuted(); lab.font = MDFont(11, UIFontWeightBold); }
        }
    }
}

- (void)handleMultiSelectTapForRow:(UIView *)row atPoint:(CGPoint)inContent {
    NSArray *keys = objc_getAssociatedObject(row, kMultiSelectKeysKey);
    NSArray<UIView *> *cells = objc_getAssociatedObject(row, kSegCellsKey);
    UIView *track = [row viewWithTag:kMultiSelectTrackTag];
    if (!track || cells.count == 0 || keys.count == 0) return;

    CGPoint inRow = CGPointMake(inContent.x - row.frame.origin.x, inContent.y - row.frame.origin.y);
    if (!CGRectContainsPoint(track.frame, inRow)) return;

    CGFloat relX = inRow.x - track.frame.origin.x;
    CGFloat w = track.bounds.size.width;
    NSInteger n = (NSInteger)cells.count;
    if (w <= 0 || n <= 0) return;
    NSInteger idx = (NSInteger)(relX / (w / (CGFloat)n));
    if (idx < 0) idx = 0;
    if (idx >= n) idx = n - 1;
    if (idx >= (NSInteger)keys.count) return;

    NSString *key = keys[idx];
    BOOL now = !ESPPrefsBool(key, NO);
    ESPPrefsSetBool(key, now);
    if ([key isEqualToString:@(oxorany("AimBehindWall"))]) {
        ESPSetAimBehindWallLive(now);
    }
    ESPPrefsSync();
    ESPSyncFromPrefs();
    [self updateMultiSelectRowVisual:row];
}

- (void)updateSegmentedRowVisual:(UIView *)row selectedIndex:(int)sel {
    NSArray<UIView *> *cells = objc_getAssociatedObject(row, kSegCellsKey);
    if (!cells || cells.count == 0) return;

    for (NSInteger i = 0; i < (NSInteger)cells.count; i++) {
        UIView *cell = cells[i];
        UILabel *lab = [cell viewWithTag:kSegmentLabelTag];
        if (i == sel) {
            cell.backgroundColor = MDAccentSoft(0.18f);
            cell.layer.borderWidth = 1.0f;
            cell.layer.borderColor = MDAccentSoft(0.45f).CGColor;
            cell.layer.shadowOpacity = 0;
            if (lab) {
                lab.textColor = MDText();
                lab.font = MDFont(11, UIFontWeightHeavy);
            }
        } else {
            cell.backgroundColor = [UIColor clearColor];
            cell.layer.borderWidth = 0.0f;
            cell.layer.borderColor = [UIColor clearColor].CGColor;
            cell.layer.shadowOpacity = 0;
            if (lab) {
                lab.textColor = MDMuted();
                lab.font = MDFont(11, UIFontWeightBold);
            }
        }
    }
}

- (void)handleSegmentTapForRow:(UIView *)row atPoint:(CGPoint)inContent {
    NSString *prefsKey = objc_getAssociatedObject(row, kSegComboPrefsKey);
    NSString *segType = objc_getAssociatedObject(row, kSegTypeKey);
    NSArray<UIView *> *cells = objc_getAssociatedObject(row, kSegCellsKey);
    UIView *track = [row viewWithTag:kSegmentTrackTag];
    if (!track || cells.count == 0) return;

    CGPoint inRow = CGPointMake(inContent.x - row.frame.origin.x, inContent.y - row.frame.origin.y);
    if (!CGRectContainsPoint(track.frame, inRow)) return;

    CGFloat relX = inRow.x - track.frame.origin.x;
    CGFloat w = track.bounds.size.width;
    NSInteger n = (NSInteger)cells.count;
    if (w <= 0 || n <= 0) return;
    NSInteger idx = (NSInteger)(relX / (w / (CGFloat)n));
    if (idx < 0) idx = 0;
    if (idx >= n) idx = n - 1;

    [self updateSegmentedRowVisual:row selectedIndex:(int)idx];

    if (prefsKey) {
        // Master aim type dropdown: exactly one of Aimbot / Assist / Legit.
        if ([prefsKey isEqualToString:@(oxorany("AimTypeMode"))]) {
            ESPPrefsSetFloat(prefsKey, (float)idx);
            ESPPrefsSetBool(@(oxorany("AimMaster")), YES);
            if (idx == 0) {
                ESPPrefsSetBool(@(oxorany("Aimbot")), YES);
                ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
                ESPPrefsSetBool(@(oxorany("AimLegit")), NO);
            } else if (idx == 1) {
                ESPPrefsSetBool(@(oxorany("Aimbot")), NO);
                ESPPrefsSetBool(@(oxorany("AimAssist")), YES);
                ESPPrefsSetBool(@(oxorany("AimLegit")), NO);
                ESPPrefsSetFloat(@(oxorany("AimSphereMode")), 0.0f);
                ESPPrefsSetBool(@(oxorany("Aim360")), NO);
            } else {
                ESPPrefsSetBool(@(oxorany("Aimbot")), NO);
                ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
                ESPPrefsSetBool(@(oxorany("AimLegit")), YES);
                ESPPrefsSetFloat(@(oxorany("AimSphereMode")), 0.0f);
                ESPPrefsSetBool(@(oxorany("Aim360")), NO);
            }
            ESPPrefsSync();
            ESPSyncFromPrefs();
            if (self.currentTab == MenuTabAimbot) [self loadTabContent:self.currentTab];
            return;
        }
        if ([prefsKey isEqualToString:@(oxorany("MenuLayoutStyle"))]) {
            // Write layout first so ResolveKey uses the new Pro/Lite namespace.
            ESPPrefsSetFloat(prefsKey, (float)idx);

            if (idx == 1) {
                // Switching INTO Lite: write Lite-suffixed keys only.
                BOOL wasProESPOn = ESPPrefsBool(@(oxorany("EnableESP")), NO);
                if (wasProESPOn) {
                    ESPPrefsSetBool(@(oxorany("EnableESP2")), YES);
                }

                ESPPrefsSetBool(@(oxorany("EnableESP")), NO);
                ESPPrefsSetBool(@(oxorany("Name")), NO);
                ESPPrefsSetBool(@(oxorany("Bone")), NO);
                ESPPrefsSetBool(@(oxorany("Distance")), NO);
                ESPPrefsSetBool(@(oxorany("Weapon")), NO);
                ESPPrefsSetBool(@(oxorany("EspBot")), NO);
                ESPPrefsSetBool(@(oxorany("Alert360")), NO);
                ESPPrefsSetBool(@(oxorany("AlertNum")), NO);

                ESPPrefsSetBool(@(oxorany("AimIgnoreBot")), NO);
                ESPPrefsSetBool(@(oxorany("AimIgnoreKnock")), NO);
                ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
                ESPPrefsSetBool(@(oxorany("AimBehindWall")), NO);
                ESPSetAimBehindWallLive(false);
                // Lite default trigger = Fire&Scope (3). Auto (0) locks cam always.
                ESPPrefsSetFloat(@(oxorany("TriggerMode")), 3.0f);

                ESPPrefsSetBool(@(oxorany("StreamerMode")), NO);
                ESPPrefsSetBool(@(oxorany("SpeedX50")), NO);

                int currentPos = (int)ESPPrefsFloat(@(oxorany("AimPos")), 0.0f);
                if (currentPos > 1) {
                    ESPPrefsSetFloat(@(oxorany("AimPos")), 1.0f);
                    [[NSNotificationCenter defaultCenter] postNotificationName:@(oxorany("AimPosChangedNotification")) object:nil];
                }

                [self hideExternalAimButton];
            } else {
                // Switching INTO Pro: restore Pro profile; resync wall live from Pro prefs.
                if (ESPPrefsBool(@(oxorany("EnableESP2")), NO)) {
                    ESPPrefsSetBool(@(oxorany("EnableESP")), YES);
                }
                ESPPrefsSetBool(@(oxorany("EnableESP2")), NO);
                ESPSetAimBehindWallLive(ESPPrefsBool(@(oxorany("AimBehindWall")), NO));
            }
            ESPPrefsSync();
            ESPSyncFromPrefs();
            [self loadTabContent:self.currentTab];
            // Rebuild sidebar labels so Pro/Lite + language stay in sync.
            [self updateSidebarForTab:self.currentTab];
            [[NSNotificationCenter defaultCenter] postNotificationName:NSUserDefaultsDidChangeNotification object:nil];
        } else {
            ESPPrefsSetFloat(prefsKey, (float)idx);
            // Keep legacy Aim360 bool in sync for older prefs readers.
            if ([prefsKey isEqualToString:@(oxorany("AimSphereMode"))]) {
                ESPPrefsSetBool(@(oxorany("Aim360")), idx == 2);
            }
            ESPPrefsSync();
            ESPSyncFromPrefs();

            if ([prefsKey isEqualToString:@(oxorany("AimPos"))]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@(oxorany("AimPosChangedNotification")) object:nil];
            }
            // Color mode dropdown: reload so color board shows/hides.
            if ([prefsKey hasSuffix:@(oxorany("ColorMode"))]) {
                [self loadTabContent:self.currentTab];
            }
            // Aim range FOV/180/360: rebuild to show/hide FOV slider.
            if ([prefsKey isEqualToString:@(oxorany("AimSphereMode"))]) {
                [self loadTabContent:self.currentTab];
            }
            // Accent mode Default/Custom: rebuild board + refresh chrome colors.
            if ([prefsKey isEqualToString:@(oxorany("AppAccentMode"))]) {
                MDLoadThemeFromPrefs();
                [self refreshThemeColors];
                [self loadTabContent:self.currentTab];
                [self updateSidebarForTab:self.currentTab];
            }
            // Live accent RGB from spectrum uses AppAccentColorR/G/B + ColorMode.
            if ([prefsKey hasPrefix:@(oxorany("AppAccent"))]) {
                MDLoadThemeFromPrefs();
                [self refreshThemeColors];
            }
        }

    } else if ([segType isEqualToString:@(oxorany("Language"))]) {
        self.isVietnamese = (idx == 0);
        ESPPrefsSetBool(@(oxorany("AppLanguage")), self.isVietnamese);
        ESPPrefsSync();
        // Reload current tab + sidebar so all labels match language immediately.
        [self loadTabContent:self.currentTab];
        [self updateSidebarForTab:self.currentTab];
    } else if ([segType isEqualToString:@(oxorany("AppTheme"))]) {
        // 0 Dark / 1 Light
        BOOL light = (idx == 1);
        ESPPrefsSetBool(@(oxorany("AppThemeMode")), light);
        ESPPrefsSync();
        MDLoadThemeFromPrefs();
        self.isLightMode = light;
        [self refreshThemeColors];
        [self loadTabContent:self.currentTab];
        [self updateSidebarForTab:self.currentTab];
    }
}

- (void)tabButtonTapped:(UIButton *)sender {
    MenuTab tab = (MenuTab)sender.tag;
    if (tab == self.currentTab) return;
    self.currentTab = tab;
    ESPPrefsSetFloat(@(oxorany("MenuLastTab")), (float)tab);
    [self updateSidebarForTab:tab];
    [self loadTabContent:tab];
}

- (void)updateSidebarForTab:(MenuTab)tab {
    for (NSInteger i = 0; i < self.tabButtons.count; i++) {
        UIButton *btn = self.tabButtons[i];
        [[btn viewWithTag:7301] removeFromSuperview];
        UILabel *ico = (UILabel *)[btn viewWithTag:7401];
        UILabel *ttl = (UILabel *)[btn viewWithTag:7402];
        if (i == tab) {
            btn.backgroundColor = MDAccentSoft(0.12f);
            btn.layer.borderWidth = 1.0f;
            btn.layer.borderColor = MDAccentSoft(0.22f).CGColor;
            if (ttl) { ttl.textColor = MDText(); ttl.font = MDFont(12, UIFontWeightBold); }
            if (ico) { ico.textColor = MDAccent(); }
            UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 10, 3, btn.bounds.size.height - 20)];
            bar.backgroundColor = MDAccent();
            bar.tag = 7301;
            bar.autoresizingMask = UIViewAutoresizingFlexibleHeight;
            [btn addSubview:bar];
        } else {
            btn.backgroundColor = [UIColor clearColor];
            btn.layer.borderWidth = 0.0f;
            btn.layer.borderColor = [UIColor clearColor].CGColor;
            if (ttl) { ttl.textColor = MDMuted(); ttl.font = MDFont(12, UIFontWeightSemibold); }
            if (ico) { ico.textColor = MDMuted(); }
        }
    }
}

- (void)switchChanged:(UISwitch *)sender {
    NSString *key = objc_getAssociatedObject(sender, kKeyKey);
    if (key) {
        if ([key isEqualToString:@(oxorany("EnableESP"))] && sender.on) {
            ESPPrefsSetBool(@(oxorany("EnableESP2")), NO);
        } else if ([key isEqualToString:@(oxorany("EnableESP2"))] && sender.on) {
            ESPPrefsSetBool(@(oxorany("EnableESP")), NO);
        }
        
        // Memory update is immediate; disk write is debounced in ESPPrefs.
        ESPPrefsSetBool(key, sender.on);

        // Keep AimOnBot <-> AimIgnoreBot mirrored for engine + legacy prefs.
        if ([key isEqualToString:@(oxorany("AimOnBot"))]) {
            ESPPrefsSetBool(@(oxorany("AimIgnoreBot")), !sender.on);
        } else if ([key isEqualToString:@(oxorany("AimIgnoreBot"))]) {
            ESPPrefsSetBool(@(oxorany("AimOnBot")), !sender.on);
        } else if ([key isEqualToString:@(oxorany("AimMaster"))]) {
            // Master aim switch: ON enables selected type; OFF kills all camera aim modes.
            if (sender.on) {
                int type = (int)ESPPrefsFloat(@(oxorany("AimTypeMode")), 0.0f);
                if (type < 0) type = 0;
                if (type > 2) type = 2;
                ESPPrefsSetFloat(@(oxorany("AimTypeMode")), (float)type);
                if (type == 0) {
                    ESPPrefsSetBool(@(oxorany("Aimbot")), YES);
                    ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
                    ESPPrefsSetBool(@(oxorany("AimLegit")), NO);
                } else if (type == 1) {
                    ESPPrefsSetBool(@(oxorany("Aimbot")), NO);
                    ESPPrefsSetBool(@(oxorany("AimAssist")), YES);
                    ESPPrefsSetBool(@(oxorany("AimLegit")), NO);
                    ESPPrefsSetFloat(@(oxorany("AimSphereMode")), 0.0f);
                    ESPPrefsSetBool(@(oxorany("Aim360")), NO);
                } else {
                    ESPPrefsSetBool(@(oxorany("Aimbot")), NO);
                    ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
                    ESPPrefsSetBool(@(oxorany("AimLegit")), YES);
                    ESPPrefsSetFloat(@(oxorany("AimSphereMode")), 0.0f);
                    ESPPrefsSetBool(@(oxorany("Aim360")), NO);
                }
            } else {
                ESPPrefsSetBool(@(oxorany("Aimbot")), NO);
                ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
                ESPPrefsSetBool(@(oxorany("AimLegit")), NO);
                ESPPrefsSetFloat(@(oxorany("AimSphereMode")), 0.0f);
                ESPPrefsSetBool(@(oxorany("Aim360")), NO);
            }
        } else if ([key isEqualToString:@(oxorany("Aimbot"))]) {
            if (sender.on) {
                ESPPrefsSetBool(@(oxorany("AimMaster")), YES);
                ESPPrefsSetFloat(@(oxorany("AimTypeMode")), 0.0f);
                ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
                ESPPrefsSetBool(@(oxorany("AimLegit")), NO);
            } else {
                ESPPrefsSetFloat(@(oxorany("AimSphereMode")), 0.0f);
                ESPPrefsSetBool(@(oxorany("Aim360")), NO);
            }
        } else if ([key isEqualToString:@(oxorany("AimLegit"))] && sender.on) {
            ESPPrefsSetBool(@(oxorany("AimMaster")), YES);
            ESPPrefsSetFloat(@(oxorany("AimTypeMode")), 2.0f);
            ESPPrefsSetBool(@(oxorany("Aimbot")), NO);
            ESPPrefsSetBool(@(oxorany("AimAssist")), NO);
            ESPPrefsSetFloat(@(oxorany("AimSphereMode")), 0.0f);
            ESPPrefsSetBool(@(oxorany("Aim360")), NO);
        } else if ([key isEqualToString:@(oxorany("AimAssist"))] && sender.on) {
            ESPPrefsSetBool(@(oxorany("AimMaster")), YES);
            ESPPrefsSetFloat(@(oxorany("AimTypeMode")), 1.0f);
            ESPPrefsSetBool(@(oxorany("Aimbot")), NO);
            ESPPrefsSetBool(@(oxorany("AimLegit")), NO);
            ESPPrefsSetFloat(@(oxorany("AimSphereMode")), 0.0f);
            ESPPrefsSetBool(@(oxorany("Aim360")), NO);
        } else if ([key isEqualToString:@(oxorany("AimBehindWall"))]) {
            ESPSetAimBehindWallLive(sender.on);
        } else if ([key isEqualToString:@(oxorany("Norecoil"))] && sender.on) {
            // Brutal ON → force menu Speed OFF (Brutal has its own ~1.50 run scale).
            ESPPrefsSetBool(@(oxorany("Speed")), NO);
        } else if ([key isEqualToString:@(oxorany("Speed"))] && sender.on) {
            // Cannot enable menu Speed while Brutal is on.
            if (ESPPrefsBool(@(oxorany("Norecoil")), NO)) {
                ESPPrefsSetBool(@(oxorany("Speed")), NO);
                sender.on = NO;
            }
        }

        ESPSyncFromPrefs();

        if ([key isEqualToString:@(oxorany("SpeedX50"))]) {
            ToggleSpeedX50(sender.on);
        }

        if ((int)ESPPrefsFloat(@(oxorany("MenuLayoutStyle")), 0) == 1) {
            [self hideExternalAimButton];
        }

        if ([key isEqualToString:@(oxorany("EnableESP"))] || [key isEqualToString:@(oxorany("EnableESP2"))] ||
            [key isEqualToString:@(oxorany("Box"))] || [key isEqualToString:@(oxorany("Name"))] ||
            [key isEqualToString:@(oxorany("Distance"))] || [key isEqualToString:@(oxorany("Health"))] ||
            [key isEqualToString:@(oxorany("Bone"))] || [key isEqualToString:@(oxorany("Line"))]) {
            if (self.currentTab == MenuTabESP) {
                [self loadTabContent:self.currentTab];
            }
        }
        // Rebuild Aimbot tab when aim master / type toggles (dropdown + sphere/FOV).
        if ([key isEqualToString:@(oxorany("AimMaster"))] ||
            [key isEqualToString:@(oxorany("Aimbot"))] ||
            [key isEqualToString:@(oxorany("AimLegit"))] ||
            [key isEqualToString:@(oxorany("AimAssist"))]) {
            if (self.currentTab == MenuTabAimbot) {
                [self loadTabContent:self.currentTab];
            }
        }
        // Rebuild Other tab when Speed/Brutal toggles (show/hide sliders).
        if ([key isEqualToString:@(oxorany("Speed"))] || [key isEqualToString:@(oxorany("Norecoil"))]) {
            if (self.currentTab == MenuTabOther) {
                [self loadTabContent:self.currentTab];
            }
        }
        if ([key isEqualToString:@(oxorany("LockMenuIcon"))] ||
            [key isEqualToString:@(oxorany("FloatAimBtn"))] ||
            [key isEqualToString:@(oxorany("FloatAimPosBtn"))]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:NSUserDefaultsDidChangeNotification object:nil];
        }
    }
}

- (void)sliderChanged:(UISlider *)sender {
    // Drag path: label only. Prefs/ESPSync on finger-up (see touch Ended).
    // Writing UserDefaults + full ESPSync every move was the main menu lag source.
    NSString *key = objc_getAssociatedObject(sender, kKeyKey);
    UILabel *lbl = objc_getAssociatedObject(sender, kLabelKey);
    if (!lbl) return;
    float v = sender.value;
    if ([key isEqualToString:@(oxorany("Fov"))]) {
        lbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Aim FOV: %.0f")) viText:@(oxorany("Vòng FOV: %.0f"))], v];
    } else if ([key isEqualToString:@(oxorany("Distance"))] || [key isEqualToString:@(oxorany("AimDistance"))]) {
        lbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Distance: %.0fm")) viText:@(oxorany("Cự ly Aim: %.0fm"))], v];
    } else if ([key isEqualToString:@(oxorany("AimSpeed"))]) {
        lbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Aim Speed: %.0f%%")) viText:@(oxorany("Tốc độ kéo: %.0f%%"))], v];
    } else if ([key isEqualToString:@(oxorany("SpeedValue"))]) {
        lbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Run Speed: %.2fx (online ≤1.28)")) viText:@(oxorany("Tốc độ chạy: %.2fx (online ≤1.28)"))], v];
    } else if ([key isEqualToString:@(oxorany("BrutalSpeed"))]) {
        lbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Brutal Run Speed: %.2f")) viText:@(oxorany("Tốc độ chạy Brutal: %.2f"))], v];
    } else if ([key isEqualToString:@(oxorany("CamPCValue"))]) {
        lbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Camera iPad Dist: %.1f")) viText:@(oxorany("Độ xa Camera: %.1f"))], v];
    } else if ([key isEqualToString:@(oxorany("FastReloadSpeed"))]) {
        lbl.text = [NSString stringWithFormat:[self localized:@(oxorany("Reload Speed: %.1fx")) viText:@(oxorany("Tốc độ nạp đạn: %.1fx"))], v];
    } else if ([key isEqualToString:@(oxorany("EspDistanceLimit"))]) {
        lbl.text = [NSString stringWithFormat:[self localized:@(oxorany("ESP Distance: %.0fm")) viText:@(oxorany("Tầm xa ESP: %.0fm"))], v];
    }
}

- (void)closeTapped {
    ESPPrefsSetFloat(@(oxorany("FloatingPanelX")), _floatingPanel.frame.origin.x);
    ESPPrefsSetFloat(@(oxorany("FloatingPanelY")), _floatingPanel.frame.origin.y);
    ESPPrefsSetFloat(@(oxorany("MenuLastTab")), (float)self.currentTab);
    ESPPrefsSync();
    if (self.onCloseBlock) self.onCloseBlock();
}

- (BOOL)handleTouchAtViewPoint:(CGPoint)point phase:(NSInteger)phase pointerId:(NSInteger)pointerId {
    BOOL insidePanel = CGRectContainsPoint(_floatingPanel.frame, point);
    UITouchPhase ph = (UITouchPhase)phase;

    if (ph == UITouchPhaseBegan) {
        if (!insidePanel) return NO;
        
        _trackingPointerId = pointerId;
        _touchStartPoint = point;
        _startScrollOffsetY = _contentScrollView.contentOffset.y;
        
        _isContentDragging = NO;
        _isSideNavDragging = NO;
        _menuDragging = NO;
        _touchOnClose = NO;

        _pendingSwitch = nil;
        _pendingSegment = nil;
        _pendingColorSwatch = nil;
        _activeSlider = nil;
        _activeSpectrumBoard = nil;
        _pendingTabIdx = -1;

        CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x, point.y - _floatingPanel.frame.origin.y);

        if (inPanel.y < kHeaderHeight) {
            CGRect closeRect = CGRectMake(kPanelWidth - 42, (kHeaderHeight - 30) / 2.0f, 30, 30);
            if (CGRectContainsPoint(CGRectInset(closeRect, -10, -10), inPanel)) {
                _touchOnClose = YES;
            } else {
                _menuDragging = YES;
                _menuDragStartCenter = _floatingPanel.center;
                _menuDragStartPoint = point;
            }
            return YES;
        }

        // Left side navigation hit-test (profile pinned top + scrollable tabs)
        if (inPanel.x < kSideNavWidth &&
            inPanel.y >= kHeaderHeight &&
            inPanel.y < kPanelHeight - kFooterHeight) {
            _startSideNavOffsetY = _sideNavScrollView.contentOffset.y;
            // Convert into sideNavScrollView content space for tab buttons.
            CGPoint inSideNav = CGPointMake(inPanel.x,
                                            inPanel.y - kHeaderHeight);
            // Profile card lives outside the scroll view — ignore tab select there.
            UIView *prof = [_sideNavBar viewWithTag:7201];
            if (prof && CGRectContainsPoint(prof.frame, inSideNav)) {
                _pendingTabIdx = -1;
                return YES;
            }
            CGPoint inScroll = CGPointMake(inSideNav.x - _sideNavScrollView.frame.origin.x,
                                           inSideNav.y - _sideNavScrollView.frame.origin.y + _sideNavScrollView.contentOffset.y);
            _pendingTabIdx = -1;
            for (UIButton *btn in _tabButtons) {
                if (CGRectContainsPoint(btn.frame, inScroll)) {
                    _pendingTabIdx = btn.tag;
                    break;
                }
            }
            return YES;
        }

        // Content area is to the right of side nav
        CGFloat contentY = kHeaderHeight;
        CGPoint inContent = CGPointMake(inPanel.x - kSideNavWidth,
                                        inPanel.y - contentY + _contentScrollView.contentOffset.y);

        if (inPanel.x >= kSideNavWidth &&
            inPanel.y >= contentY &&
            inPanel.y < kPanelHeight - kFooterHeight) {
            for (UIView *rowView in _contentContainer.subviews) {
                if (!CGRectContainsPoint(rowView.frame, inContent)) continue;

                if ([rowView viewWithTag:kSegmentTrackTag] || [rowView viewWithTag:kMultiSelectTrackTag]) {
                    UIView *track = [rowView viewWithTag:kSegmentTrackTag] ?: [rowView viewWithTag:kMultiSelectTrackTag];
                    CGPoint inRow = CGPointMake(inContent.x - rowView.frame.origin.x, inContent.y - rowView.frame.origin.y);
                    if (track && CGRectContainsPoint(track.frame, inRow)) {
                        _pendingSegment = rowView;
                    }
                    break;
                }

                // Color board: spectrum drag + preset chips.
                if (rowView.tag == kColorBoardTag) {
                    CGPoint inBoard = CGPointMake(inContent.x - rowView.frame.origin.x, inContent.y - rowView.frame.origin.y);
                    UIView *spectrum = objc_getAssociatedObject(rowView, kColorSpectrumKey);
                    if (spectrum && CGRectContainsPoint(CGRectInset(spectrum.frame, -8, -8), inBoard)) {
                        _activeSpectrumBoard = rowView;
                        [self handleSpectrumTouchOnBoard:rowView atPointInBoard:inBoard commit:NO];
                        break;
                    }
                    for (UIView *sub in rowView.subviews) {
                        if (sub.tag >= kColorSwatchBaseTag && sub.tag < kColorSwatchBaseTag + kESPColorPresetCount &&
                            CGRectContainsPoint(sub.frame, inBoard)) {
                            _pendingColorSwatch = sub;
                            break;
                        }
                    }
                    break;
                }

                for (UIView *sub in rowView.subviews) {
                    if ([sub isKindOfClass:[UISwitch class]]) {
                        _pendingSwitch = (UISwitch *)sub;
                        break;
                    }
                }

                if (!_pendingSwitch && (!_pendingSegment) && (!_activeSlider) && (!_pendingColorSwatch)) {
                    for (UIView *sub in _contentContainer.subviews) {
                        if ([sub isKindOfClass:[UISlider class]] && CGRectContainsPoint(sub.frame, inContent)) {
                            _activeSlider = (UISlider *)sub;
                            break;
                        }
                    }
                }
                break;
            }
        }
        return YES;
    }

    if (ph == UITouchPhaseMoved && pointerId == _trackingPointerId) {
        if (_menuDragging) {
            // Absolute from drag start (no per-frame start reset) + no implicit layer animations.
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            CGFloat dx = point.x - _menuDragStartPoint.x;
            CGFloat dy = point.y - _menuDragStartPoint.y;
            CGPoint c = CGPointMake(_menuDragStartCenter.x + dx, _menuDragStartCenter.y + dy);
            // Keep panel mostly on-screen.
            CGSize scr = self.view.bounds.size;
            CGFloat hw = _floatingPanel.bounds.size.width * 0.5f;
            CGFloat hh = _floatingPanel.bounds.size.height * 0.5f;
            if (c.x < hw * 0.35f) c.x = hw * 0.35f;
            if (c.y < hh * 0.35f) c.y = hh * 0.35f;
            if (c.x > scr.width - hw * 0.35f) c.x = scr.width - hw * 0.35f;
            if (c.y > scr.height - hh * 0.35f) c.y = scr.height - hh * 0.35f;
            _floatingPanel.center = c;
            [CATransaction commit];
            return YES;
        }

        if (_activeSpectrumBoard) {
            CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x, point.y - _floatingPanel.frame.origin.y);
            CGFloat contentY = kHeaderHeight;
            CGPoint inContent = CGPointMake(inPanel.x - kSideNavWidth,
                                            inPanel.y - contentY + _contentScrollView.contentOffset.y);
            CGPoint inBoard = CGPointMake(inContent.x - _activeSpectrumBoard.frame.origin.x,
                                          inContent.y - _activeSpectrumBoard.frame.origin.y);
            [self handleSpectrumTouchOnBoard:_activeSpectrumBoard atPointInBoard:inBoard commit:NO];
            return YES;
        }

        if (_activeSlider) {
            CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x, point.y - _floatingPanel.frame.origin.y);
            CGFloat contentY = kHeaderHeight;
            CGPoint inContent = CGPointMake(inPanel.x - kSideNavWidth,
                                            inPanel.y - contentY + _contentScrollView.contentOffset.y);
            // Convert slider frame into contentContainer space.
            CGRect sliderFrameInContent = [_activeSlider.superview convertRect:_activeSlider.frame toView:_contentContainer];
            CGFloat width = sliderFrameInContent.size.width;
            if (width < 1.0f) width = 1.0f;
            CGFloat ratio = (inContent.x - sliderFrameInContent.origin.x) / width;
            if (ratio < 0) ratio = 0; if (ratio > 1) ratio = 1;
            float newVal = _activeSlider.minimumValue + (float)ratio * (_activeSlider.maximumValue - _activeSlider.minimumValue);
            // Skip identical values — reduces label churn while finger holds still.
            if (fabsf(newVal - _activeSlider.value) > 0.0001f) {
                _activeSlider.value = newVal;
                [self sliderChanged:_activeSlider];
            }
            return YES;
        }

        CGFloat dy = point.y - _touchStartPoint.y;
        CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x, point.y - _floatingPanel.frame.origin.y);
        BOOL touchInSideNav = (inPanel.x < kSideNavWidth &&
                               inPanel.y >= kHeaderHeight &&
                               inPanel.y < kPanelHeight - kFooterHeight);

        if (!_isContentDragging && !_isSideNavDragging && fabs(dy) > 5.0f) {
            if (touchInSideNav) {
                _isSideNavDragging = YES;
            } else {
                _isContentDragging = YES;
            }
            _pendingSwitch = nil;
            _pendingSegment = nil;
            _pendingColorSwatch = nil;
            _pendingTabIdx = -1;
        }

        if (_isSideNavDragging) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            CGFloat newOffset = _startSideNavOffsetY - dy;
            CGFloat maxOffset = _sideNavScrollView.contentSize.height - _sideNavScrollView.bounds.size.height;
            if (maxOffset < 0) maxOffset = 0;
            if (newOffset < 0) newOffset = 0;
            if (newOffset > maxOffset) newOffset = maxOffset;
            _sideNavScrollView.contentOffset = CGPointMake(0, newOffset);
            [CATransaction commit];
            return YES;
        }

        if (_isContentDragging) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            CGFloat newOffset = _startScrollOffsetY - dy;
            CGFloat maxOffset = _contentScrollView.contentSize.height - _contentScrollView.bounds.size.height;
            if (maxOffset < 0) maxOffset = 0;
            if (newOffset < 0) newOffset = 0;
            if (newOffset > maxOffset) newOffset = maxOffset;
            _contentScrollView.contentOffset = CGPointMake(0, newOffset);
            [CATransaction commit];
            return YES;
        }

        return YES;
    }

    if ((ph == UITouchPhaseEnded || ph == UITouchPhaseCancelled) && pointerId == _trackingPointerId) {
        if (!_isContentDragging && !_isSideNavDragging && !_menuDragging && !_activeSlider && !_activeSpectrumBoard) {
            if (_touchOnClose) {
                [self closeTapped];
            } else if (_pendingTabIdx >= 0 && _pendingTabIdx < kTabCount && _pendingTabIdx != (NSInteger)self.currentTab) {
                [self tabButtonTapped:self.tabButtons[_pendingTabIdx]];
            } else if (_pendingSwitch) {
                _pendingSwitch.on = !_pendingSwitch.on;
                [self switchChanged:_pendingSwitch];
            } else if (_pendingSegment) {
                CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x, point.y - _floatingPanel.frame.origin.y);
                CGFloat contentY = kHeaderHeight;
                CGPoint inContent = CGPointMake(inPanel.x - kSideNavWidth,
                                                inPanel.y - contentY + _contentScrollView.contentOffset.y);
                NSString *segType = objc_getAssociatedObject(_pendingSegment, kSegTypeKey);
                if ([segType isEqualToString:@(oxorany("MultiSelect"))] ||
                    [_pendingSegment viewWithTag:kMultiSelectTrackTag]) {
                    [self handleMultiSelectTapForRow:_pendingSegment atPoint:inContent];
                } else {
                    [self handleSegmentTapForRow:_pendingSegment atPoint:inContent];
                }
            } else if (_pendingColorSwatch) {
                NSInteger idx = _pendingColorSwatch.tag - kColorSwatchBaseTag;
                NSString *prefix = objc_getAssociatedObject(_pendingColorSwatch, kColorPrefixKey);
                [self applyColorPreset:idx forPrefix:prefix];
            }
        }

        if (_menuDragging) {
            // Save position once on release (not every move).
            ESPPrefsSetFloat(@(oxorany("FloatingPanelX")), _floatingPanel.frame.origin.x);
            ESPPrefsSetFloat(@(oxorany("FloatingPanelY")), _floatingPanel.frame.origin.y);
            ESPPrefsSync();
        }
        if (_activeSpectrumBoard) {
            CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x, point.y - _floatingPanel.frame.origin.y);
            CGFloat contentY = kHeaderHeight;
            CGPoint inContent = CGPointMake(inPanel.x - kSideNavWidth,
                                            inPanel.y - contentY + _contentScrollView.contentOffset.y);
            CGPoint inBoard = CGPointMake(inContent.x - _activeSpectrumBoard.frame.origin.x,
                                          inContent.y - _activeSpectrumBoard.frame.origin.y);
            [self handleSpectrumTouchOnBoard:_activeSpectrumBoard atPointInBoard:inBoard commit:YES];
        }
        if (_activeSlider) {
            // Commit live slider value + one sync on release.
            NSString *key = objc_getAssociatedObject(_activeSlider, kKeyKey);
            if (key) {
                ESPPrefsSetFloat(key, _activeSlider.value);
                ESPPrefsSync();
                ESPSyncFromPrefs();
            }
        }

        _trackingPointerId = -1;
        _touchOnClose = NO;
        _menuDragging = NO;
        _isContentDragging = NO;
        _isSideNavDragging = NO;
        _pendingSwitch = nil;
        _pendingSegment = nil;
        _pendingColorSwatch = nil;
        _activeSlider = nil;
        _activeSpectrumBoard = nil;
        _pendingTabIdx = -1;
        return YES;
    }

    if (insidePanel && pointerId == _trackingPointerId) return YES;
    if (_isContentDragging) return YES;
    return NO;
}

@end