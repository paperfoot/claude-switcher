"""Verified account changes across connected Chrome profiles."""

from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import subprocess

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


def _switch(path, email, deadline, sender, restores, selected_at=None, open_login=False):
    """Switch one profile, replying while `restores` changed profiles can still be restored.

    `selected_at` stamps a deliberate selection; the profile records it so it never
    re-applies an older one. Rollbacks carry none. `open_login` (menu switches only) lets
    the profile open Claude's sign-in page when the saved login is dead. Returns None without contacting
    the profile when too little time is left.
    """
    reserve = restores * deadlines.PROFILE_RESTORE_RESERVE
    if deadline.remaining(reserve) < deadlines.PROFILE_SWITCH_MINIMUM:
        return None
    options = {'deadline': deadline.unix_ms(reserve)}
    if selected_at is not None:
        options['selected_at'] = selected_at
    if open_login:
        options['open_login'] = True
    result = _send(path, 'switch', email, sender, **options)
    if result.get('error') == 'invalid_request':
        # A host started before an update still runs the old validator, which refuses the
        # deadline fields. Ask in the old shape rather than fail until Chrome restarts it.
        try:
            timeout = deadline.timeout(deadlines.PROFILE_SWITCH_TIMEOUT + 2, reserve)
        except deadlines.DeadlineExceeded:
            return result
        result = _send(path, 'switch', email, sender, timeout=timeout)
    return result


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


def _expiries(rows):
    """Saved-login expiry per email across profiles, in Unix seconds.

    Every profile reads the same shared vault metadata; a differing value is an
    older read, and a renewal only moves the expiry later, so the latest wins.
    """
    merged = {}
    for _, state in rows:
        reported = state.get('expiries')
        if not isinstance(reported, dict):
            continue
        for email, seconds in reported.items():
            if (isinstance(email, str) and isinstance(seconds, (int, float))
                    and not isinstance(seconds, bool) and math.isfinite(seconds)):
                merged[email] = max(merged.get(email, seconds), seconds)
    return merged


def _summary(rows):
    profiles = [dict(connection=path.name, **{key: state[key] for key in
                ('ok', 'email', 'error', 'busy', 'version', 'lastHealthCheckAt', 'lastSessionSavedAt',
                 'lastSessionCheckedAt') if key in state}) for path, state in rows]
    emails = {state.get('email') for _, state in rows}
    ok = bool(rows) and all(state.get('ok') for _, state in rows)
    result = {'ok': ok, 'email': next(iter(emails)) if ok and len(emails) == 1 else None,
              'accounts': sorted({email for _, state in rows for email in state.get('accounts', [])}),
              'expiries': _expiries(rows),
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


def switch(base, email, expected_profiles=1, exclude=None, sender=None, deadline=None, selected_at=None,
           open_login=False):
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
            if selected_at is not None:
                # Already there, but it must still record this selection, or a later
                # reconnect would re-apply an older one. A failure here changes nothing.
                _switch(path, email, deadline, sender, 0, selected_at)
            final.append((path, before))
            continue
        index = pending.index(path)
        # If a later profile fails, this one must be restored too; the last needs no slot.
        result = _switch(path, email, deadline, sender, min(index + 1, len(pending) - 1), selected_at,
                         open_login)
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
                **{key: result[key] for key in ('failureStep', 'cookieName', 'probeStatus', 'httpStatus', 'loginOpened') if key in result}}
    return _summary(final)


APP_EXECUTABLE = '/Applications/Claude Switcher.app/Contents/MacOS/claude-switcher'


def _helper_executable():
    configured = os.environ.get('CLAUDE_SWITCHER_EXECUTABLE')
    if configured and os.path.isfile(configured) and os.access(configured, os.X_OK):
        return configured
    return APP_EXECUTABLE


