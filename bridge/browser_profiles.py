"""Verified account changes across connected Chrome profiles."""

from pathlib import Path

try:
    from . import native_transport, profile_transport, event_log
except ImportError:
    import native_transport
    import profile_transport
    import event_log


def _request(path, command, email=None, sender=None):
    try:
        result = (sender or native_transport.send_request)(
            str(path), command, email, timeout=170 if command == 'switch' else 25)
        return result if isinstance(result, dict) else {'ok': False, 'error': 'invalid_browser_result'}
    except (OSError, TimeoutError, ValueError):
        return {'ok': False, 'error': 'host_unavailable'}


def _connections(base, exclude=None, sender=None):
    rows = []
    for path in profile_transport.connection_paths(base):
        if exclude is not None and path == Path(exclude):
            continue
        state = _request(path, 'status', sender=sender)
        # A killed Chrome/native process can leave a socket behind.
        if state.get('error') == 'host_unavailable':
            continue
        if state.get('ok') is False:
            event_log.emit(base, 'browser_error', error=state.get('error', 'web_unavailable'), failureStep='connect')
        rows.append((path, state))
    return rows


def _summary(rows):
    profiles = [dict(connection=path.name, **{key: state[key] for key in
                ('ok', 'email', 'error', 'version', 'lastHealthCheckAt', 'lastSessionSavedAt') if key in state}) for path, state in rows]
    emails = {state.get('email') for _, state in rows}
    ok = bool(rows) and all(state.get('ok') for _, state in rows)
    result = {'ok': ok, 'email': next(iter(emails)) if ok and len(emails) == 1 else None,
              'accounts': sorted({email for _, state in rows for email in state.get('accounts', [])}),
              'profileCount': len(rows), 'profiles': profiles}
    if not rows:
        result['error'] = 'browser_missing'
    elif not ok:
        result['error'] = 'web_unavailable'
    return result


def status(base, sender=None):
    return _summary(_connections(base, sender=sender))


def switch(base, email, expected_profiles=1, exclude=None, sender=None):
    """Restore already-changed profiles if another profile rejects the selection."""
    rows = _connections(base, exclude=exclude, sender=sender)
    previous = _summary(rows)
    if len(rows) < expected_profiles:
        return {**previous, 'ok': False, 'error': 'browser_profiles_missing',
                'expectedProfiles': expected_profiles}
    if not rows:
        return {'ok': True, 'email': email, 'profiles': [], 'profileCount': 0}
    if not previous['ok']:
        return previous
    attempted = []
    final = []
    for path, before in rows:
        if before.get('email') == email:
            final.append((path, before))
            continue
        attempted.append((path, before))
        result = _request(path, 'switch', email, sender)
        event_log.emit(base, 'browser_profile_finished', **result)
        if result.get('ok') and result.get('email') == email:
            final.append((path, {**before, **result}))
            continue
        restored = True
        for changed_path, old in reversed(attempted):
            current = _request(changed_path, 'status', sender=sender)
            if current.get('ok') and current.get('email') == old.get('email'):
                continue
            if not old.get('email'):
                restored = False
                continue
            rollback = _request(changed_path, 'switch', old['email'], sender)
            restored &= bool(rollback.get('ok') and rollback.get('email') == old['email'])
        return {**_summary([(p, _request(p, 'status', sender=sender)) for p, _ in rows]),
                'ok': False, 'error': result.get('error', 'web_identity_mismatch') if restored else 'web_restore_failed',
                'rolledBack': restored, 'failedConnection': path.name,
                **{key: result[key] for key in ('failureStep', 'cookieName', 'probeStatus', 'httpStatus') if key in result}}
    return _summary(final)
