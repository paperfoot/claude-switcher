import math
import unittest

from bridge import deadlines


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def wall(self):
        return 5_000.0 + self.now


class DeadlineTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()

    def deadline(self, seconds):
        return deadlines.Deadline(seconds, clock=self.clock.monotonic, wall=self.clock.wall)

    def test_timeout_is_capped_by_the_call_and_by_the_reserved_time_left(self):
        deadline = self.deadline(100)
        self.assertEqual(deadline.timeout(60), 60)
        self.assertEqual(deadline.timeout(60, reserve=45), 55)
        self.clock.now = 90
        self.assertEqual(deadline.timeout(60), 10)
        with self.assertRaises(deadlines.DeadlineExceeded):
            deadline.timeout(60, reserve=10)

    def test_unix_ms_is_the_same_instant_for_other_processes(self):
        deadline = self.deadline(100)
        self.clock.now = 30
        self.assertEqual(deadline.unix_ms(), (5_000 + 100) * 1000)
        self.assertEqual(deadline.unix_ms(reserve=70), (5_000 + 30) * 1000)

    def test_deadline_from_another_process_is_capped_and_validated(self):
        def received(value):
            return deadlines.Deadline.from_unix_ms(
                value, 150, clock=self.clock.monotonic, wall=self.clock.wall)

        self.assertEqual(received((5_000 + 90) * 1000).remaining(), 90)
        self.assertEqual(received((5_000 + 900) * 1000).remaining(), 150)
        self.assertEqual(received((5_000 - 10) * 1000).remaining(), 0)
        for invalid in (None, True, "90", math.nan, math.inf, [90]):
            with self.subTest(value=invalid):
                self.assertIsNone(received(invalid))

    def test_the_ladder_nests(self):
        swift_kill = 350
        self.assertLess(deadlines.MENU_BUDGET, swift_kill)
        self.assertLess(deadlines.STATUS_BUDGET, swift_kill)
        # The popup waits 180 s for select (background.js SELECT_REPLY_MS); older
        # popups wait 120 s and send no deadline.
        self.assertLess(deadlines.POPUP_BUDGET, 180)
        self.assertLess(deadlines.LEGACY_POPUP_BUDGET, 120)
        self.assertGreater(deadlines.PROFILE_SWITCH_MINIMUM,
                           deadlines.native_transport.BROWSER_ROLLBACK_GRACE)
        self.assertGreaterEqual(deadlines.CODE_RESTORE_RESERVE, deadlines.IDENTITY_TIMEOUT)


if __name__ == "__main__":
    unittest.main()
