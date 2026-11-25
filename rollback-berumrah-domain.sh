#!/usr/bin/env bash
# Berumrah rollback planner. APPLY IS DISABLED: transaction recovery is not runtime-tested.
# Only passive validation and a separately displayed manual runbook are implemented.
# No Nginx/PM2 CLI, filesystem writes, network health probes, or DB access on dry run.
set -euo pipefail
exec /usr/bin/python3 -I -B -S - "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
from urllib.parse import urlsplit

DEFAULT_BACKUP = Path('/root/backups/berumrah-com-20261125T080027Z')
APPS = Path('/www/wwwroot/berumrah-marketplace')
VHOSTS = Path('/www/server/panel/vhost/nginx')
NODE = Path('/www/server/nodejs/v22.19.0/bin/node')
PM2_MODULES = NODE.parent.parent / 'lib/node_modules/pm2/modules'
HOSTS = ('berumrah.id', 'api.berumrah.id', 'dash.berumrah.id')
PROCESSES = {
    'berumrah-marketplace-backend': APPS / 'be-marketplace',
    'berumrah-marketplace-workers': APPS / 'be-marketplace',
    'berumrah-marketplace-frontend': APPS / 'fe-marketplace',
    'berumrah-marketplace-dashboard': APPS / 'dash-marketplace',
}
# Exact domain-variable allowlist. Never restore entire backup .env files.
ENV_HOSTS = {
    'be-marketplace': {
        'FRONTEND_URL': 'berumrah.id',
        'BACKEND_URL': 'api.berumrah.id',
        'DASHBOARD_URL': 'dash.berumrah.id',
    },
    'fe-marketplace': {
        'VITE_APP_URL': 'berumrah.id',
        'VITE_API_URL': 'api.berumrah.id',
    },
    'dash-marketplace': {
        'VITE_API_BASE_URL': 'api.berumrah.id',
        'VITE_FRONTEND_URL': 'berumrah.id',
        'VITE_APP_URL': 'dash.berumrah.id',
    },
}
REQUIRED_ORIGINS = (
    'https://berumrah.id', 'https://dash.berumrah.id',
    'https://berumrah.com', 'https://dash.berumrah.com',
)
ASSIGNMENT = re.compile(
    rb'^([ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*)([^\r\n]*)(\r?\n)?$'
)
REFERENCE = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)')
HASHED_ASSET = re.compile(
    r'^assets/(?:[^/]+/)*[^/]+-[A-Za-z0-9_-]{8,}\.(?:js|css|png|svg|jpe?g|webp|gif|avif|woff2?|ttf|eot|ico|wasm)$'
)


