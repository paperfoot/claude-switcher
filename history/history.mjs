import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {spawnSync} from 'node:child_process';
import {createHash, randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {layout, accounts, inventory, move, undo, desktopHasWorkers} from './transplant.mjs';

const UUID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const home = os.homedir();
const base = path.join(home, '.config/claude-switcher');
const digest = data => createHash('sha256').update(data).digest('hex');
const readJSON = async file => JSON.parse(await fs.readFile(file, 'utf8'));
export class HistoryError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = code => { throw new HistoryError(code); };

export async function noSymlinks(file) {
  const absolute = path.resolve(file);
  let current = path.parse(absolute).root;
  for (const part of absolute.slice(current.length).split(path.sep)) {
    current = path.join(current, part);
    const info = await fs.lstat(current).catch(error => {
      if (error.code === 'ENOENT') return null;
      throw error;
    });
    if (info?.isSymbolicLink()) fail('unsafe_path');
  }
}

export async function atomicJSON(file, data) {
  await noSymlinks(file);
  await fs.mkdir(path.dirname(file), {recursive: true, mode: 0o700});
  const temporary = `${file}.${randomUUID()}.tmp`;
  const handle = await fs.open(temporary, 'wx', 0o600);
  try {
    await handle.writeFile(JSON.stringify(data));
    await handle.sync();
  } finally { await handle.close(); }
  try { await fs.rename(temporary, file); }
  finally { await fs.unlink(temporary).catch(() => {}); }
}

// A cached UUID survives logout. Only a successful initialization after the current
// process started, with no later logout or failed initialization, licenses a move.
export function identityFromLog(text, startedAt, cachedAccount) {
  let identity = null;
  for (const line of text.split('\n')) {
    const timestamp = line.match(/^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?) /)?.[1];
    const at = timestamp ? Date.parse(timestamp.replace(' ', 'T')) : NaN;
    if (!Number.isFinite(at) || at < Math.floor(startedAt / 1000) * 1000 || at > Date.now() + 2000) continue;
    if (line.includes('[account] Login-state transition') ||
        /\[LocalSessionManager\].*(Account logged out|Cannot initialize|loadSessions failed)/.test(line)) identity = null;
    if (!line.includes('[LocalSessionManager] Initialization succeeded')) continue;
    const match = line.match(/accountId=([a-f\d-]+), orgId=([a-f\d-]+)/i);
    identity = match && UUID.test(match[1]) && UUID.test(match[2])
      ? {account: match[1].toLowerCase(), org: match[2].toLowerCase(), proof: digest(line), at}
      : null;
  }
  return identity?.account === cachedAccount?.toLowerCase() ? identity : null;
}

export async function identities(config, userHome = home) {
  const allowed = new Set(config.profiles.map(p => p.expectedEmail?.toLowerCase()).filter(Boolean));
  const inputs = [path.join(userHome, '.claude.json')];
  for (const profile of config.profiles) if (profile.credDir) {
    inputs.push(path.join(profile.credDir, '.claude.json'), path.join(profile.credDir, '.config.json'));
  }
  const registry = new Map();
  const take = value => {
    const email = value?.emailAddress?.toLowerCase();
    if (allowed.has(email) && UUID.test(value.accountUuid ?? '') && UUID.test(value.organizationUuid ?? '')) {
      const key = `${value.accountUuid.toLowerCase()}/${value.organizationUuid.toLowerCase()}`;
      if (registry.has(key) && registry.get(key) !== email) fail('identity_conflict');
      registry.set(key, email);
    }
  };
  for (const file of inputs) {
    await noSymlinks(file);
    const value = await readJSON(file).catch(() => null);
    take(value?.oauthAccount);
  }
  const sequence = await readJSON(path.join(userHome, '.claude-swap-backup/sequence.json')).catch(() => null);
  for (const account of Object.values(sequence?.accounts ?? {})) {
    take({emailAddress: account.email, accountUuid: account.uuid, organizationUuid: account.organizationUuid});
  }
  return registry;
}

