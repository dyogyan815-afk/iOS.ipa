/*
 * STBAnalyzerInterface.h — modular interface between the in-app capture layer
 * and an external AI engine.
 *
 * HONEST STATUS: no AI model is integrated in this build. The default
 * analyzer returns no predictions and reports "AI module not integrated".
 * An external engine can later drop prediction JSON files into
 * Documents/BOTBTweak/predictions/ using the documented schema; this
 * interface loads and validates them. Nothing here fabricates results.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Prediction JSON schema (one file per image):
 * {
 *   "image_sha1": "<sha1 of captured PNG>",
 *   "generator": "<engine name>",
 *   "predictions": [
 *     {"x": 0.512, "y": 0.487, "confidence": 0.83},   // normalized [0,1]
 *     ...
 *   ]
 * }
 */
@interface STBPrediction : NSObject
@property (nonatomic, assign) double x;            /* normalized [0,1] */
@property (nonatomic, assign) double y;
@property (nonatomic, assign) double confidence;   /* [0,1] or -1 if absent */
@end

@interface STBAnalysisResult : NSObject
@property (nonatomic, copy, nullable) NSString *generator;
@property (nonatomic, copy, nullable) NSString *imageSHA1;
@property (nonatomic, copy) NSArray<STBPrediction *> *predictions;
@property (nonatomic, copy, nullable) NSString *statusMessage;
@end

@protocol STBAnalyzer
/* Analyze the image (PNG data + pixel size). Must not block the main thread
 * for long; engines doing heavy work should return quickly from a cache or
 * run async and post results to the predictions directory. */
- (STBAnalysisResult *)analyzeImagePNG:(NSData *)pngData
                                  size:(CGSize)pixelSize
                              imageSHA1:(NSString *)sha1;
@end

@interface STBAnalyzerHub : NSObject

+ (instancetype)shared;

/* Currently registered analyzer (nil by default => not integrated). */
@property (nonatomic, strong, nullable) id<STBAnalyzer> analyzer;

/* Runs the analyzer if registered; ALWAYS also consults the external
 * predictions directory. Never fabricates: missing data => status message. */
- (STBAnalysisResult *)resultForImagePNG:(NSData *)pngData
                                    size:(CGSize)pixelSize
                                imageSHA1:(NSString *)sha1;

/* Load predictions/<sha1>.json if present (external engine contract). */
- (nullable STBAnalysisResult *)loadExternalResultForSHA1:(NSString *)sha1;

@end

NS_ASSUME_NONNULL_END
