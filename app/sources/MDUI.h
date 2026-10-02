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

NS_ASSUME_NONNULL_BEGIN

// Template SF Symbol. Null on iOS < 13 or for an unknown name, which is why
// every call site falls back rather than asserting.
UIImage *_Nullable MDUISymbol(NSString *symbolName, CGFloat pointSize, UIFontWeight weight);

// Bundle image, falling back to a path lookup because the bundled game icons
// are .webp and UIImage's imageNamed: does not always decode those. Null when
// the name resolves to neither.
UIImage *_Nullable MDUIImageNamed(NSString *baseName);

UIFont *MDUIMonoFont(CGFloat size, UIFontWeight weight);

// Standard navigation bar: opaque card background, hairline bottom, centred
// title, no large title.
void MDUIApplyNavigationBarStyle(UINavigationBar *navBar);

// Tile + title + optional subtitle + optional value + optional chevron.
//
// The cell lays itself out with Auto Layout and sizes to its content. An
// earlier version positioned subviews in layoutSubviews and asked the
// delegate for a height computed against a hardcoded 280pt width, which
// clipped long subtitles and overlapped rows at any other width. Callers
// should now leave rowHeight on UITableViewAutomaticDimension and not
// implement heightForRowAtIndexPath:.
@interface MDIconRowCell : UITableViewCell

@property (nonatomic, strong) UIView *iconTile;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIImageView *chevronView;

// Shows a rounded square of `color` with a white SF Symbol in it. Passing a
// nil name leaves the tile as a plain colour block.
- (void)applyIconNamed:(nullable NSString *)symbolName color:(nullable UIColor *)color;

- (void)applyTitle:(NSString *)title
          subtitle:(nullable NSString *)subtitle
             value:(nullable NSString *)value
       showsChevron:(BOOL)chevron
           tappable:(BOOL)tappable;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif