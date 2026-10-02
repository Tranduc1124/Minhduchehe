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
            [normal setValue:@{ NSForegroundColorAttributeName: MDThemeText() }
                      forKey:@"titleTextAttributes"];
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
static const CGFloat kChevronGap = 8.0f;

// The chevron wants a grey lighter than the label colour, and MDTheme exposes
// no alpha helper, so tint by scaling the existing colour.
static UIColor *MDChevronTint(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return c;
    return [UIColor colorWithRed:r * 0.62f green:g * 0.62f blue:b * 0.62f alpha:a];
}

@implementation MDIconRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)ident {
    self = [super initWithStyle:style reuseIdentifier:ident];
    if (!self) return nil;

    _iconTile = [[UIView alloc] initWithFrame:CGRectZero];
    _iconTile.userInteractionEnabled = NO;
    _iconTile.layer.cornerRadius = 8.0f;
    _iconTile.clipsToBounds = YES;
    [self.contentView addSubview:_iconTile];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.userInteractionEnabled = NO;
    [_iconTile addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = MDThemeFont(17.0f, UIFontWeightSemibold);
    _titleLabel.textColor = MDThemeText();
    [self.contentView addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.font = MDThemeFont(13.0f, UIFontWeightRegular);
    _subtitleLabel.textColor = MDThemeMuted();
    _subtitleLabel.numberOfLines = 2;
    [self.contentView addSubview:_subtitleLabel];

    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.font = MDThemeFont(15.0f, UIFontWeightRegular);
    _valueLabel.textColor = MDThemeMuted();
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:_valueLabel];

    _chevronView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _chevronView.image = MDUISymbol(@"chevron.right", 13.0f, UIFontWeightSemibold);
    _chevronView.tintColor = MDChevronTint(MDThemeMuted());
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;
    _chevronView.userInteractionEnabled = NO;
    [self.contentView addSubview:_chevronView];

    return self;
}

- (void)applyIconNamed:(NSString *)symbolName color:(UIColor *)color {
    _iconTile.backgroundColor = color ?: MDThemePanel2();
    _iconView.image = [symbolName length] ? MDUISymbol(symbolName, 15.0f, UIFontWeightSemibold) : nil;
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
    _subtitleLabel.hidden = (subtitle.length == 0);
    _valueLabel.text = value;
    _valueLabel.hidden = (value.length == 0);
    _chevronView.hidden = !chevron;
    self.selectionStyle = tappable ? UITableViewCellSelectionStyleDefault
                                   : UITableViewCellSelectionStyleNone;
    self.userInteractionEnabled = tappable;
    [self setNeedsLayout];
}

+ (CGFloat)heightForTitle:(NSString *)title subtitle:(NSString *)subtitle {
    if (subtitle.length == 0) return 54.0f;
    CGFloat h = 14.0f + 22.0f + 4.0f;
    h += [self subtitleHeightForWidth:280.0f text:subtitle title:title];
    return h + 12.0f;
}

+ (CGFloat)subtitleHeightForWidth:(CGFloat)width text:(NSString *)subtitle title:(NSString *)title {
    if (subtitle.length == 0) return 0.0f;
    CGFloat textW = width - (kTilePad + kTileSize + kTileGap) - kTilePad - kChevronW - kChevronGap * 2;
    if (textW < 80.0f) textW = 80.0f;
    CGSize bound = CGSizeMake(textW, 100.0f);
    NSDictionary *attrs = @{ NSFontAttributeName: MDThemeFont(13.0f, UIFontWeightRegular) };
    CGRect r = [subtitle boundingRectWithSize:bound
                                      options:(NSStringDrawingUsesLineFragmentOrigin |
                                               NSStringDrawingUsesFontLeading)
                                   attributes:attrs
                                      context:nil];
    CGFloat titleH = [title boundingRectWithSize:bound
                                          options:NSStringDrawingUsesLineFragmentOrigin
                                       attributes:@{ NSFontAttributeName: MDThemeFont(17.0f, UIFontWeightSemibold) }
                                          context:nil].size.height;
    return MAX(titleH, ceil(r.size.height));
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect content = self.contentView.bounds;
    CGFloat x = kTilePad;
    CGFloat w = CGRectGetWidth(content);

    BOOL hasChevron = !_chevronView.hidden;
    BOOL hasValue = !_valueLabel.hidden;
    CGFloat trailing = kTilePad;
    if (hasChevron) {
        _chevronView.frame = CGRectMake(w - trailing - kChevronW, (CGRectGetHeight(content) - 12.0f) * 0.5f,
                                        kChevronW, 14.0f);
        trailing += kChevronW + kChevronGap;
    }
    CGFloat textX = x + kTileSize + kTileGap;
    CGFloat textW = w - textX - trailing;

    CGFloat centerY = CGRectGetHeight(content) * 0.5f;
    _iconTile.frame = CGRectMake(x, centerY - kTileSize * 0.5f, kTileSize, kTileSize);
    CGFloat inset = 7.0f;
    _iconView.frame = CGRectMake(inset, inset, kTileSize - inset * 2, kTileSize - inset * 2);

    if (_subtitleLabel.hidden) {
        _titleLabel.frame = CGRectMake(textX, 0, hasValue ? textW - 110.0f : textW, CGRectGetHeight(content));
        _valueLabel.frame = CGRectMake(w - trailing - 104.0f, 0, 104.0f, CGRectGetHeight(content));
        _valueLabel.textAlignment = NSTextAlignmentRight;
    } else {
        CGFloat subH = [MDIconRowCell subtitleHeightForWidth:MAX(80.0f, textW)
                                                        text:_subtitleLabel.text
                                                       title:_titleLabel.text];
        CGFloat blockH = 22.0f + 3.0f + subH;
        CGFloat top = (CGRectGetHeight(content) - blockH) * 0.5f;
        _titleLabel.frame = CGRectMake(textX, top, textW, 22.0f);
        _subtitleLabel.frame = CGRectMake(textX, top + 25.0f, textW, subH);
        _valueLabel.frame = CGRectZero;
    }
}

@end