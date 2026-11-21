/*
 * STBCoordinateMath.h — pure C coordinate-mapping core for the BOTB research tweak.
 *
 * Host-testable on any platform (no UIKit dependency). Handles the mapping
 * between: view points (points), image pixel space (pixels) and normalized
 * [0,1] coordinates, under aspectFit / aspectFill / scaleToFill content modes.
 *
 * All functions return 0 on success, -1 on invalid input.
 */
#ifndef STB_COORDINATE_MATH_H
#define STB_COORDINATE_MATH_H

#include <stddef.h>

typedef enum {
    STBScaleAspectFit = 0,   /* UIViewContentModeScaleAspectFit  */
    STBScaleAspectFill = 1,  /* UIViewContentModeScaleAspectFill */
    STBScaleFill = 2         /* UIViewContentModeScaleToFill     */
} STBScaleMode;

typedef struct {
    double scale;   /* image pixels per view point under the chosen mode */
    double dx;      /* image-space offset of view origin (pixels) */
    double dy;
    double visible_w; /* visible image region width  (pixels) */
    double visible_h; /* visible image region height (pixels) */
} STBImageMapping;

/* Compute the view->image mapping for an image of (img_w x img_h) pixels
 * displayed in a view of (view_w x view_h) points. */
int stb_compute_mapping(double img_w, double img_h,
                        double view_w, double view_h,
                        STBScaleMode mode,
                        STBImageMapping *out);

/* Convert a point in view space to image pixel space. */
int stb_view_point_to_image_px(const STBImageMapping *m,
                              double vx, double vy,
                              double *out_px, double *out_py);

/* Convert image pixel coordinates to normalized [0,1] fractions of the
 * full image (the space BOTB judge coordinates are expressed in). */
int stb_image_px_to_normalized(double img_w, double img_h,
                               double px, double py,
                               double *out_nx, double *out_ny);

/* Normalized [0,1] -> image pixel. */
int stb_normalized_to_image_px(double img_w, double img_h,
                               double nx, double ny,
                               double *out_px, double *out_py);

/* Clamp a normalized coordinate into [0,1]. */
double stb_clamp01(double v);

/* ---- v2 additions (pixel-exact overlay fix) ----------------------------
 * The functions above are UNCHANGED. The helpers below compose them into
 * the two conversion directions the overlay needs, plus the content rect
 * (the sub-rect of the view in which the image is actually displayed).
 * All are pure C and host-testable.
 */

typedef struct {
    double x, y, w, h;
} STBRect;

/* Rect (in view points, relative to the view origin) where the image is
 * actually drawn, derived from the mapping:
 *   aspect fit/fill : origin = (-dx/scale, -dy/scale), size = (img/scale)
 *   stretch (fill)  : the full view bounds (per-axis stretch)
 */
int stb_content_rect(const STBImageMapping *m,
                     double img_w, double img_h,
                     double view_w, double view_h,
                     STBRect *out);

/* Image pixel -> view point (inverse of stb_view_point_to_image_px).
 * For fit/fill modes the result lands inside the content rect. */
int stb_image_px_to_view_point(const STBImageMapping *m,
                               double px, double py,
                               double *out_vx, double *out_vy);

/* Normalized [0,1] -> view point. Exactly:
 *   stb_normalized_to_image_px + stb_image_px_to_view_point
 * so display and touch-back paths share one implementation. */
int stb_normalized_to_view_point(const STBImageMapping *m,
                                 double img_w, double img_h,
                                 double nx, double ny,
                                 double *out_vx, double *out_vy);

/* View point -> normalized [0,1]. Exactly:
 *   stb_view_point_to_image_px + stb_image_px_to_normalized
 * Points outside the content rect clamp to [0,1]. */
int stb_view_point_to_normalized(const STBImageMapping *m,
                                 double img_w, double img_h,
                                 double vx, double vy,
                                 double *out_nx, double *out_ny);

#endif /* STB_COORDINATE_MATH_H */
