#!/usr/bin/env python3
"""Local coordinator. No web cookies or tokens are written to logs or JSON files."""
import fcntl
import functools
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
try:
    from . import deadlines, event_log
except ImportError:
    import deadlines
    import event_log

BASE = Path.home() / '.config' / 'claude-switcher'
SOCKET = BASE / 'browser.sock'
STATE = BASE / 'coordinated-state.json'
SELECTORS = ('CLAUDE_CONFIG_DIR', 'CLAUDE_SECURESTORAGE_CONFIG_DIR', 'CLAUDE_CODE_OAUTH_TOKEN',
             'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN',
             'ANTHROPIC_BASE_URL', 'ANTHROPIC_CUSTOM_HEADERS', 'CLAUDE_CODE_USE_BEDROCK',
             'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY')


def logged_switch(scope):
    def decorate(function):
        @functools.wraps(function)
        def run(*args, **kwargs):
            started = time.monotonic()
            event_log.emit(BASE, 'switch_started', scope=scope)
            try:
                result = function(*args, **kwargs)
            except Exception:
                event_log.emit(BASE, 'switch_finished', scope=scope, ok=False, error='backend_unavailable',
                               durationMs=int((time.monotonic() - started) * 1000))
                raise
            event_log.emit(BASE, 'switch_finished', scope=scope,
                           durationMs=int((time.monotonic() - started) * 1000), **result)
            return result
        return run
    return decorate


def clean_environment():
    return {k: v for k, v in os.environ.items() if k not in SELECTORS}


