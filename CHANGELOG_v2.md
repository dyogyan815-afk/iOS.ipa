# CHANGELOG — BOTBTweak v2 "Pixel-Exact Overlay" (2026-11-02)

## Which view was wrong
`-[STBCrosshairOverlay refreshMapping]` computed its mapping from the
overlay's **superview** (`self.superview.bounds`) and from a content mode
recorded once at capture time (`rec.scaleMode`), then wrote the result with a
raw frame assignment **in superview coordinates**. The overlay's superview is
NOT guaranteed to be the game's real image container: any origin offset,
inset, safe-area padding or transform between the view the crosshair was
attached to and the view that actually displays the photo (or a stale
`rec.scaleMode`) shifted the drawn crosshair by that unconverted delta.
The inverse path (`hook_touchesEnded`) had the mirror-image bug: it mapped
game touches through the *touching view's* bounds (`view.bounds` of
STBTicketCoordinatesView / STBSpotsView), not through the image view, so
touch-back and display used two different coordinate systems.

Measured effect (user's screenshot, 4416x3336 image): stored (0.516, 0.552),
drawn at ~(0.511, 0.546) = game readout X:2258 Y:1823 instead of X:2279
Y:1841 — about 6 screen px (~2 pt at 3x) up-left, ~20 image px on both axes.

## What was changed (files)
- **STBOverlayUI.m**
  - `refreshMapping` now resolves the LIVE game image view (weak ref kept by
    `STBOverlayController.crosshairImageView` / `STBCaptureRecord.displayView`),
    builds the mapping against THAT view's `bounds` and THAT view's live
    `contentMode` (record only as fallback), then places the crosshair with
    `-[UIImageView convertPoint:toView:]` into the overlay's coordinate space,
    so origin offsets, insets, safe areas, transforms and zoom state are
    honored exactly. The crosshair is attached as a SIBLING of the image view
    (`iv.superview ?: iv.window`), never inside it — no original BOTB view is
    resized, moved, restyled or padded; `pointInside:` still passes every
    touch through except on the crosshair's own handle.
  - Label (`_tag`) is now computed FROM THE DRAWN POINT: frame.origin is
    converted back through the same view path (`convertPoint:`), then
    `stb_view_point_to_normalized` gives the normalized value that is really
    on screen. After the fix, "51.6%, 55.2%" corresponds to game readout
    X 2279, Y 1841 on a 4416x3336 image.
  - `onPan:` now runs the inverse path first (`syncNormalizedFromDrawnOrigin:`)
    before re-running the display path, so dragging stores exactly what was
    drawn and the crosshair no longer snaps back to the pre-drag position.
  - `hook_touchesEnded` (STBTweakCore.m) inverse path rewritten the same way:
    touch -> `convertPoint:fromView:` into the live image view -> same mapping
    as display -> normalized. Display and touch-back now share one geometry.
  - New `STBHeatmapView`: heatmap of the primary prediction (green peak) and
    alternates (amber blobs), `userInteractionEnabled = NO`. Its frame is the
    SAME content rect (from `+contentRectForView:record:`) converted through
    the same `convertPoint:` call as the crosshair, so its peak is exactly
    under the crosshair. Toggle button added to the panel.
  - Panel buttons re-flowed (Crosshair / Heatmap / Export); exports
    (`annotated_*.png`, `analysis_*.json`, `report_*.txt` / capture JSON),
    alternates and the analyzer interface are unchanged. The tweak still
    never auto-submits, never touches network/tickets/payments/account data.
- **STBCoordinateMath.[ch]** — v2 additions only (the verified v1 functions
  `stb_compute_mapping`, `stb_normalized_to_image_px`, `stb_image_px_to_normalized`,
  `stb_view_point_to_image_px` are byte-for-byte unchanged):
  `stb_content_rect` (where the image really sits inside the view),
  `stb_image_px_to_view_point`, `stb_normalized_to_view_point`,
  `stb_view_point_to_normalized` (the two composed round-trip directions).
- **STBTweakCore.m** — inverse path + resync of the overlay to live geometry
  on every game touch (`refreshCrosshairIfVisible`), so zoom/layout changes
  cannot leave a stale mapping on screen.
- **STBImageCapture.[h,m]** — `STBCaptureRecord.displayView` (weak) keeps the
  LIVE displaying image view for both conversion paths.
- **test_coordinate_math.c** — v2 tests: aspect check, round-trip at corner /
  center / right edge, label-vs-game-readout (X2279 Y1841), heatmap
  alignment, second screen size, stretch mode, and an explicit reproduction
  of the v1 wrong-view bug.

## Before / after offset
| Metric | v1 (buggy) | v2 (fixed) |
|---|---|---|
| Drawn-vs-stored offset (user screenshot) | ~6 screen px (~2 pt @3x) up-left, ~20 image px per axis | 0 px nominal; round-trip error <= 1e-9 normalized (<= 0.005 image px) |
| Label vs game readout | label showed stored (0.516/0.552) while pixels read X2258/Y1823 | label computed from drawn point; matches readout (X2279/Y1841 for 0.516/0.552) |
| Touch-back -> stored round trip | not wired (drag snapped back) | |A-B| < 0.0005 required; measured ~1e-16 at corner / center / right edge |
| Heatmap vs crosshair | n/a (new) | same content rect + same convertPoint path; peak coincides to 1e-9 pt |

## Verification (host, this sandbox)
- 35/35 checks PASS in `test_coordinate_math.c` (incl. the v1-bug reproduction).
- `BOTB_Tweak_v2_PixelExact.ipa`: 262/262 entries valid, 261 byte-identical
  to the v1 IPA, ONLY `Payload/BOTB.app/BOTBTweak.dylib` replaced;
  main executable byte-identical (LC_LOAD_DYLIB untouched); dylib = arm64
  Mach-O filetype 6, `LC_ID_DYLIB @executable_path/BOTBTweak.dylib`.
- On-device behaviour NOT TESTED here (no iOS device in sandbox) — install
  with KSign as before (INSTALL_KSIGN.md unchanged and still applies).