export function desktopProcesses(appPath) {
  const result = spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,comm='], {encoding: 'utf8', timeout: 4000});
  if (result.status !== 0) fail('process_check_failed');
  const executable = path.join(appPath, 'Contents/MacOS/Claude');
  return result.stdout.split('\n').flatMap(line => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/);
    return match && match[3] === executable ? [Number(match[1])] : [];
  });
}

export async function context() {
  const config = await readJSON(path.join(base, 'config.json'));
  const roots = [...new Set([path.join(home, 'Library/Application Support/Claude'),
    ...config.profiles.map(p => p.userDataDir).filter(Boolean)].map(p => path.resolve(p)))];
  for (const root of roots) await noSymlinks(root);
  const known = await identities(config);
  return {config, roots, known, userHome: home, logs: path.join(home, 'Library/Logs/Claude'), state: path.join(base, 'desktop-history')};
}

export async function logText(root) {
  const names = (await fs.readdir(root)).filter(name => /^main(?:\d+)?\.log$/.test(name));
  const files = (await Promise.all(names.map(async name => ({name, at:(await fs.stat(path.join(root,name))).mtimeMs})))).sort((a,b)=>a.at-b.at).map(row=>row.name);
  const rows = [];
  for (const file of files) {
    const handle = await fs.open(path.join(root, file), 'r');
    try {
      const size = (await handle.stat()).size;
      const buffer = Buffer.alloc(Math.min(size, 4 * 1024 * 1024));
      await handle.read(buffer, 0, buffer.length, Math.max(0, size - buffer.length));
      rows.push(...buffer.toString('utf8').split('\n').filter(line =>
        line.includes('[LocalSessionManager]') || line.includes('[account] Login-state transition')));
    } finally { await handle.close(); }
  }
  return rows.join('\n');
}

export async function currentIdentity(ctx, root, pid, startedAt) {
  if (!ctx.roots.includes(path.resolve(root))) fail('unknown_profile');
  const processes = desktopProcesses(ctx.config.claudeAppPath);
  if (processes.length !== 1 || processes[0] !== pid) fail('desktop_not_ready');
  const config = await readJSON(path.join(root, 'config.json')).catch(() => null);
  const identity = identityFromLog(await logText(ctx.logs), startedAt, config?.lastKnownAccountUuid);
  if (!identity) fail('desktop_signed_out');
  const email = ctx.known.get(`${identity.account}/${identity.org}`);
  if (!email) fail('unknown_account');
  return {...identity, email, root, pid, startedAt};
}

async function scopedAccounts(ctx, root) {
  const paths = {...layout(ctx.userHome), records: path.join(root, 'claude-code-sessions'), desktop: path.join(root, 'config.json'), state: ctx.state};
  const all = await accounts(paths, []);
  return all.filter(row => ctx.known.has(`${row.account}/${row.org}`)).map(row => ({...row,
    email: ctx.known.get(`${row.account}/${row.org}`),
    label: ctx.known.get(`${row.account}/${row.org}`)}));
}

