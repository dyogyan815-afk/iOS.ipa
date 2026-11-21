/*
 * STBImageCapture.h — full-resolution capture of the genuine competition
 * image as loaded by the app, plus metadata export.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "STBCoordinateMath.h"

NS_ASSUME_NONNULL_BEGIN

@interface STBCaptureRecord : NSObject
@property (nonatomic, strong) UIImage *image;        /* genuine loaded image */
@property (nonatomic, assign) CGSize viewSize;       /* displaying view size (points) */
@property (nonatomic, assign) STBScaleMode scaleMode;/* detected content mode */
@property (nonatomic, weak, nullable) UIImageView *displayView; /* LIVE displaying view (weak) */
@property (nonatomic, strong, nullable) NSString *viewClass;
@property (nonatomic, strong, nullable) NSArray<NSString *> *hierarchyClasses;
@property (nonatomic, assign) NSTimeInterval timestamp;
@end

@interface STBImageCapture : NSObject

+ (instancetype)shared;

/* Record a newly set image on an image view inside the STB game UI. */
- (void)noteImage:(UIImage *)image
        inImageView:(UIImageView *)imageView;

/* Latest record, if any. */
@property (nonatomic, strong, readonly, nullable) STBCaptureRecord *latest;

/* Write latest image as PNG + sidecar JSON metadata. Returns saved path or nil. */
- (nullable NSString *)exportLatestCapture;

/* SHA-1 hex of the image's PNG data (stable id for predictions dir). */
+ (nullable NSString *)sha1HexOfData:(NSData *)data;

/* Render a crosshair + alternates onto the FULL-RESOLUTION image and save PNG. */
- (nullable NSString *)exportAnnotatedPNGAtNormalizedX:(double)nx
                                                     Y:(double)ny
                                              alternates:(NSArray<NSValue *> *)altNorm
                                                   label:(nullable NSString *)label;

@end

NS_ASSUME_NONNULL_END
