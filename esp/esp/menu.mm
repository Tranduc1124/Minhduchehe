#import "menu.h"
#import "ModMenuViewController.h"
#import "icons.h"

#import "ESPPrefs.h"
#import "esp.h"
#import "AimbotMaintenance.h"

#include <sys/types.h>

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>

static const CGFloat kMenuButtonSize = 56.0f;
static const CGFloat kAccentR = 1.0f, kAccentG = 0.35f, kAccentB = 0.2f;
static const CGFloat kAuxButtonSize = 46.0f;
static const CGFloat kAuxGap = 8.0f;
static const CGFloat kQuickLogoSize = 64.0f;
static const CGFloat kQuickPanelWidth = 320.0f;
static const CGFloat kQuickPanelHeight = 190.0f;

// =======================================================
// LỚP CANVAS ẨN ĐỂ LÀM STREAMER MODE CHO ICON MENU
// =======================================================
@interface HTHIconSecureWrapper : UITextField
@end

@implementation HTHIconSecureWrapper
- (BOOL)canBecomeFirstResponder { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
@end
// =======================================================

@interface MenuView ()
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIButton *aimbotButton;
@property (nonatomic, strong) UIButton *aimPosButton;

@property (nonatomic, strong) UIButton *quickLogoButton;
@property (nonatomic, strong) UIView *quickPanel;
@property (nonatomic, strong) UIButton *quickCloseButton;
@property (nonatomic, strong) UISwitch *quickBoxSwitch;
@property (nonatomic, strong) UILabel *quickStatusLabel;
@property (nonatomic, assign) BOOL quickPanelVisible;
@property (nonatomic, assign) BOOL touchOnQuickLogo, quickLogoDragging;
@property (nonatomic, assign) BOOL touchOnQuickClose, touchOnQuickSwitch, touchOnQuickPanel;
@property (nonatomic, assign) CGPoint quickLogoDragStartCenter;
@property (nonatomic, assign) CGPoint quickLogoDragStartPoint;

@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) HTHIconSecureWrapper *secureTextField;
@property (nonatomic, strong) UIView *secureCanvas;

@property (nonatomic, assign) NSInteger trackingPointerId;

@property (nonatomic, assign) BOOL touchOnButton, buttonDragging;
@property (nonatomic, assign) BOOL touchOnAimbotButton, aimbotButtonDragging;
@property (nonatomic, assign) BOOL touchOnAimPosButton, aimPosButtonDragging;

// CÁC BIẾN LƯU TỌA ĐỘ GỐC ĐỂ KÉO SIÊU MƯỢT (ĐÃ KHÔI PHỤC)
@property (nonatomic, assign) CGPoint buttonDragStartCenter;
@property (nonatomic, assign) CGPoint buttonDragStartPoint;

@property (nonatomic, assign) CGPoint aimbotDragStartCenter;
@property (nonatomic, assign) CGPoint aimbotDragStartPoint;

@property (nonatomic, assign) CGPoint aimPosDragStartCenter;
@property (nonatomic, assign) CGPoint aimPosDragStartPoint;

@property (nonatomic, strong) ModMenuViewController *presentedModMenu;
@property (nonatomic, assign) BOOL didApplyInitialLayoutForSize;
@end

@implementation MenuView

- (void)resetTouchTrackingState {
    _touchOnButton = NO;
    _touchOnAimbotButton = NO;
    _touchOnAimPosButton = NO;
    _touchOnQuickLogo = NO;
    _touchOnQuickClose = NO;
    _touchOnQuickSwitch = NO;
    _touchOnQuickPanel = NO;
    
    _buttonDragging = NO;
    _aimbotButtonDragging = NO;
    _aimPosButtonDragging = NO;
    _quickLogoDragging = NO;
    
    _trackingPointerId = -1;
}

