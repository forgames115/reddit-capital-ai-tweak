#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** In-memory ring-buffer logger — surfaced in the floating options panel. */
@interface RABLog : NSObject
+ (void)line:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
+ (NSArray<NSString *> *)tail:(NSUInteger)count;
+ (void)clear;
@end

NS_ASSUME_NONNULL_END
