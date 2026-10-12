import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

import {SessionSwitcher, SelectionMemory, failure, identityFrom, claudeCookie, browserScopedCookie} from './session-core.js';
import {OfficialFollower, OFFICIAL_ID, OPTIONS_URL} from './official-extension.js';

const EMAIL = {
  A: 'a@example.com',
  B: 'b@example.com',
  C: 'c@example.com',
};
const BROWSER_COOKIE_NAMES = [
  '__cf_bm',
  '_cfuvid',
  'cf_clearance',
  'ion-vk',
  'anthropic-device-id',
];

// Real SHA-256 that settles as a microtask, so the harness flushes stay deterministic.
async function sha256(_algorithm, data) {
  return new Uint8Array(createHash('sha256').update(data).digest()).buffer;
}

function clone(value) {
  return value === undefined ? undefined : structuredClone(value);
}

function sessionCookie(value, overrides = {}) {
  return {
    domain: '.claude.ai',
    hostOnly: false,
    httpOnly: true,
    name: 'sessionKey',
    path: '/',
    sameSite: 'lax',
    secure: true,
    session: true,
    storeId: '0',
    value,
    ...overrides,
  };
}

function savedSession(key, overrides = {}) {
  return {
    email: EMAIL[key],
    cookies: [sessionCookie(key)],
    savedAt: 1,
    url: `https://claude.ai/${key.toLowerCase()}`,
    ...overrides,
  };
}

function browserCookies(version) {
  return BROWSER_COOKIE_NAMES.map(name => sessionCookie(`${version}:${name}`, {name}));
}

function browserCookieValues(cookies) {
  return Object.fromEntries(cookies
    .filter(cookie => BROWSER_COOKIE_NAMES.includes(cookie.name))
    .map(cookie => [cookie.name, cookie.value]));
}

function cookieFromSetDetails(details) {
  const hostname = new URL(details.url).hostname;
  return {
    domain: details.domain ?? hostname,
    hostOnly: details.domain === undefined,
    httpOnly: Boolean(details.httpOnly),
    name: details.name,
    path: details.path ?? '/',
    sameSite: details.sameSite ?? 'unspecified',
    secure: Boolean(details.secure),
    session: details.expirationDate === undefined,
    storeId: details.storeId,
    value: details.value,
    ...(details.expirationDate === undefined ? {} : {expirationDate: details.expirationDate}),
    ...(details.partitionKey === undefined ? {} : {partitionKey: clone(details.partitionKey)}),
  };
}

// Unix seconds, like the companion's selectedAt stamps.
const nowSeconds = () => Date.now() / 1000;

