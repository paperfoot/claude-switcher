"""Verified account changes across connected Chrome profiles."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

try:
    from . import native_transport, profile_transport, event_log, deadlines
except ImportError:
    import native_transport
    import profile_transport
    import event_log
    import deadlines


def _send(path, command, email, sender, **options):
    try:
        result = (sender or native_transport.send_request)(str(path), command, email, **options)
        return result if isinstance(result, dict) else {'ok': False, 'error': 'invalid_browser_result'}
    except (OSError, TimeoutError, ValueError):
        return {'ok': False, 'error': 'host_unavailable'}


def _status(path, deadline, sender):
    try:
        timeout = deadline.timeout(deadlines.STATUS_TIMEOUT)
    except deadlines.DeadlineExceeded:
        return {'ok': False, 'error': 'browser_timeout'}
    return _send(path, 'status', None, sender, timeout=timeout)


def _switch(path, email, deadline, sender, restores, selected_at=None):
    """Switch one profile, replying while `restores` changed profiles can still be restored.

    `selected_at` stamps a deliberate selection; the profile records it so it never
    re-applies an older one. Rollbacks carry none. Returns None without contacting
    the profile when too little time is left.
    """
    reserve = restores * deadlines.PROFILE_RESTORE_RESERVE
    if deadline.remaining(reserve) < deadlines.PROFILE_SWITCH_MINIMUM:
        return None
    options = {'deadline': deadline.unix_ms(reserve)}
    if selected_at is not None:
        options['selected_at'] = selected_at
    return _send(path, 'switch', email, sender, **options)


def _connections(base, deadline, exclude=None, sender=None):
    paths = [path for path in profile_transport.connection_paths(base)
             if exclude is None or path != Path(exclude)]
    if not paths:
        return []
    # One unresponsive profile costs one status timeout, not one per profile.
    with ThreadPoolExecutor(max_workers=min(8, len(paths))) as executor:
        states = list(executor.map(lambda path: _status(path, deadline, sender), paths))
    rows = []
    for path, state in zip(paths, states):
        # A killed Chrome/native process can leave a socket behind.
        if state.get('error') == 'host_unavailable':
            continue
        if state.get('ok') is False:
            event_log.emit(base, 'browser_error', error=state.get('error', 'web_unavailable'), failureStep='connect')
        rows.append((path, state))
    return rows


def _summary(rows):
    profiles = [dict(connection=path.name, **{key: state[key] for key in
                ('ok', 'email', 'error', 'busy', 'version', 'lastHealthCheckAt', 'lastSessionSavedAt') if key in state}) for path, state in rows]
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


def status(base, sender=None, deadline=None):
    deadline = deadline or deadlines.Deadline(deadlines.STATUS_BUDGET)
    return _summary(_connections(base, deadline, sender=sender))


def _restore(changed, deadline, sender):
    """Return the given profiles to their previous logins, newest change first."""
    restored = True
    for index, (path, old) in enumerate(reversed(changed)):
        current = _status(path, deadline, sender)
        if current.get('ok') and current.get('email') == old.get('email'):
            continue
        if not old.get('email'):
            restored = False
            continue
        later = len(changed) - index - 1
        rollback = _switch(path, old['email'], deadline, sender, later)
        restored &= bool(rollback and rollback.get('ok') and rollback.get('email') == old['email'])
    return restored


def switch(base, email, expected_profiles=1, exclude=None, sender=None, deadline=None, selected_at=None):
    """Restore already-changed profiles if another profile rejects the selection.

    Every reply is due early enough to restore the profiles changed so far before
    `deadline`; a profile is not contacted once that is no longer possible.
    """
    deadline = deadline or deadlines.Deadline(deadlines.MENU_BUDGET)
    rows = _connections(base, deadline, exclude=exclude, sender=sender)
    previous = _summary(rows)
    if len(rows) < expected_profiles:
        return {**previous, 'ok': False, 'error': 'browser_profiles_missing',
                'expectedProfiles': expected_profiles}
    if not rows:
        return {'ok': True, 'email': email, 'profiles': [], 'profileCount': 0}
    if not previous['ok']:
        return previous
    # A busy profile reports its last committed login while another switch runs;
    # neither its email nor a rollback target is reliable until that finishes.
    if any(state.get('busy') for _, state in rows):
        return {**previous, 'ok': False, 'error': 'switch_in_progress'}
    pending = [path for path, before in rows if before.get('email') != email]
    attempted = []
    final = []
    for path, before in rows:
        if before.get('email') == email:
            final.append((path, before))
            continue
        index = pending.index(path)
        # If a later profile fails, this one must be restored too; the last needs no slot.
        result = _switch(path, email, deadline, sender, min(index + 1, len(pending) - 1), selected_at)
        if result is None:
            result = {'ok': False, 'error': 'browser_timeout'}
        else:
            attempted.append((path, before))
            event_log.emit(base, 'browser_profile_finished', **result)
        if result.get('ok') and result.get('email') == email:
            final.append((path, {**before, **result}))
            continue
        restored = _restore(attempted, deadline, sender)
        return {**_summary([(p, _status(p, deadline, sender)) for p, _ in rows]),
                'ok': False, 'error': result.get('error', 'web_identity_mismatch') if restored else 'web_restore_failed',
                'rolledBack': restored, 'failedConnection': path.name,
                **{key: result[key] for key in ('failureStep', 'cookieName', 'probeStatus', 'httpStatus') if key in result}}
    return _summary(final)
