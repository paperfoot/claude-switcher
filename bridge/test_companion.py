import fcntl
import json
import os
import sys
import tempfile
import types
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

from bridge import companion


OLD_EMAIL = "old@example.com"
TARGET_EMAIL = "target@example.com"


class CompanionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name) / "claude-switcher"
        self.state = self.base / "coordinated-state.json"
        self.stack = ExitStack()
        self.stack.enter_context(mock.patch.object(companion, "BASE", self.base))
        self.stack.enter_context(mock.patch.object(companion, "STATE", self.state))
        self.stack.enter_context(
            mock.patch.object(companion, "SOCKET", self.base / "browser.sock")
        )
        self.validate_email = self.stack.enter_context(
            mock.patch.object(
                companion,
                "validate_email",
                autospec=True,
                side_effect=lambda email: email.lower(),
            )
        )
        self.code_identity = self.stack.enter_context(
            mock.patch.object(
                companion, "code_identity", autospec=True, return_value=OLD_EMAIL
            )
        )
        self.switch_code = self.stack.enter_context(
            mock.patch.object(companion, "switch_code", autospec=True)
        )
        self.browser_request = self.stack.enter_context(
            mock.patch.object(
                companion,
                "browser_request",
                autospec=True,
                return_value={"ok": True, "email": TARGET_EMAIL},
            )
        )
        self.run_backend = self.stack.enter_context(
            mock.patch.object(companion, "run_backend", autospec=True)
        )

    def tearDown(self):
        self.stack.close()
        self.temporary.cleanup()

    def assert_saved(self, result):
        self.assertEqual(json.loads(self.state.read_text()), result)

    def handle_native(self, message, keychain=None):
        fake_claude_swap = types.ModuleType("claude_swap")
        fake_claude_swap.macos_keychain = keychain or mock.Mock()
        with mock.patch.dict(sys.modules, {"claude_swap": fake_claude_swap}):
            return companion.handle_native(message)

    def test_restorable_web_entry_filters_unrestorable_cookies_without_mutating_source(self):
        entry = {
            "email": TARGET_EMAIL,
            "savedAt": 1234567890,
            "url": "https://claude.ai/new",
            "cookies": [
                {
                    "name": "expired-at-boundary",
                    "value": "old",
                    "session": False,
                    "expirationDate": 100,
                },
                {
                    "name": "zero-expiry",
                    "value": "old",
                    "session": False,
                    "expirationDate": 0,
                },
                {
                    "name": "sessionKey",
                    "value": "live",
                    "session": False,
                    "expirationDate": 101,
                },
                {
                    "name": "sessionKeyLC",
                    "value": "session",
                    "session": True,
                },
                {
                    "name": "lastActiveOrg",
                    "value": "org",
                    "session": False,
                    "expirationDate": 101,
                },
                *(
                    {
                        "name": name,
                        "value": "stale-browser-validation",
                        "session": False,
                        "expirationDate": 101,
                    }
                    for name in (
                        "__cf_bm",
                        "_cfuvid",
                        "cf_clearance",
                        "ion-vk",
                        "anthropic-device-id",
                    )
                ),
            ],
        }
        original = json.loads(json.dumps(entry))

        result = companion.restorable_web_entry(entry, now=100)

        self.assertEqual(result["email"], TARGET_EMAIL)
        self.assertEqual(result["savedAt"], 1234567890)
        self.assertEqual(result["url"], "https://claude.ai/new")
        self.assertEqual(
            [cookie["name"] for cookie in result["cookies"]],
            ["sessionKey", "sessionKeyLC", "lastActiveOrg"],
        )
        self.assertEqual(entry, original)

    def test_vault_get_drops_expired_login_without_renewing_stored_entry(self):
        entry = {
            "email": TARGET_EMAIL,
            "savedAt": 1234567890,
            "url": "https://claude.ai/new",
            "cookies": [
                {
                    "name": "sessionKey",
                    "value": "expired-login",
                    "domain": ".claude.ai",
                    "session": False,
                    "expirationDate": 100,
                }
            ],
        }
        encoded = json.dumps(entry)
        keychain = mock.Mock()
        keychain.get_password.return_value = encoded

        with mock.patch.object(companion.time, "time", return_value=100):
            result = self.handle_native(
                {"action": "vault_get", "email": TARGET_EMAIL},
                keychain=keychain,
            )

        self.assertEqual(
            result,
            {
                "ok": True,
                "entry": {
                    "email": TARGET_EMAIL,
                    "savedAt": 1234567890,
                    "url": "https://claude.ai/new",
                    "cookies": [],
                },
            },
        )
        keychain.get_password.assert_called_once_with(
            "Paperfoot Claude Switcher Web", TARGET_EMAIL
        )
        keychain.set_password.assert_not_called()
        self.assertEqual(json.loads(encoded), entry)

    def test_vault_get_does_not_restore_stale_browser_validation_cookies(self):
        browser_validation_names = (
            "__cf_bm",
            "_cfuvid",
            "cf_clearance",
            "ion-vk",
            "anthropic-device-id",
        )
        entry = {
            "email": TARGET_EMAIL,
            "savedAt": 1,
            "url": "https://claude.ai/new",
            "cookies": [
                {
                    "name": "sessionKey",
                    "value": "account-login",
                    "domain": ".claude.ai",
                    "session": False,
                    "expirationDate": 200,
                },
                *(
                    {
                        "name": name,
                        "value": "old-browser-state",
                        "domain": ".claude.ai",
                        "session": False,
                        "expirationDate": 200,
                    }
                    for name in browser_validation_names
                ),
            ],
        }
        encoded = json.dumps(entry)
        keychain = mock.Mock()
        keychain.get_password.return_value = encoded

        with mock.patch.object(companion.time, "time", return_value=100):
            result = self.handle_native(
                {"action": "vault_get", "email": TARGET_EMAIL},
                keychain=keychain,
            )

        self.assertEqual(
            [cookie["name"] for cookie in result["entry"]["cookies"]],
            ["sessionKey"],
        )
        self.assertEqual(result["entry"]["savedAt"], 1)
        keychain.set_password.assert_not_called()
        self.assertEqual(json.loads(encoded), entry)

    def test_read_state_tolerates_missing_corrupt_and_non_object_state(self):
        self.assertEqual(companion.read_state(), {})

        self.base.mkdir(parents=True)
        for content in ("{not valid json", "[]", "null"):
            with self.subTest(content=content):
                self.state.write_text(content)
                self.assertEqual(companion.read_state(), {})

    def test_code_and_web_switch_succeeds(self):
        result = companion.select_account(TARGET_EMAIL)

        self.assertTrue(result["ok"])
        self.assertEqual(result["codeEmail"], TARGET_EMAIL)
        self.assertEqual(result["webEmail"], TARGET_EMAIL)
        self.assertTrue(result["browserReady"])
        self.assertEqual(result["message"], "Chrome and Code switched")
        self.assertIsInstance(result["selectedAt"], float)
        self.switch_code.assert_called_once_with(TARGET_EMAIL)
        self.browser_request.assert_called_once_with("switch", TARGET_EMAIL)
        self.assert_saved(result)

    def test_missing_chrome_returns_code_only_success(self):
        self.browser_request.side_effect = FileNotFoundError("browser socket missing")

        result = companion.select_account(TARGET_EMAIL)

        self.assertTrue(result["ok"])
        self.assertEqual(result["codeEmail"], TARGET_EMAIL)
        self.assertIsNone(result["webEmail"])
        self.assertFalse(result["browserReady"])
        self.assertEqual(result["message"], "Code switched · connect Chrome")
        self.switch_code.assert_called_once_with(TARGET_EMAIL)
        self.browser_request.assert_called_once_with("switch", TARGET_EMAIL)
        self.assert_saved(result)

    def test_browser_transport_exceptions_restore_previous_code_account(self):
        for error in (
            TimeoutError("browser request timed out"),
            OSError("browser transport failed"),
            ValueError("browser response was invalid"),
        ):
            with self.subTest(error=type(error).__name__):
                self.switch_code.reset_mock()
                self.browser_request.reset_mock()
                self.browser_request.side_effect = error

                result = companion.select_account(TARGET_EMAIL)

                self.assertEqual(
                    result,
                    {
                        "ok": False,
                        "error": "web_unavailable",
                        "codeEmail": OLD_EMAIL,
                    },
                )
                self.assertEqual(
                    self.switch_code.call_args_list,
                    [mock.call(TARGET_EMAIL), mock.call(OLD_EMAIL)],
                )
                self.browser_request.assert_called_once_with("switch", TARGET_EMAIL)
                self.assert_saved(result)

    def test_explicit_transport_errors_restore_previous_code_account(self):
        for error in (
            "host_disconnected",
            "host_timeout",
            "browser_timeout",
            "invalid_host_response",
            "response_too_large",
        ):
            with self.subTest(error=error):
                self.switch_code.reset_mock()
                self.browser_request.reset_mock()
                self.browser_request.side_effect = None
                self.browser_request.return_value = {"ok": False, "error": error}

                result = companion.select_account(TARGET_EMAIL)

                self.assertEqual(
                    result,
                    {"ok": False, "error": error, "codeEmail": OLD_EMAIL},
                )
                self.assertEqual(
                    self.switch_code.call_args_list,
                    [mock.call(TARGET_EMAIL), mock.call(OLD_EMAIL)],
                )
                self.browser_request.assert_called_once_with("switch", TARGET_EMAIL)
                self.assert_saved(result)

    def test_explicit_code_only_switch_does_not_contact_chrome(self):
        result = companion.select_account(TARGET_EMAIL, include_browser=False)

        self.assertTrue(result["ok"])
        self.assertEqual(result["codeEmail"], TARGET_EMAIL)
        self.assertIsNone(result["webEmail"])
        self.assertFalse(result["browserReady"])
        self.assertEqual(result["message"], "Code switched · connect Chrome")
        self.browser_request.assert_not_called()
        self.assert_saved(result)

    def test_web_failure_restores_previous_code_account(self):
        self.browser_request.return_value = {
            "ok": False,
            "error": "web_login_expired",
        }

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(
            result,
            {
                "ok": False,
                "error": "web_login_expired",
                "codeEmail": OLD_EMAIL,
            },
        )
        self.assertEqual(
            self.switch_code.call_args_list,
            [mock.call(TARGET_EMAIL), mock.call(OLD_EMAIL)],
        )
        self.assert_saved(result)

    def test_web_failure_without_previous_code_account_reports_actual_code_state(self):
        self.code_identity.return_value = None
        self.browser_request.return_value = {
            "ok": False,
            "error": "web_login_expired",
        }

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(
            result,
            {
                "ok": False,
                "error": "code_only_after_web_failure",
                "codeEmail": TARGET_EMAIL,
                "browserReady": False,
            },
        )
        self.switch_code.assert_called_once_with(TARGET_EMAIL)
        self.assert_saved(result)

    def test_browser_success_with_wrong_identity_restores_previous_code_account(self):
        self.browser_request.return_value = {
            "ok": True,
            "email": "wrong@example.com",
        }

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(
            result,
            {
                "ok": False,
                "error": "web_identity_mismatch",
                "codeEmail": OLD_EMAIL,
            },
        )
        self.assertEqual(
            self.switch_code.call_args_list,
            [mock.call(TARGET_EMAIL), mock.call(OLD_EMAIL)],
        )
        self.assert_saved(result)

    def test_code_failure_never_attempts_chrome(self):
        self.code_identity.return_value = None
        self.switch_code.side_effect = RuntimeError("code switch failed")

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(result, {"ok": False, "error": "code_switch_failed"})
        self.switch_code.assert_called_once_with(TARGET_EMAIL)
        self.browser_request.assert_not_called()
        self.assertFalse(self.state.exists())

    def test_failed_rollback_is_reported_explicitly(self):
        self.browser_request.return_value = {
            "ok": False,
            "error": "web_switch_failed",
        }
        self.switch_code.side_effect = [None, RuntimeError("restore failed")]

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(result, {"ok": False, "error": "code_restore_failed"})
        self.assertEqual(
            self.switch_code.call_args_list,
            [mock.call(TARGET_EMAIL), mock.call(OLD_EMAIL)],
        )
        self.assertFalse(self.state.exists())

    def test_lock_contention_fails_before_switching(self):
        self.base.mkdir(parents=True)
        lock_path = self.base / "switch.lock"

        with lock_path.open("a") as held_lock:
            fcntl.flock(held_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(result, {"ok": False, "error": "switch_in_progress"})
        self.code_identity.assert_not_called()
        self.switch_code.assert_not_called()
        self.browser_request.assert_not_called()
        self.assertFalse(self.state.exists())

    def test_snapshot_passes_allowed_metadata_without_copying_environment_tokens(self):
        backend = {
            "accounts": [
                {
                    "email": TARGET_EMAIL,
                    "active": True,
                    "usageStatus": "fresh",
                    "usage": {
                        "fiveHour": {"pct": 12.5, "resetsAt": None},
                        "sevenDay": None,
                    },
                    "usageFetchedAt": "2026-09-28T10:00:00Z",
                }
            ]
        }
        last_switch = {
            "ok": True,
            "codeEmail": TARGET_EMAIL,
            "webEmail": TARGET_EMAIL,
            "browserReady": True,
            "selectedAt": 1.0,
        }
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps(last_switch))
        self.run_backend.return_value = backend
        self.code_identity.return_value = TARGET_EMAIL
        self.browser_request.return_value = {
            "ok": True,
            "email": TARGET_EMAIL,
            "accounts": [TARGET_EMAIL],
        }

        with mock.patch.dict(
            os.environ,
            {
                "CLAUDE_CODE_OAUTH_TOKEN": "must-not-be-copied",
                "ANTHROPIC_API_KEY": "must-not-be-copied-either",
            },
        ):
            result = companion.snapshot()

        self.run_backend.assert_called_once_with("list", "--json")
        self.code_identity.assert_called_once_with()
        self.browser_request.assert_called_once_with("status")
        self.assertEqual(result["accounts"], backend["accounts"])
        self.assertEqual(result["codeEmail"], TARGET_EMAIL)
        self.assertEqual(
            result["browser"],
            {"ok": True, "email": TARGET_EMAIL, "accounts": [TARGET_EMAIL]},
        )
        self.assertEqual(result["lastSwitch"], last_switch)
        encoded = json.dumps(result)
        self.assertNotIn("must-not-be-copied", encoded)
        self.assertNotIn("must-not-be-copied-either", encoded)

    def test_pending_selection_only_returns_current_successful_code_only_account(self):
        self.base.mkdir(parents=True)
        cases = (
            (
                {
                    "ok": True,
                    "codeEmail": TARGET_EMAIL,
                    "browserReady": False,
                },
                TARGET_EMAIL,
                TARGET_EMAIL,
                "matching pending selection",
            ),
            (
                {
                    "ok": False,
                    "codeEmail": TARGET_EMAIL,
                    "browserReady": False,
                },
                TARGET_EMAIL,
                None,
                "failed selection",
            ),
            (
                {
                    "ok": True,
                    "codeEmail": TARGET_EMAIL,
                    "browserReady": True,
                },
                TARGET_EMAIL,
                None,
                "browser already ready",
            ),
            (
                {
                    "ok": True,
                    "codeEmail": TARGET_EMAIL,
                    "browserReady": False,
                },
                OLD_EMAIL,
                None,
                "Code identity changed",
            ),
        )

        with mock.patch.object(
            companion,
            "configured_emails",
            autospec=True,
            return_value={OLD_EMAIL, TARGET_EMAIL},
        ):
            for state, identity, expected, label in cases:
                with self.subTest(case=label):
                    self.state.write_text(json.dumps(state))
                    self.code_identity.reset_mock()
                    self.code_identity.return_value = identity

                    result = self.handle_native({"action": "pending_selection"})

                    self.assertEqual(result, {"ok": True, "email": expected})

    def test_browser_ready_rejects_changed_selection(self):
        original = {
            "ok": True,
            "codeEmail": TARGET_EMAIL,
            "browserReady": False,
            "selectedAt": 1234.5,
        }
        self.base.mkdir(parents=True)

        cases = (
            (OLD_EMAIL, TARGET_EMAIL, "stored selection changed"),
            (TARGET_EMAIL, OLD_EMAIL, "Code identity changed"),
        )
        for stored_email, identity, label in cases:
            with self.subTest(case=label):
                state = {**original, "codeEmail": stored_email}
                self.state.write_text(json.dumps(state))
                self.code_identity.reset_mock()
                self.code_identity.return_value = identity

                result = self.handle_native(
                    {"action": "browser_ready", "email": TARGET_EMAIL}
                )

                self.assertEqual(
                    result, {"ok": False, "error": "selection_changed"}
                )
                self.assert_saved(state)

    def test_browser_ready_rejects_acknowledgement_while_switch_lock_is_held(self):
        state = {
            "ok": True,
            "codeEmail": TARGET_EMAIL,
            "browserReady": False,
            "selectedAt": 1234.5,
        }
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps(state))
        lock_path = self.base / "switch.lock"

        with lock_path.open("a") as held_lock:
            fcntl.flock(held_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.handle_native(
                {"action": "browser_ready", "email": TARGET_EMAIL}
            )

        self.assertEqual(result, {"ok": False, "error": "switch_in_progress"})
        self.code_identity.assert_not_called()
        self.assert_saved(state)

    def test_browser_ready_preserves_selection_timestamp_on_success(self):
        selected_at = 1234.5
        state = {
            "ok": True,
            "codeEmail": TARGET_EMAIL,
            "webEmail": None,
            "browserReady": False,
            "selectedAt": selected_at,
            "message": "Code switched · connect Chrome",
        }
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps(state))
        self.code_identity.return_value = TARGET_EMAIL

        result = self.handle_native(
            {"action": "browser_ready", "email": TARGET_EMAIL}
        )

        self.assertEqual(result, {"ok": True})
        self.assert_saved(
            {
                **state,
                "webEmail": TARGET_EMAIL,
                "browserReady": True,
                "message": "Chrome and Code switched",
            }
        )
        self.assertEqual(json.loads(self.state.read_text())["selectedAt"], selected_at)

    def test_invalid_email_is_rejected_before_any_external_call(self):
        self.validate_email.side_effect = ValueError("unknown_account")

        with self.assertRaisesRegex(ValueError, "unknown_account"):
            companion.select_account("unknown@example.com")

        self.validate_email.assert_called_once_with("unknown@example.com")
        self.code_identity.assert_not_called()
        self.switch_code.assert_not_called()
        self.browser_request.assert_not_called()
        self.run_backend.assert_not_called()
        self.assertFalse(self.base.exists())


if __name__ == "__main__":
    unittest.main()
