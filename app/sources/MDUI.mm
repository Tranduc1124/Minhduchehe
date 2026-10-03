#import "MDUI.h"
#import "MDTheme.h"

UIImage *MDUISymbol(NSString *symbolName, CGFloat pointSize, UIFontWeight weight) {
    if (symbolName.length == 0 || pointSize <= 0) return nil;
    if (@available(iOS 13.0, *)) {
        // UIFontWeight and UIImageSymbolWeight are both doubles but are
        // distinct typedefs, so the cast is needed, not optional.
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                           weight:(UIImageSymbolWeight)weight];
        UIImage *img = [UIImage systemImageNamed:symbolName withConfiguration:cfg];
        return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

UIImage *MDUIImageNamed(NSString *baseName) {
    if (baseName.length == 0) return nil;
    UIImage *img = [UIImage imageNamed:baseName];
    if (img) return img;
    for (NSString *ext in @[ @"webp", @"png" ]) {
        NSString *path = [[NSBundle mainBundle] pathForResource:baseName ofType:ext];
        if (path.length) {
            img = [UIImage imageWithContentsOfFile:path];
            if (img) return img;
        }
    }
    return nil;
}

UIFont *MDUIMonoFont(CGFloat size, UIFontWeight weight) {
    return [UIFont monospacedSystemFontOfSize:size weight:weight];
}

void MDUIApplyNavigationBarStyle(UINavigationBar *navBar) {
    if (!navBar) return;
    navBar.translucent = NO;
    navBar.barTintColor = MDThemePanel();
    navBar.tintColor = MDThemeAccent();
    navBar.prefersLargeTitles = NO;

    Class appearanceCls = NSClassFromString(@"UINavigationBarAppearance");
    if (appearanceCls) {
        id app = [[appearanceCls alloc] init];
        if ([app respondsToSelector:@selector(configureWithOpaqueBackground)]) {
            [app configureWithOpaqueBackground];
        }
        if ([app respondsToSelector:@selector(setBackgroundColor:)]) {
            [app setBackgroundColor:MDThemePanel()];
        }
        if ([app respondsToSelector:@selector(setShadowColor:)]) {
            [app setShadowColor:MDThemeLine()];
        }
        @try {
            id normal = [[app valueForKey:@"standardLayoutAppearance"] valueForKey:@"normal"];
            [normal setValue:MDThemeText() forKey:@"titleTextAttributes"];
        } @catch (__unused NSException *e) {}
        if ([navBar respondsToSelector:@selector(setStandardAppearance:)]) {
            [navBar setValue:app forKey:@"standardAppearance"];
        }
        if ([navBar respondsToSelector:NSSelectorFromString(@"setScrollEdgeAppearance:")]) {
            @try { [navBar setValue:app forKey:@"scrollEdgeAppearance"]; } @catch (__unused NSException *e) {}
        }
        if ([navBar respondsToSelector:NSSelectorFromString(@"setCompactAppearance:")]) {
            @try { [navBar setValue:app forKey:@"compactAppearance"]; } @catch (__unused NSException *e) {}
        }
    }
}

#pragma mark - MDIconRowCell

static const CGFloat kTileSize = 30.0f;
static const CGFloat kTilePad = 16.0f;
static const CGFloat kTileGap = 12.0f;
static const CGFloat kChevronW = 8.0f;
static const CGFloat kChevronGap = 10.0f;
static const CGFloat kMinRowHeight = 54.0f;

@implementation MDIconRowCell {
    UIStackView *_textStack;
    UIView *_spacer;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)ident {
    self = [super initWithStyle:style reuseIdentifier:ident];
    if (!self) return nil;

    self.backgroundColor = MDThemePanel();
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _iconTile = [[UIView alloc] initWithFrame:CGRectZero];
    _iconTile.userInteractionEnabled = NO;
    _iconTile.layer.cornerRadius = 8.0f;
    _iconTile.clipsToBounds = YES;
    _iconTile.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_iconTile];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.userInteractionEnabled = NO;
    // Without this the view keeps a zero frame and its Auto Layout constraints
    // are inert, which shows up as a blank coloured tile with no glyph on it.
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [_iconTile addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = MDThemeFont(17.0f, UIFontWeightSemibold);
    _titleLabel.textColor = MDThemeText();
    _titleLabel.numberOfLines = 1;

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = MDThemeFont(13.0f, UIFontWeightRegular);
    _subtitleLabel.textColor = MDThemeMuted();
    // Wrapping is the whole point of the subtitle. Two lines was enough for the
    // English strings and not for the Vietnamese ones, which is where the
    // truncation came from.
    _subtitleLabel.numberOfLines = 3;

    _textStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _subtitleLabel ]];
    _textStack.axis = UILayoutConstraintAxisVertical;
    _textStack.spacing = 2.0f;
    _textStack.alignment = UIStackViewAlignmentFill;
    _textStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_textStack];

    // A value label sits on the right, before the chevron. The spacer is what
    // keeps the value from being pushed off-screen when the title runs long,
    // because the stack is fill-aligned and the chevron has a fixed width.
    _spacer = [[UIView alloc] initWithFrame:CGRectZero];
    _spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [_textStack addArrangedSubview:_spacer];
    [_spacer setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                      forAxis:UILayoutConstraintAxisHorizontal];
    [_spacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                           forAxis:UILayoutConstraintAxisHorizontal];

    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.font = MDThemeFont(15.0f, UIFontWeightRegular);
    _valueLabel.textColor = MDThemeMuted();
    _valueLabel.textAlignment = NSTextAlignmentRight;
    _valueLabel.numberOfLines = 1;
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_valueLabel];

    _chevronView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _chevronView.image = MDUISymbol(@"chevron.right", 13.0f, UIFontWeightSemibold);
    // The chevron wants a grey lighter than the label colour.
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [MDThemeMuted() getRed:&r green:&g blue:&b alpha:&a];
    _chevronView.tintColor = [UIColor colorWithRed:r * 0.62f green:g * 0.62f blue:b * 0.62f alpha:a];
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;
    _chevronView.userInteractionEnabled = NO;
    _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_chevronView];

    [self buildConstraints];
    return self;
}

