// Browser operations are injected so the complete switch can be tested without real logins.
// Errors that can reach the popup carry a snake_case `code` it maps, plus readable text.
export function failure(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}
export function emailKey(value) {
  if (typeof value !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) || value.length > 254) throw failure('invalid_data', 'Invalid account email');
  return value.toLowerCase();
}
export function claudeCookie(cookie) {
  const domain = String(cookie?.domain || '').replace(/^\./, '');
  return domain === 'claude.ai' || domain.endsWith('.claude.ai');
}
export function browserScopedCookie(cookie) {
  return ['__cf_bm', '_cfuvid', 'cf_clearance', 'ion-vk', 'anthropic-device-id'].includes(cookie.name);
}
export function cookieDetails(cookie) {
  if (!claudeCookie(cookie) || typeof cookie.value !== 'string' || typeof cookie.name !== 'string') throw failure('invalid_data', 'Invalid saved cookie');
  const domain = cookie.domain.replace(/^\./, '');
  const result = {url: `https://${domain}${cookie.path || '/'}`, name: cookie.name, value: cookie.value,
    path: cookie.path || '/', secure: true, httpOnly: Boolean(cookie.httpOnly), storeId: cookie.storeId};
  if (!cookie.hostOnly && !cookie.name.startsWith('__Host-')) result.domain = cookie.domain;
  if (cookie.name.startsWith('__Host-')) result.path = '/';
  if (cookie.sameSite && cookie.sameSite !== 'unspecified') result.sameSite = cookie.sameSite;
  if (!cookie.session && Number.isFinite(cookie.expirationDate)) result.expirationDate = cookie.expirationDate;
  if (cookie.partitionKey) result.partitionKey = cookie.partitionKey;
  return result;
}
export function validSession(cookies, now = Date.now() / 1000) {
  return cookies.some(c => claudeCookie(c) && c.name === 'sessionKey' && c.value && unexpiredCookie(c, now));
}
export function unexpiredCookie(cookie, now = Date.now() / 1000) {
  return cookie.session || cookie.expirationDate === undefined ||
    (Number.isFinite(cookie.expirationDate) && cookie.expirationDate > now);
}
export function identityFrom(data) {
  const account = data?.account || data?.current_account || data;
  const email = account?.email_address || account?.email;
  return email ? emailKey(email) : null;
}

// What one Chrome profile remembers about Code selections, so it adopts a
// selection it missed and never undoes a login chosen afterwards.
//   appliedAt  newest selection (Unix seconds) this profile performed or adopted,
//              or the time of a later manual sign-in; older selections never apply
//   identity   digest of the login it last switched to or saw, never the email
// Updates run one at a time, so a switch is recorded before a later save compares.
export class SelectionMemory {
  constructor(storage, digest, now = () => Date.now() / 1000) {
    this.storage = storage; this.digest = digest; this.now = now;
    this.record = null;
    this.queue = Promise.resolve();
  }
  update(change) {
    const result = this.queue.then(async () => {
      this.record ??= await this.load();
      const next = await change(this.record);
      if (next) {
        this.record = next;
        await this.storage.set(next).catch(() => {});
      }
      return this.record;
    });
    this.queue = result.catch(() => {});
    return result;
  }
  async load() {
    const stored = await this.storage.get().catch(() => null);
    if (Number.isFinite(stored?.appliedAt) && (stored.identity === null || typeof stored.identity === 'string')) return stored;
    // A first run adopts no earlier selection; it starts from the login it finds.
    const fresh = {appliedAt: this.now(), identity: null};
    await this.storage.set(fresh).catch(() => {});
    return fresh;
  }
  current() {
    return this.update(() => null);
  }
  // This profile switched to `email`; `selectedAt` is absent for rollbacks.
  switched(email, selectedAt) {
    return this.update(async record => ({
      appliedAt: Number.isFinite(selectedAt) ? Math.max(record.appliedAt, selectedAt) : record.appliedAt,
      identity: await this.digest(emailKey(email)),
    }));
  }
  // A verified login was saved. One the companion did not switch to is the user's choice.
  observed(email) {
    return this.update(async record => {
      const identity = await this.digest(emailKey(email));
      if (record.identity === identity) return null;
      const manual = record.identity !== null;
      return {appliedAt: manual ? Math.max(record.appliedAt, this.now()) : record.appliedAt, identity};
    });
  }
  // "Add another account": whatever the user signs in to next wins over older selections.
  manualLogin() {
    return this.update(record => ({appliedAt: Math.max(record.appliedAt, this.now()), identity: null}));
  }
}

