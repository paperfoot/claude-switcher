// Browser operations are injected so the complete switch can be tested without real logins.
export function emailKey(value) {
  if (typeof value !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) || value.length > 254) throw new Error('Invalid account email');
  return value.toLowerCase();
}
export function claudeCookie(cookie) {
  const domain = String(cookie?.domain || '').replace(/^\./, '');
  return domain === 'claude.ai' || domain.endsWith('.claude.ai');
}
export function cookieDetails(cookie) {
  if (!claudeCookie(cookie) || typeof cookie.value !== 'string' || typeof cookie.name !== 'string') throw new Error('Invalid saved cookie');
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
  return cookies.some(c => claudeCookie(c) && c.name === 'sessionKey' && c.value && (c.session || !c.expirationDate || c.expirationDate > now));
}
export function identityFrom(data) {
  const account = data?.account || data?.current_account || data;
  const email = account?.email_address || account?.email;
  return email ? emailKey(email) : null;
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
    if (!before) throw new Error('Sign in to Claude.ai, then save this account');
    const cookies = (await this.browser.cookies()).filter(claudeCookie);
    if (!validSession(cookies)) throw new Error('This Claude login has expired');
    const after = await this.probe();
    if (after !== before) throw new Error('Account changed while saving; try again');
    return {email: emailKey(before), cookies, savedAt: Date.now(), url: await this.browser.currentURL()};
  }
  save() { return this.serialize(async () => {
    const entry = await this.capture(); await this.vault.put(entry); return {ok:true,email:entry.email};
  }); }
  newLogin() { return this.serialize(async () => {
    if (await this.probe()) await this.vault.put(await this.capture());
    // Clear locally, without calling Claude's logout endpoint and revoking a saved session.
    await this.browser.clear();
    await this.browser.openLogin();
    return {ok:true};
  }); }
  status() { return this.serialize(async () => ({ok:true,email:await this.probe(),accounts:await this.vault.list()})); }
  switchTo(email, activateCode = null, expiresAt = Infinity) { return this.serialize(async () => {
    const expired = () => Date.now() >= expiresAt;
    if (expired()) return {ok:false,error:'browser_timeout',email};
    email = emailKey(email);
    const target = await this.vault.get(email);
    if (!target || emailKey(target.email) !== email) return {ok:false,error:'web_login_needed',email};
    if (!Array.isArray(target.cookies) || !validSession(target.cookies)) return {ok:false,error:'web_login_expired',email};
    // Validate the entire target before touching the live cookie jar.
    const details = target.cookies.map(cookieDetails);
    const previous = (await this.browser.cookies()).filter(claudeCookie);
    let oldIdentity = await this.probe();
    if (oldIdentity) {
      const captured = await this.capture();
      oldIdentity = captured.email;
      await this.vault.put(captured);
      if (expired()) return {ok:false,error:'browser_timeout',email};
      if (oldIdentity === email) {
        try {
          if (activateCode && (await activateCode(email))?.ok === false) throw new Error('Code activation failed');
        } catch { return {ok:false,error:'code_switch_failed',email}; }
        return {ok:true,email};
      }
    }
    let failure = 'web_switch_failed';
    try {
      if (expired()) return {ok:false,error:'browser_timeout',email};
      await this.browser.clear();
      for (const cookie of details) {
        if (expired()) throw new Error('Switch timed out');
        if (!await this.browser.set(cookie)) throw new Error('Cookie restoration failed');
      }
      if (await this.probe() !== email) throw new Error('Restored account could not be verified');
      if (expired()) throw new Error('Switch timed out');
      // Keep the browser transaction locked until Code has committed or rolled back.
      // A menu selection must not interleave with a popup selection halfway through.
      if (activateCode) {
        failure = 'code_switch_failed';
        if ((await activateCode(email))?.ok === false) throw new Error('Code activation failed');
      }
    } catch {
      // Preserve the previous session if ANY restore or identity check failed.
      try {
        await this.browser.clear();
        for (const cookie of previous) {
          if (!await this.browser.set(cookieDetails(cookie))) throw new Error('restore failed');
        }
        if (await this.probe() !== oldIdentity) throw new Error('identity mismatch');
      } catch { return {ok:false,error:'web_restore_failed',email}; }
      return {ok:false,error:failure,email};
    }
    await this.browser.refresh(target.url);
    return {ok:true,email};
  }); }
}
