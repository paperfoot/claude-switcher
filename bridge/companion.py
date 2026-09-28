#!/usr/bin/env python3
"""Local coordinator. No web cookies or tokens are written to logs or JSON files."""
import fcntl
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

BASE = Path.home() / '.config' / 'claude-switcher'
SOCKET = BASE / 'browser.sock'
STATE = BASE / 'coordinated-state.json'
SELECTORS = ('CLAUDE_CONFIG_DIR', 'CLAUDE_SECURESTORAGE_CONFIG_DIR', 'CLAUDE_CODE_OAUTH_TOKEN',
             'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN',
             'ANTHROPIC_BASE_URL', 'ANTHROPIC_CUSTOM_HEADERS', 'CLAUDE_CODE_USE_BEDROCK',
             'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY')


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


def run_backend(*args, timeout=60):
    result = subprocess.run([configuration()['cswap'], *args], env=clean_environment(),
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError('code_switch_failed')
    return json.loads(result.stdout)


def code_identity():
    result = subprocess.run([configuration()['claude'], 'auth', 'status', '--json'], env=clean_environment(),
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
    data = json.loads(result.stdout)
    if data.get('loggedIn') and data.get('authMethod') == 'claude.ai':
        return str(data.get('email', '')).lower() or None
    return None


def switch_code(email):
    validate_email(email)
    run_backend('switch', email, '--json')
    if code_identity() != email:
        raise RuntimeError('code_identity_mismatch')


def browser_request(command, email=None):
    from native_transport import send_request
    result = send_request(str(SOCKET), command, email, timeout=170)
    if result.get('error') == 'host_unavailable':
        return {'ok': False, 'error': 'browser_missing', 'accounts': []}
    return result


def browser_state():
    try:
        return browser_request('status')
    except (OSError, TimeoutError, ValueError):
        return {'ok': False, 'error': 'browser_missing', 'accounts': []}


def select_account(email, include_browser=True, verified_browser=False):
    email = validate_email(email)
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(BASE / 'switch.lock', 'a') as lock:
        os.chmod(BASE / 'switch.lock', 0o600)
        # Serialise selections across the menu and the extension; fail promptly on contention.
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return {'ok': False, 'error': 'switch_in_progress'}
        old = code_identity()
        try:
            switch_code(email)
        except Exception:
            # cswap rolls back failed writes; verify/repair if activation failed after a write.
            if old and old != email:
                try: switch_code(old)
                except Exception: return {'ok': False, 'error': 'code_restore_failed'}
            return {'ok': False, 'error': 'code_switch_failed'}
        web = {'ok': True, 'email': email} if verified_browser else {'ok': False, 'error': 'browser_missing'}
        if include_browser:
            try: web = browser_request('switch', email)
            except FileNotFoundError: pass
            except (OSError, TimeoutError, ValueError):
                web = {'ok': False, 'error': 'web_unavailable'}
            if web.get('ok') and web.get('email') != email:
                web = {'ok': False, 'error': 'web_identity_mismatch'}
            # An installed companion rejecting a target must not leave Code on a different account.
            if not web.get('ok') and web.get('error') != 'browser_missing':
                if old and old != email:
                    try: switch_code(old)
                    except Exception: return {'ok': False, 'error': 'code_restore_failed'}
                result = {'ok': False, 'error': web.get('error', 'web_unavailable'), 'codeEmail': old}
                if old is None:
                    # There was no signed-in Code account to restore. Report the actual state.
                    result.update(error='code_only_after_web_failure', codeEmail=email, browserReady=False)
                atomic_json(STATE, result)
                return result
        result = {'ok': True, 'codeEmail': email, 'webEmail': web.get('email') if web.get('ok') else None,
                  'browserReady': bool(web.get('ok')), 'selectedAt': time.time(),
                  'message': 'Chrome and Code switched' if web.get('ok') else 'Code switched · connect Chrome'}
        atomic_json(STATE, result)
        return result


def snapshot():
    data = run_backend('list', '--json')
    # Account and usage metadata only. Secret values never cross this interface.
    state = read_state()
    data['codeEmail'] = code_identity()
    data['browser'] = browser_state()
    data['lastSwitch'] = state
    return data


def handle_native(message):
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
            emails = json.loads((BASE / 'web-accounts.json').read_text()) if (BASE / 'web-accounts.json').exists() else []
            atomic_json(BASE / 'web-accounts.json', sorted(set(emails + [email])))
            return {'ok': True}
        if action == 'vault_list':
            emails = json.loads((BASE / 'web-accounts.json').read_text()) if (BASE / 'web-accounts.json').exists() else []
            return {'ok': True, 'accounts': [e for e in emails if e in configured_emails()]}
        if action == 'pending_selection':
            state = read_state()
            email = state.get('codeEmail')
            pending = state.get('ok') and state.get('browserReady') is False
            return {'ok': True, 'email': email if pending and email in configured_emails() and code_identity() == email else None}
        if action == 'browser_ready':
            email = validate_email(message.get('email'))
            with open(BASE / 'switch.lock', 'a') as lock:
                try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: return {'ok': False, 'error': 'switch_in_progress'}
                state = read_state()
                if state.get('codeEmail') != email or code_identity() != email:
                    return {'ok': False, 'error': 'selection_changed'}
                state.update(browserReady=True, webEmail=email, message='Chrome and Code switched')
                atomic_json(STATE, state)
            return {'ok': True}
        if action == 'select':
            # The extension has already switched and verified Chrome; don't ask it recursively.
            return select_account(message.get('email'), include_browser=False, verified_browser=True)
        return {'ok': False, 'error': 'unknown_action'}
    except Exception:
        return {'ok': False, 'error': 'Account could not be saved or opened. Unlock your Keychain and try again.'}


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command == 'native':
        from native_transport import run_host
        origin = sys.argv[2] if len(sys.argv) > 2 else ''
        ident = (Path(__file__).parent / 'extension_id.txt').read_text().strip()
        raise SystemExit(run_host(origin, 'chrome-extension://' + ident + '/', str(SOCKET), handle_native))
    try:
        result = snapshot() if command == 'snapshot' else select_account(sys.argv[2]) if command == 'switch' else {'ok': False, 'error': 'unknown_action'}
    except Exception:
        result = {'ok': False, 'error': 'Backend unavailable. Open Settings → Set up switching.'}
    print(json.dumps(result))
    if result.get('ok') is False: sys.exit(1)


if __name__ == '__main__': main()