- (void)buildConstraints {
    UILayoutGuide *guide = self.contentView.layoutMarginsGuide;

    // Margins: 16 on the leading and trailing edge, 10 vertical. The tile
    // hangs off the left margin and the text starts after its gap.
    self.contentView.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(10.0f, kTilePad, 10.0f, kTilePad);

    [NSLayoutConstraint activateConstraints:@[
        [_iconTile.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [_iconTile.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconTile.widthAnchor constraintEqualToConstant:kTileSize],
        [_iconTile.heightAnchor constraintEqualToConstant:kTileSize],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconTile.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconTile.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:kTileSize - 14.0f],
        [_iconView.heightAnchor constraintEqualToConstant:kTileSize - 14.0f],

        [_textStack.leadingAnchor constraintEqualToAnchor:_iconTile.trailingAnchor constant:kTileGap],
        [_textStack.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [_textStack.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],

        [_chevronView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [_chevronView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_chevronView.widthAnchor constraintEqualToConstant:kChevronW],
        [_chevronView.heightAnchor constraintGreaterThanOrEqualToConstant:12.0f],

        // valueLabel sits left of the chevron, textStack left of valueLabel.
        [_valueLabel.trailingAnchor constraintEqualToAnchor:_chevronView.leadingAnchor
                                                  constant:-kChevronGap],
        [_valueLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_valueLabel.leadingAnchor
                                                            constant:-8.0f],

        // A single-line row still has to clear the native row height.
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:kMinRowHeight],
    ]];
}

- (void)applyIconNamed:(NSString *)symbolName color:(UIColor *)color {
    _iconTile.backgroundColor = color ?: MDThemePanel2();
    _iconView.image = symbolName.length ? MDUISymbol(symbolName, 15.0f, UIFontWeightSemibold) : nil;
    _iconView.tintColor = [UIColor whiteColor];
}

- (void)applyTitle:(NSString *)title
          subtitle:(NSString *)subtitle
             value:(NSString *)value
       showsChevron:(BOOL)chevron
           tappable:(BOOL)tappable {
    _titleLabel.text = title;
    _titleLabel.textColor = MDThemeText();
    _subtitleLabel.text = subtitle;
    // Hiding rather than blanking, so the stack drops the row entirely and the
    // cell shrinks to one line.
    _subtitleLabel.hidden = (subtitle.length == 0);
    _valueLabel.text = value;
    _valueLabel.hidden = (value.length == 0);
    _chevronView.hidden = !chevron;
    _spacer.hidden = !chevron;
    self.selectionStyle = tappable ? UITableViewCellSelectionStyleDefault
                                   : UITableViewCellSelectionStyleNone;
    self.userInteractionEnabled = tappable;
    [self setNeedsLayout];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    [self setPressHighlighted:highlighted animated:animated];
}

// Dimming the whole contentView took the icon tile down with it, so the accent
// square went grey on touch and the press looked like a rendering fault rather
// than a response. A wash behind the card keeps every glyph at full opacity and
// reads as the row lighting up instead of breaking.
- (void)setPressHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    void (^apply)(void) = ^{
        self.contentView.backgroundColor = highlighted ? MDThemeAccentSoft(0.10f)
                                                       : MDThemePanel();
        self.contentView.layer.cornerRadius = 14.0f;
        self.contentView.layer.masksToBounds = YES;
        CGFloat scale = highlighted ? 0.985f : 1.0f;
        self.transform = CGAffineTransformMakeScale(scale, scale);
    };
    if (!animated) { apply(); return; }
    [UIView animateWithDuration:0.14f animations:apply];
}

