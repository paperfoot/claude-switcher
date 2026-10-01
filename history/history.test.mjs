import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import {
  HistoryError,
  applyPrepared,
  identities,
  identityFromLog,
  noSymlinks,
  plan,
  prepare,
  restore,
} from './history.mjs';
import {layout, undo, desktopHasWorkers} from './transplant.mjs';

const ACCOUNT_A = '10000000-0000-4000-8000-000000000001';
const ORG_A = '20000000-0000-4000-8000-000000000001';
const ACCOUNT_B = '10000000-0000-4000-8000-000000000002';
const ORG_B = '20000000-0000-4000-8000-000000000002';
const SESSION = '30000000-0000-4000-8000-000000000001';
const OTHER_SESSION = '30000000-0000-4000-8000-000000000002';
const USER_EVENT = '40000000-0000-4000-8000-000000000001';
const ASSISTANT_EVENT = '40000000-0000-4000-8000-000000000002';

const json = value => `${JSON.stringify(value)}\n`;
const writeJSON = async (file, value) => {
  await fs.mkdir(path.dirname(file), {recursive: true});
  await fs.writeFile(file, json(value));
};
const rejectsCode = (promise, code) => assert.rejects(promise, error => {
  assert.ok(error instanceof HistoryError);
  assert.equal(error.code, code);
  return true;
});

test('Desktop workers defer transfer, while standalone CLI and ordinary renderer processes do not', () => {
  const app = {pid: 10, desktopPid: 10, worker: true};
  const renderer = {pid: 11, desktopPid: 10, worker: false};
  const terminal = {pid: 12, desktopPid: null, worker: true};
  assert.equal(desktopHasWorkers('', [app, renderer, terminal]), false);
  assert.equal(desktopHasWorkers('', [app, renderer, {pid: 13, desktopPid: 10, worker: true}]), true);
});

async function temporaryHome(t) {
  const temporaryRoot = await fs.realpath(os.tmpdir());
  const home = await fs.mkdtemp(path.join(temporaryRoot, 'claude-history-test-'));
  t.after(() => fs.rm(home, {recursive: true, force: true}));
  return home;
}

function logFixture(account = ACCOUNT_B, org = ORG_B) {
  const timestamp = new Date(Date.now() - 1_000).toISOString().replace('T', ' ').replace('Z', '');
  const startedAt = Date.parse(timestamp.replace(' ', 'T')) - 100;
  const line = `${timestamp} [info] [LocalSessionManager] Initialization succeeded accountId=${account}, orgId=${org}`;
  return {timestamp, startedAt, line};
}

function sourceRecord(cwd) {
  return {
    sessionId: `local_${SESSION}`,
    cliSessionId: SESSION,
    cwd,
    originCwd: cwd,
    title: 'Synthetic session',
    createdAt: 1_700_000_000_000,
    lastActivityAt: 1_700_000_001_000,
    lastFocusedAt: 1_700_000_001_000,
    permissionMode: 'bypassPermissions',
    alwaysAllowedReasons: ['fixture grant'],
    sessionPermissionUpdates: [{tool: 'fixture'}],
    bridgeSessionIds: ['session_fixture_bridge'],
    remoteControlAutoEligible: true,
    steeredByRemoteClient: true,
    remoteMcpServersConfig: {fixture: {command: 'never-run'}},
    enabledMcpTools: ['fixture__tool'],
    chromePermissionMode: 'allow',
    toolSurfaceSnapshot: {fixture: true},
    promptAppendSnapshot: 'fixture',
    sessionSettings: {fixture: true},
    spawnSeed: {fixture: true},
  };
}

function transcriptFixture(cwd) {
  return [
    {
      type: 'user',
      uuid: USER_EVENT,
      sessionId: SESSION,
      cwd,
      timestamp: '2026-09-30T12:00:00.000Z',
      message: {role: 'user', content: 'Keep this message byte-for-byte.'},
    },
    {
      type: 'assistant',
      uuid: ASSISTANT_EVENT,
      parentUuid: USER_EVENT,
      sessionId: SESSION,
      cwd,
      timestamp: '2026-09-30T12:00:01.000Z',
      message: {role: 'assistant', content: [{type: 'text', text: 'Preserved.'}]},
    },
  ].map(JSON.stringify).join('\n') + '\n';
}