// `storage` is shared between harnesses to model the service worker restarting.
// The default is an installed profile that has never applied a selection.
async function makeHarness({
  initialCookies = [sessionCookie('A')],
  entries = [savedSession('A'), savedSession('B'), savedSession('C')],
  pendingEmail = null,
  pendingSelectedAt = nowSeconds() - 60,
  pendingResults = null,
  selectResult = null,
  nativeOverrides = {},
  storage = {selection: {appliedAt: 0, identity: null}},
  deferSelect = false,
  official = null,
  diskVersion = undefined,
} = {}) {
  const reloads = [];
  let jar = clone(initialCookies);
  const alarmListeners = [];
  const vault = new Map(entries.map(entry => [entry.email, clone(entry)]));
  const tabs = [{id: 1, url: 'https://claude.ai/chat', lastAccessed: 1}];
  const nativeRequests = [];
  const nativeResults = [];
  const actionWaiters = new Map();
  const resultWaiters = new Map();
  const deferredRequests = new Map();
  const portMessageListeners = [];
  const runtimeMessageListeners = [];

  function notify(waiters, key, value) {
    const listeners = waiters.get(key) ?? [];
    waiters.delete(key);
    for (const resolve of listeners) resolve(value);
  }

  function waitFor(waiters, values, key, predicate) {
    const existing = values.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise(resolve => {
      const listeners = waiters.get(key) ?? [];
      listeners.push(resolve);
      waiters.set(key, listeners);
    });
  }

  function emitPortMessage(message) {
    for (const listener of portMessageListeners) listener(message);
  }

  function nativeResult(message) {
    if (message.action in nativeOverrides) return clone(nativeOverrides[message.action]);
    switch (message.action) {
      case 'diagnostic':
        return {ok: true};
      case 'vault_get':
        return {ok: true, entry: clone(vault.get(message.email))};
      case 'vault_put':
        vault.set(message.entry.email, clone(message.entry));
        return {ok: true};
      case 'vault_list':
        return {ok: true, accounts: [...vault.values()].map(clone)};
      case 'pending_selection':
        if (pendingResults?.length) return pendingResults.shift();
        return {ok: true, email: pendingEmail, selectedAt: pendingEmail ? pendingSelectedAt : null};
      case 'select':
        return selectResult ?? {ok: true, email: message.email};
      case 'browser_ready':
      case 'ping':
        return {ok: true};
      default:
        throw new Error(`Unexpected native action: ${message.action}`);
    }
  }

  function respond(message, result = nativeResult(message)) {
    queueMicrotask(() => emitPortMessage({type: 'response', id: message.id, result}));
  }

  const port = {
    onDisconnect: {addListener() {}},
    onMessage: {addListener(listener) { portMessageListeners.push(listener); }},
    postMessage(message) {
      if (message.type === 'request') {
        nativeRequests.push(clone(message));
        notify(actionWaiters, message.action, message);
        if (deferSelect && message.action === 'select') deferredRequests.set(message.id, message);
        else respond(message);
        return;
      }
      if (message.type === 'result') {
        nativeResults.push(clone(message));
        notify(resultWaiters, message.id, message);
      }
    },
  };

  const officialCalls = [];
  const tabListeners = [];
  const chrome = {
    management: {
      async get(id) {
        officialCalls.push(['get', id]);
        if (!official) throw new Error(`Failed to find extension with id ${id}`);
        return clone(official);
      },
      async setEnabled(id, enabled) { officialCalls.push(['setEnabled', id, enabled]); official.enabled = enabled; },
    },
    windows: {
      async create(details) { officialCalls.push(['createWindow', clone(details)]); return {id: 77, tabs: [{id: 78}]}; },
      async remove(id) { officialCalls.push(['removeWindow', id]); },
    },
    scripting: {
      async executeScript(details) { officialCalls.push(['executeScript', details.target.tabId, details.args]); return [{result: 'clicked'}]; },
    },
    alarms: {
      create() {},
      onAlarm: {addListener(listener) { alarmListeners.push(listener); }},
    },
    storage: {
      local: {
        async get(key) { return key in storage ? {[key]: clone(storage[key])} : {}; },
        async set(values) { Object.assign(storage, clone(values)); },
      },
    },
    cookies: {
      async getAll() { return clone(jar); },
      async remove(details) {
        const index = jar.findIndex(cookie => cookie.name === details.name && cookie.storeId === details.storeId);
        if (index < 0) return null;
        const [removed] = jar.splice(index, 1);
        return clone(removed);
      },
      async set(details) {
        jar = jar.filter(cookie => !(cookie.name === details.name && cookie.storeId === details.storeId));
        const cookie = cookieFromSetDetails(details);
        jar.push(cookie);
        return clone(cookie);
      },
      onChanged: {addListener() {}},
    },
    runtime: {
      id: 'background-test-extension',
      lastError: null,
      connectNative() { return port; },
      getManifest() { return {version: '0.7.1'}; },
      ...(diskVersion === undefined ? {} : {getURL: path => `chrome-extension://background-test-extension/${path}`}),
      reload() { reloads.push(Date.now()); },
      onInstalled: {addListener() {}},
      onMessage: {addListener(listener) { runtimeMessageListeners.push(listener); }},
      onStartup: {addListener() {}},
    },
    tabs: {
      async create(details) {
        const tab = {id: tabs.length + 1, url: details.url, lastAccessed: tabs.length + 1};
        tabs.push(tab);
        return clone(tab);
      },
      async query() { return clone(tabs); },
      onUpdated: {addListener(listener) { tabListeners.push(listener); }},
      async remove(id) { officialCalls.push(['removeTab', id]); },
      async reload(id) { officialCalls.push(['reloadTab', id]); },
      async update(id, details) {
        const tab = tabs.find(candidate => candidate.id === id);
        if (!tab) throw new Error('Unknown tab');
        Object.assign(tab, details);
        return clone(tab);
      },
    },
  };

  const fetch = async url => {
    if (String(url).endsWith('/manifest.json')) return {ok: true, async json() { return {version: diskVersion}; }};
    const key = jar.find(cookie => cookie.name === 'sessionKey')?.value;
    const email = EMAIL[key] ?? null;
    return {
      ok: true,
      async json() {
        return email ? {current_account: {email_address: email}} : {current_account: null};
      },
    };
  };

  const source = await readFile(new URL('./background.js', import.meta.url), 'utf8');
  const executable = source.replace(/^import \{[^}]+\} from '\.\/session-core\.js'; import \{OfficialFollower\} from '\.\/official-extension\.js';\n/, '');
  assert.notEqual(executable, source, 'background module import was removed for dependency injection');
  vm.runInNewContext(executable, {
    AbortSignal,
    SessionSwitcher,
    SelectionMemory,
    OfficialFollower,
    TextEncoder,
    failure,
    URL,
    chrome,
    claudeCookie,
    browserScopedCookie,
    clearTimeout,
    console,
    crypto: {randomUUID, subtle: {digest: sha256}},
    fetch,
    identityFrom,
    queueMicrotask,
    setTimeout,
  }, {filename: 'background.js'});

  return {
    currentEmail() {
      const key = jar.find(cookie => cookie.name === 'sessionKey')?.value;
      return EMAIL[key] ?? null;
    },
    jar: () => clone(jar),
    officialCalls,
    reloads,
    official: () => official,
    async tabUpdated(tabId, change, tab) {
      for (const listener of tabListeners) listener(tabId, change, tab);
      for (let i = 0; i < 20; i++) await new Promise(resolve => setImmediate(resolve));
    },
    storage,
    nativeRequests,
    requested(action) {
      return nativeRequests.filter(message => message.action === action);
    },
    async alarm() {
      for (const listener of alarmListeners) listener();
      for (let i = 0; i < 20; i++) await new Promise(resolve => setImmediate(resolve));
    },
    async settle() {
      for (let i = 0; i < 20; i++) await new Promise(resolve => setImmediate(resolve));
    },
    tabs,
    async flush() {
      await new Promise(resolve => setImmediate(resolve));
    },
    waitForNative(action) {
      return waitFor(actionWaiters, nativeRequests, action, message => message.action === action);
    },
    waitForResult(id) {
      return waitFor(resultWaiters, nativeResults, id, message => message.id === id);
    },
    resolveDeferred(action, result) {
      const message = [...deferredRequests.values()].find(candidate => candidate.action === action);
      assert.ok(message, `a deferred ${action} request exists`);
      deferredRequests.delete(message.id);
      respond(message, result ?? nativeResult(message));
    },
    sendMenu(message) {
      emitPortMessage({type: 'command', ...message});
      return this.waitForResult(message.id);
    },
    sendPopup(message) {
      assert.equal(runtimeMessageListeners.length, 1);
      return new Promise(resolve => {
        const keptOpen = runtimeMessageListeners[0](message, {id: chrome.runtime.id}, resolve);
        assert.equal(keptOpen, true);
      });
    },
  };
}

