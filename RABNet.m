#import "RABNet.h"
#import "RABConfig.h"
#import "RABLog.h"
#import "RABEngine.h"
#import <unistd.h>

#define RAB_UA_FALLBACK @"ios:com.capitalai.redditbridge:v2.0 (personal AI-companion automation)"

static NSString * const kTok    = @"rab_bearer_token";
static NSString * const kHdrTpl = @"rab_hdr_template";
static NSString * const kMeName = @"rab_me_name";
static NSString * const kMeAt   = @"rab_me_name_at";

static NSString *RABUrlEncode(NSString *s) {
    if (!s) return @"";
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static NSString *RABPreview(NSString *s) {
    if (s.length > 90) return [[s substringToIndex:90] stringByAppendingString:@"…"];
    return s ?: @"";
}

@implementation RABNet

/* ------------------------------------------------- header template capture */

+ (void)captureTemplateHeaders:(NSDictionary *)headers forURL:(NSURL *)url {
    @try {
        if (!headers.count || !url) return;
        NSString *host = url.host.lowercaseString;
        if (![host hasSuffix:@".reddit.com"] && ![host isEqualToString:@"reddit.com"]) return;

        NSMutableDictionary *tpl = [NSMutableDictionary dictionary];
        for (NSString *k in headers) {
            NSString *lk = k.lowercaseString;
            // never persist credentials / per-request framing headers
            if ([lk isEqualToString:@"authorization"] || [lk isEqualToString:@"content-length"] ||
                [lk isEqualToString:@"host"] || [lk isEqualToString:@"cookie"] ||
                [lk isEqualToString:@"if-none-match"] || [lk isEqualToString:@"accept-encoding"]) continue;
            tpl[k] = [NSString stringWithFormat:@"%@", headers[k]];
        }
        if (!tpl.count) return;
        NSData *d = [NSJSONSerialization dataWithJSONObject:tpl options:0 error:nil];
        if (!d) return;
        NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if (![json isEqualToString:[ud stringForKey:kHdrTpl]]) {
            [ud setObject:json forKey:kHdrTpl];
            [ud synchronize];
            [RABLog line:@"captured app header template (%lu headers, UA=%@)", (unsigned long)tpl.count,
                tpl[@"User-Agent"] ?: tpl[@"user-agent"] ?: @"?"];
        }
    } @catch (NSException *e) { /* never break app traffic */ }
}

+ (NSDictionary *)templateHeaders {
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:kHdrTpl];
    if (!s.length) return @{};
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [o isKindOfClass:[NSDictionary class]] ? o : @{};
}

+ (NSString *)currentToken {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kTok];
}

/* ------------------------------------------------------------ reddit GETs */

+ (NSDictionary *)redditGET:(NSString *)path params:(NSDictionary *)params {
    NSString *token = [self currentToken];
    if (!token.length) { [RABLog line:@"no bearer token yet — open the Reddit app once so the tweak captures it"]; return nil; }

    NSString *query = @"";
    if (params.count) {
        NSMutableArray *ps = [NSMutableArray array];
        for (NSString *k in params) {
            [ps addObject:[NSString stringWithFormat:@"%@=%@", RABUrlEncode(k), RABUrlEncode([NSString stringWithFormat:@"%@", params[k]])]];
        }
        query = [@"?" stringByAppendingString:[ps componentsJoinedByString:@"&"]];
    }
    NSURL *url = [NSURL URLWithString:[@"https://oauth.reddit.com" stringByAppendingString:[path stringByAppendingString:query]]];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod      = @"GET";
    req.timeoutInterval = 45;

    // Header replication: the app's own captured headers, verbatim.
    [[self templateHeaders] enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        [req setValue:v forHTTPHeaderField:[NSString stringWithFormat:@"%@", k]];
    }];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (![req valueForHTTPHeaderField:@"User-Agent"].length) [req setValue:RAB_UA_FALLBACK forHTTPHeaderField:@"User-Agent"];

    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    if (err || !data) { [RABLog line:@"GET %@ failed: %@", path, err.localizedDescription ?: @"empty"]; return nil; }
    NSInteger status = resp.statusCode;
    [RABEngine noteHTTPStatus:status forURL:url];
    if (status == 401) { [RABLog line:@"token expired (401) — open the app to refresh; idling"]; return nil; }
    if (status >= 400) { [RABLog line:@"GET %@ HTTP %ld", path, (long)status]; return nil; }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

/* --------------------------------------------- direct-HTTP fallback (opt-in) */

+ (BOOL)redditPostReply:(NSString *)t4name text:(NSString *)text {
    if (!t4name.length || !text.length) return NO;
    NSDictionary *resp = [self redditCallPOST:@"/api/comment"
                                         form:[NSString stringWithFormat:@"api_type=json&thing_id=%@&text=%@",
                                               RABUrlEncode(t4name), RABUrlEncode(text)]];
    if (!resp) return NO;
    NSArray *errors = [resp valueForKeyPath:@"json.errors"] ?: @[];
    if (errors.count) { [RABLog line:@"/api/comment errors: %@", errors]; return NO; }
    return YES;
}

+ (void)redditMarkRead:(NSString *)t4name {
    if (!t4name.length) return;
    [self redditCallPOST:@"/api/read_message"
                    form:[NSString stringWithFormat:@"id=%@", RABUrlEncode(t4name)]];
}

