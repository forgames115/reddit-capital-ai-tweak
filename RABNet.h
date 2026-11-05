#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * RABNet — network layer.
 *
 * READ-ONLY towards Reddit: the Ghost engine only ever GETs the unread list
 * and thread history. Sends go through the app's own UI (RABGhost) so every
 * outbound message rides the official app's network stack — real headers,
 * real TLS fingerprint, real telemetry. A direct-HTTP POST fallback exists
 * for emergencies but is OFF by default (ghostOnly = YES).
 *
 * Header replication: Tweak.x feeds every request the official app makes
 * into captureTemplateHeaders:forURL: — we keep the app's exact header set
 * (User-Agent, X-Reddit-* / device identifiers…) minus Authorization/Host/
 * Content-Length/Cookie, and replay it verbatim on our two read endpoints,
 * adding only the current Bearer token.
 */
@interface RABNet : NSObject

+ (void)captureTemplateHeaders:(nullable NSDictionary *)headers forURL:(nullable NSURL *)url;
+ (NSDictionary *)templateHeaders;
+ (nullable NSString *)currentToken;

/** oauth.reddit.com GET → parsed JSON dict or nil. Status codes feed the kill-switch. */
+ (nullable NSDictionary *)redditGET:(NSString *)path params:(nullable NSDictionary *)params;

/** Direct-HTTP reply fallback — ONLY used when ghostOnly = NO (ban risk!). */
+ (BOOL)redditPostReply:(NSString *)t4name text:(NSString *)text;
+ (void)redditMarkRead:(NSString *)t4name;

/** CapitalAI /generateResponse — same payload as the Chrome extension. */
+ (nullable NSDictionary *)capitalAI:(NSArray *)chatHistory partner:(nullable NSString *)author convCreatedMs:(double)convCreatedMs;

/** Normalize one CapitalAI response into sendable text pieces:
 *  dedupe, drop media pieces, v1.9.4 grounding guard (nothing after a
 *  '?'-ending piece), capped to maxPiecesPerReply. */
+ (NSArray<NSString *> *)textPiecesFromResponse:(nullable NSDictionary *)resp;

/** Cached /api/v1/me → username. */
+ (nullable NSString *)currentUserName;

@end

NS_ASSUME_NONNULL_END
