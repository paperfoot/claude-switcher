import fcntl
import io
import json
import math
import os
import sys
import tempfile
import time
import types
import unittest
from contextlib import ExitStack, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from bridge import browser_profiles, companion


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
        self.stack.enter_context(mock.patch.object(companion.deadlines, "LOCK_WAIT", 0.05))
        self.stack.enter_context(mock.patch.object(companion.deadlines, "POPUP_LOCK_WAIT", 0.05))

    def tearDown(self):
        self.stack.close()
        self.temporary.cleanup()

    def assert_saved(self, result):
        self.assertEqual(json.loads(self.state.read_text()), result)

    def code_targets(self):
        return [call.args[0] for call in self.switch_code.call_args_list]

    def assert_browser_switch(self, email, **expected):
        self.browser_request.assert_called_once()
        args, kwargs = self.browser_request.call_args
        self.assertEqual(args, ("switch", email))
        self.assertIsInstance(kwargs.pop("deadline"), companion.deadlines.Deadline)
        self.assertIsInstance(kwargs.pop("selected_at"), float)
        self.assertEqual(kwargs, expected)

    def handle_native(self, message, keychain=None):
        fake_engine = types.ModuleType("switch_engine")
        fake_engine.macos_keychain = keychain or mock.Mock()
        with mock.patch.dict(sys.modules, {"switch_engine": fake_engine}):
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

    def web_entry(self, value="key-1", url="https://claude.ai/chat/1", saved_at=1):
        return {
            "email": TARGET_EMAIL,
            "savedAt": saved_at,
            "url": url,
            "cookies": [
                {"name": "sessionKey", "value": value, "domain": ".claude.ai", "session": False,
                 "expirationDate": 2_000_000_000},
                {"name": "lastActiveOrg", "value": "org", "domain": ".claude.ai", "session": False,
                 "expirationDate": 2_000_000_000},
            ],
        }

    def put_with_stored(self, stored, entry):
        keychain = mock.Mock()
        encoded = json.dumps(entry, separators=(",", ":"))
        keychain.get_password.side_effect = [stored, encoded]
        with mock.patch.object(companion, "configured_emails", return_value={TARGET_EMAIL}):
            result = self.handle_native({"action": "vault_put", "entry": entry}, keychain=keychain)
        return result, keychain, encoded

    def test_vault_put_skips_the_keychain_write_when_nothing_changed(self):
        self.base.mkdir(parents=True)
        accounts = self.base / "web-accounts.json"
        accounts.write_text(json.dumps([TARGET_EMAIL]))
        before = accounts.stat().st_mtime_ns
        stored = self.web_entry(saved_at=1)
        stored["cookies"].reverse()
        result, keychain, _ = self.put_with_stored(json.dumps(stored), self.web_entry(saved_at=99))

        self.assertEqual(result, {"ok": True, "saved": False})
        keychain.set_password.assert_not_called()
        self.assertEqual(keychain.get_password.call_count, 1)
        self.assertEqual(accounts.stat().st_mtime_ns, before)

    def test_vault_put_writes_renewed_cookies_and_new_pages(self):
        self.base.mkdir(parents=True)
        cases = (
            ("renewed value", json.dumps(self.web_entry()), self.web_entry(value="key-2")),
            ("later page", json.dumps(self.web_entry()), self.web_entry(url="https://claude.ai/chat/2")),
            ("first save", None, self.web_entry()),
            ("unreadable stored entry", "{not json", self.web_entry()),
        )
        for label, stored, entry in cases:
            with self.subTest(case=label):
                result, keychain, encoded = self.put_with_stored(stored, entry)
                self.assertEqual(result, {"ok": True, "saved": True})
                keychain.set_password.assert_called_once_with(
                    "Paperfoot Claude Switcher Web", TARGET_EMAIL, encoded)
        self.assertEqual(json.loads((self.base / "web-accounts.json").read_text()), [TARGET_EMAIL])

    def test_vault_put_records_when_the_saved_login_expires_without_cookie_values(self):
        self.base.mkdir(parents=True)
        entry = self.web_entry(value="secret-session-value")
        entry["cookies"] = [
            {"name": "sessionKey", "value": "secret-session-value", "domain": ".claude.ai",
             "session": False, "expirationDate": 2_000_000_100},
            {"name": "sessionKeyLC", "value": "secret-lc", "domain": ".claude.ai",
             "session": False, "expirationDate": 2_000_000_050.5},
            {"name": "sessionKeyV3", "value": "secret-v3", "domain": ".claude.ai", "session": True},
            {"name": "lastActiveOrg", "value": "org", "domain": ".claude.ai",
             "session": False, "expirationDate": 1_000},
        ]
        result, _, _ = self.put_with_stored(None, entry)

        self.assertTrue(result["ok"])
        meta = (self.base / "web-accounts-meta.json").read_text()
        self.assertEqual(json.loads(meta), {"expiries": {TARGET_EMAIL: 2_000_000_050.5}})
        self.assertNotIn("secret", meta)
        # Older companions keep reading the plain list.
        self.assertEqual(json.loads((self.base / "web-accounts.json").read_text()), [TARGET_EMAIL])

    def test_a_login_without_persistent_session_cookies_drops_its_expiry(self):
        self.base.mkdir(parents=True)
        self.put_with_stored(None, self.web_entry())
        session_only = self.web_entry(value="key-2")
        session_only["cookies"][0] = {"name": "sessionKey", "value": "key-2", "domain": ".claude.ai", "session": True}
        self.put_with_stored(json.dumps(self.web_entry()), session_only)
        self.assertEqual(json.loads((self.base / "web-accounts-meta.json").read_text()), {"expiries": {}})

    def test_vault_list_reports_expiries_for_configured_saved_accounts(self):
        self.base.mkdir(parents=True)
        (self.base / "web-accounts.json").write_text(json.dumps([OLD_EMAIL, TARGET_EMAIL]))
        (self.base / "web-accounts-meta.json").write_text(json.dumps({"expiries": {
            TARGET_EMAIL: 1_900_000_000, OLD_EMAIL: 1_900_000_001,
            "stranger@example.com": 1_900_000_002, "bad@example.com": "soon"}}))
        with mock.patch.object(companion, "configured_emails", return_value={TARGET_EMAIL}):
            result = self.handle_native({"action": "vault_list"})
        self.assertEqual(result, {"ok": True, "accounts": [TARGET_EMAIL],
                                  "expiries": {TARGET_EMAIL: 1_900_000_000}})

    def test_vault_list_without_expiry_metadata_still_lists_accounts(self):
        self.base.mkdir(parents=True)
        (self.base / "web-accounts.json").write_text(json.dumps([TARGET_EMAIL]))
        for meta in (None, "{not json", "[]", '{"expiries": []}'):
            with self.subTest(meta=meta):
                path = self.base / "web-accounts-meta.json"
                if meta is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_text(meta)
                with mock.patch.object(companion, "configured_emails", return_value={TARGET_EMAIL}):
                    result = self.handle_native({"action": "vault_list"})
                self.assertEqual(result, {"ok": True, "accounts": [TARGET_EMAIL], "expiries": {}})

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
        self.assertEqual(self.code_targets(), [TARGET_EMAIL])
        self.assert_browser_switch(TARGET_EMAIL)
        self.assert_saved(result)

    def test_missing_chrome_returns_code_only_success(self):
        self.browser_request.side_effect = FileNotFoundError("browser socket missing")

        result = companion.select_account(TARGET_EMAIL)

        self.assertTrue(result["ok"])
        self.assertEqual(result["codeEmail"], TARGET_EMAIL)
        self.assertIsNone(result["webEmail"])
        self.assertFalse(result["browserReady"])
        self.assertEqual(result["message"], "Code switched · connect Chrome")
        self.assertEqual(self.code_targets(), [TARGET_EMAIL])
        self.assert_browser_switch(TARGET_EMAIL)
        self.assert_saved(result)

    def test_browser_transport_exceptions_keep_selected_code_account(self):
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
                        "partial": True,
                        "error": "code_only_after_web_failure",
                        "browserError": "web_unavailable",
                        "codeEmail": TARGET_EMAIL,
                        "webEmail": None,
                        "browserReady": False,
                        "selectedAt": mock.ANY,
                    },
                )
                self.assertEqual(self.code_targets(), [TARGET_EMAIL])
                self.assert_browser_switch(TARGET_EMAIL)
                self.assert_saved(result)

    def test_explicit_transport_errors_keep_selected_code_account(self):
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
                    {
                        "ok": False,
                        "partial": True,
                        "error": "code_only_after_web_failure",
                        "browserError": error,
                        "codeEmail": TARGET_EMAIL,
                        "webEmail": None,
                        "browserReady": False,
                        "selectedAt": mock.ANY,
                    },
                )
                self.assertEqual(self.code_targets(), [TARGET_EMAIL])
                self.assert_browser_switch(TARGET_EMAIL)
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

    def test_web_failure_keeps_selected_code_account(self):
        self.browser_request.return_value = {
            "ok": False,
            "error": "web_login_expired",
        }

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(
            result,
            {
                "ok": False,
                "partial": True,
                "error": "code_only_after_web_failure",
                "browserError": "web_login_expired",
                "codeEmail": TARGET_EMAIL,
                "webEmail": None,
                "browserReady": False,
                "selectedAt": mock.ANY,
            },
        )
        self.assertEqual(self.code_targets(), [TARGET_EMAIL])
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
                "partial": True,
                "error": "code_only_after_web_failure",
                "browserError": "web_login_expired",
                "codeEmail": TARGET_EMAIL,
                "webEmail": None,
                "browserReady": False,
                "selectedAt": mock.ANY,
            },
        )
        self.assertEqual(self.code_targets(), [TARGET_EMAIL])
        self.assert_saved(result)

    def test_browser_success_with_wrong_identity_keeps_selected_code_account(self):
        self.browser_request.return_value = {
            "ok": True,
            "email": "wrong@example.com",
        }

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(
            result,
            {
                "ok": False,
                "partial": True,
                "error": "code_only_after_web_failure",
                "browserError": "web_identity_mismatch",
                "codeEmail": TARGET_EMAIL,
                "webEmail": None,
                "browserReady": False,
                "selectedAt": mock.ANY,
            },
        )
        self.assertEqual(self.code_targets(), [TARGET_EMAIL])
        self.assert_saved(result)

    def test_code_failure_never_attempts_chrome(self):
        self.code_identity.return_value = None
        self.switch_code.side_effect = RuntimeError("code switch failed")

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(result, {"ok": False, "error": "code_switch_failed"})
        self.assertEqual(self.code_targets(), [TARGET_EMAIL])
        self.browser_request.assert_not_called()
        self.assertFalse(self.state.exists())

    def test_code_failure_restores_previous_code_account(self):
        self.switch_code.side_effect = [RuntimeError("code switch failed"), None]

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(result, {"ok": False, "error": "code_switch_failed"})
        self.assertEqual(self.code_targets(), [TARGET_EMAIL, OLD_EMAIL])
        self.browser_request.assert_not_called()
        self.assertFalse(self.state.exists())

    def test_failed_code_restore_is_reported_explicitly(self):
        self.switch_code.side_effect = [
            RuntimeError("code switch failed"),
            RuntimeError("restore failed"),
        ]

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(result, {"ok": False, "error": "code_restore_failed"})
        self.assertEqual(self.code_targets(), [TARGET_EMAIL, OLD_EMAIL])
        self.browser_request.assert_not_called()
        self.assertFalse(self.state.exists())

    def test_browser_failure_never_attempts_code_rollback(self):
        self.browser_request.return_value = {
            "ok": False,
            "error": "web_switch_failed",
        }

        result = companion.select_account(TARGET_EMAIL)

        self.assertEqual(
            result,
            {
                "ok": False,
                "partial": True,
                "error": "code_only_after_web_failure",
                "browserError": "web_switch_failed",
                "codeEmail": TARGET_EMAIL,
                "webEmail": None,
                "browserReady": False,
                "selectedAt": mock.ANY,
            },
        )
        self.assertEqual(self.code_targets(), [TARGET_EMAIL])
        self.assert_saved(result)

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

        self.assertEqual(self.run_backend.call_args.args, ("list", "--json"))
        self.assertLessEqual(self.run_backend.call_args.kwargs["timeout"], companion.deadlines.CSWAP_TIMEOUT)
        self.code_identity.assert_called_once()
        self.assertLessEqual(self.code_identity.call_args.kwargs["timeout"], companion.deadlines.IDENTITY_TIMEOUT)
        self.assertEqual(self.browser_request.call_args.args, ("status",))
        self.assertIsInstance(self.browser_request.call_args.kwargs["deadline"], companion.deadlines.Deadline)
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

    def per_profile_selection(self):
        return self.handle_native({"action": "pending_selection", "perProfile": True})

    def test_selection_is_offered_to_every_profile_after_one_catches_up(self):
        state = {"ok": True, "codeEmail": TARGET_EMAIL, "browserReady": False, "selectedAt": 1234.5}
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps(state))
        self.code_identity.return_value = TARGET_EMAIL
        with mock.patch.object(companion, "configured_emails", return_value={OLD_EMAIL, TARGET_EMAIL}):
            first = self.per_profile_selection()
            ready = self.handle_native(
                {"action": "browser_ready", "email": TARGET_EMAIL, "selectedAt": 1234.5})
            second = self.per_profile_selection()
            legacy = self.handle_native({"action": "pending_selection"})

        expected = {"ok": True, "email": TARGET_EMAIL, "selectedAt": 1234.5, "unfinished": False, "loginDead": False}
        self.assertEqual(first, expected)
        self.assertEqual(ready, {"ok": True})
        self.assertTrue(json.loads(self.state.read_text())["browserReady"])
        # A second profile, or one that was closed during the switch, still sees it.
        self.assertEqual(second, expected)
        # 0.7.x companions keep their one-shot behaviour.
        self.assertEqual(legacy, {"ok": True, "email": None})

    def test_selection_says_when_the_saved_login_is_known_dead(self):
        state = {"ok": False, "partial": True, "codeEmail": TARGET_EMAIL, "browserReady": False, "selectedAt": 99.0}
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps(state))
        (self.base / "web-accounts-meta.json").write_text(json.dumps({"expiries": {TARGET_EMAIL: 1.0}}))
        self.code_identity.return_value = TARGET_EMAIL
        with mock.patch.object(companion, "configured_emails", return_value={TARGET_EMAIL}):
            self.assertTrue(self.per_profile_selection()["loginDead"])

    def test_selection_includes_code_switches_that_some_profiles_missed(self):
        state = {"ok": False, "partial": True, "error": "code_only_after_web_failure",
                 "browserError": "host_timeout", "codeEmail": TARGET_EMAIL,
                 "browserReady": False, "selectedAt": 99.0}
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps(state))
        self.code_identity.return_value = TARGET_EMAIL
        with mock.patch.object(companion, "configured_emails", return_value={TARGET_EMAIL}):
            self.assertEqual(self.per_profile_selection(),
                             {"ok": True, "email": TARGET_EMAIL, "selectedAt": 99.0, "unfinished": True, "loginDead": False})
            with mock.patch.object(companion, "spawn_extension_follow", autospec=True) as follow:
                ready = self.handle_native(
                    {"action": "browser_ready", "email": TARGET_EMAIL, "selectedAt": 99.0})
        self.assertEqual(ready, {"ok": True})
        # Chrome caught up, for example after the user signed in: the switch is complete,
        # and the official Claude extension follows outside this native reply.
        self.assert_saved({"ok": True, "codeEmail": TARGET_EMAIL, "browserReady": True,
                           "selectedAt": 99.0, "webEmail": TARGET_EMAIL,
                           "message": "Chrome and Code switched", "recovered": True})
        follow.assert_called_once_with(TARGET_EMAIL)

    def test_browser_ready_leaves_a_partial_switch_for_another_account_or_code_login(self):
        state = {"ok": False, "partial": True, "error": "code_only_after_web_failure",
                 "browserError": "web_login_expired", "codeEmail": TARGET_EMAIL,
                 "browserReady": False, "selectedAt": 99.0, "loginOpened": True}
        self.base.mkdir(parents=True)
        cases = ((OLD_EMAIL, TARGET_EMAIL, 99.0, "Chrome signed in to another account"),
                 (TARGET_EMAIL, OLD_EMAIL, 99.0, "Code moved on since"),
                 (TARGET_EMAIL, TARGET_EMAIL, 98.0, "an older selection"))
        for email, identity, stamp, label in cases:
            with self.subTest(case=label):
                self.state.write_text(json.dumps(state))
                self.code_identity.return_value = identity
                with mock.patch.object(companion, "configured_emails", return_value={OLD_EMAIL, TARGET_EMAIL}), \
                        mock.patch.object(companion, "spawn_extension_follow", autospec=True) as follow:
                    ready = self.handle_native(
                        {"action": "browser_ready", "email": email, "selectedAt": stamp})
                self.assertEqual(ready, {"ok": False, "error": "selection_changed"})
                self.assert_saved(state)
                follow.assert_not_called()

    def test_extension_follow_runs_detached_from_the_native_reply(self):
        with mock.patch.object(companion.subprocess, "Popen", autospec=True) as popen:
            companion.spawn_extension_follow(TARGET_EMAIL)
        args, kwargs = popen.call_args
        self.assertEqual(args[0][0], sys.executable)
        self.assertTrue(args[0][1].endswith("companion.py"))
        self.assertEqual(args[0][2:], ["extension-follow", TARGET_EMAIL])
        self.assertTrue(kwargs["start_new_session"])
        self.assertIs(kwargs["stdin"], companion.subprocess.DEVNULL)

    def test_only_menu_switches_ask_chrome_to_open_sign_in(self):
        companion.select_account(TARGET_EMAIL, open_login=True)
        self.assertIs(self.browser_request.call_args.kwargs["open_login"], True)
        for call in (lambda: companion.select_account(TARGET_EMAIL),
                     lambda: companion.select_account(TARGET_EMAIL, verified_browser=True, open_login=False)):
            self.browser_request.reset_mock()
            call()
            self.assertNotIn("open_login", self.browser_request.call_args.kwargs)
        self.browser_request.reset_mock()
        companion.select_browser(TARGET_EMAIL, open_login=True)
        self.assertIs(self.browser_request.call_args.kwargs["open_login"], True)

    def test_the_menu_commands_open_sign_in_and_automatic_ticks_do_not(self):
        for argv, target in ((["switch", TARGET_EMAIL], "select_account"),
                             (["browser-switch", TARGET_EMAIL], "select_browser")):
            with self.subTest(command=argv[0]), \
                    mock.patch.object(companion, target, autospec=True, return_value={"ok": True}) as run, \
                    mock.patch.object(sys, "argv", ["companion.py", *argv]), redirect_stdout(io.StringIO()):
                companion.main()
            self.assertIs(run.call_args.kwargs["open_login"], True)
        with mock.patch.object(companion, "auto_tick", autospec=True, return_value={"ok": True}) as tick, \
                mock.patch.object(companion, "schedule_login_check", autospec=True) as schedule, \
                mock.patch.object(sys, "argv", ["companion.py", "auto-tick", "95"]), redirect_stdout(io.StringIO()):
            companion.main()
        self.assertNotIn("open_login", tick.call_args.kwargs)
        schedule.assert_called_once_with()

    def test_a_dead_saved_login_is_marked_expired_and_the_opened_sign_in_is_reported(self):
        self.base.mkdir(parents=True)
        (self.base / "web-accounts.json").write_text(json.dumps([TARGET_EMAIL]))
        (self.base / "web-accounts-meta.json").write_text(json.dumps({"expiries": {TARGET_EMAIL: 4_000_000_000}}))
        self.browser_request.return_value = {"ok": False, "error": "web_login_expired", "rolledBack": True,
                                             "failureStep": "verify_identity", "probeStatus": "signed_out",
                                             "httpStatus": 200, "loginOpened": True}
        result = companion.select_account(TARGET_EMAIL, open_login=True)

        self.assertEqual(result["browserError"], "web_login_expired")
        self.assertIs(result["loginOpened"], True)
        self.assertLessEqual(companion.read_expiries()[TARGET_EMAIL], companion.time.time())

    def test_a_later_save_replaces_the_expired_mark(self):
        self.base.mkdir(parents=True)
        (self.base / "web-accounts.json").write_text(json.dumps([TARGET_EMAIL]))
        self.assertTrue(companion.mark_login_expired(TARGET_EMAIL, now=1_000.0))
        self.assertEqual(companion.read_expiries(), {TARGET_EMAIL: 1_000.0})
        entry = self.web_entry(value="fresh")
        entry["cookies"] = [{"name": "sessionKey", "value": "fresh", "domain": ".claude.ai",
                             "session": False, "expirationDate": 2_000_000_100}]
        self.put_with_stored(None, entry)
        self.assertEqual(companion.read_expiries(), {TARGET_EMAIL: 2_000_000_100})

    def test_marking_ignores_logins_that_were_never_saved(self):
        self.base.mkdir(parents=True)
        self.assertFalse(companion.mark_login_expired(TARGET_EMAIL, now=1_000.0))
        self.assertEqual(companion.read_expiries(), {})

    def test_selection_requires_the_active_code_login_and_a_valid_stamp(self):
        good = {"ok": True, "codeEmail": TARGET_EMAIL, "selectedAt": 10.0}
        cases = (
            (good, OLD_EMAIL, {TARGET_EMAIL}, "Code login changed since"),
            (good, TARGET_EMAIL, {OLD_EMAIL}, "account no longer configured"),
            ({**good, "ok": False}, TARGET_EMAIL, {TARGET_EMAIL}, "Code switch failed"),
            ({**good, "selectedAt": None}, TARGET_EMAIL, {TARGET_EMAIL}, "no stamp"),
            ({**good, "selectedAt": True}, TARGET_EMAIL, {TARGET_EMAIL}, "boolean stamp"),
            ({**good, "selectedAt": "10"}, TARGET_EMAIL, {TARGET_EMAIL}, "text stamp"),
            ({}, TARGET_EMAIL, {TARGET_EMAIL}, "no selection yet"),
        )
        self.base.mkdir(parents=True)
        for state, identity, configured, label in cases:
            with self.subTest(case=label):
                self.state.write_text(json.dumps(state))
                self.code_identity.return_value = identity
                with mock.patch.object(companion, "configured_emails", return_value=configured):
                    self.assertEqual(self.per_profile_selection(),
                                     {"ok": True, "email": None, "selectedAt": None})

    def test_selection_is_deferred_while_a_switch_runs(self):
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps({"ok": True, "codeEmail": TARGET_EMAIL, "selectedAt": 1.0}))
        with (self.base / "switch.lock").open("a") as held_lock:
            fcntl.flock(held_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.per_profile_selection()
        self.assertEqual(result, {"ok": False, "error": "switch_in_progress"})
        self.code_identity.assert_not_called()

    def test_one_stamp_covers_the_code_switch_every_profile_and_the_saved_state(self):
        result = companion.select_account(TARGET_EMAIL)

        stamp = self.browser_request.call_args.kwargs["selected_at"]
        self.assertEqual(result["selectedAt"], stamp)
        self.assertEqual(json.loads(self.state.read_text())["selectedAt"], stamp)

    def test_chrome_only_switch_stamps_its_selection_without_code_state(self):
        companion.select_browser(TARGET_EMAIL, expected_profiles=2)

        self.assertIsInstance(self.browser_request.call_args.kwargs["selected_at"], float)
        self.assertFalse(self.state.exists())

    def test_browser_ready_rejects_another_selection_stamp(self):
        state = {"ok": True, "codeEmail": TARGET_EMAIL, "browserReady": False, "selectedAt": 1.0}
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps(state))
        self.code_identity.return_value = TARGET_EMAIL

        result = self.handle_native(
            {"action": "browser_ready", "email": TARGET_EMAIL, "selectedAt": 2.0})

        self.assertEqual(result, {"ok": False, "error": "selection_changed"})
        self.assert_saved(state)

    def test_browser_ready_never_overwrites_a_switch_that_finished_meanwhile(self):
        state = {"ok": True, "codeEmail": TARGET_EMAIL, "browserReady": False, "selectedAt": 1.0}
        newer = {"ok": True, "codeEmail": TARGET_EMAIL, "browserReady": True, "selectedAt": 2.0}
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps(state))

        def identity_while_another_switch_finishes(**_):
            self.state.write_text(json.dumps(newer))
            return TARGET_EMAIL

        self.code_identity.side_effect = identity_while_another_switch_finishes
        result = self.handle_native(
            {"action": "browser_ready", "email": TARGET_EMAIL, "selectedAt": 1.0})

        self.assertEqual(result, {"ok": False, "error": "selection_changed"})
        self.assert_saved(newer)

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

    def test_browser_only_does_not_read_or_change_code(self):
        result = companion.select_browser(TARGET_EMAIL, expected_profiles=2)
        self.assertTrue(result['ok'])
        self.assert_browser_switch(TARGET_EMAIL, expected_profiles=2)
        self.code_identity.assert_not_called()
        self.switch_code.assert_not_called()
        self.run_backend.assert_not_called()
        self.assertFalse(self.state.exists())

    def test_connection_ping_does_not_access_credentials_or_accounts(self):
        with mock.patch.dict(sys.modules, {'switch_engine': None}):
            self.assertEqual(companion.handle_native({'action': 'ping'}), {'ok': True})
        self.code_identity.assert_not_called()
        self.switch_code.assert_not_called()
        self.run_backend.assert_not_called()

    def test_failed_browser_switch_preserves_safe_diagnostics(self):
        self.browser_request.return_value = {
            'ok': False, 'error': 'web_switch_failed', 'failureStep': 'restore_cookies',
            'cookieName': 'sessionKey', 'failedConnection': '12.sock', 'rolledBack': True,
            'probeStatus': 'unauthorized', 'httpStatus': 401,
            'cookieValue': 'must-not-appear', 'rawException': 'must-not-appear',
        }
        result = companion.select_account(TARGET_EMAIL)
        self.assertFalse(result['ok'])
        self.assertTrue(result['partial'])
        self.assertEqual(result['error'], 'code_only_after_web_failure')
        self.assertEqual(result['browserError'], 'web_switch_failed')
        self.assertEqual(result['codeEmail'], TARGET_EMAIL)
        self.assertIsNone(result['webEmail'])
        self.assertFalse(result['browserReady'])
        self.assertEqual(result['failureStep'], 'restore_cookies')
        self.assertEqual(result['cookieName'], 'sessionKey')
        self.assertEqual(result['failedConnection'], '12.sock')
        self.assertTrue(result['rolledBack'])
        self.assertEqual(result['probeStatus'], 'unauthorized')
        self.assertEqual(result['httpStatus'], 401)
        self.assertNotIn('must-not-appear', json.dumps(result))
        self.assertEqual(self.code_targets(), [TARGET_EMAIL])
        self.assert_saved(result)

    def test_partial_switch_log_has_failure_metadata_without_addresses(self):
        self.browser_request.return_value = {
            'ok': False,
            'error': 'web_login_expired',
            'failureStep': 'verify_identity',
            'probeStatus': 'unauthorized',
            'httpStatus': 401,
        }

        companion.select_account(TARGET_EMAIL)

        events = companion.event_log.recent(self.base)
        self.assertEqual([event['event'] for event in events],
                         ['switch_started', 'switch_finished'])
        self.assertEqual(events[0]['scope'], 'claude')
        self.assertEqual(events[1]['scope'], 'claude')
        self.assertFalse(events[1]['ok'])
        self.assertTrue(events[1]['partial'])
        self.assertEqual(events[1]['error'], 'code_only_after_web_failure')
        self.assertEqual(events[1]['browserError'], 'web_login_expired')
        self.assertEqual(events[1]['failureStep'], 'verify_identity')
        self.assertEqual(events[1]['probeStatus'], 'unauthorized')
        self.assertEqual(events[1]['httpStatus'], 401)
        self.assertFalse(events[1]['browserReady'])
        log_text = (self.base / 'events.jsonl').read_text()
        self.assertNotIn(OLD_EMAIL, log_text)
        self.assertNotIn(TARGET_EMAIL, log_text)
        self.assertNotIn('@', log_text)

    def test_browser_only_failure_is_logged_without_target_address(self):
        self.browser_request.return_value = {'ok': False, 'error': 'host_timeout'}

        result = companion.select_browser(TARGET_EMAIL, expected_profiles=2)

        self.assertEqual(result, {'ok': False, 'error': 'host_timeout'})
        events = companion.event_log.recent(self.base)
        self.assertEqual([event['event'] for event in events],
                         ['switch_started', 'switch_finished'])
        self.assertEqual(events[0]['scope'], 'chrome')
        self.assertEqual(events[1]['scope'], 'chrome')
        self.assertFalse(events[1]['ok'])
        self.assertEqual(events[1]['error'], 'host_timeout')
        self.assertNotIn(TARGET_EMAIL, (self.base / 'events.jsonl').read_text())

    def test_native_diagnostic_log_sanitizes_untrusted_fields(self):
        result = self.handle_native(
            {
                'action': 'diagnostic',
                'details': {
                    'event': 'native_error',
                    'error': 'web_login_expired',
                    'failureStep': 'verify_identity',
                    'httpStatus': 401,
                    'email': TARGET_EMAIL,
                    'cookieValue': 'must-not-appear',
                },
            }
        )

        self.assertEqual(result, {'ok': True})
        events = companion.event_log.recent(self.base)
        self.assertEqual(len(events), 1)
        event = events[0]
        self.assertEqual(event['event'], 'browser_error')
        self.assertEqual(event['error'], 'web_login_expired')
        self.assertEqual(event['failureStep'], 'verify_identity')
        self.assertEqual(event['httpStatus'], 401)
        log_text = (self.base / 'events.jsonl').read_text()
        self.assertNotIn(TARGET_EMAIL, log_text)
        self.assertNotIn('must-not-appear', log_text)

    def assert_code(self, result, code):
        self.assertEqual(result["ok"], False)
        self.assertEqual(result["error"], code)
        self.assertRegex(result["error"], r"^[a-z_]+$")
        self.assertIn(code, companion.event_log.ERRORS)
        self.assertIsInstance(result["message"], str)

    def test_native_failures_carry_a_code_and_separate_text(self):
        locked = mock.Mock()
        locked.get_password.side_effect = RuntimeError("security: User interaction is not allowed.")
        self.assert_code(
            self.handle_native({"action": "vault_get", "email": TARGET_EMAIL}, keychain=locked),
            "keychain_unavailable")
        self.assert_code(
            self.handle_native({"action": "vault_put", "entry": {
                "email": TARGET_EMAIL, "cookies": [{"name": "sessionKey", "domain": ".example.com"}]}}),
            "invalid_data")
        self.assert_code(self.handle_native({"action": "vault_put", "entry": "not an entry"}), "invalid_data")
        self.validate_email.side_effect = ValueError("unknown_account")
        self.assert_code(
            self.handle_native({"action": "vault_get", "email": "stranger@example.com"}), "unknown_account")
        self.validate_email.side_effect = lambda email: email.lower()
        with mock.patch.object(companion, "select_account", side_effect=RuntimeError("boom")):
            self.assert_code(self.handle_native({"action": "select", "email": TARGET_EMAIL}),
                             "backend_unavailable")
        with mock.patch.dict(sys.modules, {"switch_engine": None}):
            self.assert_code(companion.handle_native({"action": "vault_list"}), "backend_unavailable")
        logged = [event["error"] for event in companion.event_log.recent(self.base)]
        self.assertIn("keychain_unavailable", logged)
        self.assertNotIn("User interaction", (self.base / "events.jsonl").read_text())

    def run_main(self, *arguments):
        output = io.StringIO()
        with (
            mock.patch.object(companion.sys, "argv", ["companion.py", *arguments]),
            redirect_stdout(output),
        ):
            try:
                companion.main()
                status = 0
            except SystemExit as exit:
                status = exit.code
        return json.loads(output.getvalue()), status

    def test_command_line_failures_carry_a_code_and_separate_text(self):
        with mock.patch.object(companion, "select_account", side_effect=RuntimeError("boom")):
            result, status = self.run_main("switch", TARGET_EMAIL)
        self.assert_code(result, "backend_unavailable")
        self.assertEqual(status, 1)
        with mock.patch.object(companion, "select_account", side_effect=ValueError("unknown_account")):
            result, _ = self.run_main("switch", "stranger@example.com")
        self.assert_code(result, "unknown_account")
        result, status = self.run_main("switch")
        self.assert_code(result, "invalid_request")
        self.assertEqual(status, 1)

    def test_browser_only_refuses_during_another_account_switch(self):
        self.base.mkdir()
        with open(self.base / 'switch.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(companion.select_browser(TARGET_EMAIL),
                             {'ok': False, 'error': 'switch_in_progress'})
        self.browser_request.assert_not_called()
        self.switch_code.assert_not_called()

    def test_popup_selection_excludes_its_waiting_native_host(self):
        self.browser_request.return_value = {'ok': True, 'email': TARGET_EMAIL}
        result = self.handle_native({'action': 'select', 'email': TARGET_EMAIL})
        self.assertTrue(result['ok'])
        self.assert_browser_switch(TARGET_EMAIL, expected_profiles=0, exclude=companion.SOCKET)

    def test_invalid_email_is_rejected_before_any_external_call(self):
        self.validate_email.side_effect = ValueError("unknown_account")

        with self.assertRaisesRegex(ValueError, "unknown_account"):
            companion.select_account("unknown@example.com")

        self.validate_email.assert_called_once_with("unknown@example.com")
        self.code_identity.assert_not_called()
        self.switch_code.assert_not_called()
        self.browser_request.assert_not_called()
        self.run_backend.assert_not_called()
        self.assertFalse(self.state.exists())