test('a deferred popup Code selection keeps an incoming menu switch busy', async () => {
  const harness = await makeHarness({deferSelect: true});
  await harness.waitForNative('pending_selection');
  await harness.flush();

  const popup = harness.sendPopup({action: 'switch', email: EMAIL.B});
  await harness.waitForNative('select');
  assert.equal(harness.currentEmail(), EMAIL.B);

  const menu = await harness.sendMenu({id: 'menu-switch', command: 'switch', email: EMAIL.C});
  assert.deepEqual(clone(menu.result), {ok: false, error: 'switch_in_progress'});
  assert.equal(harness.currentEmail(), EMAIL.B);

  harness.resolveDeferred('select');
  assert.deepEqual(clone(await popup), {ok: true, email: EMAIL.B});
  assert.equal(harness.currentEmail(), EMAIL.B);
});

const sha256Hex = text => createHash('sha256').update(text).digest('hex');

test('a profile closed during a switch catches up once when it opens', async () => {
  const storage = {selection: {appliedAt: nowSeconds() - 600, identity: sha256Hex(EMAIL.A)}};
  const selectedAt = nowSeconds() - 60;
  const opened = await makeHarness({pendingEmail: EMAIL.B, pendingSelectedAt: selectedAt, storage});
  const ready = await opened.waitForNative('browser_ready');
  assert.equal(opened.requested('pending_selection')[0].perProfile, true);
  assert.equal(ready.selectedAt, selectedAt);
  assert.equal(opened.currentEmail(), EMAIL.B);
  await opened.settle();
  assert.deepEqual(storage.selection, {appliedAt: selectedAt, identity: sha256Hex(EMAIL.B)});

  const restarted = await makeHarness({initialCookies: opened.jar(), pendingEmail: EMAIL.B, pendingSelectedAt: selectedAt, storage});
  await restarted.waitForNative('pending_selection');
  await restarted.settle();
  assert.equal(restarted.requested('vault_get').length, 0);
  assert.equal(restarted.requested('browser_ready').length, 0);
});

