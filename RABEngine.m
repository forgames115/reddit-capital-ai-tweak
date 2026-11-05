#import "RABEngine.h"
#import "RABConfig.h"
#import "RABLog.h"
#import "RABNet.h"
#import "RABGhost.h"
#import <UIKit/UIKit.h>
#import <unistd.h>

static void RABMainSync(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

static BOOL RABForeground(void) {
    return [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
}

static double RABNow(void) { return [[NSDate date] timeIntervalSince1970]; }

/** Fractional sleep in ≤250 ms chunks (usleep is unreliable above 1 s). */
static void RABSleep(double seconds) {
    double left = MAX(0, seconds);
    while (left > 0) {
        double chunk = left > 0.25 ? 0.25 : left;
        usleep((useconds_t)(chunk * 1000000.0));
        left -= chunk;
    }
}

static NSString *RABPreview(NSString *s) {
    if (s.length > 90) return [[s substringToIndex:90] stringByAppendingString:@"…"];
    return s ?: @"";
}

@interface RABEngine ()
@property (nonatomic, assign) BOOL cycleRunning;
@property (nonatomic, assign) double lastWarmUpAt;
@end

@implementation RABEngine

+ (instancetype)shared {
    static RABEngine *e = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [[RABEngine alloc] init]; });
    return e;
}

/* ----------------------------------------------------- token/header capture */

+ (void)observeRequest:(NSURLRequest *)request {
    @try {
        if (!request || !request.URL || !request.URL.host) return;
        NSString *host = request.URL.host.lowercaseString;
        if (![host hasSuffix:@".reddit.com"] && ![host isEqualToString:@"reddit.com"]) return;

        // bearer token (same as v1)
        NSString *auth = [request valueForHTTPHeaderField:@"Authorization"];
        if ([auth isKindOfClass:[NSString class]] && [auth hasPrefix:@"Bearer "]) {
            NSString *tok = [auth substringFromIndex:7];
            if (tok.length >= 20) {
                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                NSString *old = [ud stringForKey:@"rab_bearer_token"];
                if (![tok isEqualToString:old]) {
                    [ud setObject:tok forKey:@"rab_bearer_token"];
                    [ud setDouble:RABNow() forKey:@"rab_bearer_seen_at"];
                    [ud synchronize];
                    [RABLog line:@"captured fresh bearer token (%@…) — replies enabled",
                        [tok substringToIndex:MIN(8, tok.length)]];
                }
            }
        }
        // exact header template of the official app (for our two read GETs)
        if (request.allHTTPHeaderFields.count) {
            [RABNet captureTemplateHeaders:request.allHTTPHeaderFields forURL:request.URL];
        }
    } @catch (NSException *e) { /* never break app traffic */ }
}

/* ------------------------------------------------------------ kill-switch */

+ (void)noteHTTPStatus:(NSInteger)status forURL:(NSURL *)url {
    @try {
        if (!url) return;
        NSString *host = url.host.lowercaseString;
        if (![host hasSuffix:@".reddit.com"] && ![host isEqualToString:@"reddit.com"]) return;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

        if (status == 429 || status == 403) {
            double hours = MAX(1, [[RABConfig shared] doubleForKey:@"killSwitchHours"]);
            if (status == 403) hours *= 2;   // 403 usually means enforcement — double the halt
            double until = RABNow() + hours * 3600;
            [ud setDouble:until forKey:@"rab_kill_until"];
            [ud synchronize];
            [RABLog line:@"⛔ KILL-SWITCH: HTTP %ld — all automation halted for the next %.0f h",
                (long)status, hours];
        } else if (status < 400 && [ud doubleForKey:@"rab_kill_until"] == 0) {
            // healthy response — nothing to do; kill expiry is checked by isKilled
        }
    } @catch (NSException *e) { /* never throw from hooks */ }
}

+ (BOOL)isKilled {
    return [[NSUserDefaults standardUserDefaults] doubleForKey:@"rab_kill_until"] > RABNow();
}

/* ------------------------------------------------------------- caps state */

