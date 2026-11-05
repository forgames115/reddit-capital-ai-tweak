#import <Foundation/Foundation.h>
#import <stdlib.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * RABRand — triangular random in [min,max] (average of two uniforms).
 * Everything the tweak randomizes uses this instead of a flat uniform:
 * the resulting cadence clusters around the middle of each range the way
 * real human behavior does (no suspicious uniform plateaus).
 */
static inline double RABRand(double min, double max) {
    if (max <= min) return min;
    double r1 = (double)arc4random() / 4294967296.0;
    double r2 = (double)arc4random() / 4294967296.0;
    return min + ((r1 + r2) / 2.0) * (max - min);
}

/**
 * RABConfig — all tweak settings.
 * Read from /var/mobile/Library/Preferences/com.capitalai.redditbridge.plist
 * on EVERY access cycle (edits apply without respring); the floating options
 * panel writes straight into the same plist.
 * Unknown / missing keys fall back to the defaults below.
 */
@interface RABConfig : NSObject

+ (instancetype)shared;
- (void)reload;
- (BOOL)boolForKey:(NSString *)key;
- (NSInteger)intForKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;   // writes + persists the plist
- (NSDictionary *)allValues;
- (NSString *)plistPath;

@end

NS_ASSUME_NONNULL_END
