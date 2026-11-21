/*
 * STBConfig.m — settings + logging helpers.
 *
 * SAFETY NOTE: this tweak never submits entries and never modifies game
 * state. These settings only control diagnostics (capture, overlay, logs).
 */
#import "STBConfig.h"
#import <Foundation/Foundation.h>

NSString * const STBTweakLogPrefix = @"[BOTBTweak]";

static STBConfig *_instance = nil;

@implementation STBConfig

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _instance = [[STBConfig alloc] init];
        NSDictionary *d = [[NSUserDefaults standardUserDefaults]
                           dictionaryRepresentation];
        _instance.enabled        = d[@"stbtweak_enabled"]  ? [d[@"stbtweak_enabled"] boolValue]        : YES;
        _instance.showOverlay    = d[@"stbtweak_overlay"]  ? [d[@"stbtweak_overlay"] boolValue]        : NO;
        _instance.captureImages  = d[@"stbtweak_capture"]  ? [d[@"stbtweak_capture"] boolValue]        : YES;
        _instance.verboseLogging = d[@"stbtweak_verbose"]  ? [d[@"stbtweak_verbose"] boolValue]        : NO;
    });
    return _instance;
}

+ (NSString *)documentsRoot {
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/BOTBTweak"];
    [self ensureDir:p];
    return p;
}

+ (NSString *)capturesDir {
    NSString *p = [self.documentsRoot stringByAppendingPathComponent:@"captures"];
    [self ensureDir:p];
    return p;
}

+ (NSString *)predictionsDir {
    NSString *p = [self.documentsRoot stringByAppendingPathComponent:@"predictions"];
    [self ensureDir:p];
    return p;
}

+ (void)ensureDir:(NSString *)p {
    [[NSFileManager defaultManager] createDirectoryAtPath:p
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

+ (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@ %@", STBTweakLogPrefix, msg);
}

+ (void)logVerbose:(NSString *)format, ... {
    if (![STBConfig shared].verboseLogging) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@ %@", STBTweakLogPrefix, msg);
}

@end
