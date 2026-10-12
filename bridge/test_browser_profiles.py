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


class LegacyHostTests(unittest.TestCase):
    def test_a_host_from_before_an_update_is_asked_in_the_old_shape(self):
        calls = []
        def sender(path, command, email, **options):
            calls.append(options)
            if "deadline" in options:
                return {"ok": False, "error": "invalid_request"}
            return {"ok": True, "email": email}
        deadline = browser_profiles.deadlines.Deadline(300)
        result = browser_profiles._switch(Path("/tmp/1.sock"), "target@example.com", deadline, sender, 0)
        self.assertEqual(result, {"ok": True, "email": "target@example.com"})
        self.assertIn("deadline", calls[0])
        self.assertNotIn("deadline", calls[1])
        self.assertIn("timeout", calls[1])


class StampTests(unittest.TestCase):
    def test_profiles_already_on_the_target_still_record_the_selection(self):
        sent = []
        def sender(path, command, email, **options):
            if command == "status":
                return {"ok": True, "email": "target@example.com", "accounts": ["target@example.com"]}
            sent.append((path, options.get("selected_at")))
            return {"ok": True, "email": email}
        with mock.patch.object(browser_profiles.profile_transport, "connection_paths",
                               return_value=[Path("/tmp/a.sock"), Path("/tmp/b.sock")]):
            result = browser_profiles.switch(Path("/tmp"), "target@example.com", sender=sender,
                                             deadline=browser_profiles.deadlines.Deadline(300), selected_at=123.0)
        self.assertTrue(result["ok"])
        self.assertEqual(sorted(stamp for _, stamp in sent), [123.0, 123.0])

    def test_only_profiles_that_switch_are_asked_to_open_sign_in(self):
        sent = []
        def sender(path, command, email, **options):
            path = Path(path)
            if command == "status":
                current = "target@example.com" if path.name == "a.sock" else "old@example.com"
                return {"ok": True, "email": current, "accounts": []}
            sent.append((path.name, email, options.get("open_login", False)))
            if path.name == "b.sock" and email == "target@example.com":
                return {"ok": False, "error": "web_login_expired", "failureStep": "verify_identity",
                        "probeStatus": "signed_out", "httpStatus": 200, "loginOpened": True}
            return {"ok": True, "email": email}
        with mock.patch.object(browser_profiles.profile_transport, "connection_paths",
                               return_value=[Path("/tmp/a.sock"), Path("/tmp/b.sock")]):
            result = browser_profiles.switch(Path("/tmp"), "target@example.com", expected_profiles=2,
                                             sender=sender, deadline=browser_profiles.deadlines.Deadline(300),
                                             selected_at=1.0, open_login=True)
        self.assertEqual(result["error"], "web_login_expired")
        self.assertIs(result["loginOpened"], True)
        self.assertEqual(result["probeStatus"], "signed_out")
        # The profile already on the target only records the stamp; only b may open sign-in.
        self.assertEqual(sent, [("a.sock", "target@example.com", False), ("b.sock", "target@example.com", True)])


class OfficialSender:
    """Answers status, official_prepare and official_finish like connected companions."""

    def __init__(self, states, prepared, finished=None):
        self.states = {Path(path): dict(state) for path, state in states.items()}
        self.prepared = {Path(path): dict(result) for path, result in prepared.items()}
        self.finished = {Path(path): dict(result) for path, result in (finished or {}).items()}
        self.calls = []
        self.lock = threading.Lock()

    def __call__(self, path, command, email, timeout=None, deadline=None, selected_at=None):
        path = Path(path)
        with self.lock:
            self.calls.append((path, command, email, timeout))
        assert deadline is None and selected_at is None and timeout is not None
        if command == "status":
            return dict(self.states[path])
        if command == "official_prepare":
            return dict(self.prepared.get(path, {"ok": True, "state": "not_installed"}))
        if command == "official_finish":
            return dict(self.finished.get(path, {"ok": True, "authorized": False, "consent": "none"}))
        raise AssertionError(command)

    def commands(self, name):
        return [call for call in self.calls if call[1] == name]


