#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * RABEngine — orchestrator ("Ghost" architecture).
 *
 * Loop (background serial, only while the Reddit app is alive):
 *   1. kill-switch / caps check
 *   2. READ-ONLY: GET /message/unread (headers replicated from the app)
 *   3. per target: thread history → CapitalAI → disclosure → ghost send
 *      (type into the real composer + press the real Send button)
 *   4. warm-up feed scroll / idle breaks between sessions
 */
@interface RABEngine : NSObject

/// Singleton — Tweak.x calls [[RABEngine shared] start] once at injection.
+ (instancetype)shared;

- (void)start;

/// Called from Tweak.x for every outbound URLSession task of the host app:
/// captures the bearer token + exact header template. Cheap, read-only.
+ (void)observeRequest:(nullable NSURLRequest *)request;

/// Called for every visible HTTP response (our reads + wrapped app completions).
/// 429 → kill-switch for killSwitchHours; 403 → double. Success resets the streak.
+ (void)noteHTTPStatus:(NSInteger)status forURL:(nullable NSURL *)url;

/// Panel actions.
- (void)forceCycle;        ///< run one cycle immediately
- (void)testTyping;        ///< type a test string into the open composer (no send)
- (NSString *)statusLine;  ///< one-line state for the options panel

@end

NS_ASSUME_NONNULL_END
