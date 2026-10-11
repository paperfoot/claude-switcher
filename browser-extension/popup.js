const message = document.querySelector('#message');
// Every failed reply carries a code in `error`; `message` is only fallback text.
const errors = {
  web_login_needed: 'Sign in to this account once. It will be saved automatically.',
  web_login_expired: 'This login expired. Sign in once to reconnect.',
  web_signed_out: 'Sign in to Claude.ai, then save this login.',
  web_identity_changed: 'The account changed while saving. Try again.',
  web_switch_failed: 'Could not switch Chrome. Your previous login was restored.',
  web_restore_failed: 'Chrome needs a fresh sign-in.',
  browser_timeout: 'Switching took too long. Your previous login was restored.',
  code_switch_failed: 'Code could not switch. Your Chrome login is unchanged.',
  code_only_after_web_failure: 'Code switched. Another Chrome profile could not switch.',
  browser_missing: 'Chrome companion is not connected.',
  switch_in_progress: 'Another switch is finishing. Try again.',
  keychain_unavailable: 'Your Keychain is locked. Unlock it and try again.',
  backend_unavailable: 'Claude Switcher needs setup. Open Settings, then Set up switching.',
  unknown_account: 'This account is not set up in Claude Switcher.',
  invalid_data: 'This login could not be saved. Sign in again.',
  native_unavailable: 'Open Claude Switcher to connect.',
  native_timeout: 'Claude Switcher did not respond. Try again.',
  native_disconnected: 'Claude Switcher disconnected. Try again.',
  host_busy: 'Claude Switcher is busy. Try again.',
};

function setButtonsDisabled(disabled) {
  document.querySelectorAll('button').forEach(button => { button.disabled = disabled; });
}

async function run(action, extra = {}) {
  setButtonsDisabled(true);
  try {
    const result = await chrome.runtime.sendMessage({action, ...extra});
    if (!result?.ok) throw new Error(errors[result?.error] || result?.message || 'Could not connect');
    return result;
  } finally {
    setButtonsDisabled(false);
  }
}

async function refresh() {
  try {
    const result = await run('status');
    const list = document.querySelector('#accounts');
    list.replaceChildren();
    for (const email of result.accounts) {
      const button = document.createElement('button');
      button.textContent = (result.email === email ? '✓  ' : '') + email;
      button.onclick = async () => {
        try {
          message.textContent = 'Switching…';
          const switched = await run('switch', {email});
          message.textContent = switched.message || 'Switched';
          await refresh();
        } catch (error) {
          message.textContent = error.message;
        }
      };
      list.append(button);
    }
    message.textContent = result.email ? `Chrome: ${result.email}` : 'Sign in to Claude.ai, then save this login.';
  } catch (error) {
    message.textContent = error.message;
  }
}

document.querySelector('#add').onclick = async () => {
  try {
    await run('newLogin');
    message.textContent = 'Choose the next account on Claude.ai. It will be saved automatically.';
  } catch (error) {
    message.textContent = error.message;
  }
};
document.querySelector('#save').onclick = async () => {
  try {
    await run('save');
    await refresh();
  } catch (error) {
    message.textContent = error.message;
  }
};
refresh();