class CodeCacheCoordinatorTests(unittest.TestCase):
    def test_already_active_account_still_refreshes_existing_code_cache(self):
        with (
            mock.patch.object(companion, 'validate_email'),
            mock.patch.object(companion, 'run_backend', return_value={'reason': 'already-active'}) as backend,
            mock.patch.object(companion, 'code_identity', return_value=TARGET_EMAIL),
            mock.patch.object(companion, 'refresh_code_cache', return_value={'ok': True, 'cacheUpdated': True}) as refresh,
        ):
            companion.switch_code(TARGET_EMAIL)
        self.assertEqual(backend.call_args.args, ('switch', TARGET_EMAIL, '--json'))
        self.assertLessEqual(backend.call_args.kwargs['timeout'], companion.deadlines.CSWAP_TIMEOUT)
        refresh.assert_called_once_with(TARGET_EMAIL)

    def test_cache_repair_failure_does_not_undo_verified_code_login(self):
        with (
            mock.patch.object(companion, 'validate_email'),
            mock.patch.object(companion, 'run_backend') as backend,
            mock.patch.object(companion, 'code_identity', return_value=TARGET_EMAIL),
            mock.patch.object(companion, 'refresh_code_cache', return_value={'ok': False, 'error': 'code_cache_sync_failed'}),
        ):
            companion.switch_code(TARGET_EMAIL)
        self.assertEqual(backend.call_args.args, ('switch', TARGET_EMAIL, '--json'))
        self.assertLessEqual(backend.call_args.kwargs['timeout'], companion.deadlines.CSWAP_TIMEOUT)


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def wall(self):
        return 1_000_000.0 + self.now

    def deadline(self, seconds):
        return companion.deadlines.Deadline(seconds, clock=self.monotonic, wall=self.wall)


class DeadlineCoordinatorTests(unittest.TestCase):
    """The menu and popup budgets flow into every Code and Chrome step."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name) / "claude-switcher"
        self.clock = FakeClock()
        self.backend_calls = []
        self.identity_timeouts = []
        self.identity = OLD_EMAIL
        self.stack = ExitStack()
        self.stack.enter_context(mock.patch.object(companion, "BASE", self.base))
        self.stack.enter_context(
            mock.patch.object(companion, "STATE", self.base / "coordinated-state.json"))
        self.stack.enter_context(
            mock.patch.object(companion, "validate_email", side_effect=lambda email: email.lower()))
        self.stack.enter_context(
            mock.patch.object(companion, "code_identity", side_effect=self.fake_identity))
        self.stack.enter_context(
            mock.patch.object(companion, "run_backend", side_effect=self.fake_backend))
        self.refresh = self.stack.enter_context(
            mock.patch.object(companion, "refresh_code_cache", return_value={"ok": True}))
        self.browser_request = self.stack.enter_context(
            mock.patch.object(companion, "browser_request",
                              return_value={"ok": True, "email": TARGET_EMAIL}))
        self.backend_seconds = 1.0
        self.backend_failures = 0

    def tearDown(self):
        self.stack.close()
        self.temporary.cleanup()

    def fake_identity(self, timeout):
        self.identity_timeouts.append(timeout)
        self.clock.now += 1
        return self.identity

    def fake_backend(self, *args, timeout):
        self.backend_calls.append((args, timeout))
        if self.backend_failures:
            self.backend_failures -= 1
            self.clock.now += timeout
            raise companion.subprocess.TimeoutExpired("cswap", timeout)
        self.clock.now += self.backend_seconds
        if args[0] == "switch":
            self.identity = args[1]
        return {}

    def test_code_steps_get_the_time_left_and_keep_time_to_restore_code(self):
        deadline = self.clock.deadline(100)

        result = companion.select_account(TARGET_EMAIL, deadline=deadline)

        self.assertTrue(result["ok"])
        reserve = companion.deadlines.CODE_RESTORE_RESERVE
        identity = companion.deadlines.IDENTITY_TIMEOUT
        # The old identity read, the forward cswap and its identity check all leave the restore
        # reserve; the forward cswap also leaves time for that identity check.
        self.assertEqual(self.identity_timeouts[0], min(15, 100 - reserve))
        self.assertEqual(self.backend_calls, [(("switch", TARGET_EMAIL, "--json"), 100 - 1 - reserve - identity)])
        self.assertEqual(self.identity_timeouts[1], 15)
        self.refresh.assert_called_once_with(TARGET_EMAIL)
        self.assertIs(self.browser_request.call_args.kwargs["deadline"], deadline)

    def test_code_switch_is_not_started_without_time_to_restore_it(self):
        self.clock.now = 0
        deadline = self.clock.deadline(50)
        self.clock.now = 6

        result = companion.select_account(TARGET_EMAIL, deadline=deadline)

        self.assertEqual(result, {"ok": False, "error": "code_switch_failed"})
        self.assertEqual(self.backend_calls, [])
        self.browser_request.assert_not_called()

    def test_timed_out_cswap_restores_previous_code_login_before_the_deadline(self):
        self.backend_failures = 1
        deadline = self.clock.deadline(120)

        result = companion.select_account(TARGET_EMAIL, deadline=deadline)

        self.assertEqual(result, {"ok": False, "error": "code_switch_failed"})
        self.assertEqual([call[0] for call in self.backend_calls],
                         [("switch", TARGET_EMAIL, "--json"), ("switch", OLD_EMAIL, "--json")])
        forward, restore = (call[1] for call in self.backend_calls)
        reserve = companion.deadlines.CODE_RESTORE_RESERVE
        identity = companion.deadlines.IDENTITY_TIMEOUT
        self.assertEqual(forward, min(60, 120 - 1 - reserve - identity))
        # The restore keeps time for its own identity check before the deadline.
        self.assertEqual(restore, min(60, 120 - 1 - forward - identity))
        self.assertLessEqual(self.clock.now, 120)
        self.browser_request.assert_not_called()

    def test_cache_repair_is_skipped_when_it_could_overrun_the_deadline(self):
        self.backend_seconds = 45
        deadline = self.clock.deadline(70)

        companion.switch_code(TARGET_EMAIL, deadline)

        self.refresh.assert_not_called()
        events = companion.event_log.recent(self.base)
        self.assertEqual(events[-1]["error"], "code_cache_sync_skipped")

    def test_popup_selection_uses_the_extension_deadline_within_bounds(self):
        fake_swap = types.ModuleType("switch_engine")
        fake_swap.macos_keychain = mock.Mock()
        cases = (
            (90, 90),
            (600, companion.deadlines.POPUP_BUDGET),
            (None, companion.deadlines.LEGACY_POPUP_BUDGET),
            ("soon", companion.deadlines.LEGACY_POPUP_BUDGET),
            (True, companion.deadlines.LEGACY_POPUP_BUDGET),
        )
        for offset, expected in cases:
            with self.subTest(offset=offset):
                message = {"action": "select", "email": TARGET_EMAIL}
                if isinstance(offset, (int, float)) and not isinstance(offset, bool):
                    message["deadline"] = (companion.time.time() + offset) * 1000
                elif offset is not None:
                    message["deadline"] = offset
                with (
                    mock.patch.dict(sys.modules, {"switch_engine": fake_swap}),
                    mock.patch.object(companion, "select_account", return_value={"ok": True}) as select,
                ):
                    companion.handle_native(message)
                remaining = select.call_args.kwargs["deadline"].remaining()
                self.assertAlmostEqual(remaining, expected, delta=1)
                self.assertTrue(select.call_args.kwargs["verified_browser"])

    def test_menu_switch_runs_under_the_menu_budget(self):
        output = io.StringIO()
        with (
            mock.patch.object(companion.sys, "argv", ["companion.py", "switch", TARGET_EMAIL]),
            mock.patch.object(companion, "select_account", return_value={"ok": True}) as select,
            redirect_stdout(output),
        ):
            companion.main()
        remaining = select.call_args.kwargs["deadline"].remaining()
        self.assertAlmostEqual(remaining, companion.deadlines.MENU_BUDGET, delta=1)
        self.assertLess(companion.deadlines.MENU_BUDGET, 350)
        self.assertEqual(json.loads(output.getvalue()), {"ok": True})


if __name__ == "__main__":
    unittest.main()


class AutoTickTests(unittest.TestCase):
    """One engine auto-switch decision, with Chrome following any Code switch."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name) / "claude-switcher"
        self.state = self.base / "coordinated-state.json"
        self.stack = ExitStack()
        self.stack.enter_context(mock.patch.object(companion, "BASE", self.base))
        self.stack.enter_context(mock.patch.object(companion, "STATE", self.state))
        self.stack.enter_context(mock.patch.object(
            companion, "validate_email", autospec=True, side_effect=self.validate))
        self.code_identity = self.stack.enter_context(mock.patch.object(
            companion, "code_identity", autospec=True, return_value=OLD_EMAIL))
        self.browser_request = self.stack.enter_context(mock.patch.object(
            companion, "browser_request", autospec=True, return_value={"ok": True, "email": TARGET_EMAIL}))
        self.refresh = self.stack.enter_context(mock.patch.object(
            companion, "refresh_code_cache", autospec=True, return_value={"ok": True, "cacheUpdated": False}))

    def tearDown(self):
        self.stack.close()
        self.temporary.cleanup()

    @staticmethod
    def validate(email):
        if email.lower() not in (OLD_EMAIL, TARGET_EMAIL):
            raise ValueError("unknown_account")
        return email.lower()

    @staticmethod
    def switched_to(email, dry_run=False):
        return [{"event": "poll", "active": {"number": 1, "email": OLD_EMAIL}},
                {"event": "switch", "trigger": "proactive", "from": {"number": 1, "email": OLD_EMAIL},
                 "to": {"number": 2, "email": email}, "dryRun": dry_run}]

    def stored_state(self):
        return json.loads(self.state.read_text())

    def test_no_action_reports_the_engine_reason_and_leaves_chrome_alone(self):
        events = [{"event": "poll"}, {"event": "no-switch", "reason": "below-threshold", "detail": "54% < 95%"}]
        result = companion.auto_tick(95, events=events)
        self.assertEqual(result, {"ok": True, "switched": False, "reason": "below-threshold"})
        self.browser_request.assert_not_called()
        self.assertFalse(self.state.exists())

    def test_all_accounts_exhausted_is_reported(self):
        events = [{"event": "poll"}, {"event": "all-exhausted", "earliestResetAt": None}]
        self.assertEqual(companion.auto_tick(95, events=events)["reason"], "all_exhausted")

    def test_a_dry_run_switch_event_changes_nothing(self):
        result = companion.auto_tick(95, events=self.switched_to(TARGET_EMAIL, dry_run=True))
        self.assertFalse(result["switched"])
        self.browser_request.assert_not_called()

    def test_switch_moves_chrome_and_records_a_selection_for_late_profiles(self):
        self.code_identity.side_effect = [OLD_EMAIL, TARGET_EMAIL]
        result = companion.auto_tick(95, events=self.switched_to(TARGET_EMAIL))
        self.assertEqual(result["switched"], True)
        self.assertEqual(result["codeEmail"], TARGET_EMAIL)
        self.assertEqual(result["previousEmail"], OLD_EMAIL)
        self.assertTrue(result["browserReady"])
        self.assertEqual(self.browser_request.call_args.args[:2], ("switch", TARGET_EMAIL))
        state = self.stored_state()
        self.assertTrue(state["ok"])
        self.assertTrue(state["automatic"])
        self.assertEqual(state["codeEmail"], TARGET_EMAIL)
        self.assertIsInstance(state["selectedAt"], float)
        # The app matches a later Chrome catch-up against this selection.
        self.assertEqual(result["selectedAt"], state["selectedAt"])

    def test_a_known_dead_chrome_login_is_not_restored_but_code_still_moves(self):
        self.code_identity.side_effect = [OLD_EMAIL, TARGET_EMAIL]
        self.base.mkdir(parents=True, exist_ok=True)
        (self.base / "web-accounts-meta.json").write_text(json.dumps({"expiries": {TARGET_EMAIL: 1.0}}))
        result = companion.auto_tick(95, events=self.switched_to(TARGET_EMAIL))
        self.browser_request.assert_not_called()
        self.assertTrue(result["switched"])
        self.assertEqual(result["browserError"], "web_login_expired")
        state = self.stored_state()
        self.assertTrue(state["partial"])
        self.assertEqual(state["browserError"], "web_login_expired")

    def test_closed_chrome_still_records_a_selection_to_catch_up_on(self):
        self.code_identity.side_effect = [OLD_EMAIL, TARGET_EMAIL]
        self.browser_request.return_value = {"ok": False, "error": "browser_missing"}
        result = companion.auto_tick(95, events=self.switched_to(TARGET_EMAIL))
        self.assertFalse(result["browserReady"])
        state = self.stored_state()
        self.assertTrue(state["ok"])
        self.assertFalse(state["browserReady"])

    def test_a_chrome_failure_keeps_code_switched_and_is_recorded_as_partial(self):
        self.code_identity.side_effect = [OLD_EMAIL, TARGET_EMAIL]
        self.browser_request.return_value = {"ok": False, "error": "web_switch_failed"}
        result = companion.auto_tick(95, events=self.switched_to(TARGET_EMAIL))
        self.assertTrue(result["ok"])
        self.assertEqual(result["browserError"], "web_switch_failed")
        state = self.stored_state()
        self.assertTrue(state["partial"])
        self.assertEqual(state["error"], "code_only_after_web_failure")

    def test_chrome_does_not_follow_when_code_did_not_land_on_the_target(self):
        self.code_identity.side_effect = [OLD_EMAIL, OLD_EMAIL]
        result = companion.auto_tick(95, events=self.switched_to(TARGET_EMAIL))
        self.assertEqual(result["error"], "code_switch_failed")
        self.browser_request.assert_not_called()

    def test_an_account_the_switcher_does_not_know_is_not_mirrored(self):
        self.code_identity.side_effect = [OLD_EMAIL, "stranger@example.com"]
        result = companion.auto_tick(95, events=self.switched_to("stranger@example.com"))
        self.assertEqual(result["error"], "unknown_account")
        # Code did move, so the app must hear about it rather than stay silent.
        self.assertTrue(result["switched"])
        self.assertEqual(result["codeEmail"], "stranger@example.com")
        self.browser_request.assert_not_called()

    def test_a_running_switch_makes_the_tick_skip(self):
        self.base.mkdir(parents=True)
        with open(self.base / "switch.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = companion.auto_tick(95, events=self.switched_to(TARGET_EMAIL))
        self.assertEqual(result, {"ok": True, "switched": False, "reason": "switch_in_progress"})

    def test_a_manual_choice_holds_until_it_runs_low_and_an_automatic_one_does_not(self):
        self.base.mkdir(parents=True, exist_ok=True)
        now = 10_000.0
        with mock.patch.object(companion, "agents_driving_browser", return_value=False):
            self.state.write_text(json.dumps({"ok": True, "codeEmail": TARGET_EMAIL, "selectedAt": now - 1800}))
            self.assertEqual(companion.hold_reason(TARGET_EMAIL, now), "manual")
            # Hours later the pick still stands.
            self.state.write_text(json.dumps({"ok": True, "codeEmail": TARGET_EMAIL, "selectedAt": now - 9 * 3600}))
            self.assertEqual(companion.hold_reason(TARGET_EMAIL.upper(), now), "manual")
            # Code moved elsewhere since, so the pick no longer describes it.
            self.assertIsNone(companion.hold_reason(OLD_EMAIL, now))
            self.state.write_text(json.dumps({"ok": True, "codeEmail": TARGET_EMAIL, "selectedAt": now - 60,
                                              "automatic": True}))
            self.assertIsNone(companion.hold_reason(TARGET_EMAIL, now))
        with mock.patch.object(companion, "agents_driving_browser", return_value=True):
            self.assertEqual(companion.hold_reason(TARGET_EMAIL, now), "agents")
        (self.base / "hold").touch()
        self.assertEqual(companion.hold_reason(TARGET_EMAIL, now), "pinned")

    def test_a_decision_is_logged_once_until_it_changes(self):
        events = [{"event": "poll", "active": {"number": 2, "email": OLD_EMAIL}, "headroomPct": {"2": 12.0}},
                  {"event": "no-switch", "reason": "held"}]
        with mock.patch.object(companion, "auto_events", return_value=events), \
                mock.patch.object(companion, "hold_reason", return_value="manual"), \
                mock.patch.object(companion.event_log, "emit") as emit:
            self.code_identity.side_effect = None
            self.code_identity.return_value = OLD_EMAIL
            companion.auto_tick(95)
            companion.auto_tick(95)
            decisions = [call for call in emit.call_args_list if call.args[1] == "auto_decision"]
            self.assertEqual(len(decisions), 1)
            self.assertEqual(decisions[0].kwargs, {"reason": "held", "hold": "manual", "used": 88})

    def test_a_fast_burn_brings_the_exit_forward_and_a_slow_one_keeps_the_threshold(self):
        # Tonight's run: 92% to 97% in seven minutes on one account.
        fast = [[0, 3, 92.0], [180, 3, 94.0], [300, 3, 95.0], [420, 3, 97.0]]
        self.assertAlmostEqual(companion.burn_rate(fast) * 60, 5 / 7)
        self.assertEqual(companion.leave_at(99, fast), 92.9)
        slow = [[0, 3, 60.0], [600, 3, 61.0]]
        self.assertEqual(companion.leave_at(99, slow), 99)
        # Too little history to judge a pace yet.
        self.assertEqual(companion.leave_at(99, [[0, 3, 90.0], [60, 3, 95.0]]), 99)
        # A burst brings the exit forward by at most BURN_MAX_MARGIN; a lower setting still wins.
        self.assertEqual(companion.leave_at(99, [[0, 3, 10.0], [180, 3, 60.0]]), 80.0)
        self.assertEqual(companion.leave_at(60, [[0, 3, 10.0], [180, 3, 60.0]]), 60)

    def test_the_pace_carries_across_a_switch_but_not_the_jump_itself(self):
        samples = [[0, 3, 90.0], [240, 3, 94.0], [300, 1, 16.0], [480, 1, 19.0]]
        # 4 points in 240 s plus 3 in 180 s; the 94 -> 16 step between accounts is skipped.
        self.assertAlmostEqual(companion.burn_rate(samples), 7 / 420)
        # A reset reads as a drop and is skipped too.
        self.assertEqual(companion.burn_rate([[0, 3, 98.0], [300, 3, 2.0]]), 0.0)

    def test_the_tick_passes_the_paced_exit_to_the_engine_and_records_its_reading(self):
        now = time.time()
        self.base.mkdir(parents=True)
        (self.base / "burn.json").write_text(json.dumps(
            [[now - 900 - 5, 2, 50.0], [now - 420, 2, 92.0], [now - 60, 2, 97.0]]))
        events = [{"event": "poll", "active": {"number": 2, "email": OLD_EMAIL}, "headroomPct": {"2": 2.0}},
                  {"event": "no-switch", "reason": "cooldown"}]
        with mock.patch.object(companion, "auto_events", return_value=events) as engine, \
                mock.patch.object(companion, "hold_reason", return_value="agents"), \
                mock.patch.object(companion.event_log, "emit") as emit:
            companion.auto_tick(99)
        leave = engine.call_args.args[0]
        self.assertEqual(leave, 91.7)  # 5 points in 6 minutes: leave about 8 points early
        self.assertEqual(engine.call_args.kwargs, {"hold": True})
        decision = next(call for call in emit.call_args_list if call.args[1] == "auto_decision")
        self.assertEqual(decision.kwargs["leaveAt"], math.floor(leave))
        stored = json.loads((self.base / "burn.json").read_text())
        self.assertEqual(len(stored), 3)  # the sample older than the window is dropped
        self.assertEqual(stored[-1][1:], [2, 98.0])

    def test_recent_browser_or_computer_use_by_any_session_is_seen(self):
        home = Path(self.temporary.name) / "home"
        project = home / ".claude" / "projects" / "-work"
        (project / "s1" / "subagents").mkdir(parents=True)
        now = time.time()

        def line(tool, seconds_ago):
            stamp = datetime.fromtimestamp(now - seconds_ago, timezone.utc).isoformat().replace("+00:00", "Z")
            return json.dumps({"type": "assistant", "timestamp": stamp,
                               "message": {"content": [{"type": "tool_use", "name": tool}]}},
                              separators=(",", ":")) + "\n"

        session = project / "s1.jsonl"
        subagent = project / "s1" / "subagents" / "agent-a.jsonl"
        with mock.patch.object(companion.Path, "home", return_value=home):
            session.write_text(line("Bash", 30))
            self.assertFalse(companion.agents_driving_browser(now))
            subagent.write_text(line("mcp__claude-in-chrome__computer", 60))
            self.assertTrue(companion.agents_driving_browser(now))
            subagent.write_text(line("mcp__computer-use__screenshot", 3600))
            self.assertFalse(companion.agents_driving_browser(now))
            session.write_text(line("mcp__computer-use__left_click", 120))
            self.assertTrue(companion.agents_driving_browser(now))

    def test_an_out_of_range_threshold_is_refused(self):
        for threshold in (101, 10, float("nan")):
            self.assertEqual(companion.auto_tick(threshold, events=[])["error"], "invalid_request")

    def test_engine_output_is_parsed_and_its_failure_raises(self):
        output = b'{"event":"poll"}\n{"event":"no-switch","reason":"below-threshold"}\nnot json\n'
        completed = types.SimpleNamespace(returncode=2, stdout=output, stderr=b"")
        with mock.patch.object(companion, "configuration", return_value={"engine": "/bin/cswap"}), \
                mock.patch.object(companion.subprocess, "run", return_value=completed) as run:
            events = companion.auto_events(95.0, timeout=30)
        self.assertEqual([event["event"] for event in events], ["poll", "no-switch"])
        self.assertEqual(run.call_args.args[0], ["/bin/cswap", "auto", "--once", "--json", "--strategy", "consume-first",
                                                 "--cooldown", "120", "--threshold", "95", "--urgent-only"])
        with mock.patch.object(companion, "configuration", return_value={"engine": "/bin/cswap"}), \
                mock.patch.object(companion.subprocess, "run", return_value=completed) as run:
            companion.auto_events(95.0, timeout=30, hold=True)
        self.assertEqual(run.call_args.args[0][-1], "--hold")
        failed = types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"")
        with mock.patch.object(companion, "configuration", return_value={"engine": "/bin/cswap"}), \
                mock.patch.object(companion.subprocess, "run", return_value=failed):
            with self.assertRaises(RuntimeError):
                companion.auto_events(95.0, timeout=30)

    def test_an_engine_failure_after_code_moved_still_brings_chrome_along(self):
        self.code_identity.side_effect = [OLD_EMAIL, TARGET_EMAIL]
        with mock.patch.object(companion, "auto_events", side_effect=RuntimeError("auto_switch_failed")):
            result = companion.auto_tick(95)
        self.assertTrue(result["switched"])
        self.assertEqual(result["codeEmail"], TARGET_EMAIL)
        self.assertEqual(self.browser_request.call_args.args[:2], ("switch", TARGET_EMAIL))

    def test_an_engine_failure_without_a_move_is_quiet(self):
        with mock.patch.object(companion, "auto_events", side_effect=RuntimeError("auto_switch_failed")):
            result = companion.auto_tick(95)
        self.assertEqual(result, {"ok": True, "switched": False, "reason": "auto_switch_failed"})
        self.browser_request.assert_not_called()


class ExpiryBackfillTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.stack = ExitStack()
        self.stack.enter_context(mock.patch.object(companion, "BASE", self.base))
        self.stack.enter_context(mock.patch.object(companion, "_EXPIRY_CHECKED", set()))

    def tearDown(self):
        self.stack.close()
        self.temporary.cleanup()

    def test_older_saved_logins_gain_an_expiry_once(self):
        saved = {TARGET_EMAIL: json.dumps({"email": TARGET_EMAIL, "cookies": [
            {"name": "sessionKey", "value": "secret", "expirationDate": 2_000_000_000.0},
            {"name": "other", "value": "x", "expirationDate": 1_000.0}]})}
        reads = []
        def read(email):
            reads.append(email)
            return saved.get(email)
        companion.backfill_expiries([TARGET_EMAIL, OLD_EMAIL], read)
        companion.backfill_expiries([TARGET_EMAIL, OLD_EMAIL], read)
        self.assertEqual(companion.read_expiries(), {TARGET_EMAIL: 2_000_000_000.0})
        # Each email is read at most once per process, including one with nothing saved.
        self.assertEqual(sorted(reads), sorted([TARGET_EMAIL, OLD_EMAIL]))
        self.assertNotIn("secret", (self.base / "web-accounts-meta.json").read_text())


