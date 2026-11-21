/*
 * STBOverlayUI.m — in-app diagnostic panel + draggable crosshair overlay
 * + prediction heatmap.
 *
 * v2 — PIXEL-EXACT MAPPING FIX
 * ============================
 * v1 bugs fixed here:
 *   1. refreshMapping built its mapping from self.superview.bounds, assuming
 *      the overlay's superview was exactly the view that displays the image.
 *      If the attach point differs from the game's image container (origin,
 *      inset, safe area, transform), the drawn crosshair was offset.
 *   2. The stored normalized value was converted with a scaleMode recorded
 *      at capture time; the LIVE UIImageView contentMode is authoritative.
 *   3. The label showed the STORED normalized value, not the normalized
 *      value of the point really drawn.
 *   4. onPan moved the view center but never wrote it back into
 *      normalizedPos, so the next refreshMapping snapped the crosshair back
 *      (drag was a no-op and display/touch paths diverged).
 *   5. The heatmap (new) must share the exact content rect of the crosshair.
 *
 * v2 rules (implemented below):
 *   - ONE source of truth: the LIVE game image view (weak ref kept by the
 *     controller). Mapping is always computed against THAT view's bounds and
 *     THAT view's contentMode, then placed with UIView convertPoint so any
 *     transform/offset/zoom state of the hierarchy is honored.
 *   - Display path:  normalized -> image px -> view pt (C core, unchanged)
 *                    -> convertPoint into the anchor (sibling) space -> frame.
 *   - Inverse path:  drawn point -> convertPoint back into image-view space
 *                    -> view pt -> image px -> normalized (same C core).
 *   - The label is computed FROM THE DRAWN POINT, never from the stored
 *     target, so label and pixels can never disagree.
 *   - Pan writes the drawn point back through the inverse path, then re-runs
 *     the display path: |stored - displayed| round-trip error ~1e-12.
 */
#import "STBOverlayUI.h"
#import "STBConfig.h"
#import "STBImageCapture.h"
#import "STBAnalyzerInterface.h"
#import "STBCoordinateMath.h"

/* ---------------- Crosshair overlay ---------------- */

@implementation STBCrosshairOverlay {
    UIView *_handle;
    UILabel *_tag;
    CGPoint _drawnNormalized;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;

        _handle = [[UIView alloc] initWithFrame:CGRectMake(-26, -26, 52, 52)];
        _handle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.001]; /* touch target */
        _handle.layer.cornerRadius = 26;
        [self addSubview:_handle];

        CGFloat s = 22;
        UIView *cross = [[UIView alloc] initWithFrame:CGRectMake(-s, -0.75, s * 2, 1.5)];
        cross.backgroundColor = [UIColor colorWithRed:0 green:1 blue:0.35 alpha:0.95];
        UIView *cross2 = [[UIView alloc] initWithFrame:CGRectMake(-0.75, -s, 1.5, s * 2)];
        cross2.backgroundColor = cross.backgroundColor;
        UIView *ring = [[UIView alloc] initWithFrame:CGRectMake(-14, -14, 28, 28)];
        ring.backgroundColor = [UIColor clearColor];
        ring.layer.cornerRadius = 14;
        ring.layer.borderWidth = 2;
        ring.layer.borderColor = [UIColor colorWithRed:0 green:1 blue:0.35 alpha:0.95].CGColor;
        [self addSubview:cross];
        [self addSubview:cross2];
        [self addSubview:ring];

        _tag = [[UILabel alloc] initWithFrame:CGRectMake(18, -34, 150, 24)];
        _tag.font = [UIFont boldSystemFontOfSize:13];
        _tag.textColor = [UIColor colorWithRed:0 green:1 blue:0.35 alpha:1];
        _tag.shadowColor = [UIColor colorWithWhite:0 alpha:0.8];
        _tag.shadowOffset = CGSizeMake(1, 1);
        [self addSubview:_tag];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(onPan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

/* Pass touches through everywhere except near the crosshair. */
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGPoint local = [self convertPoint:point toView:_handle];
    CGRect r = _handle.bounds;
    return CGRectContainsPoint(CGRectInset(r, -12, -12), local);
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.superview];
        /* move the DRAWN point (local (0,0) == frame.origin == cross center) */
        CGPoint origin = self.frame.origin;
        origin.x += t.x; origin.y += t.y;
        [g setTranslation:CGPointZero inView:self.superview];
        /* inverse path first: drawn point -> stored normalized (same geometry) */
        [self syncNormalizedFromDrawnOrigin:origin];
        /* display path: stored normalized -> drawn point -> label */
        [self refreshMapping];
        [[STBOverlayController shared] refreshHeatmap];
    }
}

