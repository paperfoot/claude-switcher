import threading
import unittest
from pathlib import Path
from unittest import mock

from bridge import browser_profiles, deadlines


OLD_ONE = "one@example.com"
OLD_TWO = "two@example.com"
TARGET = "target@example.com"
WALL = 1_000_000.0


class FakeClock:
    """Monotonic and wall clocks that move only when a test says so."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def wall(self):
        return WALL + self.now

    def deadline(self, seconds):
        return deadlines.Deadline(seconds, clock=self.monotonic, wall=self.wall)


class StatefulSender:
    def __init__(self, states, switch_results=None, clock=None, switch_seconds=0.0):
        self.states = {Path(path): dict(state) for path, state in states.items()}
        self.switch_results = {
            (Path(path), email): [dict(result) for result in results]
            for (path, email), results in (switch_results or {}).items()
        }
        self.calls = []
        self.options = []
        self.clock = clock
        self.switch_seconds = switch_seconds
        self.lock = threading.Lock()

    def __call__(self, path, command, email, timeout=None, deadline=None, selected_at=None):
        path = Path(path)
        with self.lock:
            self.calls.append((path, command, email))
            self.options.append((path, command, email, timeout, deadline, selected_at))
        if command == "status":
            return dict(self.states[path])

        assert timeout is None and deadline is not None, "switches carry a reply deadline"
        if self.clock is not None:
            self.clock.now += self.switch_seconds
        scripted = self.switch_results.get((path, email), [])
        result = scripted.pop(0) if scripted else {"ok": True, "email": email}
        if result.get("ok") and result.get("email"):
            self.states[path] = {**self.states[path], **result}
        return dict(result)

    def switch_calls(self):
        return [call for call in self.calls if call[1] == "switch"]

    def switch_deadlines(self):
        return [option[4] for option in self.options if option[1] == "switch"]

    def switch_stamps(self):
        return [(option[0], option[2], option[5]) for option in self.options if option[1] == "switch"]

    def status_timeouts(self):
        return [option[3] for option in self.options if option[1] == "status"]


class BrowserProfilesTests(unittest.TestCase):
    def setUp(self):
        self.base = Path("/unused/bridge")
        self.one = self.base / "browsers" / "1.sock"
        self.two = self.base / "browsers" / "2.sock"

    def run_switch(self, paths, sender, **kwargs):
        with mock.patch.object(
            browser_profiles.profile_transport,
            "connection_paths",
            return_value=paths,
        ):
            return browser_profiles.switch(self.base, TARGET, sender=sender, **kwargs)

    def test_two_different_profiles_converge_on_target(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE, "accounts": [OLD_ONE, TARGET]},
                self.two: {"ok": True, "email": OLD_TWO, "accounts": [OLD_TWO, TARGET]},
            }
        )

        result = self.run_switch([self.one, self.two], sender, expected_profiles=2)

        self.assertTrue(result["ok"])
        self.assertEqual(result["email"], TARGET)
        self.assertEqual(result["profileCount"], 2)
        self.assertEqual(sender.states[self.one]["email"], TARGET)
        self.assertEqual(sender.states[self.two]["email"], TARGET)
        self.assertEqual(
            sender.switch_calls(),
            [
                (self.one, "switch", TARGET),
                (self.two, "switch", TARGET),
            ],
        )

    def test_profile_already_on_target_is_not_switched(self):
        sender = StatefulSender({self.one: {"ok": True, "email": TARGET}})

        result = self.run_switch([self.one], sender)

        self.assertTrue(result["ok"])
        self.assertEqual(result["email"], TARGET)
        self.assertEqual(sender.switch_calls(), [])

    def test_missing_expected_profile_causes_no_mutations(self):
        sender = StatefulSender({self.one: {"ok": True, "email": OLD_ONE}})

        result = self.run_switch([self.one], sender, expected_profiles=2)

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "browser_profiles_missing")
        self.assertEqual(result["expectedProfiles"], 2)
        self.assertEqual(result["profileCount"], 1)
        self.assertEqual(sender.switch_calls(), [])
        self.assertEqual(sender.states[self.one]["email"], OLD_ONE)

    def test_stale_unavailable_socket_is_omitted(self):
        sender = StatefulSender(
            {
                self.one: {"ok": False, "error": "host_unavailable"},
                self.two: {"ok": True, "email": TARGET},
            }
        )
        with mock.patch.object(
            browser_profiles.profile_transport,
            "connection_paths",
            return_value=[self.one, self.two],
        ):
            result = browser_profiles.status(self.base, sender=sender)

        self.assertTrue(result["ok"])
        self.assertEqual(result["profileCount"], 1)
        self.assertEqual(result["profiles"], [{"connection": "2.sock", "ok": True, "email": TARGET}])

    def test_rejection_restores_an_already_changed_profile(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": True, "email": OLD_TWO},
            },
            {(self.two, TARGET): [{"ok": False, "error": "selection_rejected"}]},
        )

        result = self.run_switch([self.one, self.two], sender, expected_profiles=2)

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "selection_rejected")
        self.assertTrue(result["rolledBack"])
        self.assertEqual(sender.states[self.one]["email"], OLD_ONE)
        self.assertEqual(sender.states[self.two]["email"], OLD_TWO)
        self.assertIn((self.one, "switch", OLD_ONE), sender.switch_calls())

    def test_forward_switches_carry_the_selection_stamp_and_rollbacks_do_not(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": True, "email": OLD_TWO},
            },
            {(self.two, TARGET): [{"ok": False, "error": "web_login_needed"}]},
        )

        result = self.run_switch([self.one, self.two], sender, expected_profiles=2, selected_at=7.5)

        self.assertTrue(result["rolledBack"])
        self.assertEqual(
            sender.switch_stamps(),
            [(self.one, TARGET, 7.5), (self.two, TARGET, 7.5), (self.one, OLD_ONE, None)],
        )

    def test_identity_mismatch_fails_and_rolls_back(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": True, "email": OLD_TWO},
            },
            {(self.two, TARGET): [{"ok": True, "email": "unexpected@example.com"}]},
        )

        result = self.run_switch([self.one, self.two], sender, expected_profiles=2)

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "web_identity_mismatch")
        self.assertTrue(result["rolledBack"])
        self.assertEqual(sender.states[self.one]["email"], OLD_ONE)
        self.assertEqual(sender.states[self.two]["email"], OLD_TWO)

    def test_failed_rollback_reports_web_restore_failed(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": True, "email": OLD_TWO},
            },
            {
                (self.two, TARGET): [{"ok": False, "error": "selection_rejected"}],
                (self.one, OLD_ONE): [{"ok": False, "error": "restore_rejected"}],
            },
        )

        result = self.run_switch([self.one, self.two], sender, expected_profiles=2)

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "web_restore_failed")
        self.assertFalse(result["rolledBack"])
        self.assertEqual(sender.states[self.one]["email"], TARGET)
        self.assertEqual(sender.states[self.two]["email"], OLD_TWO)

    def test_unreadable_status_prevents_changes(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": False, "error": "invalid_browser_result"},
            }
        )

        result = self.run_switch([self.one, self.two], sender, expected_profiles=2)

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "web_unavailable")
        self.assertEqual(sender.switch_calls(), [])
        self.assertEqual(sender.states[self.one]["email"], OLD_ONE)

    def test_exclude_skips_initiating_host(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": True, "email": OLD_TWO},
            }
        )

        result = self.run_switch(
            [self.one, self.two], sender, expected_profiles=1, exclude=self.one
        )

        self.assertTrue(result["ok"])
        self.assertEqual(result["profileCount"], 1)
        self.assertEqual(sender.states[self.one]["email"], OLD_ONE)
        self.assertEqual(sender.states[self.two]["email"], TARGET)
        self.assertNotIn(self.one, [call[0] for call in sender.calls])

    def test_status_merges_saved_login_expiries_across_profiles(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE,
                           "expiries": {OLD_ONE: 100.0, OLD_TWO: 200.0}},
                self.two: {"ok": True, "email": OLD_ONE,
                           "expiries": {OLD_ONE: 150.0, TARGET: "soon", 7: 9.0}},
            }
        )
        with mock.patch.object(
            browser_profiles.profile_transport, "connection_paths",
            return_value=[self.one, self.two],
        ):
            result = browser_profiles.status(self.base, sender=sender)

        # The later value is the fresher read of the shared vault.
        self.assertEqual(result["expiries"], {OLD_ONE: 150.0, OLD_TWO: 200.0})

    def test_busy_profile_counts_as_connected_in_status(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "busy": True, "email": OLD_ONE},
                self.two: {"ok": True, "email": OLD_ONE},
            }
        )
        with mock.patch.object(
            browser_profiles.profile_transport,
            "connection_paths",
            return_value=[self.one, self.two],
        ):
            result = browser_profiles.status(self.base, sender=sender)

        self.assertTrue(result["ok"])
        self.assertEqual(result["email"], OLD_ONE)
        self.assertEqual(result["profiles"][0]["busy"], True)
        self.assertNotIn("busy", result["profiles"][1])

    def test_busy_profile_prevents_a_concurrent_fan_out(self):
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": True, "busy": True, "email": OLD_TWO},
            }
        )

        result = self.run_switch([self.one, self.two], sender, expected_profiles=2)

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "switch_in_progress")
        self.assertEqual(sender.switch_calls(), [])
        self.assertEqual(sender.states[self.one]["email"], OLD_ONE)

    def test_each_reply_is_due_while_changed_profiles_can_still_be_restored(self):
        clock = FakeClock()
        three = self.base / "browsers" / "3.sock"
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": True, "email": OLD_TWO},
                three: {"ok": True, "email": OLD_TWO},
            }
        )

        result = self.run_switch([self.one, self.two, three], sender,
                                 expected_profiles=3, deadline=clock.deadline(300))

        self.assertTrue(result["ok"])
        reserve = deadlines.PROFILE_RESTORE_RESERVE
        # The first switch keeps one restore slot, the next two keep two; the
        # last profile needs no slot of its own because nothing follows it.
        self.assertEqual(
            sender.switch_deadlines(),
            [(WALL + 300 - reserve) * 1000, (WALL + 300 - 2 * reserve) * 1000,
             (WALL + 300 - 2 * reserve) * 1000],
        )
        self.assertEqual(set(sender.status_timeouts()), {deadlines.STATUS_TIMEOUT})

    def test_fan_out_stops_before_the_deadline_and_restores_changed_profiles(self):
        clock = FakeClock()
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": True, "email": OLD_TWO},
            },
            clock=clock,
            switch_seconds=80,
        )

        result = self.run_switch([self.one, self.two], sender,
                                 expected_profiles=2, deadline=clock.deadline(200))

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "browser_timeout")
        self.assertTrue(result["rolledBack"])
        self.assertEqual(result["failedConnection"], "2.sock")
        self.assertEqual(
            sender.switch_calls(),
            [(self.one, "switch", TARGET), (self.one, "switch", OLD_ONE)],
        )
        self.assertEqual(sender.states[self.one]["email"], OLD_ONE)
        self.assertEqual(sender.states[self.two]["email"], OLD_TWO)
        self.assertLessEqual(clock.now, 200)

    def test_status_checks_are_capped_by_the_deadline(self):
        clock = FakeClock()
        sender = StatefulSender({self.one: {"ok": True, "email": OLD_ONE}})
        with mock.patch.object(
            browser_profiles.profile_transport, "connection_paths", return_value=[self.one]
        ):
            browser_profiles.status(self.base, sender=sender, deadline=clock.deadline(4))
            spent = clock.deadline(0)
            result = browser_profiles.switch(self.base, TARGET, sender=sender, deadline=spent)

        self.assertEqual(sender.status_timeouts(), [4])
        self.assertFalse(result["ok"])
        self.assertEqual(result["profiles"][0]["error"], "browser_timeout")
        self.assertEqual(sender.switch_calls(), [])

    def test_status_checks_run_concurrently(self):
        barrier = threading.Barrier(2, timeout=2)
        sender = StatefulSender(
            {
                self.one: {"ok": True, "email": OLD_ONE},
                self.two: {"ok": True, "email": OLD_ONE},
            }
        )

        def concurrent(path, command, email, timeout=None, deadline=None, selected_at=None):
            if command == "status":
                barrier.wait()
            return sender(path, command, email, timeout=timeout, deadline=deadline,
                          selected_at=selected_at)

        with mock.patch.object(
            browser_profiles.profile_transport, "connection_paths",
            return_value=[self.one, self.two],
        ):
            result = browser_profiles.status(self.base, sender=concurrent)

        self.assertTrue(result["ok"])
        self.assertEqual([profile["connection"] for profile in result["profiles"]],
                         ["1.sock", "2.sock"])

    def test_expected_zero_allows_no_connections(self):
        sender = StatefulSender({})

        result = self.run_switch([], sender, expected_profiles=0)

        self.assertEqual(
            result,
            {"ok": True, "email": TARGET, "profiles": [], "profileCount": 0},
        )
        self.assertEqual(sender.calls, [])


if __name__ == "__main__":
    unittest.main()