test('every profile catches up on its own; one catching up does not hide it from another', async () => {
  const selectedAt = nowSeconds() - 60;
  for (const profile of ['first', 'second']) {
    const storage = {selection: {appliedAt: nowSeconds() - 600, identity: sha256Hex(EMAIL.A)}};
    const harness = await makeHarness({pendingEmail: EMAIL.B, pendingSelectedAt: selectedAt, storage});
    await harness.waitForNative('browser_ready');
    assert.equal(harness.currentEmail(), EMAIL.B, `${profile} profile switched`);
  }
});

test('a first run adopts no earlier selection', async () => {
  const storage = {};
  const harness = await makeHarness({pendingEmail: EMAIL.B, pendingSelectedAt: nowSeconds() - 60, storage});
  await harness.waitForNative('pending_selection');
  await harness.settle();
  assert.equal(harness.currentEmail(), EMAIL.A);
  assert.equal(harness.requested('vault_get').length, 0);
  assert.ok(storage.selection.appliedAt > nowSeconds() - 60);
});

test('a manual sign-in in this profile is not undone by an older selection', async () => {
  const storage = {selection: {appliedAt: nowSeconds() - 600, identity: sha256Hex(EMAIL.A)}};
  // The user signed in to C here after the last selection.
  const harness = await makeHarness({
    initialCookies: [sessionCookie('C')], pendingEmail: EMAIL.B, pendingSelectedAt: nowSeconds() - 60, storage,
  });
  await harness.waitForNative('pending_selection');
  await harness.settle();
  assert.equal(harness.currentEmail(), EMAIL.C);
  assert.equal(harness.requested('vault_get').length, 0);
  assert.equal(storage.selection.identity, sha256Hex(EMAIL.C));
});

