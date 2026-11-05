import { episodeFingerprint, verifyEditorialNow, EditorialUnavailable } from './editorial-truth.mjs';
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
async function ingest(request, env) {
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
    raster_sha256, object_key, title, editorial_text, status, created_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)`).bind(
    id, i.project, i.editorialId, i.revision, i.episodeFingerprint,
    i.commandId, originalSHA, r2key, title, editorialText, new Date().toISOString(),
  ).run();
  // Repeated ingest is idempotent, never reopens rejected/approved images.
  return json({ id, state: inserted.meta?.changes ? 'pending' : 'existing' }, inserted.meta?.changes ? 201 : 200);
}

async function ingestManual(request, env, githubFetch) {
  // Browser/iPhone editor uploads use the same *private* original inbox as PC
  // imports, authenticated by the existing GitHub OAuth editor session.
  // No PC ingest key or publication key is ever sent to a mobile device.
  const declared = Number(request.headers.get('Content-Length') || '0');
  if (declared > 12_000_000) return error(413, 'IMAGE_TOO_LARGE');
  const form = await request.formData();
  const raw = form.get('image');
  const textMetadata = form.get('metadata');
  if (!raw || typeof raw.arrayBuffer !== 'function' || typeof textMetadata !== 'string') {
    return error(400, 'MISSING_IMAGE_OR_METADATA');
  }
  const meta = JSON.parse(textMetadata);
  const project = meta?.project;
  const editorialId = meta?.editorialId;
  const revision = meta?.revision;
  const commandId = meta?.commandId;
  const title = assertText(meta?.title, 300);
  const editorialText = assertText(meta?.editorialText, 4000);
  const expectedHash = meta?.rasterSHA256;
  if (!['ttittulares', 'ttendencias'].includes(project) ||
      !IDENTIFIER.test(editorialId || '') ||
      !Number.isSafeInteger(revision) || revision < 0 ||
      typeof commandId !== 'string' || commandId.length < 3 || commandId.length > 200 ||
      !SHA.test(expectedHash || '')) return error(400, 'INVALID_IDENTITY');
  const original = await raw.arrayBuffer();
  const bytes = new Uint8Array(original);
  if (bytes.length < 24 || bytes.length > 8_000_000) return error(413, 'IMAGE_TOO_LARGE');
  if (![137,80,78,71,13,10,26,10].every((v, i) => bytes[i] === v) ||
      ![73,72,68,82].every((v, i) => bytes[i+12] === v)) {
    return error(415, 'ORIGINAL_PNG_REQUIRED');
  }
  const view = new DataView(original);
  const width = view.getUint32(16);
  const height = view.getUint32(20);
  if (!width || !height || width > 8192 || height > 8192 ||
      width * height > 40_000_000) return error(415, 'INVALID_IMAGE_DIMENSIONS');
  const actualSHA = await hash(original);
  if (actualSHA !== expectedHash) return error(409, 'RASTER_SHA_MISMATCH');
  // The editorial text, not a user-selected rank/title, is authoritative.
  // Verify BEFORE writing an original, and again through /decision.
  const episode = await episodeFingerprint({ project, editorialId, revision, editorialText });
  const candidate = identity({ project, editorialId, revision, episodeFingerprint: episode,
    commandId, rasterSHA256: actualSHA });
  const verdict = await verifyEditorialNow(candidate, editorialText, githubFetch, token(request));
  if (verdict !== 'current') return error(409, 'EDITORIAL_CHANGED_OR_NOT_READY');
  const id = await candidateID(candidate);
  const existing = await env.DB.prepare(`SELECT status FROM image_candidates WHERE id=?`)
    .bind(id).first();
  if (existing) return json({ id, state: existing.status, identity: candidate, existing: true });
  const key = `private/${id}/${actualSHA}.png`;
  await env.ORIGINALS.put(key, original, { httpMetadata: { contentType: 'image/png' } });
  const inserted = await env.DB.prepare(`INSERT OR IGNORE INTO image_candidates (
    id, project, editorial_id, revision, episode_fingerprint, command_id,
    raster_sha256, object_key, title, editorial_text, status, created_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)`).bind(
    id, project, editorialId, revision, episode, commandId,
    actualSHA, key, title, editorialText, new Date().toISOString()
  ).run();
  if (!inserted.meta?.changes) {
    const current = await env.DB.prepare(`SELECT status FROM image_candidates WHERE id=?`)
      .bind(id).first();
    return json({ id, state: current?.status || 'existing', identity: candidate, existing: true });
  }
  return json({ id, state: 'pending', identity: candidate }, 201);
}

function rowIdentity(row) {
  return {
    project: row.project, editorialId: row.editorial_id, revision: row.revision,
    episodeFingerprint: row.episode_fingerprint, commandId: row.command_id,
    rasterSHA256: row.raster_sha256,
  };
}
async function list(env) {
  const result = await env.DB.prepare(`SELECT id, project, editorial_id, revision,
    episode_fingerprint, command_id, raster_sha256, title, editorial_text, created_at
    FROM image_candidates WHERE status='pending' ORDER BY created_at ASC LIMIT 100`).all();
  return json({ items: (result.results || []).map(row => ({
    id: row.id, identity: rowIdentity(row), title: row.title,
    editorialText: row.editorial_text, createdAt: row.created_at,
  })) });
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
  // The editor explicitly approved the immutable episode identity.
  // Removing a card from Listas does NOT revoke its right to an image.
  // Never contact an external READY/Lists source at publication time:
  // those files are transient/large and a failed fetch caused intermittent
  // 503 errors while permanently blocking archived editorial episodes.
  const stored = rowIdentity(row);
  if ((await episodeFingerprint({ ...stored, editorialText: row.editorial_text })) !==
      stored.episodeFingerprint) return error(409, 'EPISODE_FINGERPRINT_MISMATCH');
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
  // Approval is tied to the immutable, exact candidate delivered to
  // this private inbox. Current Listas presence is irrelevant: editorial
  // items can be withdrawn/published while their images remain valid.
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
    // Authenticated editor + candidateID + fingerprint + conditional DB
    // update protect against mismatched IDs/revisions and double decisions.
    // Ingest of manual originals already validates GitHub identity once.
    // The trusted PC import is authenticated by its separate secret.
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
    if (url.pathname === PREFIX + '/ingest' && request.method === 'POST') return await ingest(request, env);
    const who = await editor(request, env, githubFetch);
    if (!who) return error(401, 'UNAUTHORIZED_EDITOR');
    if (url.pathname === PREFIX + '/manual' && request.method === 'POST') {
      return await ingestManual(request, env, githubFetch);
    }
    if (url.pathname === PREFIX && request.method === 'GET') return await list(env);
    const match = new RegExp(`^${PREFIX}/([a-f0-9]{64})(?:/(original|decision))?$`).exec(url.pathname);
    if (!match) return error(404, 'NOT_FOUND');
    const [, id, action] = match;
    if (request.method === 'GET' && action === 'original') return await preview(env, id);
    if (request.method === 'POST' && action === 'decision') return await decide(request, env, id, who, githubFetch);
    return error(405, 'METHOD_NOT_ALLOWED');
  } catch (e) {
    if (e instanceof EditorialUnavailable) return error(503, 'EDITORIAL_SOURCE_UNAVAILABLE');
    if (e instanceof SyntaxError || e instanceof TypeError) return error(400, 'INVALID_REQUEST');
    // Never leak tokens, original bytes, private object names, SQL internals.
    return error(503, 'TEMPORARILY_UNAVAILABLE');
  }
}
export default { fetch(request, env) { return handleRequest(request, env); } };