@end

#pragma mark - MDPrimaryButton

@implementation MDPrimaryButton {
    CAGradientLayer *_fill;
    UIStackView *_labelStack;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = NO;

    // The gradient is a plain layer behind everything rather than a CAGradientLayer
    // used as the control's own layer, because the control's own layer is where
    // the shadow has to be drawn and a gradient layer masks the shadow away.
    _fill = [CAGradientLayer layer];
    _fill.startPoint = CGPointMake(0.0f, 0.0f);
    _fill.endPoint = CGPointMake(1.0f, 1.0f);
    _fill.cornerRadius = 16.0f;
    _fill.masksToBounds = YES;
    [self.layer insertSublayer:_fill atIndex:0];

    self.layer.cornerRadius = 16.0f;
    self.layer.shadowColor = [UIColor colorWithWhite:0.0f alpha:1.0f].CGColor;
    self.layer.shadowOpacity = 0.16f;
    self.layer.shadowRadius = 14.0f;
    self.layer.shadowOffset = CGSizeMake(0.0f, 6.0f);

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.tintColor = [UIColor whiteColor];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = MDThemeFont(17.0f, UIFontWeightBold);
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.numberOfLines = 1;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = MDThemeFont(13.0f, UIFontWeightMedium);
    // 0.92 white over a saturated fill: pure white subtitle next to pure white
    // title is unreadable, and the tint is what carries the difference instead.
    _subtitleLabel.textColor = [UIColor colorWithWhite:1.0f alpha:0.88f];
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_subtitleLabel];

    _labelStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _subtitleLabel ]];
    _labelStack.axis = UILayoutConstraintAxisVertical;
    _labelStack.spacing = 2.0f;
    _labelStack.alignment = UIStackViewAlignmentLeading;
    _labelStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_labelStack];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.color = [UIColor whiteColor];
    _spinner.hidesWhenStopped = YES;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_spinner];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20.0f],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:22.0f],
        [_iconView.heightAnchor constraintEqualToConstant:22.0f],

        [_labelStack.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:14.0f],
        [_labelStack.topAnchor constraintEqualToAnchor:self.topAnchor constant:15.0f],
        [_labelStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-15.0f],
        [_labelStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-20.0f],

        [_spinner.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20.0f],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

        [self.heightAnchor constraintGreaterThanOrEqualToConstant:68.0f],
    ]];

    [self applyKind:MDPrimaryButtonKindAccent title:@"" subtitle:nil busy:NO enabled:YES];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // The fill is a sublayer, so it has to be told the new bounds; a gradient
    // layer left at its old size is how the button ends up filled on the left
    // half only after a rotation.
    _fill.frame = self.bounds;
}

