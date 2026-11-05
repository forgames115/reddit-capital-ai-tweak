#import "RABLog.h"

#define RAB_MAX_LINES 250

static NSMutableArray *rabLines = nil;
static NSLock *rabLock = nil;

__attribute__((constructor)) static void RABLogBoot(void) {
    if (!rabLines) rabLines = [NSMutableArray array];
    if (!rabLock) rabLock = [[NSLock alloc] init];
}

@implementation RABLog

+ (void)line:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[RAB] %@", msg);
    if (!rabLock || !rabLines) return;
    [rabLock lock];
    @try {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"HH:mm:ss";
        [rabLines addObject:[NSString stringWithFormat:@"%@  %@", [f stringFromDate:[NSDate date]], msg]];
        if (rabLines.count > RAB_MAX_LINES) [rabLines removeObjectsInRange:NSMakeRange(0, rabLines.count - RAB_MAX_LINES)];
    } @finally { [rabLock unlock]; }
}

+ (NSArray<NSString *> *)tail:(NSUInteger)count {
    if (!rabLock || !rabLines) return @[];
    [rabLock lock];
    @try {
        NSUInteger s = rabLines.count > count ? rabLines.count - count : 0;
        return [rabLines subarrayWithRange:NSMakeRange(s, rabLines.count - s)];
    } @finally { [rabLock unlock]; }
}

+ (void)clear {
    if (!rabLock || !rabLines) return;
    [rabLock lock];
    @try { [rabLines removeAllObjects]; } @finally { [rabLock unlock]; }
}

@end