- (BOOL)capsAvailable {
    RABConfig *cfg = [RABConfig shared];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    // day rollover (device-local day)
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd";
    NSString *today = [f stringFromDate:[NSDate date]];
    if (![today isEqualToString:[ud stringForKey:@"rab_day"]]) {
        [ud setObject:today forKey:@"rab_day"];
        [ud setInteger:0 forKey:@"rab_sent_today"];
    }
    NSMutableArray *hourly = [NSMutableArray arrayWithArray:[ud arrayForKey:@"rab_hourly"] ?: @[]];
    NSMutableArray *fresh = [NSMutableArray array];
    for (id t in hourly) if ([t doubleValue] > RABNow() - 3600) [fresh addObject:t];
    [ud setObject:fresh forKey:@"rab_hourly"];

    NSInteger sentToday = [ud integerForKey:@"rab_sent_today"];
    if (sentToday >= [cfg intForKey:@"dailyCap"]) return NO;
    if ((NSInteger)fresh.count >= [cfg intForKey:@"hourlyCap"]) return NO;
    return YES;
}

- (void)recordSend {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setInteger:[ud integerForKey:@"rab_sent_today"] + 1 forKey:@"rab_sent_today"];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd";
    [ud setObject:[f stringFromDate:[NSDate date]] forKey:@"rab_day"];
    NSMutableArray *hourly = [NSMutableArray arrayWithArray:[ud arrayForKey:@"rab_hourly"] ?: @[]];
    [hourly addObject:@(RABNow())];
    NSMutableArray *fresh = [NSMutableArray array];
    for (id t in hourly) if ([t doubleValue] > RABNow() - 3600) [fresh addObject:t];
    [ud setObject:fresh forKey:@"rab_hourly"];
    [ud synchronize];
}

- (NSInteger)sentThisHour {
    NSInteger n = 0;
    for (id t in [[NSUserDefaults standardUserDefaults] arrayForKey:@"rab_hourly"] ?: @[])
        if ([t doubleValue] > RABNow() - 3600) n++;
    return n;
}

/* ------------------------------------------------------------------- loop */

- (void)start {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSThread setThreadPriority:0.1];
        sleep(25); // let the app launch and start producing traffic (token capture)
        [RABLog line:@"engine v2.0.0 (Ghost) loop started"];
        while (YES) {
            @autoreleasepool {
                @try {
                    [[RABConfig shared] reload];
                    if ([[RABConfig shared] boolForKey:@"enabled"]) {
                        if ([RABEngine isKilled]) {
                            [RABLog line:@"kill-switch active (%.0f min left) — doing nothing",
                                ([[NSUserDefaults standardUserDefaults] doubleForKey:@"rab_kill_until"] - RABNow()) / 60.0];
                        } else {
                            [self warmUpIfDue];
                            [self runCycle];
                        }
                    }
                } @catch (NSException *e) {
                    [RABLog line:@"cycle exception: %@ — %@", e.name, e.reason];
                }
                double iv = MAX(45, [[RABConfig shared] doubleForKey:@"pollIntervalSec"]);
                iv *= RABRand(0.75, 1.35);   // triangular cadence jitter — no two gaps look alike
                RABSleep(iv);
            }
        }
    });
}

/* ---------------------------------------------------------------- warm-up */

