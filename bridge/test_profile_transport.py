import os
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from bridge import profile_transport


class ProfileTransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.base = self.root / "bridge"
        self.base.mkdir(mode=0o700)
        self.listeners = []

    def tearDown(self):
        for listener in self.listeners:
            listener.close()
        self.temporary.cleanup()

    def bind_socket(self, path):
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        self.listeners.append(listener)
        return path

    def test_native_socket_uses_distinct_positive_pids(self):
        self.assertEqual(
            profile_transport.native_socket(self.base, 101),
            self.base / "browsers" / "101.sock",
        )
        self.assertNotEqual(
            profile_transport.native_socket(self.base, 101),
            profile_transport.native_socket(self.base, 202),
        )
        with mock.patch.object(profile_transport.os, "getpid", return_value=303):
            self.assertEqual(
                profile_transport.native_socket(self.base),
                self.base / "browsers" / "303.sock",
            )
        for invalid in (0, -1, True, 1.5, "1"):
            with self.subTest(pid=invalid), self.assertRaises(ValueError):
                profile_transport.native_socket(self.base, invalid)

    def test_two_profiles_are_contacted_concurrently_in_numeric_order(self):
        self.bind_socket(self.base / "browsers" / "10.sock")
        self.bind_socket(self.base / "browsers" / "2.sock")
        barrier = threading.Barrier(2, timeout=2)

        def sender(path, command, email, timeout):
            barrier.wait()
            return {"ok": True, "pid": int(Path(path).stem)}

        self.assertEqual(
            profile_transport.requests(self.base, "status", sender=sender),
            [
                {"connection": "2.sock", "result": {"ok": True, "pid": 2}},
                {"connection": "10.sock", "result": {"ok": True, "pid": 10}},
            ],
        )

    def test_legacy_socket_precedes_profile_sockets(self):
        self.bind_socket(self.base / "browser.sock")
        self.bind_socket(self.base / "browsers" / "7.sock")

        calls = []

        def sender(path, command, email, timeout):
            calls.append((Path(path).name, command, email, timeout))
            return {"ok": True}

        results = profile_transport.requests(
            self.base, "switch", "person@example.com", sender
        )
        self.assertEqual(
            [item["connection"] for item in results], ["browser.sock", "7.sock"]
        )
        self.assertCountEqual(
            calls,
            [
                ("browser.sock", "switch", "person@example.com", 170),
                ("7.sock", "switch", "person@example.com", 170),
            ],
        )

    def test_unsafe_directory_and_non_socket_entries_are_ignored(self):
        outside = self.root / "outside"
        outside.mkdir(mode=0o700)
        self.bind_socket(outside / "22.sock")
        (self.base / "browsers").symlink_to(outside, target_is_directory=True)
        self.assertEqual(profile_transport.connection_paths(self.base), [])

        (self.base / "browsers").unlink()
        browsers = self.base / "browsers"
        browsers.mkdir(mode=0o700)
        (browsers / "11.sock").write_text("not a socket")
        real = self.bind_socket(browsers / "12.sock")
        (browsers / "13.sock").symlink_to(real)
        self.assertEqual(profile_transport.connection_paths(self.base), [real])

    def test_unsafe_or_wrong_owner_base_fails_closed(self):
        self.bind_socket(self.base / "browser.sock")
        self.base.chmod(0o777)
        self.assertEqual(profile_transport.connection_paths(self.base), [])
        self.base.chmod(0o700)
        with mock.patch.object(
            profile_transport.os, "geteuid", return_value=os.geteuid() + 1
        ):
            self.assertEqual(profile_transport.connection_paths(self.base), [])

    def test_partial_connection_failures_are_bounded_and_ordered(self):
        self.bind_socket(self.base / "browsers" / "1.sock")
        self.bind_socket(self.base / "browsers" / "2.sock")
        self.bind_socket(self.base / "browsers" / "3.sock")

        def sender(path, command, email, timeout):
            pid = int(Path(path).stem)
            if pid == 1:
                time.sleep(0.02)
                raise OSError("private path details")
            if pid == 2:
                raise TimeoutError("private request details")
            return {"ok": True, "pid": pid}

        self.assertEqual(
            profile_transport.requests(self.base, "status", sender=sender),
            [
                {
                    "connection": "1.sock",
                    "result": {"ok": False, "error": "host_unavailable"},
                },
                {
                    "connection": "2.sock",
                    "result": {"ok": False, "error": "host_unavailable"},
                },
                {"connection": "3.sock", "result": {"ok": True, "pid": 3}},
            ],
        )

    def test_absent_base_or_sockets_returns_empty(self):
        self.assertEqual(profile_transport.connection_paths(self.root / "missing"), [])
        self.assertEqual(profile_transport.requests(self.base, "status"), [])


if __name__ == "__main__":
    unittest.main()
