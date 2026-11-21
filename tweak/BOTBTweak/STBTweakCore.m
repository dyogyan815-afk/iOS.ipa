/*
 * STBTweakCore.m — entry point and hooks for the BOTB research tweak.
 *
 * EVIDENCE BASIS (extracted from BOTB 3.1.96 main executable):
 *   _TtC6GuiKit12STBImageView          (GuiKit.STBImageView)
 *   _TtC6GuiKit24STBTicketCoordinatesView
 *   _TtC6GuiKit13STBTicketView
 *   _TtC6GuiKit12STBSpotsView
 *   _TtC6GuiKit16STBCrosshairView
 *   _TtC7CoreKit24BOTBSpotTheBallViewModel
 * The game logic is pure Swift (not ObjC-selectable); therefore we swizzle
 * inherited UIKit entry points and filter by exact app class membership.
 *
 * SAFETY: this tweak observes and renders only. It contains NO code path
 * that submits entries, alters selections or calls any BOTB network API.
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "STBConfig.h"
#import "STBImageCapture.h"
#import "STBAnalyzerInterface.h"
#import "STBOverlayUI.h"
#import "STBCoordinateMath.h"

/* ---- swizzled originals ---- */
static void (*orig_setImage)(id, SEL, UIImage *);
static void (*orig_didMoveToWindow)(id, SEL);
static void (*orig_touchesBegan)(id, SEL, NSSet<UITouch *> *, UIEvent *);
static void (*orig_touchesEnded)(id, SEL, NSSet<UITouch *> *, UIEvent *);

/* ---- cached app class pointers (resolved lazily) ---- */
static Class kSTBImageView, kSTBTicketCoords, kSTBTicketView, kSTBSpots,
             kSTBCrosshair, kSTBRulers, kSTBTargetView, kSTBViewModel;
static BOOL kClassesResolved = NO;

static void ensureClassesResolved(void) {
    if (kClassesResolved) return;
    kSTBImageView   = objc_getClass("_TtC6GuiKit12STBImageView");
    kSTBTicketCoords= objc_getClass("_TtC6GuiKit24STBTicketCoordinatesView");
    kSTBTicketView  = objc_getClass("_TtC6GuiKit13STBTicketView");
    kSTBSpots       = objc_getClass("_TtC6GuiKit12STBSpotsView");
    kSTBCrosshair   = objc_getClass("_TtC6GuiKit16STBCrosshairView");
    kSTBRulers      = objc_getClass("_TtC6GuiKit13STBRulersView");
    kSTBTargetView  = objc_getClass("_TtC6GuiKit13STBTargetView");
    kSTBViewModel   = objc_getClass("_TtC7CoreKit24BOTBSpotTheBallViewModel");
    /* latch only once the app's ObjC classes are actually registered */
    if (kSTBImageView || kSTBTicketCoords || kSTBTicketView) {
        kClassesResolved = YES;
        [STBConfig logVerbose:@"classes resolved: img=%@ coords=%@ ticket=%@ spots=%@",
            kSTBImageView, kSTBTicketCoords, kSTBTicketView, kSTBSpots];
    }
}

/* Does this view belong to the STB game UI? (checks self + ancestors) */
static BOOL inSTBHierarchy(UIView *view) {
    ensureClassesResolved();
    if (!kSTBTicketView && !kSTBImageView && !kSTBTicketCoords) return NO;
    UIView *v = view;
    int depth = 0;
    while (v && depth < 24) {
        Class c = object_getClass(v);
        if (c == kSTBTicketView || c == kSTBImageView || c == kSTBTicketCoords ||
            c == kSTBSpots || c == kSTBCrosshair || c == kSTBRulers ||
            c == kSTBTargetView)
            return YES;
        v = v.superview;
        depth++;
    }
    return NO;
}

static void installOverlayIfPossible(void) {
    [[STBOverlayController shared] ensureInstalled];
    if ([STBConfig shared].showOverlay) {
        /* re-attach crosshair when a fresh image arrives */
        [[STBOverlayController shared] refreshContent];
    }
}

/* ---------------- UIImageView setImage: ---------------- */
static void hook_setImage(id self, SEL _cmd, UIImage *image) {
    orig_setImage(self, _cmd, image);
    @try {
        if (![STBConfig shared].enabled) return;
        UIImageView *iv = self;
        if (!image || ![iv isKindOfClass:[UIImageView class]]) return;
        if (inSTBHierarchy(iv)) {
            [[STBImageCapture shared] noteImage:image inImageView:iv];
            installOverlayIfPossible();
        }
    } @catch (NSException *ex) {
        [STBConfig log:@"setImage hook exception: %@", ex.reason];
    }
}

