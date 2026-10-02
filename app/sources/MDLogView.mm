#import "MDLogView.h"
#import "MDLog.h"
#import "MDUI.h"
#import "MDTheme.h"
#import <sys/utsname.h>

@interface MDLogView ()
@property (nonatomic, strong) UIView *headerCard;
@property (nonatomic, strong) UIView *divider;
@property (nonatomic, strong) UITextView *console;
@end

@implementation MDLogView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithRed:0.043f green:0.055f blue:0.086f alpha:1.0f];

    _headerCard = [[UIView alloc] initWithFrame:CGRectZero];
    _headerCard.backgroundColor = [UIColor colorWithRed:0.071f green:0.086f blue:0.137f alpha:1.0f];
    _headerCard.layer.cornerRadius = 14.0f;
    _headerCard.clipsToBounds = YES;
    [self addSubview:_headerCard];

    NSString *version = @"—";
    NSString *build = @"0";
    NSDictionary *info = [NSBundle mainBundle].infoDictionary ?: @{};
    if (info[@"CFBundleShortVersionString"]) version = info[@"CFBundleShortVersionString"];
    if (info[@"CFBundleVersion"]) build = info[@"CFBundleVersion"];

    NSString *model = @"Unknown";
    struct utsname u;
    if (uname(&u) == 0) model = [NSString stringWithCString:u.machine encoding:NSUTF8StringEncoding];

    NSArray<NSString *> *lines = @[
        @"@MINHDUC",
        [NSString stringWithFormat:@"External for Free Fire | Version: %@ (%@)", version, build],
        [NSString stringWithFormat:@"%@ • iOS %@", model, [[UIDevice currentDevice] systemVersion]],
    ];
    CGFloat fontSizes[] = { 15.0f, 11.0f, 11.0f };
    CGFloat y = 12.0f;
    for (NSUInteger i = 0; i < lines.count; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
        l.text = lines[i];
        l.font = MDUIMonoFont(fontSizes[i], UIFontWeightBold);
        l.textColor = [UIColor whiteColor];
        l.textAlignment = NSTextAlignmentCenter;
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.7f;
        l.frame = CGRectMake(12.0f, y, 0.0f, i == 0 ? 20.0f : 15.0f); // width set in layoutSubviews
        [_headerCard addSubview:l];
        y += (i == 0 ? 24.0f : 17.0f);
    }

    _divider = [[UIView alloc] initWithFrame:CGRectZero];
    _divider.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.08f];
    [self addSubview:_divider];

    _console = [[UITextView alloc] initWithFrame:CGRectZero];
    _console.editable = NO;
    _console.scrollEnabled = YES;
    _console.backgroundColor = [UIColor clearColor];
    _console.font = MDUIMonoFont(10.5f, UIFontWeightRegular);
    _console.textColor = [UIColor colorWithRed:0.84f green:0.88f blue:0.94f alpha:1.0f];
    _console.textContainerInset = UIEdgeInsetsMake(8.0f, 12.0f, 12.0f, 12.0f);
    _console.textContainer.lineFragmentPadding = 0.0f;
    _console.alwaysBounceVertical = YES;
    [self addSubview:_console];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(logChanged)
                                                 name:MDLogDidAppendNotification
                                               object:nil];
    [self refresh];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)logChanged {
    [self refresh];
}

- (void)refresh {
    NSString *t = [MDLog text];
    if ([_console.text isEqualToString:t]) return;
    _console.attributedText = [self colourisedText:t];
    [self scrollToBottom];
}

// KernelBoot tags every line with its stage: RUN, KRW, DONE, OK, WARN, ERR.
// Colouring by that first word is what makes the boot readable at a glance,
// and it is the only structure the lines have — there is no level field.
- (UIColor *)colourForLine:(NSString *)line {
    NSString *head = [[line componentsSeparatedByString:@" "] firstObject] ?: @"";
    if ([head isEqualToString:@"RUN"])     return [UIColor colorWithRed:1.00f green:0.84f blue:0.04f alpha:1.0f];
    if ([head isEqualToString:@"KRW"])     return [UIColor colorWithRed:1.00f green:0.42f blue:0.55f alpha:1.0f];
    if ([head isEqualToString:@"DONE"])    return [UIColor colorWithRed:0.31f green:0.83f blue:1.00f alpha:1.0f];
    if ([head isEqualToString:@"CLEANUP"]) return [UIColor colorWithRed:0.85f green:0.85f blue:0.90f alpha:1.0f];
    if ([head isEqualToString:@"OK"])      return [UIColor colorWithRed:0.30f green:0.85f blue:0.50f alpha:1.0f];
    if ([head isEqualToString:@"WARN"])    return [UIColor colorWithRed:1.00f green:0.62f blue:0.04f alpha:1.0f];
    if ([head isEqualToString:@"ERR"])     return [UIColor colorWithRed:1.00f green:0.29f blue:0.24f alpha:1.0f];
    if ([line hasPrefix:@"["])             return [UIColor colorWithRed:0.62f green:0.68f blue:0.78f alpha:1.0f];
    return [UIColor colorWithRed:0.84f green:0.88f blue:0.94f alpha:1.0f];
}

- (NSAttributedString *)colourisedText:(NSString *)text {
    UIFont *font = MDUIMonoFont(10.5f, UIFontWeightRegular);
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    __block BOOL isFirst = YES;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString *substring, NSRange substringRange,
                                       NSRange enclosingRange, BOOL *stop) {
        if (!isFirst) {
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        }
        isFirst = NO;
        // substringRange includes the newline; drop it so the added \n is the
        // only break and the text view does not double-space.
        NSRange lineRange = substringRange;
        if (lineRange.length > 0 && [text characterAtIndex:NSMaxRange(lineRange) - 1] == '\n') {
            lineRange.length -= 1;
        }
        NSString *line = [text substringWithRange:lineRange];
        [out appendAttributedString:[[NSAttributedString alloc]
            initWithString:line
                attributes:@{ NSForegroundColorAttributeName: [self colourForLine:line],
                              NSFontAttributeName: font }]];
    }];
    return out;
}

- (void)scrollToBottom {
    if (_console.text.length == 0) return;
    [_console scrollRangeToVisible:NSMakeRange(_console.text.length, 0)];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat inset = 16.0f;

    CGFloat headerH = 88.0f;
    _headerCard.frame = CGRectMake(inset, 12.0f, w - inset * 2.0f, headerH);
    _divider.frame = CGRectMake(0.0f, CGRectGetMaxY(_headerCard.frame) + 12.0f, w, 1.0f);

    CGFloat top = CGRectGetMaxY(_divider.frame);
    _console.frame = CGRectMake(0.0f, top, w, h - top);

    // Header labels were created with zero width; give them the card's width.
    for (UIView *v in _headerCard.subviews) {
        if ([v isKindOfClass:[UILabel class]]) {
            v.frame = CGRectMake(12.0f, v.frame.origin.y, _headerCard.bounds.size.width - 24.0f,
                                 v.bounds.size.height);
        }
    }
}

@end