import test from 'node:test';
import assert from 'node:assert/strict';

import {installAccountLink, protocol, silentSwitch} from './account-link.js';

const COMPANION_ID = 'hlldhcbaknomojegdfceljiepokkhcll';
const REDIRECT = `https://${COMPANION_ID}.chromiumapp.org/callback`;
const UUID_A = '11111111-1111-4111-8111-111111111111';
const UUID_B = '22222222-2222-4222-8222-222222222222';
const UUID_C = '33333333-3333-4333-8333-333333333333';
const EMAIL_B = 'target@example.com';

const identity = (email = EMAIL_B, uuid = UUID_B) => ({email, uuid});

function makeChrome({launch} = {}) {
  const calls = {launch: []};
  let listener;
  const chromeAPI = {
    identity: {
      getRedirectURL: () => REDIRECT,
      launchWebAuthFlow: async options => {
        calls.launch.push(options);
        if (launch) return launch(options);
        const state = new URL(options.url).searchParams.get('state');
        return `${REDIRECT}?code=authorization-code&state=${state}`;
      },
    },
    runtime: {
      onMessageExternal: {
        addListener: value => { listener = value; },
      },
    },
  };
  return {chromeAPI, calls, listener: () => listener};
}

function makeOAuth(overrides = {}) {
  const calls = {
    challenge: [], exchange: [], verify: [], invalidate: 0, commit: [], epoch: 0,
  };
  const order = [];
  let randomIndex = 0;
  const oauth = {
    epoch: () => { calls.epoch += 1; return 7; },
    config: () => ({
      AUTHORIZE_URL: 'https://console.anthropic.com/v1/oauth/authorize',
      CLIENT_ID: 'client-id',
      SCOPES_STR: 'user:profile user:inference',
    }),
    random: () => ['state-value', 'verifier-value'][randomIndex++],
    challenge: async verifier => {
      calls.challenge.push(verifier);
      return 'challenge-value';
    },
    exchange: async (...args) => {
      calls.exchange.push(args);
      return {success: true, accountUuid: UUID_B, accessToken: 'access-token', refreshToken: 'refresh-token'};
    },
    verify: async token => { calls.verify.push(token); return UUID_B; },
    invalidate: () => { calls.invalidate += 1; order.push('invalidate'); return 8; },
    commit: async (...args) => { calls.commit.push(args); order.push('commit'); return true; },
    ...overrides,
  };
  return {oauth, calls, order};
}

function dispatch(listener, message, sender = {id: COMPANION_ID}) {
  let wasSent = false;
  let resolveResponse;
  const response = new Promise(resolve => { resolveResponse = resolve; });
  const keepOpen = listener(message, sender, value => {
    wasSent = true;
    resolveResponse(value);
  });
  return {keepOpen, response, wasSent: () => wasSent};
}

async function expectCode(promise, code) {
  await assert.rejects(promise, error => {
    assert.equal(error.message, code);
    return true;
  });
}

