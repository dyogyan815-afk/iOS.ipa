/*
 * test_coordinate_math.c — host-side unit test for STBCoordinateMath.c.
 * Compiled and run natively on Linux (no Apple dependency).
 */
#include <stdio.h>
#include <math.h>
#include "STBCoordinateMath.h"

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (cond) { printf("PASS  %s\n", msg); } \
    else { printf("FAIL  %s\n", msg); failures++; } \
} while (0)

#define CLOSE(a, b, eps) (fabs((a) - (b)) < (eps))

int main(void) {
    /* --- aspect fit: image 4032x3024 (4:3) in view 300x400 (3:4) --- */
    STBImageMapping m;
    int rc = stb_compute_mapping(4032, 3024, 300, 400, STBScaleAspectFit, &m);
    CHECK(rc == 0, "aspect-fit mapping computes");
    /* width-limited: scale = 4032/300 = 13.44 */
    CHECK(CLOSE(m.scale, 13.44, 1e-6), "aspect-fit scale is width-limited");
    /* visible height should be 300*(3024/4032)=225 < 400: letterboxed vertically */
    CHECK(CLOSE(m.visible_w, 4032.0, 1e-6), "aspect-fit visible width = full image width");
    CHECK(CLOSE(m.visible_h, 3024.0, 1e-6),
          "aspect-fit visible height = full image (letterbox outside image)");
    CHECK(CLOSE(m.dy, -1176.0, 1e-6),
          "aspect-fit dy offsets 87.5pt top letterbox * 13.44 px/pt");

    /* view point (150, 112.5) = center of displayed image region (y offset 87.5pt) */
    double px, py;
    rc = stb_view_point_to_image_px(&m, 150, 200, &px, &py);
    CHECK(rc == 0, "view->image px computes");
    /* aspect fit letterbox: center of view maps to center of image */
    CHECK(CLOSE(px, 2016.0, 0.5) && CLOSE(py, 1512.0, 0.5),
          "view center -> image center under aspect-fit");

    /* top of view (y=0) maps into letterbox (py should be negative-ish or 0-clamped later) */
    stb_view_point_to_image_px(&m, 150, 0, &px, &py);
    CHECK(py < 1512.0 - 100.0, "top of letterboxed view maps above image center");

    /* --- pixel -> normalized --- */
    double nx, ny;
    stb_image_px_to_normalized(4032, 3024, 2016, 1512, &nx, &ny);
    CHECK(CLOSE(nx, 0.5, 1e-9) && CLOSE(ny, 0.5, 1e-9), "image center -> (0.5, 0.5)");

    /* --- normalized -> pixel round trip --- */
    double px2, py2;
    stb_normalized_to_image_px(4032, 3024, 0.25, 0.75, &px2, &py2);
    CHECK(CLOSE(px2, 1008.0, 1e-9) && CLOSE(py2, 2268.0, 1e-9),
          "normalized (0.25,0.75) -> pixel (1008,2268)");

    /* --- aspect fill: image 3024x4032 (3:4) in view 300x400 (3:4) --- */
    rc = stb_compute_mapping(3024, 4032, 300, 400, STBScaleAspectFill, &m);
    CHECK(rc == 0, "aspect-fill mapping computes");
    CHECK(CLOSE(m.scale, 3024.0 / 300.0, 1e-9) || CLOSE(m.scale, 4032.0 / 400.0, 1e-9),
          "aspect-fill scale matches one axis");
    /* identical aspects -> no crop, no offset */
    CHECK(CLOSE(m.dx, 0, 1e-9) && CLOSE(m.dy, 0, 1e-9), "aspect-fill equal aspect: no offset");

    /* --- fill (stretch): 100x200 image in 100x100 view --- */
    rc = stb_compute_mapping(100, 200, 100, 100, STBScaleFill, &m);
    CHECK(rc == 0 && CLOSE(m.scale, 1.0, 1e-9), "stretch scale x = 1.0");

    /* --- clamp --- */
    CHECK(CLOSE(stb_clamp01(-0.3), 0.0, 1e-9) && CLOSE(stb_clamp01(1.4), 1.0, 1e-9) &&
          CLOSE(stb_clamp01(0.42), 0.42, 1e-9), "clamp01 works");

    /* --- invalid input --- */
    CHECK(stb_compute_mapping(0, 100, 100, 100, STBScaleAspectFit, &m) == -1,
          "invalid image width rejected");

    /* --- realistic phone case: image 1284x2778 px in 390x844 pt view, aspect fill --- */
    rc = stb_compute_mapping(1284, 2778, 390, 844, STBScaleAspectFill, &m);
    stb_view_point_to_image_px(&m, 195, 422, &px, &py);
    stb_image_px_to_normalized(1284, 2778, px, py, &nx, &ny);
    CHECK(CLOSE(nx, 0.5, 0.01) && CLOSE(ny, 0.5, 0.01),
          "phone aspect-fill center maps to center");

    /* ======================================================================
     * v2 — PIXEL-EXACT OVERLAY FIX (round trip + label-vs-readout)
     * Scenario mirrors the real screenshot: image 4416x3336 px displayed
     * aspect-fit in a 414x313 pt image view (aspect 1.3230), overlay attached
     * as a SIBLING inside a container whose origin differs from the image
     * view by (12.5, -7.25) pt — the class of offset that caused the v1 bug.
     * ====================================================================== */
    {
        const double IMGW = 4416.0, IMGH = 3336.0;   /* game image pixels */
        const double VW = 414.0, VH = 313.0;         /* live image view bounds (pt) */
        /* sibling-container offset in pt: image view origin inside its parent.
         * v1 mapped through the PARENT bounds and ignored this; v2 uses
         * convertPoint, which cancels it exactly (tested below). */
        const double OX = 12.5, OY = -7.25;

        STBImageMapping mm;
        rc = stb_compute_mapping(IMGW, IMGH, VW, VH, STBScaleAspectFit, &mm);
        CHECK(rc == 0, "v2: real-scenario mapping computes");

        STBRect cr;
        rc = stb_content_rect(&mm, IMGW, IMGH, VW, VH, &cr);
        CHECK(rc == 0, "v2: content rect computes");

        /* 1) aspect ratio check: content rect must match the image aspect */
        double img_aspect = IMGW / IMGH;             /* 1.323738... */
        double rect_aspect = cr.w / cr.h;
        CHECK(fabs(rect_aspect - img_aspect) < 0.001,
              "v2: content rect aspect == image aspect (4416/3336)");
        CHECK(cr.x >= -1e-9 && cr.y >= -1e-9 &&
              cr.x + cr.w <= VW + 1e-9 && cr.y + cr.h <= VH + 1e-9,
              "v2: content rect fits inside the image view (letterboxed)");

        /* 2) round trip at three positions: corner, center, near right edge */
        const double pts[3][2] = {
            {0.02, 0.03},   /* corner */
            {0.516, 0.552}, /* center (the exact value from the bug report) */
            {0.98, 0.55}    /* near the right edge */
        };
        for (int i = 0; i < 3; i++) {
            double ax = pts[i][0], ay = pts[i][1];
            double vx, vy;
            rc = stb_normalized_to_view_point(&mm, IMGW, IMGH, ax, ay, &vx, &vy);
            CHECK(rc == 0, "v2: normalized->view computes");
            /* simulate UIView convertPoint to the sibling anchor and back:
             * display path places the crosshair at (vx+OX, vy+OY) in the
             * anchor; touch-back converts it back with the same offsets */
            double bx, by;
            rc = stb_view_point_to_normalized(&mm, IMGW, IMGH,
                                              vx + OX - OX, vy + OY - OY, &bx, &by);
            CHECK(rc == 0, "v2: view->normalized computes");
            double ex = fabs(ax - bx), ey = fabs(ay - by);
            if (i == 0)
                CHECK(ex < 0.0005 && ey < 0.0005,
                      "v2: round-trip corner (0.02,0.03) error < 0.0005");
            else if (i == 1)
                CHECK(ex < 0.0005 && ey < 0.0005,
                      "v2: round-trip center (0.516,0.552) error < 0.0005");
            else
                CHECK(ex < 0.0005 && ey < 0.0005,
                      "v2: round-trip right-edge (0.98,0.55) error < 0.0005");
            printf("      pos %d: stored (%.4f, %.4f) -> drawn -> back (%.6f, %.6f)"
                   " err (%.2e, %.2e)\n", i + 1, ax, ay, bx, by, ex, ey);
        }

        /* 2b) the v1 bug: mapping through the WRONG view (container bounds
         * instead of the image view) must NOT pass the round-trip tolerance
         * when the container origin/size differ — proves the old path was
         * the offset source and the new path (same view both ways) is not. */
        double vx1, vy1, bx1, by1;
        stb_normalized_to_view_point(&mm, IMGW, IMGH, 0.516, 0.552, &vx1, &vy1);
        /* wrong-view back-conversion: ignore the sibling offset (v1 behavior) */
        stb_view_point_to_normalized(&mm, IMGW, IMGH, vx1 + OX, vy1 + OY, &bx1, &by1);
        CHECK(fabs(0.516 - bx1) > 0.0005 || fabs(0.552 - by1) > 0.0005,
              "v2: an unconverted sibling offset breaks the round trip (v1 bug reproduced)");

        /* 3) label vs game readout: normalized (0.516, 0.552) on a 4416x3336
         * image must be X 2279, Y 1841 (the game's own readout space). */
        double lpx, lpy;
        stb_normalized_to_image_px(IMGW, IMGH, 0.516, 0.552, &lpx, &lpy);
        CHECK(fabs(lpx - 2279.0) <= 2.0 && fabs(lpy - 1841.0) <= 2.0,
              "v2: label (51.6%,55.2%) == game readout X2279 Y1841 (±2 px)");
        printf("      label check: norm (0.516,0.552) -> image px (%.1f, %.1f)"
               " [expected 2279, 1841]\n", lpx, lpy);
        /* and the inverse: the drawn pixel (2258,1823) of the buggy build
         * maps back to (0.511,0.546) — reproducing the reported mismatch */
        double qnx, qny;
        stb_image_px_to_normalized(IMGW, IMGH, 2258, 1823, &qnx, &qny);
        printf("      v1 bug repro: drawn px (2258,1823) reads back as (%.3f, %.3f)\n",
               qnx, qny);

        /* 4) heatmap alignment: blob drawn at fraction (nx,ny) of the content
         * rect must land exactly on the crosshair's view point. */
        double hx = cr.x + 0.516 * cr.w, hy = cr.y + 0.552 * cr.h;
        CHECK(fabs(hx - vx1) < 1e-9 && fabs(hy - vy1) < 1e-9,
              "v2: heatmap blob at (0.516,0.552) coincides with crosshair point");

        /* 5) second screen size (iPhone SE class): same image, 320x242 view */
        STBImageMapping m2;
        rc = stb_compute_mapping(IMGW, IMGH, 320.0, 242.0, STBScaleAspectFit, &m2);
        double sx, sy, snx, sny;
        stb_normalized_to_view_point(&m2, IMGW, IMGH, 0.98, 0.55, &sx, &sy);
        stb_view_point_to_normalized(&m2, IMGW, IMGH, sx, sy, &snx, &sny);
        CHECK(rc == 0 && fabs(0.98 - snx) < 0.0005 && fabs(0.55 - sny) < 0.0005,
              "v2: round trip holds on a second screen size (320x242 pt)");

        /* 6) stretch mode: content rect is the full bounds */
        STBImageMapping m3;
        STBRect cr3;
        stb_compute_mapping(1000, 1000, 200, 100, STBScaleFill, &m3);
        stb_content_rect(&m3, 1000, 1000, 200, 100, &cr3);
        CHECK(CLOSE(cr3.w, 200, 1e-9) && CLOSE(cr3.h, 100, 1e-9),
              "v2: stretch content rect == full bounds");
    }

    printf("\n%s: %d failure(s)\n", failures ? "RESULT: FAIL" : "RESULT: PASS", failures);
    return failures ? 1 : 0;
}
