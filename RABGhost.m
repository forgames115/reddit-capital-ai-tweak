#import "RABGhost.h"
#import "RABConfig.h"
#import "RABLog.h"

/* ------------------------------------------------------------------ private
   UIKit-level synthetic touch (classic tweak technique). All selectors are
   guarded at runtime; if the private surface changed on this iOS build the
   other activation strategies still cover us.                                */
@interface UITouch (RABPrivate)
- (instancetype)initAtPoint:(CGPoint)point inView:(UIView *)view;
- (void)_setPhase:(UITouchPhase)phase;
- (void)setPhase:(UITouchPhase)phase;
- (void)_setLocationInWindow:(CGPoint)locationInWindow preserveTimestamp:(BOOL)preserveTimestamp;
@end
@interface UIEvent (RABPrivate)
- (void)_setTouches:(NSSet *)touches;
@end

#define RABLogD(...) do { if ([[RABConfig shared] boolForKey:@"debug"]) [RABLog line:__VA_ARGS__]; } while (0)

/* ------------------------------------------------------------------ helpers */

static UIWindow *RABKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (id sceneObj in app.connectedScenes) {
        if (![sceneObj isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *sc = sceneObj;
        if (sc.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in sc.windows) if (w.isKeyWindow) return w;
        for (UIWindow *w in sc.windows) return w;
    }
    return app.keyWindow;
}

static BOOL RABVisible(UIView *v) {
    if (!v || !v.window || v.hidden || v.alpha < 0.05) return NO;
    CGRect f = v.frame;
    return f.size.width > 24 && f.size.height > 10;
}

static BOOL RABInsideSearchBar(UIView *v) {
    UIView *p = v;
    while (p) {
        if ([p isKindOfClass:[UISearchBar class]]) return YES;
        NSString *cls = NSStringFromClass([p class]);
        if ([cls containsString:@"Search"]) return YES;
        p = p.superview;
    }
    return NO;
}

@implementation RABGhost

/* -------------------------------------------------------------- traversal */

+ (void)collectViews:(UIView *)root class:(Class)cls into:(NSMutableArray *)out depth:(NSInteger)depth {
    if (!root || depth > 16) return;
    if ([root isKindOfClass:cls] && RABVisible(root)) [out addObject:root];
    for (UIView *sub in root.subviews) [self collectViews:sub class:cls into:out depth:depth + 1];
}

+ (NSArray *)visibleViewsOfClass:(Class)cls {
    UIWindow *w = RABKeyWindow();
    if (!w) return @[];
    NSMutableArray *arr = [NSMutableArray array];
    [self collectViews:w class:cls into:arr depth:0];
    return arr;
}

+ (NSArray *)visibleTextInputs {
    NSMutableArray *arr = [NSMutableArray array];
    [arr addObjectsFromArray:[self visibleViewsOfClass:[UITextView class]]];
    [arr addObjectsFromArray:[self visibleViewsOfClass:[UITextField class]]];
    return arr;
}

+ (CGPoint)windowPointOf:(UIView *)v {
    UIWindow *w = RABKeyWindow();
    return [v convertPoint:CGPointMake(v.bounds.size.width / 2.0, v.bounds.size.height / 2.0) toView:w ?: v];
}

/* ----------------------------------------------------------- state probes */

+ (BOOL)chatScreenVisible { return [self composerView] != nil; }

+ (UIView *)composerView {
    NSArray *inputs = [self visibleTextInputs];
    UIView *best = nil;
    CGPoint bestPoint = CGPointZero;
    UIWindow *w = RABKeyWindow();
    CGFloat screenH = w ? w.bounds.size.height : 800;
    for (UIView *v in inputs) {
        if (RABInsideSearchBar(v)) continue;
        if (![v isKindOfClass:[UITextView class]] && ![v isKindOfClass:[UITextField class]]) continue;
        CGPoint p = [self windowPointOf:v];
        // chat composer sits in the bottom third of the screen
        if (p.y < screenH * 0.45) continue;
        if (!best || p.y > bestPoint.y) { best = v; bestPoint = p; }
    }
    return best;
}

+ (NSString *)visibleThreadHint {
    // best-effort: a small label near the top of the screen (thread title)
    UIWindow *w = RABKeyWindow();
    if (!w) return nil;
    NSMutableArray *labels = [NSMutableArray array];
    [self collectViews:w class:[UILabel class] into:labels depth:0];
    UILabel *best = nil;
    CGFloat bestY = CGFLOAT_MAX;
    for (UILabel *l in labels) {
        if (!l.text.length) continue;
        CGPoint p = [self windowPointOf:l];
        if (p.y > w.bounds.size.height * 0.12) continue;
        if (l.frame.size.width < 60) continue;
        if (best == nil || p.y < bestY) { best = l; bestY = p.y; }
    }
    return best.text ?: nil;
}

/* ------------------------------------------------- multi-strategy tapping */

+ (BOOL)activateView:(UIView *)view {
    if (!view) return NO;

    // 1) accessibility activation — works for SwiftUI controls & bar buttons
    if ([(id)view respondsToSelector:@selector(accessibilityActivate)]) {
        @try {
            if ([(id)view accessibilityActivate]) {
                RABLogD(@"activate: a11yActivate OK on %@", NSStringFromClass([view class]));
                return YES;
            }
        } @catch (NSException *e) { /* fall through */ }
    }

    // 2) UIKit control actions
    UIControl *ctrl = nil;
    if ([view isKindOfClass:[UIControl class]]) ctrl = (UIControl *)view;
    else {
        UIView *p = view.superview;
        while (p && ![p isKindOfClass:[UIControl class]]) p = p.superview;
        if (p) ctrl = (UIControl *)p;
    }
    if (ctrl && ctrl.enabled) {
        [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
        RABLogD(@"activate: sendActions on %@", NSStringFromClass([ctrl class]));
        return YES;
    }

    // 3) synthetic touch through the app's own event pipeline
    return [self syntheticTap:view];
}

+ (BOOL)syntheticTap:(UIView *)view {
    @try {
        UIWindow *w = view.window ?: RABKeyWindow();
        if (!w) return NO;
        CGPoint p = [view convertPoint:CGPointMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0) toView:w];

        UITouch *touch = [[UITouch alloc] initAtPoint:p inView:w];
        if (!touch) { RABLogD(@"activate: private UITouch unavailable"); return NO; }
        if ([(id)touch respondsToSelector:@selector(_setPhase:)]) [(id)touch _setPhase:UITouchPhaseBegan];
        else if ([(id)touch respondsToSelector:@selector(setPhase:)]) [(id)touch setPhase:UITouchPhaseBegan];

        UIEvent *ev = [[UIEvent alloc] init];
        if (![(id)ev respondsToSelector:@selector(_setTouches:)]) {
            RABLogD(@"activate: private UIEvent unavailable");
            return NO;
        }
        [(id)ev _setTouches:[NSSet setWithObject:touch]];
        [[UIApplication sharedApplication] sendEvent:ev];

        // ended
        if ([(id)touch respondsToSelector:@selector(_setPhase:)]) [(id)touch _setPhase:UITouchPhaseEnded];
        else if ([(id)touch respondsToSelector:@selector(setPhase:)]) [(id)touch setPhase:UITouchPhaseEnded];
        ev = [[UIEvent alloc] init];
        [(id)ev _setTouches:[NSSet setWithObject:touch]];
        [[UIApplication sharedApplication] sendEvent:ev];
        RABLogD(@"activate: synthetic touch at %@", NSStringFromCGPoint(p));
        return YES;
    } @catch (NSException *e) {
        [RABLog line:@"syntheticTap exception: %@ — %@", e.name, e.reason];
        return NO;
    }
}

/* ------------------------------------------------------ humanized typing */

+ (void)typeText:(NSString *)text
    intoComposer:(UIView *)composer
      msPerChar:(NSInteger)msPerChar
         haptics:(BOOL)haptics
      completion:(void (^)(BOOL))done {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (![text length] ||
                (![composer isKindOfClass:[UITextView class]] && ![composer isKindOfClass:[UITextField class]])) {
                if (done) done(NO);
                return;
            }
            BOOL isTextView = [composer isKindOfClass:[UITextView class]];
            [(UIResponder *)composer becomeFirstResponder];
            if (isTextView) ((UITextView *)composer).text = @"";
            else ((UITextField *)composer).text = @"";
            RABLogD(@"typing %lu chars into %@", (unsigned long)text.length, isTextView ? @"UITextView" : @"UITextField");

            // 1-3 char bursts
            NSMutableArray *chunks = [NSMutableArray array];
            NSUInteger i = 0;
            while (i < text.length) {
                NSUInteger len = 1 + arc4random_uniform(3);
                if (i + len > text.length) len = text.length - i;
                [chunks addObject:[text substringWithRange:NSMakeRange(i, len)]];
                i += len;
            }

            __block NSUInteger idx = 0;
            __block UIImpactFeedbackGenerator *hap =
                haptics ? [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] : nil;

            __block void (^step)(void) = nil;
            step = ^{
                if (idx >= chunks.count) {
                    step = nil;
                    if (done) done(YES);
                    return;
                }
                NSString *chunk = chunks[idx];
                idx++;
                @try {
                    [(id<UITextInput>)composer insertText:chunk];
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:isTextView ? UITextViewTextDidChangeNotification
                                                        : UITextFieldTextDidChangeNotification
                                      object:composer];
                    if (hap && idx % 4 == 0) [hap impactOccurred];
                } @catch (NSException *e) {
                    [RABLog line:@"typing exception: %@ — %@", e.name, e.reason];
                    step = nil;
                    if (done) done(NO);
                    return;
                }
                // humanized pacing: base ms/char jittered ±30%, punctuation pauses,
                // occasional longer hesitation mid-sentence
                double ms = msPerChar * (double)chunk.length * (0.7 + 0.6 * ((double)arc4random() / UINT32_MAX));
                if (chunk.length) {
                    unichar last = [chunk characterAtIndex:chunk.length - 1];
                    if (last == ' ' || last == '.' || last == ',' || last == '?' || last == '!')
                        ms += 120 + arc4random_uniform(240);
                }
                if (idx % 17 == 0) ms += 300 + arc4random_uniform(900);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), step);
            };
            step();
        } @catch (NSException *e) {
            [RABLog line:@"typeText exception: %@ — %@", e.name, e.reason];
            if (done) done(NO);
        }
    });
}

