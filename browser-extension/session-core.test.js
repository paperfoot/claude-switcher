import test from 'node:test';
import assert from 'node:assert/strict';

import {
  SessionSwitcher,
  emailKey,
  cookieDetails,
  identityFrom,
  validSession,
} from './session-core.js';

const EMAIL = {
  A: 'a@example.com',
  B: 'b@example.com',
  C: 'c@example.com',
};

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

function clone(value) {
  return structuredClone(value);
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

function makeRig({
  initialCookies = [sessionCookie('A')],
  entries = [savedSession('A'), savedSession('B'), savedSession('C')],
  identityForKey = {A: EMAIL.A, B: EMAIL.B, C: EMAIL.C},
  probe: probeOverride,
  onSet,
} = {}) {
  let jar = clone(initialCookies);
  let url = 'https://claude.ai/chat';
  const events = [];
  const values = new Map(entries.map(entry => [emailKey(entry.email), clone(entry)]));

  const browser = {
    async cookies() {
      events.push('browser:cookies');
      return clone(jar);
    },
    async clear() {
      events.push('browser:clear');
      jar = jar.filter(cookie => !String(cookie.domain).replace(/^\./, '').endsWith('claude.ai'));
    },
    async set(details) {
      events.push(`browser:set:${details.value}`);
      if (details.expirationDate !== undefined && details.expirationDate <= Date.now() / 1000) return null;
      if (onSet && !await onSet(details, events)) return false;
      jar = jar.filter(cookie => !(cookie.name === details.name && cookie.storeId === details.storeId));
      jar.push(cookieFromSetDetails(details));
      return true;
    },
    async currentURL() {
      events.push('browser:currentURL');
      return url;
    },
    async refresh(nextURL) {
      events.push(`browser:refresh:${nextURL}`);
      url = nextURL;
    },
  };

  const vault = {
    async get(email) {
      events.push(`vault:get:${email}`);
      const entry = values.get(email);
      return entry && clone(entry);
    },
    async put(entry) {
      events.push(`vault:put:${entry.email}`);
      values.set(emailKey(entry.email), clone(entry));
    },
    async list() {
      events.push('vault:list');
      return [...values.values()].map(clone);
    },
  };

  let probeCalls = 0;
  const probe = async () => {
    probeCalls += 1;
    const sessionKey = jar.find(cookie => cookie.name === 'sessionKey')?.value;
    const identity = probeOverride
      ? await probeOverride({call: probeCalls, jar: clone(jar), sessionKey})
      : identityForKey[sessionKey] ?? null;
    events.push(`probe:${identity}`);
    return identity;
  };

  return {
    browser,
    events,
    jar: () => clone(jar),
    probe,
    switcher: new SessionSwitcher(browser, vault, probe),
    values,
    vault,
  };
}

test('helpers normalize account identity and recognize a live Claude session', () => {
  assert.equal(emailKey('A@EXAMPLE.COM'), EMAIL.A);
  assert.equal(identityFrom({current_account: {email_address: 'B@EXAMPLE.COM'}}), EMAIL.B);
  assert.equal(validSession([sessionCookie('A')]), true);
  assert.equal(validSession([sessionCookie('A', {session: false, expirationDate: 20})], 20), false);
  assert.equal(validSession([sessionCookie('A', {session: false, expirationDate: 10})], 20), false);
});

test('successful switch restores B, verifies B, then refreshes', async () => {
  const rig = makeRig();

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B), {ok: true, email: EMAIL.B});
  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'B');

  const verified = rig.events.lastIndexOf(`probe:${EMAIL.B}`);
  const refreshed = rig.events.indexOf('browser:refresh:https://claude.ai/b');
  assert.ok(verified >= 0, 'target identity was probed');
  assert.ok(refreshed > verified, 'refresh happened only after target identity verification');
});