test('successful follow uses the account-link protocol and completes target OAuth before commit', async () => {
  const chrome = makeChrome();
  const auth = makeOAuth();
  let account = UUID_A;
  const afterSwitchCalls = [];
  installAccountLink({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    currentAccount: async () => account,
    afterSwitch: async (previous, next) => {
      afterSwitchCalls.push([previous, next]);
      account = next;
    },
    web: async () => identity(),
    now: () => 1_000,
  });

  assert.equal(protocol, 'paperfoot-account-link-v1');
  const result = dispatch(chrome.listener(), {
    protocol,
    action: 'follow',
    email: EMAIL_B,
    expiresAt: 121_000,
  });
  assert.equal(result.keepOpen, true);
  assert.deepEqual(await result.response, {ok: true, email: EMAIL_B, accountUUID: UUID_B});

  assert.equal(chrome.calls.launch.length, 1);
  assert.deepEqual(chrome.calls.launch[0], {
    url: chrome.calls.launch[0].url,
    interactive: false,
    abortOnLoadForNonInteractive: false,
    timeoutMsForNonInteractive: 15000,
  });
  const authorize = new URL(chrome.calls.launch[0].url);
  assert.equal(authorize.origin + authorize.pathname, 'https://console.anthropic.com/v1/oauth/authorize');
  assert.equal(authorize.searchParams.get('client_id'), 'client-id');
  assert.equal(authorize.searchParams.get('response_type'), 'code');
  assert.equal(authorize.searchParams.get('scope'), 'user:profile user:inference');
  assert.equal(authorize.searchParams.get('redirect_uri'), REDIRECT);
  assert.equal(authorize.searchParams.get('state'), 'state-value');
  assert.equal(authorize.searchParams.get('code_challenge'), 'challenge-value');
  assert.equal(authorize.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(authorize.searchParams.get('prompt'), 'none');
  assert.equal(authorize.searchParams.get('login_hint'), UUID_B);
  assert.deepEqual(auth.calls.challenge, ['verifier-value']);
  assert.deepEqual(auth.calls.exchange, [[
    'authorization-code',
    'state-value',
    'verifier-value',
    {
      AUTHORIZE_URL: 'https://console.anthropic.com/v1/oauth/authorize',
      CLIENT_ID: 'client-id',
      SCOPES_STR: 'user:profile user:inference',
      REDIRECT_URI: REDIRECT,
    },
  ]]);
  assert.deepEqual(auth.calls.verify, ['access-token']);
  assert.deepEqual(auth.order, ['invalidate', 'commit']);
  assert.equal(auth.calls.commit[0][1], 'state-value');
  assert.equal(auth.calls.commit[0][2], 8);
  assert.deepEqual(afterSwitchCalls, [[UUID_A, UUID_B]]);
});

test('status reports the protocol and current account', async () => {
  const chrome = makeChrome();
  installAccountLink({
    chromeAPI: chrome.chromeAPI,
    oauth: makeOAuth().oauth,
    currentAccount: async () => UUID_A,
    afterSwitch: async () => {},
  });
  const result = dispatch(chrome.listener(), {protocol, action: 'status'});
  assert.equal(result.keepOpen, true);
  assert.deepEqual(await result.response, {
    ok: true, protocol, accountUUID: UUID_A, busy: false,
  });
});

test('website, other extensions, and wrong protocols cannot invoke the adapter', () => {
  const chrome = makeChrome();
  let currentAccountCalls = 0;
  installAccountLink({
    chromeAPI: chrome.chromeAPI,
    oauth: makeOAuth().oauth,
    currentAccount: async () => { currentAccountCalls += 1; return UUID_A; },
    afterSwitch: async () => {},
  });

  const website = dispatch(chrome.listener(), {protocol, action: 'status'}, {url: 'https://claude.ai/'});
  const extension = dispatch(chrome.listener(), {protocol, action: 'status'}, {id: 'another-extension'});
  const wrongProtocol = dispatch(chrome.listener(), {protocol: 'paperfoot-account-link-v0', action: 'status'});
  for (const result of [website, extension, wrongProtocol]) {
    assert.equal(result.keepOpen, false);
    assert.equal(result.wasSent(), false);
  }
  assert.equal(currentAccountCalls, 0);
});

test('a matching account is idempotent and does not authorize, invalidate, commit, or switch', async () => {
  const chrome = makeChrome({launch: async () => { throw new Error('must not launch'); }});
  const auth = makeOAuth();
  let afterSwitchCalls = 0;
  installAccountLink({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    currentAccount: async () => UUID_B,
    afterSwitch: async () => { afterSwitchCalls += 1; },
    web: async () => identity(),
    now: () => 1_000,
  });

  const result = dispatch(chrome.listener(), {
    protocol, action: 'follow', email: EMAIL_B, expiresAt: 121_000,
  });
  assert.deepEqual(await result.response, {ok: true, email: EMAIL_B, accountUUID: UUID_B});
  assert.equal(chrome.calls.launch.length, 0);
  assert.equal(auth.calls.invalidate, 0);
  assert.equal(auth.calls.commit.length, 0);
  assert.equal(afterSwitchCalls, 0);
});

test('a wrong web identity is rejected before OAuth starts', async () => {
  const chrome = makeChrome();
  const auth = makeOAuth();
  let afterSwitchCalls = 0;
  installAccountLink({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    currentAccount: async () => UUID_A,
    afterSwitch: async () => { afterSwitchCalls += 1; },
    web: async () => identity('other@example.com'),
    now: () => 1_000,
  });

  const result = dispatch(chrome.listener(), {
    protocol, action: 'follow', email: EMAIL_B, expiresAt: 121_000,
  });
  assert.deepEqual(await result.response, {ok: false, error: 'web_identity_mismatch'});
  assert.equal(chrome.calls.launch.length, 0);
  assert.equal(auth.calls.invalidate, 0);
  assert.equal(auth.calls.commit.length, 0);
  assert.equal(afterSwitchCalls, 0);
});

test('a token response for another account UUID is rejected before profile verification', async () => {
  const chrome = makeChrome();
  const auth = makeOAuth({
    exchange: async (...args) => {
      auth.calls.exchange.push(args);
      return {success: true, accountUuid: UUID_C, accessToken: 'access-token'};
    },
  });
  await expectCode(silentSwitch({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    web: async () => identity(),
    email: EMAIL_B,
    expiresAt: 2_000,
    now: () => 1_000,
  }), 'extension_identity_mismatch');
  assert.deepEqual(auth.calls.verify, []);
  assert.equal(auth.calls.invalidate, 0);
  assert.equal(auth.calls.commit.length, 0);
});

test('an OAuth profile mismatch is rejected without replacing auth', async () => {
  const chrome = makeChrome();
  const auth = makeOAuth({verify: async token => {
    auth.calls.verify.push(token);
    return UUID_C;
  }});
  await expectCode(silentSwitch({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    web: async () => identity(),
    email: EMAIL_B,
    expiresAt: 2_000,
    now: () => 1_000,
  }), 'extension_identity_mismatch');
  assert.deepEqual(auth.calls.verify, ['access-token']);
  assert.equal(auth.calls.invalidate, 0);
  assert.equal(auth.calls.commit.length, 0);
});

for (const [name, callback] of [
  ['origin', () => 'https://attacker.example/callback?code=x&state=state-value'],
  ['path', () => `https://${COMPANION_ID}.chromiumapp.org/other?code=x&state=state-value`],
  ['state', () => `${REDIRECT}?code=x&state=wrong-state`],
]) {
  test(`a callback ${name} mismatch is rejected before code exchange`, async () => {
    const chrome = makeChrome({launch: async () => callback()});
    const auth = makeOAuth();
    await expectCode(silentSwitch({
      chromeAPI: chrome.chromeAPI,
      oauth: auth.oauth,
      web: async () => identity(),
      email: EMAIL_B,
      expiresAt: 2_000,
      now: () => 1_000,
    }), 'invalid_callback');
    assert.equal(auth.calls.exchange.length, 0);
    assert.equal(auth.calls.invalidate, 0);
    assert.equal(auth.calls.commit.length, 0);
  });
}

test('consent-required authorization preserves the previous auth', async () => {
  const chrome = makeChrome({launch: async () => { throw new Error('interaction required'); }});
  const auth = makeOAuth();
  let account = UUID_A;
  let afterSwitchCalls = 0;
  installAccountLink({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    currentAccount: async () => account,
    afterSwitch: async () => { afterSwitchCalls += 1; account = UUID_B; },
    web: async () => identity(),
    now: () => 1_000,
  });
  const result = dispatch(chrome.listener(), {
    protocol, action: 'follow', email: EMAIL_B, expiresAt: 121_000,
  });
  assert.deepEqual(await result.response, {ok: false, error: 'authorization_needed'});
  assert.equal(account, UUID_A);
  assert.equal(auth.calls.invalidate, 0);
  assert.equal(auth.calls.commit.length, 0);
  assert.equal(afterSwitchCalls, 0);
});

test('an expired request is rejected synchronously before account or web reads', () => {
  const chrome = makeChrome();
  let reads = 0;
  installAccountLink({
    chromeAPI: chrome.chromeAPI,
    oauth: makeOAuth().oauth,
    currentAccount: async () => { reads += 1; return UUID_A; },
    afterSwitch: async () => {},
    web: async () => { reads += 1; return identity(); },
    now: () => 1_000,
  });
  const result = dispatch(chrome.listener(), {
    protocol, action: 'follow', email: EMAIL_B, expiresAt: 1_000,
  });
  assert.equal(result.keepOpen, false);
  assert.equal(result.wasSent(), true);
  assert.equal(reads, 0);
});

test('a deadline reached during OAuth prevents invalidation and commit', async () => {
  const chrome = makeChrome();
  let time = 1_000;
  const auth = makeOAuth({verify: async token => {
    auth.calls.verify.push(token);
    time = 2_000;
    return UUID_B;
  }});
  await expectCode(silentSwitch({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    web: async () => identity(),
    email: EMAIL_B,
    expiresAt: 2_000,
    now: () => time,
  }), 'switch_expired');
  assert.equal(auth.calls.invalidate, 0);
  assert.equal(auth.calls.commit.length, 0);
});

test('a changed web identity before commit preserves current auth', async () => {
  const chrome = makeChrome();
  const auth = makeOAuth();
  let reads = 0;
  const web = async () => {
    reads += 1;
    return reads < 3 ? identity() : identity(EMAIL_B, UUID_C);
  };
  await expectCode(silentSwitch({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    web,
    email: EMAIL_B,
    expiresAt: 2_000,
    now: () => 1_000,
  }), 'web_identity_changed');
  assert.equal(auth.calls.invalidate, 0);
  assert.equal(auth.calls.commit.length, 0);
});

test('a superseded auth epoch cannot invalidate or commit', async () => {
  const chrome = makeChrome();
  const epochs = [7, 8];
  const auth = makeOAuth({epoch: () => {
    auth.calls.epoch += 1;
    return epochs.shift();
  }});
  await expectCode(silentSwitch({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    web: async () => identity(),
    email: EMAIL_B,
    expiresAt: 2_000,
    now: () => 1_000,
  }), 'authorization_superseded');
  assert.equal(auth.calls.epoch, 2);
  assert.equal(auth.calls.invalidate, 0);
  assert.equal(auth.calls.commit.length, 0);
});

test('invalidation happens before commit and its epoch is passed to commit', async () => {
  const chrome = makeChrome();
  const auth = makeOAuth();
  await silentSwitch({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    web: async () => identity(),
    email: EMAIL_B,
    expiresAt: 2_000,
    now: () => 1_000,
  });
  assert.deepEqual(auth.order, ['invalidate', 'commit']);
  assert.equal(auth.calls.invalidate, 1);
  assert.equal(auth.calls.commit.length, 1);
  assert.equal(auth.calls.commit[0][2], 8);
});

test('a concurrent follow request is rejected while the first remains in progress', async () => {
  const chrome = makeChrome();
  const auth = makeOAuth();
  let releaseAccount;
  const accountGate = new Promise(resolve => { releaseAccount = resolve; });
  let accountCalls = 0;
  installAccountLink({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    currentAccount: async () => {
      accountCalls += 1;
      if (accountCalls === 1) await accountGate;
      return UUID_B;
    },
    afterSwitch: async () => {},
    web: async () => identity(),
    now: () => 1_000,
  });
  const request = {protocol, action: 'follow', email: EMAIL_B, expiresAt: 121_000};
  const first = dispatch(chrome.listener(), request);
  const second = dispatch(chrome.listener(), request);
  assert.equal(second.keepOpen, false);
  assert.deepEqual(await second.response, {ok: false, error: 'switch_in_progress'});
  releaseAccount();
  assert.deepEqual(await first.response, {ok: true, email: EMAIL_B, accountUUID: UUID_B});
  assert.equal(chrome.calls.launch.length, 0);
});

test('unexpected OAuth errors are sanitized and never expose token material', async () => {
  const secret = 'sk-ant-secret-token-material';
  const chrome = makeChrome();
  const auth = makeOAuth({commit: async (...args) => {
    auth.calls.commit.push(args);
    throw new Error(`provider failure for ${secret}`);
  }});
  installAccountLink({
    chromeAPI: chrome.chromeAPI,
    oauth: auth.oauth,
    currentAccount: async () => UUID_A,
    afterSwitch: async () => {},
    web: async () => identity(),
    now: () => 1_000,
  });
  const result = dispatch(chrome.listener(), {
    protocol, action: 'follow', email: EMAIL_B, expiresAt: 121_000,
  });
  const response = await result.response;
  assert.deepEqual(response, {ok: false, error: 'extension_unavailable'});
  assert.equal(JSON.stringify(response).includes(secret), false);
});
