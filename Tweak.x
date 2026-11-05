/**
 * Tweak.x — RedditAIBridge v2.0.0 ("Ghost")
 * Companion iOS tweak to the capitalai-amateri Chrome extension.
 *
 * Runs inside the Reddit iOS app (com.reddit.Reddit) and:
 *   1. Observes the app's own network tasks — captures the OAuth bearer token
 *      and the EXACT header template the official app uses (User-Agent,
 *      X-Reddit-* and device identifiers) so the two read-only GETs the
 *      engine makes are byte-for-byte indistinguishable from app traffic.
 *   2. Watches response status codes — 429/403 trigger the kill-switch.
 *   3. Sends replies by driving the app's own UI: type into the real chat
 *      composer (native typing indicators fire for free) and press the real
 *      Send button. No private send endpoints, no custom network stack,
 *      no TLS spoofing needed — the app IS the client.
 *   4. Installs a floating 🤖 options bubble (caps, delays, kill-switch,
 *      discovery mode, logs) after the app finishes launching.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "RABEngine.h"
#import "RABPanel.h"

/* Private CFNetwork task classes — not publicly declared. */
@interface __NSCFLocalSessionTask : NSURLSessionTask
@end
@interface __NSCFURLSessionTask : NSURLSessionTask
@end

static BOOL RABIsRedditURL(NSURL *url) {
    if (!url || !url.host) return NO;
    NSString *host = url.host.lowercaseString;
    return [host hasSuffix:@".reddit.com"] || [host isEqualToString:@"reddit.com"];
}

%group GeneralHooks
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    [RABEngine observeRequest:request];
    if (request && completionHandler && RABIsRedditURL(request.URL)) {
        NSURL *url = request.URL;
        void (^orig)(NSData *, NSURLResponse *, NSError *) = completionHandler;
        return %orig(request, ^(NSData *data, NSURLResponse *response, NSError *error) {
            @try {
                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    [RABEngine noteHTTPStatus:((NSHTTPURLResponse *)response).statusCode forURL:url];
                }
            } @catch (NSException *e) { /* never break the app */ }
            if (orig) orig(data, response, error);
        });
    }
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    [RABEngine observeRequest:request];
    return %orig;
}
%end
%end

%group LocalTaskHooks
%hook __NSCFLocalSessionTask
- (void)resume {
    [RABEngine observeRequest:self.originalRequest];
    %orig;
}
%end
%end

%group CFURLTaskHooks
%hook __NSCFURLSessionTask
- (void)resume {
    [RABEngine observeRequest:self.originalRequest];
    %orig;
}
%end
%end

%ctor {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.reddit.Reddit"]) return;

        %init(GeneralHooks);
        if (objc_getClass("__NSCFLocalSessionTask")) %init(LocalTaskHooks);
        if (objc_getClass("__NSCFURLSessionTask"))   %init(CFURLTaskHooks);

        [[RABEngine shared] start];

        // floating options bubble once the UI is up
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [RABPanel install];
        });
        NSLog(@"[RAB] RedditAIBridge v2.0.0 (Ghost) loaded — engine + hooks installed");
    } @catch (NSException *e) {
        NSLog(@"[RAB] ctor exception: %@ — %@", e.name, e.reason);
    }
}
