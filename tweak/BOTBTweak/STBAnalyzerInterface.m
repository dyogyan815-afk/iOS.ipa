/*
 * STBAnalyzerInterface.m — analyzer hub: no built-in model (clearly labelled),
 * external prediction loader with strict validation.
 */
#import "STBAnalyzerInterface.h"
#import "STBConfig.h"
#import "STBImageCapture.h"

@implementation STBPrediction
@end

@implementation STBAnalysisResult
@end

static STBAnalyzerHub *_hub = nil;

@implementation STBAnalyzerHub

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _hub = [[STBAnalyzerHub alloc] init]; });
    return _hub;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        /* No analyzer is registered: AI module is NOT integrated in this
         * build. Register one via [STBAnalyzerHub shared].analyzer = ...  */
        _analyzer = nil;
    }
    return self;
}

- (STBAnalysisResult *)resultForImagePNG:(NSData *)pngData
                                    size:(CGSize)pixelSize
                                imageSHA1:(NSString *)sha1 {
    STBAnalysisResult *res = nil;
    if (self.analyzer) {
        @try {
            res = [self.analyzer analyzeImagePNG:pngData size:pixelSize imageSHA1:sha1];
        } @catch (NSException *ex) {
            [STBConfig log:@"analyzer exception: %@", ex.reason];
            res = nil;
        }
    }
    STBAnalysisResult *ext = [self loadExternalResultForSHA1:sha1];
    if (ext) return ext;
    if (!res) {
        res = [[STBAnalysisResult alloc] init];
        res.statusMessage = @"AI module not integrated — analysis interface ready.";
    }
    return res;
}

- (nullable STBAnalysisResult *)loadExternalResultForSHA1:(NSString *)sha1 {
    if (sha1.length < 6) return nil;
    NSArray<NSString *> *candidates = @[
        [[STBConfig predictionsDir] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", sha1]],
        [[STBConfig predictionsDir] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", [sha1 substringToIndex:12]]],
    ];
    NSString *path = nil;
    for (NSString *c in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:c]) { path = c; break; }
    }
    if (!path) return nil;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = (NSDictionary *)obj;

    /* strict validation: predictions must be an array of dicts with numeric x,y */
    id predsRaw = dict[@"predictions"];
    if (![predsRaw isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray<STBPrediction *> *preds = [NSMutableArray array];
    for (id p in (NSArray *)predsRaw) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        id xv = ((NSDictionary *)p)[@"x"], yv = ((NSDictionary *)p)[@"y"];
        if (![xv isKindOfClass:[NSNumber class]] || ![yv isKindOfClass:[NSNumber class]]) continue;
        double x = [xv doubleValue], y = [yv doubleValue];
        if (x < 0 || x > 1 || y < 0 || y > 1) continue;   /* normalized only */
        STBPrediction *pr = [[STBPrediction alloc] init];
        pr.x = x; pr.y = y;
        id cv = ((NSDictionary *)p)[@"confidence"];
        pr.confidence = ([cv isKindOfClass:[NSNumber class]] && [cv doubleValue] >= 0 && [cv doubleValue] <= 1)
                        ? [cv doubleValue] : -1;
        [preds addObject:pr];
    }
    if (!preds.count) return nil;

    STBAnalysisResult *res = [[STBAnalysisResult alloc] init];
    res.predictions = preds;
    res.generator = [dict[@"generator"] isKindOfClass:[NSString class]] ? dict[@"generator"] : @"external";
    res.imageSHA1 = sha1;
    res.statusMessage = [NSString stringWithFormat:@"external predictions from %@", res.generator];
    [STBConfig log:@"loaded %lu external predictions for %@",
        (unsigned long)preds.count, [sha1 substringToIndex:MIN(12, sha1.length)]];
    return res;
}

@end
