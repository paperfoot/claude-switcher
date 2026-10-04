import unittest
from pathlib import Path
from unittest import mock

from bridge import browser_profiles


OLD_ONE = "one@example.com"
OLD_TWO = "two@example.com"
TARGET = "target@example.com"


class StatefulSender:
    def __init__(self, states, switch_results=None):
        self.states = {Path(path): dict(state) for path, state in states.items()}
        self.switch_results = {
            (Path(path), email): [dict(result) for result in results]
            for (path, email), results in (switch_results or {}).items()
        }
        self.calls = []

    def __call__(self, path, command, email, timeout):
        path = Path(path)
        self.calls.append((path, command, email, timeout))
        if command == "status":
            return dict(self.states[path])

        scripted = self.switch_results.get((path, email), [])
        result = scripted.pop(0) if scripted else {"ok": True, "email": email}
        if result.get("ok") and result.get("email"):
            self.states[path] = {**self.states[path], **result}
        return dict(result)

    def switch_calls(self):
        return [call for call in self.calls if call[1] == "switch"]


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
                (self.one, "switch", TARGET, 170),
                (self.two, "switch", TARGET, 170),
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
        self.assertIn((self.one, "switch", OLD_ONE, 170), sender.switch_calls())

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
