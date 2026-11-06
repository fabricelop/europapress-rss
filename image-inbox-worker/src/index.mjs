import { episodeFingerprint, verifyEditorialNow, EditorialUnavailable } from './editorial-truth.mjs';
import {NEWS_CUTOVER_ISO, VISIBLE_INBOX_LIMIT, editorialTime, recentNewsEpisode,
  currentTop30Episodes, filterVisibleCandidates} from './approval-scope.mjs';

class ApprovalScopeUnavailable extends Error {}
async function top30Now(env, fetchFn = fetch) {
  const url = 'https://api.github.com/repos/fabricelop/europapress-rss/contents/trends/site-top30-current.json?ref=main';
  try {
    const r = await fetchFn(url, {headers: {
      Accept:'application/vnd.github.raw+json', 'Cache-Control':'no-cache',
      'User-Agent':'TTActualidad-Private-Inbox',
      ...(env.GITHUB_SOURCE_READ_TOKEN ? {Authorization:'Bearer '+env.GITHUB_SOURCE_READ_TOKEN} : {})
    },cache:'no-store',redirect:'error'});
    if (!r.ok) throw Error('TOP30_FETCH_FAILED');
    const raw = await r.text();
    if (raw.length > 400000) throw Error('TOP30_TOO_LARGE');
    return currentTop30Episodes(JSON.parse(raw));
  } catch { throw new ApprovalScopeUnavailable() }
}

