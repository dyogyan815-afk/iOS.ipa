/*
 * STBImageCapture.m — records the genuine competition image exactly as the
 * app received it (no placeholder substitution), preserves resolution,
 * exports PNG + metadata JSON, renders annotated copies.
 */
#import "STBImageCapture.h"
#import "STBConfig.h"
#import "STBCoordinateMath.h"
#import <CommonCrypto/CommonDigest.h>

static STBImageCapture *_captureInstance = nil;

@implementation STBCaptureRecord
@end

@implementation STBImageCapture {
    STBCaptureRecord *_latestInternal;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _captureInstance = [[STBImageCapture alloc] init]; });
    return _captureInstance;
}

- (STBCaptureRecord *)latest {
    return _latestInternal;
}

- (void)noteImage:(UIImage *)image inImageView:(UIImageView *)imageView {
    if (!image || image.size.width <= 0) return;
    if (![STBConfig shared].captureImages && ![STBConfig shared].showOverlay) return;

    STBCaptureRecord *rec = [[STBCaptureRecord alloc] init];
    rec.image = image;
    rec.displayView = imageView;      /* LIVE view: bounds/contentMode/convertPoint */
    rec.viewSize = imageView.bounds.size;
    switch (imageView.contentMode) {
        case UIViewContentModeScaleToFill:   rec.scaleMode = STBScaleFill;       break;
        case UIViewContentModeScaleAspectFill: rec.scaleMode = STBScaleAspectFill; break;
        default:                             rec.scaleMode = STBScaleAspectFit;  break;
    }
    rec.viewClass = NSStringFromClass([imageView class]);
    rec.timestamp = [[NSDate date] timeIntervalSince1970];

    /* capture view-hierarchy class names (evidence) */
    NSMutableArray<NSString *> *h = [NSMutableArray array];
    UIView *v = imageView;
    int depth = 0;
    while (v && depth < 24) {
        [h addObject:NSStringFromClass([v class])];
        v = v.superview;
        depth++;
    }
    rec.hierarchyClasses = h;

    _latestInternal = rec;

    STBScaleMode m;
    STBImageMapping map;
    m = rec.scaleMode;
    if (stb_compute_mapping(image.size.width, image.size.height,
                            rec.viewSize.width, rec.viewSize.height, m, &map) == 0) {
        [STBConfig logVerbose:@"image %@x%@ px in view %@x%@ pt scale=%.3f dx=%.1f dy=%.1f",
            @(image.size.width), @(image.size.height),
            @(rec.viewSize.width), @(rec.viewSize.height), map.scale, map.dx, map.dy];
    }
    [STBConfig log:@"captured game image %dx%d px (class %@)",
        (int)image.size.width, (int)image.size.height, rec.viewClass];
}

+ (nullable NSString *)sha1HexOfData:(NSData *)data {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    if (!CC_SHA1(data.bytes, (CC_LONG)data.length, digest)) return nil;
    NSMutableString *hex = [NSMutableString stringWithCapacity:40];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

- (nullable NSString *)exportLatestCapture {
    STBCaptureRecord *rec = _latestInternal;
    if (!rec.image) return nil;
    NSData *png = UIImagePNGRepresentation(rec.image);
    if (!png) return nil;
    NSString *sha = [STBImageCapture sha1HexOfData:png] ?: @"unknown";
    NSString *base = [NSString stringWithFormat:@"stb_%lld_%@",
                      (long long)rec.timestamp, [sha substringToIndex:MIN(12, sha.length)]];
    NSString *pngPath = [[STBConfig capturesDir] stringByAppendingPathComponent:
                         [base stringByAppendingPathExtension:@"png"]];
    [png writeToFile:pngPath atomically:YES];

    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    meta[@"type"] = @"botb_tweak_capture_v1";
    meta[@"timestamp_epoch"] = @(rec.timestamp);
    meta[@"image_png"] = pngPath.lastPathComponent;
    meta[@"image_sha1"] = sha;
    meta[@"width_px"] = @((int)rec.image.size.width);
    meta[@"height_px"] = @((int)rec.image.size.height);
    meta[@"scale_px_per_point"] = @(rec.image.scale);
    meta[@"display_view_class"] = rec.viewClass ?: @"";
    meta[@"display_view_size_pt"] = @{@"w": @(rec.viewSize.width), @"h": @(rec.viewSize.height)};
    meta[@"display_content_mode_raw"] = @(rec.scaleMode);
    meta[@"view_hierarchy"] = rec.hierarchyClasses ?: @[];
    meta[@"note"] = @"Genuine competition image captured from app image view; no modification.";
    NSData *json = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil];
    if (json) {
        [json writeToFile:[[STBConfig capturesDir] stringByAppendingPathComponent:
                           [base stringByAppendingPathExtension:@"json"]] atomically:YES];
    }
    [STBConfig log:@"exported capture %@", pngPath.lastPathComponent];
    return pngPath;
}

- (nullable NSString *)exportAnnotatedPNGAtNormalizedX:(double)nx
                                                     Y:(double)ny
                                              alternates:(NSArray<NSValue *> *)altNorm
                                                   label:(NSString *)label {
    STBCaptureRecord *rec = _latestInternal;
    if (!rec.image) return nil;

    CGFloat W = rec.image.size.width * rec.image.scale;
    CGFloat H = rec.image.size.height * rec.image.scale;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(W, H), YES, 1.0);
    [rec.image drawInRect:CGRectMake(0, 0, W, H)];
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    double cx = stb_clamp01(nx) * W;
    double cy = stb_clamp01(ny) * H;
    CGFloat r = MAX(24.0, MIN(W, H) * 0.03);

    /* alternates */
    CGContextSetStrokeColorWithColor(ctx, [[UIColor colorWithRed:1.0 green:0.75 blue:0.0 alpha:0.9] CGColor]);
    CGContextSetLineWidth(ctx, MAX(2.0, W * 0.002));
    for (NSValue *v in altNorm) {
        CGPoint p = v.CGPointValue;
        double ax = stb_clamp01(p.x) * W, ay = stb_clamp01(p.y) * H;
        CGRect rect = CGRectMake(ax - r * 0.6, ay - r * 0.6, r * 1.2, r * 1.2);
        CGContextStrokeEllipseInRect(ctx, rect);
    }
    /* primary crosshair */
    CGContextSetStrokeColorWithColor(ctx, [[UIColor colorWithRed:0.0 green:1.0 blue:0.35 alpha:0.95] CGColor]);
    CGContextSetLineWidth(ctx, MAX(2.5, W * 0.0025));
    CGContextMoveToPoint(ctx, cx - r * 1.6, cy); CGContextAddLineToPoint(ctx, cx + r * 1.6, cy);
    CGContextMoveToPoint(ctx, cx, cy - r * 1.6); CGContextAddLineToPoint(ctx, cx, cy + r * 1.6);
    CGContextStrokePath(ctx);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2, r * 2));

    if (label.length) {
        NSDictionary *attrs = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:MAX(18, W * 0.012)],
                                NSForegroundColorAttributeName: UIColor.greenColor};
        [label drawAtPoint:CGPointMake(cx + r * 1.8, cy - r) withAttributes:attrs];
    }

    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!out) return nil;
    NSData *png = UIImagePNGRepresentation(out);
    if (!png) return nil;
    NSString *path = [[STBConfig capturesDir] stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"annotated_%lld.png", (long long)rec.timestamp]];
    [png writeToFile:path atomically:YES];
    [STBConfig log:@"exported annotated image %@", path.lastPathComponent];
    return path;
}

@end