- (void)setNormalizedPos:(CGPoint)normalizedPos {
    _normalizedPos = normalizedPos;
    [self refreshMapping];
}

/* Common inputs for both conversion directions. Returns NO if anything is
 * missing; fills m/imgW/imgH on success. */
- (BOOL)liveMapping:(STBImageMapping *)m
               imgW:(double *)imgW
               imgH:(double *)imgH {
    STBCaptureRecord *rec = [STBImageCapture shared].latest;
    UIImageView *iv = _gameImageView;
    if (!rec || !rec.image || !iv || !self.superview) return NO;
    CGSize bs = iv.bounds.size;
    if (bs.width < 1 || bs.height < 1) return NO;
    double W = rec.image.size.width * rec.image.scale;
    double H = rec.image.size.height * rec.image.scale;
    if (W <= 0 || H <= 0) return NO;
    STBScaleMode mode = [STBOverlayController scaleModeForView:iv record:rec];
    if (stb_compute_mapping(W, H, bs.width, bs.height, mode, m) != 0) return NO;
    if (imgW) *imgW = W;
    if (imgH) *imgH = H;
    return YES;
}

- (void)refreshMapping {
    STBImageMapping m;
    double imgW = 0, imgH = 0;
    if (![self liveMapping:&m imgW:&imgW imgH:&imgH]) return;

    /* display path: normalized -> image px -> view point in image-view space */
    double vx, vy;
    if (stb_normalized_to_view_point(&m, imgW, imgH,
                                     _normalizedPos.x, _normalizedPos.y,
                                     &vx, &vy) != 0) return;
    /* place in the ANCHOR (sibling) space via the live hierarchy geometry */
    CGPoint inIV = CGPointMake(vx, vy);
    CGPoint target = [_gameImageView convertPoint:inIV toView:self.superview];
    self.frame = CGRectMake(target.x, target.y, 4, 4);

    [self refreshLabelWithMapping:&m imgW:imgW imgH:imgH];
}

/* Label = normalized value of the point REALLY drawn (frame.origin, i.e.
 * local (0,0), where the cross graphic is centered). */
- (void)refreshLabelWithMapping:(STBImageMapping *)m
                           imgW:(double)imgW
                           imgH:(double)imgH {
    if (!self.superview || !_gameImageView) return;
    CGPoint drawnLocal = CGPointMake(0, 0);
    CGPoint drawnInAnchor = [self convertPoint:drawnLocal toView:self.superview];
    CGPoint backInIV = [self.superview convertPoint:drawnInAnchor toView:_gameImageView];
    double nx, ny;
    if (stb_view_point_to_normalized(m, imgW, imgH,
                                     backInIV.x, backInIV.y, &nx, &ny) != 0) return;
    _drawnNormalized = CGPointMake(nx, ny);
    _tag.text = [NSString stringWithFormat:@"%.1f%%, %.1f%%",
                 nx * 100.0, ny * 100.0];
}

/* Inverse path: a drawn point (in anchor space) -> stored normalized value.
 * Uses the SAME live geometry and the SAME C core as the display path, so a
 * round trip differs only by double-precision noise (< 1e-9). */
