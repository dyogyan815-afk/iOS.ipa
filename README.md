# BOTB tweak — v2 "PixelExact" unsigned ipa (GitHub Actions build)

This repository builds an **unsigned** `BOTB_v2_PixelExact_unsigned.ipa` with
GitHub Actions and publishes it as a Release asset. The ipa carries the
BOTB app with the research tweak `BOTBTweak.dylib` (v2 "Pixel-Exact
Overlay") injected; it is intentionally unsigned — you sign it yourself
with your own Apple ID / developer certificate.

## Repository layout

| Path | Purpose |
| --- | --- |
| `tweak/BOTBTweak/` | Full v2 tweak sources (`STBTweakCore.m`, `STBOverlayUI.m`, `STBCoordinateMath.c/h`, `STBImageCapture.m`, `STBAnalyzerInterface.m`, `STBConfig.m`) + Theos `Makefile` reference |
| `tweak/tests/test_coordinate_math.c` | Host unit tests for the coordinate core (35 checks, run in CI) |
| `tweak/project.yml` | XcodeGen spec for the dynamic-library target |
| `packaging/assemble_ipa.py` | Repackages the verified seed with ONLY the dylib replaced; enforces byte-parity of every other entry |
| `seed/` | The verified v2 "PixelExact" ipa, split into 24 MB parts (GitHub 100 MB file limit) + SHA-256 checksum |
| `.github/workflows/build.yml` | The CI pipeline |

## What the Actions build does

1. Reassembles the seed ipa from `seed/` and verifies its SHA-256
   (`913f5d057d674f2fe8f4106ea12c1bcf764021704123f373dec2589d3e5e9e7d`).
2. Runs the 35 coordinate-math unit tests on the runner (host compile).
3. Generates the Xcode project with XcodeGen and builds
   `BOTBTweak.dylib` with `xcodebuild -sdk iphoneos`
   `CODE_SIGNING_ALLOWED=NO` (arm64, min iOS 16.1, ARC, `-O2`,
   install name `@executable_path/BOTBTweak.dylib`).
4. Compares the exported symbol set of the fresh dylib against the
   verified v2 dylib (must be identical).
5. Repackages: every entry of the seed ipa is copied **byte-identical**
   except `Payload/BOTB.app/BOTBTweak.dylib`, which is the fresh CI build.
   The main executable (which already carries
   `LC_LOAD_DYLIB @executable_path/BOTBTweak.dylib`) is untouched and
   verified byte-identical. Output zip integrity + entry parity are
   verified before the release step.
6. Publishes the result as a Release asset (tag `v2-pixelexact-unsigned`).

## Getting the ipa

Releases page: `https://github.com/dyogyan815-afk/iOS.ipa/releases`
Direct asset: `https://github.com/dyogyan815-afk/iOS.ipa/releases/download/v2-pixelexact-unsigned/BOTB_v2_PixelExact_unsigned.ipa`

## Signing it yourself

The ipa ships unsigned. Sign with your own certificate, e.g.:

- **KSign / ESign** (on-device, Apple ID cert) — same flow as before
- **Sideloadly** (PC, Apple ID)
- **AltStore / SideStore** (Apple ID)
- **codesign** (developer certificate + provisioning profile)

After signing, the overlay feature set is unchanged from v2:
capture + crosshair + heatmap + export; the tweak never auto-submits,
never touches network/tickets/payments/account data.

## Seed provenance

`seed/` is the verified v2 "PixelExact" build output
(`BOTB_Tweak_v2_PixelExact.ipa`, sha256
`913f5d057d674f2fe8f4106ea12c1bcf764021704123f373dec2589d3e5e9e7d`,
262/262 zip entries valid, 35/35 unit tests PASS). The v2 sources in
`tweak/BOTBTweak/` are the exact sources that produced its dylib; the CI
rebuild only replaces that dylib, so the assembled result is equivalent
to the verified v2 ipa with a freshly compiled tweak. See
`CHANGELOG_v2.md` for the full v2 change list (what was wrong in v1 and
what changed).

---

# Private Judges Workspace (independent app)

`judges-workspace/` contains the independent BOTB Private Judges Edition — a
standalone SwiftUI app (not the original BOTB application, and no claim to be).
Source-of-truth archive with full documentation: the `Botb01` repository.

Workflow `.github/workflows/judges.yml` builds it on every change to
`judges-workspace/**`:

1. Python coordinate-engine regression suite (50 tests, mirrors the Swift engine).
2. Swift seven-judge core checks (`swiftc` compile + execute).
3. `xcodegen generate` + `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO`.
4. Packages `Private_Judges_Workspace.ipa`, verifies bundle id/plist/zip,
   and publishes it as a Release asset with its SHA-256
   (tag `private-judges-workspace-v1.2.0`).

App v1.2.0: 4-tab dashboard (Judge submission / Local seven-judge panel /
Multi-judge comparison with human approval gate / AI proposals kept strictly
separate from consensus), coordinate-synced loupe magnifier, JSON export.
