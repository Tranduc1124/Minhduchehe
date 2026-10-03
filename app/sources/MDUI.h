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

// The row press feedback used to be a whole-contentView alpha dip to 0.62, which
// greys the icon tile along with the text and reads as the row glitching. This is
// the same idea at a scale that keeps the accent: a soft accent wash behind the
// card, no dimming of the glyphs.
- (void)setPressHighlighted:(BOOL)highlighted animated:(BOOL)animated;

@end

// A full-width action button for the one thing a screen exists to do.
//
// The Game screen's start control was a table row like every other row on it, so
// the only thing on screen that actually starts the hack had the same visual
// weight as the footer text. This is a filled pill: accent gradient when idle,
// muted while working, red when it will stop what is running, plus an optional
// busy spinner and a soft shadow so it sits above the card.
//
// States are set through -applyKind:title:subtitle:busy:enabled:.
typedef NS_ENUM(NSInteger, MDPrimaryButtonKind) {
    MDPrimaryButtonKindAccent = 0, // "Start ESP" — does the thing
    MDPrimaryButtonKindStop,       // "Stop ESP" — undoes a running session
    MDPrimaryButtonKindBusy,       // "Starting…" — nothing to tap
};

@interface MDPrimaryButton : UIControl

@property (nonatomic, readonly) UILabel *titleLabel;
@property (nonatomic, readonly) UILabel *subtitleLabel;
@property (nonatomic, readonly) UIImageView *iconView;
@property (nonatomic, readonly) UIActivityIndicatorView *spinner;

// `kind` drives the colours, `busy` shows the spinner and blocks taps, `enabled`
// is the honest one: a busy button must not swallow the touch that would cancel
// the thing it is waiting for.
- (void)applyKind:(MDPrimaryButtonKind)kind
            title:(NSString *)title
         subtitle:(nullable NSString *)subtitle
             busy:(BOOL)busy
          enabled:(BOOL)enabled;

@end

// A read-only status chip: a coloured dot, a word, and an optional second line.
//
// This is the thing the Game screen exists to answer, and it was a 30pt icon
// tile inside a row that looked like every other row, so the one fact the user
// opened the screen for was the least noticeable thing on it.
//
// Three states, matching what the rows underneath already work out:
//   Off    nothing running
//   Ready  the exploit is up, ESP is off. Ready is not on, and the row this
//          replaces said "Inactive" for a machine that was in fact ready.
//   Live   a session is running
typedef NS_ENUM(NSInteger, MDStatusChipKind) {
    MDStatusChipKindOff = 0,
    MDStatusChipKindReady,
    MDStatusChipKindLive,
};

@interface MDStatusChip : UIControl

@property (nonatomic, readonly) UIView *dotView;
@property (nonatomic, readonly) UILabel *valueLabel;
@property (nonatomic, readonly) UILabel *detailLabel;

- (void)applyKind:(MDStatusChipKind)kind title:(NSString *)title detail:(nullable NSString *)detail;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif