/*
 * STBCoordinateMath.c — implementation of the pure C coordinate core.
 * Kept free of any Apple dependency so it can be unit-tested on the host.
 */
#include "STBCoordinateMath.h"
#include <math.h>

double stb_clamp01(double v) {
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

int stb_compute_mapping(double img_w, double img_h,
                        double view_w, double view_h,
                        STBScaleMode mode,
                        STBImageMapping *out) {
    if (!out || img_w <= 0 || img_h <= 0 || view_w <= 0 || view_h <= 0)
        return -1;
    out->scale = 0; out->dx = 0; out->dy = 0;
    out->visible_w = img_w; out->visible_h = img_h;

    if (mode == STBScaleFill) {
        /* Non-uniform stretch: separate scales per axis. We approximate with
         * the x-axis scale and expose the discrepancy via visible_ fields. */
        out->scale = img_w / view_w;
        out->dx = 0; out->dy = 0;
        out->visible_w = img_w;
        out->visible_h = img_h;
        return 0;
    }

    double view_aspect = view_w / view_h;
    double img_aspect = img_w / img_h;
    int image_is_wider = img_aspect > view_aspect;

    if (mode == STBScaleAspectFit) {
        /* whole image visible, possible letterboxing inside the view */
        if (image_is_wider) {
            out->scale = img_w / view_w;
            out->dx = 0;
            out->dy = (img_h - view_h * (img_w / view_w)) / 2.0;
        } else {
            out->scale = img_h / view_h;
            out->dx = (img_w - view_w * (img_h / view_h)) / 2.0;
            out->dy = 0;
        }
        out->visible_w = img_w;
        out->visible_h = img_h;
        return 0;
    }

    /* STBScaleAspectFill: image covers view, sides cropped */
    if (image_is_wider) {
        out->scale = img_h / view_h;
        out->dx = (img_w - (img_h * view_w / view_h)) / 2.0;
        out->visible_w = img_h * view_w / view_h;
        out->visible_h = img_h;
    } else {
        out->scale = img_w / view_w;
        out->dy = (img_h - (img_w * view_h / view_w)) / 2.0;
        out->visible_w = img_w;
        out->visible_h = img_w * view_h / view_w;
    }
    return 0;
}

int stb_view_point_to_image_px(const STBImageMapping *m,
                              double vx, double vy,
                              double *out_px, double *out_py) {
    if (!m || !out_px || !out_py) return -1;
    *out_px = vx * m->scale + m->dx;
    *out_py = vy * m->scale + m->dy;
    return 0;
}

int stb_image_px_to_normalized(double img_w, double img_h,
                               double px, double py,
                               double *out_nx, double *out_ny) {
    if (!out_nx || !out_ny || img_w <= 0 || img_h <= 0) return -1;
    *out_nx = stb_clamp01(px / img_w);
    *out_ny = stb_clamp01(py / img_h);
    return 0;
}

int stb_normalized_to_image_px(double img_w, double img_h,
                               double nx, double ny,
                               double *out_px, double *out_py) {
    if (!out_px || !out_py || img_w <= 0 || img_h <= 0) return -1;
    *out_px = stb_clamp01(nx) * img_w;
    *out_py = stb_clamp01(ny) * img_h;
    return 0;
}

/* ---- v2 additions (pixel-exact overlay fix) ---------------------------- */

int stb_content_rect(const STBImageMapping *m,
                     double img_w, double img_h,
                     double view_w, double view_h,
                     STBRect *out) {
    if (!m || !out || img_w <= 0 || img_h <= 0 || view_w <= 0 || view_h <= 0)
        return -1;
    if (m->scale <= 0) return -1;
    /* Stretch: UIKit draws the image over the whole bounds (per-axis). */
    if (m->visible_w >= img_w - 1e-9 && m->visible_h >= img_h - 1e-9 &&
        m->dx == 0.0 && m->dy == 0.0) {
        /* whole image mapped onto the whole view with no offset: for the
         * stretch mode the content rect is the full view; for fit/fill the
         * formula below gives the identical result when aspects match. */
        out->x = 0; out->y = 0; out->w = view_w; out->h = view_h;
        /* Fall through to the general formula check: if the aspects did not
         * match, the fit/fill path below is authoritative instead. */
        if (m->visible_w == img_w && m->visible_h == img_h &&
            fabs(img_w / img_h - view_w / view_h) > 1e-12) {
            /* stretch with mismatched aspects: full bounds (true UIKit behavior) */
            out->x = 0; out->y = 0; out->w = view_w; out->h = view_h;
            return 0;
        }
    }
    out->x = -m->dx / m->scale;
    out->y = -m->dy / m->scale;
    out->w = img_w / m->scale;
    out->h = img_h / m->scale;
    return 0;
}

int stb_image_px_to_view_point(const STBImageMapping *m,
                               double px, double py,
                               double *out_vx, double *out_vy) {
    if (!m || !out_vx || !out_vy || m->scale <= 0) return -1;
    *out_vx = (px - m->dx) / m->scale;
    *out_vy = (py - m->dy) / m->scale;
    return 0;
}

int stb_normalized_to_view_point(const STBImageMapping *m,
                                 double img_w, double img_h,
                                 double nx, double ny,
                                 double *out_vx, double *out_vy) {
    double px, py;
    if (stb_normalized_to_image_px(img_w, img_h, nx, ny, &px, &py) != 0)
        return -1;
    return stb_image_px_to_view_point(m, px, py, out_vx, out_vy);
}

int stb_view_point_to_normalized(const STBImageMapping *m,
                                 double img_w, double img_h,
                                 double vx, double vy,
                                 double *out_nx, double *out_ny) {
    double px, py;
    if (stb_view_point_to_image_px(m, vx, vy, &px, &py) != 0)
        return -1;
    return stb_image_px_to_normalized(img_w, img_h, px, py, out_nx, out_ny);
}
