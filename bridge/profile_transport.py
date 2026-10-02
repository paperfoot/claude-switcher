"""Discover and contact native hosts for individual Chrome profiles."""

from __future__ import annotations

import os
import stat
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable

try:
    from . import native_transport
except ImportError:
    import native_transport


def native_socket(base: Path, pid: int | None = None) -> Path:
    """Return the per-process native-host socket path."""

    process_id = os.getpid() if pid is None else pid
    if (
        isinstance(process_id, bool)
        or not isinstance(process_id, int)
        or process_id <= 0
    ):
        raise ValueError("pid must be a positive integer")
    return Path(base) / "browsers" / f"{process_id}.sock"


def _safe_directory(path: Path) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISDIR(info.st_mode)
        and info.st_uid == os.geteuid()
        and not info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    )


def _owned_socket(path: Path) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISSOCK(info.st_mode) and info.st_uid == os.geteuid()


def connection_paths(base: Path) -> list[Path]:
    """Return safe native-host sockets in stable connection order."""

    root = Path(base)
    if not _safe_directory(root):
        return []

    paths: list[Path] = []
    legacy = root / "browser.sock"
    if _owned_socket(legacy):
        paths.append(legacy)

    browser_dir = root / "browsers"
    if not _safe_directory(browser_dir):
        return paths

    try:
        entries = list(browser_dir.iterdir())
    except OSError:
        return paths

    numbered: list[tuple[int, Path]] = []
    for path in entries:
        if path.suffix != ".sock":
            continue
        stem = path.stem
        if not stem.isascii() or not stem.isdigit():
            continue
        process_id = int(stem)
        if process_id <= 0 or not _owned_socket(path):
            continue
        numbered.append((process_id, path))
    paths.extend(path for _, path in sorted(numbered, key=lambda item: item[0]))
    return paths


def requests(
    base: Path,
    command: str,
    email: str | None = None,
    sender: Callable[..., dict] | None = None,
) -> list[dict]:
    """Send a command to each discovered native host concurrently."""

    paths = connection_paths(base)
    if not paths:
        return []
    send = native_transport.send_request if sender is None else sender

    def call(path: Path) -> dict:
        try:
            result = send(str(path), command, email, timeout=170)
        except (OSError, TimeoutError):
            result = {"ok": False, "error": "host_unavailable"}
        return {"connection": path.name, "result": result}

    with ThreadPoolExecutor(max_workers=min(8, len(paths))) as executor:
        return list(executor.map(call, paths))
