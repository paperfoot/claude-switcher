"""Bounded local diagnostics. Only predefined codes and scalar counts are persisted."""
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import stat

MAX_BYTES = 262144
EVENTS = {'switch_started', 'switch_finished', 'browser_profile_finished', 'native_error', 'browser_error'}
ERRORS = set('''unknown_error switch_in_progress web_login_needed web_login_expired
web_switch_failed web_restore_failed web_identity_mismatch web_unavailable
code_switch_failed code_restore_failed code_only_after_web_failure
browser_missing browser_profiles_missing browser_timeout host_timeout host_unavailable
host_disconnected invalid_browser_result invalid_host_response response_too_large
backend_unavailable keychain_error invalid_data session_save_failed native_disconnected
native_timeout unauthorized forbidden network_error rate_limited server_error'''.split())
STEPS = {'capture_session', 'clear_cookies', 'restore_cookies', 'verify_identity', 'activate_code', 'save_session', 'connect'}
PROBES = {'verified', 'unauthorized', 'forbidden', 'network_error', 'rate_limited', 'server_error', 'invalid_response', 'identity_mismatch'}


def _record(event, fields):
    if event not in EVENTS:
        return None
    record = {'at': datetime.now(timezone.utc).isoformat(timespec='milliseconds'), 'event': event}
    for key, value in fields.items():
        if key == 'scope' and value in ('chrome', 'claude'):
            record[key] = value
        elif key in ('error', 'browserError') and isinstance(value, str):
            record[key] = value if value in ERRORS else 'unknown_error'
        elif key == 'failureStep' and isinstance(value, str) and value in STEPS:
            record[key] = value
        elif key == 'probeStatus' and isinstance(value, str) and value in PROBES:
            record[key] = value
        elif key in ('ok', 'partial', 'rolledBack', 'browserReady') and type(value) is bool:
            record[key] = value
        elif key in ('durationMs', 'profileCount', 'expectedProfiles') and type(value) is int and 0 <= value <= 2**31:
            record[key] = value
        elif key == 'httpStatus' and type(value) is int and 100 <= value <= 599:
            record[key] = value
    return record


def _open(path, flags):
    fd = os.open(path, flags | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
        os.close(fd)
        raise OSError('Invalid log file')
    os.fchmod(fd, 0o600)
    return fd


def emit(base, event, **fields):
    try:
        record = _record(event, fields)
        if record is None:
            return
        base = Path(base)
        base.mkdir(parents=True, exist_ok=True, mode=0o700)
        if base.is_symlink() or base.stat().st_uid != os.geteuid():
            return
        os.chmod(base, 0o700)
        data = (json.dumps(record, separators=(',', ':')) + '\n').encode()
        with os.fdopen(_open(base / 'events.lock', os.O_WRONLY | os.O_CREAT), 'wb') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = base / 'events.jsonl'
            with os.fdopen(_open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND), 'ab') as stream:
                if os.fstat(stream.fileno()).st_size + len(data) <= MAX_BYTES:
                    stream.write(data)
                    return
            os.replace(path, base / 'events.jsonl.1')
            with os.fdopen(_open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND), 'ab') as stream:
                stream.write(data)
    except (OSError, ValueError, TypeError):
        # Diagnostics must never prevent a credential operation or a rollback.
        return


def recent(base, limit=50):
    limit = max(1, min(200, int(limit)))
    rows = []
    for name in ('events.jsonl.1', 'events.jsonl'):
        try:
            with os.fdopen(_open(Path(base) / name, os.O_RDONLY), 'r') as stream:
                data = stream.read(MAX_BYTES + 4096)
            for line in data.splitlines():
                try:
                    row = json.loads(line)
                    clean = _record(row.get('event'), row)
                    if clean and isinstance(row.get('at'), str):
                        clean['at'] = datetime.fromisoformat(row['at']).isoformat(timespec='milliseconds')
                        rows.append(clean)
                except (ValueError, TypeError, AttributeError):
                    pass
        except (OSError, ValueError):
            pass
    return rows[-limit:]
