'use strict';
// Publishes ONLY optional Windows X evidence, with an isolated Git index.
// No checkout/reset/rebase, no mutation of shared worktree, editorial or SeLoRecordamos.
const fs = require('node:fs'), os = require('node:os');
const path = require('node:path'), cp = require('node:child_process');
const { assembleEvidence, validPost } = require('./x_context.js');
// Isolated TT-specific Git store, no writes to the SeLoRecordamos repository.
const repo = process.env.TT_X_GIT_REPO || path.resolve(__dirname, '..');
const EVIDENCE = 'trends/x-context-evidence.json';
const QUEUE = 'trends/editorial-queue.json';
function git(args, env = {}) {
  // Git safe.directory is protected configuration. Trust only the explicit
  // TT-XContext git-store for this invocation, including commit-tree and push.
  const trusted = 'safe.directory=' + path.resolve(repo).replace(/\\/g, '/');
  return cp.execFileSync('git', ['-c', trusted, ...args], {
    cwd: repo, encoding: 'utf8', timeout: 90000,
    env: { ...process.env, ...env }, maxBuffer: 16 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  }).trim();
}
function gitJSON(ref, file, fallback) {
  try { return JSON.parse(git(['show', ref + ':' + file])); } catch (_) { return fallback; }
}
function validEntry(x, current, now) {
  if (!x || x.source !== 'x_recent_posts_windows' || !['ok', 'empty', 'error'].includes(x.status)) return null;
  const k = String(x.id || '') + ':' + String(x.revision ?? 0);
  const item = current.get(k);
  if (!item || String(item.name) !== String(x.name)) return null;
  const date = Date.parse(String(x.searched_at || ''));
  if (!Number.isFinite(date) || date > now + 300000 || date < now - 6 * 3600000) return null;
  const posts = (Array.isArray(x.posts) ? x.posts : []).filter(p => validPost(p, now)).slice(0, 8)
    .map(p => ({ id: String(p.id), author: String(p.author || '').slice(0, 18),
      datetime: p.datetime, url: p.url, text: p.text.slice(0, 900) }));
  return { id: item.id, revision: Number(item.revision), name: item.name,
    searched_at: x.searched_at, source: 'x_recent_posts_windows',
    search_url: String(x.search_url || '').slice(0, 300),
    status: x.status === 'ok' && !posts.length ? 'empty' : x.status,
    posts, ...(x.status === 'error' ? { reason: String(x.reason || 'local_x_failed').slice(0, 80),
      http_status: Number(x.http_status) || null } : {}) };
}
function mergeForPublish(remote, local, queue, now = Date.now()) {
  const active = new Map((Array.isArray(queue.items) ? queue.items : [])
    .filter(x => x && ['preparing', 'update', 'problematic'].includes(x.status))
    .map(x => [String(x.id) + ':' + String(x.revision ?? 0), x]));
  const updates = [];
  for (const x of (Array.isArray(local.items) ? local.items : [])) {
    const clean = validEntry(x, active, now);
    if (!clean) continue;
    const old = (Array.isArray(remote.items) ? remote.items : []).find(y =>
      y && String(y.id) === clean.id && Number(y.revision) === clean.revision);
    if (old && Date.parse(String(old.searched_at || '')) >= Date.parse(clean.searched_at)) continue;
    updates.push(clean);
  }
  return { updates, merged: assembleEvidence(remote, updates, now) };
}
function publish(localPath) {
  const local = JSON.parse(fs.readFileSync(localPath, 'utf8'));
  if (!Array.isArray(local.items)) throw Error('Invalid isolated Windows evidence');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tt-x-publish-'));
  const dest = path.join(tmpDir, 'merged.json');
  const index = path.join(tmpDir, 'index');
  const gitEnv = { GIT_INDEX_FILE: index,
    GIT_AUTHOR_NAME: 'TT X Context', GIT_AUTHOR_EMAIL: 'tt-x-context@users.noreply.github.com',
    GIT_COMMITTER_NAME: 'TT X Context', GIT_COMMITTER_EMAIL: 'tt-x-context@users.noreply.github.com' };
  try {
    const remoteUrl = git(['remote', 'get-url', 'origin']);
    if (!/^https:\/\/github\.com\/fabricelop\/europapress-rss(?:\.git)?\/?$/i.test(remoteUrl))
      throw Error('Unexpected TT-XContext git-store origin');
    // Independent local lock is held by the Windows runner; remote races
    // are handled by fast-forward push with fetch and retry.
    return (() => {
      for (let attempt = 1; attempt <= 4; attempt++) {
        git(['fetch', '--quiet', '--no-tags', 'origin', 'main']);
        const base = git(['rev-parse', 'refs/remotes/origin/main']);
        const remote = gitJSON(base, EVIDENCE, { items: [] });
        const queue = gitJSON(base, QUEUE, { items: [] });
        const { updates, merged } = mergeForPublish(remote, local, queue);
        if (!updates.length) { console.log('TT_X_WINDOWS no_fresh_matching_evidence'); return false; }
        fs.writeFileSync(dest, JSON.stringify(merged, null, 2) + '\n', 'utf8');
        try { fs.unlinkSync(index); } catch (_) {}
        git(['read-tree', base], gitEnv);
        const blob = git(['hash-object', '-w', '--', dest]);
        git(['update-index', '--add', '--cacheinfo', '100644,' + blob + ',' + EVIDENCE], gitEnv);
        const tree = git(['write-tree'], gitEnv);
        const commit = git(['commit-tree', tree, '-p', base, '-m',
          'Update optional TTendencias X evidence from Windows'], gitEnv);
        try {
          git(['push', 'origin', commit + ':refs/heads/main']);
          console.log('TT_X_WINDOWS PUBLISHED count=' + updates.length + ' commit=' + commit.slice(0, 12));
          return true;
        } catch (error) {
          if (attempt === 4) throw Error('Push failed; local evidence kept for retry: ' + String(error.message).slice(0, 180));
        }
      }
    })();
  } finally { fs.rmSync(tmpDir, { recursive: true, force: true }); }
}
if (require.main === module) {
  try { if (!process.argv[2]) throw Error('Usage: node publish_x_context.js LOCAL_EVIDENCE_FILE');
    publish(path.resolve(process.argv[2])); }
  catch (e) { console.error('TT_X_WINDOWS publish_error=' + String(e.message || e).slice(0, 280)); process.exitCode = 1; }
}
module.exports = { mergeForPublish, validEntry };
