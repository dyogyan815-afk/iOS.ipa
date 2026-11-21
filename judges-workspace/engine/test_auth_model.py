"""First-launch authentication model tests (PIN setup, verify, lockout)."""
import os, sys, time, unittest
ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
from auth_model import (AuthError, FAILURES_BEFORE_LOCK, RateLimiter,
                        create_credential, verify_credential)


class TestCredentialLifecycle(unittest.TestCase):
    def test_setup_then_unlock(self):
        cred = create_credential("135790")
        self.assertEqual(cred["algo"], "PBKDF2-HMAC-SHA256")
        self.assertTrue(verify_credential(cred, "135790"))

    def test_wrong_pin_rejected(self):
        cred = create_credential("135790")
        self.assertFalse(verify_credential(cred, "135791"))
        self.assertFalse(verify_credential(cred, ""))

    def test_verifier_never_stores_pin(self):
        cred = create_credential("135790")
        blob = str(cred).encode("utf-8")
        self.assertNotIn(b"135790", blob)

    def test_salts_unique_per_setup(self):
        a = create_credential("135790")
        b = create_credential("135790")
        self.assertNotEqual(a["salt_hex"], b["salt_hex"])
        self.assertNotEqual(a["verifier_hex"], b["verifier_hex"])

    def test_pin_policy(self):
        with self.assertRaises(AuthError):
            create_credential("123")          # too short
        with self.assertRaises(AuthError):
            create_credential("1" * 13)       # too long
        with self.assertRaises(AuthError):
            create_credential("12ab90")       # non-digits


class TestRateLimiter(unittest.TestCase):
    def test_lockout_after_consecutive_failures(self):
        t = [1000.0]
        clock = lambda: t[0]
        rl = RateLimiter(clock=clock)
        for _ in range(FAILURES_BEFORE_LOCK - 1):
            rl.register_failure()
            self.assertFalse(rl.is_locked())
        rl.register_failure()
        self.assertTrue(rl.is_locked())
        self.assertGreater(rl.remaining_seconds(), 0.0)
        t[0] += 31.0
        self.assertFalse(rl.is_locked())

    def test_success_resets(self):
        rl = RateLimiter()
        for _ in range(FAILURES_BEFORE_LOCK + 1):
            rl.register_failure()
        rl.register_success()
        self.assertFalse(rl.is_locked())
        self.assertEqual(rl.consecutive_failures, 0)

    def test_backoff_grows(self):
        t = [0.0]
        clock = lambda: t[0]
        rl = RateLimiter(clock=clock)
        for _ in range(FAILURES_BEFORE_LOCK):       # 1st lock: 30s
            rl.register_failure()
        self.assertTrue(rl.is_locked())
        self.assertAlmostEqual(rl.remaining_seconds(), 30.0, delta=1.0)
        t[0] += 31.0                                # lock expires
        rl.register_failure()                       # 6th consecutive failure: 60s
        self.assertTrue(rl.is_locked())
        self.assertAlmostEqual(rl.remaining_seconds(), 60.0, delta=1.0)

    def test_two_rate_limiters_independent(self):
        a, b = RateLimiter(), RateLimiter()
        for _ in range(FAILURES_BEFORE_LOCK):
            a.register_failure()
        self.assertTrue(a.is_locked())
        self.assertFalse(b.is_locked())


if __name__ == "__main__":
    unittest.main(verbosity=2)
