#import "RABPanel.h"
#import "RABConfig.h"
#import "RABLog.h"
#import "RABEngine.h"
#import "RABGhost.h"
#import <objc/runtime.h>

@interface RABPanel (RABPanelInternal)
+ (void)updateSliderLabel:(UISlider *)sl;
@end

static UIWindow *rabBubbleWindow = nil;
static UIWindow *rabPanelWindow  = nil;

#define RAB_PANEL_ALPHA 0.96f

#pragma mark - small builders

static UILabel *RABLabel(NSString *text, CGFloat size, CGFloat weightDelta, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.textColor = color ?: [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:size weight:weightDelta];
    l.numberOfLines = 1;
    return l;
}

static UISwitch *RABSwitchRow(NSString *title, NSString *key, CGFloat y, CGFloat width, UIView *parent) {
    UILabel *l = RABLabel(title, 14, UIFontWeightRegular, [UIColor whiteColor]);
    l.frame = CGRectMake(20, y, width - 100, 24);
    [parent addSubview:l];
    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = [UIColor systemGreenColor];
    sw.frame = CGRectMake(width - 74, y - 6, 51, 31);
    sw.on = [[RABConfig shared] boolForKey:key];
    [sw addTarget:[RABPanel class] action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    sw.accessibilityIdentifier = key;
    [parent addSubview:sw];
    return sw;
}

static UISlider *RABSliderRow(NSString *title, NSString *key, double minV, double maxV,
                              CGFloat y, CGFloat width, UIView *parent, NSString *suffix) {
    UILabel *l = RABLabel(title, 13, UIFontWeightRegular, [UIColor lightGrayColor]);
    l.frame = CGRectMake(20, y, width - 140, 18);
    [parent addSubview:l];
    UILabel *val = RABLabel(@"", 13, UIFontWeightSemibold, [UIColor systemGreenColor]);
    val.textAlignment = NSTextAlignmentRight;
    val.frame = CGRectMake(width - 130, y, 100, 18);
    [parent addSubview:val];
    UISlider *sl = [[UISlider alloc] init];
    sl.minimumValue = minV;
    sl.maximumValue = maxV;
    sl.frame = CGRectMake(20, y + 20, width - 40, 30);
    sl.value = [[RABConfig shared] doubleForKey:key];
    sl.accessibilityIdentifier = key;
    objc_setAssociatedObject(sl, "rab_suffix", suffix, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(sl, "rab_valLabel", val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sl addTarget:[RABPanel class] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [[RABPanel class] updateSliderLabel:sl];
    [parent addSubview:sl];
    return sl;
}

#pragma mark - panel VC

@implementation RABPanel

+ (void)install {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installBubble];
    });
}

+ (void)installBubble {
    if (rabBubbleWindow) return;
    UIWindowScene *scene = [self primaryScene];
    if (!scene) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self installBubble]; }); return; }

    rabBubbleWindow = [[UIWindow alloc] initWithWindowScene:scene];
    rabBubbleWindow.windowLevel = UIWindowLevelAlert + 100;
    rabBubbleWindow.frame = CGRectMake(18, 180, 54, 54);
    rabBubbleWindow.backgroundColor = [UIColor clearColor];
    rabBubbleWindow.rootViewController = [[UIViewController alloc] init];
    rabBubbleWindow.hidden = NO;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = rabBubbleWindow.bounds;
    b.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.8];
    b.layer.cornerRadius = 27;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    b.clipsToBounds = YES;
    [b setTitle:@"🤖" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:24];
    b.accessibilityLabel = @"RedditAIBridge options";
    [b addTarget:[RABPanel class] action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [rabBubbleWindow.rootViewController.view addSubview:b];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[RABPanel class]
                                                                          action:@selector(bubbleDragged:)];
    [b addGestureRecognizer:pan];
    [RABLog line:@"options bubble installed — tap 🤖 to configure"];
}

+ (UIWindowScene *)primaryScene {
    for (id obj in [UIApplication sharedApplication].connectedScenes) {
        if ([obj isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *sc = obj;
            if (sc.activationState == UISceneActivationStateForegroundActive) return sc;
        }
    }
    for (id obj in [UIApplication sharedApplication].connectedScenes) {
        if ([obj isKindOfClass:[UIWindowScene class]]) return obj;
    }
    return nil;
}

+ (void)bubbleDragged:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:p.view];
    CGRect f = rabBubbleWindow.frame;
    f.origin.x = MAX(0, MIN([UIScreen mainScreen].bounds.size.width - f.size.width, f.origin.x + t.x));
    f.origin.y = MAX(0, MIN([UIScreen mainScreen].bounds.size.height - f.size.height, f.origin.y + t.y));
    rabBubbleWindow.frame = f;
    [p setTranslation:CGPointZero inView:p.view];
}

+ (void)togglePanel { [self panelVisible] ? [self hidePanel] : [self showPanel]; }
+ (BOOL)panelVisible { return rabPanelWindow && !rabPanelWindow.hidden; }

