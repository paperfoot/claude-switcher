import json
import os
import stat
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

from bridge import code_cache


EMAIL = "verified@example.test"
ACCESS_TOKEN = "synthetic-access-secret"
REFRESH_TOKEN = "synthetic-refresh-secret"


def credential_json(access_token=ACCESS_TOKEN, refresh_token=REFRESH_TOKEN):
    return json.dumps(
        {
            "claudeAiOauth": {
                "accessToken": access_token,
                "refreshToken": refresh_token,
                "expiresAt": 4_102_444_800_000,
                "scopes": ["user:profile", "user:inference"],
            },
            "extra": {"preserved": True},
        },
        separators=(",", ":"),
    )


class CodeCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.path = self.root / ".credentials.json"

    def tearDown(self):
        self.temporary.cleanup()

    def dependencies(self, raw, identity=None):
        read = mock.Mock(return_value=raw)
        resolve = mock.Mock(
            return_value={"email": EMAIL} if identity is None else identity
        )
        lock = mock.Mock(return_value=mock.MagicMock())
        return read, resolve, lock

    def assert_secret_absent(self, error, *secrets):
        message = str(error.exception)
        for secret in secrets:
            self.assertNotIn(secret, message)

    def test_absent_cache_is_not_created_or_read_from_keychain(self):
        read, resolve, lock = self.dependencies(credential_json())

        changed = code_cache.synchronize(
            EMAIL, path=self.path, read=read, resolve=resolve, lock=lock
        )

        self.assertFalse(changed)
        self.assertFalse(self.path.exists())
        read.assert_not_called()
        resolve.assert_not_called()
        lock.assert_not_called()

    def test_equal_json_does_not_write_resolve_or_lock(self):
        raw = credential_json()
        equivalent = json.dumps(json.loads(raw), indent=2)
        self.path.write_text(equivalent)
        before = self.path.stat().st_mtime_ns
        read, resolve, lock = self.dependencies(raw)

        changed = code_cache.synchronize(
            EMAIL, path=self.path, read=read, resolve=resolve, lock=lock
        )

        self.assertFalse(changed)
        self.assertEqual(self.path.read_text(), equivalent)
        self.assertEqual(self.path.stat().st_mtime_ns, before)
        read.assert_called_once_with()
        resolve.assert_not_called()
        lock.assert_not_called()

    def test_stale_cache_is_replaced_with_verified_full_json_under_lock(self):
        self.path.write_text(credential_json("old-access", "old-refresh"))
        self.path.chmod(0o644)
        old_time = 1_600_000_000
        os.utime(self.path, (old_time, old_time))
        raw = credential_json()
        events = []
        inside_lock = False

        def read():
            events.append(("read", inside_lock))
            return raw

        def resolve(token):
            events.append(("resolve", inside_lock, token))
            return {"email": EMAIL}

        @contextmanager
        def lock():
            nonlocal inside_lock
            events.append(("lock_enter", inside_lock))
            inside_lock = True
            try:
                yield
            finally:
                inside_lock = False
                events.append(("lock_exit", inside_lock))

        real_replace = os.replace

        def replace(source, destination):
            events.append(("replace", inside_lock))
            return real_replace(source, destination)

        with mock.patch.object(code_cache.os, "replace", side_effect=replace):
            changed = code_cache.synchronize(
                EMAIL, path=self.path, read=read, resolve=resolve, lock=lock
            )

        self.assertTrue(changed)
        self.assertEqual(self.path.read_text(), raw)
        self.assertEqual(json.loads(self.path.read_text()), json.loads(raw))
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertGreater(self.path.stat().st_mtime, old_time)
        self.assertEqual(
            events,
            [
                ("read", False),
                ("resolve", False, ACCESS_TOKEN),
                ("lock_enter", False),
                ("read", True),
                ("replace", True),
                ("lock_exit", False),
            ],
        )

    def test_wrong_or_unresolved_identity_refuses_without_exposing_secrets(self):
        original = credential_json("old-access", "old-refresh")
        raw = credential_json()
        for identity in ({"email": "wrong@example.test"}, None, {}):
            with self.subTest(identity=identity):
                self.path.write_text(original)
                read = mock.Mock(return_value=raw)
                resolve = mock.Mock(return_value=identity)
                lock = mock.Mock(return_value=mock.MagicMock())

                with self.assertRaises(code_cache.CacheSyncError) as error:
                    code_cache.synchronize(
                        EMAIL,
                        path=self.path,
                        read=read,
                        resolve=resolve,
                        lock=lock,
                    )

                self.assertEqual(str(error.exception), "credential_identity_mismatch")
                self.assert_secret_absent(error, ACCESS_TOKEN, REFRESH_TOKEN)
                self.assertEqual(self.path.read_text(), original)
                resolve.assert_called_once_with(ACCESS_TOKEN)
                lock.assert_not_called()

    def test_keychain_change_after_lock_refuses_to_overwrite(self):
        original = credential_json("old-access", "old-refresh")
        self.path.write_text(original)
        verified = credential_json()
        rotated_access = "synthetic-rotated-access-secret"
        rotated_refresh = "synthetic-rotated-refresh-secret"
        rotated = credential_json(rotated_access, rotated_refresh)
        inside_lock = False
        read_states = []

        def read():
            read_states.append(inside_lock)
            return verified if len(read_states) == 1 else rotated

        @contextmanager
        def lock():
            nonlocal inside_lock
            inside_lock = True
            try:
                yield
            finally:
                inside_lock = False

        with self.assertRaises(code_cache.CacheSyncError) as error:
            code_cache.synchronize(
                EMAIL,
                path=self.path,
                read=read,
                resolve=lambda token: {"email": EMAIL},
                lock=lock,
            )

        self.assertEqual(str(error.exception), "credentials_changed")
        self.assert_secret_absent(
            error, ACCESS_TOKEN, REFRESH_TOKEN, rotated_access, rotated_refresh
        )
        self.assertEqual(read_states, [False, True])
        self.assertEqual(self.path.read_text(), original)

    def test_cache_removed_while_waiting_for_lock_is_not_recreated(self):
        self.path.write_text(credential_json("old-access", "old-refresh"))
        raw = credential_json()

        @contextmanager
        def lock():
            self.path.unlink()
            yield

        changed = code_cache.synchronize(
            EMAIL,
            path=self.path,
            read=lambda: raw,
            resolve=lambda token: {"email": EMAIL},
            lock=lock,
        )

        self.assertFalse(changed)
        self.assertFalse(self.path.exists())

    def test_symlink_cache_is_refused_before_reading_secrets(self):
        target = self.root / "target.json"
        original = credential_json("target-access", "target-refresh")
        target.write_text(original)
        self.path.symlink_to(target)
        read, resolve, lock = self.dependencies(credential_json())

        with self.assertRaises(code_cache.CacheSyncError) as error:
            code_cache.synchronize(
                EMAIL, path=self.path, read=read, resolve=resolve, lock=lock
            )

        self.assertEqual(str(error.exception), "invalid_cache_file")
        self.assert_secret_absent(error, ACCESS_TOKEN, REFRESH_TOKEN)
        self.assertEqual(target.read_text(), original)
        self.assertTrue(self.path.is_symlink())
        read.assert_not_called()
        resolve.assert_not_called()
        lock.assert_not_called()

    def test_corrupt_json_is_repaired_from_verified_keychain(self):
        self.path.write_text("{corrupt-json")
        raw = credential_json()
        read, resolve, lock = self.dependencies(raw)

        changed = code_cache.synchronize(
            EMAIL, path=self.path, read=read, resolve=resolve, lock=lock
        )

        self.assertTrue(changed)
        self.assertEqual(self.path.read_text(), raw)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        resolve.assert_called_once_with(ACCESS_TOKEN)
        lock.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