def configuration():
    return json.loads((BASE / 'coordinated.json').read_text())


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.switch-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def read_state():
    try:
        value = json.loads(STATE.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def restorable_web_entry(entry, now=None):
    """Skip expired cookie writes, including for older already-loaded companions."""
    now = time.time() if now is None else now
    def live(cookie):
        # Browser/device validation is not an account credential. Let Chrome keep or renew it.
        if cookie.get('name') in {'__cf_bm', '_cfuvid', 'cf_clearance', 'ion-vk', 'anthropic-device-id'}:
            return False
        expiration = cookie.get('expirationDate')
        return bool(cookie.get('session')) or expiration is None or (
            isinstance(expiration, (int, float)) and math.isfinite(expiration) and expiration > now)
    return {**entry, 'cookies': [cookie for cookie in entry.get('cookies', []) if live(cookie)]}


def configured_emails():
    data = json.loads((BASE / 'config.json').read_text())
    return {p['expectedEmail'].lower() for p in data['profiles'] if p.get('expectedEmail')}


def validate_email(email):
    if not isinstance(email, str) or email.lower() not in configured_emails():
        raise ValueError('unknown_account')
    return email.lower()


def run_backend(*args, timeout=deadlines.CSWAP_TIMEOUT):
    result = subprocess.run([configuration()['cswap'], *args], env=clean_environment(),
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError('code_switch_failed')
    return json.loads(result.stdout)


def code_identity(timeout=deadlines.IDENTITY_TIMEOUT):
    result = subprocess.run([configuration()['claude'], 'auth', 'status', '--json'], env=clean_environment(),
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    data = json.loads(result.stdout)
    if data.get('loggedIn') and data.get('authMethod') == 'claude.ai':
        return str(data.get('email', '')).lower() or None
    return None


class CodeSwitchNotStarted(Exception):
    """The deadline left no time to switch Code and still restore it; nothing changed."""


def switch_code(email, deadline=None, reserve=0.0):
    """Switch and verify Code; `reserve` is kept free for restoring the previous login."""
    deadline = deadline or deadlines.Deadline(deadlines.MENU_BUDGET)
    validate_email(email)
    try:
        timeout = deadline.timeout(deadlines.CSWAP_TIMEOUT, reserve)
    except deadlines.DeadlineExceeded:
        raise CodeSwitchNotStarted() from None
    run_backend('switch', email, '--json', timeout=timeout)
    if code_identity(timeout=deadline.timeout(deadlines.IDENTITY_TIMEOUT)) != email:
        raise RuntimeError('code_identity_mismatch')
    # cswap deliberately skips writes for an already-active account. A manual login
    # can leave its existing file cache behind even though Keychain is current.
    # The repair takes up to ~25 s (Keychain, profile lookup, Claude's lock).
    if deadline.remaining() < deadlines.CACHE_REPAIR_MINIMUM:
        event_log.emit(BASE, 'native_error', error='code_cache_sync_skipped')
        return
    refresh_code_cache(email)


def refresh_code_cache(email):
    try:
        try:
            from . import code_cache
        except ImportError:
            import code_cache
        changed = code_cache.synchronize(email)
        if changed:
            event_log.emit(BASE, 'code_cache_synced', ok=True)
        return {'ok': True, 'cacheUpdated': changed}
    except Exception:
        event_log.emit(BASE, 'native_error', error='code_cache_sync_failed')
        return {'ok': False, 'error': 'code_cache_sync_failed'}


def browser_request(command, email=None, expected_profiles=1, exclude=None, deadline=None, selected_at=None):
    try:
        from . import browser_profiles
    except ImportError:
        import browser_profiles
    if command == 'status':
        return browser_profiles.status(BASE, deadline=deadline)
    email = validate_email(email)
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(BASE / 'chrome-switch.lock', 'a') as lock:
        os.chmod(lock.name, 0o600)
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return {'ok': False, 'error': 'switch_in_progress'}
        result = browser_profiles.switch(BASE, email, expected_profiles, exclude,
                                         deadline=deadline, selected_at=selected_at)
        if result.get('error') == 'browser_profiles_missing' and result.get('profileCount') == 0 and expected_profiles == 1:
            result['error'] = 'browser_missing'
        return result


def browser_state(deadline=None):
    try:
        return browser_request('status', deadline=deadline)
    except (OSError, TimeoutError, ValueError):
        return {'ok': False, 'error': 'browser_missing', 'accounts': []}


@logged_switch('chrome')
def select_browser(email, expected_profiles=1, deadline=None):
    deadline = deadline or deadlines.Deadline(deadlines.MENU_BUDGET)
    email = validate_email(email)
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(BASE / 'switch.lock', 'a') as lock:
        os.chmod(lock.name, 0o600)
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return {'ok': False, 'error': 'switch_in_progress'}
        # A deliberate Chrome-only choice also supersedes older Code selections, so
        # a profile that reconnects later does not switch back to the Code account.
        return browser_request('switch', email, expected_profiles=expected_profiles,
                               deadline=deadline, selected_at=time.time())


@logged_switch('claude')
def select_account(email, include_browser=True, verified_browser=False, deadline=None):
    """Switch Code, then Chrome, finishing (including rollback) before `deadline`."""
    deadline = deadline or deadlines.Deadline(deadlines.MENU_BUDGET)
    email = validate_email(email)
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(BASE / 'switch.lock', 'a') as lock:
        os.chmod(BASE / 'switch.lock', 0o600)
        # Serialise selections across the menu and the extension; fail promptly on contention.
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return {'ok': False, 'error': 'switch_in_progress'}
        # Profiles record this stamp when they switch, so a reconnect never re-applies
        # it and a profile that missed it can catch up later.
        selected_at = time.time()
        try:
            identity_timeout = deadline.timeout(deadlines.IDENTITY_TIMEOUT, deadlines.CODE_RESTORE_RESERVE)
        except deadlines.DeadlineExceeded:
            return {'ok': False, 'error': 'code_switch_failed'}
        old = code_identity(timeout=identity_timeout)
        try:
            switch_code(email, deadline, reserve=deadlines.CODE_RESTORE_RESERVE)
        except CodeSwitchNotStarted:
            return {'ok': False, 'error': 'code_switch_failed'}
        except Exception:
            # cswap rolls back failed writes; verify/repair if activation failed after a write.
            if old and old != email:
                try:
                    switch_code(old, deadline)
                except Exception:
                    return {'ok': False, 'error': 'code_restore_failed'}
            return {'ok': False, 'error': 'code_switch_failed'}
        web = {'ok': True, 'email': email} if verified_browser else {'ok': False, 'error': 'browser_missing'}
        if include_browser:
            try:
                if verified_browser:
                    web = browser_request('switch', email, expected_profiles=0, exclude=SOCKET,
                                          deadline=deadline, selected_at=selected_at)
                else:
                    web = browser_request('switch', email, deadline=deadline, selected_at=selected_at)
            except FileNotFoundError: pass
            except (OSError, TimeoutError, ValueError):
                web = {'ok': False, 'error': 'web_unavailable'}
            if web.get('ok') and web.get('email') != email:
                web = {'ok': False, 'error': 'web_identity_mismatch'}
            # A browser failure must not undo a verified Code login used by new processes.
            # Profiles that did not switch catch up from this state when they reconnect.
            if not web.get('ok') and web.get('error') != 'browser_missing':
                result = {'ok': False, 'partial': True, 'error': 'code_only_after_web_failure',
                          'browserError': web.get('error', 'web_unavailable'),
                          'codeEmail': email, 'webEmail': web.get('email'), 'browserReady': False,
                          'selectedAt': selected_at}
                result.update({key: web[key] for key in ('failureStep', 'cookieName', 'failedConnection', 'rolledBack', 'probeStatus', 'httpStatus') if key in web})
                atomic_json(STATE, result)
                return result
        result = {'ok': True, 'codeEmail': email, 'webEmail': web.get('email') if web.get('ok') else None,
                  'browserReady': bool(web.get('ok')), 'selectedAt': selected_at,
                  'message': 'Chrome and Code switched' if web.get('ok') else 'Code switched · connect Chrome'}
        atomic_json(STATE, result)
        return result


def snapshot(deadline=None):
    deadline = deadline or deadlines.Deadline(deadlines.STATUS_BUDGET)
    data = run_backend('list', '--json', timeout=deadline.timeout(deadlines.CSWAP_TIMEOUT))
    # Account and usage metadata only. Secret values never cross this interface.
    state = read_state()
    data['codeEmail'] = code_identity(timeout=deadline.timeout(deadlines.IDENTITY_TIMEOUT))
    data['browser'] = browser_state(deadline)
    data['lastSwitch'] = state
    return data


def switch_running():
    """True while a switch holds the lock. The probe never holds it long enough to
    make a new menu switch fail."""
    try:
        with open(BASE / 'switch.lock', 'r') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(lock, fcntl.LOCK_UN)
            return False
    except FileNotFoundError:
        return False


def current_selection():
    """The last Code selection, while it is still the active Code login."""
    state = read_state()
    email = state.get('codeEmail')
    selected_at = state.get('selectedAt')
    # Code switched in both cases; a partial result only lacks some Chrome profiles.
    code_switched = state.get('ok') is True or state.get('partial') is True
    stamped = (isinstance(selected_at, (int, float)) and not isinstance(selected_at, bool)
               and math.isfinite(selected_at))
    if (code_switched and stamped and isinstance(email, str)
            and email in configured_emails() and code_identity() == email):
        return {'email': email, 'selectedAt': selected_at}
    return {'email': None, 'selectedAt': None}


def handle_native(message):
    if message.get('action') == 'ping':
        return {'ok': True}
    if message.get('action') == 'diagnostic':
        details = message.get('details')
        if isinstance(details, dict):
            event_log.emit(BASE, 'browser_error', **{k: v for k, v in details.items() if k not in ('event', 'base')})
        return {'ok': True}
    from claude_swap import macos_keychain
    service = 'Paperfoot Claude Switcher Web'
    action = message.get('action')
    try:
        if action == 'vault_get':
            email = validate_email(message.get('email'))
            raw = macos_keychain.get_password(service, email)
            return {'ok': True, 'entry': restorable_web_entry(json.loads(raw)) if raw else None}
        if action == 'vault_put':
            entry = message['entry']
            email = validate_email(entry.get('email'))
            cookies = entry.get('cookies')
            if not isinstance(cookies, list) or len(cookies) > 200: raise ValueError()
            for cookie in cookies:
                domain = str(cookie.get('domain', '')).lstrip('.')
                if domain != 'claude.ai' and not domain.endswith('.claude.ai'): raise ValueError()
            encoded = json.dumps(entry, separators=(',', ':'))
            if len(encoded) > 512_000: raise ValueError()
            macos_keychain.set_password(service, email, encoded)
            if macos_keychain.get_password(service, email) != encoded: raise RuntimeError()
            with open(BASE / 'web-accounts.lock', 'a') as lock:
                os.chmod(lock.name, 0o600)
                fcntl.flock(lock, fcntl.LOCK_EX)
                emails = json.loads((BASE / 'web-accounts.json').read_text()) if (BASE / 'web-accounts.json').exists() else []
                atomic_json(BASE / 'web-accounts.json', sorted(set(emails + [email])))
            return {'ok': True}
        if action == 'vault_list':
            emails = json.loads((BASE / 'web-accounts.json').read_text()) if (BASE / 'web-accounts.json').exists() else []
            return {'ok': True, 'accounts': [e for e in emails if e in configured_emails()]}
        if action == 'pending_selection':
            if message.get('perProfile') is not True:
                # Companions before 0.8.0 apply any email returned here on every connect.
                state = read_state()
                email = state.get('codeEmail')
                pending = state.get('ok') and state.get('browserReady') is False
                return {'ok': True, 'email': email if pending and email in configured_emails() and code_identity() == email else None}
            # Every profile compares selectedAt with the last selection it applied itself,
            # so one profile catching up never hides the selection from another.
            if switch_running():
                # A profile that connected mid-switch may have been missed; it retries.
                return {'ok': False, 'error': 'switch_in_progress'}
            return {'ok': True, **current_selection()}
        if action == 'browser_ready':
            email = validate_email(message.get('email'))
            if switch_running():
                return {'ok': False, 'error': 'switch_in_progress'}
            state = read_state()
            selected_at = message.get('selectedAt', state.get('selectedAt'))
            # Read the Code identity without the lock so a menu switch is never refused.
            if state.get('codeEmail') != email or state.get('selectedAt') != selected_at or code_identity() != email:
                return {'ok': False, 'error': 'selection_changed'}
            if state.get('ok') is not True:
                # A partial result keeps its Chrome failure details for diagnostics.
                return {'ok': True}
            with open(BASE / 'switch.lock', 'a') as lock:
                try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: return {'ok': False, 'error': 'switch_in_progress'}
                if read_state() != state:
                    return {'ok': False, 'error': 'selection_changed'}
                state.update(browserReady=True, webEmail=email, message='Chrome and Code switched')
                atomic_json(STATE, state)
            return {'ok': True}
        if action == 'select':
            # The initiating profile is waiting for this reply; contact only the other hosts.
            # Finish before the popup gives up and restores its own cookies. Popups
            # older than 0.8.0 send no deadline and wait 120 s.
            deadline = deadlines.Deadline.from_unix_ms(message.get('deadline'), deadlines.POPUP_BUDGET)
            return select_account(message.get('email'), verified_browser=True,
                                  deadline=deadline or deadlines.Deadline(deadlines.LEGACY_POPUP_BUDGET))
        return {'ok': False, 'error': 'unknown_action'}
    except Exception:
        event_log.emit(BASE, 'native_error', error='keychain_error' if action in ('vault_get', 'vault_put') else 'backend_unavailable')
        return {'ok': False, 'error': 'Account could not be saved or opened. Unlock your Keychain and try again.'}


def main():
    global SOCKET
    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command == 'native':
        from native_transport import run_host
        from profile_transport import native_socket
        SOCKET = native_socket(BASE)
        origin = sys.argv[2] if len(sys.argv) > 2 else ''
        ident = (Path(__file__).parent / 'extension_id.txt').read_text().strip()
        raise SystemExit(run_host(origin, 'chrome-extension://' + ident + '/', str(SOCKET), handle_native))
    try:
        if command == 'refresh-code':
            email = validate_email(code_identity())
            result = {**refresh_code_cache(email), 'codeEmail': email}
        elif command == 'logs':
            result = {'ok': True, 'path': str(BASE / 'events.jsonl'), 'events': event_log.recent(BASE)}
        elif command == 'browser-status':
            result = browser_state(deadlines.Deadline(deadlines.STATUS_BUDGET))
        elif command == 'browser-switch':
            import argparse
            parser = argparse.ArgumentParser()
            parser.add_argument('email')
            parser.add_argument('--expect-profiles', type=int, default=1)
            args = parser.parse_args(sys.argv[2:])
            if args.expect_profiles < 1: parser.error('--expect-profiles must be at least 1')
            result = select_browser(args.email, expected_profiles=args.expect_profiles,
                                    deadline=deadlines.Deadline(deadlines.MENU_BUDGET))
        elif command == 'snapshot':
            result = snapshot(deadlines.Deadline(deadlines.STATUS_BUDGET))
        elif command == 'switch':
            # The menu app kills this helper after 350 s; finish well before that.
            result = select_account(sys.argv[2], deadline=deadlines.Deadline(deadlines.MENU_BUDGET))
        else:
            result = {'ok': False, 'error': 'unknown_action'}
    except Exception:
        event_log.emit(BASE, 'native_error', error='backend_unavailable')
        result = {'ok': False, 'error': 'Backend unavailable. Open Settings → Set up switching.'}
    print(json.dumps(result))
    if result.get('ok') is False: sys.exit(1)


if __name__ == '__main__': main()