class LoginCheckTests(unittest.TestCase):
    """Saved web logins claude.ai has signed out are marked expired, so the app warns."""

    LIVE, DEAD, FLAKY = "live@example.com", "dead@example.com", "flaky@example.com"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.stack = ExitStack()
        self.stack.enter_context(mock.patch.object(companion, "BASE", self.base))
        (self.base / "web-accounts.json").write_text(json.dumps([self.LIVE, self.DEAD, self.FLAKY]))
        (self.base / "web-accounts-meta.json").write_text(json.dumps(
            {"expiries": {email: 4_000_000_000 for email in (self.LIVE, self.DEAD, self.FLAKY)}}))

    def tearDown(self):
        self.stack.close()
        self.temporary.cleanup()

    @staticmethod
    def saved(email):
        return json.dumps({"email": email, "cookies": [
            {"name": "sessionKey", "value": "secret-" + email, "domain": ".claude.ai",
             "session": False, "expirationDate": 4_000_000_000},
            {"name": "cf_clearance", "value": "browser-bound", "domain": ".claude.ai", "session": True}]})

    def test_signed_out_logins_are_marked_and_unanswered_ones_left_alone(self):
        replies = {"secret-" + self.LIVE: "live", "secret-" + self.DEAD: "dead", "secret-" + self.FLAKY: "unknown"}
        sent = []
        def probe(cookies):
            sent.append([cookie["name"] for cookie in cookies])
            return replies[cookies[0]["value"]]
        with redirect_stdout(io.StringIO()) as output:
            result = companion.check_logins(read=self.saved, probe=probe, now=2_000_000_000.0)
            print(json.dumps(result))

        self.assertEqual(result, {"ok": True, "checked": 3, "live": 1, "unknown": 1, "expired": [self.DEAD]})
        self.assertEqual(companion.read_expiries(), {self.LIVE: 4_000_000_000, self.DEAD: 2_000_000_000.0,
                                                     self.FLAKY: 4_000_000_000})
        # Browser-bound Cloudflare cookies are never replayed; no cookie value is printed or stored.
        self.assertEqual(sent, [["sessionKey"]] * 3)
        self.assertNotIn("secret", output.getvalue())
        self.assertNotIn("secret", (self.base / "web-accounts-meta.json").read_text())
        self.assertEqual(json.loads((self.base / "login-check.json").read_text()), {"lastRun": 2_000_000_000.0})

    def test_bootstrap_replies_are_classified_conservatively(self):
        import urllib.error

        def reply(body):
            response = mock.MagicMock()
            response.__enter__.return_value.read.return_value = json.dumps(body).encode()
            return response

        def refused(code, content_type="application/json", **headers):
            message = mock.Mock()
            message.get.side_effect = lambda key, default=None: {"Content-Type": content_type, **headers}.get(key, default)
            return urllib.error.HTTPError(companion.BOOTSTRAP_URL, code, "x", message, None)

        cookies = [{"name": "sessionKey", "value": "secret"}]
        cases = (
            (reply({"account": None, "locale": "en"}), "dead"),
            (reply({"account": {"email_address": "a@example.com"}}), "live"),
            (reply({"unexpected": True}), "unknown"),
            (refused(401), "dead"),
            (refused(403), "dead"),
            (refused(403, "text/html", **{"cf-mitigated": "challenge"}), "unknown"),
            (refused(429), "unknown"),
            (refused(503), "unknown"),
            (urllib.error.URLError("offline"), "unknown"),
        )
        for outcome, expected in cases:
            with self.subTest(expected=expected, outcome=repr(outcome)[:60]):
                with mock.patch("urllib.request.urlopen", side_effect=[outcome]) as urlopen:
                    self.assertEqual(companion.bootstrap_status(cookies), expected)
                request = urlopen.call_args.args[0]
                self.assertEqual(request.full_url, companion.BOOTSTRAP_URL)
                self.assertEqual(request.get_header("Cookie"), "sessionKey=secret")

    def test_the_automatic_check_runs_at_most_every_six_hours(self):
        with mock.patch.object(companion.subprocess, "Popen", autospec=True) as popen:
            self.assertTrue(companion.schedule_login_check(now=1_000_000.0))
            self.assertFalse(companion.schedule_login_check(now=1_000_000.0 + 6 * 3600 - 1))
            self.assertTrue(companion.schedule_login_check(now=1_000_000.0 + 6 * 3600))
        self.assertEqual(popen.call_count, 2)
        self.assertEqual(popen.call_args.args[0][2:], ["check-logins"])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])


