"""Refresh an existing Claude credential file from the verified macOS Keychain."""
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


class CacheSyncError(Exception):
    pass


def _existing(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
        raise CacheSyncError('invalid_cache_file')
    return True


def synchronize(email, *, path=None, read=None, resolve=None, lock=None):
    if read is None and sys.platform != 'darwin':
        return False
    path = Path(path) if path is not None else Path.home() / '.claude' / '.credentials.json'
    if not _existing(path):
        return False
    if read is None:
        from switch_engine import macos_keychain
        read = lambda: macos_keychain.get_password('Claude Code-credentials', macos_keychain.keychain_account_name())
    raw = read()
    if not raw:
        raise CacheSyncError('keychain_unavailable')
    current = json.loads(raw)
    try:
        cached = json.loads(path.read_text())
    except json.JSONDecodeError:
        cached = None
    if current == cached:
        return False
    token = current.get('claudeAiOauth', {}).get('accessToken')
    if not token:
        raise CacheSyncError('oauth_missing')
    if resolve is None:
        from switch_engine.oauth import fetch_oauth_profile
        resolve = fetch_oauth_profile
    identity = resolve(token)
    if not identity or str(identity.get('email', '')).casefold() != email.casefold():
        raise CacheSyncError('credential_identity_mismatch')
    if lock is None:
        from switch_engine.claude_locks import claude_credentials_lock
        # The coordinator switches the default login, regardless of its caller's shell.
        configured = os.environ.get('CLAUDE_CONFIG_DIR')
        if configured and Path(configured).expanduser() != path.parent:
            raise CacheSyncError('credential_lock_scope_mismatch')
        lock = lambda: claude_credentials_lock(timeout=10)
    # No network under Claude's refresh locks. Re-read after locking so a concurrent
    # token rotation cannot be overwritten with the generation just verified.
    with lock():
        if read() != raw:
            raise CacheSyncError('credentials_changed')
        if not _existing(path):
            return False
        fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.credential-sync-')
        try:
            with os.fdopen(fd, 'w') as stream:
                stream.write(raw)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return True