class FollowOfficialTests(unittest.TestCase):
    def setUp(self):
        self.base = Path("/unused/bridge")
        self.one = self.base / "browsers" / "1.sock"
        self.two = self.base / "browsers" / "2.sock"
        self.clock = FakeClock()
        self.presses = []

    def press(self, result):
        def run(timeout, windows):
            self.presses.append((timeout, windows))
            return dict(result)
        return run

    def follow(self, paths, sender, press=None, seconds=300):
        with mock.patch.object(browser_profiles.profile_transport, "connection_paths", return_value=paths), \
                mock.patch.object(browser_profiles.event_log, "emit"):
            return browser_profiles.follow_official(self.base, TARGET, self.clock.deadline(seconds),
                                                    sender=sender, press=press or self.press({"ok": True}))

    def test_opened_profiles_are_pressed_then_always_finished(self):
        sender = OfficialSender(
            {self.one: {"ok": True, "email": TARGET}, self.two: {"ok": True, "email": TARGET.upper()}},
            {self.one: {"ok": True, "state": "opened", "windowId": 7},
             self.two: {"ok": True, "state": "opened", "windowId": 9}},
            {self.one: {"ok": True, "authorized": True, "consent": "clicked"},
             self.two: {"ok": True, "authorized": True, "consent": "skipped"}})

        result = self.follow([self.one, self.two], sender,
                             self.press({"ok": True, "windows": 2, "pressed": 2, "signedIn": 2}))

        self.assertTrue(result["ok"])
        self.assertIs(result["extensionReady"], True)
        self.assertNotIn("extensionError", result)
        self.assertEqual(result["pressed"], 2)
        self.assertEqual(self.presses, [(60, 2)])
        self.assertEqual([call[2] for call in sender.commands("official_prepare")], [TARGET, TARGET])
        self.assertTrue(all(call[3] <= 20 for call in sender.commands("official_prepare")))
        self.assertEqual(len(sender.commands("official_finish")), 2)
        self.assertEqual(result["profiles"][0],
                         {"connection": "1.sock", "state": "opened", "authorized": True, "consent": "clicked"})

    def test_profiles_on_another_account_are_left_alone(self):
        sender = OfficialSender({self.one: {"ok": True, "email": OLD_ONE}}, {})

        result = self.follow([self.one], sender)

        self.assertEqual(result, {"ok": True, "extensionReady": None, "extension": "no_profiles"})
        self.assertEqual(sender.commands("official_prepare"), [])
        self.assertEqual(self.presses, [])

    def test_nothing_to_do_without_the_official_extension(self):
        sender = OfficialSender({self.one: {"ok": True, "email": TARGET}},
                                {self.one: {"ok": True, "state": "not_installed"}})

        result = self.follow([self.one], sender)

        self.assertIsNone(result["extensionReady"])
        self.assertEqual(result["extension"], "not_installed")
        self.assertEqual(self.presses, [])
        self.assertEqual(sender.commands("official_finish"), [])

    def test_a_failed_press_still_finishes_and_reports_why(self):
        sender = OfficialSender({self.one: {"ok": True, "email": TARGET}},
                                {self.one: {"ok": True, "state": "opened"}})

        result = self.follow([self.one], sender, self.press({"ok": False, "error": "accessibility_needed"}))

        self.assertIs(result["extensionReady"], False)
        self.assertEqual(result["extensionError"], "accessibility_needed")
        self.assertEqual(len(sender.commands("official_finish")), 1)

    def test_consent_seen_by_every_profile_counts_without_the_helper(self):
        sender = OfficialSender({self.one: {"ok": True, "email": TARGET}},
                                {self.one: {"ok": True, "state": "opened"}},
                                {self.one: {"ok": True, "authorized": True, "consent": "clicked"}})

        result = self.follow([self.one], sender, self.press({"ok": False, "error": "timeout"}))

        self.assertIs(result["extensionReady"], True)

    def test_refused_consent_is_reported(self):
        sender = OfficialSender({self.one: {"ok": True, "email": TARGET}},
                                {self.one: {"ok": True, "state": "opened"}},
                                {self.one: {"ok": True, "authorized": False, "consent": "refused"}})

        result = self.follow([self.one], sender, self.press({"ok": False, "error": "timeout"}))

        self.assertEqual(result["extensionError"], "consent_refused")

    def test_the_helper_never_eats_the_time_needed_to_finish(self):
        sender = OfficialSender({self.one: {"ok": True, "email": TARGET}},
                                {self.one: {"ok": True, "state": "opened"}})

        self.follow([self.one], sender, self.press({"ok": True}), seconds=40)

        self.assertEqual(len(self.presses), 1)
        self.assertLessEqual(self.presses[0][0], 40 - 15)


class PressLoginTests(unittest.TestCase):
    def test_missing_helper_is_reported(self):
        with mock.patch.dict(browser_profiles.os.environ, {"CLAUDE_SWITCHER_EXECUTABLE": "/nonexistent"}), \
                mock.patch.object(browser_profiles, "APP_EXECUTABLE", "/nonexistent/app"):
            self.assertEqual(browser_profiles.press_login(5, 1), {"ok": False, "error": "helper_missing"})

    def test_helper_arguments_and_reply(self):
        import os
        import stat
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "claude-switcher"
            script.write_text('#!/bin/sh\necho "$@" >&2\necho \'{"ok":true,"windows":1,"pressed":1,"signedIn":1}\'\n')
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            with mock.patch.dict(os.environ, {"CLAUDE_SWITCHER_EXECUTABLE": str(script)}), \
                    mock.patch.object(browser_profiles.subprocess, "run",
                                      wraps=browser_profiles.subprocess.run) as run:
                result = browser_profiles.press_login(12.7, 2)
            self.assertEqual(result, {"ok": True, "windows": 1, "pressed": 1, "signedIn": 1})
            self.assertEqual(run.call_args.args[0],
                             [str(script), "--chrome-extension-login", "--timeout", "12", "--windows", "2"])
