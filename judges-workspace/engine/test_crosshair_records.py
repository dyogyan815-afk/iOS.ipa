"""Crosshair record save / reopen / verify tests."""
import json, os, shutil, sys, tempfile, unittest
ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
from coordinate_engine import ImageIdentity, PixelPoint, record_hash
from crosshair_records import CrosshairRecord, CrosshairStore, RecordError


IMG = ImageIdentity("ab" * 32, 800, 600)


def make_rec(judge="J1", x=321, y=123, note="ok"):
    return CrosshairRecord(
        competition_id="BOTB-2026-R1", judge_id=judge, image_id=IMG.sha256,
        image_width_px=IMG.width_px, image_height_px=IMG.height_px,
        x_px=x, y_px=y, note=note)


class TestSaveReopenVerify(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="botb_xhair_")
        self.store = CrosshairStore(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_save_then_reopen_roundtrip(self):
        rec = make_rec()
        rid = self.store.save(rec)
        self.assertEqual(rid, rec.to_json_dict()["record_id"])
        loaded, status = self.store.load(rid)
        self.assertEqual(status, "PASS")
        self.assertEqual(loaded.competition_id, rec.competition_id)
        self.assertEqual(loaded.judge_id, rec.judge_id)
        self.assertEqual((loaded.x_px, loaded.y_px), (rec.x_px, rec.y_px))
        self.assertEqual(loaded.note, rec.note)

    def test_verify_passes_on_untouched_record(self):
        rid = self.store.save(make_rec())
        report = self.store.verify(rid, identity=IMG)
        self.assertEqual(report["status"], "PASS")
        self.assertEqual(set(report["checks"].values()), {"PASS"})

    def test_tamper_detection(self):
        rid = self.store.save(make_rec())
        path = os.path.join(self.tmp, rid + ".json")
        with open(path, "r", encoding="utf-8") as fh:
            d = json.load(fh)
        d["x_px"] = 799  # tamper
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(d, fh)
        rec, status = self.store.load(rid)
        self.assertEqual(status, "FAIL")
        report = self.store.verify(rid)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["checks"]["digest"], "FAIL")

    def test_identity_consistency(self):
        rec = make_rec()
        rid = self.store.save(rec)
        self.assertTrue(rec.matches_image(IMG))
        other = ImageIdentity("cd" * 32, 800, 600)
        self.assertFalse(rec.matches_image(other))
        report = self.store.verify(rid, identity=other)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["checks"]["image_identity"], "FAIL")

    def test_bounds_and_validation(self):
        with self.assertRaises(RecordError):
            make_rec(x=800, y=599)   # x out of range
        with self.assertRaises(RecordError):
            make_rec(y=600)          # y out of range
        with self.assertRaises(RecordError):
            make_rec(x=-1)
        with self.assertRaises(RecordError):
            CrosshairRecord(
                competition_id="bad id!", judge_id="J1", image_id=IMG.sha256,
                image_width_px=800, image_height_px=600, x_px=1, y_px=1)

    def test_listing_and_filtering(self):
        r1 = make_rec(judge="J1", x=10, y=20)
        r2 = make_rec(judge="J2", x=30, y=40)
        self.store.save(r1)
        self.store.save(r2)
        self.assertEqual(len(self.store.list_records()), 2)
        found = self.store.records_for("BOTB-2026-R1", IMG.sha256)
        self.assertEqual(len(found), 2)
        self.assertEqual(
            {f.judge_id for f in found}, {"J1", "J2"})

    def test_record_id_is_content_hash(self):
        a = make_rec()
        b = make_rec()
        self.assertEqual(a.to_json_dict()["record_id"], b.to_json_dict()["record_id"])
        c = make_rec(x=322)
        self.assertNotEqual(a.to_json_dict()["record_id"], c.to_json_dict()["record_id"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