- (void)syncNormalizedFromDrawnOrigin:(CGPoint)drawnOriginInAnchor {
    STBImageMapping m;
    double imgW = 0, imgH = 0;
    if (![self liveMapping:&m imgW:&imgW imgH:&imgH]) return;
    if (!self.superview || !_gameImageView) return;
    CGPoint backInIV = [self.superview convertPoint:drawnOriginInAnchor toView:_gameImageView];
    double nx, ny;
    if (stb_view_point_to_normalized(&m, imgW, imgH,
                                     backInIV.x, backInIV.y, &nx, &ny) != 0) return;
    _normalizedPos = CGPointMake(nx, ny);
}

@end

/* ---------------- Heatmap ---------------- */

@implementation STBHeatmapView {
    NSArray<STBPrediction *> *_preds;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;   /* never intercepts touches */
        self.opaque = NO;
    }
    return self;
}

- (void)setPredictions:(NSArray<STBPrediction *> *)predictions {
    _preds = [predictions copy];
    [self setNeedsDisplay];
}

/* Re-place using the SAME content rect as the crosshair: the frame is the
 * content rect converted through the live view hierarchy, so a blob drawn at
 * fraction (fx, fy) of this view's bounds coincides EXACTLY with the point
 * where the crosshair renders normalized (fx, fy). */
- (void)refreshFrame {
    UIImageView *iv = _gameImageView;
    if (!iv || !self.superview) return;
    STBCaptureRecord *rec = [STBImageCapture shared].latest;
    CGRect content = [STBOverlayController contentRectForView:iv record:rec];
    if (content.size.width < 1 || content.size.height < 1) return;
    CGPoint p0 = [iv convertPoint:content.origin toView:self.superview];
    CGPoint p1 = [iv convertPoint:
                  CGPointMake(content.origin.x + content.size.width,
                              content.origin.y + content.size.height)
                  toView:self.superview];
    self.frame = CGRectMake(p0.x, p0.y, p1.x - p0.x, p1.y - p0.y);
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (!_preds.count) return;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w < 2 || h < 2) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetBlendMode(ctx, kCGBlendModePlusLighter);

    CGFloat baseR = MIN(w, h) * 0.11;
    for (NSUInteger i = 0; i < _preds.count && i < 5; i++) {
        STBPrediction *p = _preds[i];
        double fx = stb_clamp01(p.x), fy = stb_clamp01(p.y);
        CGPoint c = CGPointMake(fx * w, fy * h);
        CGFloat r = (i == 0) ? baseR : baseR * 0.6;
        CGFloat alpha = (i == 0) ? 0.34 : 0.16;
        CGColorRef col = (i == 0)
            ? [UIColor colorWithRed:0.0 green:1.0 blue:0.35 alpha:alpha].CGColor
            : [UIColor colorWithRed:1.0 green:0.75 blue:0.0 alpha:alpha].CGColor;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *cols = @[(__bridge id)col,
                          (__bridge id)[UIColor colorWithRed:0 green:0 blue:0 alpha:0].CGColor];
        CGGradientRef grad = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols,
                                                        (const CGFloat[]){0.0, 1.0});
        if (grad) {
            CGContextDrawRadialGradient(ctx, grad, c, 0, c, r,
                                        kCGGradientDrawsBeforeStartLocation);
            CGGradientRelease(grad);
        }
        CGColorSpaceRelease(cs);
    }
}

@end

/* ---------------- Panel + controller ---------------- */

@interface STBOverlayController ()
@property (nonatomic, strong, nullable) UIButton *toggleButton;
@property (nonatomic, strong, nullable) UIView *panel;
@property (nonatomic, strong, nullable) UITextView *textView;
@property (nonatomic, strong, nullable) STBCrosshairOverlay *crosshair;
@property (nonatomic, strong, nullable) NSArray<STBPrediction *> *preds;
@property (nonatomic, copy, nullable) NSString *statusLine;
@end

