#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * RABGhost — UI-level automation ("Ghost user" method).
 *
 * Instead of calling Reddit's private send endpoints over HTTP (easily
 * flagged by server-side anomaly detection), the engine drives the OFFICIAL
 * app's own UI: focus the chat composer, type humanized text (native typing
 * indicators fire for free), then press the real Send button. Every
 * telemetry event, tracking beacon, header and TLS fingerprint the app
 * normally emits during a human chat session is emitted identically.
 *
 * All methods MUST be called on the main thread unless noted.
 */
@interface RABGhost : NSObject

/* ---- state probes ---- */
+ (BOOL)chatScreenVisible;                 ///< composer present → a chat thread is open
+ (nullable UIView *)composerView;         ///< the visible chat text input, or nil
+ (nullable NSString *)visibleThreadHint;  ///< best-effort author/title hint of the open chat

/* ---- actions ---- */
+ (void)typeText:(NSString *)text
    intoComposer:(UIView *)composer
      msPerChar:(NSInteger)msPerChar
         haptics:(BOOL)haptics
      completion:(void (^)(BOOL ok))done;  ///< humanized typing; completion on main thread

+ (BOOL)activateView:(nullable UIView *)view;              ///< multi-strategy "tap"
+ (void)scrollFeedWarmUp;                                  ///< one simulated feed scroll
+ (void)dumpHierarchy;                                     ///< discovery: view tree → syslog

/* ---- finders (heuristic, adaptive labels from RABConfig) ---- */
+ (nullable UIView *)findTabBarItemWithLabel:(NSString *)label;
+ (nullable UIView *)findCellContainingName:(NSString *)name;
+ (nullable UIView *)findSendButtonNearComposer:(nullable UIView *)composer;
+ (nullable UIView *)findBackButton;

@end

NS_ASSUME_NONNULL_END
