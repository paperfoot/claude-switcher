import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import {HistoryError, identityFromLog} from './history.mjs';
import {applyCopy, planCopy, prepareCopy, undoCopy} from './copy.mjs';

const ACCOUNT_A = '10000000-0000-4000-8000-000000000001';
const ORG_A = '20000000-0000-4000-8000-000000000001';
const ACCOUNT_B = '10000000-0000-4000-8000-000000000002';
const ORG_B = '20000000-0000-4000-8000-000000000002';
const SESSION = '30000000-0000-4000-8000-000000000001';

const json = value => `${JSON.stringify(value)}\n`;

async function writeJSON(file, value) {
  await fs.mkdir(path.dirname(file), {recursive: true});
  await fs.writeFile(file, json(value));
}

async function temporaryHome(t) {
  const temporaryRoot = await fs.realpath(os.tmpdir());
  const home = await fs.mkdtemp(path.join(temporaryRoot, 'claude-copy-test-'));
  t.after(() => fs.rm(home, {recursive: true, force: true}));
  return home;
}

function logFixture(account = ACCOUNT_B, org = ORG_B) {
  const timestamp = new Date(Date.now() - 1_000).toISOString().replace('T', ' ').replace('Z', '');
  const startedAt = Date.parse(timestamp.replace(' ', 'T')) - 100;
  const line = `${timestamp} [info] [LocalSessionManager] Initialization succeeded accountId=${account}, orgId=${org}`;
  return {startedAt, line};
}

