#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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