@implementation STBOverlayController

- (instancetype)init {
    self = [super init];
    if (self) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        _heatVisible = [d objectForKey:@"stbtweak_heatmap"] == nil
            ? YES : [d boolForKey:@"stbtweak_heatmap"];
    }
    return self;
}

+ (instancetype)shared {
    static STBOverlayController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[STBOverlayController alloc] init]; });
    return c;
}

/* LIVE contentMode is authoritative; the capture record is only a fallback
 * for exotic content modes we do not model (center/top/left gravity). */
+ (STBScaleMode)scaleModeForView:(UIImageView *)view
                          record:(STBCaptureRecord *)record {
    switch (view.contentMode) {
        case UIViewContentModeScaleToFill:     return STBScaleFill;
        case UIViewContentModeScaleAspectFill: return STBScaleAspectFill;
        case UIViewContentModeScaleAspectFit:  return STBScaleAspectFit;
        default:                               return record ? record.scaleMode
                                                             : STBScaleAspectFit;
    }
}

+ (CGRect)contentRectForView:(UIView *)view
                      record:(STBCaptureRecord *)record {
    STBCaptureRecord *rec = record ?: [STBImageCapture shared].latest;
    if (!view || !rec.image) return CGRectZero;
    CGSize bs = view.bounds.size;
    if (bs.width < 1 || bs.height < 1) return CGRectZero;
    double W = rec.image.size.width * rec.image.scale;
    double H = rec.image.size.height * rec.image.scale;
    if (W <= 0 || H <= 0) return CGRectZero;
    STBScaleMode mode = [view isKindOfClass:[UIImageView class]]
        ? [self scaleModeForView:(UIImageView *)view record:rec]
        : STBScaleAspectFit;
    STBImageMapping m;
    if (stb_compute_mapping(W, H, bs.width, bs.height, mode, &m) != 0)
        return CGRectZero;
    STBRect cr;
    if (stb_content_rect(&m, W, H, bs.width, bs.height, &cr) != 0)
        return CGRectZero;
    return CGRectMake(cr.x, cr.y, cr.w, cr.h);
}

- (void)ensureInstalled {
    if (self.toggleButton && self.toggleButton.window) return;
    UIWindow *win = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            win = ((UIWindowScene *)scene).keyWindow;
            break;
        }
    }
    if (!win) return;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(12, 60, 64, 30);
    btn.layer.cornerRadius = 8;
    btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    btn.tintColor = UIColor.cyanColor;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [btn setTitle:@"STB-AI" forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:btn];
    self.toggleButton = btn;
}

- (void)togglePanel {
    if (self.panel && self.panel.superview) [self hidePanel];
    else [self showPanel];
}

- (void)showPanel {
    UIWindow *win = self.toggleButton.window;
    if (!win) return;
    [self recomputePredictions];
    [self refreshContent];

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(8, 96, 300, 330)];
    panel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.92];
    panel.layer.cornerRadius = 12;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = UIColor.cyanColor.CGColor;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 270, 22)];
    title.text = @"BOTB Tweak — research build";
    title.font = [UIFont boldSystemFontOfSize:13];
    title.textColor = UIColor.cyanColor;
    [panel addSubview:title];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(8, 34, 284, 244)];
    tv.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    tv.textColor = UIColor.whiteColor;
    tv.font = [UIFont fontWithName:@"Menlo" size:10.5] ?: [UIFont systemFontOfSize:10.5];
    tv.editable = NO;
    tv.layer.cornerRadius = 6;
    self.textView = tv;
    [panel addSubview:tv];

    UIButton *xh = [UIButton buttonWithType:UIButtonTypeSystem];
    xh.frame = CGRectMake(10, 288, 108, 32);
    [xh setTitle:@"Crosshair" forState:UIControlStateNormal];
    [xh addTarget:self action:@selector(toggleCrosshair) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:xh];

    UIButton *hm = [UIButton buttonWithType:UIButtonTypeSystem];
    hm.frame = CGRectMake(122, 288, 84, 32);
    [hm setTitle:@"Heatmap" forState:UIControlStateNormal];
    [hm addTarget:self action:@selector(toggleHeatmap) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:hm];

    UIButton *ex = [UIButton buttonWithType:UIButtonTypeSystem];
    ex.frame = CGRectMake(210, 288, 82, 32);
    [ex setTitle:@"Export" forState:UIControlStateNormal];
    [ex addTarget:self action:@selector(exportNow) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:ex];

    [win addSubview:panel];
    self.panel = panel;
    [self refreshContent];
}

