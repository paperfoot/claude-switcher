export const protocol = 'paperfoot-account-link-v1';
const companionID = 'hlldhcbaknomojegdfceljiepokkhcll';
const validEmail = value => typeof value === 'string' && value.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
const validUUID = value => typeof value === 'string' && /^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(value);
const problem = code => { throw new Error(code); };

export function webIdentity(data) {
  const account = data?.account || data?.current_account || data;
  const email = account?.email_address || account?.email;
  if (!validEmail(email) || !validUUID(account?.uuid)) problem('web_identity_unavailable');
  return {email: email.toLowerCase(), uuid: account.uuid.toLowerCase()};
}

export async function readWebIdentity(fetcher = fetch) {
  for (const endpoint of ['/api/auth/current_account', '/api/bootstrap']) {
    try {
      const response = await fetcher(`https://claude.ai${endpoint}`, {
        credentials: 'include', cache: 'no-store', signal: AbortSignal.timeout(8000),
      });
      if (response.ok) return webIdentity(await response.json());
    } catch {}
  }
  problem('web_identity_unavailable');
}

export async function silentSwitch({chromeAPI, oauth, web, email, expiresAt, now = Date.now}) {
  const target = await web();
  if (target.email !== email) problem('web_identity_mismatch');
  const check = async () => {
    if (now() >= expiresAt) problem('switch_expired');
    const latest = await web();
    if (now() >= expiresAt) problem('switch_expired');
    if (latest.email !== email || latest.uuid !== target.uuid) problem('web_identity_changed');
  };
  await check();
  const epoch = oauth.epoch();
  const config = oauth.config();
  const redirect = chromeAPI.identity.getRedirectURL();
  const state = oauth.random();
  const verifier = oauth.random();
  const challenge = await oauth.challenge(verifier);
  const url = new URL(config.AUTHORIZE_URL);
  url.search = new URLSearchParams({client_id: config.CLIENT_ID, response_type: 'code',
    scope: config.SCOPES_STR, redirect_uri: redirect, state, code_challenge: challenge,
    code_challenge_method: 'S256', prompt: 'none', login_hint: target.uuid}).toString();
  let callback;
  try {
    callback = await chromeAPI.identity.launchWebAuthFlow({url: url.href, interactive: false,
      abortOnLoadForNonInteractive: false, timeoutMsForNonInteractive: 15000});
  } catch { problem('authorization_needed'); }
  let result;
  try { result = new URL(callback); } catch { problem('authorization_failed'); }
  const expected = new URL(redirect);
  if (result.origin !== expected.origin || result.pathname !== expected.pathname || result.searchParams.get('state') !== state) problem('invalid_callback');
  if (result.searchParams.has('error')) problem('authorization_needed');
  const code = result.searchParams.get('code');
  if (!code) problem('authorization_failed');
  const tokens = await oauth.exchange(code, state, verifier, {...config, REDIRECT_URI: redirect});
  if (!tokens.success) problem('authorization_failed');
  if (tokens.accountUuid?.toLowerCase() !== target.uuid) problem('extension_identity_mismatch');
  if ((await oauth.verify(tokens.accessToken))?.toLowerCase() !== target.uuid) problem('extension_identity_mismatch');
  await check();
  if (oauth.epoch() !== epoch) problem('authorization_superseded');
  // Invalidate refreshes for the previous account before committing the replacement.
  const nextEpoch = oauth.invalidate();
  if (!await oauth.commit({...tokens, org: tokens.org ?? null}, state, nextEpoch)) problem('authorization_superseded');
  return target;
}

export function installAccountLink({chromeAPI, oauth, currentAccount, afterSwitch, web = readWebIdentity, now = Date.now}) {
  let busy = false;
  chromeAPI.runtime.onMessageExternal.addListener((message, sender, send) => {
    if (sender.id !== companionID || message?.protocol !== protocol) return false;
    if (message.action === 'status') {
      currentAccount().then(uuid => send({ok: true, protocol, accountUUID: uuid ?? null, busy}))
        .catch(() => send({ok: false, error: 'extension_unavailable'}));
      return true;
    }
    if (message.action !== 'follow' || !validEmail(message.email) || !Number.isFinite(message.expiresAt) ||
        message.expiresAt <= now() || message.expiresAt > now() + 120000) {
      send({ok: false, error: 'invalid_request'}); return false;
    }
    if (busy) { send({ok: false, error: 'switch_in_progress'}); return false; }
    busy = true;
    void (async () => {
      try {
        const previous = await currentAccount();
        const target = await web();
        if (target.email !== message.email.toLowerCase()) problem('web_identity_mismatch');
        if (previous?.toLowerCase() !== target.uuid) {
          await silentSwitch({chromeAPI, oauth, web, email: target.email, expiresAt: message.expiresAt, now});
          await afterSwitch(previous, target.uuid);
        }
        const verified = await currentAccount();
        const finalWeb = await web();
        if (verified?.toLowerCase() !== target.uuid || finalWeb.uuid !== target.uuid || finalWeb.email !== target.email) problem('extension_identity_mismatch');
        send({ok: true, email: target.email, accountUUID: target.uuid});
      } catch (error) {
        const allowed = ['web_identity_unavailable', 'web_identity_mismatch', 'web_identity_changed', 'switch_expired',
          'authorization_needed', 'authorization_failed', 'invalid_callback', 'extension_identity_mismatch', 'authorization_superseded'];
        send({ok: false, error: allowed.includes(error.message) ? error.message : 'extension_unavailable'});
      } finally { busy = false; }
    })();
    return true;
  });
}