def press_login(timeout, windows):
    """Ask the menu app to press Log in in the official extension's options windows.

    It runs as a child of whoever runs this helper, so macOS checks Accessibility for
    the menu app, or for the terminal when an agent switches from the command line.
    """
    executable = _helper_executable()
    if not (os.path.isfile(executable) and os.access(executable, os.X_OK)):
        return {'ok': False, 'error': 'helper_missing'}
    seconds = max(1, int(timeout))
    try:
        completed = subprocess.run(
            [executable, '--chrome-extension-login', '--timeout', str(seconds), '--windows', str(windows)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=seconds + 5)
    except subprocess.TimeoutExpired:
        return {'ok': False, 'error': 'helper_timeout'}
    except OSError:
        return {'ok': False, 'error': 'helper_missing'}
    try:
        result = json.loads(completed.stdout.strip().splitlines()[-1])
    except (IndexError, ValueError):
        return {'ok': False, 'error': 'helper_failed'}
    return result if isinstance(result, dict) else {'ok': False, 'error': 'helper_failed'}


def _official(path, command, email, deadline, sender, cap):
    try:
        timeout = deadline.timeout(cap)
    except deadlines.DeadlineExceeded:
        return {'ok': False, 'error': 'browser_timeout'}
    return _send(path, command, email, sender, timeout=timeout)


def follow_official(base, email, deadline, sender=None, press=None):
    """Sign the official Claude extension in each profile in to `email`, best effort.

    Each companion restarts the official extension, which keeps a login only for the
    account Claude.ai now uses, and opens its options page when it needs signing in.
    The menu app presses Log in there; the companion approves the consent page for
    this account. Never changes Claude.ai or Code, so it never needs a rollback.
    `extensionReady` is None when no profile had anything to do.
    """
    press = press or press_login
    rows = [(path, state) for path, state in _connections(base, deadline, sender=sender)
            if state.get('ok') and str(state.get('email') or '').lower() == email.lower()]
    if not rows:
        return {'ok': True, 'extensionReady': None, 'extension': 'no_profiles'}
    prepared = [(path, _official(path, 'official_prepare', email, deadline, sender,
                                 deadlines.OFFICIAL_PREPARE_TIMEOUT)) for path, _ in rows]
    opened = [path for path, result in prepared if result.get('ok') and result.get('state') == 'opened']
    profiles = {path: {'connection': path.name, 'state': result.get('state') or result.get('error', 'failed')}
                for path, result in prepared}
    if not opened:
        states = {result.get('state') for _, result in prepared if result.get('ok')}
        failed = [result.get('error', 'failed') for _, result in prepared if not result.get('ok')]
        result = {'ok': True, 'extensionReady': None if not failed else False,
                  'extension': 'not_installed' if states == {'not_installed'} else
                               'disabled' if 'disabled' in states else 'no_profiles',
                  'profiles': list(profiles.values())}
        if failed:
            result['extensionError'] = failed[0]
        event_log.emit(base, 'official_extension_finished', extensionReady=result['extensionReady'],
                       extension=result['extension'], profileCount=len(rows))
        return result
    budget = min(deadlines.OFFICIAL_HELPER_TIMEOUT, deadline.remaining(deadlines.OFFICIAL_FINISH_TIMEOUT + 5))
    pressed = press(budget, len(opened)) if budget >= 5 else {'ok': False, 'error': 'timeout'}
    if not isinstance(pressed, dict):
        pressed = {'ok': False, 'error': 'helper_failed'}
    finished = []
    for path in opened:
        # Always close the windows and stop approving consent, even after a failure.
        timeout = max(1.0, min(deadlines.OFFICIAL_FINISH_TIMEOUT, deadline.remaining()))
        done = _send(path, 'official_finish', None, sender, timeout=timeout)
        finished.append(done)
        profiles[path].update(authorized=bool(done.get('authorized')), consent=done.get('consent', 'none'))
    authorized = all(done.get('ok') and done.get('authorized') for done in finished)
    ready = bool(pressed.get('ok')) or authorized
    result = {'ok': True, 'extensionReady': ready, 'extension': 'opened',
              'profiles': list(profiles.values())}
    for key in ('pressed', 'signedIn', 'windows'):
        if isinstance(pressed.get(key), int) and not isinstance(pressed.get(key), bool):
            result[key] = pressed[key]
    if not ready:
        refused = any(done.get('consent') == 'refused' for done in finished)
        result['extensionError'] = 'consent_refused' if refused else str(pressed.get('error') or 'extension_not_signed_in')
    event_log.emit(base, 'official_extension_finished', extensionReady=ready, extension='opened',
                   profileCount=len(rows), opened=len(opened),
                   **({'error': result['extensionError']} if not ready else {}))
    return result
