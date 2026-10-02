#import <UIKit/UIKit.h>

// Shared chrome for the app's three tabs: SF Symbol helpers, the inset-grouped
// row cell used on the Game and Settings tabs, and the navigation bar skin.
//
// Icons are SF Symbols on purpose. The old menu chrome drew Font Awesome
// codepoints, but the repo ships no .ttf at all, so every one of those glyphs
// rendered as a tofu box.

#ifdef __cplusplus
extern "C" {
#endif

// Template SF Symbol, nil on iOS < 13 or for an unknown name.
UIImage *MDUISymbol(NSString *symbolName, CGFloat pointSize, UIFontWeight weight);

// Bundle image, falling back to a path lookup because the bundled game icons
// are .webp and UIImage's imageNamed: does not always decode those.
UIImage *MDUIImageNamed(NSString *baseName);

UIFont *MDUIMonoFont(CGFloat size, UIFontWeight weight);

// Standard navigation bar: opaque card background, hairline bottom, centred
// title, no large title.
void MDUIApplyNavigationBarStyle(UINavigationBar *navBar);

NS_ASSUME_NONNULL_BEGIN

// Tile + title + optional subtitle + optional value + optional chevron.
@interface MDIconRowCell : UITableViewCell

// Height the subtitle actually needs at this width. Used by the table
// delegate, so it has to be reachable from outside the implementation.
+ (CGFloat)subtitleHeightForWidth:(CGFloat)width text:(nullable NSString *)subtitle title:(NSString *)title;

@property (nonatomic, strong) UIView *iconTile;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIImageView *chevronView;

// Shows a rounded square of `color` with a white SF Symbol in it. Passing a
// nil name leaves the tile as a plain colour block.
- (void)applyIconNamed:(NSString *)symbolName color:(UIColor *)color;
- (void)applyTitle:(NSString *)title
          subtitle:(nullable NSString *)subtitle
             value:(nullable NSString *)value
        showsChevron:(BOOL)chevron
            tappable:(BOOL)tappable;

// Row height matching what applyTitle: set: laid out.
+ (CGFloat)heightForTitle:(NSString *)title subtitle:(nullable NSString *)subtitle;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif