// Keeps Anthropic's own Claude extension on the account this profile selected.
// Its tokens live in chrome.storage.session, so a disable/enable cycle drops them
// without touching its saved shortcuts or tasks. It then signs back in silently
// only when Claude.ai is on its stored account; otherwise it shows Log in, which
// the menu app presses. This module only arms the Authorize click for that one
// OAuth client and checks the page shows the expected account first.
export const OFFICIAL_ID = 'fcoeoabgfenejglbffodgkkbkcdhcgfn';
export const OFFICIAL_CLIENT_ID = 'dae2cad8-15c5-43d2-9046-fcaecc135fa4';
export const OFFICIAL_REDIRECT = `chrome-extension://${OFFICIAL_ID}/oauth_callback.html`;
export const OPTIONS_URL = `chrome-extension://${OFFICIAL_ID}/options.html`;
export const ARM_MS = 150_000;
const SETTLE_MS = 1500;

function claudeURL(url) {
  try {
    const parsed = new URL(url);
    return parsed.origin === 'https://claude.ai' ? parsed : null;
  } catch {
    return null;
  }
}

export function officialAuthorizeURL(url) {
  const parsed = claudeURL(url);
  return Boolean(parsed && parsed.pathname === '/oauth/authorize' &&
    parsed.searchParams.get('client_id') === OFFICIAL_CLIENT_ID &&
    parsed.searchParams.get('redirect_uri') === OFFICIAL_REDIRECT);
}

export function installedURL(url) {
  const parsed = claudeURL(url);
  return Boolean(parsed && (parsed.pathname === '/chrome/installed' || parsed.pathname.startsWith('/chrome/installed/')));
}

// Injected into the consent page, so it must not reference anything outside itself.
export async function authorizeOnPage(email, timeoutMs = 10_000) {
  const wanted = String(email).toLowerCase();
  const end = Date.now() + timeoutMs;
  for (;;) {
    const text = (document.body?.innerText || '').replace(/\s+/g, ' ').trim().toLowerCase();
    const shown = /logged in as\s+([^\s@]+@[^\s]+?)(?=[\s,;)]|$)/.exec(text)?.[1]?.replace(/[.,;:]+$/, '');
    if (shown) {
      if (shown !== wanted) return 'refused';
      const buttons = [...document.querySelectorAll('button')].filter(button => button.textContent.trim() === 'Authorize');
      if (buttons.length > 1) return 'refused';
      if (buttons.length === 1 && !buttons[0].disabled) {
        buttons[0].click();
        return 'clicked';
      }
    }
    if (Date.now() >= end) return 'refused';
    await new Promise(resolve => setTimeout(resolve, 250));
  }
}

export class OfficialFollower {
  constructor({management, windows, tabs, scripting, identity, now = () => Date.now(),
    sleep = ms => new Promise(resolve => setTimeout(resolve, ms)), settleMs = SETTLE_MS}) {
    Object.assign(this, {management, windows, tabs, scripting, identity, now, sleep, settleMs});
    this.arm = null;
  }

  armed() {
    return this.arm && this.now() < this.arm.until ? this.arm : null;
  }

  async prepare(email) {
    if (typeof email !== 'string' || !email.includes('@')) return {ok: false, error: 'invalid_request'};
    if (this.armed()) return {ok: false, error: 'switch_in_progress'};
    const wanted = email.toLowerCase();
    const current = await this.identity().catch(() => null);
    if (!current || current.toLowerCase() !== wanted) return {ok: false, error: 'web_identity_mismatch'};
    let info;
    try {
      info = await this.management.get(OFFICIAL_ID);
    } catch {
      // Chrome rejects the lookup when the extension is not installed in this profile.
      return {ok: true, state: 'not_installed'};
    }
    if (!info) return {ok: true, state: 'not_installed'};
    if (!info.enabled) return {ok: true, state: 'disabled'};
    if (this.armed()) return {ok: false, error: 'switch_in_progress'};
    const arm = {email: wanted, until: this.now() + ARM_MS, windowId: null, tabId: null,
      authorized: false, consent: 'none', attempted: false};
    this.arm = arm;
    try {
      await this.management.setEnabled(OFFICIAL_ID, false);
      await this.management.setEnabled(OFFICIAL_ID, true);
    } catch {
      // Never leave Anthropic's extension switched off.
      await this.management.setEnabled(OFFICIAL_ID, true).catch(() => {});
      if (this.arm === arm) this.arm = null;
      return {ok: false, error: 'official_unavailable'};
    }
    await this.sleep(this.settleMs);
    if (this.arm !== arm) return {ok: false, error: 'switch_in_progress'};
    try {
      const window = await this.windows.create({url: OPTIONS_URL, focused: false, type: 'normal', width: 900, height: 760});
      arm.windowId = window?.id ?? null;
      arm.tabId = window?.tabs?.[0]?.id ?? null;
    } catch {
      if (this.arm === arm) this.arm = null;
      return {ok: false, error: 'official_unavailable'};
    }
    return {ok: true, state: 'opened', windowId: arm.windowId};
  }

  async finish() {
    const arm = this.arm;
    this.arm = null;
    if (!arm) return {ok: true, authorized: false, consent: 'none'};
    if (arm.windowId !== null) await this.windows.remove(arm.windowId).catch(() => {});
    return {ok: true, authorized: arm.authorized, consent: arm.consent};
  }

  async onTabUpdated(tabId, change, tab) {
    const arm = this.armed();
    if (!arm) return;
    const url = change?.url ?? tab?.url;
    if (installedURL(url)) {
      if (arm.authorized) return;
      arm.authorized = true;
      if (arm.consent !== 'clicked') arm.consent = 'skipped';
      await this.tabs.remove(tabId).catch(() => {});
      // The options page shows Log in until it renders again.
      if (arm.tabId !== null) await this.tabs.reload(arm.tabId).catch(() => {});
      return;
    }
    if (change?.status !== 'complete' || !officialAuthorizeURL(tab?.url) || arm.attempted) return;
    arm.attempted = true;
    let outcome;
    try {
      const [injected] = await this.scripting.executeScript({
        target: {tabId}, world: 'ISOLATED', func: authorizeOnPage, args: [arm.email],
      });
      outcome = injected?.result;
    } catch {
      outcome = 'refused';
    }
    if (outcome === 'clicked') arm.consent = 'clicked';
    else if (!arm.authorized) arm.consent = 'refused';
  }
}