test('"Add another account" keeps the next sign-in; a newer selection still applies', async () => {
  const storage = {selection: {appliedAt: nowSeconds() - 600, identity: sha256Hex(EMAIL.A)}};
  const before = await makeHarness({storage});
  await before.waitForNative('pending_selection');
  await before.settle();
  assert.deepEqual(clone(await before.sendPopup({action: 'newLogin'})), {ok: true});
  const signedInAt = storage.selection.appliedAt;
  assert.equal(storage.selection.identity, null);

  // The user signs in to C, then Chrome restarts.
  const older = await makeHarness({
    initialCookies: [sessionCookie('C')], pendingEmail: EMAIL.B, pendingSelectedAt: signedInAt - 1, storage,
  });
  await older.waitForNative('pending_selection');
  await older.settle();
  assert.equal(older.currentEmail(), EMAIL.C);
  assert.equal(older.requested('vault_get').length, 0);

  const newer = await makeHarness({
    initialCookies: [sessionCookie('C')], pendingEmail: EMAIL.B, pendingSelectedAt: signedInAt + 1, storage,
  });
  await newer.waitForNative('browser_ready');
  assert.equal(newer.currentEmail(), EMAIL.B);
});

test('a menu switch records its selection; a rollback leaves it to catch up later', async () => {
  const storage = {selection: {appliedAt: 5, identity: null}};
  const harness = await makeHarness({storage});
  await harness.waitForNative('pending_selection');
  await harness.settle();
  const selectedAt = nowSeconds() - 30;

  await harness.sendMenu({id: 'forward', command: 'switch', email: EMAIL.B, selectedAt});
  assert.deepEqual(storage.selection, {appliedAt: selectedAt, identity: sha256Hex(EMAIL.B)});
  // Another profile failed, so the coordinator restored this one without a stamp.
  await harness.sendMenu({id: 'rollback', command: 'switch', email: EMAIL.A});
  assert.deepEqual(storage.selection, {appliedAt: selectedAt, identity: sha256Hex(EMAIL.A)});

  const reconnected = await makeHarness({
    initialCookies: harness.jar(), pendingEmail: EMAIL.B, pendingSelectedAt: selectedAt, storage,
  });
  await reconnected.waitForNative('browser_ready');
  assert.equal(reconnected.currentEmail(), EMAIL.B);
});

test('a popup selection records the stamp the companion returns', async () => {
  const storage = {selection: {appliedAt: 5, identity: null}};
  const harness = await makeHarness({storage, selectResult: {ok: true, email: EMAIL.B, codeEmail: EMAIL.B, selectedAt: 42.5}});
  await harness.waitForNative('pending_selection');
  await harness.settle();
  await harness.sendPopup({action: 'switch', email: EMAIL.B});
  await harness.settle();
  assert.deepEqual(storage.selection, {appliedAt: 42.5, identity: sha256Hex(EMAIL.B)});
});

test('a selection deferred by a running switch is retried on the next alarm', async () => {
  const selectedAt = nowSeconds() - 60;
  const harness = await makeHarness({
    pendingEmail: EMAIL.B, pendingSelectedAt: selectedAt,
    pendingResults: [{ok: false, error: 'switch_in_progress'}],
  });
  await harness.waitForNative('pending_selection');
  await harness.settle();
  assert.equal(harness.currentEmail(), EMAIL.A);

  await harness.alarm();
  await harness.waitForNative('browser_ready');
  assert.equal(harness.requested('pending_selection').length, 2);
  assert.equal(harness.currentEmail(), EMAIL.B);
});

test('status reports saved login expiries, also while a switch is running', async () => {
  const expiries = {[EMAIL.A]: 1_900_000_000, [EMAIL.B]: 1_900_000_500};
  const harness = await makeHarness({
    deferSelect: true,
    nativeOverrides: {vault_list: {ok: true, accounts: [EMAIL.A, EMAIL.B], expiries}},
  });
  await harness.waitForNative('pending_selection');
  await harness.settle();
  const status = await harness.sendMenu({id: 'status-expiries', command: 'status'});
  assert.deepEqual(clone(status.result.expiries), expiries);
  assert.deepEqual(clone(status.result.accounts), [EMAIL.A, EMAIL.B]);

  const popup = harness.sendPopup({action: 'switch', email: EMAIL.B});
  await harness.waitForNative('select');
  const busy = await harness.sendMenu({id: 'status-busy', command: 'status'});
  assert.equal(busy.result.busy, true);
  assert.deepEqual(clone(busy.result.expiries), expiries);
  harness.resolveDeferred('select');
  await popup;
});