- (void)clampButton:(UIButton *)button size:(CGSize)size {
    if (!button || button.hidden) return;
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    if (w < size.width || h < size.height) return;

    CGRect frame = button.frame;
    frame.size = size;
    if (frame.origin.x < 0.0f) frame.origin.x = 0.0f;
    if (frame.origin.y < 0.0f) frame.origin.y = 0.0f;
    if (CGRectGetMaxX(frame) > w) frame.origin.x = w - size.width;
    if (CGRectGetMaxY(frame) > h) frame.origin.y = h - size.height;
    button.frame = frame;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    
    _secureTextField.frame = self.bounds;
    _secureCanvas.frame = self.bounds;
    
    if (!self.didApplyInitialLayoutForSize && w > 32.0f && h > 32.0f) {
        self.didApplyInitialLayoutForSize = YES;
        [self loadMenuButtonPosition];
        [self loadQuickLogoPosition];
        [self refreshAllButtonTitles];
        [self refreshQuickMenu];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshAllButtonTitles) name:@"AimPosChangedNotification" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshAllButtonTitles) name:NSUserDefaultsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshQuickMenu) name:NSUserDefaultsDidChangeNotification object:nil];
    }
    
    [self clampButton:_menuButton size:CGSizeMake(kMenuButtonSize, kMenuButtonSize)];
    [self clampButton:_aimbotButton size:CGSizeMake(kAuxButtonSize, kAuxButtonSize)];
    [self clampButton:_aimPosButton size:CGSizeMake(kAuxButtonSize, kAuxButtonSize)];
    [self clampButton:_quickLogoButton size:CGSizeMake(kQuickLogoSize, kQuickLogoSize)];
    if (_quickPanel) {
        _quickPanel.frame = CGRectMake((w - kQuickPanelWidth) * 0.5f,
                                       (h - kQuickPanelHeight) * 0.5f,
                                       kQuickPanelWidth,
                                       kQuickPanelHeight);
    }
    
    [_secureCanvas bringSubviewToFront:_menuButton];
    [_secureCanvas bringSubviewToFront:_aimbotButton];
    [_secureCanvas bringSubviewToFront:_aimPosButton];
    [self bringSubviewToFront:_quickLogoButton];
    if (_quickPanelVisible) [self bringSubviewToFront:_quickPanel];
    
    if (_presentedModMenu.view.superview == self) {
        [self bringSubviewToFront:_presentedModMenu.view];
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Full-screen overlay must never become the hit target — only real controls.
    // Returning self/secure canvas would steal game touches under CLEAR/count/ESP.
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self) return nil;
    if (hit == _menuButton || hit == _aimbotButton || hit == _aimPosButton) return nil;
    if (hit == _secureTextField || hit == _secureCanvas) return nil;
    // Mod menu root is full-screen pass-through; only its panel should hit via custom path.
    if (_presentedModMenu && (hit == _presentedModMenu.view || [hit isDescendantOfView:_presentedModMenu.view])) {
        // Let super find something inside panel; if hit is empty full view → nil.
        if (hit == _presentedModMenu.view) return nil;
    }
    return hit;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        _trackingPointerId = -1;
        
        _secureTextField = [[HTHIconSecureWrapper alloc] initWithFrame:self.bounds];
        _secureTextField.userInteractionEnabled = NO;
        _secureTextField.backgroundColor = [UIColor clearColor];
        _secureTextField.text = @"\u200B"; 
        _secureTextField.textColor = [UIColor clearColor];
        [self addSubview:_secureTextField];
        
        _secureTextField.secureTextEntry = ESPPrefsBool(@"StreamerMode", NO);
        [_secureTextField layoutIfNeeded];
        
        _secureCanvas = _secureTextField.subviews.firstObject ?: _secureTextField;
        _secureCanvas.userInteractionEnabled = NO;
        
        [self setupMenuButton];
        [self setupQuickMenu];
        
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateVisibility)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)setupMenuButton {
    _menuButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _menuButton.frame = CGRectMake(20, 100, kMenuButtonSize, kMenuButtonSize);
    // Pure circular image (no frame/border/padding around the artwork).
    _menuButton.backgroundColor = [UIColor clearColor];
    _menuButton.layer.cornerRadius = kMenuButtonSize * 0.5f;
    _menuButton.clipsToBounds = YES;
    _menuButton.layer.borderWidth = 0.0f;
    _menuButton.layer.masksToBounds = YES;
    UIImage *icon = FloatButtonIcon();
    if (!icon) {
        // Prefer bundled circular-looking assets if logo missing.
        icon = [UIImage imageNamed:@"menu.png"] ?: [UIImage imageNamed:@"icon.png"] ?: [UIImage imageNamed:@"okma.png"];
    }
    if (!icon) {
        if (@available(iOS 13.0, *)) {
            _menuButton.tintColor = [UIColor colorWithRed:kAccentR green:kAccentG blue:kAccentB alpha:1.0f];
            icon = [UIImage systemImageNamed:@"line.3.horizontal.circle.fill"];
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:kMenuButtonSize weight:UIImageSymbolWeightRegular];
            icon = [icon imageByApplyingSymbolConfiguration:cfg];
        }
    }
    if (icon) {
        // Fill the whole circle with the image (crop to round via cornerRadius/clipsToBounds).
        [_menuButton setBackgroundImage:icon forState:UIControlStateNormal];
        [_menuButton setImage:nil forState:UIControlStateNormal];
        _menuButton.imageEdgeInsets = UIEdgeInsetsZero;
        _menuButton.contentEdgeInsets = UIEdgeInsetsZero;
        _menuButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
        _menuButton.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
        // Ensure background image scales to button bounds.
        _menuButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
        for (UIView *v in _menuButton.subviews) {
            if ([v isKindOfClass:[UIImageView class]]) {
                v.contentMode = UIViewContentModeScaleAspectFill;
                v.clipsToBounds = YES;
            }
        }
    } else {
        [_menuButton setTitle:@"M" forState:UIControlStateNormal];
        [_menuButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _menuButton.titleLabel.font = [UIFont boldSystemFontOfSize:20.0f];
        _menuButton.backgroundColor = [UIColor colorWithRed:0.10f green:0.12f blue:0.14f alpha:0.85f];
    }
    [_secureCanvas addSubview:_menuButton];

    _aimbotButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _aimbotButton.frame = CGRectMake(CGRectGetMaxX(_menuButton.frame) + kAuxGap, _menuButton.frame.origin.y, kAuxButtonSize, kAuxButtonSize);
    _aimbotButton.backgroundColor = [UIColor colorWithRed:0.17f green:0.21f blue:0.22f alpha:0.40f];
    _aimbotButton.layer.cornerRadius = kAuxButtonSize / 2.0f;
    _aimbotButton.titleLabel.font = [UIFont boldSystemFontOfSize:14.0f]; 
    [_aimbotButton setTitle:@"AIM" forState:UIControlStateNormal];
    [_secureCanvas addSubview:_aimbotButton];
    
    _aimPosButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _aimPosButton.frame = CGRectMake(CGRectGetMaxX(_aimbotButton.frame) + kAuxGap, _aimbotButton.frame.origin.y, kAuxButtonSize, kAuxButtonSize);
    _aimPosButton.backgroundColor = [UIColor colorWithRed:0.17f green:0.21f blue:0.22f alpha:0.40f];
    _aimPosButton.layer.cornerRadius = kAuxButtonSize / 2.0f;
    _aimPosButton.titleLabel.font = [UIFont boldSystemFontOfSize:11.0f];
    [_aimPosButton setTitle:@"HEAD" forState:UIControlStateNormal];
    [_secureCanvas addSubview:_aimPosButton];

    [self loadMenuButtonPosition];
    [self refreshAllButtonTitles];
}