test('successful switch runs the code switch after browser verification and before refresh', async () => {
  const rig = makeRig();
  const activateCode = async email => {
    rig.events.push(`code:switch:${email}`);
    return {ok: true};
  };

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B, activateCode), {
    ok: true,
    email: EMAIL.B,
  });

  const verified = rig.events.lastIndexOf(`probe:${EMAIL.B}`);
  const codeSwitched = rig.events.indexOf(`code:switch:${EMAIL.B}`);
  const refreshed = rig.events.indexOf('browser:refresh:https://claude.ai/b');
  assert.ok(codeSwitched > verified, 'code switch ran after the target browser identity was verified');
  assert.ok(refreshed > codeSwitched, 'browser refresh ran after the code switch completed');
});

test('a manually changed C session is saved under C and never overwrites A', async () => {
  const originalA = savedSession('A', {savedAt: 12345, url: 'https://claude.ai/original-a'});
  const rig = makeRig({initialCookies: [sessionCookie('C')], entries: [originalA, savedSession('B')]});

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B), {ok: true, email: EMAIL.B});
  assert.deepEqual(rig.values.get(EMAIL.A), originalA);
  assert.equal(rig.values.get(EMAIL.C).cookies[0].value, 'C');
  assert.ok(rig.events.includes(`vault:put:${EMAIL.C}`));
  assert.ok(!rig.events.includes(`vault:put:${EMAIL.A}`));
});

test('a missing target leaves the live cookie jar untouched', async () => {
  const initial = [sessionCookie('A'), sessionCookie('preference', {name: 'preference', value: 'dark'})];
  const rig = makeRig({initialCookies: initial, entries: [savedSession('A')]});

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B), {
    ok: false,
    error: 'web_login_needed',
    email: EMAIL.B,
  });
  assert.deepEqual(rig.jar(), initial);
  assert.equal(rig.events.includes('browser:clear'), false);
  assert.equal(rig.events.some(event => event.startsWith('browser:set:')), false);
});

test('an expired target leaves the live cookie jar untouched', async () => {
  const initial = [sessionCookie('A')];
  const expiredB = savedSession('B', {
    cookies: [sessionCookie('B', {session: false, expirationDate: 1})],
  });
  const rig = makeRig({initialCookies: initial, entries: [savedSession('A'), expiredB]});

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B), {
    ok: false,
    error: 'web_login_expired',
    email: EMAIL.B,
  });
  assert.deepEqual(rig.jar(), initial);
  assert.equal(rig.events.includes('browser:clear'), false);
  assert.equal(rig.events.some(event => event.startsWith('browser:set:')), false);
});

test('an expired auxiliary target cookie is ignored while restoring a valid session', async t => {
  t.mock.method(Date, 'now', () => 20_000);
  const expiredAuxiliary = sessionCookie('expired-target-auxiliary', {
    name: '__cf_bm',
    session: false,
    expirationDate: 10,
  });
  const target = savedSession('B', {
    cookies: [sessionCookie('B'), expiredAuxiliary],
  });
  const rig = makeRig({entries: [savedSession('A'), target]});

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B), {ok: true, email: EMAIL.B});
  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'B');
  assert.equal(rig.jar().some(cookie => cookie.name === '__cf_bm'), false);
  assert.equal(rig.events.includes('browser:set:expired-target-auxiliary'), false);
});

test('a target cookie set failure restores A and reports switch failure', async () => {
  let failedTarget = false;
  const rig = makeRig({
    onSet(details) {
      if (details.value === 'B' && !failedTarget) {
        failedTarget = true;
        return false;
      }
      return true;
    },
  });

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B), {
    ok: false,
    error: 'web_switch_failed',
    email: EMAIL.B, failureStep: 'restore_cookies', cookieName: 'sessionKey',
  });
  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'A');
  assert.equal(rig.events.filter(event => event === 'browser:clear').length, 2);
  assert.equal(rig.events.includes(`probe:${EMAIL.A}`), true);
});

