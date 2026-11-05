#import "RABConfig.h"

static NSString * const kPlistPath = @"/var/mobile/Library/Preferences/com.capitalai.redditbridge.plist";

@interface RABConfig ()
@property (nonatomic, strong) NSMutableDictionary *vals;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation RABConfig

+ (instancetype)shared {
    static RABConfig *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[RABConfig alloc] init]; });
    return c;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init];
        _vals = [NSMutableDictionary dictionary];
        [self reload];
    }
    return self;
}

- (NSString *)plistPath { return kPlistPath; }

- (NSDictionary *)defaults {
    return @{
        // ---- master switches -------------------------------------------------
        @"enabled"             : @YES,   // master switch
        @"dryRun"              : @YES,   // SAFE DEFAULT: log what would be typed, send nothing
        @"debug"               : @YES,   // verbose syslog
        @"discoveryMode"       : @NO,    // dump the view hierarchy to syslog (panel toggle)
        // ---- behavior mode ---------------------------------------------------
        @"ghostOnly"           : @YES,   // replies ONLY through the app UI (v1-style HTTP sends off)
        @"autoNavigate"        : @YES,   // swap chats automatically: tab -> inbox cell -> chat -> back
        // ---- human simulation ------------------------------------------------
        @"typingHaptics"       : @YES,   // light impact haptic while "typing"
        @"typingMsPerChar"     : @180,   // average ms per character (jittered ±30%)
        @"thinkDelayMinSec"    : @3,     // "thinking" pause before typing starts
        @"thinkDelayMaxSec"    : @12,
        @"warmUpEnabled"       : @YES,   // simulated feed scrolling while idle
        @"warmUpIntervalSec"   : @300,   // ~every 5 min (user request)
        @"idleBreaksEnabled"   : @YES,   // occasional 1-2 min "reading" breaks between sessions
        @"idleBreakChancePct"  : @25,
        @"idleBreakMinSec"     : @60,
        @"idleBreakMaxSec"     : @120,
        // ---- rate limiting (the anti-ban core) --------------------------------
        @"pollIntervalSec"     : @180,   // unread check cadence (jittered ±20%)
        @"dailyCap"            : @40,    // max replies / 24 h window
        @"hourlyCap"           : @8,     // max replies / sliding hour
        @"perThreadCooldownMin": @10,    // same thread revisited after >= this
        @"minReplyDelaySec"    : @20,    // pause between two replies in one cycle
        @"killSwitchHours"     : @12,    // halt length after 429/403 streak
        // ---- CapitalAI / content ---------------------------------------------
        @"maxPiecesPerReply"   : @2,     // joined into ONE message (no double posts)
        @"historyLimit"        : @20,
        @"disclosureFirstReplyOnly" : @YES,
        @"disclosureText"      : @"— *I'm an AI companion (this account replies automatically via an AI assistant). Not a real person — tell me if you'd rather I stop replying.*",
        @"detectLanguage"      : @YES,
        @"language"            : @"English",
        @"timezone"            : @"Europe/Prague",
        @"platform"            : @"Reddit",
        @"licensekey"          : @"",
        @"modelId"             : @1,
        @"presetId"            : @1,
        @"accountId"           : @"",
        // ---- adaptive UI labels (adjust if your app language differs) ---------
        @"labelChatTab"        : @"Chat",     // bottom tab bar item
        @"labelSend"           : @"Send",     // composer send button a11y label
        @"labelBack"           : @"Back"      // chat back button a11y label
    };
}

- (void)reload {
    [self.lock lock];
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
        self.vals = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
    } @finally { [self.lock unlock]; }
}

- (id)valueForKey:(NSString *)key {
    [self.lock lock];
    @try {
        if (!key) return nil;
        id v = self.vals[key];
        if (!v) v = [self defaults][key];
        return v;
    } @finally { [self.lock unlock]; }
}

- (BOOL)boolForKey:(NSString *)key          { return [[self valueForKey:key] boolValue]; }
- (NSInteger)intForKey:(NSString *)key      { return [[self valueForKey:key] integerValue]; }
- (double)doubleForKey:(NSString *)key      { return [[self valueForKey:key] doubleValue]; }
- (NSString *)stringForKey:(NSString *)key  { return [NSString stringWithFormat:@"%@", [self valueForKey:key] ?: @""]; }

- (void)setObject:(id)value forKey:(NSString *)key {
    [self.lock lock];
    @try {
        if (!key || !value) return;
        self.vals[key] = value;
        [self.vals writeToFile:kPlistPath atomically:YES];
    } @catch (NSException *e) {
        NSLog(@"[RAB] config save failed: %@", e.reason);
    } @finally { [self.lock unlock]; }
}

- (NSDictionary *)allValues {
    [self.lock lock];
    @try {
        NSMutableDictionary *merged = [[self defaults] mutableCopy];
        [merged addEntriesFromDictionary:self.vals];
        return [merged copy];
    } @finally { [self.lock unlock]; }
}

@end