- (void)hidePanel {
    [self.panel removeFromSuperview];
    self.panel = nil;
}

- (void)toggleCrosshair {
    BOOL on = ![STBConfig shared].showOverlay;
    [STBConfig shared].showOverlay = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"stbtweak_overlay"];
    if (on) [self attachCrosshair];
    else [self detachCrosshair];
    [self refreshContent];
}

- (void)toggleHeatmap {
    self.heatVisible = !self.heatVisible;
    [[NSUserDefaults standardUserDefaults] setBool:self.heatVisible forKey:@"stbtweak_heatmap"];
    self.heatmap.hidden = !self.heatVisible;
    [self refreshHeatmap];
}

- (void)attachCrosshair {
    STBCaptureRecord *rec = [STBImageCapture shared].latest;
    if (!rec) return;
    [self detachCrosshair];
    /* find the LIVE game image view inside the active window */
    UIImageView *iv = [self findGameImageView];
    if (!iv) { [STBConfig log:@"no game image view found for crosshair"]; return; }
    self.crosshairImageView = iv;
    /* SIBLING attach: never a subview of the game's own views, so we cannot
     * influence their layout; we render above them (added last). */
    UIView *parent = iv.superview ?: iv.window;
    if (!parent) return;

    STBCrosshairOverlay *ch = [[STBCrosshairOverlay alloc]
                               initWithFrame:CGRectMake(0, 0, 4, 4)];
    ch.gameImageView = iv;
    ch.normalizedPos = CGPointMake(0.5, 0.42);   /* center-ish default; user drags */
    [parent addSubview:ch];
    self.crosshair = ch;

    STBHeatmapView *hm = [[STBHeatmapView alloc] initWithFrame:CGRectZero];
    hm.gameImageView = iv;
    [parent addSubview:hm];
    hm.hidden = !self.heatVisible;
    self.heatmap = hm;

    [ch refreshMapping];
    [self refreshHeatmap];
    [self refreshContent];
}

- (void)detachCrosshair {
    [self.crosshair removeFromSuperview];
    self.crosshair = nil;
    [self.heatmap removeFromSuperview];
    self.heatmap = nil;
}

- (void)refreshCrosshairIfVisible {
    if (![STBConfig shared].showOverlay) return;
    if (!self.crosshair) { [self attachCrosshair]; return; }
    [self.crosshair refreshMapping];
    [self refreshHeatmap];
}

- (void)refreshHeatmap {
    [self.heatmap refreshFrame];
    self.heatmap.predictions = self.preds;
    self.heatmap.hidden = !self.heatVisible;
}

- (nullable UIImageView *)findGameImageView {
    UIWindow *win = self.toggleButton.window;
    if (!win) return nil;
    UIImageView *best = nil;
    for (UIView *sub in win.subviews) {
        best = [self searchImageView:sub];
        if (best) break;
    }
    return best;
}

- (nullable UIImageView *)searchImageView:(UIView *)v {
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        if (iv.image && v.bounds.size.width > 40) {
            /* prefer the image view that carries the captured image */
            if (iv.image.size.width == [STBImageCapture shared].latest.image.size.width)
                return iv;
        }
    }
    for (UIView *sub in v.subviews) {
        UIImageView *r = [self searchImageView:sub];
        if (r) return r;
    }
    return nil;
}

