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
    self.contentView.alpha = highlighted ? 0.62f : 1.0f;
}

@end