/* ---------------------------------------------------------------- finders */

+ (UIView *)findTabBarItemWithLabel:(NSString *)label {
    if (!label.length) return nil;
    for (UIView *v in [self visibleViewsOfClass:[UIControl class]]) {
        NSString *lab = v.accessibilityLabel ?: @"";
        if ([lab compare:label options:NSCaseInsensitiveSearch] == NSOrderedSame &&
            RABVisible(v) && v.frame.size.width < 180) {
            return v;
        }
    }
    // fallback: UITabBarButton is a UIControl subclass with hashed names
    for (UIView *v in [self visibleViewsOfClass:[UIControl class]]) {
        NSString *lab = v.accessibilityLabel ?: @"";
        if (lab.length && [lab.lowercaseString containsString:label.lowercaseString] &&
            v.frame.size.width < 180) return v;
    }
    return nil;
}

+ (UIView *)findCellContainingName:(NSString *)name {
    if (!name.length) return nil;
    UIWindow *w = RABKeyWindow();
    if (!w) return nil;
    // cells (UIKit list classes) then any view with a matching a11y label
    NSMutableArray *cells = [NSMutableArray array];
    [self collectViews:w class:[UITableViewCell class] into:cells depth:0];
    [self collectViews:w class:[UICollectionViewCell class] into:cells depth:0];
    if (!cells.count) {
        // SwiftUI lists expose cells as plain UIViews with a11y labels
        for (UIView *v in [self visibleViewsOfClass:[UIView class]]) {
            NSString *lab = v.accessibilityLabel ?: @"";
            if (lab.length >= name.length && [lab.lowercaseString containsString:name.lowercaseString]) return v;
        }
        return nil;
    }
    UICollectionViewCell *best = nil;
    for (UIView *v in cells) {
        NSString *lab = v.accessibilityLabel ?: @"";
        if (![lab.lowercaseString containsString:name.lowercaseString]) continue;
        if ([v isKindOfClass:[UICollectionViewCell class]]) best = (UICollectionViewCell *)v;
        else return v;
    }
    return best;
}