- (void)exportNow {
    NSString *p = [[STBImageCapture shared] exportLatestCapture];
    STBPrediction *top = self.preds.firstObject;
    if (top && p) {
        [[STBImageCapture shared] exportAnnotatedPNGAtNormalizedX:top.x
                                                                Y:top.y
                                                       alternates:[self altPoints]
                                                             label:self.statusLine];
    }
    [self refreshContent];
}

- (NSArray<NSValue *> *)altPoints {
    NSMutableArray *a = [NSMutableArray array];
    for (NSUInteger i = 1; i < self.preds.count && i < 5; i++) {
        [a addObject:[NSValue valueWithCGPoint:
                      CGPointMake(self.preds[i].x, self.preds[i].y)]];
    }
    return a;
}

- (void)refreshContent {
    if (!self.textView) return;
    NSMutableString *s = [NSMutableString string];
    STBCaptureRecord *rec = [STBImageCapture shared].latest;

    [s appendString:@"STATE\n"];
    [s appendFormat:@"  game image: %@\n", rec ? @"captured" : @"not captured yet"];
    if (rec) {
        CGSize px = CGSizeMake(rec.image.size.width * rec.image.scale,
                               rec.image.size.height * rec.image.scale);
        [s appendFormat:@"  size: %d x %d px\n", (int)px.width, (int)px.height];
        [s appendFormat:@"  view: %@ (%.0f x %.0f pt)\n",
            rec.viewClass ?: @"?", rec.viewSize.width, rec.viewSize.height];
        NSString *top = rec.hierarchyClasses.firstObject;
        [s appendFormat:@"  hierarchy: %@ ...\n", top ?: @"?"];
    }
    [s appendString:@"\nPREDICTION\n"];
    if (self.preds.count) {
        STBPrediction *p = self.preds[0];
        [s appendFormat:@"  x=%.3f  y=%.3f  conf=%.2f\n", p.x, p.y, p.confidence];
        for (NSUInteger i = 1; i < self.preds.count && i < 4; i++) {
            [s appendFormat:@"  alt%lu: x=%.3f y=%.3f\n",
                (unsigned long)i, self.preds[i].x, self.preds[i].y];
        }
        [s appendFormat:@"  source: %@\n", self.statusLine ?: @""];
    } else {
        [s appendString:@"  AI module not integrated.\n"];
        [s appendString:@"  Drop predictions/<sha1>.json in\n"];
        [s appendString:@"  Documents/BOTBTweak/predictions.\n"];
    }
    if (self.preds.count && self.crosshair) {
        STBPrediction *p = self.preds[0];
        self.crosshair.normalizedPos = CGPointMake(p.x, p.y);
        [self.crosshair refreshMapping];
    }
    [self refreshHeatmap];
    self.textView.text = s;
}

/* Heavier path: hash image, consult analyzer + external predictions.
 * Called on capture and panel-open, NOT on pan gestures. */
- (void)recomputePredictions {
    STBCaptureRecord *rec = [STBImageCapture shared].latest;
    if (!rec) return;
    NSData *png = UIImagePNGRepresentation(rec.image);
    if (!png) return;
    NSString *sha = [STBImageCapture sha1HexOfData:png] ?: @"";
    STBAnalysisResult *res = [[STBAnalyzerHub shared] resultForImagePNG:png
                                                                  size:CGSizeMake(rec.image.size.width, rec.image.size.height)
                                                              imageSHA1:sha];
    self.preds = res.predictions;
    self.statusLine = res.statusMessage ?: res.generator;
    [STBConfig logVerbose:@"recompute: %lu preds (%@)", (unsigned long)self.preds.count, self.statusLine ?: @"-"];
}

@end