export async function plan(ctx, identity) {
  if (desktopHasWorkers(ctx.config.claudeAppPath)) fail('desktop_busy');
  const paths = {...layout(ctx.userHome), records: path.join(identity.root, 'claude-code-sessions'), state: ctx.state};
  const all = (await Promise.all(ctx.roots.map(root => scopedAccounts(ctx, root)))).flat();
  let target = all.find(row => row.account === identity.account && row.org === identity.org &&
    path.dirname(path.dirname(row.dir)) === paths.records);
  if (!target) target = {account: identity.account, org: identity.org, email: identity.email, label: identity.email,
    dir: path.join(paths.records, identity.account, identity.org), sessions: [], allSessions: [], unreadable: [],
    taskFile: path.join(paths.records, identity.account, identity.org, 'scheduled-tasks.json'), taskSessions: new Set(), taskError: null};
  const sources = all.filter(row => row.dir !== target.dir && row.sessions.length);
  for (const row of [...sources, target]) {
    await noSymlinks(row.dir);
    for (const session of row.sessions) {
      await noSymlinks(session.file);
      if (session.record.scheduledTaskId || session.record.notifySessionId || row.taskSessions.size) fail('scheduled_sessions');
    }
  }
  const inv = await inventory(sources, target, paths, () => {}, {localProjectsOnly: true});
  for (const row of [...inv.move, ...inv.there]) {
    await noSymlinks(row.transcript);
  }
  if (inv.blocked.length || inv.unreadable.length || inv.rejected.length) fail('sessions_busy_or_conflicted');
  const selection = [...sources, target].map(row => ({dir: row.dir, records: row.sessions.map(s =>
    ({file: s.file, record: {...s.record, lastFocusedAt: null, lastActivityAt: null}})).sort((a,b) => a.file.localeCompare(b.file))})).sort((a,b)=>a.dir.localeCompare(b.dir));
  if (desktopHasWorkers(ctx.config.claudeAppPath)) fail('desktop_busy');
  return {paths, sources, target, inv, selectionHash: digest(JSON.stringify(selection)),
    summary: {ok: true, email: identity.email, count: inv.move.length, unavailable: inv.missing.length,
      remoteLinks: inv.move.filter(row => row.record.bridgeSessionIds?.length).length, identity}};
}

export async function prepare(ctx, identity) {
  const result = await plan(ctx, identity);
  const token = randomUUID();
  await atomicJSON(path.join(ctx.state, 'prepared.json'), {token, identity, selectionHash: result.selectionHash, expires: Date.now()+120000});
  return {...result.summary, token};
}

export async function applyPrepared(ctx, token) {
  const prepared = await readJSON(path.join(ctx.state, 'prepared.json'));
  if (prepared.token !== token || prepared.expires < Date.now()) fail('plan_expired');
  if (desktopProcesses(ctx.config.claudeAppPath).length) fail('desktop_running');
  const identity = prepared.identity;
  if (!ctx.roots.includes(identity.root) || ctx.known.get(`${identity.account}/${identity.org}`) !== identity.email) fail('identity_changed');
  const config = await readJSON(path.join(identity.root, 'config.json'));
  const proof = identityFromLog(await logText(ctx.logs), identity.startedAt, config.lastKnownAccountUuid);
  if (!proof || proof.proof !== identity.proof) fail('identity_changed');
  const result = await plan(ctx, identity);
  if (result.selectionHash !== prepared.selectionHash) fail('sessions_changed');
  if (!result.inv.move.length) return {...result.summary, moved: 0};
  const moved = await move(result.inv, result.target, result.paths);
  if (!moved.ok || moved.receipt?.verification?.ok === false) fail('transfer_incomplete');
  await fs.unlink(path.join(ctx.state, 'prepared.json'));
  return {...result.summary, moved: moved.receipt.sessions.length, receipt: moved.file};
}

export async function restore(ctx) {
  if (desktopProcesses(ctx.config.claudeAppPath).length) fail('desktop_running');
  const result = await undo({...layout(ctx.userHome), state: ctx.state});
  if (!result?.dest && result?.nothing !== true) fail('undo_changed');
  return {ok: true};
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  const ctx = await context();
  const copy = await import('./copy.mjs');
  if (command === 'apply') return copy.applyCopy(ctx, args[0]);
  if (command === 'undo') return copy.undoCopy(ctx);
  if (!['probe', 'plan', 'prepare'].includes(command)) fail('unknown_command');
  const identity = await currentIdentity(ctx, args[0], Number(args[1]), Number(args[2]));
  if (command === 'probe') return {ok:true, email:identity.email, identity};
  if (command === 'prepare') return copy.prepareCopy(ctx, identity);
  return (await copy.planCopy(ctx, identity)).summary;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then(result => process.stdout.write(JSON.stringify(result)+'\n')).catch(error => {
    process.stdout.write(JSON.stringify({ok:false, error:error instanceof HistoryError ? error.code : 'history_unavailable'})+'\n');
    process.exitCode=1;
  });
}
