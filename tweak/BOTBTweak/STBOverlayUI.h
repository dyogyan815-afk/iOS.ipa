/*
 * STBOverlayUI.h — diagnostic panel, crosshair overlay, heatmap and toggle.
 *
 * Interaction safety: the overlay only accepts touches near the crosshair
 * center (pointInside override); every other touch passes through to the
 * game. The panel is user-interactive; it never touches game state.
 *
 * v2 pixel-exact mapping: the crosshair is attached as a SIBLING of the
 * game image view (never inside it), and every conversion runs through the
 * LIVE image view bounds/contentMode + UIView convertPoint, so any origin
 * offset, inset, safe area, transform or zoom of the game view is honored
 * identically in the display path and the touch-back path.
 */
#import <UIKit/UIKit.h>
#import "STBCoordinateMath.h"

NS_ASSUME_NONNULL_BEGIN

@class STBCaptureRecord;
@class STBPrediction;

@interface STBCrosshairOverlay : UIView
@property (nonatomic, assign) CGPoint normalizedPos;           /* [0,1] within image rect (stored target) */
@property (nonatomic, assign, readonly) CGPoint drawnNormalized; /* normalized value of the point REALLY drawn */
@property (nonatomic, weak, nullable) UIImageView *gameImageView; /* the LIVE view that displays the image */
- (void)refreshMapping;   /* normalized -> drawn point -> label (label from drawn point) */
- (void)syncNormalizedFromDrawnOrigin:(CGPoint)drawnOriginInAnchor; /* inverse path */
@end

/* Heat of plausible ball locations: primary prediction = peak, alternates =
 * secondary blobs. Uses EXACTLY the same content rect and scale as the
 * crosshair, so the hottest pixel sits under the crosshair. */
@interface STBHeatmapView : UIView
@property (nonatomic, copy, nullable) NSArray<STBPrediction *> *predictions;
@property (nonatomic, weak, nullable) UIImageView *gameImageView;
- (void)refreshFrame;      /* re-place using the same content rect as the crosshair */
@end

@interface STBOverlayController : NSObject

+ (instancetype)shared;

- (void)ensureInstalled;                 /* add toggle button to key window */
- (void)showPanel;
- (void)hidePanel;
- (void)toggleCrosshair;
- (void)refreshContent;                  /* update panel text + predictions */
- (void)refreshCrosshairIfVisible;       /* cheap re-sync to live view geometry */
- (void)refreshHeatmap;                  /* re-place heatmap + reload predictions */

/* The live game image view currently driving the overlay (weak). */
@property (nonatomic, weak, nullable) UIImageView *crosshairImageView;
@property (nonatomic, strong, nullable) STBHeatmapView *heatmap;
@property (nonatomic, assign) BOOL heatVisible;

/* Content rect (in the given view's coordinate space) where the image is
 * really displayed, from LIVE bounds/contentMode (record is fallback). */
+ (CGRect)contentRectForView:(UIView *)view
                      record:(nullable STBCaptureRecord *)record;

/* Mapping mode for a view: live contentMode first, record fallback. */
+ (STBScaleMode)scaleModeForView:(UIImageView *)view
                          record:(nullable STBCaptureRecord *)record;

@end

NS_ASSUME_NONNULL_END