- (void)warmUpIfDue {
    RABConfig *cfg = [RABConfig shared];
    double now = RABNow();
    // the interval itself is jittered ±25% on every check — gaps never repeat
    double interval = MAX(60, [cfg doubleForKey:@"warmUpIntervalSec"]) * RABRand(0.75, 1.25);
    if (now - self.lastWarmUpAt < interval) return;
    if (!RABForeground() || [RABGhost chatScreenVisible]) return;
    self.lastWarmUpAt = now;

    // 2–7 swipes (triangular: short bursts are the most common, like real browsing)
    NSInteger swipes = 2 + (NSInteger)RABRand(0.0, 5.0);
    double started = RABNow();
    for (NSInteger i = 0; i < swipes; i++) {
        RABMainSync(^{ [RABGhost scrollFeedWarmUp]; });

        // "read" whatever landed on screen: 0.8–5.5 s, and every ~4th swipe
        // a deeper 4–9 s dwell (people stop on interesting posts)
        double dwell = RABRand(0.8, 5.5);
        if (arc4random_uniform(4) == 0) dwell += RABRand(4.0, 9.0);
        RABSleep(dwell);

        // occasionally scroll back up a little before moving on
        if (arc4random_uniform(100) < 12) {
            RABMainSync(^{ [RABGhost scrollFeedWarmUp]; });
            RABSleep(RABRand(0.5, 2.0));
        }
    }
    [RABLog line:@"warm-up done (%ld swipe(s) in %.1f s)", (long)swipes, RABNow() - started];

    if ([cfg boolForKey:@"idleBreaksEnabled"] &&
        (NSInteger)arc4random_uniform(100) < [cfg intForKey:@"idleBreakChancePct"]) {
        NSInteger lo = MAX(10, [cfg intForKey:@"idleBreakMinSec"]);
        NSInteger hi = MAX(lo, [cfg intForKey:@"idleBreakMaxSec"]);
        NSInteger s = (NSInteger)RABRand((double)lo, (double)hi);
        [RABLog line:@"multi-tasking pause: idle for %lds", (long)s];
        RABSleep((double)s);
    }
}

/* -------------------------------------------------------------- main cycle */

