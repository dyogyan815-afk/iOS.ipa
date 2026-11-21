"""
BOTB Judges Edition - Authoritative Coordinate Engine (reference implementation).

This module is the SINGLE AUTHORITATIVE coordinate system for all crosshair
placement, adjustment, consensus and verification in the Judges Edition.
The Swift port in ios/JudgesEdition/CoordinateEngine.swift mirrors this module
rule-for-rule; both must produce identical results for identical inputs.

Coordinate spaces
-----------------
P  (pixel space, CANONICAL) : integer (x, y); origin at image top-left,
                              x grows right, y grows down.
                              0 <= x < W and 0 <= y < H.
N  (normalized space)       : (x_n, y_n) with x_n = x / W, y_n = y / H,
                              each in [0, 1). Derived from P, never stored as
                              the primary value in records.

Identity rules
--------------
- Image identity is the SHA-256 of the raw image bytes (never a filename).
- Record integrity is the SHA-256 of the canonical JSON serialization
  (UTF-8, sorted keys, compact separators).

All arithmetic in this module is deterministic IEEE-754 double precision.
"""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass, field
from typing import Dict, List, Sequence, Tuple

ENGINE_VERSION = "1.0.0"

# Weiszfeld parameters (deterministic consensus)
WEISZFELD_MAX_ITER = 100
WEISZFELD_TOL = 1e-7
_WEISZFELD_EPS = 1e-9


class CoordinateError(ValueError):
    """Raised for invalid coordinate, image or identity input."""


# ---------------------------------------------------------------------------
# Canonical serialization and hashing
# ---------------------------------------------------------------------------