test('popup failures carry a code in error and readable text only in message', async () => {
  const signedOut = await makeHarness({initialCookies: []});
  await signedOut.waitForNative('pending_selection');
  await signedOut.settle();
  assert.deepEqual(clone(await signedOut.sendPopup({action: 'save'})), {
    ok: false, error: 'web_signed_out', message: 'Sign in to Claude.ai, then save this account',
  });
  assert.deepEqual(clone(await signedOut.sendPopup({action: 'export'})), {
    ok: false, error: 'unknown_action', message: 'Unknown action',
  });

  const locked = await makeHarness({nativeOverrides: {
    vault_put: {ok: false, error: 'keychain_unavailable', message: 'Unlock your Keychain and try again.'},
  }});
  await locked.waitForNative('pending_selection');
  await locked.settle();
  assert.deepEqual(clone(await locked.sendPopup({action: 'save'})), {
    ok: false, error: 'keychain_unavailable', message: 'Unlock your Keychain and try again.',
  });
});

test('a popup selection gives the companion a deadline shorter than its own wait', async () => {
  const harness = await makeHarness();
  await harness.waitForNative('pending_selection');
  await harness.flush();

  const before = Date.now();
  assert.deepEqual(clone(await harness.sendPopup({action: 'switch', email: EMAIL.B})), {ok: true, email: EMAIL.B});
  const select = harness.nativeRequests.find(message => message.action === 'select');
  assert.equal(select.email, EMAIL.B);
  assert.ok(select.deadline >= before + 150_000 && select.deadline <= Date.now() + 150_000,
    'the companion must finish 30 s before the popup stops waiting at 180 s');
});

test('a status request during a popup switch answers at once with the committed login', async () => {
  const harness = await makeHarness({deferSelect: true});
  await harness.waitForNative('pending_selection');
  await harness.flush();

  const popup = harness.sendPopup({action: 'switch', email: EMAIL.B});
  await harness.waitForNative('select');
  const status = await harness.sendMenu({id: 'menu-status', command: 'status'});
  assert.equal(status.result.ok, true);
  assert.equal(status.result.busy, true);
  assert.equal(status.result.email, EMAIL.A);
  assert.equal(status.result.version, '0.7.1');

  harness.resolveDeferred('select');
  assert.deepEqual(clone(await popup), {ok: true, email: EMAIL.B});
  const after = await harness.sendMenu({id: 'menu-status-after', command: 'status'});
  assert.equal(after.result.busy, undefined);
  assert.equal(after.result.email, EMAIL.B);
});

test('reconnect saves the current browser account before restoring and acknowledging a pending selection', async () => {
  const harness = await makeHarness({pendingEmail: EMAIL.B});
  const ready = await harness.waitForNative('browser_ready');
  await harness.flush();

  const actions = harness.nativeRequests.map(message => message.action);
  const firstSave = actions.indexOf('vault_put');
  const pending = actions.indexOf('pending_selection');
  const restore = actions.indexOf('vault_get');
  const acknowledged = actions.indexOf('browser_ready');
  assert.ok(firstSave >= 0 && pending > firstSave, 'current browser account was saved before pending selection lookup');
  assert.ok(restore > pending && acknowledged > restore, 'pending target was restored before browser_ready');
  assert.equal(ready.email, EMAIL.B);
  assert.equal(harness.currentEmail(), EMAIL.B);
  assert.equal(harness.tabs[0].url, 'https://claude.ai/b');
});