- (void)runCycle {
    if (self.cycleRunning) return;
    RABConfig *cfg = [RABConfig shared];
    @try {
        self.cycleRunning = YES;

        if (![RABNet currentToken].length) return;   // message already logged by RABNet
        if (![cfg stringForKey:@"licensekey"].length) {
            [RABLog line:@"no licensekey — open the 🤖 panel and set it (once)"];
            return;
        }
        if (!RABForeground()) return;                // only chat while the app is actually open

        NSDictionary *unread = [RABNet redditGET:@"/message/unread" params:@{ @"mark" : @"false", @"limit" : @"25" }];
        if (!unread) return;
        NSArray *children = [unread valueForKeyPath:@"data.children"] ?: @[];
        if (!children.count) return;

        NSString *myName = [RABNet currentUserName];
        double now = RABNow();
        NSMutableArray *targets = [NSMutableArray array];
        for (NSDictionary *ch in children) {
            @try {
                if (![ch[@"kind"] isEqualToString:@"t4"]) continue;
                NSDictionary *d = ch[@"data"];
                if (![d isKindOfClass:[NSDictionary class]]) continue;
                if ([d[@"was_chat"] boolValue]) continue;                       // new chat API: unsupported
                NSString *author = [d[@"author"] isKindOfClass:[NSString class]] ? d[@"author"] : nil;
                NSString *name   = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
                if (!author.length || !name.length) continue;
                if (myName && [author isEqualToString:myName]) continue;
                NSString *firstMsg   = [d[@"first_message_name"] isKindOfClass:[NSString class]] ? d[@"first_message_name"] : @"";
                NSString *threadRoot = firstMsg.length ? firstMsg : name;
                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                if ([ud doubleForKey:[@"rab_replied_" stringByAppendingString:name]] > 0) continue;
                if ([ud doubleForKey:[@"rab_dry_" stringByAppendingString:name]] > 0) continue;
                if (now - [ud doubleForKey:[@"rab_thread_" stringByAppendingString:threadRoot]] <
                    [cfg doubleForKey:@"perThreadCooldownMin"] * 60.0) continue;
                [targets addObject:@{
                    @"name"       : name,
                    @"author"     : author,
                    @"threadRoot" : threadRoot,
                    @"body"       : ([d[@"body"] isKindOfClass:[NSString class]] ? d[@"body"] : @""),
                    @"created"    : @([d[@"created_utc"] doubleValue])
                }];
            } @catch (NSException *e) { [RABLog line:@"filter exception: %@", e.reason]; }
        }
        if (!targets.count) return;
        [RABLog line:@"%lu unread item(s) — %lu in scope (caps: today %ld/%ld, hour %ld/%ld)",
            (unsigned long)children.count, (unsigned long)targets.count,
            (long)[[NSUserDefaults standardUserDefaults] integerForKey:@"rab_sent_today"],
            (long)[cfg intForKey:@"dailyCap"], (long)[self sentThisHour], (long)[cfg intForKey:@"hourlyCap"]];

        for (NSDictionary *t in targets) {
            if (![self capsAvailable]) { [RABLog line:@"daily/hourly cap reached — stopping this cycle"]; break; }

            // ---- context + reply text (background thread: network work stays off the UI) ----
            NSArray *hist = [self historyForThreadRoot:t[@"threadRoot"]
                                              myName:myName
                                        fallbackBody:t[@"body"]
                                          fallbackTs:[t[@"created"] doubleValue]];
            if (!hist.count) continue;
            NSDictionary *resp = [RABNet capitalAI:hist
                                           partner:t[@"author"]
                                     convCreatedMs:[[hist.firstObject valueForKeyPath:@"timestamp"] doubleValue] * 1000.0];
            NSArray *pieces = [RABNet textPiecesFromResponse:resp];
            if (!pieces.count) {
                [RABLog line:@"empty CapitalAI response for %@ — skipped", t[@"author"]];
                [self stamp:[@"rab_replied_" stringByAppendingString:t[@"name"]]];
                continue;
            }
            NSString *text = [pieces componentsJoinedByString:@"\n\n"];

            // ---- disclosure (transparent AI) ----
            NSString *discKey  = [@"rab_disclosed_" stringByAppendingString:t[@"threadRoot"]];
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            BOOL firstInThread = ![ud boolForKey:discKey];
            BOOL disclose      = [cfg boolForKey:@"disclosureFirstReplyOnly"] ? firstInThread : YES;
            if (disclose) text = [text stringByAppendingFormat:@"\n\n%@", [cfg stringForKey:@"disclosureText"]];

            // ---- send ----
            if ([cfg boolForKey:@"dryRun"]) {
                [RABLog line:@"[DRYRUN] %@ — would type into the app: %@", t[@"author"], RABPreview(text)];
                [self stamp:[@"rab_dry_" stringByAppendingString:t[@"name"]]];
                continue;
            }
            BOOL ok = [cfg boolForKey:@"ghostOnly"] ? [self ghostReply:t text:text]
                                                    : [self httpReply:t text:text];
            if (ok) {
                [self stamp:[@"rab_thread_" stringByAppendingString:t[@"threadRoot"]]];
                if (disclose) [ud setBool:YES forKey:discKey];
                [self recordSend];
                [RABLog line:@"✅ replied to %@ (%@): %@", t[@"author"], t[@"name"], RABPreview(text)];
                RABSleep(MAX(5, [cfg intForKey:@"minReplyDelaySec"]) * RABRand(0.8, 1.6));
                // occasional multi-tasking pause between active chatting sessions
                if ([cfg boolForKey:@"idleBreaksEnabled"] &&
                    (NSInteger)arc4random_uniform(100) < [cfg intForKey:@"idleBreakChancePct"]) {
                    NSInteger lo = MAX(10, [cfg intForKey:@"idleBreakMinSec"]);
                    NSInteger hi = MAX(lo, [cfg intForKey:@"idleBreakMaxSec"]);
                    NSInteger s = (NSInteger)RABRand((double)lo, (double)hi);
                    [RABLog line:@"pause between sessions: idle %lds", (long)s];
                    RABSleep((double)s);
                }
            } else {
                [self stamp:[@"rab_replied_" stringByAppendingString:t[@"name"]]];
            }
        }
    } @catch (NSException *e) {
        [RABLog line:@"runCycle exception: %@ — %@", e.name, e.reason];
    } @finally {
        self.cycleRunning = NO;
    }
}