// -------------------------------------------------------------
// Quick MINDO menu: logo toggles a small ESP Box panel.
// The HUD delivers touches manually through handleTouchAtWindowPoint,
// so the panel is visual-only (userInteractionEnabled = NO) and the
// hit zones are checked by frame in that handler.
// -------------------------------------------------------------
- (void)setupQuickMenu {
    _quickLogoButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _quickLogoButton.frame = CGRectMake(20, 100, kQuickLogoSize, kQuickLogoSize);
    _quickLogoButton.backgroundColor = [UIColor blackColor];
    _quickLogoButton.layer.cornerRadius = kQuickLogoSize * 0.5f;
    _quickLogoButton.clipsToBounds = YES;
    _quickLogoButton.layer.borderWidth = 1.0f;
    _quickLogoButton.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.18f].CGColor;
    _quickLogoButton.userInteractionEnabled = NO;

    [_quickLogoButton setTitle:@"MINDO" forState:UIControlStateNormal];
    [_quickLogoButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _quickLogoButton.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    _quickLogoButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    _quickLogoButton.titleLabel.minimumScaleFactor = 0.6f;
    [self addSubview:_quickLogoButton];

    _quickPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kQuickPanelWidth, kQuickPanelHeight)];
    _quickPanel.backgroundColor = [UIColor colorWithRed:0.11f green:0.11f blue:0.12f alpha:0.97f];
    _quickPanel.layer.cornerRadius = 18.0f;
    _quickPanel.clipsToBounds = YES;
    _quickPanel.userInteractionEnabled = NO;
    _quickPanel.hidden = YES;
    [self addSubview:_quickPanel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20.0f, 16.0f, 200.0f, 34.0f)];
    title.text = @"MINDO";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:26.0f];
    [_quickPanel addSubview:title];

    _quickCloseButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _quickCloseButton.frame = CGRectMake(kQuickPanelWidth - 44.0f, 12.0f, 32.0f, 32.0f);
    [_quickCloseButton setTitle:@"\u2715" forState:UIControlStateNormal];
    [_quickCloseButton setTitleColor:[UIColor colorWithWhite:0.85f alpha:1.0f] forState:UIControlStateNormal];
    _quickCloseButton.titleLabel.font = [UIFont systemFontOfSize:20.0f weight:UIFontWeightMedium];
    _quickCloseButton.userInteractionEnabled = NO;
    [_quickPanel addSubview:_quickCloseButton];

    UILabel *boxLabel = [[UILabel alloc] initWithFrame:CGRectMake(20.0f, 76.0f, 180.0f, 28.0f)];
    boxLabel.text = @"ESP Box";
    boxLabel.textColor = [UIColor whiteColor];
    boxLabel.font = [UIFont systemFontOfSize:18.0f weight:UIFontWeightSemibold];
    [_quickPanel addSubview:boxLabel];

    _quickBoxSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(kQuickPanelWidth - 20.0f - 51.0f, 70.0f, 51.0f, 31.0f)];
    _quickBoxSwitch.onTintColor = [UIColor colorWithRed:0.20f green:0.85f blue:0.40f alpha:1.0f];
    _quickBoxSwitch.userInteractionEnabled = NO;
    [_quickPanel addSubview:_quickBoxSwitch];

    _quickStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20.0f, 118.0f, kQuickPanelWidth - 40.0f, 52.0f)];
    _quickStatusLabel.textColor = [UIColor colorWithWhite:0.62f alpha:1.0f];
    _quickStatusLabel.font = [UIFont systemFontOfSize:13.0f weight:UIFontWeightRegular];
    _quickStatusLabel.numberOfLines = 2;
    [_quickPanel addSubview:_quickStatusLabel];

    _quickPanelVisible = NO;
    [self refreshQuickMenu];
}