+ (void)showPanel {
    UIWindowScene *scene = [self primaryScene];
    if (!scene) return;
    if (rabPanelWindow) { rabPanelWindow.hidden = NO; [self refreshPanel]; return; }

    CGRect screen = [UIScreen mainScreen].bounds;
    rabPanelWindow = [[UIWindow alloc] initWithWindowScene:scene];
    rabPanelWindow.windowLevel = UIWindowLevelAlert + 101;
    rabPanelWindow.frame = screen;
    rabPanelWindow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    rabPanelWindow.hidden = NO;

    UIViewController *vc = [[UIViewController alloc] init];
    rabPanelWindow.rootViewController = vc;
    UIView *root = vc.view;
    root.backgroundColor = [UIColor clearColor];

    CGFloat pw = MIN(430, screen.size.width - 30);
    CGFloat ph = MIN(680, screen.size.height - 110);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((screen.size.width - pw) / 2, (screen.size.height - ph) / 2, pw, ph)];
    panel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:RAB_PANEL_ALPHA];
    panel.layer.cornerRadius = 18;
    panel.clipsToBounds = YES;
    [root addSubview:panel];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:panel.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [panel addSubview:scroll];

    CGFloat w = pw;
    CGFloat y = 16;
    UILabel *title = RABLabel(@"RedditAIBridge v2.0 (Ghost)", 17, UIFontWeightSemibold, [UIColor whiteColor]);
    title.frame = CGRectMake(20, y, w - 40, 24);
    [scroll addSubview:title];
    y += 30;
    UILabel *status = RABLabel(@"", 12, UIFontWeightRegular, [UIColor systemGreenColor]);
    status.numberOfLines = 2;
    status.frame = CGRectMake(20, y, w - 40, 34);
    status.accessibilityIdentifier = @"rab_status";
    [scroll addSubview:status];
    y += 44;

    UILabel *secToggles = RABLabel(@"MODE", 11, UIFontWeightBold, [UIColor colorWithWhite:1 alpha:0.45]);
    secToggles.frame = CGRectMake(20, y, w - 40, 16);
    [scroll addSubview:secToggles];
    y += 22;
    RABSwitchRow(@"Master switch", @"enabled", y, w, scroll); y += 40;
    RABSwitchRow(@"Dry-run (log only, send nothing)", @"dryRun", y, w, scroll); y += 40;
    RABSwitchRow(@"Ghost mode (UI send only — recommended)", @"ghostOnly", y, w, scroll); y += 40;
    RABSwitchRow(@"Auto chat-swap (open inbox cells itself)", @"autoNavigate", y, w, scroll); y += 40;
    RABSwitchRow(@"Typing haptics", @"typingHaptics", y, w, scroll); y += 40;
    RABSwitchRow(@"Feed warm-up scrolling", @"warmUpEnabled", y, w, scroll); y += 40;
    RABSwitchRow(@"Idle breaks between sessions", @"idleBreaksEnabled", y, w, scroll); y += 40;
    RABSwitchRow(@"Discovery mode (dump UI tree to log)", @"discoveryMode", y, w, scroll); y += 46;

    UILabel *secCaps = RABLabel(@"SAFETY LIMITS — how many requests I accept", 11, UIFontWeightBold, [UIColor colorWithWhite:1 alpha:0.45]);
    secCaps.frame = CGRectMake(20, y, w - 40, 16);
    [scroll addSubview:secCaps];
    y += 24;
    RABSliderRow(@"Max replies / day", @"dailyCap", 5, 100, y, w, scroll, @""); y += 56;
    RABSliderRow(@"Max replies / hour", @"hourlyCap", 1, 30, y, w, scroll, @""); y += 56;
    RABSliderRow(@"Per-thread cooldown (min)", @"perThreadCooldownMin", 5, 60, y, w, scroll, @" min"); y += 56;
    RABSliderRow(@"Unread poll interval", @"pollIntervalSec", 60, 600, y, w, scroll, @" s"); y += 56;
    RABSliderRow(@"Typing speed (ms/char)", @"typingMsPerChar", 80, 400, y, w, scroll, @" ms"); y += 56;
    RABSliderRow(@"Kill-switch halt on 429/403 (h)", @"killSwitchHours", 1, 48, y, w, scroll, @" h"); y += 60;

    UILabel *secAcc = RABLabel(@"CAPITALAI ACCOUNT", 11, UIFontWeightBold, [UIColor colorWithWhite:1 alpha:0.45]);
    secAcc.frame = CGRectMake(20, y, w - 40, 16);
    [scroll addSubview:secAcc];
    y += 24;
    UITextField *lic = [[UITextField alloc] init];
    lic.placeholder = @"licensekey";
    lic.secureTextEntry = YES;
    lic.text = [[RABConfig shared] stringForKey:@"licensekey"];
    lic.frame = CGRectMake(20, y, w - 40, 36);
    lic.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    lic.textColor = [UIColor whiteColor];
    lic.layer.cornerRadius = 8;
    lic.returnKeyType = UIReturnKeyDone;
    [lic addTarget:[RABPanel class] action:@selector(textEdited:) forControlEvents:UIControlEventEditingChanged | UIControlEventEditingDidEnd];
    lic.accessibilityIdentifier = @"licensekey";
    [scroll addSubview:lic];
    y += 44;
    UITextField *acc = [[UITextField alloc] init];
    acc.placeholder = @"accountId (bot name)";
    acc.text = [[RABConfig shared] stringForKey:@"accountId"];
    acc.frame = CGRectMake(20, y, w - 40, 36);
    acc.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    acc.textColor = [UIColor whiteColor];
    acc.layer.cornerRadius = 8;
    [acc addTarget:[RABPanel class] action:@selector(textEdited:) forControlEvents:UIControlEventEditingChanged | UIControlEventEditingDidEnd];
    acc.accessibilityIdentifier = @"accountId";
    [scroll addSubview:acc];
    y += 54;

    // buttons
    NSArray *btns = @[
        @[@"Force cycle", @"forceCycle"],
        @[@"Dump UI tree", @"dumpUI"],
        @[@"Typing test", @"typingTest"],
        @[@"Close", @"closePanel"]
    ];
    CGFloat bw = (w - 40 - 12) / 2.0;
    for (NSUInteger i = 0; i < btns.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(20 + (i % 2) * (bw + 12), y + (i / 2) * 44, bw, 36);
        [b setTitle:btns[i][0] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        b.layer.cornerRadius = 8;
        b.tintColor = [UIColor whiteColor];
        [b addTarget:[RABPanel class] action:NSSelectorFromString(btns[i][1]) forControlEvents:UIControlEventTouchUpInside];
        [scroll addSubview:b];
    }
    y += 2 * 44 + 14;

    UITextView *logs = [[UITextView alloc] initWithFrame:CGRectMake(20, y, w - 40, 130)];
    logs.editable = NO;
    logs.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    logs.textColor = [UIColor lightGrayColor];
    logs.font = [UIFont fontWithName:@"Menlo" size:10];
    logs.layer.cornerRadius = 8;
    logs.accessibilityIdentifier = @"rab_logs";
    [scroll addSubview:logs];
    y += 146;

    scroll.contentSize = CGSizeMake(w, y + 20);
    objc_setAssociatedObject(rabPanelWindow, "rab_statusLabel", status, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(rabPanelWindow, "rab_logsView", logs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self refreshPanel];
}

+ (void)hidePanel {
    if (rabPanelWindow) rabPanelWindow.hidden = YES;
}

+ (void)refreshPanel {
    UILabel *status = objc_getAssociatedObject(rabPanelWindow, "rab_statusLabel");
    UITextView *logs = objc_getAssociatedObject(rabPanelWindow, "rab_logsView");
    if (status) status.text = [[RABEngine shared] statusLine];
    if (logs) {
        NSMutableString *s = [NSMutableString string];
        for (NSString *l in [RABLog tail:12]) { [s appendFormat:@"%@\n", l]; }
        logs.text = s;
        NSRange b = NSMakeRange(logs.text.length ? logs.text.length - 1 : 0, 0);
        [logs scrollRangeToVisible:b];
    }
}

/* ---- control handlers ---- */

+ (void)switchChanged:(UISwitch *)sw {
    [[RABConfig shared] setObject:@(sw.on) forKey:sw.accessibilityIdentifier];
    [RABLog line:@"panel: %@ = %@", sw.accessibilityIdentifier, sw.on ? @"ON" : @"OFF"];
}

+ (void)updateSliderLabel:(UISlider *)sl {
    UILabel *val = objc_getAssociatedObject(sl, "rab_valLabel");
    NSString *suffix = objc_getAssociatedObject(sl, "rab_suffix");
    val.text = [NSString stringWithFormat:@"%ld%@", (long)[sl value], suffix ?: @""];
}

+ (void)sliderChanged:(UISlider *)sl {
    [[RABConfig shared] setObject:@((NSInteger)[sl value]) forKey:sl.accessibilityIdentifier];
    [self updateSliderLabel:sl];
}

+ (void)textEdited:(UITextField *)tf {
    NSString *v = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (v.length) [[RABConfig shared] setObject:v forKey:tf.accessibilityIdentifier];
}

+ (void)forceCycle {
    [self hidePanel];
    [[RABEngine shared] forceCycle];
}

+ (void)dumpUI {
    [RABGhost dumpHierarchy];
    [RABLog line:@"panel: UI tree dumped to syslog ([DUMP] lines)"];
}

+ (void)typingTest {
    [self hidePanel];
    [RABLog line:@"panel: typing test"];
    [[RABEngine shared] testTyping];
}

+ (void)closePanel { [self hidePanel]; }

@end
