#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * RABPanel — floating options bubble ("options bubble where I can choose how
 * many requests I can accept").
 *
 * A draggable 🤖 bubble floats over the Reddit app. Tapping it opens a panel
 * with: master switch, dry-run, ghost mode, auto chat-swap, haptics, warm-up,
 * idle breaks, discovery mode, caps (daily / hourly / per-thread cooldown /
 * poll interval / typing speed), license key + accountId, engine status,
 * live log tail, force-cycle / dump-UI / typing-test buttons.
 * Every change is written to the config plist immediately (no respring).
 */
@interface RABPanel : NSObject
/// Call on the main thread, after the app finished launching.
+ (void)install;
+ (void)showPanel;
+ (void)hidePanel;
+ (BOOL)panelVisible;
@end

NS_ASSUME_NONNULL_END
