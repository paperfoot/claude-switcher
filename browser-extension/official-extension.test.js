import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ARM_MS,
  OFFICIAL_CLIENT_ID,
  OFFICIAL_ID,
  OFFICIAL_REDIRECT,
  OPTIONS_URL,
  OfficialFollower,
  authorizeOnPage,
  installedURL,
  officialAuthorizeURL,
} from './official-extension.js';

const EMAIL = 'a@example.com';

function authorizeURL(overrides = {}) {
  const params = {client_id: OFFICIAL_CLIENT_ID, redirect_uri: OFFICIAL_REDIRECT, response_type: 'code', state: 's', ...overrides};
  return `https://claude.ai/oauth/authorize?${new URLSearchParams(params)}`;
}

function rig({installed = true, enabled = true, identity = EMAIL, failEnable = false, script = 'clicked'} = {}) {
  const calls = [];
  const clock = {now: 1_000};
  const extension = installed ? {id: OFFICIAL_ID, enabled} : null;
  const follower = new OfficialFollower({
    management: {
      async get(id) {
        calls.push(['get', id]);
        if (!extension) throw new Error('Failed to find extension');
        return {...extension};
      },
      async setEnabled(id, value) {
        calls.push(['setEnabled', id, value]);
        if (failEnable && value) { failEnable = false; throw new Error('blocked'); }
        extension.enabled = value;
      },
    },
    windows: {
      async create(details) { calls.push(['create', details]); return {id: 5, tabs: [{id: 6}]}; },
      async remove(id) { calls.push(['removeWindow', id]); },
    },
    tabs: {
      async remove(id) { calls.push(['removeTab', id]); },
      async reload(id) { calls.push(['reload', id]); },
    },
    scripting: {
      async executeScript(details) {
        calls.push(['inject', details.target.tabId, details.world, details.func, details.args]);
        if (script instanceof Error) throw script;
        return [{result: script}];
      },
    },
    identity: async () => identity,
    now: () => clock.now,
    sleep: async ms => { calls.push(['sleep', ms]); },
  });
  return {follower, calls, clock, extension};
}

test('only the official extension consent URL is recognised', () => {
  assert.equal(officialAuthorizeURL(authorizeURL()), true);
  assert.equal(officialAuthorizeURL(authorizeURL({client_id: 'other'})), false);
  assert.equal(officialAuthorizeURL(authorizeURL({redirect_uri: 'https://evil.example/cb'})), false);
  assert.equal(officialAuthorizeURL(authorizeURL().replace('https://claude.ai', 'https://claude.ai.evil.example')), false);
  assert.equal(officialAuthorizeURL(authorizeURL().replace('https:', 'http:')), false);
  assert.equal(officialAuthorizeURL(authorizeURL().replace('/oauth/authorize', '/oauth/authorize2')), false);
  assert.equal(officialAuthorizeURL('not a url'), false);
  assert.equal(officialAuthorizeURL(undefined), false);
  assert.equal(installedURL('https://claude.ai/chrome/installed'), true);
  assert.equal(installedURL('https://claude.ai/chrome/installed?x=1'), true);
  assert.equal(installedURL('https://claude.ai/chrome/installedx'), false);
  assert.equal(installedURL('https://evil.example/chrome/installed'), false);
});

test('prepare refuses a profile whose Claude.ai account differs', async () => {
  const {follower, calls} = rig({identity: 'b@example.com'});
  assert.deepEqual(await follower.prepare(EMAIL), {ok: false, error: 'web_identity_mismatch'});
  assert.deepEqual(calls, []);
  assert.deepEqual(await rig({identity: null}).follower.prepare(EMAIL), {ok: false, error: 'web_identity_mismatch'});
});

test('prepare compares emails without case and reports a missing or disabled extension', async () => {
  assert.deepEqual(await rig({installed: false}).follower.prepare(EMAIL), {ok: true, state: 'not_installed'});
  const disabled = rig({enabled: false, identity: 'A@Example.com'});
  assert.deepEqual(await disabled.follower.prepare(EMAIL), {ok: true, state: 'disabled'});
  assert.deepEqual(disabled.calls, [['get', OFFICIAL_ID]]);
  assert.equal(disabled.follower.armed(), null);
});

test('prepare cycles the extension, then opens its options page unfocused', async () => {
  const {follower, calls} = rig();
  assert.deepEqual(await follower.prepare(EMAIL), {ok: true, state: 'opened', windowId: 5});
  assert.deepEqual(calls, [
    ['get', OFFICIAL_ID],
    ['setEnabled', OFFICIAL_ID, false],
    ['setEnabled', OFFICIAL_ID, true],
    ['sleep', 1500],
    ['create', {url: OPTIONS_URL, focused: false, type: 'normal', width: 900, height: 760}],
  ]);
  assert.deepEqual(await follower.prepare(EMAIL), {ok: false, error: 'switch_in_progress'});
});

test('an expired arm neither blocks a new prepare nor acts on tabs', async () => {
  const {follower, calls, clock} = rig();
  await follower.prepare(EMAIL);
  clock.now += ARM_MS;
  calls.length = 0;
  await follower.onTabUpdated(9, {status: 'complete'}, {url: authorizeURL()});
  assert.deepEqual(calls, []);
  assert.deepEqual((await follower.prepare(EMAIL)).state, 'opened');
});

