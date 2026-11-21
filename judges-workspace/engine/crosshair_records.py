"""
BOTB Judges Edition - Crosshair record persistence layer (reference implementation).

Implements crosshair placement records with:
- save / reopen / verify semantics
- competition + image identity consistency checks
- SHA-256 canonical-JSON record integrity

The Swift `RecordsStore.swift` in the app scaffold mirrors this format so
records are interchangeable between the reference tools and the app.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

from coordinate_engine import (ENGINE_VERSION, CoordinateError, ImageIdentity,
                               PixelPoint, canonical_json, record_hash)

_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


class RecordError(ValueError):
    """Raised for invalid or inconsistent record data."""


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _validate_id(value: str, name: str) -> str:
    if not isinstance(value, str) or not _ID_RE.match(value):
        raise RecordError(f"{name} must match ^[A-Za-z0-9._-]{{1,128}}$")
    return value


@dataclass
class CrosshairRecord:
    competition_id: str
    judge_id: str
    image_id: str
    image_width_px: int
    image_height_px: int
    x_px: int
    y_px: int
    note: str = ""
    created_at: str = field(default_factory=utc_now_iso)
    engine_version: str = ENGINE_VERSION

    def __post_init__(self) -> None:
        _validate_id(self.competition_id, "competition_id")
        _validate_id(self.judge_id, "judge_id")
        try:
            ImageIdentity(self.image_id, self.image_width_px,
                          self.image_height_px).validate_point_inside(
                              self.x_px, self.y_px)
        except CoordinateError as exc:
            raise RecordError(str(exc)) from exc

    def to_json_dict(self) -> Dict:
        d = {
            "competition_id": self.competition_id,
            "judge_id": self.judge_id,
            "image_id": self.image_id,
            "image_width_px": self.image_width_px,
            "image_height_px": self.image_height_px,
            "x_px": self.x_px,
            "y_px": self.y_px,
            "note": self.note,
            "created_at": self.created_at,
            "engine_version": self.engine_version,
        }
        d["record_id"] = record_hash(
            {k: v for k, v in d.items() if k != "record_id"})
        return d

    @staticmethod
    def from_json_dict(d: Dict) -> "CrosshairRecord":
        stored_id = d.get("record_id")
        recomputed = record_hash({k: v for k, v in d.items()
                                  if k != "record_id" and k != "hash"})
        if stored_id is not None and stored_id != recomputed:
            raise RecordError(
                f"record integrity failure: stored record_id {stored_id!r} "
                f"!= recomputed {recomputed!r}")
        rec = CrosshairRecord(
            competition_id=d["competition_id"],
            judge_id=d["judge_id"],
            image_id=d["image_id"],
            image_width_px=int(d["image_width_px"]),
            image_height_px=int(d["image_height_px"]),
            x_px=int(d["x_px"]),
            y_px=int(d["y_px"]),
            note=str(d.get("note", "")),
            created_at=str(d.get("created_at", utc_now_iso())),
            engine_version=str(d.get("engine_version", ENGINE_VERSION)),
        )
        if stored_id is None:
            raise RecordError("record_id missing; refusing to accept unhashed record")
        return rec

    def matches_image(self, identity: ImageIdentity) -> bool:
        return (self.image_id == identity.sha256
                and self.image_width_px == identity.width_px
                and self.image_height_px == identity.height_px)


class CrosshairStore:
    """Filesystem-backed store. One JSON file per record, filename = record_id.

    In the iOS app the equivalent directory is
    Application Support/JudgesEdition/Records/ ; format identical.
    """

    def __init__(self, root: str):
        self.root = root
        os.makedirs(root, exist_ok=True)

    def _path(self, record_id: str) -> str:
        if not _ID_RE.match(record_id):
            raise RecordError("record_id contains path-unsafe characters")
        return os.path.join(self.root, record_id + ".json")

    def save(self, rec: CrosshairRecord) -> str:
        d = rec.to_json_dict()
        path = self._path(d["record_id"])
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(d, fh, ensure_ascii=False, indent=1)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)  # atomic
        return d["record_id"]

    def load(self, record_id: str) -> Tuple[CrosshairRecord, str]:
        """Returns (record, verification_status). status is PASS or FAIL."""
        path = self._path(record_id)
        with open(path, "r", encoding="utf-8") as fh:
            d = json.load(fh)
        try:
            rec = CrosshairRecord.from_json_dict(d)
            return rec, "PASS"
        except RecordError:
            return CrosshairRecord.__new__(CrosshairRecord), "FAIL"

    def verify(self, record_id: str, identity: Optional[ImageIdentity] = None) -> Dict:
        """Full verification: digest integrity + identity consistency."""
        path = self._path(record_id)
        with open(path, "r", encoding="utf-8") as fh:
            d = json.load(fh)
        checks: Dict[str, str] = {}
        checks["digest"] = "PASS" if d.get("record_id") == record_hash(
            {k: v for k, v in d.items() if k != "record_id"}) else "FAIL"
        if identity is not None:
            checks["image_identity"] = "PASS" if (
                d["image_id"] == identity.sha256
                and int(d["image_width_px"]) == identity.width_px
                and int(d["image_height_px"]) == identity.height_px) else "FAIL"
        checks["bounds"] = "PASS" if (
            0 <= int(d["x_px"]) < int(d["image_width_px"])
            and 0 <= int(d["y_px"]) < int(d["image_height_px"])) else "FAIL"
        return {
            "record_id": record_id,
            "status": "PASS" if all(v == "PASS" for v in checks.values()) else "FAIL",
            "checks": checks,
        }

    def list_records(self) -> List[str]:
        return sorted(f[:-5] for f in os.listdir(self.root) if f.endswith(".json"))

    def records_for(self, competition_id: str, image_id: str) -> List[CrosshairRecord]:
        out = []
        for rid in self.list_records():
            path = self._path(rid)
            with open(path, "r", encoding="utf-8") as fh:
                d = json.load(fh)
            if d["competition_id"] == competition_id and d["image_id"] == image_id:
                out.append(CrosshairRecord.from_json_dict(d))
        return out