- (void)applyKind:(MDPrimaryButtonKind)kind
            title:(NSString *)title
         subtitle:(NSString *)subtitle
             busy:(BOOL)busy
          enabled:(BOOL)enabled {
    UIColor *from = nil;
    UIColor *to = nil;

    switch (kind) {
        case MDPrimaryButtonKindStop: {
            // Not systemRed: a saturated red fill with white text is what iOS
            // uses for "delete", and this stops a session rather than destroying
            // anything. The pair below is the same hue with the intensity taken
            // out so it reads as a stop control.
            from = [UIColor colorWithRed:0.98f green:0.36f blue:0.36f alpha:1.0f];
            to   = [UIColor colorWithRed:0.93f green:0.25f blue:0.30f alpha:1.0f];
            _iconView.image = MDUISymbol(@"stop.fill", 16.0f, UIFontWeightBold);
            self.layer.shadowColor = [UIColor colorWithRed:0.90f green:0.25f blue:0.30f alpha:1.0f].CGColor;
            break;
        }
        case MDPrimaryButtonKindBusy: {
            // Muted grey rather than a dimmed accent: a half-faded accent next to
            // the enabled accent two taps away is hard to tell apart, and the
            // spinner already says "working".
            from = [UIColor colorWithWhite:0.66f alpha:1.0f];
            to   = [UIColor colorWithWhite:0.58f alpha:1.0f];
            _iconView.image = nil;
            self.layer.shadowColor = [UIColor colorWithWhite:0.0f alpha:1.0f].CGColor;
            break;
        }
        case MDPrimaryButtonKindAccent:
        default: {
            CGFloat ar = 0, ag = 0, ab = 0, aa = 1;
            [MDThemeAccent() getRed:&ar green:&ag blue:&ab alpha:&aa];
            // Diagonal, and the second stop is the accent darkened, so the pill
            // has some depth without needing a second view.
            from = [UIColor colorWithRed:ar green:ag blue:ab alpha:1.0f];
            to   = [UIColor colorWithRed:ar * 0.82f green:ag * 0.86f blue:ab * 0.84f alpha:1.0f];
            _iconView.image = MDUISymbol(@"bolt.fill", 16.0f, UIFontWeightBold);
            self.layer.shadowColor = [UIColor colorWithRed:ar green:ag blue:ab alpha:1.0f].CGColor;
            break;
        }
    }

    [_fill setColors:@[ (__bridge id)from.CGColor, (__bridge id)to.CGColor ]];

    _titleLabel.text = title;
    _titleLabel.textColor = [UIColor whiteColor];
    _subtitleLabel.text = subtitle;
    _subtitleLabel.hidden = (subtitle.length == 0);

    if (busy && !_spinner.isAnimating) {
        [_spinner startAnimating];
    } else if (!busy && _spinner.isAnimating) {
        [_spinner stopAnimating];
    }

    self.userInteractionEnabled = enabled;
    self.alpha = enabled ? 1.0f : 0.92f;
    // The shadow is what makes this look like a button rather than a coloured
    // rectangle, and it has to go while it is disabled — a shadow under a control
    // that cannot be pressed reads as broken.
    self.layer.shadowOpacity = enabled ? 0.16f : 0.0f;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12f animations:^{
        self.transform = CGAffineTransformMakeScale(highlighted ? 0.97f : 1.0f,
                                                    highlighted ? 0.97f : 1.0f);
        self.alpha = highlighted ? 0.90f : (self.userInteractionEnabled ? 1.0f : 0.92f);
    }];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, 74.0f);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(size.width, 74.0f);
}