test('a failed re-enable switches the extension back on and disarms', async () => {
  const {follower, calls, extension} = rig({failEnable: true});
  assert.deepEqual(await follower.prepare(EMAIL), {ok: false, error: 'official_unavailable'});
  assert.deepEqual(calls.slice(1), [
    ['setEnabled', OFFICIAL_ID, false],
    ['setEnabled', OFFICIAL_ID, true],
    ['setEnabled', OFFICIAL_ID, true],
  ]);
  assert.equal(extension.enabled, true);
  assert.equal(follower.armed(), null);
});

test('nothing happens to tabs while unarmed or for other OAuth clients', async () => {
  const {follower, calls} = rig();
  await follower.onTabUpdated(9, {status: 'complete'}, {url: authorizeURL()});
  await follower.onTabUpdated(9, {url: 'https://claude.ai/chrome/installed'}, {url: 'https://claude.ai/chrome/installed'});
  assert.deepEqual(calls, []);
  await follower.prepare(EMAIL);
  calls.length = 0;
  await follower.onTabUpdated(9, {status: 'complete'}, {url: authorizeURL({client_id: 'someone-else'})});
  await follower.onTabUpdated(9, {status: 'loading'}, {url: authorizeURL()});
  assert.deepEqual(calls, []);
});

test('the consent page is checked and clicked once, then success closes it and reloads the options page', async () => {
  const {follower, calls} = rig();
  await follower.prepare(EMAIL);
  calls.length = 0;
  await follower.onTabUpdated(9, {status: 'complete'}, {url: authorizeURL()});
  await follower.onTabUpdated(9, {status: 'complete'}, {url: authorizeURL()});
  assert.deepEqual(calls, [['inject', 9, 'ISOLATED', authorizeOnPage, [EMAIL]]]);
  await follower.onTabUpdated(9, {url: 'https://claude.ai/chrome/installed'}, {url: 'https://claude.ai/chrome/installed'});
  assert.deepEqual(calls.slice(1), [['removeTab', 9], ['reload', 6]]);
  assert.deepEqual(await follower.finish(), {ok: true, authorized: true, consent: 'clicked'});
  assert.deepEqual(calls.at(-1), ['removeWindow', 5]);
  assert.deepEqual(await follower.finish(), {ok: true, authorized: false, consent: 'none'});
});

test('a sign-in that needs no consent is reported as skipped', async () => {
  const {follower} = rig();
  await follower.prepare(EMAIL);
  await follower.onTabUpdated(9, {url: 'https://claude.ai/chrome/installed'}, {url: 'https://claude.ai/chrome/installed'});
  assert.deepEqual(await follower.finish(), {ok: true, authorized: true, consent: 'skipped'});
});

test('a refused or failed consent check is reported without authorizing', async () => {
  for (const script of ['refused', new Error('tab closed')]) {
    const {follower} = rig({script});
    await follower.prepare(EMAIL);
    await follower.onTabUpdated(9, {status: 'complete'}, {url: authorizeURL()});
    assert.deepEqual(await follower.finish(), {ok: true, authorized: false, consent: 'refused'});
  }
});

function fakePage(text, buttons) {
  const elements = buttons.map(label => ({textContent: ` ${label} `, disabled: false, clicks: 0, click() { this.clicks++; }}));
  globalThis.document = {body: {innerText: text}, querySelectorAll: () => elements};
  return elements;
}

test('the page check clicks the only Authorize button for the expected account', async () => {
  const [authorize, decline] = fakePage('Claude for Chrome would like to connect\nLogged in as\nA@example.com\nSwitch account', ['Authorize', 'Decline']);
  assert.equal(await authorizeOnPage(EMAIL, 0), 'clicked');
  assert.equal(authorize.clicks, 1);
  assert.equal(decline.clicks, 0);
});

test('the page check refuses another account, even one ending in the expected email', async () => {
  const [authorize] = fakePage('Logged in as xa@example.com Switch account', ['Authorize']);
  assert.equal(await authorizeOnPage(EMAIL, 0), 'refused');
  fakePage('Logged in as b@example.com', ['Authorize']);
  assert.equal(await authorizeOnPage(EMAIL, 0), 'refused');
  assert.equal(authorize.clicks, 0);
});

test('the page check refuses two Authorize buttons and gives up when nothing renders', async () => {
  const buttons = fakePage(`Logged in as ${EMAIL}`, ['Authorize', 'Authorize']);
  assert.equal(await authorizeOnPage(EMAIL, 0), 'refused');
  assert.equal(buttons.some(button => button.clicks), false);
  fakePage('Loading', []);
  assert.equal(await authorizeOnPage(EMAIL, 0), 'refused');
});

test('the page check waits for the consent page to render', async () => {
  fakePage('Loading', []);
  const later = setTimeout(() => fakePage(`Logged in as ${EMAIL}`, ['Authorize']), 50);
  assert.equal(await authorizeOnPage(EMAIL, 2000), 'clicked');
  clearTimeout(later);
  delete globalThis.document;
});
