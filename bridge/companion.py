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
            except Exception as error:
                event_log.emit(BASE, 'switch_finished', scope=scope, ok=False, error=failure_code(error),
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


AUTO_THRESHOLD_RANGE = (50.0, 99.9)


def auto_events(threshold, timeout):
    """One `cswap auto --once` decision as JSON events. claude-swap paces its own usage
    polls through its usage store, so calling this every minute stays within rate limits."""
    result = subprocess.run([configuration()['cswap'], 'auto', '--once', '--json', '--threshold', f'{threshold:g}'],
                            env=clean_environment(), stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    # Exit 0: switched. 2: nothing to do. 3: no viable target. 1: the engine failed.
    if result.returncode not in (0, 2, 3):
        raise RuntimeError('auto_switch_failed')
    events = []
    for line in result.stdout.decode('utf-8', 'replace').splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


def auto_tick(threshold, deadline=None, events=None):
    """Let claude-swap decide whether Code should move; when it does, Chrome follows."""
    deadline = deadline or deadlines.Deadline(deadlines.MENU_BUDGET)
    low, high = AUTO_THRESHOLD_RANGE
    if not isinstance(threshold, (int, float)) or not math.isfinite(threshold) or not low <= threshold <= high:
        return {'ok': False, 'error': 'invalid_request'}
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(BASE / 'switch.lock', 'a') as lock:
        os.chmod(BASE / 'switch.lock', 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'ok': True, 'switched': False, 'reason': 'switch_in_progress'}
        previous = code_identity(timeout=deadline.timeout(deadlines.IDENTITY_TIMEOUT))
        if events is None:
            events = auto_events(threshold, deadline.timeout(deadlines.AUTO_ENGINE_TIMEOUT))
        switch = next((event for event in events if event.get('event') == 'switch' and not event.get('dryRun')), None)
        if switch is None:
            if any(event.get('event') == 'all-exhausted' for event in events):
                reason = 'all_exhausted'
            else:
                reason = next((str(event.get('reason')) for event in events if event.get('event') == 'no-switch'),
                              'no_action')
            return {'ok': True, 'switched': False, 'reason': reason}
        trigger = switch.get('trigger') if isinstance(switch.get('trigger'), str) else None
        target = switch.get('to') if isinstance(switch.get('to'), dict) else {}
        # claude-swap has already moved Code. Confirm it before Chrome follows.
        try:
            email = validate_email(str(target.get('email') or ''))
        except ValueError:
            event_log.emit(BASE, 'switch_finished', scope='auto', ok=False, error='unknown_account')
            return {'ok': False, 'switched': True, 'error': 'unknown_account', 'trigger': trigger}
        if code_identity(timeout=deadline.timeout(deadlines.IDENTITY_TIMEOUT)) != email:
            event_log.emit(BASE, 'switch_finished', scope='auto', ok=False, error='code_switch_failed')
            return {'ok': False, 'switched': True, 'error': 'code_switch_failed', 'trigger': trigger}
        if deadline.remaining() >= deadlines.CACHE_REPAIR_MINIMUM:
            refresh_code_cache(email)
        selected_at = time.time()
        try:
            web = browser_request('switch', email, deadline=deadline, selected_at=selected_at)
        except FileNotFoundError:
            web = {'ok': False, 'error': 'browser_missing'}
        except (OSError, TimeoutError, ValueError, deadlines.DeadlineExceeded):
            web = {'ok': False, 'error': 'web_unavailable'}
        if web.get('ok') and web.get('email') != email:
            web = {'ok': False, 'error': 'web_identity_mismatch'}
        ready = bool(web.get('ok'))
        # The same state a menu switch writes, so a closed Chrome profile catches up later.
        state = {'ok': True, 'codeEmail': email, 'webEmail': email if ready else None, 'browserReady': ready,
                 'selectedAt': selected_at, 'automatic': True, 'trigger': trigger,
                 'message': 'Switched automatically'}
        if not ready and web.get('error') != 'browser_missing':
            state.update(ok=False, partial=True, error='code_only_after_web_failure',
                         browserError=web.get('error', 'web_unavailable'))
        atomic_json(STATE, state)
        event_log.emit(BASE, 'switch_finished', scope='auto', ok=ready or web.get('error') == 'browser_missing',
                       browserReady=ready, **({'browserError': web.get('error')} if not ready else {}))
        return {'ok': True, 'switched': True, 'codeEmail': email, 'previousEmail': previous, 'trigger': trigger,
                'browserReady': ready, 'browserError': None if ready else web.get('error', 'web_unavailable')}


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


class InvalidData(ValueError):
    """A request carried data this coordinator refuses to store."""


def same_saved_login(raw, entry):
    """True when the stored entry already holds these cookies and this page.

    `savedAt` differs on every capture and is ignored; cookie order is not stable.
    """
    try:
        stored = json.loads(raw) if raw else None
    except ValueError:
        return False
    if not isinstance(stored, dict) or not isinstance(stored.get('cookies'), list):
        return False

    def canonical(cookies):
        return sorted(json.dumps(cookie, sort_keys=True, separators=(',', ':')) for cookie in cookies)

    return canonical(stored['cookies']) == canonical(entry['cookies']) and stored.get('url') == entry.get('url')


def session_expiry(cookies):
    """Earliest expiry (Unix seconds) of the persistent sessionKey* cookies, or None.

    The saved login stops working when the first of them lapses, so the app can
    warn before a switch to that account would fail.
    """
    expiries = []
    for cookie in cookies:
        expiration = cookie.get('expirationDate')
        if (str(cookie.get('name', '')).startswith('sessionKey') and not cookie.get('session')
                and isinstance(expiration, (int, float)) and not isinstance(expiration, bool)
                and math.isfinite(expiration)):
            expiries.append(expiration)
    return min(expiries) if expiries else None


def read_expiries():
    """Saved web login expiries by email. A separate file keeps web-accounts.json,
    which older companions read, a plain list."""
    try:
        data = json.loads((BASE / 'web-accounts-meta.json').read_text())
    except (OSError, ValueError):
        return {}
    expiries = data.get('expiries') if isinstance(data, dict) else None
    if not isinstance(expiries, dict):
        return {}
    return {email: seconds for email, seconds in expiries.items()
            if isinstance(email, str) and isinstance(seconds, (int, float))
            and not isinstance(seconds, bool) and math.isfinite(seconds)}


def remember_web_account(email, expiry):
    """List the email among saved web logins and record when its login expires.

    Each file is rewritten only when its content changes.
    """
    path = BASE / 'web-accounts.json'
    with open(BASE / 'web-accounts.lock', 'a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        emails = json.loads(path.read_text()) if path.exists() else []
        if email not in emails:
            atomic_json(path, sorted(set(emails + [email])))
        expiries = read_expiries()
        if expiries.get(email) != expiry:
            if expiry is None:
                expiries.pop(email, None)
            else:
                expiries[email] = expiry
            atomic_json(BASE / 'web-accounts-meta.json', {'expiries': expiries})


# Emails whose saved login this host process has already inspected for an expiry.
_EXPIRY_CHECKED = set()


def backfill_expiries(emails, read):
    """Logins saved before expiries were recorded have none. Read each such login once per
    host process and record when it expires; cookie values never leave this function."""
    known = read_expiries()
    for email in emails:
        if email in known or email in _EXPIRY_CHECKED:
            continue
        _EXPIRY_CHECKED.add(email)
        try:
            raw = read(email)
            entry = json.loads(raw) if raw else None
            cookies = entry.get('cookies') if isinstance(entry, dict) else None
            expiry = session_expiry(cookies) if isinstance(cookies, list) else None
        except Exception:
            continue
        if expiry is not None:
            remember_web_account(email, expiry)


# Failed replies always carry a snake_case code in `error`, which the app, the
# popup and the event log map. `message` is optional text for people.
MESSAGES = {
    'keychain_unavailable': 'Account could not be saved or opened. Unlock your Keychain and try again.',
    'backend_unavailable': 'Backend unavailable. Open Settings → Set up switching.',
    'unknown_account': 'This account is not set up in Claude Switcher.',
    'invalid_data': 'The Claude login could not be saved because it looks invalid.',
}


def failure_code(error, keychain=False):
    if isinstance(error, ValueError) and str(error) == 'unknown_account':
        return 'unknown_account'
    if isinstance(error, InvalidData):
        return 'invalid_data'
    return 'keychain_unavailable' if keychain else 'backend_unavailable'


def failure(error, keychain=False):
    code = failure_code(error, keychain)
    event_log.emit(BASE, 'native_error', error=code)
    return {'ok': False, 'error': code, 'message': MESSAGES[code]}


def handle_native(message):
    if message.get('action') == 'ping':
        return {'ok': True}
    if message.get('action') == 'diagnostic':
        details = message.get('details')
        if isinstance(details, dict):
            event_log.emit(BASE, 'browser_error', **{k: v for k, v in details.items() if k not in ('event', 'base')})
        return {'ok': True}
    service = 'Paperfoot Claude Switcher Web'
    action = message.get('action')
    try:
        from claude_swap import macos_keychain
        if action == 'vault_get':
            email = validate_email(message.get('email'))
            raw = macos_keychain.get_password(service, email)
            return {'ok': True, 'entry': restorable_web_entry(json.loads(raw)) if raw else None}
        if action == 'vault_put':
            entry = message.get('entry')
            if not isinstance(entry, dict): raise InvalidData()
            email = validate_email(entry.get('email'))
            cookies = entry.get('cookies')
            if not isinstance(cookies, list) or len(cookies) > 200: raise InvalidData()
            for cookie in cookies:
                if not isinstance(cookie, dict): raise InvalidData()
                domain = str(cookie.get('domain', '')).lstrip('.')
                if domain != 'claude.ai' and not domain.endswith('.claude.ai'): raise InvalidData()
            encoded = json.dumps(entry, separators=(',', ':'))
            if len(encoded) > 512_000: raise InvalidData()
            # One Keychain read instead of a write, read-back and file rewrite when
            # nothing changed; renewed cookies or a new page are still written.
            unchanged = same_saved_login(macos_keychain.get_password(service, email), entry)
            if not unchanged:
                macos_keychain.set_password(service, email, encoded)
                if macos_keychain.get_password(service, email) != encoded: raise RuntimeError()
            remember_web_account(email, session_expiry(cookies))
            return {'ok': True, 'saved': not unchanged}
        if action == 'vault_list':
            emails = json.loads((BASE / 'web-accounts.json').read_text()) if (BASE / 'web-accounts.json').exists() else []
            configured = configured_emails()
            accounts = [e for e in emails if e in configured]
            backfill_expiries(accounts, lambda email: macos_keychain.get_password(service, email))
            expiries = {e: seconds for e, seconds in read_expiries().items() if e in accounts}
            return {'ok': True, 'accounts': accounts, 'expiries': expiries}
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
    except Exception as error:
        return failure(error, keychain=action in ('vault_get', 'vault_put'))


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
        elif command == 'auto-tick':
            try:
                threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 95.0
            except ValueError:
                threshold = float('nan')
            result = auto_tick(threshold, deadline=deadlines.Deadline(deadlines.MENU_BUDGET))
        elif command == 'switch' and len(sys.argv) < 3:
            result = {'ok': False, 'error': 'invalid_request', 'message': 'Usage: companion.py switch EMAIL'}
        elif command == 'switch':
            # The menu app kills this helper after 350 s; finish well before that.
            result = select_account(sys.argv[2], deadline=deadlines.Deadline(deadlines.MENU_BUDGET))
        else:
            result = {'ok': False, 'error': 'unknown_action'}
    except Exception as error:
        result = failure(error)
    print(json.dumps(result))
    if result.get('ok') is False: sys.exit(1)


if __name__ == '__main__': main()