@end

#pragma mark - MDStatusChip

@implementation MDStatusChip

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.userInteractionEnabled = NO;
    self.backgroundColor = MDThemePanel2();
    self.layer.cornerRadius = 16.0f;

    // The dot is a plain view, not an image: an SF Symbol dot scales with the
    // symbol's own optical size and does not sit on the cap line the way a
    // 10pt circle does next to 15pt text.
    _dotView = [[UIView alloc] initWithFrame:CGRectZero];
    _dotView.translatesAutoresizingMaskIntoConstraints = NO;
    _dotView.layer.cornerRadius = 5.0f;
    _dotView.userInteractionEnabled = NO;
    [self addSubview:_dotView];

    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.font = MDThemeFont(16.0f, UIFontWeightBold);
    _valueLabel.numberOfLines = 1;
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_valueLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.font = MDThemeFont(12.5f, UIFontWeightMedium);
    _detailLabel.textColor = MDThemeMuted();
    _detailLabel.numberOfLines = 2;
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_detailLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_dotView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0f],
        // Centred on the title, not on the whole chip. With a two-line detail the
        // chip's centre is below the title's, and a dot on the chip's centre
        // looks like it belongs to the detail.
        [_dotView.centerYAnchor constraintEqualToAnchor:_valueLabel.centerYAnchor],
        [_dotView.widthAnchor constraintEqualToConstant:10.0f],
        [_dotView.heightAnchor constraintEqualToConstant:10.0f],

        [_valueLabel.leadingAnchor constraintEqualToAnchor:_dotView.trailingAnchor constant:10.0f],
        [_valueLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:14.0f],

        [_detailLabel.leadingAnchor constraintEqualToAnchor:_valueLabel.leadingAnchor],
        [_detailLabel.topAnchor constraintEqualToAnchor:_valueLabel.bottomAnchor constant:2.0f],
        [_detailLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-14.0f],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0f],

        [self.heightAnchor constraintGreaterThanOrEqualToConstant:62.0f],
    ]];

    [self applyKind:MDStatusChipKindOff title:@"" detail:nil];
    return self;
}

- (void)applyKind:(MDStatusChipKind)kind title:(NSString *)title detail:(NSString *)detail {
    UIColor *hue = nil;
    switch (kind) {
        case MDStatusChipKindLive:
            hue = MDThemeGreen();
            break;
        case MDStatusChipKindReady:
            // Amber, not green. The old row coloured the kernel-ready case green
            // because the exploit had worked, and green on that screen means
            // "ESP is on" everywhere else, so a ready machine looked live.
            hue = MDThemeOrange();
            break;
        case MDStatusChipKindOff:
        default:
            hue = MDThemeMuted();
            break;
    }

    CGFloat r = 0, g = 0, b = 0, a = 1;
    [hue getRed:&r green:&g blue:&b alpha:&a];

    // Soft fill of the same hue rather than a neutral one, so the chip's colour
    // is carried by both the dot and the background and neither has to be read
    // on its own.
    self.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:0.12f];
    _dotView.backgroundColor = hue;
    _valueLabel.text = title;
    _valueLabel.textColor = [UIColor colorWithRed:r * 0.55f green:g * 0.45f blue:b * 0.45f alpha:1.0f];
    _detailLabel.text = detail;
    _detailLabel.hidden = (detail.length == 0);
}

@end