- (void)loadQuickLogoPosition {
    CGFloat x = ESPPrefsFloat(@"FloatingQuickBtnX", 0.0f);
    CGFloat y = ESPPrefsFloat(@"FloatingQuickBtnY", 0.0f);
    if (x > 0.0f || y > 0.0f) {
        _quickLogoButton.frame = CGRectMake(x, y, kQuickLogoSize, kQuickLogoSize);
    } else {
        CGFloat h = CGRectGetHeight(self.bounds);
        _quickLogoButton.frame = CGRectMake(20.0f, MAX(20.0f, h - kQuickLogoSize - 20.0f),
                                            kQuickLogoSize, kQuickLogoSize);
    }
}

- (void)refreshQuickMenu {
    if (!_quickBoxSwitch || !_quickStatusLabel) return;
    BOOL boxOn = ESPPrefsBool(@"Box", YES);
    [_quickBoxSwitch setOn:boxOn animated:NO];

    BOOL connected = (get_pid_by_name("FreeFire") > 0);
    NSString *state = boxOn ? @"bật" : @"tắt";
    if (!connected) {
        _quickStatusLabel.text = [NSString stringWithFormat:@"ESP Box đang %@ - chưa kết nối game", state];
    } else {
        _quickStatusLabel.text = [NSString stringWithFormat:@"ESP Box đang %@.", state];
    }
}

- (void)toggleQuickPanel {
    _quickPanelVisible = !_quickPanelVisible;
    _quickPanel.hidden = !_quickPanelVisible;
    if (_quickPanelVisible) {
        [self bringSubviewToFront:_quickPanel];
        [self refreshQuickMenu];
    }
}

- (void)hideQuickPanel {
    _quickPanelVisible = NO;
    _quickPanel.hidden = YES;
}

- (void)toggleQuickBox {
    BOOL on = !ESPPrefsBool(@"Box", YES);
    ESPPrefsSetBool(@"Box", on);
    if (on) {
        int menuStyle = (int)ESPPrefsFloat(@"MenuLayoutStyle", 0.0f);
        ESPPrefsSetBool((menuStyle == 1) ? @"EnableESP2" : @"EnableESP", YES);
    }
    ESPPrefsSync();
    ESPSyncFromPrefs();
    [self refreshQuickMenu];
    [self refreshAllButtonTitles];
}

- (void)updateVisibility {
    BOOL isStreamer = ESPPrefsBool(@"StreamerMode", NO);
    if (_secureTextField.secureTextEntry != isStreamer) {
        [_menuButton removeFromSuperview];
        [_aimbotButton removeFromSuperview];
        [_aimPosButton removeFromSuperview];
        [_quickLogoButton removeFromSuperview];
        [_quickPanel removeFromSuperview];
        
        _secureTextField.secureTextEntry = isStreamer;
        [_secureTextField setNeedsLayout];
        [_secureTextField layoutIfNeeded];
        
        _secureCanvas = _secureTextField.subviews.firstObject ?: _secureTextField;
        _secureCanvas.userInteractionEnabled = NO;
        
        [_secureCanvas addSubview:_menuButton];
        [_secureCanvas addSubview:_aimbotButton];
        [_secureCanvas addSubview:_aimPosButton];
        [self addSubview:_quickLogoButton];
        [self addSubview:_quickPanel];
    }
    [self refreshButtonVisibility];
}

- (void)reloadFloatingAuxButtonsFromPrefs {
    [self refreshAllButtonTitles];
}

- (void)loadMenuButtonPosition {
    CGFloat x = ESPPrefsFloat(@"FloatingMenuBtnX", 0.0f);
    CGFloat y = ESPPrefsFloat(@"FloatingMenuBtnY", 0.0f);
    if (x > 0 || y > 0) _menuButton.frame = CGRectMake(x, y, kMenuButtonSize, kMenuButtonSize);

    CGFloat ax = ESPPrefsFloat(@"FloatingAimBtnX", 0.0f);
    CGFloat ay = ESPPrefsFloat(@"FloatingAimBtnY", 0.0f);
    if (ax > 0 || ay > 0) {
        _aimbotButton.frame = CGRectMake(ax, ay, kAuxButtonSize, kAuxButtonSize);
    } else {
        _aimbotButton.frame = CGRectMake(CGRectGetMaxX(_menuButton.frame) + kAuxGap, _menuButton.frame.origin.y, kAuxButtonSize, kAuxButtonSize);
    }

    CGFloat px = ESPPrefsFloat(@"FloatingAimPosBtnX", 0.0f);
    CGFloat py = ESPPrefsFloat(@"FloatingAimPosBtnY", 0.0f);
    if (px > 0 || py > 0) {
        _aimPosButton.frame = CGRectMake(px, py, kAuxButtonSize, kAuxButtonSize);
    } else {
        _aimPosButton.frame = CGRectMake(CGRectGetMaxX(_aimbotButton.frame) + kAuxGap, _aimbotButton.frame.origin.y, kAuxButtonSize, kAuxButtonSize);
    }
}