async function historyFixture(t, separateProfile = false) {
  const userHome = await temporaryHome(t);
  const targetRoot = path.join(userHome, 'Library/Application Support/Claude');
  const sourceRoot = separateProfile ? path.join(userHome, 'profiles/source') : targetRoot;
  const state = path.join(userHome, '.config/claude-switcher/desktop-history');
  const logs = path.join(userHome, 'Library/Logs/Claude');
  const cwd = path.join(userHome, 'work/project');
  const sourceDir = path.join(sourceRoot, 'claude-code-sessions', ACCOUNT_A, ORG_A);
  const targetDir = path.join(targetRoot, 'claude-code-sessions', ACCOUNT_B, ORG_B);
  const sourceFile = path.join(sourceDir, `local_${SESSION}.json`);
  const targetFile = path.join(targetDir, `local_${SESSION}.json`);
  const transcriptDir = path.join(userHome, '.claude/projects', cwd.replace(/[^A-Za-z0-9]/g, '-'));
  const transcript = path.join(transcriptDir, `${SESSION}.jsonl`);
  const transcriptBytes = transcriptFixture(cwd);
  const proofLog = logFixture();

  await Promise.all([
    fs.mkdir(cwd, {recursive: true}),
    fs.mkdir(targetDir, {recursive: true}),
    writeJSON(sourceFile, sourceRecord(cwd)),
    writeJSON(path.join(targetRoot, 'config.json'), {lastKnownAccountUuid: ACCOUNT_B}),
    fs.mkdir(logs, {recursive: true}),
    fs.mkdir(transcriptDir, {recursive: true}),
  ]);
  await Promise.all([
    fs.writeFile(path.join(logs, 'main.log'), `${proofLog.line}\n`),
    fs.writeFile(transcript, transcriptBytes),
  ]);

  const proof = identityFromLog(proofLog.line, proofLog.startedAt, ACCOUNT_B);
  assert.ok(proof, 'fixture must carry current signed-in identity evidence');
  const identity = {
    ...proof,
    email: 'target@example.test',
    root: targetRoot,
    pid: 999_999,
    startedAt: proofLog.startedAt,
  };
  const ctx = {
    config: {
      claudeAppPath: path.join(userHome, 'No-Such-Claude.app'),
      profiles: [],
    },
    roots: [...new Set([targetRoot, sourceRoot])],
    known: new Map([
      [`${ACCOUNT_A}/${ORG_A}`, 'source@example.test'],
      [`${ACCOUNT_B}/${ORG_B}`, 'target@example.test'],
    ]),
    userHome,
    logs,
    state,
  };
  return {
    userHome,
    sourceRoot,
    targetRoot,
    sourceDir,
    targetDir,
    sourceFile,
    targetFile,
    transcript,
    transcriptBytes,
    cwd,
    identity,
    ctx,
  };
}

test('identityFromLog requires fresh successful initialization evidence', () => {
  const fixture = logFixture();
  const init = fixture.line;
  const accepted = identityFromLog(init, fixture.startedAt, ACCOUNT_B);
  const later = fixture.timestamp;

  assert.equal(identityFromLog('', fixture.startedAt, ACCOUNT_B), null, 'cached UUID alone is not proof');
  assert.equal(identityFromLog(init, accepted.at + 1_000, ACCOUNT_B), null,
    'initialization before process start is stale');
  assert.deepEqual(accepted, {
    account: ACCOUNT_B,
    org: ORG_B,
    proof: accepted.proof,
    at: Date.parse(fixture.timestamp.replace(' ', 'T')),
  });
  assert.equal(identityFromLog(`${init}\n${later} [info] [account] Login-state transition`, fixture.startedAt, ACCOUNT_B), null);
  assert.equal(identityFromLog(`${init}\n${later} [error] [LocalSessionManager] Cannot initialize sessions`, fixture.startedAt, ACCOUNT_B), null);
  assert.equal(identityFromLog(`${init}\n${later} [error] [LocalSessionManager] loadSessions failed`, fixture.startedAt, ACCOUNT_B), null);
  assert.equal(identityFromLog(init, fixture.startedAt, ACCOUNT_A), null, 'cached account must match the proof');
});