class FollowExtensionTests(unittest.TestCase):
    """The official extension follows a verified switch without ever undoing it."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name) / "claude-switcher"
        self.state = self.base / "coordinated-state.json"
        self.stack = ExitStack()
        self.stack.enter_context(mock.patch.object(companion, "BASE", self.base))
        self.stack.enter_context(mock.patch.object(companion, "STATE", self.state))
        self.stack.enter_context(mock.patch.object(
            companion, "validate_email", autospec=True, side_effect=lambda email: email.lower()))
        self.code_identity = self.stack.enter_context(mock.patch.object(
            companion, "code_identity", autospec=True, return_value=OLD_EMAIL))
        self.stack.enter_context(mock.patch.object(companion, "switch_code", autospec=True))
        self.stack.enter_context(mock.patch.object(
            companion, "refresh_code_cache", autospec=True, return_value={"ok": True}))
        self.browser_request = self.stack.enter_context(mock.patch.object(
            companion, "browser_request", autospec=True,
            return_value={"ok": True, "email": TARGET_EMAIL, "profileCount": 1}))
        self.follow = self.stack.enter_context(mock.patch.object(
            browser_profiles, "follow_official", autospec=True,
            return_value={"ok": True, "extensionReady": True, "extension": "opened", "profiles": []}))
        self.stack.enter_context(mock.patch.object(companion.deadlines, "LOCK_WAIT", 0.05))

    def tearDown(self):
        self.stack.close()
        self.temporary.cleanup()

    def test_a_menu_switch_signs_the_official_extension_in_and_records_it(self):
        result = companion.select_account(TARGET_EMAIL)
        self.assertTrue(result["ok"])
        self.assertIs(result["extensionReady"], True)
        self.assertNotIn("extensionError", result)
        self.assertEqual(self.follow.call_args.args[1], TARGET_EMAIL)
        self.assertIs(json.loads(self.state.read_text())["extensionReady"], True)

    def test_a_failure_is_reported_but_never_fails_the_switch(self):
        self.follow.return_value = {"ok": True, "extensionReady": False, "extensionError": "accessibility_needed"}
        result = companion.select_account(TARGET_EMAIL)
        self.assertTrue(result["ok"])
        self.assertTrue(result["browserReady"])
        self.assertEqual(result["extensionError"], "accessibility_needed")
        self.follow.side_effect = RuntimeError("boom")
        result = companion.select_account(TARGET_EMAIL)
        self.assertTrue(result["ok"])
        self.assertEqual(result["extensionError"], "extension_follow_failed")

    def test_skipped_when_chrome_did_not_switch_or_for_a_popup_selection(self):
        self.browser_request.return_value = {"ok": False, "error": "browser_missing"}
        companion.select_account(TARGET_EMAIL)
        self.browser_request.return_value = {"ok": True, "email": TARGET_EMAIL, "profileCount": 0}
        companion.select_account(TARGET_EMAIL)
        companion.select_account(TARGET_EMAIL, verified_browser=True)
        companion.select_account(TARGET_EMAIL, include_browser=False)
        self.follow.assert_not_called()

    def test_skipped_with_too_little_time_left(self):
        deadline = companion.deadlines.Deadline(companion.deadlines.OFFICIAL_MINIMUM - 1)
        self.assertEqual(companion.follow_extension(TARGET_EMAIL, deadline),
                         {"extensionReady": False, "extensionError": "browser_timeout"})
        self.follow.assert_not_called()

    def test_a_chrome_only_switch_follows_too(self):
        result = companion.select_browser(TARGET_EMAIL)
        self.assertIs(result["extensionReady"], True)

    def test_an_automatic_switch_follows_too(self):
        self.code_identity.side_effect = [OLD_EMAIL, TARGET_EMAIL]
        events = [{"event": "switch", "trigger": "at-limit", "to": {"email": TARGET_EMAIL}}]
        result = companion.auto_tick(95, events=events)
        self.assertTrue(result["switched"])
        self.assertIs(result["extensionReady"], True)
        self.assertIs(json.loads(self.state.read_text())["extensionReady"], True)

    def test_the_repair_command_runs_only_the_follow_step(self):
        output = io.StringIO()
        with mock.patch.object(companion.sys, "argv", ["companion.py", "extension-follow", TARGET_EMAIL]), \
                redirect_stdout(output):
            companion.main()
        self.assertEqual(json.loads(output.getvalue()),
                         {"ok": True, "email": TARGET_EMAIL, "extensionReady": True})
        self.browser_request.assert_not_called()


class LockWaitTests(unittest.TestCase):
    def test_a_manual_switch_waits_for_a_short_automatic_check(self):
        import threading
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "switch.lock"
            held = open(path, "a")
            fcntl.flock(held, fcntl.LOCK_EX)
            threading.Timer(0.3, lambda: (fcntl.flock(held, fcntl.LOCK_UN), held.close())).start()
            with open(path, "a") as lock:
                self.assertTrue(companion.wait_for_lock(lock, cap=5))

    def test_a_lock_held_past_the_wait_is_reported_busy(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "switch.lock"
            with open(path, "a") as held, open(path, "a") as lock:
                fcntl.flock(held, fcntl.LOCK_EX)
                self.assertFalse(companion.wait_for_lock(lock, cap=0.3))
