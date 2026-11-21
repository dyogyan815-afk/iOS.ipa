"""Regression tests for the authoritative coordinate engine (spec section 7)."""
import os, sys, unittest
ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
from coordinate_engine import (
    CoordinateError, ImageIdentity, PixelPoint, agreement_ratio, canonical_json,
    clamp, consensus, euclidean_distance_px, evaluate_consensus, from_normalized,
    geometric_median_float, image_sha256, normalized_distance, pairwise_max_spread,
    per_axis_median, record_hash, roundtrip_error_px, to_normalized,
    within_tolerance, ENGINE_VERSION,
)


class TestConversions(unittest.TestCase):
    def test_identity_points(self):
        for (w, h) in [(2, 2), (17, 31), (1000, 750), (4096, 2160)]:
            for (x, y) in [(0, 0), (w - 1, h - 1), (w // 2, h // 2)]:
                p = PixelPoint(x, y)
                nx, ny = to_normalized(p, w, h)
                self.assertGreaterEqual(nx, 0.0)
                self.assertLess(nx, 1.0)
                q = from_normalized(nx, ny, w, h)
                self.assertEqual((q.x, q.y), (x, y))

    def test_roundtrip_error_bounded(self):
        checked = 0
        for (w, h) in [(3, 5), (100, 73), (1920, 1080)]:
            for x in range(0, w, max(1, w // 17)):
                for y in range(0, h, max(1, h // 17)):
                    dx, dy = roundtrip_error_px(PixelPoint(x, y), w, h)
                    self.assertLessEqual(dx, 1)
                    self.assertLessEqual(dy, 1)
                    checked += 1
        self.assertGreater(checked, 100)

    def test_clamp_and_rejection(self):
        self.assertEqual(clamp(-5, 0, 10), 0)
        self.assertEqual(clamp(15, 0, 10), 10)
        with self.assertRaises(CoordinateError):
            to_normalized(PixelPoint(-1, 0), 100, 100)
        with self.assertRaises(CoordinateError):
            to_normalized(PixelPoint(100, 0), 100, 100)
        with self.assertRaises(CoordinateError):
            ImageIdentity("a" * 64, 1, 1)
        q = from_normalized(-0.5, 1.5, 100, 100)
        self.assertEqual((q.x, q.y), (0, 99))

    def test_non_integer_pixel_rejected(self):
        with self.assertRaises(CoordinateError):
            PixelPoint(1.5, 2)


class TestDistances(unittest.TestCase):
    def test_345_triangle(self):
        a, b = PixelPoint(0, 0), PixelPoint(3, 4)
        self.assertAlmostEqual(euclidean_distance_px(a, b), 5.0, places=12)

    def test_normalized_distance_uses_diagonal(self):
        a, b = PixelPoint(0, 0), PixelPoint(30, 40)
        nd = normalized_distance(a, b, 100, 100)
        self.assertAlmostEqual(nd, 50.0 / (100.0 * (2 ** 0.5)), places=12)

    def test_spread(self):
        pts = [PixelPoint(0, 0), PixelPoint(10, 0), PixelPoint(3, 4)]
        self.assertAlmostEqual(pairwise_max_spread(pts), 10.0, places=12)
        self.assertEqual(pairwise_max_spread([PixelPoint(1, 1)]), 0.0)


class TestConsensus(unittest.TestCase):
    def test_symmetric_square_geometric_median_is_center(self):
        pts = [PixelPoint(10, 10), PixelPoint(10, 30),
               PixelPoint(30, 10), PixelPoint(30, 30)]
        c = consensus(pts, method="geometric_median")
        self.assertEqual((c["x_px"], c["y_px"]), (20, 20))

    def test_outlier_robustness(self):
        base = [PixelPoint(100, 100), PixelPoint(102, 98),
                PixelPoint(99, 101), PixelPoint(101, 99)]
        with_outlier = base + [PixelPoint(500, 500)]
        c1 = consensus(base)
        c2 = consensus(with_outlier)
        # geometric median must barely move despite the far outlier
        self.assertLess(euclidean_distance_px(
            PixelPoint(c1["x_px"], c1["y_px"]),
            PixelPoint(c2["x_px"], c2["y_px"])), 5.0)

    def test_per_axis_median_even_count(self):
        pts = [PixelPoint(0, 0), PixelPoint(10, 2)]
        m = per_axis_median(pts)
        self.assertEqual((m.x, m.y), (5, 1))

    def test_single_point(self):
        c = consensus([PixelPoint(7, 9)])
        self.assertEqual((c["x_px"], c["y_px"]), (7, 9))

    def test_agreement_ratio_and_gate(self):
        pts = [PixelPoint(100, 100), PixelPoint(103, 104),
               PixelPoint(200, 200)]
        con = consensus(pts)
        cp = PixelPoint(con["x_px"], con["y_px"])
        self.assertAlmostEqual(agreement_ratio(pts, cp, 10.0), 2 / 3, places=6)
        # Geometric median sits at vertex B(103,104): angle at B > 120 deg,
        # so only B is within 0.5 px of the consensus point.
        self.assertAlmostEqual(agreement_ratio(pts, cp, 0.5), 1 / 3, places=12)
        ev = evaluate_consensus(pts, 10.0)
        self.assertEqual(ev["n_judges"], 3)
        self.assertGreater(ev["max_spread_px"], 140.0)

    def test_empty_and_unknown_method(self):
        with self.assertRaises(CoordinateError):
            consensus([])
        with self.assertRaises(CoordinateError):
            consensus([PixelPoint(1, 1)], method="mean")
        with self.assertRaises(CoordinateError):
            within_tolerance(PixelPoint(0, 0), PixelPoint(1, 1), -1.0)


class TestDeterminismAndIdentity(unittest.TestCase):
    def test_canonical_serialization_is_stable(self):
        obj1 = {"b": 1, "a": {"z": [3, 1, 2], "y": "x"}}
        obj2 = {"a": {"y": "x", "z": [3, 1, 2]}, "b": 1}
        self.assertEqual(canonical_json(obj1), canonical_json(obj2))
        self.assertEqual(record_hash(obj1), record_hash(obj2))
        self.assertNotIn(" ", canonical_json(obj1))

    def test_image_identity_content_based(self):
        d1 = b"image-bytes-A"
        d2 = b"image-bytes-B"
        i1a = ImageIdentity.from_bytes(d1, 64, 48)
        i1b = ImageIdentity.from_bytes(d1, 64, 48)
        i2 = ImageIdentity.from_bytes(d2, 64, 48)
        self.assertEqual(i1a.sha256, i1b.sha256)
        self.assertNotEqual(i1a.sha256, i2.sha256)
        self.assertEqual(image_sha256(d1), i1a.sha256)
        with self.assertRaises(CoordinateError):
            i1a.validate_point_inside(64, 48)
        i1a.validate_point_inside(0, 0)
        i1a.validate_point_inside(63, 47)

    def test_engine_version_format(self):
        parts = ENGINE_VERSION.split(".")
        self.assertEqual(len(parts), 3)
        self.assertTrue(all(p.isdigit() for p in parts))


if __name__ == "__main__":
    unittest.main(verbosity=2)