test('identities admits only configured expected emails', async t => {
  const home = await temporaryHome(t);
  const credentials = path.join(home, 'credentials/allowed');
  const allowed = {
    emailAddress: 'Allowed@Example.test',
    accountUuid: ACCOUNT_A,
    organizationUuid: ORG_A,
  };
  const denied = {
    emailAddress: 'denied@example.test',
    accountUuid: ACCOUNT_B,
    organizationUuid: ORG_B,
  };
  await Promise.all([
    writeJSON(path.join(credentials, '.claude.json'), {oauthAccount: allowed}),
    writeJSON(path.join(home, '.claude.json'), {oauthAccount: denied}),
    writeJSON(path.join(home, '.claude-swap-backup/sequence.json'), {accounts: {
      allowed: {email: allowed.emailAddress, uuid: allowed.accountUuid, organizationUuid: allowed.organizationUuid},
      denied: {email: denied.emailAddress, uuid: denied.accountUuid, organizationUuid: denied.organizationUuid},
    }}),
  ]);

  const result = await identities({profiles: [{expectedEmail: 'allowed@example.test', credDir: credentials}]}, home);
  assert.deepEqual([...result], [[`${ACCOUNT_A}/${ORG_A}`, 'allowed@example.test']]);
});

test('noSymlinks rejects a symlink and a symlinked parent', async t => {
  const home = await temporaryHome(t);
  const real = path.join(home, 'real');
  const direct = path.join(home, 'direct-link');
  const parent = path.join(home, 'parent-link');
  await fs.mkdir(real);
  await Promise.all([
    fs.symlink(path.join(real, 'missing'), direct),
    fs.symlink(real, parent),
  ]);

  await rejectsCode(noSymlinks(direct), 'unsafe_path');
  await rejectsCode(noSymlinks(path.join(parent, 'child')), 'unsafe_path');
});

test('plan, prepare, apply, and undo move a local session without changing its transcript or IDs', async t => {
  const fixture = await historyFixture(t);
  const planned = await plan(fixture.ctx, fixture.identity);
  assert.equal(planned.summary.count, 1);
  assert.equal(planned.summary.remoteLinks, 1);

  const prepared = await prepare(fixture.ctx, fixture.identity);
  assert.equal(prepared.count, 1);
  assert.equal(typeof prepared.token, 'string');
  const applied = await applyPrepared(fixture.ctx, prepared.token);
  assert.equal(applied.moved, 1);
  assert.equal(await fs.readFile(fixture.transcript, 'utf8'), fixture.transcriptBytes);
  await assert.rejects(fs.access(fixture.sourceFile), {code: 'ENOENT'});

  const placed = JSON.parse(await fs.readFile(fixture.targetFile, 'utf8'));
  assert.equal(placed.sessionId, `local_${SESSION}`);
  assert.equal(placed.cliSessionId, SESSION);
  assert.equal(placed.cwd, fixture.cwd);
  assert.equal(placed.originCwd, fixture.cwd);
  assert.equal(placed.permissionMode, 'default');
  assert.deepEqual(placed.alwaysAllowedReasons, []);
  assert.deepEqual(placed.sessionPermissionUpdates, []);
  assert.deepEqual(placed.bridgeSessionIds, []);
  assert.equal(placed.remoteControlAutoEligible, false);
  assert.equal(placed.steeredByRemoteClient, false);
  for (const key of ['remoteMcpServersConfig', 'enabledMcpTools', 'chromePermissionMode',
    'toolSurfaceSnapshot', 'promptAppendSnapshot', 'sessionSettings', 'spawnSeed']) {
    assert.equal(placed[key], undefined, `${key} must not cross accounts`);
  }

  const restored = await undo({...layout(fixture.userHome), state: fixture.ctx.state});
  assert.equal(typeof restored.dest, 'string', JSON.stringify(restored));
  assert.equal(await fs.readFile(fixture.transcript, 'utf8'), fixture.transcriptBytes);
  assert.deepEqual(JSON.parse(await fs.readFile(fixture.sourceFile, 'utf8')), sourceRecord(fixture.cwd));
  await assert.rejects(fs.access(fixture.targetFile), {code: 'ENOENT'});
});

test('applyPrepared rejects a changed source record', async t => {
  const fixture = await historyFixture(t);
  const prepared = await prepare(fixture.ctx, fixture.identity);
  const changed = sourceRecord(fixture.cwd);
  changed.title = 'Changed after prepare';
  await writeJSON(fixture.sourceFile, changed);

  await rejectsCode(applyPrepared(fixture.ctx, prepared.token), 'sessions_changed');
  await fs.access(fixture.sourceFile);
  await assert.rejects(fs.access(fixture.targetFile), {code: 'ENOENT'});
});