// Private TTActualidad inbox. No automatic publication path and no public R2 links.
const SHA = /^[a-f0-9]{64}$/;
const IDENTIFIER = /^[A-Za-z0-9_-]{3,160}$/;
const PREFIX = '/v1/images';
const encoder = new TextEncoder();

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
  } });
}
function error(status, code) { return json({ error: code }, status); }
function hex(buffer) {
  return Array.from(new Uint8Array(buffer), v => v.toString(16).padStart(2, '0')).join('');
}
async function hash(value) {
  return hex(await crypto.subtle.digest('SHA-256', value));
}
function identity(value) {
  if (!value || typeof value !== 'object' ||
      !['ttittulares', 'ttendencias'].includes(value.project) ||
      !IDENTIFIER.test(value.editorialId || '') ||
      !Number.isSafeInteger(value.revision) || value.revision < 0 ||
      typeof value.episodeFingerprint !== 'string' || !SHA.test(value.episodeFingerprint) ||
      typeof value.commandId !== 'string' || value.commandId.length < 3 || value.commandId.length > 200 ||
      typeof value.rasterSHA256 !== 'string' || !SHA.test(value.rasterSHA256)) {
    throw new TypeError('INVALID_IDENTITY');
  }
  return {
    project: value.project, editorialId: value.editorialId, revision: value.revision,
    episodeFingerprint: value.episodeFingerprint, commandId: value.commandId,
    rasterSHA256: value.rasterSHA256,
  };
}
async function candidateID(i) {
  return hash(encoder.encode(JSON.stringify(identity(i))));
}
function assertText(value, max) {
  if (typeof value !== 'string' || !value.trim() || value.length > max) throw new TypeError('INVALID_TEXT');
  return value;
}
function token(request) {
  const header = request.headers.get('Authorization') || '';
  return /^Bearer [^\s]+$/.test(header) ? header.slice(7) : null;
}
async function editor(request, env, githubFetch) {
  const access = token(request);
  if (!access || !env.APP_GITHUB_USER_ID) return null;
  const res = await githubFetch('https://api.github.com/user', {
    headers: { Authorization: 'Bearer ' + access, Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'TTActualidad-Image-Inbox' },
    redirect: 'error',
  });
  if (!res.ok) return null;
  const user = await res.json();
  return String(user.id) === String(env.APP_GITHUB_USER_ID) ? String(user.id) : null;
}
async function ingest(request, env, githubFetch = fetch) {
  const secret = request.headers.get('X-TT-Ingest-Key') || '';
  if (!env.INGEST_TOKEN || env.INGEST_TOKEN.length < 32 ||
      secret.length !== env.INGEST_TOKEN.length || secret !== env.INGEST_TOKEN) {
    return error(401, 'UNAUTHORIZED_INGEST');
  }
  const declaredLength = Number(request.headers.get('Content-Length') || '0');
  if (declaredLength > 12_000_000) return error(413, 'IMAGE_TOO_LARGE');
  const form = await request.formData();
  const raw = form.get('image');
  const metadataJSON = form.get('metadata');
  if (!raw || typeof raw.arrayBuffer !== 'function' || typeof metadataJSON !== 'string') {
    return error(400, 'MISSING_IMAGE_OR_METADATA');
  }
  const meta = JSON.parse(metadataJSON);
  const original = await raw.arrayBuffer();
  const b = new Uint8Array(original);
  if (b.length < 24 || b.length > 10_000_000 ||
      ![137,80,78,71,13,10,26,10].every((v, n) => b[n] === v)) {
    return error(415, 'ORIGINAL_PNG_REQUIRED');
  }
  const originalSHA = await hash(original);
  const i = identity({ ...meta.identity, rasterSHA256: originalSHA });
  if (meta.identity?.rasterSHA256 && meta.identity.rasterSHA256 !== originalSHA) {
    return error(409, 'RASTER_SHA_MISMATCH');
  }
  const title = assertText(meta.title, 300);
  const editorialText = assertText(meta.editorialText, 4000);
  const originalAt = editorialTime(meta.editorialAt);
  if (i.project === 'ttittulares' && !recentNewsEpisode(meta.editorialAt)) {
    return error(409,'NEWS_BEFORE_CUTOVER');
  }
  if (i.project === 'ttendencias') {
    const scope = await top30Now(env, githubFetch);
    if (!scope.some(row=>row.editorialId===i.editorialId && row.revision===i.revision)) {
      return error(409,'NOT_CURRENT_TOP30');
    }
  }
  // A self-declared hash is insufficient: bind the episode to the exact
  // editorial bytes and identity, including revision 0 after a new episode.
  if ((await episodeFingerprint({ ...i, editorialText })) !== i.episodeFingerprint) {
    return error(409, 'EPISODE_FINGERPRINT_MISMATCH');
  }
  const id = await candidateID(i);
  const r2key = `private/${id}/${originalSHA}.png`;
  await env.ORIGINALS.put(r2key, original, { httpMetadata: { contentType: 'image/png' } });
  const inserted = await env.DB.prepare(`INSERT OR IGNORE INTO image_candidates (
    id, project, editorial_id, revision, episode_fingerprint, command_id,
    raster_sha256, object_key, title, editorial_text, editorial_at, status, created_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)`).bind(
    id, i.project, i.editorialId, i.revision, i.episodeFingerprint,
    i.commandId, originalSHA, r2key, title, editorialText,
    originalAt===null?null:new Date(originalAt).toISOString(), new Date().toISOString(),
  ).run();
  // Repeated ingest is idempotent, never reopens rejected/approved images.
  return json({ id, state: inserted.meta?.changes ? 'pending' : 'existing' }, inserted.meta?.changes ? 201 : 200);
}
function rowIdentity(row) {
  return {
    project: row.project, editorialId: row.editorial_id, revision: row.revision,
    episodeFingerprint: row.episode_fingerprint, commandId: row.command_id,
    rasterSHA256: row.raster_sha256,
  };
}
// Stable newest-first pagination. The old ASC LIMIT 100 returned the oldest
// pictures forever and hid every recent one when the inbox exceeded 100.
function listPage(url) {
  const rawLimit = url.searchParams.get('limit');
  const limit = rawLimit === null ? VISIBLE_INBOX_LIMIT : Number(rawLimit);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > VISIBLE_INBOX_LIMIT) {
    throw new TypeError('INVALID_PAGE_LIMIT');
  }
  const before = url.searchParams.get('before');
  if (!before) return { limit, before: null };
  const separator = before.lastIndexOf('|');
  if (separator < 1) throw new TypeError('INVALID_PAGE_CURSOR');
  const createdAt = before.slice(0, separator), id = before.slice(separator + 1);
  const date = new Date(createdAt);
  if (!SHA.test(id) || !Number.isFinite(date.valueOf()) ||
      date.toISOString() !== createdAt) {
    throw new TypeError('INVALID_PAGE_CURSOR');
  }
  return { limit, before: { createdAt, id } };
}
async function list(env, url, githubFetch = fetch) {
  const {limit,before} = listPage(url);
  const current = await top30Now(env,githubFetch);
  const exactTrends = current.length ? "(project='ttendencias' AND (editorial_id,revision) IN (" +
    current.map(()=>'(?,?)').join(',') + "))" : "0";
  // Rank ALL decisions before restricting to pending. Rejecting a newer PNG
  // must not reveal an older duplicate and demand approval again.
  const sql = [
    'WITH ranked AS (',
    ' SELECT id, project, editorial_id, revision, episode_fingerprint, command_id,',
    ' raster_sha256, title, editorial_text, editorial_at, created_at, status,',
    ' ROW_NUMBER() OVER (PARTITION BY project, editorial_id, revision',
    ' ORDER BY created_at DESC, id DESC) AS rn',
    ' FROM image_candidates WHERE ' + exactTrends,
    " OR (project='ttittulares' AND editorial_at >= ?)",
    ') SELECT id,project,editorial_id,revision,episode_fingerprint,command_id,',
    ' raster_sha256,title,editorial_text,editorial_at,created_at,status FROM ranked',
    " WHERE rn=1 AND status='pending'",
    before ? 'AND (created_at < ? OR (created_at = ? AND id < ?))' : '',
    'ORDER BY created_at DESC,id DESC LIMIT ?',
  ].join('\n');
  const args = [...current.flatMap(x=>[x.editorialId,x.revision]),NEWS_CUTOVER_ISO,
    ...(before?[before.createdAt,before.createdAt,before.id]:[]),limit+1];
  const result = await env.DB.prepare(sql).bind(...args).all();
  const rows = filterVisibleCandidates(result.results||[],current,limit+1,before);
  const hasMore = rows.length > limit;
  const page = rows.slice(0,limit);
  const last = page[page.length-1];
  return json({items:page.map(row=>({
    id:row.id,identity:rowIdentity(row),title:row.title,
    editorialText:row.editorial_text,editorialAt:row.editorial_at,
    createdAt:row.created_at,
  })),hasMore,nextCursor:hasMore?last.created_at+'|'+last.id:null,
    pageLimit:VISIBLE_INBOX_LIMIT});
}
async function preview(env, id) {
  const row = await env.DB.prepare(`SELECT object_key FROM image_candidates
    WHERE id=? AND status='pending'`).bind(id).first();
  if (!row) return error(404, 'NOT_IN_INBOX');
  const obj = await env.ORIGINALS.get(row.object_key);
  if (!obj) return error(404, 'ORIGINAL_NOT_FOUND');
  return new Response(obj.body, { headers: {
    'Content-Type': 'image/png', 'Content-Disposition': 'inline',
    'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff',
  } });
}
function publisher(request, env) {
  // Separate scoped secret, never reusing the editor OAuth or the ingest key.
  const given = request.headers.get('X-TT-Publish-Key') || '';
  return Boolean(env.PUBLISH_TOKEN && env.PUBLISH_TOKEN.length >= 32 &&
    given.length === env.PUBLISH_TOKEN.length && given === env.PUBLISH_TOKEN);
}
async function publicationQueue(env) {
  const r = await env.DB.prepare(`SELECT id, project, editorial_id, revision,
    episode_fingerprint, command_id, raster_sha256, title, editorial_text, decided_at
    FROM image_candidates WHERE status='approved_awaiting_publication'
    ORDER BY decided_at ASC LIMIT 100`).all();
  return json({ items: (r.results || []).map(row => ({
    id: row.id, identity: rowIdentity(row), title: row.title,
    state: 'approved_awaiting_publication',
    editorialText: row.editorial_text, approvedAt: row.decided_at,
  })) });
}
async function publicationOriginal(env, id, githubFetch) {
  const row = await env.DB.prepare(`SELECT object_key, raster_sha256, project, editorial_id, revision,
      episode_fingerprint, command_id, editorial_text FROM image_candidates
    WHERE id=? AND status='approved_awaiting_publication'`).bind(id).first();
  if (!row) return error(404, 'NOT_APPROVED');
  // Revalidate at hand-off: an approval for a later-changed READY entry
  // must never yield bytes to a publisher. Publisher re-checks again before
  // the actual remote Sites/APP commit.
  if (!env.GITHUB_SOURCE_READ_TOKEN) return error(503, 'SOURCE_VERIFICATION_NOT_CONFIGURED');
  if (await verifyEditorialNow(rowIdentity(row), row.editorial_text,
    githubFetch, env.GITHUB_SOURCE_READ_TOKEN) !== 'current') {
    return error(409, 'EDITORIAL_CHANGED_OR_NOT_READY');
  }
  const obj = await env.ORIGINALS.get(row.object_key);
  if (!obj) return error(503, 'ORIGINAL_NOT_FOUND');
  const bytes = await obj.arrayBuffer();
  if ((await hash(bytes)) !== row.raster_sha256) return error(409, 'RASTER_CHANGED');
  return new Response(bytes, { headers: {
    'Content-Type': 'image/png', 'Cache-Control': 'private, no-store',
    'Content-Disposition': 'attachment; filename="approved-original.png"',
    'X-Original-SHA256': row.raster_sha256, 'X-Content-Type-Options': 'nosniff',
  } });
}
async function decide(request, env, id, actor, githubFetch) {
  const input = await request.json();
  if (!input || !['approve', 'reject'].includes(input.action)) return error(400, 'INVALID_ACTION');
  const expected = identity(input.expectedIdentity);
  if ((await candidateID(expected)) !== id) return error(409, 'STALE_CANDIDATE');
  // Approval must re-check main; rejection only clears the private inbox.
  // A stale/removed READY row can never receive a new approval.
  if (input.action === 'approve') {
    const current = await env.DB.prepare(`SELECT editorial_text, status FROM image_candidates
      WHERE id=? AND status='pending'`).bind(id).first();
    if (!current) {
      const prior = await env.DB.prepare(`SELECT status FROM image_candidates WHERE id=?`).bind(id).first();
      if (prior?.status === 'approved_awaiting_publication') {
        return json({ id, state: prior.status, alreadyApplied: true });
      }
      return error(409, 'ALREADY_DECIDED_OR_STALE');
    }
    if ((await episodeFingerprint({ ...expected, editorialText: current.editorial_text })) !== expected.episodeFingerprint) {
      return error(409, 'EPISODE_FINGERPRINT_MISMATCH');
    }
    const verdict = await verifyEditorialNow(expected, current.editorial_text, githubFetch, token(request));
    if (verdict !== 'current') return error(409, 'EDITORIAL_CHANGED_OR_NOT_READY');
  }
  const status = input.action === 'approve' ? 'approved_awaiting_publication' : 'rejected';
  const result = await env.DB.prepare(`UPDATE image_candidates SET status=?, decided_at=?,
    decided_by=? WHERE id=? AND status='pending' AND project=? AND editorial_id=?
    AND revision=? AND episode_fingerprint=? AND command_id=? AND raster_sha256=?`).bind(
    status, new Date().toISOString(), actor, id, expected.project, expected.editorialId,
    expected.revision, expected.episodeFingerprint, expected.commandId,
    expected.rasterSHA256,
  ).run();
  if ((result.meta?.changes || 0) === 1) {
    // APPROVE is an intent only: publication is forbidden until the separate
    // publisher revalidates GitHub, actual raster SHA and BOTH app+Sites receipts.
    return json({ id, state: status });
  }
  const old = await env.DB.prepare(`SELECT status FROM image_candidates WHERE id=?`).bind(id).first();
  if (old?.status === status) return json({ id, state: status, alreadyApplied: true });
  return error(409, 'ALREADY_DECIDED_OR_STALE');
}
export async function handleRequest(request, env, githubFetch = fetch) {
  try {
    const url = new URL(request.url);
    if (!env.DB || !env.ORIGINALS) return error(503, 'STORAGE_NOT_CONFIGURED');
    if (url.pathname === '/healthz' && request.method === 'GET') return json({ ok: true });
    // Publish hand-off is PRIVATE and read-only: this service never writes
    // publicly visible catalogs or changes the 'published' state.
    if (url.pathname === '/v1/publications' || url.pathname.startsWith('/v1/publications/')) {
      if (!publisher(request, env)) return error(401, 'UNAUTHORIZED_PUBLISHER');
      if (url.pathname === '/v1/publications' && request.method === 'GET') return await publicationQueue(env);
      const allowed = /^\/v1\/publications\/([a-f0-9]{64})\/original$/.exec(url.pathname);
      if (allowed && request.method === 'GET') return await publicationOriginal(env, allowed[1], githubFetch);
      return error(404, 'NOT_FOUND');
    }
    if (url.pathname === PREFIX + '/ingest' && request.method === 'POST') return await ingest(request, env, githubFetch);
    const who = await editor(request, env, githubFetch);
    if (!who) return error(401, 'UNAUTHORIZED_EDITOR');
    if (url.pathname === PREFIX && request.method === 'GET') return await list(env, url, githubFetch);
    const match = new RegExp(`^${PREFIX}/([a-f0-9]{64})(?:/(original|decision))?$`).exec(url.pathname);
    if (!match) return error(404, 'NOT_FOUND');
    const [, id, action] = match;
    if (request.method === 'GET' && action === 'original') return await preview(env, id);
    if (request.method === 'POST' && action === 'decision') return await decide(request, env, id, who, githubFetch);
    return error(405, 'METHOD_NOT_ALLOWED');
  } catch (e) {
    if (e instanceof EditorialUnavailable) return error(503, 'EDITORIAL_SOURCE_UNAVAILABLE');
    if (e instanceof ApprovalScopeUnavailable) return error(503, 'TOP30_SCOPE_UNAVAILABLE');
    if (e instanceof SyntaxError || e instanceof TypeError) return error(400, 'INVALID_REQUEST');
    // Never leak tokens, original bytes, private object names, SQL internals.
    return error(503, 'TEMPORARILY_UNAVAILABLE');
  }
}
export default { fetch(request, env) { return handleRequest(request, env); } };