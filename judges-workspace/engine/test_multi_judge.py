"""Multi-judge assessment tests: schema validation, AI separation, approval gate,
audit chain integrity, competition/image identity consistency."""
import json, os, sys, unittest
ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
from crosshair_records import RecordError
from multi_judge import (Assessment, JudgeSubmission, SchemaViolation,
                         validate_schema, validate_assessment_file)
SCHEMA_PATH = os.path.join(ROOT, "assessment.schema.json")


def sub(judge="J1", x=100, y=100, note=""):
    return JudgeSubmission(judge_id=judge, x_px=x, y_px=y,
                           image_width_px=800, image_height_px=600, note=note)


def make_assessment(judges=(("J1", 100, 100), ("J2", 103, 104), ("J3", 99, 101))):
    a = Assessment(assessment_id="A-001", competition_id="BOTB-2026-R1",
                   image_id="ab" * 32, judges=[],
                   tolerance_px=12.0)
    for jid, x, y in judges:
        a.add_judge_submission(sub(jid, x, y), actor=jid)
    return a


class TestSchemaValidation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(SCHEMA_PATH, encoding="utf-8") as fh:
            cls.schema = json.load(fh)

    def test_valid_document_passes(self):
        a = make_assessment()
        a.approval = {"status": "PENDING", "approver": None, "decided_at": None}
        doc = a.to_json_dict()
        validate_schema(doc, self.schema)

    def test_missing_required_fails(self):
        a = make_assessment()
        doc = a.to_json_dict()
        del doc["competition_id"]
        with self.assertRaises(SchemaViolation):
            validate_schema(doc, self.schema)

    def test_bad_image_id_fails(self):
        a = make_assessment()
        doc = a.to_json_dict()
        doc["image_id"] = "not-a-hash"
        with self.assertRaises(SchemaViolation):
            validate_schema(doc, self.schema)

    def test_bad_enum_fails(self):
        a = make_assessment()
        doc = a.to_json_dict()
        doc["consensus_method"] = "mean"
        with self.assertRaises(SchemaViolation):
            validate_schema(doc, self.schema)

    def test_additional_properties_fails(self):
        a = make_assessment()
        doc = a.to_json_dict()
        doc["extra"] = 1
        with self.assertRaises(SchemaViolation):
            validate_schema(doc, self.schema)

    def test_validate_assessment_file_helper(self):
        import tempfile
        a = make_assessment()
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "a.json")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(a.to_json())
            self.assertEqual(validate_assessment_file(p, SCHEMA_PATH), [])
            with open(p, "r", encoding="utf-8") as fh:
                bad = json.load(fh)
            bad["tolerance_px"] = -1
            with open(p, "w", encoding="utf-8") as fh:
                json.dump(bad, fh)
            self.assertTrue(validate_assessment_file(p, SCHEMA_PATH))


class TestJudgeWorkflow(unittest.TestCase):
    def test_ai_cannot_become_a_judge(self):
        a = Assessment(assessment_id="A-002", competition_id="C",
                       image_id="ab" * 32, judges=[], tolerance_px=10)
        with self.assertRaises(RecordError):
            a.add_judge_submission(sub("AI-1"), actor="AI")
        with self.assertRaises(RecordError):
            a.add_judge_submission(sub("ai_helper"), actor="AI")

    def test_ai_proposals_are_separate(self):
        a = make_assessment()
        n_judges = len(a.judges)
        c_before = dict(a.consensus)
        a.add_ai_proposal({"x_px": 150, "y_px": 130, "model": "reference"}, actor="system")
        self.assertEqual(len(a.judges), n_judges)
        self.assertEqual(len(a.ai_proposals), 1)
        self.assertIn("proposal_id", a.ai_proposals[0])
        self.assertEqual(a.consensus, c_before)  # consensus unaffected by AI

    def test_duplicate_judge_rejected(self):
        a = make_assessment()
        with self.assertRaises(RecordError):
            a.add_judge_submission(sub("J1", 1, 1), actor="J1")

    def test_mixed_image_sizes_rejected(self):
        a = Assessment(assessment_id="A-003", competition_id="C",
                       image_id="ab" * 32, judges=[sub("J1")], tolerance_px=10)
        alien = JudgeSubmission(judge_id="J2", x_px=5, y_px=5,
                                image_width_px=1024, image_height_px=768)
        with self.assertRaises(RecordError):
            a.add_judge_submission(alien, actor="J2")

    def test_consensus_recomputed_on_submission(self):
        a = Assessment(assessment_id="A-004", competition_id="C",
                       image_id="ab" * 32, judges=[sub("J1", 100, 100)],
                       tolerance_px=10)
        c1 = a.consensus
        self.assertEqual((c1["x_px"], c1["y_px"]), (100, 100))
        a.add_judge_submission(sub("J2", 104, 100), actor="J2")
        c2 = a.consensus
        self.assertTrue(100 <= c2["x_px"] <= 102)


class TestApprovalGate(unittest.TestCase):
    def test_approval_requires_full_agreement(self):
        a = make_assessment(judges=(("J1", 100, 100), ("J2", 500, 500)))
        ratio = a.consensus["agreement_ratio"]
        self.assertLess(ratio, 1.0)
        with self.assertRaises(RecordError):
            a.decide("APPROVED", approver="owner")

    def test_approval_passes_when_all_agree(self):
        a = make_assessment(judges=(("J1", 100, 100), ("J2", 103, 104),
                                    ("J3", 99, 101)))
        self.assertEqual(a.consensus["agreement_ratio"], 1.0)
        a.decide("APPROVED", approver="owner")
        self.assertEqual(a.approval["status"], "APPROVED")
        self.assertEqual(a.approval["approver"], "owner")
        a.decide("REJECTED", approver="owner")
        self.assertEqual(a.approval["status"], "REJECTED")

    def test_invalid_status_rejected(self):
        a = make_assessment()
        with self.assertRaises(RecordError):
            a.decide("MAYBE", approver="owner")


class TestAuditChainAndIntegrity(unittest.TestCase):
    def test_chain_valid_and_tamper_detected(self):
        a = make_assessment()
        self.assertTrue(a.audit_chain_valid())
        a.add_judge_submission(sub("J4", 90, 110), actor="J4")
        self.assertTrue(a.audit_chain_valid())
        # tamper with one entry's payload -> chain invalid
        a.audit[0]["actor"] = "attacker"
        self.assertFalse(a.audit_chain_valid())

    def test_chain_links(self):
        a = make_assessment()
        prev = "GENESIS"
        for e in a.audit:
            self.assertEqual(e["prev_entry_hash"], prev)
            prev = e["entry_hash"]

    def test_roundtrip_preserves_content_and_detects_mutation(self):
        a = make_assessment()
        doc = json.loads(a.to_json())
        b = Assessment.from_json_dict(doc)
        self.assertEqual(a.to_json_dict()["assessment_hash"],
                         b.to_json_dict()["assessment_hash"])
        doc["judges"][0]["x_px"] = 999
        with self.assertRaises(RecordError):
            Assessment.from_json_dict(doc)

    def test_first_launch_identity_fields(self):
        a = make_assessment()
        d = a.to_json_dict()
        self.assertEqual(d["competition_id"], "BOTB-2026-R1")
        self.assertEqual(d["image_id"], "ab" * 32)
        for j in d["judges"]:
            self.assertEqual(j["crosshair"]["image_width_px"], 800)
            self.assertEqual(j["crosshair"]["image_height_px"], 600)


if __name__ == "__main__":
    unittest.main(verbosity=2)