test('applyPrepared rejects an expired token', async t => {
  const fixture = await historyFixture(t);
  const prepared = await prepare(fixture.ctx, fixture.identity);
  const preparedFile = path.join(fixture.ctx.state, 'prepared.json');
  const saved = JSON.parse(await fs.readFile(preparedFile, 'utf8'));
  await writeJSON(preparedFile, {...saved, expires: 0});

  await rejectsCode(applyPrepared(fixture.ctx, prepared.token), 'plan_expired');
});

test('applyPrepared rejects a destination collision introduced after prepare', async t => {
  const fixture = await historyFixture(t);
  const prepared = await prepare(fixture.ctx, fixture.identity);
  await writeJSON(fixture.targetFile, {
    sessionId: `local_${SESSION}`,
    cliSessionId: OTHER_SESSION,
    cwd: fixture.cwd,
    title: 'Destination collision',
  });

  await rejectsCode(applyPrepared(fixture.ctx, prepared.token), 'sessions_busy_or_conflicted');
  await fs.access(fixture.sourceFile);
});

test('undo preserves a transcript changed after transfer', async t => {
  const fixture = await historyFixture(t);
  const prepared = await prepare(fixture.ctx, fixture.identity);
  await applyPrepared(fixture.ctx, prepared.token);
  const changed = `${fixture.transcriptBytes}${JSON.stringify({
    type: 'user',
    uuid: '40000000-0000-4000-8000-000000000003',
    sessionId: SESSION,
    message: {role: 'user', content: 'New local work.'},
  })}\n`;
  await fs.writeFile(fixture.transcript, changed);

  const result = await undo({...layout(fixture.userHome), state: fixture.ctx.state});
  assert.equal(typeof result.dest, 'string', JSON.stringify(result));
  assert.equal(await fs.readFile(fixture.transcript, 'utf8'), changed);
  await fs.access(fixture.sourceFile);
  await assert.rejects(fs.access(fixture.targetFile), {code: 'ENOENT'});
});

test('undo refuses destination record drift', async t => {
  const fixture = await historyFixture(t);
  const prepared = await prepare(fixture.ctx, fixture.identity);
  await applyPrepared(fixture.ctx, prepared.token);
  const placed = JSON.parse(await fs.readFile(fixture.targetFile, 'utf8'));
  await writeJSON(fixture.targetFile, {...placed, title: 'Used after transfer'});

  const result = await undo({...layout(fixture.userHome), state: fixture.ctx.state});
  assert.ok(result.changed?.some(message => message.includes('desktop record changed')));
  await rejectsCode(restore(fixture.ctx), 'undo_changed');
  await fs.access(fixture.targetFile);
  await assert.rejects(fs.access(fixture.sourceFile), {code: 'ENOENT'});
});

test('cross-profile transfer keeps recovery files inside quarantine and restores exact records', async t => {
  const fixture = await historyFixture(t, true);
  const original = await fs.readFile(fixture.sourceFile);
  const prepared = await prepare(fixture.ctx, fixture.identity);
  const applied = await applyPrepared(fixture.ctx, prepared.token);
  const receipt = JSON.parse(await fs.readFile(applied.receipt, 'utf8'));
  for (const item of receipt.superseded) for (const [, parked] of item.moved) {
    const relative = path.relative(path.join(fixture.ctx.state, 'quarantine'), parked);
    assert.ok(!relative.startsWith('..') && !path.isAbsolute(relative));
  }
  assert.equal((await restore(fixture.ctx)).ok, true);
  assert.deepEqual(await fs.readFile(fixture.sourceFile), original);
  assert.equal(await fs.readFile(fixture.transcript, 'utf8'), fixture.transcriptBytes);
  await assert.rejects(fs.access(fixture.targetFile), {code: 'ENOENT'});
});

test('normal quit timestamp updates do not invalidate an otherwise unchanged transfer', async t => {
  const fixture = await historyFixture(t);
  const prepared = await prepare(fixture.ctx, fixture.identity);
  await writeJSON(fixture.sourceFile, {...sourceRecord(fixture.cwd), lastFocusedAt: Date.now(), lastActivityAt: Date.now()});
  assert.equal((await applyPrepared(fixture.ctx, prepared.token)).moved, 1);
  assert.equal((await restore(fixture.ctx)).ok, true);
});
