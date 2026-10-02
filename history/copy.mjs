import fs from 'node:fs/promises';
import path from 'node:path';
import {createHash, randomUUID} from 'node:crypto';
import {HistoryError, noSymlinks, atomicJSON, identityFromLog, logText, desktopProcesses, restore} from './history.mjs';
import {desktopHasWorkers, writeNew, locked} from './transplant.mjs';

const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const local = /^local_([a-f0-9-]+)$/i;
const hash = value => createHash('sha256').update(value).digest('hex');
const json = async file => JSON.parse(await fs.readFile(file, 'utf8'));
const fail = code => { throw new HistoryError(code); };
const key = r => `${r.cliSessionId}/${r.cwd}`;
const semantic = r => JSON.stringify({...r, lastActivityAt: null, lastFocusedAt: null});

function cleanRecord(record) {
  const copy = {...record, bridgeSessionIds: [], remoteControlAutoEligible: false,
    steeredByRemoteClient: false, permissionMode: 'default', alwaysAllowedReasons: [], sessionPermissionUpdates: []};
  for (const field of ['remoteMcpServersConfig', 'enabledMcpTools', 'chromePermissionMode',
    'toolSurfaceSnapshot', 'promptAppendSnapshot', 'sessionSettings', 'spawnSeed']) delete copy[field];
  return copy;
}

async function listRecords(dir) {
  await noSymlinks(dir);
  const names = await fs.readdir(dir).catch(error => {
    if (error.code === 'ENOENT') return [];
    throw error;
  });
  const rows = [];
  for (const name of names.sort()) {
    if (!name.startsWith('local_') || !name.endsWith('.json')) continue;
    const file = path.join(dir, name);
    await noSymlinks(file);
    const raw = await fs.readFile(file, 'utf8');
    let record;
    try { record = JSON.parse(raw); } catch { fail('sessions_busy_or_conflicted'); }
    const id = record.sessionId?.match(local)?.[1];
    if (!uuid.test(id ?? '') || name !== `${record.sessionId}.json`) fail('sessions_busy_or_conflicted');
    rows.push({file, raw, record});
  }
  return rows;
}

async function transcriptIndex(userHome) {
  const pool = path.join(userHome, '.claude/projects'), byId = new Map();
  await noSymlinks(pool);
  for (const dir of await fs.readdir(pool, {withFileTypes: true}).catch(() => [])) {
    if (!dir.isDirectory()) continue;
    for (const file of await fs.readdir(path.join(pool, dir.name), {withFileTypes: true})) {
      const id = file.name.slice(0, -6);
      if (file.isFile() && file.name.endsWith('.jsonl') && uuid.test(id)) {
        byId.set(id, [...(byId.get(id) ?? []), path.join(pool, dir.name, file.name)]);
      }
    }
  }
  return byId;
}

export async function planCopy(ctx, identity) {
  if (!ctx.roots.includes(identity.root) || ctx.known.get(`${identity.account}/${identity.org}`) !== identity.email) fail('identity_changed');
  if (desktopHasWorkers(ctx.config.claudeAppPath)) fail('desktop_busy');
  const targetDir = path.join(identity.root, 'claude-code-sessions', identity.account, identity.org);
  const targetRows = await listRecords(targetDir);
  const existing = new Map(targetRows.map(row => [key(row.record), row]));
  const names = new Map(targetRows.map(row => [row.record.sessionId, row.record]));
  const selected = new Map(), claimed = new Map();
  let unavailable = 0;
  for (const root of ctx.roots) for (const pair of ctx.known.keys()) {
    const dir = path.join(root, 'claude-code-sessions', pair);
    if (dir === targetDir) continue;
    const scheduled = await json(path.join(dir, 'scheduled-tasks.json')).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (scheduled?.scheduledTasks?.length) fail('scheduled_sessions');
    for (const row of await listRecords(dir)) {
      const r = row.record;
      if (!uuid.test(r.cliSessionId ?? '') || typeof r.cwd !== 'string' || !path.isAbsolute(r.cwd) ||
          r.scheduledTaskId || r.notifySessionId) { unavailable++; continue; }
      const collision = names.get(r.sessionId) ?? claimed.get(r.sessionId);
      if (collision && key(collision) !== key(r)) fail('sessions_busy_or_conflicted');
      claimed.set(r.sessionId, r);
      if (existing.has(key(r))) continue;
      const prior = selected.get(key(r));
      if (!prior || (r.lastActivityAt ?? 0) > (prior.record.lastActivityAt ?? 0)) selected.set(key(r), row);
    }
  }
  const index = selected.size ? await transcriptIndex(ctx.userHome) : new Map();
  let entries = [];
  for (const row of selected.values()) {
    const candidates = index.get(row.record.cliSessionId) ?? [];
    const transcript = candidates.length === 1 ? candidates[0] : candidates.find(file => path.basename(path.dirname(file)) === row.record.cwd.replace(/[^A-Za-z0-9]/g, '-'));
    if (!transcript) { unavailable++; continue; }
    await noSymlinks(transcript);
    if (!(await fs.stat(transcript)).size) { unavailable++; continue; }
    entries.push({...row, target: path.join(targetDir, `${row.record.sessionId}.json`), transcript});
  }
  // A fork stays on its source account until its parent is also available.
  let changed;
  do {
    const available = new Set([...names.keys(), ...entries.map(row => row.record.sessionId)]);
    const keep = entries.filter(row => !row.record.forkedFromSessionId || available.has(row.record.forkedFromSessionId));
    changed = keep.length !== entries.length; unavailable += entries.length - keep.length; entries = keep;
  } while (changed);
  entries.sort((a,b) => a.target.localeCompare(b.target));
  const selectionHash = hash(JSON.stringify({
    sources: entries.map(row => [row.file, semantic(row.record)]),
    target: targetRows.map(row => [row.file, semantic(row.record)])
  }));
  if (desktopHasWorkers(ctx.config.claudeAppPath)) fail('desktop_busy');
  return {entries, selectionHash, targetDir,
    summary: {ok: true, email: identity.email, count: entries.length, unavailable, identity}};
}