export class SessionSwitcher {
  constructor(browser, vault, probe) {
    this.browser = browser; this.vault = vault; this.probe = probe;
    this.pending = Promise.resolve();
  }
  serialize(work) {
    const result = this.pending.then(work);
    this.pending = result.catch(() => {});
    return result;
  }
  async capture() {
    // Never attribute current cookies to a remembered selection. Users can sign in manually.
    const before = await this.probe();
    if (!before) throw failure('web_signed_out', 'Sign in to Claude.ai, then save this account');
    const cookies = (await this.browser.cookies()).filter(claudeCookie);
    if (!validSession(cookies)) throw failure('web_login_expired', 'This Claude login has expired');
    const after = await this.probe();
    if (after !== before) throw failure('web_identity_changed', 'Account changed while saving; try again');
    return {email: emailKey(before), cookies, savedAt: Date.now(), url: await this.browser.currentURL()};
  }
  // `onSaved` receives the stored entry, so a caller can remember what it saved
  // without the cookies ever leaving this module in a result.
  save(onSaved) { return this.serialize(async () => {
    const entry = await this.capture(); await this.vault.put(entry); onSaved?.(entry); return {ok:true,email:entry.email};
  }); }
  newLogin() { return this.serialize(async () => {
    await this.openLogin();
    return {ok:true};
  }); }
  // Callers hold the serialized section. A current login that cannot be saved stops
  // this before anything is cleared, so no working login is ever lost.
  async openLogin() {
    if (await this.probe()) await this.vault.put(await this.capture());
    // Clear locally, without calling Claude's logout endpoint and revoking a saved session.
    await this.browser.clear();
    await this.browser.openLogin();
  }
  status() { return this.serialize(async () => {
    const email = await this.probe();
    // A vault may also report when each saved login expires, in Unix seconds.
    const listing = await this.vault.list();
    const {accounts, expiries} = Array.isArray(listing) ? {accounts: listing} : listing ?? {};
    return {ok: true, email, accounts: accounts ?? [], ...(expiries ? {expiries} : {})};
  }); }
  // The current login, never observed halfway through a switch.
  identity() { return this.serialize(() => this.probe()); }
  // `stillWanted` runs first inside the serialized section, so a switch queued ahead of
  // this one can cancel it instead of being overwritten by it.
  // `openLogin` is for a switch the user just chose: when the target's saved login is
  // missing or dead, Chrome is left at claude.ai/login so one sign-in finishes the switch.
  // The previous login is saved first and only cleared locally, never revoked.
  switchTo(email, activateCode = null, expiresAt = Infinity, stillWanted = null, {openLogin = false} = {}) { return this.serialize(async () => {
    const result = await this.attemptSwitch(email, activateCode, expiresAt, stillWanted);
    if (!openLogin || !['web_login_expired', 'web_login_needed'].includes(result.error)) return result;
    try { await this.openLogin(); } catch { return result; }
    return {...result, loginOpened:true};
  }); }
  async attemptSwitch(email, activateCode, expiresAt, stillWanted) {
    const expired = () => Date.now() >= expiresAt;
    if (expired()) return {ok:false,error:'browser_timeout',email};
    if (stillWanted && !(await stillWanted())) return {ok:false,error:'selection_changed',email};
    email = emailKey(email);
    const target = await this.vault.get(email);
    if (!target || emailKey(target.email) !== email) return {ok:false,error:'web_login_needed',email};
    if (!Array.isArray(target.cookies) || !validSession(target.cookies)) return {ok:false,error:'web_login_expired',email};
    // Validate the entire target before touching the live cookie jar.
    const details = target.cookies.map(cookie => ({cookie, details:cookieDetails(cookie)}));
    const previous = (await this.browser.cookies()).filter(claudeCookie);
    let oldIdentity = await this.probe();
    if (oldIdentity) {
      const captured = await this.capture();
      oldIdentity = captured.email;
      await this.vault.put(captured);
      if (expired()) return {ok:false,error:'browser_timeout',email};
      if (oldIdentity === email) {
        try {
          const activation = activateCode ? await activateCode(email) : null;
          if (activation?.partial && activation.codeEmail === email) return {...activation, email};
          if (activation?.ok === false) throw new Error('Code activation failed');
        } catch { return {ok:false,error:'code_switch_failed',email}; }
        return {ok:true,email};
      }
    }
    let failure = 'web_switch_failed';
    let failureStep = 'clear_cookies';
    let cookieName;
    let verification;
    let activation;
    try {
      if (expired()) return {ok:false,error:'browser_timeout',email};
      await this.browser.clear();
      failureStep = 'restore_cookies';
      for (const entry of details) {
        if (expired()) throw new Error('Switch timed out');
        // Chrome treats setting a past expiry as deletion and can return null.
        // Ancillary cookies may expire hours before the actual Claude login does.
        if (!unexpiredCookie(entry.cookie) || browserScopedCookie(entry.cookie)) continue;
        cookieName = entry.cookie.name;
        if (!await this.browser.set(entry.details)) throw new Error('Cookie restoration failed');
      }
      failureStep = 'verify_identity';
      cookieName = undefined;
      const identity = await this.probe();
      if (identity !== email) {
        verification = {...this.probe.diagnostic};
        if (identity) verification.probeStatus = 'identity_mismatch';
        if (['unauthorized', 'signed_out'].includes(verification.probeStatus)) failure = 'web_login_expired';
        throw new Error('Restored account could not be verified');
      }
      if (expired()) throw new Error('Switch timed out');
      // Keep the browser transaction locked until Code has committed or rolled back.
      // A menu selection must not interleave with a popup selection halfway through.
      if (activateCode) {
        failureStep = 'activate_code';
        failure = 'code_switch_failed';
        activation = await activateCode(email);
        if (activation?.ok === false && !(activation.partial && activation.codeEmail === email)) throw new Error('Code activation failed');
      }
    } catch {
      // Preserve the previous session if ANY restore or identity check failed.
      try {
        await this.browser.clear();
        for (const cookie of previous) {
          if (!unexpiredCookie(cookie) || browserScopedCookie(cookie)) continue;
          if (!await this.browser.set(cookieDetails(cookie))) throw new Error('restore failed');
        }
        if (await this.probe() !== oldIdentity) throw new Error('identity mismatch');
      } catch { return {ok:false,error:'web_restore_failed',email,failureStep,...verification,...(cookieName?{cookieName}:{})}; }
      return {ok:false,error:failure,email,failureStep,...verification,...(cookieName?{cookieName}:{})};
    }
    await this.browser.refresh(target.url);
    if (activation?.partial) return {...activation, email};
    return {ok:true,email};
  }
}
