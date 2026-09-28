"""Chrome native-messaging to local Unix-socket transport."""

from __future__ import annotations

import errno
import json
import os
import selectors
import socket
import stat
import struct
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO, Callable


MAX_NATIVE_MESSAGE = 1024 * 1024
MAX_CLIENT_MESSAGE = 64 * 1024
CLIENT_REQUEST_TIMEOUT = 45.0
MAX_ID_LENGTH = 256
MAX_EMAIL_LENGTH = 320
MAX_ACTION_LENGTH = 128


class ProtocolError(Exception):
    """Raised when a peer violates a bounded wire protocol."""


class _NativeFrameParser:
    def __init__(self) -> None:
        self.buffer = bytearray()
        self.expected: int | None = None

    def feed(self, chunk: bytes) -> list[dict]:
        self.buffer.extend(chunk)
        messages: list[dict] = []
        while True:
            if self.expected is None:
                if len(self.buffer) < 4:
                    break
                self.expected = struct.unpack("<I", self.buffer[:4])[0]
                del self.buffer[:4]
                if self.expected > MAX_NATIVE_MESSAGE:
                    raise ProtocolError("native message too large")
            if len(self.buffer) < self.expected:
                break
            payload = bytes(self.buffer[: self.expected])
            del self.buffer[: self.expected]
            self.expected = None
            try:
                message = json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ProtocolError("invalid native message") from exc
            if not isinstance(message, dict):
                raise ProtocolError("native message must be an object")
            messages.append(message)
        return messages


def _write_native(stream: BinaryIO, message: dict) -> None:
    payload = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )
    if len(payload) > MAX_NATIVE_MESSAGE:
        raise ProtocolError("native response too large")
    stream.write(struct.pack("<I", len(payload)) + payload)
    stream.flush()


def _bounded_string(value: object, maximum: int) -> bool:
    return (
        isinstance(value, str)
        and 0 < len(value) <= maximum
        and "\n" not in value
        and "\r" not in value
    )


def _validate_client_request(message: object) -> tuple[str, str, str | None] | None:
    if not isinstance(message, dict):
        return None
    request_id = message.get("id")
    command = message.get("command")
    if not _bounded_string(request_id, MAX_ID_LENGTH):
        return None
    if command not in ("switch", "status"):
        return None
    if command == "switch":
        email = message.get("email")
        if not _bounded_string(email, MAX_EMAIL_LENGTH):
            return None
        if set(message) != {"id", "command", "email"}:
            return None
        return request_id, command, email
    if set(message) != {"id", "command"}:
        return None
    return request_id, command, None


@dataclass
class _Client:
    sock: socket.socket
    input: bytearray = field(default_factory=bytearray)
    output: bytearray = field(default_factory=bytearray)
    closing: bool = False


def _encode_client_result(result: dict) -> bytes:
    payload = json.dumps(result, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )
    if len(payload) + 1 > MAX_CLIENT_MESSAGE:
        payload = b'{"ok":false,"error":"response_too_large"}'
    return payload + b"\n"


def _prepare_listener(socket_path: str) -> socket.socket:
    path = Path(socket_path)
    parent = path.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(parent, 0o700)

    if os.path.lexists(path):
        info = os.lstat(path)
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid():
            raise RuntimeError("socket path is not an owned socket")
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.settimeout(0.2)
        try:
            probe.connect(socket_path)
        except OSError as exc:
            if exc.errno not in (errno.ECONNREFUSED, errno.ENOENT):
                raise RuntimeError("cannot verify existing socket") from exc
            if os.path.lexists(path):
                os.unlink(path)
        else:
            raise RuntimeError("native bridge is already running")
        finally:
            probe.close()

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(socket_path)
        os.chmod(socket_path, 0o600)
        listener.listen()
        listener.setblocking(False)
    except Exception:
        listener.close()
        raise
    return listener


