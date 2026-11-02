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
async function decide(request, env, id, actor) {
  const input = await request.json();
  if (!input || !['approve', 'reject'].includes(input.action)) return error(400, 'INVALID_ACTION');
  const expected = identity(input.expectedIdentity);
  if ((await candidateID(expected)) !== id) return error(409, 'STALE_CANDIDATE');
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
    if (url.pathname === PREFIX + '/ingest' && request.method === 'POST') return await ingest(request, env);
    const who = await editor(request, env, githubFetch);
    if (!who) return error(401, 'UNAUTHORIZED_EDITOR');
    if (url.pathname === PREFIX && request.method === 'GET') return await list(env);
    const match = new RegExp(`^${PREFIX}/([a-f0-9]{64})(?:/(original|decision))?$`).exec(url.pathname);
    if (!match) return error(404, 'NOT_FOUND');
    const [, id, action] = match;
    if (request.method === 'GET' && action === 'original') return await preview(env, id);
    if (request.method === 'POST' && action === 'decision') return await decide(request, env, id, who);
    return error(405, 'METHOD_NOT_ALLOWED');
  } catch (e) {
    if (e instanceof SyntaxError || e instanceof TypeError) return error(400, 'INVALID_REQUEST');
    // Never leak tokens, original bytes, private object names, SQL internals.
    return error(503, 'TEMPORARILY_UNAVAILABLE');
  }
}
export default { fetch(request, env) { return handleRequest(request, env); } };