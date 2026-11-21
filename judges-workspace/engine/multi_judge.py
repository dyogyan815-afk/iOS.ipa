"""
BOTB Judges Edition - Multi-judge assessments: schema validation, consensus,
human approval and hash-chained audit history (reference implementation).

Separation rule: AI PROPOSALS ARE NOT JUDGE SUBMISSIONS. This module refuses
any attempt to insert an AI proposal into the judges[] array; proposals live
in their own section (ai_proposals[]) and are excluded from consensus.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

import sys as _sys
_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from coordinate_engine import (ENGINE_VERSION, PixelPoint, canonical_json,
                               evaluate_consensus, record_hash)
from crosshair_records import RecordError, _validate_id, utc_now_iso


# ---------------------------------------------------------------------------
# Minimal self-contained JSON Schema validator (subset)
# ---------------------------------------------------------------------------

class SchemaViolation(ValueError):
    def __init__(self, path: str, message: str):
        super().__init__(f"{path}: {message}")
        self.path = path
        self.message = message


def _type_ok(value, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    raise SchemaViolation("$", f"unsupported type keyword {expected!r}")


def validate_schema(instance, schema: Dict, root_path: str = "$") -> None:
    """Validate `instance` against the JSON Schema (draft-07 subset) used by
    schemas/assessment.schema.json. Raises SchemaViolation on first failure."""
    if "const" in schema:
        if instance != schema["const"]:
            raise SchemaViolation(root_path, f"expected const {schema['const']!r}")
    if "enum" in schema:
        if instance not in schema["enum"]:
            raise SchemaViolation(root_path, f"value not in enum {schema['enum']!r}")
    if "type" in schema:
        expected = schema["type"]
        types = expected if isinstance(expected, list) else [expected]
        if not any(_type_ok(instance, t) for t in types):
            raise SchemaViolation(root_path,
                                  f"expected type {expected!r}, got {type(instance).__name__}")
    if isinstance(instance, dict):
        for req in schema.get("required", []):
            if req not in instance:
                raise SchemaViolation(f"{root_path}.{req}", "required property missing")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            extra = set(instance) - set(props)
            if extra:
                raise SchemaViolation(root_path,
                                      f"additional properties not allowed: {sorted(extra)}")
        for key, sub in props.items():
            if key in instance:
                validate_schema(instance[key], sub, f"{root_path}.{key}")
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            raise SchemaViolation(root_path, f"expected >= {schema['minItems']} items")
        if "items" in schema:
            for i, item in enumerate(instance):
                validate_schema(item, schema["items"], f"{root_path}[{i}]")
    if isinstance(instance, str) and "pattern" in schema:
        import re
        if not re.search(schema["pattern"], instance):
            raise SchemaViolation(root_path,
                                  f"string does not match pattern {schema['pattern']!r}")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise SchemaViolation(root_path, f"expected >= {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            raise SchemaViolation(root_path, f"expected <= {schema['maximum']}")


# ---------------------------------------------------------------------------
# Assessment model
# ---------------------------------------------------------------------------

AI_JUDGE_ID_FORBIDDEN = True


@dataclass
class JudgeSubmission:
    judge_id: str
    x_px: int
    y_px: int
    image_width_px: int
    image_height_px: int
    submitted_at: str = field(default_factory=utc_now_iso)
    note: str = ""

    def to_json_dict(self) -> Dict:
        return {
            "judge_id": self.judge_id,
            "crosshair": {
                "x_px": self.x_px,
                "y_px": self.y_px,
                "image_width_px": self.image_width_px,
                "image_height_px": self.image_height_px,
            },
            "submitted_at": self.submitted_at,
            "note": self.note,
        }


@dataclass
class Assessment:
    assessment_id: str
    competition_id: str
    image_id: str
    judges: List[JudgeSubmission]
    tolerance_px: float
    consensus_method: str = "geometric_median"
    consensus: Optional[Dict] = None
    approval: Dict = field(default_factory=lambda: {
        "status": "PENDING", "approver": None, "decided_at": None})
    ai_proposals: List[Dict] = field(default_factory=list)
    audit: List[Dict] = field(default_factory=list)

    # -- lifecycle ---------------------------------------------------------

    def _audit_entry(self, actor: str, action: str, details: Dict) -> Dict:
        prev = self.audit[-1]["entry_hash"] if self.audit else "GENESIS"
        payload = {
            "timestamp": utc_now_iso(),
            "actor": actor,
            "action": action,
            "details": details,
            "prev_entry_hash": prev,
        }
        entry = {**payload, "entry_hash": record_hash(payload)}
        self.audit.append(entry)
        return entry

    def __post_init__(self) -> None:
        _validate_id(self.competition_id, "competition_id")
        if self.consensus is None and self.judges:
            self.recompute_consensus(actor="system", silent=True)
        if not self.audit:
            self._audit_entry("system", "assessment_created", {
                "assessment_id": self.assessment_id,
                "competition_id": self.competition_id,
                "image_id": self.image_id,
            })

    def add_judge_submission(self, sub: JudgeSubmission, actor: str) -> Dict:
        """Append an individual judge submission. AI proposals are rejected."""
        if sub.judge_id.lower().startswith("ai"):
            raise RecordError(
                "AI proposals must not be submitted as judge submissions; "
                "use add_ai_proposal()")
        existing = {j.judge_id for j in self.judges}
        if sub.judge_id in existing:
            raise RecordError(f"duplicate judge submission: {sub.judge_id}")
        if (sub.image_width_px, sub.image_height_px) and self.judges:
            ref = self.judges[0]
            if (sub.image_width_px, sub.image_height_px) != (
                    ref.image_width_px, ref.image_height_px):
                raise RecordError("submission image size differs from assessment")
        self.judges.append(sub)
        entry = self._audit_entry(actor, "judge_submission_added",
                                  {"judge_id": sub.judge_id})
        self.recompute_consensus(actor="system", silent=True)
        return entry

    def add_ai_proposal(self, proposal: Dict, actor: str) -> Dict:
        """Register an AI proposal SEPARATELY from judge submissions."""
        proposal = {**proposal, "proposal_id": record_hash(proposal)}
        self.ai_proposals.append(proposal)
        return self._audit_entry(actor, "ai_proposal_registered", {
            "proposal_id": proposal["proposal_id"]})

    def recompute_consensus(self, actor: str = "system", silent: bool = False) -> Optional[Dict]:
        if not self.judges:
            self.consensus = None
            return None
        pts = [PixelPoint(j.x_px, j.y_px) for j in self.judges]
        ref_w, ref_h = self.judges[0].image_width_px, self.judges[0].image_height_px
        if any((j.image_width_px, j.image_height_px) != (ref_w, ref_h) for j in self.judges):
            raise RecordError("mixed image sizes in assessment")
        self.consensus = evaluate_consensus(pts, self.tolerance_px,
                                            method=self.consensus_method)
        if not silent:
            self._audit_entry(actor, "consensus_recomputed",
                              {"x_px": self.consensus["x_px"],
                               "y_px": self.consensus["y_px"]})
        return self.consensus

    def decide(self, status: str, approver: str) -> Dict:
        if status not in ("APPROVED", "REJECTED"):
            raise RecordError("approval status must be APPROVED or REJECTED")
        c = self.consensus or {}
        if status == "APPROVED" and (c.get("agreement_ratio", 0) < 1.0):
            raise RecordError(
                "human approval requires agreement_ratio == 1.0; "
                f"current={c.get('agreement_ratio')}")
        self.approval = {"status": status, "approver": approver,
                         "decided_at": utc_now_iso()}
        return self._audit_entry(approver, f"approval_{status.lower()}",
                                 {"approver": approver})

    # -- integrity ---------------------------------------------------------

    def audit_chain_valid(self) -> bool:
        prev = "GENESIS"
        for entry in self.audit:
            payload = {k: v for k, v in entry.items() if k != "entry_hash"}
            if entry.get("prev_entry_hash") != prev:
                return False
            if record_hash(payload) != entry.get("entry_hash"):
                return False
            prev = entry["entry_hash"]
        return True

    # -- serialization -----------------------------------------------------

    def to_json_dict(self) -> Dict:
        d = {
            "assessment_id": self.assessment_id,
            "competition_id": self.competition_id,
            "image_id": self.image_id,
            "consensus_method": self.consensus_method,
            "tolerance_px": self.tolerance_px,
            "judges": [j.to_json_dict() for j in self.judges],
            "consensus": self.consensus,
            "approval": self.approval,
            "ai_proposals": self.ai_proposals,
            "audit": self.audit,
            "engine_version": ENGINE_VERSION,
        }
        d["assessment_hash"] = record_hash(
            {k: v for k, v in d.items() if k != "assessment_hash"})
        return d

    def to_json(self, indent: int = 1) -> str:
        return json.dumps(self.to_json_dict(), ensure_ascii=False, indent=indent)

    @staticmethod
    def from_json_dict(d: Dict) -> "Assessment":
        stored = d.get("assessment_hash")
        recomputed = record_hash(
            {k: v for k, v in d.items() if k != "assessment_hash"})
        if stored is not None and stored != recomputed:
            raise RecordError("assessment integrity failure (hash mismatch)")
        judges = []
        for j in d["judges"]:
            ch = j["crosshair"]
            judges.append(JudgeSubmission(
                judge_id=j["judge_id"], x_px=int(ch["x_px"]), y_px=int(ch["y_px"]),
                image_width_px=int(ch["image_width_px"]),
                image_height_px=int(ch["image_height_px"]),
                submitted_at=j.get("submitted_at", utc_now_iso()),
                note=j.get("note", "")))
        a = Assessment(
            assessment_id=d["assessment_id"],
            competition_id=d["competition_id"],
            image_id=d["image_id"],
            judges=judges,
            tolerance_px=float(d["tolerance_px"]),
            consensus_method=d.get("consensus_method", "geometric_median"),
            consensus=d.get("consensus"),
            approval=d.get("approval", {"status": "PENDING", "approver": None,
                                        "decided_at": None}),
            ai_proposals=d.get("ai_proposals", []),
            audit=d.get("audit", []),
        )
        a.audit = d.get("audit", [])
        if not a.audit:
            a._audit_entry("system", "assessment_created",
                           {"assessment_id": a.assessment_id})
        return a


def validate_assessment_file(path: str, schema_path: str) -> List[str]:
    """Validate an assessment JSON file against the schema.
    Returns a list of violation descriptions; empty list == valid."""
    with open(path, "r", encoding="utf-8") as fh:
        instance = json.load(fh)
    with open(schema_path, "r", encoding="utf-8") as fh:
        schema = json.load(fh)
    try:
        validate_schema(instance, schema)
        return []
    except SchemaViolation as exc:
        return [f"{exc.path}: {exc.message}"]