- (void)refreshButtonVisibility {
    // No more "hide icon" feature — always show menu icon (unless global HideMenu1 / menu open).
    // One-time force-show for users stuck after older hide builds.
    if (!ESPPrefsBool(@"MenuIconForceShow_v3", NO)) {
        ESPPrefsSetBool(@"ShowMenuIcon", YES); // legacy key, keep true for old prefs
        ESPPrefsSetBool(@"LockMenuIcon", NO);
        _menuButton.frame = CGRectMake(20, 100, kMenuButtonSize, kMenuButtonSize);
        ESPPrefsSetFloat(@"FloatingMenuBtnX", 20.0f);
        ESPPrefsSetFloat(@"FloatingMenuBtnY", 100.0f);
        ESPPrefsSetBool(@"MenuIconForceShow_v3", YES);
        ESPPrefsSync();
    }

    if (_presentedModMenu) {
        _menuButton.hidden = YES;
        _aimbotButton.hidden = YES;
        _aimPosButton.hidden = YES;
        _quickLogoButton.hidden = YES;
        [self hideQuickPanel];
        return;
    }

    if (ESPPrefsBool(@"StreamerMode", NO)) {
        _quickLogoButton.hidden = YES;
        [self hideQuickPanel];
        return;
    }

    BOOL hideMenu = ESPPrefsBool(@"HideMenu1", NO);
    int menuStyle = (int)ESPPrefsFloat(@"MenuLayoutStyle", 0.0f); // 0 Pro, 1 Lite

    if (hideMenu) {
        _menuButton.hidden = YES;
        _aimbotButton.hidden = YES;
        _aimPosButton.hidden = YES;
        _quickLogoButton.hidden = YES;
        [self hideQuickPanel];
        return;
    }

    // Always visible + tappable.
    _menuButton.hidden = NO;
    _menuButton.alpha = 1.0f;
    _menuButton.userInteractionEnabled = YES;
    if (_menuButton.frame.size.width < 8.0f || _menuButton.frame.size.height < 8.0f) {
        _menuButton.frame = CGRectMake(20, 100, kMenuButtonSize, kMenuButtonSize);
    }
    [self clampButton:_menuButton size:CGSizeMake(kMenuButtonSize, kMenuButtonSize)];

    if (menuStyle == 1) {
        _aimbotButton.hidden = YES;
        _aimPosButton.hidden = YES;
    } else {
        BOOL showAim = ESPPrefsBool(@"FloatAimBtn", YES);
        BOOL showAimPos = ESPPrefsBool(@"FloatAimPosBtn", YES);
        _aimbotButton.hidden = !showAim;
        _aimPosButton.hidden = !showAimPos;
    }

    if (_secureCanvas) {
        [_secureCanvas bringSubviewToFront:_menuButton];
        [_secureCanvas bringSubviewToFront:_aimbotButton];
        [_secureCanvas bringSubviewToFront:_aimPosButton];
    }

    _quickLogoButton.hidden = NO;
    _quickLogoButton.alpha = 1.0f;
    [self clampButton:_quickLogoButton size:CGSizeMake(kQuickLogoSize, kQuickLogoSize)];
    if (_secureCanvas && _quickLogoButton) {
        [self bringSubviewToFront:_quickLogoButton];
        if (_quickPanelVisible && _quickPanel) [self bringSubviewToFront:_quickPanel];
    }
}