test('a restored identity mismatch restores A and reports switch failure', async () => {
  const rig = makeRig({identityForKey: {A: EMAIL.A, B: EMAIL.C, C: EMAIL.C}});

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B), {
    ok: false,
    error: 'web_switch_failed',
    email: EMAIL.B, failureStep: 'verify_identity', probeStatus: 'identity_mismatch',
  });
  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'A');
  assert.ok(rig.events.includes(`probe:${EMAIL.C}`));
  assert.equal(rig.events.some(event => event.startsWith('browser:refresh:')), false);
});

test('cookie failure diagnostics include the cookie name but never its value or exception', async () => {
  const privateValue='private-cookie-value';
  const rig=makeRig({entries:[savedSession('A'),savedSession('B',{cookies:[sessionCookie(privateValue)]})],
    onSet(details){if(details.value===privateValue)throw new Error('private exception '+privateValue);return true;}});
  const result=await rig.switcher.switchTo(EMAIL.B);
  assert.deepEqual(result,{ok:false,error:'web_switch_failed',email:EMAIL.B,
    failureStep:'restore_cookies',cookieName:'sessionKey'});
  assert.equal(JSON.stringify(result).includes(privateValue),false);
  assert.equal(await rig.probe(),EMAIL.A);
});

test('a thrown code switch failure restores A and reports code_switch_failed', async () => {
  const rig = makeRig();

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B, async email => {
    rig.events.push(`code:switch:${email}`);
    throw new Error('code account unavailable');
  }), {
    ok: false,
    error: 'code_switch_failed',
    email: EMAIL.B, failureStep: 'activate_code',
  });

  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'A');
  assert.ok(rig.events.indexOf(`code:switch:${EMAIL.B}`) > rig.events.indexOf(`probe:${EMAIL.B}`));
  assert.equal(rig.events.filter(event => event === 'browser:clear').length, 2);
  assert.equal(rig.events.includes(`probe:${EMAIL.A}`), true);
  assert.equal(rig.events.some(event => event.startsWith('browser:refresh:')), false);
});

test('rollback ignores an expired auxiliary cookie while restoring the previous identity', async t => {
  t.mock.method(Date, 'now', () => 20_000);
  const expiredAuxiliary = sessionCookie('expired-previous-auxiliary', {
    name: '__cf_bm',
    session: false,
    expirationDate: 10,
  });
  const rig = makeRig({initialCookies: [sessionCookie('A'), expiredAuxiliary]});

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B, async () => ({ok: false})), {
    ok: false,
    error: 'code_switch_failed',
    email: EMAIL.B, failureStep: 'activate_code',
  });

  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'A');
  assert.equal(await rig.probe(), EMAIL.A);
  assert.equal(rig.jar().some(cookie => cookie.name === '__cf_bm'), false);
  assert.equal(rig.events.includes('browser:set:expired-previous-auxiliary'), false);
});

test('an explicit code switch failure restores a signed-out browser state', async () => {
  const signedOutCookies = [sessionCookie('dark', {name: 'preference', value: 'dark'})];
  const rig = makeRig({initialCookies: signedOutCookies});

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B, async email => {
    rig.events.push(`code:switch:${email}`);
    return {ok: false};
  }), {
    ok: false,
    error: 'code_switch_failed',
    email: EMAIL.B, failureStep: 'activate_code',
  });

  assert.deepEqual(rig.jar(), signedOutCookies);
  assert.equal(rig.events.filter(event => event === 'browser:clear').length, 2);
  assert.equal(rig.events.some(event => event.startsWith('browser:refresh:')), false);
});

test('a code switch failure reports web_restore_failed when browser rollback fails', async () => {
  const rig = makeRig({
    onSet(details) {
      return details.value !== 'A';
    },
  });

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B, async email => {
    rig.events.push(`code:switch:${email}`);
    return {ok: false};
  }), {
    ok: false,
    error: 'web_restore_failed',
    email: EMAIL.B, failureStep: 'activate_code',
  });

  assert.equal(rig.events.includes(`code:switch:${EMAIL.B}`), true);
  assert.equal(rig.events.includes('browser:set:A'), true);
  assert.equal(rig.events.some(event => event.startsWith('browser:refresh:')), false);
});

