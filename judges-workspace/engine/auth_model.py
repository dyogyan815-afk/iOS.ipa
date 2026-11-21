"""
BOTB Judges Edition - First-launch private access model (reference implementation).

Rules implemented (mirrored by AuthGate.swift in the app scaffold):
- First launch: the owner sets a PIN; the app stores salt + verifier only
  (PBKDF2-HMAC-SHA256), never the PIN itself.
- Unlock: constant-time verifier comparison.
- Rate limiting: consecutive failures trigger exponential lockout.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from typing import Dict, Optional

ALGO = "PBKDF2-HMAC-SHA256"
ITERATIONS = 100_000
SALT_BYTES = 16
PIN_MIN_LEN = 4
PIN_MAX_LEN = 12
BASE_LOCK_SECONDS = 30.0
FAILURES_BEFORE_LOCK = 5
MAX_LOCK_SECONDS = 3600.0


class AuthError(ValueError):
    """Raised for invalid credential or PIN input."""


def create_credential(pin: str) -> Dict:
    if not (PIN_MIN_LEN <= len(pin) <= PIN_MAX_LEN) or not pin.isdigit():
        raise AuthError(f"PIN must be {PIN_MIN_LEN}-{PIN_MAX_LEN} digits")
    salt = secrets.token_bytes(SALT_BYTES)
    verifier = hashlib.pbkdf2_hmac("sha256", pin.encode("utf-8"),
                                   salt, ITERATIONS)
    return {
        "algo": ALGO,
        "iterations": ITERATIONS,
        "salt_hex": salt.hex(),
        "verifier_hex": verifier.hex(),
    }


def verify_credential(cred: Dict, pin: str) -> bool:
    if cred.get("algo") != ALGO:
        raise AuthError("unknown credential algorithm")
    salt = bytes.fromhex(cred["salt_hex"])
    expected = bytes.fromhex(cred["verifier_hex"])
    candidate = hashlib.pbkdf2_hmac("sha256", pin.encode("utf-8"),
                                    salt, int(cred["iterations"]))
    return hmac.compare_digest(candidate, expected)


class RateLimiter:
    """Exponential lockout after consecutive failures (injectable clock)."""

    def __init__(self, clock=time.time):
        self._clock = clock
        self.consecutive_failures = 0
        self.locked_until: Optional[float] = None

    def register_failure(self) -> None:
        self.consecutive_failures += 1
        if self.consecutive_failures >= FAILURES_BEFORE_LOCK:
            exponent = self.consecutive_failures - FAILURES_BEFORE_LOCK
            seconds = min(BASE_LOCK_SECONDS * (2 ** exponent), MAX_LOCK_SECONDS)
            self.locked_until = self._clock() + seconds

    def register_success(self) -> None:
        self.consecutive_failures = 0
        self.locked_until = None

    def is_locked(self) -> bool:
        return self.locked_until is not None and self._clock() < self.locked_until

    def remaining_seconds(self) -> float:
        if self.locked_until is None:
            return 0.0
        return max(0.0, self.locked_until - self._clock())