+ (NSDictionary *)redditCallPOST:(NSString *)path form:(NSString *)form {
    NSString *token = [self currentToken];
    if (!token.length) return nil;
    NSURL *url = [NSURL URLWithString:[@"https://oauth.reddit.com" stringByAppendingString:path]];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 45;
    req.HTTPBody        = [form dataUsingEncoding:NSUTF8StringEncoding];
    [[self templateHeaders] enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        [req setValue:v forHTTPHeaderField:[NSString stringWithFormat:@"%@", k]];
    }];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    if (err || !data) { [RABLog line:@"POST %@ failed: %@", path, err.localizedDescription ?: @"empty"]; return nil; }
    [RABEngine noteHTTPStatus:resp.statusCode forURL:url];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

/* ---------------------------------------------------------------- CapitalAI */

+ (NSDictionary *)capitalAI:(NSArray *)chatHistory partner:(NSString *)author convCreatedMs:(double)convCreatedMs {
    RABConfig *cfg = [RABConfig shared];
    BOOL detect = [cfg boolForKey:@"detectLanguage"];
    NSMutableDictionary *body = [@{
        @"licensekey"           : [cfg stringForKey:@"licensekey"],
        @"modelId"              : @([cfg intForKey:@"modelId"]),
        @"presetId"             : @([cfg intForKey:@"presetId"]),
        @"accountId"            : [cfg stringForKey:@"accountId"],
        @"platform"             : [cfg stringForKey:@"platform"] ?: @"Reddit",
        @"conversationSource"   : @"Reddit",
        @"timezone"             : [cfg stringForKey:@"timezone"],
        @"detectLanguage"       : @(detect),
        @"audio"                : @NO,   // the bot never SENDS media (extension parity)
        @"video"                : @NO,
        @"image"                : @NO,
        @"conversationCreatedAt": @((NSInteger)convCreatedMs),
        @"userInfos"            : @{ @"useridentifier" : (author ?: @"unknown"), @"name" : (author ?: @"unknown") },
        @"chatHistory"          : chatHistory ?: @[]
    } mutableCopy];
    if (!detect) body[@"language"] = [cfg stringForKey:@"language"];

    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!json) { [RABLog line:@"CapitalAI payload serialization failed"]; return nil; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.capitalbot.ai/generateResponse"]];
    if (!req) return nil;
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 90;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = json;

    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    if (err || !data) { [RABLog line:@"CapitalAI failed: %@", err.localizedDescription ?: @"empty"]; return nil; }
    if (resp.statusCode != 200) {
        [RABLog line:@"CapitalAI HTTP %ld: %@", (long)resp.statusCode,
            RABPreview([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"")];
        return nil;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        [RABLog line:@"CapitalAI ok (history=%lu)", (unsigned long)chatHistory.count];
        return obj;
    }
    return nil;
}

+ (NSArray<NSString *> *)textPiecesFromResponse:(NSDictionary *)resp {
    RABConfig *cfg = [RABConfig shared];
    id raw = resp[@"content"];
    NSMutableArray *out = [NSMutableArray array];
    if ([raw isKindOfClass:[NSString class]]) {
        NSString *s = raw;
        if (s.length) [out addObject:s];
    } else if ([raw isKindOfClass:[NSArray class]]) {
        for (id p in raw) {
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            NSString *c = [p[@"content"] isKindOfClass:[NSString class]] ? p[@"content"] : nil;
            if (!c.length) continue;
            NSString *type = [p[@"type"] isKindOfClass:[NSString class]] ? p[@"type"] : @"text";
            if ([type isEqualToString:@"image"] || [type isEqualToString:@"video"] || [type isEqualToString:@"audio"]) continue;
            [out addObject:c];
        }
    }
    // dedupe
    NSMutableArray *dedup = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *s in out) {
        NSString *key = [s lowercaseString];
        if (key.length > 120) key = [key substringToIndex:120];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [dedup addObject:s];
    }
    // v1.9.4 grounding guard: the bot's turn ends at its first question
    NSMutableArray *final = [NSMutableArray array];
    for (NSString *s in dedup) {
        [final addObject:s];
        if ([self endsWithQuestion:s]) break;
    }
    NSInteger cap = MAX(1, [cfg intForKey:@"maxPiecesPerReply"]);
    if ((NSInteger)final.count > cap) final = [[final subarrayWithRange:NSMakeRange(0, cap)] mutableCopy];
    return final;
}

+ (BOOL)endsWithQuestion:(NSString *)s {
    if (!s.length) return NO;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return NO;
    unichar c = [t characterAtIndex:t.length - 1];
    return (c == '?') || (c == 0xFF1F);
}

/* -------------------------------------------------------------------- /me */

+ (NSString *)currentUserName {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *cached = [ud stringForKey:kMeName];
    if (cached.length && [[NSDate date] timeIntervalSince1970] - [ud doubleForKey:kMeAt] < 3600) return cached;
    NSDictionary *me = [self redditGET:@"/api/v1/me" params:nil];
    NSString *name = [me valueForKeyPath:@"data.name"];
    if ([name isKindOfClass:[NSString class]] && name.length) {
        [ud setObject:name forKey:kMeName];
        [ud setDouble:[[NSDate date] timeIntervalSince1970] forKey:kMeAt];
        [ud synchronize];
        return name;
    }
    return cached;
}

@end
