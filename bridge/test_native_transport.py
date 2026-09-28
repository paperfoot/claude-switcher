import json
import os
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

from bridge import native_transport


ROOT = Path(__file__).resolve().parents[1]
ORIGIN = "chrome-extension://allowed-extension/"


def _native_frame(message):
    payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
    return struct.pack("<I", len(payload)) + payload


def _read_exact(stream, length, timeout=2.0):
    result = bytearray()
    while len(result) < length:
        readable, _, _ = select.select([stream], [], [], timeout)
        if not readable:
            raise TimeoutError("native host did not produce a frame")
        chunk = os.read(stream.fileno(), length - len(result))
        if not chunk:
            raise EOFError("native host closed stdout")
        result.extend(chunk)
    return bytes(result)


def _read_native(stream, timeout=2.0):
    length = struct.unpack("<I", _read_exact(stream, 4, timeout))[0]
    return json.loads(_read_exact(stream, length, timeout).decode("utf-8"))


def _read_line(sock, timeout=2.0):
    sock.settimeout(timeout)
    data = bytearray()
    while b"\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError("socket closed before a response")
        data.extend(chunk)
    return json.loads(bytes(data).split(b"\n", 1)[0].decode("utf-8"))


class HostProcess:
    def __init__(self, socket_path, origin=ORIGIN, timeout=None, wait_ready=True):
        setup_timeout = (
            f"nt.CLIENT_REQUEST_TIMEOUT = {float(timeout)!r}\n" if timeout is not None else ""
        )
        script = f"""
import os
import sys
from bridge import native_transport as nt
{setup_timeout}original_prepare = nt._prepare_listener
def prepare(path):
    listener = original_prepare(path)
    os.write(2, b'READY\\n')
    return listener
nt._prepare_listener = prepare
def handle(message):
    return {{'ok': True, 'action': message['action']}}
raise SystemExit(nt.run_host(sys.argv[1], sys.argv[2], sys.argv[3], handle))
"""
        self.proc = subprocess.Popen(
            [sys.executable, "-u", "-c", script, origin, ORIGIN, str(socket_path)],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        if wait_ready:
            ready = self.proc.stderr.readline()
            if ready != b"READY\n":
                raise RuntimeError(f"host failed to start: {ready!r}")

    def write_native(self, message, fragments=None):
        frame = _native_frame(message)
        if fragments is None:
            self.proc.stdin.write(frame)
        else:
            offset = 0
            for size in fragments:
                self.proc.stdin.write(frame[offset : offset + size])
                self.proc.stdin.flush()
                offset += size
            self.proc.stdin.write(frame[offset:])
        self.proc.stdin.flush()

    def close(self):
        if self.proc.poll() is None:
            if not self.proc.stdin.closed:
                self.proc.stdin.close()
            self.proc.wait(timeout=2)
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            if not stream.closed:
                stream.close()


class NativeTransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.socket_path = Path(self.temporary.name) / "private" / "bridge.sock"
        self.hosts = []

    def tearDown(self):
        for host in self.hosts:
            host.close()
        self.temporary.cleanup()

    def start_host(self, **kwargs):
        host = HostProcess(self.socket_path, **kwargs)
        self.hosts.append(host)
        return host

    def connect(self):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(str(self.socket_path))
        return client

    def test_fragmented_and_multiple_native_frames(self):
        host = self.start_host()
        first = {"type": "request", "id": "local-1", "action": "vault_get"}
        host.write_native(first, fragments=[1, 2, 1, 3, 2])
        self.assertEqual(
            _read_native(host.proc.stdout),
            {
                "type": "response",
                "id": "local-1",
                "result": {"ok": True, "action": "vault_get"},
            },
        )

        combined = _native_frame(
            {"type": "request", "id": "local-2", "action": "vault_set"}
        ) + _native_frame(
            {"type": "request", "id": "local-3", "action": "vault_delete"}
        )
        host.proc.stdin.write(combined)
        host.proc.stdin.flush()
        self.assertEqual(_read_native(host.proc.stdout)["id"], "local-2")
        self.assertEqual(_read_native(host.proc.stdout)["id"], "local-3")

    def test_allowed_origin_is_exact(self):
        host = HostProcess(
            self.socket_path,
            origin="chrome-extension://wrong-extension/",
            wait_ready=False,
        )
        self.hosts.append(host)
        self.assertEqual(host.proc.wait(timeout=2), 1)
        self.assertIn(b"disallowed origin", host.proc.stderr.read())
        self.assertFalse(self.socket_path.exists())

    def test_only_known_commands_are_forwarded(self):
        host = self.start_host()
        with self.connect() as client:
            client.sendall(b'{"id":"bad","command":"delete"}\n')
            self.assertEqual(_read_line(client), {"ok": False, "error": "invalid_request"})
            readable, _, _ = select.select([host.proc.stdout], [], [], 0.1)
            self.assertEqual(readable, [])

            client.sendall(b'{"id":"status-1","command":"status"}\n')
            self.assertEqual(
                _read_native(host.proc.stdout),
                {"type": "command", "id": "status-1", "command": "status"},
            )
            host.write_native(
                {"type": "result", "id": "status-1", "result": {"ok": True}}
            )
            self.assertEqual(_read_line(client), {"ok": True})

    def test_mismatched_reply_id_does_not_consume_request(self):
        host = self.start_host()
        with self.connect() as client:
            client.sendall(
                b'{"id":"switch-1","command":"switch","email":"one@example.com"}\n'
            )
            self.assertEqual(_read_native(host.proc.stdout)["id"], "switch-1")
            host.write_native(
                {"type": "result", "id": "someone-else", "result": {"ok": True}}
            )
            client.settimeout(0.1)
            with self.assertRaises(socket.timeout):
                client.recv(1)
            host.write_native(
                {
                    "type": "result",
                    "id": "switch-1",
                    "result": {"ok": True, "active": "one@example.com"},
                }
            )
            self.assertEqual(
                _read_line(client), {"ok": True, "active": "one@example.com"}
            )

    def test_overlength_client_and_native_frames_are_rejected(self):
        host = self.start_host()
        with self.connect() as client:
            client.sendall(b"x" * (native_transport.MAX_CLIENT_MESSAGE + 1))
            self.assertEqual(
                _read_line(client), {"ok": False, "error": "request_too_large"}
            )
        readable, _, _ = select.select([host.proc.stdout], [], [], 0.1)
        self.assertEqual(readable, [])

        host.proc.stdin.write(struct.pack("<I", native_transport.MAX_NATIVE_MESSAGE + 1))
        host.proc.stdin.flush()
        self.assertEqual(host.proc.wait(timeout=2), 1)
        self.assertFalse(self.socket_path.exists())

    def test_request_timeout_is_returned_to_originating_client(self):
        host = self.start_host(timeout=0.05)
        with self.connect() as client:
            client.sendall(b'{"id":"slow","command":"status"}\n')
            self.assertEqual(_read_native(host.proc.stdout)["id"], "slow")
            self.assertEqual(
                _read_line(client, timeout=1),
                {"ok": False, "error": "browser_timeout"},
            )

    def test_live_listener_is_not_unlinked(self):
        first = self.start_host()
        second = HostProcess(self.socket_path, wait_ready=False)
        self.hosts.append(second)
        self.assertEqual(second.proc.wait(timeout=2), 1)
        self.assertTrue(self.socket_path.exists())
        self.assertIsNone(first.proc.poll())

    def test_socket_permissions_and_eof_cleanup(self):
        host = self.start_host()
        self.assertEqual(self.socket_path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.socket_path.stat().st_mode & 0o777, 0o600)
        host.proc.stdin.close()
        self.assertEqual(host.proc.wait(timeout=2), 0)
        self.assertFalse(self.socket_path.exists())

    def test_send_request_helper(self):
        self.socket_path.parent.mkdir(mode=0o700)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self.socket_path))
        listener.listen(1)
        captured = []

        def serve():
            connection, _ = listener.accept()
            with connection:
                request = _read_line(connection)
                captured.append(request)
                connection.sendall(b'{"ok":true,"state":"ready"}\n')
            listener.close()

        server = threading.Thread(target=serve)
        server.start()
        result = native_transport.send_request(str(self.socket_path), "status", timeout=1)
        server.join(timeout=2)
        self.assertFalse(server.is_alive())
        self.assertEqual(result, {"ok": True, "state": "ready"})
        self.assertEqual(captured[0]["command"], "status")
        self.assertIsInstance(captured[0]["id"], str)


if __name__ == "__main__":
    unittest.main()
