import fcntl
import io
import json
import os
import sys
import tempfile
import types
import unittest
from contextlib import ExitStack, redirect_stdout
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

        expected = {"ok": True, "email": TARGET_EMAIL, "selectedAt": 1234.5}
        self.assertEqual(first, expected)
        self.assertEqual(ready, {"ok": True})
        self.assertTrue(json.loads(self.state.read_text())["browserReady"])
        # A second profile, or one that was closed during the switch, still sees it.
        self.assertEqual(second, expected)
        # 0.7.x companions keep their one-shot behaviour.
        self.assertEqual(legacy, {"ok": True, "email": None})

    def test_selection_includes_code_switches_that_some_profiles_missed(self):
        state = {"ok": False, "partial": True, "error": "code_only_after_web_failure",
                 "browserError": "host_timeout", "codeEmail": TARGET_EMAIL,
                 "browserReady": False, "selectedAt": 99.0}
        self.base.mkdir(parents=True)
        self.state.write_text(json.dumps(state))
        self.code_identity.return_value = TARGET_EMAIL
        with mock.patch.object(companion, "configured_emails", return_value={TARGET_EMAIL}):
            self.assertEqual(self.per_profile_selection(),
                             {"ok": True, "email": TARGET_EMAIL, "selectedAt": 99.0})
            ready = self.handle_native(
                {"action": "browser_ready", "email": TARGET_EMAIL, "selectedAt": 99.0})
        self.assertEqual(ready, {"ok": True})
        self.assert_saved(state)

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
        with mock.patch.dict(sys.modules, {'claude_swap': None}):
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
        with mock.patch.dict(sys.modules, {"claude_swap": None}):
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
        # The old identity read and the forward cswap both leave the restore reserve.
        self.assertEqual(self.identity_timeouts[0], min(15, 100 - reserve))
        self.assertEqual(self.backend_calls, [(("switch", TARGET_EMAIL, "--json"), 100 - 1 - reserve)])
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
        self.assertEqual(forward, 60)
        self.assertEqual(restore, 120 - 1 - 60)
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
        fake_swap = types.ModuleType("claude_swap")
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
                    mock.patch.dict(sys.modules, {"claude_swap": fake_swap}),
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