test('a menu switch preserves live browser-scoped cookies over stale saved versions', async () => {
  const liveBrowserCookies = browserCookies('LIVE');
  const staleBrowserCookies = browserCookies('OLD');
  const harness = await makeHarness({
    initialCookies: [sessionCookie('A'), ...liveBrowserCookies],
    entries: [
      savedSession('A'),
      savedSession('B', {cookies: [sessionCookie('B'), ...staleBrowserCookies]}),
    ],
  });
  await harness.waitForNative('pending_selection');
  await harness.flush();

  const menu = await harness.sendMenu({id: 'browser-cookie-switch', command: 'switch', email: EMAIL.B});

  assert.deepEqual(clone(menu.result), {ok: true, email: EMAIL.B});
  assert.equal(harness.currentEmail(), EMAIL.B);
  assert.deepEqual(browserCookieValues(harness.jar()), browserCookieValues(liveBrowserCookies));
});

test('a failed popup selection rolls back identity without replacing live browser-scoped cookies', async () => {
  const liveBrowserCookies = browserCookies('LIVE');
  const staleBrowserCookies = browserCookies('OLD');
  const harness = await makeHarness({
    initialCookies: [sessionCookie('A'), ...liveBrowserCookies],
    entries: [
      savedSession('A'),
      savedSession('B', {cookies: [sessionCookie('B'), ...staleBrowserCookies]}),
    ],
    deferSelect: true,
  });
  await harness.waitForNative('pending_selection');
  await harness.flush();

  const popup = harness.sendPopup({action: 'switch', email: EMAIL.B});
  await harness.waitForNative('select');
  assert.equal(harness.currentEmail(), EMAIL.B);

  harness.resolveDeferred('select', {ok: false, error: 'code account unavailable'});
  assert.deepEqual(clone(await popup), {
    ok: false,
    error: 'code_switch_failed',
    email: EMAIL.B, failureStep: 'activate_code',
  });
  assert.equal(harness.currentEmail(), EMAIL.A);
  assert.deepEqual(browserCookieValues(harness.jar()), browserCookieValues(liveBrowserCookies));
});

test('newLogin clears account cookies while preserving live browser-scoped cookies', async () => {
  const liveBrowserCookies = browserCookies('LIVE');
  const harness = await makeHarness({
    initialCookies: [sessionCookie('A'), ...liveBrowserCookies],
  });
  await harness.waitForNative('pending_selection');
  await harness.flush();

  assert.deepEqual(clone(await harness.sendPopup({action: 'newLogin'})), {ok: true});
  assert.equal(harness.currentEmail(), null);
  assert.deepEqual(browserCookieValues(harness.jar()), browserCookieValues(liveBrowserCookies));
  assert.equal(harness.tabs[0].url, 'https://claude.ai/login');
});

for (const [state, target] of [
  ['missing', null],
  ['expired', savedSession('B', {cookies: [sessionCookie('B', {session: false, expirationDate: 1})]})],
]) {
  const article = state === 'expired' ? 'an' : 'a';
  test(`${article} ${state} pending target preserves current cookies without browser_ready`, async () => {
    const current = [sessionCookie('A'), sessionCookie('dark', {name: 'preference', value: 'dark'})];
    const entries = [savedSession('A'), ...(target ? [target] : [])];
    const harness = await makeHarness({initialCookies: current, entries, pendingEmail: EMAIL.B});
    await harness.waitForNative('vault_get');
    await harness.flush();

    assert.deepEqual(harness.jar(), current);
    assert.equal(harness.currentEmail(), EMAIL.A);
    assert.equal(harness.nativeRequests.some(message => message.action === 'browser_ready'), false);
  });
}

const AUTHORIZE_URL = 'https://claude.ai/oauth/authorize?' + new URLSearchParams({
  client_id: 'dae2cad8-15c5-43d2-9046-fcaecc135fa4',
  redirect_uri: `chrome-extension://${OFFICIAL_ID}/oauth_callback.html`,
  response_type: 'code',
});