+ (UIView *)findSendButtonNearComposer:(UIView *)composer {
    NSString *want = [[RABConfig shared] stringForKey:@"labelSend"];
    if (!want.length || [want isEqualToString:@"(none)"]) want = @"Send";
    UIWindow *w = RABKeyWindow();
    if (!w) return nil;
    CGFloat screenH = w.bounds.size.height;
    CGPoint composerPoint = composer ? [self windowPointOf:composer] : CGPointMake(0, screenH * 0.9);

    NSMutableArray *cands = [NSMutableArray array];
    [self collectViews:w class:[UIControl class] into:cands depth:0];
    [self collectViews:w class:[UIButton class] into:cands depth:0];
    UIView *best = nil;
    CGFloat bestDist = CGFLOAT_MAX;
    for (UIView *v in cands) {
        if (!RABVisible(v)) continue;
        NSString *lab = v.accessibilityLabel ?: @"";
        NSString *ident = v.accessibilityIdentifier ?: @"";
        BOOL match = ([lab.lowercaseString containsString:want.lowercaseString] ||
                      [ident.lowercaseString containsString:@"send"]);
        if (!match) continue;
        CGPoint p = [self windowPointOf:v];
        // must be in the bottom half of the screen (composer row)
        if (p.y < screenH * 0.5) continue;
        CGFloat dist = ABS(p.x - composerPoint.x) + ABS(p.y - composerPoint.y);
        if (dist < bestDist) { best = v; bestDist = dist; }
    }
    return best;
}