- (void)stamp:(NSString *)key {
    [[NSUserDefaults standardUserDefaults] setDouble:RABNow() forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/* -------------------------------------------------------- thread history */

- (NSArray *)historyForThreadRoot:(NSString *)threadRoot myName:(NSString *)myName
                     fallbackBody:(NSString *)fallbackBody fallbackTs:(double)fallbackTs {
    NSMutableArray *msgs = [NSMutableArray array];
    NSString *id35 = [threadRoot stringByReplacingOccurrencesOfString:@"t4_" withString:@""];
    NSDictionary *thread = [RABNet redditGET:[NSString stringWithFormat:@"/message/messages/%@", id35]
                                      params:@{ @"mark" : @"false", @"limit" : @"100" }];
    for (NSDictionary *ch in [thread valueForKeyPath:@"data.children"] ?: @[]) {
        NSDictionary *d = ch[@"data"];
        if ([d isKindOfClass:[NSDictionary class]] && [d[@"body"] isKindOfClass:[NSString class]]) [msgs addObject:d];
    }
    if (!msgs.count) {
        [RABLog line:@"thread fetch for %@ empty — using the single unread message", threadRoot];
        return @[ @{ @"role" : @"user", @"content" : fallbackBody ?: @"", @"timestamp" : @((NSInteger)fallbackTs) } ];
    }
    [msgs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[a valueForKeyPath:@"created_utc"] doubleValue] > [[b valueForKeyPath:@"created_utc"] doubleValue];
    }];
    NSMutableArray *hist = [NSMutableArray array];
    for (NSDictionary *d in msgs) {
        NSString *role = (myName && [d[@"author"] isEqualToString:myName]) ? @"bot" : @"user";
        [hist addObject:@{
            @"role"      : role,
            @"content"   : d[@"body"] ?: @"",
            @"timestamp" : @((NSInteger)[d[@"created_utc"] doubleValue])
        }];
    }
    NSInteger lim = MAX(4, [[RABConfig shared] intForKey:@"historyLimit"]);
    if ((NSInteger)hist.count > lim) hist = [[hist subarrayWithRange:NSMakeRange(hist.count - lim, lim)] mutableCopy];
    return hist;
}

/* ------------------------------------------------------------ send paths */

/** Direct-HTTP fallback (ghostOnly = NO). Ban risk — kept for emergencies. */
- (BOOL)httpReply:(NSDictionary *)t text:(NSString *)text {
    BOOL ok = [RABNet redditPostReply:t[@"name"] text:text];
    if (ok) [RABNet redditMarkRead:t[@"name"]];
    return ok;
}

/** Ghost path: drive the app's UI. Returns when the flow finished (or 240 s). */
- (BOOL)ghostReply:(NSDictionary *)t text:(NSString *)text {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ghostFlowMain:t text:text completion:^(BOOL finished) {
            ok = finished;
            dispatch_semaphore_signal(sem);
        }];
    });
    long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(240 * NSEC_PER_SEC)));
    if (r != 0) { [RABLog line:@"ghost flow timeout (240 s) for %@", t[@"author"]]; return NO; }
    return ok;
}