def canonical_json(obj) -> str:
    """Canonical JSON string: UTF-8, sorted keys, compact separators."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False)


def record_hash(obj) -> str:
    """SHA-256 hex digest of the canonical JSON serialization."""
    return hashlib.sha256(canonical_json(obj).encode("utf-8")).hexdigest()


def image_sha256(data: bytes) -> str:
    """Image identity: SHA-256 of raw image bytes."""
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------------------
# Image identity
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class ImageIdentity:
    sha256: str
    width_px: int
    height_px: int

    def __post_init__(self) -> None:
        if len(self.sha256) != 64 or any(c not in "0123456789abcdef" for c in self.sha256):
            raise CoordinateError("image sha256 must be a 64-char lowercase hex digest")
        if not isinstance(self.width_px, int) or not isinstance(self.height_px, int):
            raise CoordinateError("image dimensions must be integers")
        if self.width_px < 2 or self.height_px < 2:
            raise CoordinateError("image dimensions must be >= 2 px")

    @staticmethod
    def from_bytes(data: bytes, width_px: int, height_px: int) -> "ImageIdentity":
        return ImageIdentity(image_sha256(data), width_px, height_px)

    def validate_point_inside(self, x: int, y: int) -> None:
        if not (0 <= x < self.width_px and 0 <= y < self.height_px):
            raise CoordinateError(
                f"point ({x}, {y}) outside image {self.width_px}x{self.height_px}")


# ---------------------------------------------------------------------------
# Points and conversions
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class PixelPoint:
    """CANONICAL coordinate: integer pixel in image space (origin top-left)."""
    x: int
    y: int

    def __post_init__(self) -> None:
        if not isinstance(self.x, int) or not isinstance(self.y, int):
            raise CoordinateError("pixel coordinates must be integers")


def clamp(value: int, lo: int, hi: int) -> int:
    if hi < lo:
        raise CoordinateError("clamp range empty")
    return max(lo, min(hi, value))


def to_normalized(p: PixelPoint, width: int, height: int) -> Tuple[float, float]:
    """P -> N. Exact division; result in [0, 1)."""
    if width < 2 or height < 2:
        raise CoordinateError("image dimensions must be >= 2 px")
    if not (0 <= p.x < width and 0 <= p.y < height):
        raise CoordinateError("point outside image bounds")
    return p.x / width, p.y / height


def from_normalized(nx: float, ny: float, width: int, height: int) -> PixelPoint:
    """N -> P. round-half-to-even, then clamp. Round-trip error <= 1 px."""
    if width < 2 or height < 2:
        raise CoordinateError("image dimensions must be >= 2 px")
    if not (math.isfinite(nx) and math.isfinite(ny)):
        raise CoordinateError("normalized coordinates must be finite")
    if not (-1.0 <= nx <= 2.0 and -1.0 <= ny <= 2.0):
        raise CoordinateError("normalized coordinates far out of range")
    x = clamp(int(round(nx * width)), 0, width - 1)
    y = clamp(int(round(ny * height)), 0, height - 1)
    return PixelPoint(x, y)


def roundtrip_error_px(p: PixelPoint, width: int, height: int) -> Tuple[int, int]:
    """Max guaranteed |N->P| error is 1 px per axis. Returns actual error."""
    nx, ny = to_normalized(p, width, height)
    q = from_normalized(nx, ny, width, height)
    return abs(q.x - p.x), abs(q.y - p.y)


# ---------------------------------------------------------------------------
# Distances
# ---------------------------------------------------------------------------

def euclidean_distance_px(a: PixelPoint, b: PixelPoint) -> float:
    return math.hypot(a.x - b.x, a.y - b.y)


def normalized_distance(a: PixelPoint, b: PixelPoint, width: int, height: int) -> float:
    """Distance as a fraction of the image diagonal."""
    diag = math.hypot(width, height)
    if diag <= 0:
        raise CoordinateError("degenerate image")
    return euclidean_distance_px(a, b) / diag


# ---------------------------------------------------------------------------
# Consensus (multi-judge)
# ---------------------------------------------------------------------------

def per_axis_median(points: Sequence[PixelPoint]) -> PixelPoint:
    """Per-axis median. Even counts average the two middle values and round
    half to even (deterministic)."""
    if not points:
        raise CoordinateError("no points supplied")
    xs = sorted(p.x for p in points)
    ys = sorted(p.y for p in points)
    n = len(points)
    mx = xs[n // 2] if n % 2 else round((xs[n // 2 - 1] + xs[n // 2]) / 2)
    my = ys[n // 2] if n % 2 else round((ys[n // 2 - 1] + ys[n // 2]) / 2)
    return PixelPoint(int(mx), int(my))


def geometric_median_float(points: Sequence[PixelPoint]) -> Tuple[float, float]:
    """Weiszfeld iteration from the per-axis median; deterministic."""
    if not points:
        raise CoordinateError("no points supplied")
    med = per_axis_median(points)
    fx, fy = float(med.x), float(med.y)
    for _ in range(WEISZFELD_MAX_ITER):
        wsum = 0.0
        sx = sy = 0.0
        for p in points:
            d = max(math.hypot(p.x - fx, p.y - fy), _WEISZFELD_EPS)
            w = 1.0 / d
            wsum += w
            sx += w * p.x
            sy += w * p.y
        nx, ny = sx / wsum, sy / wsum
        if math.hypot(nx - fx, ny - fy) < WEISZFELD_TOL:
            fx, fy = nx, ny
            break
        fx, fy = nx, ny
    return fx, fy


def consensus(points: Sequence[PixelPoint],
              method: str = "geometric_median") -> Dict:
    """Authoritative consensus point for a set of judge crosshairs.

    Returns a dict (JSON-ready) with the canonical integer pixel point and
    bookkeeping fields.
    """
    if method not in ("geometric_median", "per_axis_median"):
        raise CoordinateError(f"unknown consensus method: {method}")
    if not points:
        raise CoordinateError("no points supplied")
    if method == "per_axis_median":
        med = per_axis_median(points)
        cx, cy = float(med.x), float(med.y)
    else:
        cx, cy = geometric_median_float(points)
    point = PixelPoint(int(round(cx)), int(round(cy)))
    return {
        "method": method,
        "x_px": point.x,
        "y_px": point.y,
        "raw_x": round(cx, 6),
        "raw_y": round(cy, 6),
        "engine_version": ENGINE_VERSION,
    }


def pairwise_max_spread(points: Sequence[PixelPoint]) -> float:
    """Maximum pairwise Euclidean distance in pixels."""
    if len(points) < 2:
        return 0.0
    worst = 0.0
    for i in range(len(points)):
        for j in range(i + 1, len(points)):
            worst = max(worst, euclidean_distance_px(points[i], points[j]))
    return worst


def within_tolerance(a: PixelPoint, b: PixelPoint, tolerance_px: float) -> bool:
    if tolerance_px < 0:
        raise CoordinateError("tolerance must be >= 0")
    return euclidean_distance_px(a, b) <= tolerance_px


def agreement_ratio(points: Sequence[PixelPoint], consensus_point: PixelPoint,
                    tolerance_px: float) -> float:
    """Fraction of judge points within tolerance of the consensus point."""
    if not points:
        raise CoordinateError("no points supplied")
    hits = sum(1 for p in points
               if within_tolerance(p, consensus_point, tolerance_px))
    return hits / len(points)


def evaluate_consensus(points: Sequence[PixelPoint], tolerance_px: float,
                       method: str = "geometric_median") -> Dict:
    """Full consensus evaluation used by the multi-judge comparison screen."""
    con = consensus(points, method=method)
    cpoint = PixelPoint(con["x_px"], con["y_px"])
    ratio = agreement_ratio(points, cpoint, tolerance_px)
    return {
        **con,
        "tolerance_px": tolerance_px,
        "max_spread_px": round(pairwise_max_spread(points), 3),
        "agreement_ratio": round(ratio, 4),
        "n_judges": len(points),
    }