def run_host(
    origin: str,
    allowed_origin: str,
    socket_path: str,
    handle_local: Callable[[dict], dict],
) -> int:
    """Run the native host until Chrome closes stdin.

    Returns a process-style exit code. Callers intended as executables should use
    ``raise SystemExit(run_host(...))``.
    """

    if origin != allowed_origin:
        print("native bridge: disallowed origin", file=sys.stderr)
        return 1

    try:
        listener = _prepare_listener(socket_path)
    except (OSError, RuntimeError):
        print("native bridge: unavailable socket", file=sys.stderr)
        return 1

    selector = selectors.DefaultSelector()
    clients: dict[socket.socket, _Client] = {}
    pending: dict[str, tuple[_Client, float]] = {}
    parser = _NativeFrameParser()
    stdin_fd = sys.stdin.buffer.fileno()

    def close_client(client: _Client) -> None:
        clients.pop(client.sock, None)
        for request_id, (owner, _) in list(pending.items()):
            if owner is client:
                del pending[request_id]
        try:
            selector.unregister(client.sock)
        except (KeyError, ValueError):
            pass
        client.sock.close()

    def queue_result(client: _Client, result: dict, close_after: bool = False) -> None:
        client.output.extend(_encode_client_result(result))
        client.closing = client.closing or close_after
        try:
            selector.modify(client.sock, selectors.EVENT_READ | selectors.EVENT_WRITE, client)
        except (KeyError, ValueError):
            pass

    def handle_browser_message(message: dict) -> None:
        message_type = message.get("type")
        request_id = message.get("id")
        if message_type == "result" and _bounded_string(request_id, MAX_ID_LENGTH):
            entry = pending.pop(request_id, None)
            if entry is None:
                return
            client, _ = entry
            result = message.get("result")
            if not isinstance(result, dict):
                result = {"ok": False, "error": "invalid_browser_result"}
            queue_result(client, result)
            return
        if (
            message_type == "request"
            and _bounded_string(request_id, MAX_ID_LENGTH)
            and _bounded_string(message.get("action"), MAX_ACTION_LENGTH)
        ):
            try:
                result = handle_local(message)
                if not isinstance(result, dict):
                    raise TypeError("local handler did not return an object")
            except Exception:
                result = {"ok": False, "error": "local_handler_error"}
            _write_native(
                sys.stdout.buffer,
                {"type": "response", "id": request_id, "result": result},
            )

    try:
        selector.register(stdin_fd, selectors.EVENT_READ, "stdin")
        selector.register(listener, selectors.EVENT_READ, "listener")
        while True:
            now = time.monotonic()
            nearest = min((deadline for _, deadline in pending.values()), default=now + 30.0)
            timeout = max(0.0, min(30.0, nearest - now))
            events = selector.select(timeout)
            for key, mask in events:
                if key.data == "stdin":
                    chunk = os.read(stdin_fd, 65536)
                    if not chunk:
                        return 0
                    try:
                        for message in parser.feed(chunk):
                            handle_browser_message(message)
                    except ProtocolError:
                        return 1
                elif key.data == "listener":
                    while True:
                        try:
                            client_socket, _ = listener.accept()
                        except BlockingIOError:
                            break
                        client_socket.setblocking(False)
                        client = _Client(client_socket)
                        clients[client_socket] = client
                        selector.register(client_socket, selectors.EVENT_READ, client)
                else:
                    client = key.data
                    if mask & selectors.EVENT_READ:
                        try:
                            chunk = client.sock.recv(65536)
                        except BlockingIOError:
                            chunk = None
                        except OSError:
                            close_client(client)
                            continue
                        if chunk == b"":
                            close_client(client)
                            continue
                        if chunk:
                            client.input.extend(chunk)
                            if len(client.input) > MAX_CLIENT_MESSAGE and b"\n" not in client.input:
                                queue_result(
                                    client,
                                    {"ok": False, "error": "request_too_large"},
                                    close_after=True,
                                )
                            else:
                                while b"\n" in client.input and not client.closing:
                                    line, _, remainder = client.input.partition(b"\n")
                                    client.input = bytearray(remainder)
                                    if len(line) + 1 > MAX_CLIENT_MESSAGE:
                                        queue_result(
                                            client,
                                            {"ok": False, "error": "request_too_large"},
                                            close_after=True,
                                        )
                                        break
                                    try:
                                        message = json.loads(line.decode("utf-8"))
                                    except (UnicodeDecodeError, json.JSONDecodeError):
                                        message = None
                                    validated = _validate_client_request(message)
                                    if validated is None:
                                        queue_result(
                                            client,
                                            {"ok": False, "error": "invalid_request"},
                                        )
                                        continue
                                    request_id, command, email = validated
                                    if request_id in pending:
                                        queue_result(
                                            client,
                                            {"ok": False, "error": "duplicate_id"},
                                        )
                                        continue
                                    forwarded = {
                                        "type": "command",
                                        "id": request_id,
                                        "command": command,
                                    }
                                    if email is not None:
                                        forwarded["email"] = email
                                    _write_native(sys.stdout.buffer, forwarded)
                                    pending[request_id] = (
                                        client,
                                        time.monotonic() + CLIENT_REQUEST_TIMEOUT,
                                    )
                    if client.sock not in clients:
                        continue
                    if mask & selectors.EVENT_WRITE and client.output:
                        try:
                            sent = client.sock.send(client.output)
                        except BlockingIOError:
                            sent = 0
                        except OSError:
                            close_client(client)
                            continue
                        del client.output[:sent]
                        if not client.output:
                            if client.closing:
                                close_client(client)
                            else:
                                selector.modify(client.sock, selectors.EVENT_READ, client)

            now = time.monotonic()
            for request_id, (client, deadline) in list(pending.items()):
                if deadline <= now:
                    del pending[request_id]
                    if client.sock in clients:
                        queue_result(client, {"ok": False, "error": "browser_timeout"})
    finally:
        for client in list(clients.values()):
            close_client(client)
        try:
            selector.unregister(listener)
        except (KeyError, ValueError):
            pass
        listener.close()
        selector.close()
        try:
            info = os.lstat(socket_path)
            if stat.S_ISSOCK(info.st_mode) and info.st_uid == os.geteuid():
                os.unlink(socket_path)
        except FileNotFoundError:
            pass


def send_request(
    socket_path: str,
    command: str,
    email: str | None = None,
    timeout: float = 50,
) -> dict:
    """Send one switch/status request to a running host and return its result."""

    request_id = os.urandom(16).hex()
    message: dict[str, str] = {"id": request_id, "command": command}
    if email is not None:
        message["email"] = email
    if _validate_client_request(message) is None:
        raise ValueError("invalid native bridge request")
    payload = json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n"
    response = bytearray()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(timeout)
            client.connect(socket_path)
            client.sendall(payload)
            while b"\n" not in response:
                chunk = client.recv(65536)
                if not chunk:
                    return {"ok": False, "error": "host_disconnected"}
                response.extend(chunk)
                if len(response) > MAX_CLIENT_MESSAGE:
                    return {"ok": False, "error": "response_too_large"}
    except (TimeoutError, socket.timeout):
        return {"ok": False, "error": "host_timeout"}
    except OSError:
        return {"ok": False, "error": "host_unavailable"}
    line = bytes(response).split(b"\n", 1)[0]
    try:
        result = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {"ok": False, "error": "invalid_host_response"}
    if not isinstance(result, dict):
        return {"ok": False, "error": "invalid_host_response"}
    return result