+ (UIView *)findBackButton {
    NSString *want = [[RABConfig shared] stringForKey:@"labelBack"];
    UIWindow *w = RABKeyWindow();
    if (!w) return nil;
    NSMutableArray *cands = [NSMutableArray array];
    [self collectViews:w class:[UIControl class] into:cands depth:0];
    [self collectViews:w class:[UIButton class] into:cands depth:0];
    for (UIView *v in cands) {
        if (!RABVisible(v)) continue;
        CGPoint p = [self windowPointOf:v];
        if (p.y > w.bounds.size.height * 0.25) continue; // nav area only
        NSString *lab = (v.accessibilityLabel ?: @"").lowercaseString;
        NSString *ident = (v.accessibilityIdentifier ?: @"").lowercaseString;
        if ((want.length && [lab containsString:want.lowercaseString]) ||
            [ident containsString:@"back"] || [ident containsString:@"chevron"] ||
            [lab containsString:@"chats"] || [lab containsString:@"messages"]) {
            return v;
        }
    }
    return nil;
}

/* ------------------------------------------------------------- warm-up */

+ (void)scrollFeedWarmUp {
    UIScrollView *best = nil;
    CGFloat bestArea = 0;
    for (UIScrollView *sv in [self visibleViewsOfClass:[UIScrollView class]]) {
        if ([sv isKindOfClass:[UITextView class]]) continue;
        CGFloat area = sv.bounds.size.width * sv.bounds.size.height;
        if (area > bestArea) { best = sv; bestArea = area; }
    }
    if (!best || best.contentSize.height <= best.bounds.size.height) {
        RABLogD(@"warm-up: no scrollable feed visible");
        return;
    }
    CGFloat jump = best.bounds.size.height * (0.35 + 0.5 * ((double)arc4random() / UINT32_MAX));
    if (arc4random_uniform(100) < 20) jump = -jump * 0.6;      // sometimes scroll back up
    CGPoint target = best.contentOffset;
    target.y += jump;
    CGFloat maxY = best.contentSize.height - best.bounds.size.height + best.contentInset.bottom;
    if (target.y < -best.contentInset.top) target.y = -best.contentInset.top;
    if (target.y > maxY) target.y = MAX(0, maxY);
    [best setContentOffset:target animated:YES];
    [RABLog line:@"warm-up: scrolled feed (%.0f px)", jump];
}

/* ----------------------------------------------------------- discovery */

+ (void)dumpView:(UIView *)v depth:(NSInteger)d {
    if (!v || d > 7) return;
    NSMutableString *line = [NSMutableString stringWithFormat:@"[DUMP]%*s%@ f=%@",
        (int)(d * 2), "", NSStringFromClass([v class]), NSStringFromCGRect(v.frame)];
    if (v.accessibilityLabel.length) [line appendFormat:@" a11y=\"%@\"", v.accessibilityLabel];
    if (v.accessibilityIdentifier.length) [line appendFormat:@" id=%@", v.accessibilityIdentifier];
    BOOL interesting = [v isKindOfClass:[UITextView class]] || [v isKindOfClass:[UITextField class]] ||
                       [v isKindOfClass:[UIButton class]] || [v isKindOfClass:[UIControl class]] ||
                       [v isKindOfClass:[UITableViewCell class]] || [v isKindOfClass:[UICollectionViewCell class]] ||
                       [v isKindOfClass:[UIScrollView class]] || [v isKindOfClass:[UILabel class]];
    if (interesting && RABVisible(v)) [RABLog line:@"%@", line];
    for (UIView *s in v.subviews) [self dumpView:s depth:d + 1];
}

+ (void)dumpHierarchy {
    UIWindow *w = RABKeyWindow();
    if (!w) { [RABLog line:@"[DUMP] no key window"]; return; }
    [RABLog line:@"[DUMP] ===== window %@ =====", NSStringFromClass([w class])];
    [self dumpView:w depth:0];
    [RABLog line:@"[DUMP] ===== end ====="];
}

@end
