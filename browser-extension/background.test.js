import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

import {SessionSwitcher, identityFrom, claudeCookie, browserScopedCookie} from './session-core.js';

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

async function makeHarness({
  initialCookies = [sessionCookie('A')],
  entries = [savedSession('A'), savedSession('B'), savedSession('C')],
  pendingEmail = null,
  deferSelect = false,
} = {}) {
  let jar = clone(initialCookies);
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
        return {ok: true, email: pendingEmail};
      case 'select':
        return {ok: true, email: message.email};
      case 'browser_ready':
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

  const chrome = {
    alarms: {
      create() {},
      onAlarm: {addListener() {}},
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
      async update(id, details) {
        const tab = tabs.find(candidate => candidate.id === id);
        if (!tab) throw new Error('Unknown tab');
        Object.assign(tab, details);
        return clone(tab);
      },
    },
  };

  const fetch = async () => {
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
  const executable = source.replace(/^import \{SessionSwitcher, identityFrom, claudeCookie, browserScopedCookie\} from '\.\/session-core\.js';\n/, '');
  assert.notEqual(executable, source, 'background module import was removed for dependency injection');
  vm.runInNewContext(executable, {
    AbortSignal,
    SessionSwitcher,
    URL,
    chrome,
    claudeCookie,
    browserScopedCookie,
    clearTimeout,
    console,
    crypto: {randomUUID},
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
    nativeRequests,
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
