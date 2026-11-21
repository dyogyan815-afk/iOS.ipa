/*
 * STBConfig.h — tweak settings persisted in NSUserDefaults.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const STBTweakLogPrefix;

@interface STBConfig : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) BOOL enabled;          /* master switch, default YES */
@property (nonatomic, assign) BOOL showOverlay;      /* crosshair/panel visible, default NO */
@property (nonatomic, assign) BOOL captureImages;    /* export full-res captures, default YES */
@property (nonatomic, assign) BOOL verboseLogging;   /* debug logs, default NO */

+ (NSString *)documentsRoot;      /* Documents/BOTBTweak */
+ (NSString *)capturesDir;        /* Documents/BOTBTweak/captures */
+ (NSString *)predictionsDir;     /* Documents/BOTBTweak/predictions */

+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
+ (void)logVerbose:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

@end

NS_ASSUME_NONNULL_END