export async function prepareCopy(ctx, identity) {
  const previous = await json(path.join(ctx.state, 'last-copy.json')).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
  if (previous?.status === 'pending') fail('copy_recovery_required');
  const result = await planCopy(ctx, identity), token = randomUUID();
  await atomicJSON(path.join(ctx.state, 'prepared-copy.json'), {token, identity, selectionHash: result.selectionHash, expires: Date.now() + 120000});
  return {...result.summary, token};
}

async function withLock(ctx, operation) {
  await noSymlinks(ctx.state);
  await fs.mkdir(ctx.state, {recursive: true, mode: 0o700});
  await noSymlinks(path.join(ctx.state, 'lock'));
  try { return await locked(ctx, operation); }
  catch (error) { if (error.message === 'another run holds the lock') fail('history_locked'); throw error; }
}

export async function applyCopy(ctx, token) {
  return withLock(ctx, async () => {
    const preparedFile = path.join(ctx.state, 'prepared-copy.json');
    const prepared = await json(preparedFile);
    if (prepared.token !== token || prepared.expires < Date.now()) fail('plan_expired');
    if (desktopProcesses(ctx.config.claudeAppPath).length) fail('desktop_running');
    const identity = prepared.identity;
    const config = await json(path.join(identity.root, 'config.json'));
    const proof = identityFromLog(await logText(ctx.logs), identity.startedAt, config.lastKnownAccountUuid);
    if (!proof || proof.proof !== identity.proof) fail('identity_changed');
    const result = await planCopy(ctx, identity);
    if (result.selectionHash !== prepared.selectionHash) fail('sessions_changed');
    const receiptFile = path.join(ctx.state, 'last-copy.json');
    const previous = await json(receiptFile).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (previous?.status === 'pending') fail('copy_recovery_required');
    if (!result.entries.length) return {...result.summary, moved: 0};
    if (previous) await atomicJSON(path.join(ctx.state, 'copies', `${previous.id}.json`), previous);
    const id = randomUUID();
    const entries = result.entries.map(row => {
      const text = JSON.stringify(cleanRecord(row.record));
      return {source: row.file, target: row.target, sha: hash(text), text};
    });
    const receipt = {id, status: 'pending', targetRoot: identity.root, entries: entries.map(({text, ...row}) => row)};
    await atomicJSON(receiptFile, receipt);
    await fs.mkdir(result.targetDir, {recursive: true, mode: 0o700});
    for (let i = 0; i < entries.length; i++) {
      if (i % 25 === 0 && desktopProcesses(ctx.config.claudeAppPath).length) fail('desktop_running');
      const row = entries[i], source = result.entries[i];
      if (semantic(await json(source.file)) !== semantic(source.record)) fail('sessions_changed');
      await noSymlinks(row.target);
      await writeNew(row.target, row.text);
      if (hash(await fs.readFile(row.target)) !== row.sha) fail('copy_verification_failed');
    }
    receipt.status = 'complete'; await atomicJSON(receiptFile, receipt);
    await fs.unlink(preparedFile);
    return {...result.summary, moved: entries.length, receipt: receiptFile};
  });
}

export async function undoCopy(ctx) {
  const receiptFile = path.join(ctx.state, 'last-copy.json');
  const receipt = await json(receiptFile).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
  if (!receipt) return restore(ctx);
  return withLock(ctx, async () => {
    const receipt = await json(receiptFile);
    if (desktopProcesses(ctx.config.claudeAppPath).length) fail('desktop_running');
    if (receipt.status === 'undone') return {ok: true};
    const present = [];
    for (const row of receipt.entries) {
      if (path.resolve(row.target) !== row.target || !ctx.roots.some(root => row.target.startsWith(path.join(root, 'claude-code-sessions') + path.sep))) fail('unsafe_path');
      await noSymlinks(row.target);
      const raw = await fs.readFile(row.target).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
      if (raw && hash(raw) !== row.sha) fail('undo_changed');
      if (raw) present.push(row.target);
    }
    for (const file of present) await fs.unlink(file);
    receipt.status = 'undone'; await atomicJSON(receiptFile, receipt);
    return {ok: true};
  });
}