test('a same-account switch still runs the code switch without changing browser cookies', async () => {
  const rig = makeRig();

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.A, async email => {
    rig.events.push(`code:switch:${email}`);
    return {ok: false};
  }), {
    ok: false,
    error: 'code_switch_failed',
    email: EMAIL.A,
  });

  assert.equal(rig.events.includes(`code:switch:${EMAIL.A}`), true);
  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'A');
  assert.equal(rig.events.includes('browser:clear'), false);
  assert.equal(rig.events.some(event => event.startsWith('browser:set:')), false);
});

test('a rollback failure is reported explicitly as web_restore_failed', async () => {
  const rig = makeRig({onSet: () => false});

  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B), {
    ok: false,
    error: 'web_restore_failed',
    email: EMAIL.B, failureStep: 'restore_cookies', cookieName: 'sessionKey',
  });
  assert.equal(rig.events.filter(event => event === 'browser:clear').length, 2);
  assert.equal(rig.events.includes('browser:set:B'), true);
  assert.equal(rig.events.includes('browser:set:A'), true);
});

test('concurrent switches are serialized from B through C', async () => {
  const rig = makeRig({onSet: async () => Promise.resolve(true)});

  const [toB, toC] = await Promise.all([
    rig.switcher.switchTo(EMAIL.B),
    rig.switcher.switchTo(EMAIL.C),
  ]);

  assert.deepEqual(toB, {ok: true, email: EMAIL.B});
  assert.deepEqual(toC, {ok: true, email: EMAIL.C});
  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'C');
  const refreshedB = rig.events.indexOf('browser:refresh:https://claude.ai/b');
  const beganC = rig.events.indexOf(`vault:get:${EMAIL.C}`);
  const refreshedC = rig.events.indexOf('browser:refresh:https://claude.ai/c');
  assert.ok(refreshedB >= 0 && beganC > refreshedB, 'C did not begin before B completed');
  assert.ok(refreshedC > beganC, 'C completed after it began');
});

test('a queued switch cannot change the browser while the active code switch is pending', async () => {
  const rig = makeRig();
  let enterCodeSwitch;
  let finishCodeSwitch;
  const codeSwitchEntered = new Promise(resolve => { enterCodeSwitch = resolve; });
  const codeSwitchFinished = new Promise(resolve => { finishCodeSwitch = resolve; });

  const toB = rig.switcher.switchTo(EMAIL.B, async email => {
    rig.events.push(`code:start:${email}`);
    enterCodeSwitch();
    await codeSwitchFinished;
    rig.events.push(`code:finish:${email}`);
    return {ok: true};
  });
  const toC = rig.switcher.switchTo(EMAIL.C, async email => {
    rig.events.push(`code:start:${email}`);
    return {ok: true};
  });

  await codeSwitchEntered;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'B');
  assert.equal(rig.events.filter(event => event === 'browser:clear').length, 1);
  assert.equal(rig.events.includes('browser:set:C'), false);

  finishCodeSwitch();
  assert.deepEqual(await toB, {ok: true, email: EMAIL.B});
  assert.deepEqual(await toC, {ok: true, email: EMAIL.C});
  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'C');
  assert.ok(
    rig.events.indexOf(`code:start:${EMAIL.C}`) > rig.events.indexOf(`code:finish:${EMAIL.B}`),
    'the queued switch started after the active code switch completed',
  );
});

test('a non-Claude target cookie is rejected before the live jar is cleared', async () => {
  const unsafeTarget = savedSession('B', {
    cookies: [sessionCookie('B'), sessionCookie('secret', {
      domain: '.example.com',
      name: 'secret',
      value: 'do-not-set',
    })],
  });
  const rig = makeRig({entries: [savedSession('A'), unsafeTarget]});

  await assert.rejects(rig.switcher.switchTo(EMAIL.B), /Invalid saved cookie/);
  assert.equal(rig.events.includes('browser:clear'), false);
  assert.equal(rig.jar().find(cookie => cookie.name === 'sessionKey')?.value, 'A');
});