static void RABDelayMain(double seconds, void (^block)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

/// Runs ON MAIN THREAD. Navigate → wait for composer → think → type → send → back.
- (void)ghostFlowMain:(NSDictionary *)t text:(NSString *)text completion:(void (^)(BOOL))done {
    RABConfig *cfg = [RABConfig shared];
    NSString *author = t[@"author"];
    BOOL navigate = [cfg boolForKey:@"autoNavigate"];

    void (^finish)(BOOL) = ^(BOOL ok) { if (done) done(ok); };

    void (^beginTyping)(void) = ^{
        UIView *composer = [RABGhost composerView];
        if (!composer) { [RABLog line:@"ghost: no composer visible for %@ — aborting", author]; finish(NO); return; }
        // randomized "thinking" delay before typing starts (3–12 s by default)
        NSInteger thinkMin = MAX(0, [cfg intForKey:@"thinkDelayMinSec"]);
        NSInteger thinkMax = MAX(thinkMin, [cfg intForKey:@"thinkDelayMaxSec"]);
        double think = RABRand((double)thinkMin, (double)MAX(thinkMin, thinkMax));
        RABDelayMain(think, ^{
            [RABGhost typeText:text
                  intoComposer:composer
                    msPerChar:[cfg intForKey:@"typingMsPerChar"]
                       haptics:[cfg boolForKey:@"typingHaptics"]
                    completion:^(BOOL typed) {
                if (!typed) { finish(NO); return; }
                RABDelayMain(0.6 + (double)arc4random_uniform(900) / 1000.0, ^{
                    UIView *send = [RABGhost findSendButtonNearComposer:composer];
                    if (!send) {
                        [RABLog line:@"ghost: Send button not found — enable Discovery mode and check a11y labels (config: labelSend)"];
                        finish(NO);
                        return;
                    }
                    if (![RABGhost activateView:send]) { finish(NO); return; }
                    [RABLog line:@"ghost: Send pressed for %@", author];
                    RABDelayMain(RABRand(2.5, 4.5), ^{
                        if (navigate) {
                            UIView *back = [RABGhost findBackButton];
                            if (back) [RABGhost activateView:back];
                            else [RABLog line:@"ghost: back button not found — leaving the chat open (config: labelBack)"];
                            RABDelayMain(1.5, ^{ finish(YES); });
                        } else {
                            finish(YES);
                        }
                    });
                });
            }];
        });
    };

    if (navigate) {
        if (![RABGhost chatScreenVisible]) {
            // 1) open the Chat tab
            UIView *tab = [RABGhost findTabBarItemWithLabel:[cfg stringForKey:@"labelChatTab"]];
            if (tab) [RABGhost activateView:tab];
            else [RABLog line:@"ghost: Chat tab not found (config: labelChatTab) — trying the inbox anyway"];
            // 2) open the target conversation cell
            RABDelayMain(RABRand(2.0, 4.5), ^{
                UIView *cell = [RABGhost findCellContainingName:author];
                if (!cell) { [RABLog line:@"ghost: inbox cell for %@ not found (is the inbox list visible?)", author]; finish(NO); return; }
                [RABGhost activateView:cell];
                // 3) wait for the chat screen to appear (up to ~10 s)
                [self waitForComposerTries:16 completion:^(BOOL found) {
                    if (!found) { [RABLog line:@"ghost: composer never appeared for %@", author]; finish(NO); return; }
                    beginTyping();
                }];
            });
        } else {
            beginTyping();   // right chat already open → reply directly
        }
    } else {
        if (![RABGhost chatScreenVisible]) {
            [RABLog line:@"ghost: autoNavigate off and no chat open — open the chat first"];
            finish(NO);
            return;
        }
        beginTyping();
    }
}

- (void)waitForComposerTries:(NSInteger)tries completion:(void (^)(BOOL))done {
    if (tries <= 0) { if (done) done(NO); return; }
    RABDelayMain(0.6, ^{
        if ([RABGhost chatScreenVisible]) { if (done) done(YES); return; }
        [self waitForComposerTries:tries - 1 completion:done];
    });
}

/* ---------------------------------------------------------- panel actions */

- (void)forceCycle {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [RABLog line:@"manual cycle requested from panel"];
        [self runCycle];
    });
}

- (void)testTyping {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *c = [RABGhost composerView];
        if (!c) { [RABLog line:@"typing test: open any chat first"]; return; }
        RABConfig *cfg = [RABConfig shared];
        [RABGhost typeText:@"Hi! 🙂 (typing simulation test — nothing will be sent)"
              intoComposer:c
                msPerChar:[cfg intForKey:@"typingMsPerChar"]
                   haptics:[cfg boolForKey:@"typingHaptics"]
                completion:^(BOOL ok) {
            [RABLog line:@"typing test finished (ok=%d) — nothing was sent", ok];
        }];
    });
}

- (NSString *)statusLine {
    RABConfig *cfg = [RABConfig shared];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    double killUntil = [ud doubleForKey:@"rab_kill_until"];
    NSString *state;
    if (killUntil > RABNow()) {
        state = [NSString stringWithFormat:@"⛔ KILL-SWITCH (%.0f min left)", (killUntil - RABNow()) / 60.0];
    } else if (self.cycleRunning) {
        state = @"working…";
    } else {
        state = [RABGhost chatScreenVisible] ? @"chat open" : @"idle";
    }
    return [NSString stringWithFormat:@"%@ · today %ld/%ld · hour %ld/%ld · ghost=%@ dry=%@ token=%@",
        state,
        (long)[ud integerForKey:@"rab_sent_today"], (long)[cfg intForKey:@"dailyCap"],
        (long)[self sentThisHour], (long)[cfg intForKey:@"hourlyCap"],
        [cfg boolForKey:@"ghostOnly"] ? @"ON" : @"off",
        [cfg boolForKey:@"dryRun"] ? @"ON" : @"off",
        [RABNet currentToken].length ? @"ok" : @"none"];
}

@end