/* ---------------- UIView didMoveToWindow ---------------- */
static void hook_didMoveToWindow(id self, SEL _cmd) {
    orig_didMoveToWindow(self, _cmd);
    @try {
        if (![STBConfig shared].enabled) return;
        UIView *view = (UIView *)self;
        if (!view.window) return;
        Class c = object_getClass(self);
        if (c == kSTBTicketCoords || c == kSTBImageView || c == kSTBTicketView) {
            [STBConfig logVerbose:@"%@ moved to window (%.0fx%.0f)",
                NSStringFromClass(c), [(UIView *)self bounds].size.width,
                [(UIView *)self bounds].size.height];
            installOverlayIfPossible();
        }
    } @catch (NSException *ex) {
        [STBConfig log:@"didMoveToWindow hook exception: %@", ex.reason];
    }
}

/* ---------------- UIResponder touches (observation only) ---------------- */
static void hook_touchesBegan(id self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    orig_touchesBegan(self, _cmd, touches, event);
    @try {
        if (![STBConfig shared].enabled) return;
        if (![self isKindOfClass:[UIView class]]) return;
        if (object_getClass(self) == kSTBTicketCoords || object_getClass(self) == kSTBSpots) {
            UITouch *t = touches.anyObject;
            if (!t) return;
            CGPoint p = [t locationInView:self];
            [STBConfig log:@"game touch began at (%.1f, %.1f) in %@",
                p.x, p.y, NSStringFromClass(object_getClass(self))];
            /* re-sync overlay to the LIVE view geometry (bounds/transform/zoom
             * may have changed since the last layout pass) */
            [[STBOverlayController shared] refreshCrosshairIfVisible];
        }
    } @catch (NSException *ex) {
        [STBConfig log:@"touchesBegan hook exception: %@", ex.reason];
    }
}

static void hook_touchesEnded(id self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    orig_touchesEnded(self, _cmd, touches, event);
    @try {
        if (![STBConfig shared].enabled) return;
        if (![self isKindOfClass:[UIView class]]) return;
        if (object_getClass(self) == kSTBTicketCoords || object_getClass(self) == kSTBSpots) {
            UIView *view = (UIView *)self;
            UITouch *t = touches.anyObject;
            if (!t) return;
            CGPoint p = [t locationInView:view];
            STBCaptureRecord *rec = [STBImageCapture shared].latest;
            double nx = -1, ny = -1;
            /* v2 inverse path: convert the touch into the LIVE image view's
             * coordinate space (convertPoint honors every offset/transform/
             * zoom in between), then apply the SAME mapping the display path
             * uses. Never map through this view's own bounds. */
            UIImageView *iv = rec.displayView;
            if (rec && iv && iv.window && view.window && iv.window == view.window) {
                double imgW = rec.image.size.width * rec.image.scale;
                double imgH = rec.image.size.height * rec.image.scale;
                STBScaleMode mode = [STBOverlayController scaleModeForView:iv record:rec];
                STBImageMapping m;
                if (imgW > 0 && imgH > 0 &&
                    stb_compute_mapping(imgW, imgH,
                                        iv.bounds.size.width, iv.bounds.size.height,
                                        mode, &m) == 0) {
                    CGPoint inIV = [iv convertPoint:p fromView:view];
                    double nxA = -1, nyA = -1;
                    if (stb_view_point_to_normalized(&m, imgW, imgH,
                                                     inIV.x, inIV.y,
                                                     &nxA, &nyA) == 0) {
                        nx = nxA; ny = nyA;
                    }
                }
            }
            [STBConfig log:@"game touch ended at (%.1f, %.1f) in %@ -> normalized (%.4f, %.4f)%@",
                p.x, p.y, NSStringFromClass(object_getClass(self)), nx, ny,
                (nx >= 0) ? @"" : @" (no mapping — image not captured yet)"];
        }
    } @catch (NSException *ex) {
        [STBConfig log:@"touchesEnded hook exception: %@", ex.reason];
    }
}

/* ---------------- swizzle helpers ---------------- */
static BOOL swizzleClassMethod(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

static void installHooks(void) {
    ensureClassesResolved();

    BOOL ok1 = swizzleClassMethod([UIImageView class],
                                  @selector(setImage:),
                                  (IMP)hook_setImage, (IMP *)&orig_setImage);
    BOOL ok2 = swizzleClassMethod([UIView class],
                                  @selector(didMoveToWindow),
                                  (IMP)hook_didMoveToWindow, (IMP *)&orig_didMoveToWindow);
    BOOL ok3 = swizzleClassMethod([UIView class],
                                  @selector(touchesBegan:withEvent:),
                                  (IMP)hook_touchesBegan, (IMP *)&orig_touchesBegan);
    BOOL ok4 = swizzleClassMethod([UIView class],
                                  @selector(touchesEnded:withEvent:),
                                  (IMP)hook_touchesEnded, (IMP *)&orig_touchesEnded);

    [STBConfig log:@"hooks installed: setImage=%d didMoveToWindow=%d touchesBegan=%d touchesEnded=%d",
        ok1, ok2, ok3, ok4];
}

__attribute__((constructor))
static void stbtweak_init(void) {
    @autoreleasepool {
        [STBConfig log:@"loaded — research observation build (no entry submission, no game-state modification)"];
        installHooks();
        /* overlay button installs on first didMoveToWindow of a game view */
    }
}
