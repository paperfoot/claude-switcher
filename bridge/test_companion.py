import fcntl
import json
import os
import tempfile
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