test('official commands report a missing extension and a different Claude.ai account', async () => {
  const harness = await makeHarness();
  await harness.waitForNative('pending_selection');
  await harness.flush();
  const missing = await harness.sendMenu({id: 'o1', command: 'official_prepare', email: EMAIL.A});
  assert.deepEqual(clone(missing.result), {ok: true, state: 'not_installed'});
  const other = await harness.sendMenu({id: 'o2', command: 'official_prepare', email: EMAIL.B});
  assert.deepEqual(clone(other.result), {ok: false, error: 'web_identity_mismatch'});
  const finish = await harness.sendMenu({id: 'o3', command: 'official_finish'});
  assert.deepEqual(clone(finish.result), {ok: true, authorized: false, consent: 'none'});
});

test('official prepare waits for a running switch', async () => {
  const harness = await makeHarness({deferSelect: true, official: {id: OFFICIAL_ID, enabled: true}});
  await harness.waitForNative('pending_selection');
  await harness.flush();
  const popup = harness.sendPopup({action: 'switch', email: EMAIL.B});
  await harness.waitForNative('select');
  const busy = await harness.sendMenu({id: 'o4', command: 'official_prepare', email: EMAIL.B});
  assert.deepEqual(clone(busy.result), {ok: false, error: 'switch_in_progress'});
  assert.deepEqual(harness.officialCalls, []);
  harness.resolveDeferred('select');
  await popup;
});

test('official prepare cycles the extension, opens its options and authorizes only its own consent page', async () => {
  const harness = await makeHarness({official: {id: OFFICIAL_ID, enabled: true}});
  await harness.waitForNative('pending_selection');
  await harness.flush();
  const prepared = await harness.sendMenu({id: 'o5', command: 'official_prepare', email: EMAIL.A});
  assert.deepEqual(clone(prepared.result), {ok: true, state: 'opened', windowId: 77});
  assert.deepEqual(harness.officialCalls, [
    ['get', OFFICIAL_ID],
    ['setEnabled', OFFICIAL_ID, false],
    ['setEnabled', OFFICIAL_ID, true],
    ['createWindow', {url: OPTIONS_URL, focused: false, type: 'normal', width: 900, height: 760}],
  ]);
  harness.officialCalls.length = 0;
  await harness.tabUpdated(9, {status: 'complete'}, {id: 9, url: AUTHORIZE_URL.replace('dae2cad8', 'aaaaaaaa')});
  assert.deepEqual(harness.officialCalls, []);
  await harness.tabUpdated(9, {status: 'complete'}, {id: 9, url: AUTHORIZE_URL});
  assert.deepEqual(harness.officialCalls, [['executeScript', 9, [EMAIL.A]]]);
  await harness.tabUpdated(9, {url: 'https://claude.ai/chrome/installed'}, {id: 9, url: 'https://claude.ai/chrome/installed'});
  assert.deepEqual(harness.officialCalls.slice(1), [['removeTab', 9], ['reloadTab', 78]]);
  const finish = await harness.sendMenu({id: 'o6', command: 'official_finish'});
  assert.deepEqual(clone(finish.result), {ok: true, authorized: true, consent: 'clicked'});
  assert.deepEqual(harness.officialCalls.at(-1), ['removeWindow', 77]);
});

test('the companion reloads itself once when the app installed a newer version', async () => {
  const storage = {selection: {appliedAt: 0, identity: null}};
  const harness = await makeHarness({diskVersion: '0.9.1', storage});
  await harness.waitForNative('pending_selection');
  await harness.settle();
  await harness.alarm();
  assert.equal(harness.reloads.length, 1);
  assert.equal(typeof storage.updateReloadAt, 'number');
  // A reload that did not take is not retried every minute.
  await harness.alarm();
  assert.equal(harness.reloads.length, 1);
});

test('the companion does not reload when the files on disk match the running version', async () => {
  const harness = await makeHarness({diskVersion: '0.7.1'});
  await harness.waitForNative('pending_selection');
  await harness.settle();
  await harness.alarm();
  assert.equal(harness.reloads.length, 0);
  assert.ok(harness.requested('ping').length >= 1);
});
