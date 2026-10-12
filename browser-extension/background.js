import {SessionSwitcher, SelectionMemory, failure, identityFrom, claudeCookie, browserScopedCookie} from './session-core.js'; import {OfficialFollower} from './official-extension.js';
const HOST = 'org.paperfoot.claude_switcher';
// A catch-up switch has no waiting caller; bound it like a menu switch.
const CATCH_UP_MS = 120_000;
let catchUpDue = false;
let port;
let connectionError = 'Open Claude Switcher to connect';
let popupSwitchInProgress = false;
let incomingCommands = 0;
let commandSwitches = 0;
// The last committed identity, reported while a switch holds the session lock.
let knownStatus = {email: null, accounts: [], expiries: {}};
let healthCheckRunning = false;
let lastHealthCheckAt = 0;
let lastSessionSavedAt = 0;
let lastSessionCheckedAt = 0;
// Background saves are skipped while this profile's session cookies are unchanged
// since its last save; only a digest is stored, never a value. Renewed cookies
// change the digest and are saved at once. An unchanged login is still re-saved
// after MAX_SAVE_AGE_MS, so a shared vault entry another profile replaced heals.
const SESSION_COOKIES = ['sessionKey', 'sessionKeyLC', 'sessionKeyV3', 'sessionKeyV3LC'];
const SAVED_SESSION_KEY = 'savedSession';
const SESSION_CHECK_MS = 5 * 60 * 1000;
const MAX_SAVE_AGE_MS = 6 * 60 * 60 * 1000;
let sessionSaveInFlight = null;
let probesInFlight = 0;
const requests = new Map();
// Deadline ladder: bridge/deadlines.py. The companion finishes a popup selection,
// including restoring other profiles, before SELECT_BUDGET_MS; this waits longer,
// so the local cookies are only rolled back once the companion has given up too.
const SELECT_BUDGET_MS = 150_000;
const SELECT_REPLY_MS = 180_000;
function native(action, payload = {}, timeoutMs = 30000) {
  if (!port) connect();
  if (!port) return Promise.reject(failure('native_unavailable', connectionError));
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      requests.delete(id);
      reject(failure('native_timeout', 'Companion did not respond'));
    }, timeoutMs);
    requests.set(id, {resolve, reject, timeout});
    try {
      port.postMessage({type: 'request', id, action, ...payload});
    } catch {
      clearTimeout(timeout);
      requests.delete(id);
      reject(failure('native_disconnected', 'Companion disconnected'));
    }
  });
}
async function probe() {
  probesInFlight++;
  try {
  let diagnostic = {probeStatus:'invalid_response'};
  for (const endpoint of ['/api/bootstrap','/api/auth/current_account']) {
    try {
      const response=await fetch('https://claude.ai'+endpoint,{credentials:'include',cache:'no-store',signal:AbortSignal.timeout(8000)});
      if (!response.ok) {
        // Keep the bootstrap failure; a missing legacy endpoint is not a login failure.
        if(response.status!==404) diagnostic={httpStatus:response.status,probeStatus:response.status===401?'unauthorized':response.status===403?'forbidden':response.status===429?'rate_limited':'server_error'};
        continue;
      }
      const data=await response.json();
      const email=identityFrom(data);
      if(email) {probe.diagnostic={probeStatus:'verified',httpStatus:response.status}; return email;}
      // claude.ai answers a revoked login with 200 and a null account; the saved cookies
      // can still look unexpired, so only this reply shows the login needs signing in again.
      if(data && typeof data==='object' && (data.account===null || data.current_account===null)) diagnostic={probeStatus:'signed_out',httpStatus:response.status};
    } catch { if(!diagnostic.httpStatus) diagnostic={probeStatus:'network_error'}; }
  }
  probe.diagnostic=diagnostic;
  report({error:'web_unavailable',failureStep:'verify_identity',...diagnostic});
  return null;
  } finally {probesInFlight--;}
}
function report(details) {
  if(port) void native('diagnostic',{details},5000).catch(()=>{});
}
const browser = {
  cookies:()=>chrome.cookies.getAll({domain:'claude.ai',storeId:'0'}),
  async clear() {
    for(const c of await this.cookies()) {
      if(!claudeCookie(c) || browserScopedCookie(c)) continue;
      const removed=await chrome.cookies.remove({url:`https://${c.domain.replace(/^\./,'')}${c.path||'/'}`,name:c.name,storeId:c.storeId,...(c.partitionKey?{partitionKey:c.partitionKey}:{})});
      if(!removed) throw failure('web_switch_failed', 'Could not clear Claude session');
    }
  },
  set:details=>chrome.cookies.set(details),
  async currentURL() {
    const tabs=await chrome.tabs.query({url:'https://claude.ai/*'});
    return tabs.sort((a,b)=>(b.lastAccessed||0)-(a.lastAccessed||0))[0]?.url || 'https://claude.ai/new';
  },
  async openLogin() {
    const tabs=await chrome.tabs.query({url:'https://claude.ai/*'});
    if(tabs.length)await chrome.tabs.update(tabs[0].id,{url:'https://claude.ai/login',active:true});
    else await chrome.tabs.create({url:'https://claude.ai/login'});
  },
  async refresh(savedURL) {
    let url='https://claude.ai/new';
    try { const u=new URL(savedURL); if(u.origin==='https://claude.ai' && !/^\/(oauth|logout|login)/.test(u.pathname)) url=u.href; } catch {}
    const tabs=await chrome.tabs.query({url:'https://claude.ai/*'});
    // No new window or focus change; the next visit also inherits the selected session.
    await Promise.all(tabs.map(t=>chrome.tabs.update(t.id,{url}).catch(()=>{})));
  }
};
const vault={
  async get(email){return (await native('vault_get',{email})).entry;},
  async put(entry){await native('vault_put',{entry});},
  async list() {
    const listing = await native('vault_list');
    return {accounts: listing.accounts || [], expiries: listing.expiries || {}};
  }
};
const switcher=new SessionSwitcher(browser,vault,probe);
// Created on the first command, so a profile that never follows Anthropic's
// extension never registers anything against it.
let officialFollower;
function official() {
  officialFollower ??= new OfficialFollower({
    management: chrome.management, windows: chrome.windows, tabs: chrome.tabs,
    scripting: chrome.scripting, identity: () => switcher.identity(),
  });
  return officialFollower;
}
async function digest(text) {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
  return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
}
const SELECTION_KEY = 'selection';
const selections = new SelectionMemory({
  get: async () => (await chrome.storage.local.get(SELECTION_KEY))[SELECTION_KEY],
  set: value => chrome.storage.local.set({[SELECTION_KEY]: value}),
}, digest);
async function sessionDigest(cookies) {
  const rows = cookies
    .filter(cookie => claudeCookie(cookie) && SESSION_COOKIES.includes(cookie.name))
    .map(cookie => JSON.stringify([cookie.name, cookie.domain, cookie.path, cookie.storeId ?? null,
      cookie.partitionKey ?? null, cookie.value, cookie.session ? null : cookie.expirationDate ?? null]))
    .sort();
  return rows.length ? digest(rows.join('\n')) : null;
}
async function lastSave() {
  const stored = await chrome.storage.local.get(SAVED_SESSION_KEY).catch(() => ({}));
  return stored?.[SAVED_SESSION_KEY];
}
// `force` is for the popup's explicit save, which always captures and stores.
function saveCurrentSession({force = false} = {}) {
  sessionSaveInFlight ??= (async () => {
    try {
      lastSessionCheckedAt = Date.now();
      if (!force) {
        const current = await sessionDigest(await browser.cookies());
        // Signed out: nothing to save, and no probes or diagnostics every check.
        if (!current) return {ok: false, error: 'web_signed_out'};
        const saved = await lastSave();
        if (saved?.digest === current && Date.now() - saved.savedAt < MAX_SAVE_AGE_MS) {
          return {ok: true, unchanged: true};
        }
      }
      let entry;
      const result = await switcher.save(saved => { entry = saved; });
      lastSessionSavedAt = Date.now();
      knownStatus = {...knownStatus, email: result.email};
      // The digest of exactly what was stored: a renewal during the save differs.
      const stored = {digest: await sessionDigest(entry?.cookies ?? []), savedAt: lastSessionSavedAt};
      await chrome.storage.local.set({[SAVED_SESSION_KEY]: stored}).catch(() => {});
      // Notices a sign-in this companion did not make before any catch-up runs.
      const before = (await selections.current().catch(() => null))?.identity;
      const after = (await selections.observed(result.email).catch(() => null))?.identity;
      // A new login may be the one a Code switch is waiting for, e.g. after an expired login.
      if (after && after !== before) void runCatchUp({signedIn: true});
      return result;
    } catch (error) {
      report({error: 'session_save_failed', failureStep: 'save_session', ...probe.diagnostic});
      throw error;
    } finally {
      sessionSaveInFlight = null;
    }
  })();
  return sessionSaveInFlight;
}
// A selection made while this profile was closed, or one it failed to keep,
// takes effect when it reconnects. One the user overrode afterwards, by signing
// in to another account or by a Chrome-only switch, never does.
// `signedIn`: a new login was just saved here. When it is the account Code selected, this
// profile has finished that selection by hand, so the companion can call the switch done.
async function catchUp({signedIn = false} = {}) {
  const {email, selectedAt} = await native('pending_selection', {perProfile: true});
  if (!email || !Number.isFinite(selectedAt)) return;
  if (signedIn && await switcher.identity() === email) {
    await selections.switched(email, selectedAt);
    knownStatus = {...knownStatus, email};
    void native('browser_ready', {email, selectedAt}).catch(() => {});
    return;
  }
  if (selectedAt < (await selections.current()).appliedAt) return;
  // A sign-in since the last save counts too, even if that save failed.
  const current = await switcher.identity();
  if (current) await selections.observed(current);
  const {appliedAt} = await selections.current();
  if (selectedAt < appliedAt) return;
  // An equal stamp means this profile applied the selection once, then was rolled
  // back because another profile failed, or was signed out; a manual sign-in
  // would have moved appliedAt past it.
  if (current === email) {
    if (selectedAt > appliedAt) await selections.switched(email, selectedAt);
    return;
  }
  // A popup or menu switch queued while this ran wins: it changes the record.
  const before = await selections.current();
  const unchanged = async () => {
    const now = await selections.current();
    return now.appliedAt === before.appliedAt && now.identity === before.identity;
  };
  const result = await switcher.switchTo(email, null, Date.now() + CATCH_UP_MS, unchanged);
  if (!result.ok) {
    if (result.error !== 'selection_changed') report(result);
    // Try again at the next health check after a passing problem, such as Chrome starting
    // before the network; an expired or missing login needs the user instead.
    const transient = result.error === 'browser_timeout' ||
      ['network_error', 'rate_limited', 'server_error'].includes(result.probeStatus);
    if (transient) catchUpDue = true;
    return;
  }
  await selections.switched(email, selectedAt);
  knownStatus = {...knownStatus, email};
  void native('browser_ready', {email, selectedAt}).catch(() => {});
}
// One catch-up at a time. A plain request joins one already running; one after a
// sign-in waits its turn, so the new login is always checked.
let catchUpRun = null;
function runCatchUp(options = {}) {
  if (catchUpRun && !options.signedIn) return catchUpRun;
  const run = (catchUpRun ?? Promise.resolve()).then(async () => {
    catchUpDue = false;
    try {
      await catchUp(options);
    } catch {
      // For example, a switch was still running when this profile connected.
      catchUpDue = true;
    }
  });
  catchUpRun = run;
  void run.finally(() => { if (catchUpRun === run) catchUpRun = null; });
  return run;
}
// Chrome keeps running an unpacked extension's old code after the app updates its
// files. Reload once when the manifest on disk names another version, so nobody
// has to click Reload in chrome://extensions. At most once per RELOAD_RETRY_MS.
const RELOAD_KEY = 'updateReloadAt';
const RELOAD_RETRY_MS = 10 * 60 * 1000;
async function reloadIfUpdated() {
  if (switching() || incomingCommands || requests.size || officialFollower?.armed()) return false;
  let onDisk;
  try {
    const response = await fetch(chrome.runtime.getURL('manifest.json'), {cache: 'no-store'});
    onDisk = (await response.json()).version;
  } catch { return false; }
  if (typeof onDisk !== 'string' || onDisk === chrome.runtime.getManifest().version) return false;
  const stored = await chrome.storage.local.get(RELOAD_KEY).catch(() => ({}));
  if (Date.now() - (stored?.[RELOAD_KEY] ?? 0) < RELOAD_RETRY_MS) return false;
  await chrome.storage.local.set({[RELOAD_KEY]: Date.now()}).catch(() => {});
  chrome.runtime.reload();
  return true;
}
async function maintainConnection() {
  if(healthCheckRunning || popupSwitchInProgress || incomingCommands || requests.size)return;
  if (await reloadIfUpdated()) return;
  healthCheckRunning=true;
  const previous=port;
  try {
    await native('ping',{},5000);
    lastHealthCheckAt=Date.now();
    if (Date.now() - lastSessionCheckedAt >= SESSION_CHECK_MS) await saveCurrentSession().catch(() => {});
    if (catchUpDue) await runCatchUp();
  } catch {
    if(port===previous && previous && !popupSwitchInProgress && !incomingCommands && !requests.size) {
      port=null;
      previous.disconnect();
      connect();
    }
  } finally {healthCheckRunning=false;}
}
function switching() {
  return popupSwitchInProgress || commandSwitches > 0;
}
function statusExtras() {
  return {version: chrome.runtime.getManifest().version, lastHealthCheckAt, lastSessionSavedAt, lastSessionCheckedAt};
}
async function handleCommand(message) {
  if (message.command === 'switch') {
    if (popupSwitchInProgress) return {ok: false, error: 'switch_in_progress'};
    commandSwitches++;
    try {
      const result = await switcher.switchTo(message.email, null, message.expiresAt, null,
        {openLogin: message.openLogin === true});
      // Whatever the user signs in to next must not be undone by an older selection.
      if (result.loginOpened) await selections.manualLogin().catch(() => {});
      if (result.ok) {
        knownStatus = {...knownStatus, email: result.email};
        // Rollbacks carry no selectedAt and leave a missed selection pending.
        await selections.switched(result.email, message.selectedAt).catch(() => {});
      }
      return result;
    } finally {
      commandSwitches--;
    }
  }
  if (message.command === 'official_prepare') {
    if (switching()) return {ok: false, error: 'switch_in_progress'};
    return official().prepare(message.email);
  }
  // Only closes the window it opened and reports, so it may run during a switch.
  if (message.command === 'official_finish') return official().finish();
  // A status probe queued behind a running switch would miss the coordinator's
  // short wait and only report a login in flux. Answer with the committed state.
  if (switching()) {
    return {...statusExtras(), ok: true, busy: true, ...knownStatus};
  }
  const status = await switcher.status();
  knownStatus = {email: status.email, accounts: status.accounts, expiries: status.expiries ?? {}};
  return {...status, ...statusExtras()};
}
function connect() {
  if(port) return;
  try {
    const p=chrome.runtime.connectNative(HOST); port=p;
    p.onDisconnect.addListener(()=>{
      if(port!==p)return;
      connectionError=chrome.runtime.lastError?.message || 'Companion disconnected';
      port=null;
      for(const {reject,timeout} of requests.values()){clearTimeout(timeout);reject(failure('native_disconnected', 'Companion disconnected'));}
      requests.clear();
    });
    p.onMessage.addListener(async message=>{
      if(port!==p)return;
      if(message.type==='response'){
        const pending=requests.get(message.id); if(!pending)return;
        requests.delete(message.id);clearTimeout(pending.timeout);
        const result = message.result;
        if (result?.ok === false && !result.partial) {
          pending.reject(failure(result.error || 'unknown_error', result.message || result.error || 'Companion error'));
        } else {
          pending.resolve(result);
        }
      } else if(message.type==='command'){
        incomingCommands++;
        let result;
        try {
          result = await handleCommand(message);
        } catch {
          result = {ok: false, error: 'web_unavailable'};
        } finally {
          incomingCommands--;
        }
        if(result.ok===false)report(result);
        if(message.command==='switch' && result.ok)void saveCurrentSession().catch(()=>{});
        if(port===p)p.postMessage({type:'result',id:message.id,result});
      }
    });
    // Initial setup and manual re-logins are captured without another popup click.
    // The native vault only accepts the accounts configured in the menu app.
    void (async () => {
      await saveCurrentSession().catch(() => {});
      await runCatchUp();
    })();
  } catch { port=null; }
}
chrome.runtime.onMessage.addListener((msg,sender,send)=>{
  if(sender.id!==chrome.runtime.id) return false;
  const action=msg?.action;
  const selectBoth=async()=>{
    if(popupSwitchInProgress)return {ok:false,error:'switch_in_progress'};
    popupSwitchInProgress=true;
    try{
      let activation;
      const activateCode = async email => {
        activation = await native('select', {email, deadline: Date.now() + SELECT_BUDGET_MS}, SELECT_REPLY_MS);
        return activation;
      };
      const result=await switcher.switchTo(msg.email,activateCode);
      if (result.ok || result.partial) {
        knownStatus = {...knownStatus, email: result.email};
        // This profile already shows the selection; a reconnect must not re-apply it.
        await selections.switched(result.email, activation?.selectedAt).catch(() => {});
      }
      if(result.ok===false)report(result);
      if(result.ok || result.partial)void saveCurrentSession().catch(()=>{});
      return result;
    }
    finally{popupSwitchInProgress=false;}
  };
  const newLogin = async () => {
    // The account the user signs in to next must not be undone by an older selection.
    await selections.manualLogin().catch(() => {});
    return switcher.newLogin();
  };
  const work=action==='save'?saveCurrentSession({force: true}):action==='newLogin'?newLogin():action==='status'?switcher.status():action==='switch'?selectBoth():Promise.reject(failure('unknown_action', 'Unknown action'));
  // The popup maps `error`, always a code; `message` is only a fallback for people.
  work.then(result => send(result)).catch(error => send({ok: false, error: error?.code || 'unknown_error', message: error?.message}));
  return true;
});
let saveTimer;
chrome.cookies.onChanged.addListener(change=>{
  if(change.removed || !SESSION_COOKIES.includes(change.cookie.name) || !claudeCookie(change.cookie))return;
  // Bootstrap can renew cookies itself. Do not turn verification into another save loop.
  if(sessionSaveInFlight || probesInFlight || incomingCommands || popupSwitchInProgress)return;
  clearTimeout(saveTimer);
  saveTimer=setTimeout(()=>{void saveCurrentSession().catch(()=>{});},1500);
});
chrome.tabs?.onUpdated?.addListener((tabId, change, tab) => {
  if (officialFollower) void officialFollower.onTabUpdated(tabId, change, tab).catch(() => {});
});
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create('connect',{periodInMinutes:1});
chrome.alarms.onAlarm.addListener(()=>{void maintainConnection();});
connect();