- (void)refreshAllButtonTitles {
    BOOL aimOn = ESPPrefsBool(@"Aimbot", NO);
    [_aimbotButton setTitleColor:(aimOn ? [UIColor greenColor] : [UIColor redColor]) forState:UIControlStateNormal];
    
    int aimPos = (int)ESPPrefsFloat(@"AimPos", 0.0f);
    if (aimPos == 0) {
        [_aimPosButton setTitle:@"HEAD" forState:UIControlStateNormal];
        [_aimPosButton setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    } else if (aimPos == 1) {
        [_aimPosButton setTitle:@"NECK" forState:UIControlStateNormal];
        [_aimPosButton setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
    } else {
        [_aimPosButton setTitle:@"BODY" forState:UIControlStateNormal];
        [_aimPosButton setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
    }
    [self refreshButtonVisibility];
}

- (UIViewController *)viewControllerForView:(UIView *)view {
    UIResponder *r = view;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = [r nextResponder];
    return [r isKindOfClass:[UIViewController class]] ? (UIViewController *)r : nil;
}

- (void)presentModMenu {
    UIViewController *parentVC = [self viewControllerForView:self];
    if (!parentVC) parentVC = self.window.rootViewController;
    if (!parentVC) return;
    ModMenuViewController *vc = [[ModMenuViewController alloc] init];
    vc.view.frame = self.bounds;
    __weak MenuView *wself = self;
    vc.onCloseBlock = ^{
        [wself dismissModMenu];
    };
    vc.onExitHUDRequested = ^{
        if (wself.onExitHUDRequested) wself.onExitHUDRequested();
    };
    _presentedModMenu = vc;
    [parentVC addChildViewController:vc];
    [self addSubview:vc.view];
    [vc didMoveToParentViewController:parentVC];
    [self bringSubviewToFront:vc.view];
    
    _menuButton.hidden = YES;
    _aimbotButton.hidden = YES;
    _aimPosButton.hidden = YES;
    _quickLogoButton.hidden = YES;
    [self hideQuickPanel];
}

- (void)dismissModMenu {
    if (!_presentedModMenu) return;
    ModMenuViewController *vc = _presentedModMenu;
    _presentedModMenu = nil;
    [vc willMoveToParentViewController:nil];
    [vc.view removeFromSuperview];
    [vc removeFromParentViewController];

    [self reloadFloatingAuxButtonsFromPrefs];
    [self refreshButtonVisibility];
    [_secureCanvas bringSubviewToFront:_menuButton];
    [_secureCanvas bringSubviewToFront:_aimbotButton];
    [_secureCanvas bringSubviewToFront:_aimPosButton];
}

- (void)showMenu {
    if (_presentedModMenu) return;
    [self presentModMenu];
}

- (void)hideMenu {
    if (_presentedModMenu) {
        [self dismissModMenu];
    }
}

// -------------------------------------------------------------
// THUẬT TOÁN KÉO ABSOLUTE DELTA - MƯỢT NHƯ MÀN 120HZ
// -------------------------------------------------------------

// Called with ALL finger ids present in one HID/AX event (chord).
// This is the reliable 3-finger detector: single-path tracking often never reaches 3.

- (BOOL)handleTouchAtWindowPoint:(CGPoint)windowPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId {
    CGPoint local = self.window ? [self convertPoint:windowPoint fromView:self.window] : windowPoint;
    const CGFloat kInset = 16.0f;
    
    // Đã tăng lại độ nhạy Threshold lên 10 để tránh lỗi bấm lầm thành kéo
    const CGFloat kDragThreshold = 10.0f;


    BOOL menuGloballyOff = ESPPrefsBool(@"HideMenu1", NO) || (_presentedModMenu != nil);
    CGRect btnHit = CGRectInset(_menuButton.frame, -kInset, -kInset);
    BOOL insideBtn = !menuGloballyOff && !_menuButton.hidden && CGRectContainsPoint(btnHit, local);
    BOOL insideAim = !_aimbotButton.hidden && CGRectContainsPoint(CGRectInset(_aimbotButton.frame, -kInset, -kInset), local);
    BOOL insideAimPos = !_aimPosButton.hidden && CGRectContainsPoint(CGRectInset(_aimPosButton.frame, -kInset, -kInset), local);

    BOOL quickVisible = _quickPanelVisible && !_quickPanel.hidden && !menuGloballyOff;
    BOOL insideQuickLogo = !menuGloballyOff && !_quickLogoButton.hidden &&
        CGRectContainsPoint(CGRectInset(_quickLogoButton.frame, -kInset, -kInset), local);
    BOOL insideQuickPanel = quickVisible && CGRectContainsPoint(_quickPanel.frame, local);
    CGRect quickCloseRect = _quickCloseButton ? [_quickPanel convertRect:_quickCloseButton.frame toView:self] : CGRectZero;
    CGRect quickSwitchRect = _quickBoxSwitch ? [_quickPanel convertRect:_quickBoxSwitch.frame toView:self] : CGRectZero;
    BOOL insideQuickClose = quickVisible && CGRectContainsPoint(CGRectInset(quickCloseRect, -8.0f, -8.0f), local);
    BOOL insideQuickSwitch = quickVisible && CGRectContainsPoint(CGRectInset(quickSwitchRect, -12.0f, -12.0f), local);

    if (_presentedModMenu) {
        CGPoint inMenuView = [self convertPoint:local toView:_presentedModMenu.view];
        // Only consume when the floating panel (or a control on it) handles the touch.
        // Previously: any outside tap returned YES → stole ALL game input while menu open
        // (CLEAR / count sit under the top of the screen and felt "blocked by the text").
        if ([_presentedModMenu handleTouchAtViewPoint:inMenuView phase:(NSInteger)phase pointerId:pointerId])
            return YES;

        // Outside panel: do not eat the event — let Free Fire receive the HID touch.
        // Optional soft-dismiss on empty tap without consuming.
        if (phase == UITouchPhaseBegan && !insideBtn && !insideAim && !insideAimPos) {
            // Keep menu open on game touches; user closes via X. (No steal.)
        }
        return NO;
    }

    switch (phase) {
        case UITouchPhaseBegan: {
            if (_trackingPointerId != -1 && pointerId != _trackingPointerId) {
                [self resetTouchTrackingState];
            }
            if (insideBtn && !_touchOnButton) {
                _touchOnButton = YES; _buttonDragging = NO; _trackingPointerId = pointerId;
                _buttonDragStartCenter = _menuButton.center; // Lưu tọa độ gốc
                _buttonDragStartPoint = local;
                return YES;
            }
            if (insideAim && !_touchOnAimbotButton) {
                _touchOnAimbotButton = YES; _aimbotButtonDragging = NO; _trackingPointerId = pointerId;
                _aimbotDragStartCenter = _aimbotButton.center; // Lưu tọa độ gốc
                _aimbotDragStartPoint = local;
                return YES;
            }
            if (insideAimPos && !_touchOnAimPosButton) {
                _touchOnAimPosButton = YES; _aimPosButtonDragging = NO; _trackingPointerId = pointerId;
                _aimPosDragStartCenter = _aimPosButton.center; // Lưu tọa độ gốc
                _aimPosDragStartPoint = local;
                return YES;
            }
            if (insideQuickLogo && !_touchOnQuickLogo) {
                _touchOnQuickLogo = YES; _quickLogoDragging = NO; _trackingPointerId = pointerId;
                _quickLogoDragStartCenter = _quickLogoButton.center;
                _quickLogoDragStartPoint = local;
                return YES;
            }
            if (insideQuickClose) {
                _touchOnQuickClose = YES; _trackingPointerId = pointerId;
                return YES;
            }
            if (insideQuickSwitch) {
                _touchOnQuickSwitch = YES; _trackingPointerId = pointerId;
                return YES;
            }
            if (insideQuickPanel) {
                _touchOnQuickPanel = YES;
                _trackingPointerId = pointerId;
                return YES;
            }
            return NO;
        }
        case UITouchPhaseMoved: {
            [CATransaction begin];
            [CATransaction setDisableActions:YES]; // TẮT HOẠT ẢNH NGẦM CỦA APPLE
            
            if (_touchOnButton && pointerId == _trackingPointerId) {
                BOOL lockIcon = ESPPrefsBool(@"LockMenuIcon", NO);
                CGFloat dx = local.x - _buttonDragStartPoint.x;
                CGFloat dy = local.y - _buttonDragStartPoint.y;
                if (!lockIcon) {
                    if (!_buttonDragging && ((fabs(dx) + fabs(dy)) > kDragThreshold)) _buttonDragging = YES;
                    if (_buttonDragging) {
                        _menuButton.center = CGPointMake(_buttonDragStartCenter.x + dx, _buttonDragStartCenter.y + dy);
                        [self clampButton:_menuButton size:CGSizeMake(kMenuButtonSize, kMenuButtonSize)];
                    }
                }
                [CATransaction commit];
                return YES;
            }
            if (_touchOnAimbotButton && pointerId == _trackingPointerId) {
                CGFloat dx = local.x - _aimbotDragStartPoint.x;
                CGFloat dy = local.y - _aimbotDragStartPoint.y;
                if (!_aimbotButtonDragging && (fabs(dx) + fabs(dy) > kDragThreshold)) _aimbotButtonDragging = YES;
                if (_aimbotButtonDragging) {
                    _aimbotButton.center = CGPointMake(_aimbotDragStartCenter.x + dx, _aimbotDragStartCenter.y + dy);
                    [self clampButton:_aimbotButton size:CGSizeMake(kAuxButtonSize, kAuxButtonSize)];
                }
                [CATransaction commit];
                return YES;
            }
            if (_touchOnAimPosButton && pointerId == _trackingPointerId) {
                CGFloat dx = local.x - _aimPosDragStartPoint.x;
                CGFloat dy = local.y - _aimPosDragStartPoint.y;
                if (!_aimPosButtonDragging && (fabs(dx) + fabs(dy) > kDragThreshold)) _aimPosButtonDragging = YES;
                if (_aimPosButtonDragging) {
                    _aimPosButton.center = CGPointMake(_aimPosDragStartCenter.x + dx, _aimPosDragStartCenter.y + dy);
                    [self clampButton:_aimPosButton size:CGSizeMake(kAuxButtonSize, kAuxButtonSize)];
                }
                [CATransaction commit];
                return YES;
            }
            if (_touchOnQuickLogo && pointerId == _trackingPointerId) {
                CGFloat dx = local.x - _quickLogoDragStartPoint.x;
                CGFloat dy = local.y - _quickLogoDragStartPoint.y;
                if (!_quickLogoDragging && (fabs(dx) + fabs(dy) > kDragThreshold)) _quickLogoDragging = YES;
                if (_quickLogoDragging) {
                    _quickLogoButton.center = CGPointMake(_quickLogoDragStartCenter.x + dx, _quickLogoDragStartCenter.y + dy);
                    [self clampButton:_quickLogoButton size:CGSizeMake(kQuickLogoSize, kQuickLogoSize)];
                }
                [CATransaction commit];
                return YES;
            }
            [CATransaction commit];
            return _touchOnButton || _touchOnAimbotButton || _touchOnAimPosButton || _touchOnQuickLogo || _touchOnQuickClose || _touchOnQuickSwitch || _touchOnQuickPanel;
        }
        case UITouchPhaseEnded:
        case UITouchPhaseCancelled: {
            if (_trackingPointerId == -1) return NO;
            if (pointerId != _trackingPointerId) {
                if (phase == UITouchPhaseCancelled) [self resetTouchTrackingState];
                return _touchOnButton || _touchOnAimbotButton || _touchOnAimPosButton || _touchOnQuickLogo || _touchOnQuickClose || _touchOnQuickSwitch || _touchOnQuickPanel;
            }

            if (_touchOnQuickPanel) {
                [self resetTouchTrackingState];
                return YES;
            }

            if (_touchOnQuickLogo) {
                BOOL wasDrag = _quickLogoDragging;
                [self resetTouchTrackingState];
                if (wasDrag) {
                    ESPPrefsSetFloat(@"FloatingQuickBtnX", _quickLogoButton.frame.origin.x);
                    ESPPrefsSetFloat(@"FloatingQuickBtnY", _quickLogoButton.frame.origin.y);
                    ESPPrefsSync();
                } else {
                    [self toggleQuickPanel];
                }
                return YES;
            }

            if (_touchOnQuickClose) {
                [self resetTouchTrackingState];
                [self hideQuickPanel];
                return YES;
            }

            if (_touchOnQuickSwitch) {
                [self resetTouchTrackingState];
                [self toggleQuickBox];
                return YES;
            }

            if (_touchOnAimbotButton) {
                BOOL wasDrag = _aimbotButtonDragging;
                [self resetTouchTrackingState];
                if (wasDrag) {
                    ESPPrefsSetFloat(@"FloatingAimBtnX", _aimbotButton.frame.origin.x);
                    ESPPrefsSetFloat(@"FloatingAimBtnY", _aimbotButton.frame.origin.y);
                    ESPPrefsSync();
                } else {
                    BOOL on = ESPPrefsBool(@"Aimbot", NO);
                    if (!on) {
                        // Aimbot is disabled in this build. Show the notice and
                        // leave the button off instead of flipping the pref on.
                        AimbotShowMaintenanceAlert();
                        [self refreshAllButtonTitles];
                        ESPSyncFromPrefs();
                    } else {
                        ESPPrefsSetBool(@"Aimbot", NO);
                        [self refreshAllButtonTitles];
                        ESPSyncFromPrefs();
                    }
                }
                return YES;
            }

            if (_touchOnAimPosButton) {
                BOOL wasDrag = _aimPosButtonDragging;
                [self resetTouchTrackingState];
                if (wasDrag) {
                    ESPPrefsSetFloat(@"FloatingAimPosBtnX", _aimPosButton.frame.origin.x);
                    ESPPrefsSetFloat(@"FloatingAimPosBtnY", _aimPosButton.frame.origin.y);
                    ESPPrefsSync();
                } else {
                    int aimPos = (int)ESPPrefsFloat(@"AimPos", 0.0f);
                    int menuStyle = (int)ESPPrefsFloat(@"MenuLayoutStyle", 0.0f);
                    int maxPos = (menuStyle == 0) ? 3 : 2;
                    aimPos = (aimPos + 1) % maxPos;
                    ESPPrefsSetFloat(@"AimPos", (float)aimPos);

                    [[NSNotificationCenter defaultCenter] postNotificationName:@"AimPosChangedNotification" object:nil];
                    [self refreshAllButtonTitles];
                    ESPSyncFromPrefs();
                }
                return YES;
            }

            if (_touchOnButton) {
                BOOL wasDrag = _buttonDragging;
                [self resetTouchTrackingState];
                if (!wasDrag) [self togglePanel];

                if (wasDrag) {
                    ESPPrefsSetFloat(@"FloatingMenuBtnX", (float)_menuButton.frame.origin.x);
                    ESPPrefsSetFloat(@"FloatingMenuBtnY", (float)_menuButton.frame.origin.y);
                    ESPPrefsSync();
                }
                return YES;
            }
            [self resetTouchTrackingState];
            return NO;
        }
        default: return NO;
    }
}

- (BOOL)handleTouchAtLocalPoint:(CGPoint)localPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId {
    if (self.window) {
        return [self handleTouchAtWindowPoint:[self convertPoint:localPoint toView:self.window] phase:phase pointerId:pointerId];
    }
    return [self handleTouchAtWindowPoint:localPoint phase:phase pointerId:pointerId];
}

- (void)togglePanel {
    if (_presentedModMenu) {
        [self dismissModMenu];
    } else {
        [self presentModMenu];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end