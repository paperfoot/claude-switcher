#!/usr/bin/env python3
"""Install Claude Switcher's local coordinated-switching components."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


REQUIRED_CSWAP_VERSION = "0.26.0"
NATIVE_HOST_NAME = "org.paperfoot.claude_switcher"
SELECTORS = (
    "CLAUDE_CONFIG_DIR",
    "CLAUDE_SECURESTORAGE_CONFIG_DIR",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_CUSTOM_HEADERS",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
)


class SetupError(Exception):
    """A safe, user-facing setup failure."""


class ProfileImportError(SetupError):
    def __init__(self, emails: list[str]):
        super().__init__("profile import failed")
        self.emails = emails


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Set up coordinated Claude Code and Chrome account switching."
    )
    parser.add_argument(
        "--app",
        default="/Applications/Claude Switcher.app",
        help="Claude Switcher application bundle",
    )
    parser.add_argument(
        "--cswap",
        default="~/.local/bin/cswap",
        help="cswap 0.26.0 executable",
    )
    parser.add_argument(
        "--claude",
        default="~/.local/bin/claude",
        help="Claude Code executable",
    )
    return parser.parse_args()


def absolute_path(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    return path


def require_executable(path: Path, label: str) -> None:
    if not path.is_file() or not os.access(path, os.X_OK):
        raise SetupError(f"{label} executable was not found.")


def clean_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for key in SELECTORS:
        environment.pop(key, None)
    return environment


def run_cswap(
    cswap: Path,
    arguments: list[str],
    *,
    environment: dict[str, str] | None = None,
    timeout: int = 120,
) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            [str(cswap), *arguments],
            env=environment or clean_environment(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SetupError("cswap could not be run.") from exc


def validate_cswap(cswap: Path) -> Path:
    require_executable(cswap, "cswap")
    result = run_cswap(cswap, ["--version"], timeout=15)
    version = result.stdout.decode("utf-8", errors="replace").strip()
    if result.returncode != 0 or version != f"cswap {REQUIRED_CSWAP_VERSION}":
        raise SetupError(f"cswap {REQUIRED_CSWAP_VERSION} is required.")

    try:
        resolved = cswap.resolve(strict=True)
    except OSError as exc:
        raise SetupError("The cswap installation could not be resolved.") from exc
    runtime = resolved.parent / "python3"
    require_executable(runtime, "cswap Python")
    return runtime


def read_profiles(config_path: Path) -> list[tuple[str, str | None]]:
    try:
        raw = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SetupError("Claude Switcher configuration could not be read.") from exc

    profiles = raw.get("profiles") if isinstance(raw, dict) else None
    if not isinstance(profiles, list):
        raise SetupError("Claude Switcher configuration has no profiles.")

    unique: list[tuple[str, str | None]] = []
    seen: set[str] = set()
    for profile in profiles:
        if not isinstance(profile, dict):
            raise SetupError("Claude Switcher configuration has an invalid profile.")
        email = profile.get("expectedEmail")
        if email is None or email == "":
            continue
        if not isinstance(email, str) or not email.strip():
            raise SetupError("Claude Switcher configuration has an invalid profile email.")
        email = email.strip()
        key = email.casefold()
        if key in seen:
            continue
        cred_dir = profile.get("credDir")
        if cred_dir == "":
            cred_dir = None
        if cred_dir is not None and not isinstance(cred_dir, str):
            raise SetupError(f"Profile {email} has an invalid credential directory.")
        unique.append((email, cred_dir))
        seen.add(key)

    if not unique:
        raise SetupError("No configured profile emails were found.")
    return unique


def listed_emails(cswap: Path, *, verification: bool = False) -> set[str]:
    result = run_cswap(cswap, ["list", "--json"])
    if result.returncode != 0:
        message = "Managed accounts could not be verified." if verification else "Managed accounts could not be read."
        raise SetupError(message)
    try:
        payload = json.loads(result.stdout)
        accounts = payload["accounts"]
        if not isinstance(accounts, list):
            raise TypeError
        emails = {
            account["email"].strip().casefold()
            for account in accounts
            if isinstance(account, dict)
            and isinstance(account.get("email"), str)
            and account["email"].strip()
        }
    except (json.JSONDecodeError, KeyError, TypeError, AttributeError) as exc:
        message = "Managed accounts could not be verified." if verification else "Managed accounts could not be read."
        raise SetupError(message) from exc
    return emails


def import_profiles(cswap: Path, profiles: list[tuple[str, str | None]]) -> list[str]:
    existing = listed_emails(cswap)
    for email, cred_dir in profiles:
        if email.casefold() in existing:
            continue
        environment = clean_environment()
        if cred_dir:
            resolved_cred_dir = str(absolute_path(cred_dir))
            environment["CLAUDE_CONFIG_DIR"] = resolved_cred_dir
            environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = resolved_cred_dir
        try:
            result = run_cswap(cswap, ["add"], environment=environment)
        except SetupError as exc:
            raise ProfileImportError([email]) from exc
        if result.returncode != 0:
            raise ProfileImportError([email])

    final = listed_emails(cswap, verification=True)
    missing = [email for email, _ in profiles if email.casefold() not in final]
    if missing:
        raise ProfileImportError(missing)
    return [email for email, _ in profiles]


def ensure_owned_directory(path: Path) -> None:
    if path.is_symlink():
        raise SetupError("A Claude Switcher support path is a symbolic link.")
    try:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not path.is_dir():
            raise OSError
        os.chmod(path, 0o700)
    except OSError as exc:
        raise SetupError("A Claude Switcher support directory could not be prepared.") from exc


def set_tree_permissions(root: Path) -> None:
    os.chmod(root, 0o700)
    for path in root.rglob("*"):
        if path.is_symlink():
            raise SetupError("Application resources may not contain symbolic links.")
        os.chmod(path, 0o700 if path.is_dir() else 0o600)


def bridge_ignore(_directory: str, names: list[str]) -> set[str]:
    return {name for name in names if name == "__pycache__" or name.startswith("test")}


def extension_ignore(_directory: str, names: list[str]) -> set[str]:
    return {
        name
        for name in names
        if name == "package.json"
        or name == "__pycache__"
        or name.startswith("test")
        or ".test." in name
    }


def replace_tree(source: Path, destination: Path, ignore) -> None:
    if not source.is_dir():
        raise SetupError("The application bundle is missing switching resources.")
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise SetupError("A Claude Switcher support path has an unexpected type.")

    stage_root = Path(tempfile.mkdtemp(prefix=f".{destination.name}-", dir=destination.parent))
    staged = stage_root / destination.name
    backup = stage_root / f"{destination.name}.previous"
    moved_existing = False
    try:
        shutil.copytree(source, staged, ignore=ignore)
        set_tree_permissions(staged)
        if destination.exists():
            os.replace(destination, backup)
            moved_existing = True
        try:
            os.replace(staged, destination)
        except Exception:
            if moved_existing and not destination.exists():
                os.replace(backup, destination)
            raise
        if moved_existing:
            shutil.rmtree(backup)
    except SetupError:
        raise
    except OSError as exc:
        raise SetupError("Switching resources could not be installed.") from exc
    finally:
        shutil.rmtree(stage_root, ignore_errors=True)


def atomic_write(path: Path, content: bytes, mode: int) -> None:
    descriptor = -1
    temporary = ""
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = -1
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = ""
        os.chmod(path, mode)
    except OSError as exc:
        raise SetupError(f"{path.name} could not be installed.") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def validate_extension_id(value: str) -> str:
    extension_id = value.strip()
    if not re.fullmatch(r"[a-p]{32}", extension_id):
        raise SetupError("The application bundle has an invalid extension ID.")
    return extension_id


def install_components(
    app: Path,
    python: Path,
    cswap: Path,
    claude: Path,
    config_path: Path,
) -> tuple[Path, Path]:
    resources = app / "Contents" / "Resources"
    source_bridge = resources / "Bridge"
    source_extension = resources / "BrowserExtension"
    try:
        extension_id = validate_extension_id((source_bridge / "extension_id.txt").read_text(encoding="utf-8"))
    except OSError as exc:
        raise SetupError("The application bundle is missing its extension ID.") from exc

    support_root = Path.home() / "Library" / "Application Support" / "Claude Switcher"
    ensure_owned_directory(support_root)
    bridge = support_root / "Bridge"
    extension = support_root / "BrowserExtension"
    replace_tree(source_bridge, bridge, bridge_ignore)
    replace_tree(source_extension, extension, extension_ignore)

    helper = bridge / "companion.py"
    if not helper.is_file():
        raise SetupError("The installed bridge helper is missing.")
    launcher = support_root / "native-host"
    launcher_text = (
        "#!/bin/sh\n"
        f"exec {shlex.quote(str(python))} {shlex.quote(str(helper))} native \"$@\"\n"
    )
    atomic_write(launcher, launcher_text.encode("utf-8"), 0o700)

    chrome_root = Path.home() / "Library" / "Application Support" / "Google" / "Chrome"
    if not chrome_root.is_dir():
        raise SetupError("Google Chrome's support directory was not found.")
    native_hosts = chrome_root / "NativeMessagingHosts"
    try:
        native_hosts.mkdir(exist_ok=True)
    except OSError as exc:
        raise SetupError("Chrome's native messaging directory could not be prepared.") from exc
    if not native_hosts.is_dir():
        raise SetupError("Chrome's native messaging path is not a directory.")
    manifest_path = native_hosts / f"{NATIVE_HOST_NAME}.json"
    manifest = {
        "name": NATIVE_HOST_NAME,
        "description": "Claude Switcher companion",
        "path": str(launcher),
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{extension_id}/"],
    }
    atomic_write(manifest_path, json_bytes(manifest), 0o600)

    ensure_owned_directory(config_path.parent)
    try:
        os.chmod(config_path, 0o600)
    except OSError as exc:
        raise SetupError("Claude Switcher configuration permissions could not be set.") from exc
    coordinated = {
        "enabled": True,
        "python": str(python),
        "helper": str(helper),
        "cswap": str(cswap),
        "claude": str(claude),
    }
    atomic_write(config_path.parent / "coordinated.json", json_bytes(coordinated), 0o600)
    return extension, launcher


def main() -> int:
    args = parse_args()
    app = absolute_path(args.app)
    cswap = absolute_path(args.cswap)
    claude = absolute_path(args.claude)
    config_path = Path.home() / ".config" / "claude-switcher" / "config.json"

    try:
        if not app.is_dir():
            raise SetupError("Claude Switcher.app was not found.")
        require_executable(claude, "Claude Code")
        python = validate_cswap(cswap)
        profiles = read_profiles(config_path)
        accounts = import_profiles(cswap, profiles)
        extension, host = install_components(app, python, cswap, claude, config_path)
    except ProfileImportError as exc:
        for email in exc.emails:
            print(f"Failed to import profile {email}.", file=sys.stderr)
        return 1
    except SetupError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except Exception:
        print("Coordinated switching setup failed.", file=sys.stderr)
        return 1

    print(
        json.dumps(
            {
                "ok": True,
                "accounts": accounts,
                "extensionPath": str(extension),
                "hostPath": str(host),
            },
            separators=(",", ":"),
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