function sourceRecord(cwd, id = SESSION) {
  return {
    sessionId: `local_${id}`,
    cliSessionId: id,
    cwd,
    originCwd: cwd,
    title: 'Source title',
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

function transcriptFixture(cwd, id = SESSION) {
  return `${JSON.stringify({
    type: 'user',
    uuid: '40000000-0000-4000-8000-000000000001',
    sessionId: id,
    cwd,
    message: {role: 'user', content: 'Keep this message byte-for-byte.'},
  })}\n`;
}

async function copyFixture(t, {separateProfile = false, includeRecord = true} = {}) {
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
  const sidecar = path.join(transcriptDir, SESSION, 'artifact.txt');
  const transcriptBytes = transcriptFixture(cwd);
  const sidecarBytes = 'sidecar bytes\n';
  const proofLog = logFixture();

  await Promise.all([
    fs.mkdir(cwd, {recursive: true}),
    fs.mkdir(targetDir, {recursive: true}),
    writeJSON(path.join(targetRoot, 'config.json'), {lastKnownAccountUuid: ACCOUNT_B}),
    fs.mkdir(logs, {recursive: true}),
  ]);
  await fs.writeFile(path.join(logs, 'main.log'), `${proofLog.line}\n`);
  if (includeRecord) {
    await Promise.all([
      writeJSON(sourceFile, sourceRecord(cwd)),
      fs.mkdir(path.dirname(sidecar), {recursive: true}),
    ]);
    await Promise.all([
      fs.writeFile(transcript, transcriptBytes),
      fs.writeFile(sidecar, sidecarBytes),
    ]);
  }

  const proof = identityFromLog(proofLog.line, proofLog.startedAt, ACCOUNT_B);
  assert.ok(proof, 'fixture needs fresh signed-in identity evidence');
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
    transcriptDir,
    transcript,
    transcriptBytes,
    sidecar,
    sidecarBytes,
    cwd,
    identity,
    ctx,
  };
}

const rejectsCode = (promise, code) => assert.rejects(promise, error => {
  assert.ok(error instanceof HistoryError);
  assert.equal(error.code, code);
  return true;
});

test('copy retains the source, transcript, and sidecar and clears account-specific state', async t => {
  const fixture = await copyFixture(t);
  const originalSource = await fs.readFile(fixture.sourceFile);
  const planned = await planCopy(fixture.ctx, fixture.identity);
  assert.equal(planned.targetDir, fixture.targetDir);
  assert.equal(planned.summary.count, 1);
  assert.equal(planned.summary.unavailable, 0);

  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  const applied = await applyCopy(fixture.ctx, prepared.token);
  assert.equal(applied.moved, 1);
  assert.deepEqual(await fs.readFile(fixture.sourceFile), originalSource);
  assert.equal(await fs.readFile(fixture.transcript, 'utf8'), fixture.transcriptBytes);
  assert.equal(await fs.readFile(fixture.sidecar, 'utf8'), fixture.sidecarBytes);

  const placed = JSON.parse(await fs.readFile(fixture.targetFile, 'utf8'));
  assert.equal(placed.sessionId, `local_${SESSION}`);
  assert.equal(placed.cliSessionId, SESSION);
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
});

test('plan after copy reports no work', async t => {
  const fixture = await copyFixture(t);
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  assert.equal((await applyCopy(fixture.ctx, prepared.token)).moved, 1);

  const repeated = await planCopy(fixture.ctx, fixture.identity);
  assert.equal(repeated.summary.count, 0);
  assert.equal(repeated.summary.unavailable, 0);
});

test('new copies respect the explicit user-level permission default', async t => {
  const fixture = await copyFixture(t);
  await writeJSON(path.join(fixture.userHome, '.claude/settings.json'), {permissions: {defaultMode: 'bypassPermissions'}});
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  await applyCopy(fixture.ctx, prepared.token);
  const target = JSON.parse(await fs.readFile(fixture.targetFile, 'utf8'));
  assert.equal(target.permissionMode, 'bypassPermissions');
  assert.deepEqual(target.alwaysAllowedReasons, []);
  assert.equal(target.remoteMcpServersConfig, undefined);
});

test('changing the user permission default invalidates a prepared copy', async t => {
  const fixture = await copyFixture(t);
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  await writeJSON(path.join(fixture.userHome, '.claude/settings.json'), {permissions: {defaultMode: 'bypassPermissions'}});
  await rejectsCode(applyCopy(fixture.ctx, prepared.token), 'sessions_changed');
});

test('an interrupted copy can be undone before retrying without changing its source', async t => {
  const fixture = await copyFixture(t);
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  await applyCopy(fixture.ctx, prepared.token);
  const receiptFile = path.join(fixture.ctx.state, 'last-copy.json');
  const receipt = JSON.parse(await fs.readFile(receiptFile, 'utf8'));
  await writeJSON(receiptFile, {...receipt, status: 'pending'});
  await rejectsCode(prepareCopy(fixture.ctx, fixture.identity), 'copy_recovery_required');
  assert.equal((await undoCopy(fixture.ctx)).ok, true);
  await fs.access(fixture.sourceFile);
  await assert.rejects(fs.access(fixture.targetFile), {code: 'ENOENT'});
  assert.equal((await planCopy(fixture.ctx, fixture.identity)).summary.count, 1);
});

test('a conversation already indexed under another Desktop record ID is not duplicated', async t => {
  const fixture = await copyFixture(t);
  const alternate = 'local_50000000-0000-4000-8000-000000000001';
  const file = path.join(fixture.targetDir, `${alternate}.json`);
  await writeJSON(file, {...sourceRecord(fixture.cwd), sessionId: alternate, title: 'Existing title'});
  assert.equal((await planCopy(fixture.ctx, fixture.identity)).summary.count, 0);
  assert.equal(JSON.parse(await fs.readFile(file, 'utf8')).title, 'Existing title');
});

test('an existing destination title is retained', async t => {
  const fixture = await copyFixture(t);
  await writeJSON(fixture.targetFile, {...sourceRecord(fixture.cwd), title: 'Destination title'});

  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  const applied = await applyCopy(fixture.ctx, prepared.token);
  assert.equal(applied.moved, 0);
  assert.equal(JSON.parse(await fs.readFile(fixture.targetFile, 'utf8')).title, 'Destination title');
  assert.equal(JSON.parse(await fs.readFile(fixture.sourceFile, 'utf8')).title, 'Source title');
});

test('a reused Desktop session ID with a different CLI session is refused', async t => {
  const fixture = await copyFixture(t);
  await writeJSON(fixture.targetFile, {
    ...sourceRecord(fixture.cwd, '30000000-0000-4000-8000-000000000002'),
    sessionId: `local_${SESSION}`,
  });

  await rejectsCode(planCopy(fixture.ctx, fixture.identity), 'sessions_busy_or_conflicted');
  await fs.access(fixture.sourceFile);
});

test('apply refuses a source record changed after prepare', async t => {
  const fixture = await copyFixture(t);
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  await writeJSON(fixture.sourceFile, {...sourceRecord(fixture.cwd), title: 'Changed after prepare'});

  await rejectsCode(applyCopy(fixture.ctx, prepared.token), 'sessions_changed');
  await fs.access(fixture.sourceFile);
  await assert.rejects(fs.access(fixture.targetFile), {code: 'ENOENT'});
});

test('apply refuses an expired token', async t => {
  const fixture = await copyFixture(t);
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  const preparedFile = path.join(fixture.ctx.state, 'prepared-copy.json');
  const saved = JSON.parse(await fs.readFile(preparedFile, 'utf8'));
  await writeJSON(preparedFile, {...saved, expires: 0});

  await rejectsCode(applyCopy(fixture.ctx, prepared.token), 'plan_expired');
});

test('apply refuses cached identity without fresh log evidence', async t => {
  const fixture = await copyFixture(t);
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  await fs.writeFile(path.join(fixture.ctx.logs, 'main.log'), '');

  await rejectsCode(applyCopy(fixture.ctx, prepared.token), 'identity_changed');
  await fs.access(fixture.sourceFile);
  await assert.rejects(fs.access(fixture.targetFile), {code: 'ENOENT'});
});

test('a missing transcript is counted and skipped', async t => {
  const fixture = await copyFixture(t);
  await fs.unlink(fixture.transcript);

  const planned = await planCopy(fixture.ctx, fixture.identity);
  assert.equal(planned.summary.count, 0);
  assert.equal(planned.summary.unavailable, 1);
  assert.deepEqual(planned.entries, []);
  await fs.access(fixture.sourceFile);
});

test('a record from a removed working directory is copied', async t => {
  const fixture = await copyFixture(t);
  await fs.rmdir(fixture.cwd);

  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  assert.equal((await applyCopy(fixture.ctx, prepared.token)).moved, 1);
  assert.equal(JSON.parse(await fs.readFile(fixture.targetFile, 'utf8')).cwd, fixture.cwd);
  assert.equal(await fs.readFile(fixture.transcript, 'utf8'), fixture.transcriptBytes);
});

test('copy works across Desktop profile roots', async t => {
  const fixture = await copyFixture(t, {separateProfile: true});
  const originalSource = await fs.readFile(fixture.sourceFile);

  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  assert.equal((await applyCopy(fixture.ctx, prepared.token)).moved, 1);
  assert.deepEqual(await fs.readFile(fixture.sourceFile), originalSource);
  await fs.access(fixture.targetFile);
  assert.equal(await fs.readFile(fixture.transcript, 'utf8'), fixture.transcriptBytes);
});

test('undo retains transcript content added after copy', async t => {
  const fixture = await copyFixture(t);
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  await applyCopy(fixture.ctx, prepared.token);
  const changed = `${fixture.transcriptBytes}${JSON.stringify({
    type: 'user',
    uuid: '40000000-0000-4000-8000-000000000002',
    sessionId: SESSION,
    message: {role: 'user', content: 'New local work.'},
  })}\n`;
  await fs.writeFile(fixture.transcript, changed);

  assert.equal((await undoCopy(fixture.ctx)).ok, true);
  assert.equal(await fs.readFile(fixture.transcript, 'utf8'), changed);
  await fs.access(fixture.sourceFile);
  await assert.rejects(fs.access(fixture.targetFile), {code: 'ENOENT'});
});

test('undo refuses a changed destination record', async t => {
  const fixture = await copyFixture(t);
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  await applyCopy(fixture.ctx, prepared.token);
  const placed = JSON.parse(await fs.readFile(fixture.targetFile, 'utf8'));
  await writeJSON(fixture.targetFile, {...placed, title: 'Used after copy'});

  await rejectsCode(undoCopy(fixture.ctx), 'undo_changed');
  await fs.access(fixture.sourceFile);
  await fs.access(fixture.targetFile);
});

test('copy handles 1000 distinct records', async t => {
  const fixture = await copyFixture(t, {includeRecord: false});
  await fs.mkdir(fixture.transcriptDir, {recursive: true});
  const total = 1000;
  const width = 100;

  for (let start = 0; start < total; start += width) {
    const writes = [];
    for (let index = start; index < Math.min(total, start + width); index++) {
      const id = `30000000-0000-4000-8000-${index.toString(16).padStart(12, '0')}`;
      writes.push(
        writeJSON(path.join(fixture.sourceDir, `local_${id}.json`), sourceRecord(fixture.cwd, id)),
        fs.writeFile(path.join(fixture.transcriptDir, `${id}.jsonl`), '{}\n'),
      );
    }
    await Promise.all(writes);
  }

  const planned = await planCopy(fixture.ctx, fixture.identity);
  assert.equal(planned.summary.count, total);
  assert.equal(planned.summary.unavailable, 0);
  const prepared = await prepareCopy(fixture.ctx, fixture.identity);
  assert.equal((await applyCopy(fixture.ctx, prepared.token)).moved, total);

  const sourceNames = (await fs.readdir(fixture.sourceDir)).filter(name => name.endsWith('.json'));
  const targetNames = (await fs.readdir(fixture.targetDir)).filter(name => name.endsWith('.json'));
  assert.equal(sourceNames.length, total);
  assert.equal(targetNames.length, total);
});