class Refusal(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Refusal(message)


def safe_path(path, kind='file'):
    """lstat every component; reject links, special files, and untrusted writers."""
    path = Path(path)
    check(path.is_absolute() and '..' not in path.parts, 'Absolute canonical path required.')
    for part in (*reversed(path.parents), path):
        info = part.lstat()
        check(not stat.S_ISLNK(info.st_mode), f'Symlink refused: {part}')
        check(info.st_uid == 0, f'Non-root-owned path refused: {part}')
        if part != path or kind == 'dir':
            check(stat.S_ISDIR(info.st_mode), f'Directory required: {part}')
        elif kind == 'socket':
            check(stat.S_ISSOCK(info.st_mode), f'Existing socket required: {part}')
        else:
            check(stat.S_ISREG(info.st_mode), f'Regular file required: {part}')
            check(info.st_nlink == 1, f'Hardlinked file refused: {part}')
        if kind != 'socket' or part != path:
            check(not info.st_mode & 0o022, f'Group/other-writable path refused: {part}')
    return path.lstat()


def backup_path(argument):
    path = Path(argument)
    check(path.parent == Path('/root/backups') and
          re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', path.name) is not None,
          '--backup must name one direct child of /root/backups (no links or traversal).')
    safe_path(path, 'dir')
    safe_path(path / 'files', 'dir')
    return path


def backed_up(backup, live):
    return backup / 'files' / live.relative_to('/')


def selected_assignments(path, keys):
    """Keep all bytes opaque except explicitly allowed domain assignments."""
    info = safe_path(path)
    check(info.st_size <= 128 * 1024, f'Unexpected .env size: {path}')
    lines = path.read_bytes().splitlines(keepends=True)
    found = {}
    for index, line in enumerate(lines):
        match = ASSIGNMENT.fullmatch(line)
        if not match:
            continue
        key = match[2].decode('ascii')
        if key not in keys:
            continue
        check(key not in found, f'Duplicate domain variable {key}: {path}')
        raw = match[3].decode('ascii').strip()
        if raw[:1] in ('"', "'"):
            end = raw.find(raw[0], 1)
            check(end > 0, f'Multiline/invalid domain value {key}: {path}')
            value, tail = raw[1:end], raw[end + 1:]
            check(re.fullmatch(r'[ \t]*(?:#.*)?', tail) is not None,
                  f'Unsupported domain assignment {key}: {path}')
        else:
            value, marker, comment = raw.partition('#')
            trimmed = value.rstrip()
            tail = value[len(trimmed):] + marker + comment
            value = trimmed
        check(value and '\\' not in value, f'Unsupported domain value {key}: {path}')
        found[key] = (index, match[1], value, tail.encode('ascii'), match[4] or b'')
    check(set(found) == set(keys), f'Missing allowlisted domain variables: {path}')
    return lines, found


def expand_selected(key, entries, seen=()):
    check(key in entries and key not in seen, 'Unsupported/cyclic domain-only expansion.')
    def replace(match):
        return expand_selected(match[1] or match[2], entries, (*seen, key))
    value = REFERENCE.sub(replace, entries[key][2])
    check('$' not in value, 'Unsupported dotenv expression in domain variable.')
    return value


def validate_url(value, old_host, backup=False):
    url = urlsplit(value)
    allowed = (old_host,) if backup else (old_host, old_host.removesuffix('.id') + '.com')
    check(url.scheme == 'https' and url.hostname in allowed and
          not url.username and not url.password and not url.port and
          not url.query and not url.fragment and not re.search(r'\s', value),
          'Domain URL validation failed; values withheld.')


def validate_origin(value):
    url = urlsplit(value)
    allowed = set(HOSTS) | {host.removesuffix('.id') + '.com' for host in HOSTS}
    allowed |= {'localhost', '127.0.0.1'}
    check(url.scheme in ('http', 'https') and url.hostname in allowed and
          not url.username and not url.password and not url.path and
          not url.query and not url.fragment and not re.search(r'[\s*]', value),
          'Unexpected CORS origin; values withheld; manual review required.')


def env_plan(backup, app):
    live = APPS / app / '.env'
    keys = set(ENV_HOSTS[app])
    if app == 'be-marketplace':
        keys.add('CORS_ALLOWED_ORIGINS')
    current_lines, current = selected_assignments(live, keys)
    _, original = selected_assignments(backed_up(backup, live), keys)
    desired = {}
    for key, host in ENV_HOSTS[app].items():
        desired[key] = expand_selected(key, original)
        validate_url(desired[key], host, backup=True)
        validate_url(expand_selected(key, current), host)
    if app == 'be-marketplace':
        origins = []
        for entries in (current, original):
            origins.extend(item.strip() for item in
                           expand_selected('CORS_ALLOWED_ORIGINS', entries).split(','))
        origins.extend(REQUIRED_ORIGINS)
        origins = list(dict.fromkeys(origins))
        for origin in origins:
            validate_origin(origin)
        desired['CORS_ALLOWED_ORIGINS'] = ','.join(origins)
    # Construct only in memory. Non-domain lines, including credentials, stay byte-identical.
    candidate = current_lines.copy()
    for key, value in desired.items():
        index, prefix, _, tail, ending = current[key]
        candidate[index] = prefix + value.encode('ascii') + tail + ending
    allowed_lines = {entry[0] for entry in current.values()}
    check(all(old == new for index, (old, new) in
              enumerate(zip(current_lines, candidate)) if index not in allowed_lines),
          'Non-domain .env line changed; refusing plan.')
    changed = sum(old != new for old, new in zip(current_lines, candidate))
    print(f'ENV {live}: {changed} domain lines would change; keys={",".join(sorted(keys))}')
    if app == 'be-marketplace':
        print(f'  CORS keeps .id + .com and existing validated origins ({len(origins)} total).')
        if safe_path(live).st_mode & 0o004:
            print('  WARNING: backend .env already world-readable; no permission change made.')


def dist_files(root):
    safe_path(root, 'dir')
    files = {}
    def walk_error(error):
        raise Refusal('Cannot inspect scoped dist tree.')
    for directory, directories, names in os.walk(root, followlinks=False, onerror=walk_error):
        for name in directories:
            safe_path(Path(directory) / name, 'dir')
        for name in names:
            path = Path(directory) / name
            safe_path(path)
            files[path.relative_to(root).as_posix()] = path
    check('index.html' in files, f'dist/index.html missing: {root}')
    return files


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.digest()


def dist_plan(backup, app):
    root = APPS / app / 'dist'
    current = dist_files(root)
    original = dist_files(backed_up(backup, root))
    immutable = {name for name in current if HASHED_ASSET.fullmatch(name)}
    for name in immutable & original.keys():
        check(digest(current[name]) == digest(original[name]),
              f'Hashed-asset name collision with different bytes: {app}/{name}')
    additions = immutable - original.keys()
    print(f'DIST {root}: backup {len(original)} files + {len(additions)} immutable live assets.')
    print('  Backup index/runtime wins; SW needs separate validation. Retain full original dist until commit.')


# Read same getMonitorData used by jlist, WITHOUT importing PM2 Client/API/CLI.
# Those higher-level entry points can create files or launch a daemon. This RPC cannot.
PM2_METADATA = r'''
const root = process.argv[1];
const names = new Set(JSON.parse(process.argv[2]));
const axon = require(root + '/pm2-axon');
const rpc = require(root + '/pm2-axon-rpc');
const socket = axon.socket('req');
const client = new rpc.Client(socket);
const timer = setTimeout(() => { socket.close(); process.exit(2); }, 4000);
socket.once('error', () => { clearTimeout(timer); socket.close(); process.exit(2); });
socket.once('connect', () => {
  client.call('getMonitorData', {}, (error, list) => {
    clearTimeout(timer);
    if (error || !Array.isArray(list)) { socket.close(); process.exit(2); return; }
    const selected = list.filter(p => names.has(p.name)).map(p => ({
      name: p.name, id: p.pm_id, pid: p.pid,
      status: p.pm2_env.status, mode: p.pm2_env.exec_mode, cwd: p.pm2_env.pm_cwd
    }));
    process.stdout.write(JSON.stringify(selected));
    socket.close();
    process.exit(0);
  });
});
socket.connect('/root/.pm2/rpc.sock');
'''


def daemon_identity():
    pid_file = Path('/root/.pm2/pm2.pid')
    safe_path(pid_file)
    safe_path(Path('/root/.pm2/rpc.sock'), 'socket')
    pid = pid_file.read_text(encoding='ascii').strip()
    check(pid.isdigit() and int(pid) > 1, 'Invalid existing PM2 PID.')
    proc = Path('/proc') / pid
    check(proc.stat().st_uid == 0, 'PM2 daemon not owned by root.')
    command = (proc / 'cmdline').read_bytes()
    check(b'PM2' in command and b'God Daemon' in command and b'/root/.pm2' in command,
          'Existing PID is not expected PM2 daemon; no CLI fallback.')
    # Start time detects PID reuse. Never read /proc/*/environ.
    started = (proc / 'stat').read_text().rsplit(')', 1)[1].split()[19]
    return pid, started


def process_metadata():
    before = daemon_identity()
    safe_path(NODE)
    for module in ('pm2-axon', 'pm2-axon-rpc'):
        safe_path(PM2_MODULES / module / 'index.js')
    result = subprocess.run(
        [str(NODE), '-e', PM2_METADATA, str(PM2_MODULES), json.dumps(list(PROCESSES))],
        env={'HOME': '/root', 'PATH': str(NODE.parent) + ':/usr/bin:/bin'},
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=6, check=False,
    )
    check(result.returncode == 0, 'Existing-daemon metadata RPC failed; no startup/retry fallback.')
    check(before == daemon_identity(), 'PM2 daemon identity changed during inspection.')
    entries = json.loads(result.stdout)
    for name, directory in PROCESSES.items():
        matches = [entry for entry in entries if entry['name'] == name]
        check(len(matches) == 1, f'Expected exactly one existing PM2 process: {name}')
        entry = matches[0]
        check(entry['status'] == 'online' and isinstance(entry['id'], int) and
              isinstance(entry['pid'], int) and entry['pid'] > 1 and
              entry['cwd'] == str(directory), f'Unexpected PM2 process metadata: {name}')
        check((Path('/proc') / str(entry['pid'])).stat().st_uid == 0,
              f'Unexpected PM2 application owner: {name}')
        print(f'PM2 {name}: id={entry["id"]} pid={entry["pid"]} status=online mode={entry["mode"]}')


MANUAL = r'''
MANUAL RUNBOOK — NOT EXECUTED BY THIS SCRIPT

Apply remains DISABLED, including with both production flags. No automatic transaction
has been runtime-tested. Passing passive checks is NOT authorization or proof of a
working rollback. Do not enable apply without implementing and testing transaction recovery.

1. Arrange a maintenance window and independent recovery access. An operator must
   own one exclusive lock at /root/backups/rollback-berumrah.lock before any mutation:
   open with O_RDWR|O_NOFOLLOW|O_CREAT (mode 0600), verify regular file, root owner, one link,
   verify private 0600 permissions, then flock(LOCK_EX|LOCK_NB). Never truncate it.
   Dry runs must not open/create this lock. Coordinate
   aaPanel/deploy writers too; this lock cannot stop external writers.

2. Under umask 077, create a unique 0700 capture using tempfile.mkdtemp inside a
   verified root-owned private /root/backups/rollback-captures. Never reuse a timestamp
   directory, follow links, or truncate a pre-existing capture. Capture byte-exact
   CURRENT three .env files, both full dist trees, and three old .id vhosts, retaining
   ownership/modes and existence records. Never substitute backup credentials.
   Record original PM2 daemon PID/start time, exact process IDs, cwd/script/mode/status,
   and only domain-related runtime overrides privately. Do not dump process secrets.
   Keep snapshots and a durable operation journal; print their paths, never contents.

3. Stage ALL replacements before production swaps, using exclusive unique directories
   on each destination filesystem. Reject symlinks/hardlinks/special files and any
   unexpected stage/old destination. Stage vhost files outside Nginx's *.conf glob.
   Restore ONLY these three old vhosts from backup/files:
     /www/server/panel/vhost/nginx/berumrah.id.conf
     /www/server/panel/vhost/nginx/api.berumrah.id.conf
     /www/server/panel/vhost/nginx/dash.berumrah.id.conf
   Leave rewrite files, extension files, .com vhosts/certs, berumrah-com-support/*.inc,
   rejection/default configuration, aaPanel SQLite/site registrations and renewals alone.
   Check dependencies of old vhosts still exist; do not restore private certs blindly.

   For .env, derive only allowlisted URL assignments from backup (planner lists keys).
   Restore backend FRONTEND_URL/BACKEND_URL/DASHBOARD_URL, frontend VITE_APP_URL and
   VITE_API_URL, dashboard VITE_API_BASE_URL/VITE_FRONTEND_URL/VITE_APP_URL. Preserve
   every other byte/line, including credentials. Expand domain-only references; never
   shell-source .env. CORS_ALLOWED_ORIGINS must retain existing intended origins and
   BOTH https://berumrah.id, https://dash.berumrah.id, https://berumrah.com,
   https://dash.berumrah.com. Do not copy the old two-origin CORS expression verbatim.
   Use restrictive service-readable .env permissions, not forced world-readable modes.

   Stage each dist from backup, then merge only nonconflicting immutable hashed files
   beneath live assets/. Same name/different bytes is a hard failure. Backup index.html,
   sw.js, workbox/runtime files and nonhashed configuration take precedence. Use 0755
   directories/0644 static files and correct service ownership. Do not rebuild/change
   .com source/PWA code as part of rollback. Verify the staged index references exist.

4. Persist recovery records before each operation. Atomically replace ONLY three vhost
   files, then run /www/server/nginx/sbin/nginx -t -c /www/server/nginx/conf/nginx.conf.
   This test is APPLY-ONLY: it can open/create logs. On failure, restore original vhosts;
   do not reload invalid config. No app swaps should have happened at this point.
   Two directory renames are NOT atomic together. During maintenance, use os.rename
   from each exact dist to its unique empty old slot, then stage to exact dist. If the
   second rename fails, immediately rename old back. Track and recover BOTH apps.
   Keep full old dist trees even after promotion; no generic recursive deletion.
   Install staged domain-only env files using same-filesystem atomic replacement.
   Reject changes by concurrent writers rather than overwriting their work.

5. Update/reload only the recorded existing PM2 IDs with explicit domain/CORS overrides.
   Plain --update-env does not load .env; inherited PM2 values can override dotenv.
   Verify the loader and expansion behavior for backend AND workers. Use a reviewed
   existing-daemon update path; no pm2 ping/start/resurrect, no global dump restore,
   no duplicate workers, no reload-then-restart fallback that hides failure.
   Track even an attempted/partially failed process update for recovery.
   Test Nginx again before reload. Every reload failure is fatal, not a success message.
   Use bounded health polling only during actual apply: online named PM2 processes,
   localhost 3080/3081/3082, correct Host routing, HTTPS .id responses no longer sending
   users to .com, and API CORS with credentials for all four .id/.com app origins.
   Check .com compatibility too; retained certificates/vhosts alone do not guarantee it.

6. On ANY failure after mutations, restore original current env/vhosts and both full old
   dist trees, then original scoped process domain overrides, including partial PM2
   updates. Attempt recovery for every affected item even if one recovery fails.
   Validate recovered Nginx before any required reload. If no new config was reloaded,
   do not reload merely because candidate nginx -t failed. Never claim recovery if
   validation, process restoration, required reload, or bounded health checks fail.
   Exit nonzero and retain/print exact snapshot, journal, stage and old-tree paths for
   manual repair. SIGKILL/power loss needs journal-based manual recovery; an EXIT trap
   alone cannot guarantee a transaction. Do not remove old trees before checks commit.

7. Files/processes healthy does NOT complete rollback. Reconcile migration audit and
   saved seo-setting-before.private.json / slider-before.private.json by exact row IDs.
   Confirm the intended database privately. Stop/reconcile concurrent admin edits first.
   Never restore SQL dumps, whole DB tables, aaPanel SQLite, or arbitrary .com URLs.
   The separate Node example below loads dotenv THEN dotenv-expand before models,
   checks snapshot identity and exact expected-current values under row locks, changes
   only seo.site_url and saved slider redirect_url fields, then invalidates exact caches.
   It intentionally uses ORM transaction because the service update helper has no
   transaction/compare-and-set argument. Do not restore unrelated row metadata.
   Compare migration journal timestamps too if later edits might reuse the same URL.

   This command is MANUAL and NOT run by --manual or dry run. Start with
   ROLLBACK_DATA_APPLY=NO. After reviewing the plan, database identity and row guards,
   change only NO to YES to commit. If cache invalidation fails after commit, rows may
   already be restored: rerun guarded operation to finish caches, not a full DB restore.

cd /www/wwwroot/berumrah-marketplace/be-marketplace
env -i HOME=/root PATH=/www/server/nodejs/v22.19.0/bin:/usr/bin:/bin \
  ROLLBACK_BACKUP=__BACKUP__ ROLLBACK_DATA_APPLY=NO \
  /www/server/nodejs/v22.19.0/bin/node <<'NODE_MANUAL_ONLY'
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const dotenv = require('dotenv');
const dotenvExpand = require('dotenv-expand');
let db, redis, phase = 'environment/snapshot validation';
let committed = false;
(async () => {
  try {
    const loaded = dotenv.config({ path: '.env', quiet: true });
    assert(!loaded.error);
    dotenvExpand.expand(loaded);
    const apply = process.env.ROLLBACK_DATA_APPLY === 'YES';
    assert(['NO', 'YES'].includes(process.env.ROLLBACK_DATA_APPLY));
    const backup = process.env.ROLLBACK_BACKUP;
    assert(typeof backup === 'string' &&
      /^\/root\/backups\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(backup));
    function readSnapshot(name) {
      const file = path.join(backup, name);
      for (let p = file; ; p = path.dirname(p)) {
        const s = fs.lstatSync(p);
        assert(!s.isSymbolicLink() && s.uid === 0 && !(s.mode & 0o022));
        if (p === file) assert(s.isFile() && s.nlink === 1 && s.size < 1024 * 1024);
        else assert(s.isDirectory());
        if (p === '/') break;
      }
      return JSON.parse(fs.readFileSync(file, 'utf8'));
    }
    const seo = readSnapshot('seo-setting-before.private.json');
    const sliders = readSnapshot('slider-before.private.json');
    assert(seo && typeof seo.id === 'string' && seo.category === 'seo' &&
      seo.key === 'site_url' && seo.type === 'string' &&
      seo.value === 'https://berumrah.id' && [0, 1, false, true].includes(seo.is_public));
    assert(Array.isArray(sliders) && sliders.length > 0 && sliders.length <= 100);
    assert(new Set(sliders.map(s => s.id)).size === sliders.length);
    function expectedCurrent(old) {
      assert.equal(typeof old, 'string');
      const url = new URL(old);
      assert(url.protocol === 'https:' && !url.username && !url.password && !url.port);
      const domains = { 'berumrah.id': 'berumrah.com',
        'dash.berumrah.id': 'dash.berumrah.com', 'api.berumrah.id': 'api.berumrah.com' };
      assert(domains[url.hostname]);
      const prefix = 'https://' + url.hostname;
      assert(old.startsWith(prefix) && ['', '/', '?', '#'].includes(old.slice(prefix.length, prefix.length + 1)));
      return 'https://' + domains[url.hostname] + old.slice(prefix.length);
    }
    sliders.forEach(s => {
      assert(typeof s.id === 'string' && typeof s.updated_at === 'string');
      expectedCurrent(s.redirect_url);
    });
    db = require('./config/sequelize');
    const AppSetting = require('./models/AppSetting');
    const Slider = require('./models/Slider');
    db.options.logging = false;
    phase = 'expected-current row guards / transaction';
    let changes = 0;
    await db.transaction(async transaction => {
      const liveSeo = await AppSetting.findOne({
        where: { id: seo.id, category: 'seo', key: 'site_url' },
        transaction, lock: transaction.LOCK.UPDATE
      });
      assert(liveSeo && liveSeo.type === seo.type &&
        Boolean(liveSeo.is_public) === Boolean(seo.is_public));
      const edits = [];
      function guarded(row, field, old) {
        assert(row);
        const current = row.get(field);
        assert(current === old || current === expectedCurrent(old));
        if (current !== old) edits.push({ row, field, old });
      }
      guarded(liveSeo, 'value', seo.value);
      for (const saved of [...sliders].sort((a, b) => a.id.localeCompare(b.id))) {
        const row = await Slider.findByPk(saved.id, { transaction, lock: transaction.LOCK.UPDATE });
        guarded(row, 'redirect_url', saved.redirect_url);
      }
      changes = edits.length;
      if (apply) {
        for (const { row, field, old } of edits) {
          await row.update({ [field]: old }, { transaction, fields: [field] });
        }
      }
    });
    committed = apply;
    console.log(apply ? 'Guarded data changes committed: ' + changes :
      'Guarded preview only; planned field changes: ' + changes);
    if (!apply) return;
    phase = 'targeted cache invalidation (data already committed)';
    assert.equal(process.env.CACHE_ENABLED, 'true');
    const prefix = process.env.REDIS_CACHE_PREFIX || 'berumrah:';
    assert(prefix && !/[\s*?\[\]\\]/.test(prefix));
    const Redis = require('ioredis');
    // Dedicated maintenance connection, NOT services/redisClient's shared singleton.
    redis = new Redis({
      host: process.env.REDIS_HOST || 'localhost',
      port: Number(process.env.REDIS_PORT || 6379),
      db: Number(process.env.REDIS_DB || 0),
      password: process.env.REDIS_PASSWORD || undefined,
      lazyConnect: true, enableOfflineQueue: false, enableReadyCheck: true,
      connectTimeout: 5000, commandTimeout: 5000, maxRetriesPerRequest: 1,
      retryStrategy: () => null
    });
    redis.on('error', () => {}); // Never print connection details/credentials.
    await redis.connect();
    const exact = ['app_settings:all', 'app_settings:public', 'app_settings:stats',
      'app_settings:category:seo', 'app_settings:seo:site_url', 'seo:settings'];
    await redis.del(...exact.map(key => prefix + key));
    let cursor = '0', pages = 0;
    do {
      assert(++pages <= 10000);
      const page = await redis.scan(cursor, 'MATCH', prefix + 'sliders:list:*', 'COUNT', 100);
      cursor = page[0];
      assert(page[1].every(key => key.startsWith(prefix + 'sliders:list:')));
      if (page[1].length) await redis.del(...page[1]);
    } while (cursor !== '0');
    console.log('Targeted caches invalidated; public API/manual validation still required.');
  } catch (_) {
    console.error('Manual data operation failed during ' + phase +
      (committed ? '; data may already be committed.' : '; inspect privately before retry.'));
    process.exitCode = 1;
  } finally {
    // All cache work awaited before closing only this dedicated connection.
    if (redis) {
      try { if (redis.status === 'ready') await redis.quit(); else redis.disconnect(); }
      catch (_) { redis.disconnect(); process.exitCode = 1; }
    }
    if (db) {
      try { await db.close(); } catch (_) { process.exitCode = 1; }
    }
  }
})();
NODE_MANUAL_ONLY

8. Verify uncached public SEO/API responses, slider targets by saved IDs, login,
   credentialed CORS, callback/OAuth/payment URLs and both .id/.com clients. No complete
   rollback claim until manual data/cache and external validation pass. Keep aaPanel
   .com sites, origin TLS and auto_renew=1 intact; verify renewal method separately.

9. Existing .id redirects are 302. Historical cached 301/308 responses can persist in
   browsers; never introduce reverse .com redirects that can loop with cached .id ones.
   HSTS upgrades HTTP to HTTPS; it does not redirect between .id and .com. Do not clear
   HSTS as a domain-rollback fix. Check Cloudflare redirect rules and purge only affected
   HTML/redirect/SW URLs, not unrelated zone caches. Do not FLUSHALL/FLUSHDB.
   Browser Cache Storage/service workers are origin-specific and survive Redis/edge
   purges. A retirement worker at https://berumrah.id/sw.js can keep redirecting .id
   navigations to .com even AFTER disk/Nginx rollback. During rollback, this SAME script
   URL must serve the restored .id application worker with Cache-Control: no-store,
   HTTPS 200 JavaScript, NOT a redirect/retirement worker/HTML fallback. Remove or replace
   any exact /sw.js retirement exception in the scoped .id vhost; do not alter unrelated
   .com/support/default configuration. Check the effective response at origin AND edge.
   Verify browser registration update, activation and app relaunch on .id; check installed
   PWA and open tabs on BOTH origins. Server rollback cannot guarantee immediate browser
   recovery: an offline/stale worker can still control clients until its next update.
   Restoring the backup worker alone is not proof it initializes correctly: audit found
   missing HTML precache plus navigateFallback=index.html in old/current builds. Have
   main validate a working restored .id app worker (navigateFallback:null or an actually
   precached fallback) separately. This script does not rebuild/change source or PWA.
   Redis or Cloudflare purge does NOT replace an installed browser worker. Retain
   immutable chunks; do not bulk-delete user storage/sessions or force clients.navigate.
   Audit Search Console Change of Address, OAuth origins/callbacks and DNS explicitly.
'''


def parser():
    cli = argparse.ArgumentParser(
        prog='rollback-berumrah-domain.sh',
        description='Passive Berumrah rollback planner. APPLY DISABLED; production unchanged.',
        epilog='Apply has not been runtime-tested. --manual prints separate operator instructions.',
    )
    cli.add_argument('--backup', default=str(DEFAULT_BACKUP), metavar='PATH')
    cli.add_argument('--manual', action='store_true', help='print manual runbook; execute nothing')
    cli.add_argument('-v', '--verbose', action='store_true', help='print scoped vhost source paths')
    cli.add_argument('--apply', action='store_true', help='DISABLED; always refuses production mutation')
    cli.add_argument('--confirm-production-rollback', action='store_true',
                     help='required with --apply, but cannot unlock disabled apply')
    return cli


def authorize(args):
    # Fail closed BEFORE inspection/RPC. No apply implementation exists in this version.
    if args.apply and not args.confirm_production_rollback:
        raise Refusal('--apply requires --confirm-production-rollback. Apply is also DISABLED.')
    if args.apply:
        raise Refusal('APPLY DISABLED: transaction/process recovery not runtime-tested. No mutation performed.')
    if args.confirm_production_rollback:
        raise Refusal('--confirm-production-rollback requires --apply; apply remains DISABLED.')


def main():
    args = parser().parse_args()
    authorize(args)
    backup = backup_path(args.backup)
    if args.manual:
        print(MANUAL.replace('__BACKUP__', shlex.quote(str(backup))))
        return
    print('PASSIVE DRY RUN — APPLY DISABLED. No production changes or runtime health tests.')
    print(f'Backup: {backup}')
    for app in ENV_HOSTS:
        safe_path(APPS / app, 'dir')
        env_plan(backup, app)
    for app in ('fe-marketplace', 'dash-marketplace'):
        dist_plan(backup, app)
    for host in HOSTS:
        live = VHOSTS / f'{host}.conf'
        source = backed_up(backup, live)
        safe_path(live)
        safe_path(source)
        print(f'VHOST {live}: scoped backup replacement planned, not performed.')
        if args.verbose:
            print(f'  Source: {source}')
    for name in ('seo-setting-before.private.json', 'slider-before.private.json'):
        info = safe_path(backup / name)
        print(f'MANUAL SNAPSHOT {name}: present, {info.st_size} bytes; values not printed.')
    process_metadata()
    print('Untouched: .com/support/default config, rewrite/extensions, certificates, aaPanel, DB, source/PWA.')
    print('Skipped: nginx -t/reload, PM2 CLI/reload, health probes, lock/capture/staging, data/cache changes.')
    print('Browser caveat: .id retirement SW may keep redirecting after disk rollback; Redis purge cannot fix it.')
    print('Rollback needs restored .id /sw.js at SAME URL, HTTPS 200 + no-store, then browser update/relaunch.')
    print('Backup SW initialization also needs validation (HTML precache/navigateFallback); see --manual.')
    print('Passive checks passed; NOT proof of runtime rollback. Use --manual for guarded operator runbook.')


if __name__ == '__main__':
    try:
        main()
    except Refusal as error:
        print(f'REFUSED: {error}', file=sys.stderr)
        sys.exit(2)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, RecursionError):
        # Do not expose .env values, daemon responses, or subprocess stderr in failures.
        print('REFUSED: passive inspection failed; details withheld. No mutation performed.', file=sys.stderr)
        sys.exit(2)
PY