test('cookieDetails preserves host-only semantics, httpOnly, and partitionKey', () => {
  const partitionKey = {topLevelSite: 'https://claude.ai', hasCrossSiteAncestor: false};
  const hostOnly = cookieDetails(sessionCookie('A', {
    domain: 'claude.ai',
    hostOnly: true,
    partitionKey,
  }));
  assert.equal(Object.hasOwn(hostOnly, 'domain'), false);
  assert.equal(hostOnly.httpOnly, true);
  assert.deepEqual(hostOnly.partitionKey, partitionKey);

  const domainCookie = cookieDetails(sessionCookie('B', {domain: '.claude.ai', hostOnly: false}));
  assert.equal(domainCookie.domain, '.claude.ai');
});

test('an identity race during initial capture is not saved', async () => {
  const rig = makeRig({
    entries: [],
    probe: ({call}) => call === 1 ? EMAIL.A : EMAIL.B,
  });

  await assert.rejects(rig.switcher.save(), /Account changed while saving/);
  assert.equal(rig.values.size, 0);
  assert.equal(rig.events.some(event => event.startsWith('vault:put:')), false);
});

test('adding another account saves the actual session before clearing locally', async () => {
  const rig = makeRig({initialCookies:[sessionCookie('C')]});
  rig.browser.openLogin=async()=>rig.events.push('browser:login');
  assert.deepEqual(await rig.switcher.newLogin(),{ok:true});
  assert.equal(rig.values.get(EMAIL.C).cookies[0].value,'C');
  assert.equal(rig.values.get(EMAIL.A).cookies[0].value,'A');
  assert.equal(rig.jar().length,0);
  assert.ok(rig.events.indexOf('vault:put:c@example.com')<rig.events.indexOf('browser:clear'));
  assert.equal(rig.events.at(-1),'browser:login');
});

test('an expired queued request cannot change the live browser session', async () => {
  const rig = makeRig();
  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B, null, 0), {
    ok: false, error: 'browser_timeout', email: EMAIL.B,
  });
  assert.deepEqual(rig.events, []);
  assert.equal(await rig.probe(), EMAIL.A);
});

test('a deadline reached during cookie replacement rolls back before reporting failure', async t => {
  let now = 0;
  t.mock.method(Date, 'now', () => now);
  const rig = makeRig({onSet: async details => {
    if (details.value === 'B') now = 11;
    return true;
  }});
  assert.deepEqual(await rig.switcher.switchTo(EMAIL.B, null, 10), {
    ok: false, error: 'web_switch_failed', email: EMAIL.B, failureStep: 'verify_identity',
  });
  assert.equal(await rig.probe(), EMAIL.A);
  assert.equal(rig.events.some(event => event.startsWith('browser:refresh:')), false);
});

test('a successful local browser and Code switch survives another profile failure', async () => {
  for (const target of [EMAIL.A, EMAIL.B]) {
    const rig = makeRig();
    const partial = {ok:false,partial:true,error:'code_only_after_web_failure',codeEmail:target,browserReady:false};
    const result = await rig.switcher.switchTo(target, async () => partial);
    assert.deepEqual(result, {...partial,email:target});
    assert.equal(await rig.probe(),target);
  }
});

test('an unauthorized target is reported as expired and preserves the failed probe through rollback', async () => {
  const rig = makeRig({identityForKey:{A:EMAIL.A}});
  rig.probe.diagnostic={probeStatus:'unauthorized',httpStatus:401};
  const result = await rig.switcher.switchTo(EMAIL.B);
  assert.equal(result.error,'web_login_expired');
  assert.equal(result.failureStep,'verify_identity');
  assert.equal(result.httpStatus,401);
  assert.equal(await rig.probe(),EMAIL.A);
});
