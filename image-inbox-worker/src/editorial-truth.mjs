// The approval gate only trusts the exact current READY text, ID and revision
// returned from GitHub main. Rank/title similarity and cached preview URLs are
// NEVER identity. The publisher must perform the same check once more.
const encoder = new TextEncoder();
const PAGES = Object.freeze({
  ttittulares: 'ttittulares/prepared.json',
  ttendencias: 'trends/telegram-manual-explained.json',
});

export class EditorialUnavailable extends Error {
  constructor() { super('EDITORIAL_SOURCE_UNAVAILABLE'); }
}

export function canonicalEpisode({project, editorialId, revision, editorialText}) {
  if (!(project in PAGES) || typeof editorialId !== 'string' || !editorialId ||
      !Number.isSafeInteger(revision) || revision < 0 ||
      typeof editorialText !== 'string' || !editorialText.trim()) {
    throw new TypeError('INVALID_EDITORIAL_EPISODE');
  }
  return JSON.stringify({project, editorialId, revision, editorialText});
}

export async function episodeFingerprint(snapshot) {
  const bytes = encoder.encode(canonicalEpisode(snapshot));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
}

// Use exactly the repositories read by the iPhone's Listas view. Trending
// identities live in telegram-manual-explained, NOT trends/prepared.json.
const DECISIONS = Object.freeze({
  ttittulares: 'ttittulares/decisions.json',
  ttendencias: 'trends/mobile-decisions.json',
});
const TERMINAL = new Set(['published', 'dismissed', 'deleted', 'discarded', 'removed']);

export function readyTextFromMain(data, identity) {
  if (!data || !Array.isArray(data.items)) throw new EditorialUnavailable();
  const matches = data.items.filter(row =>
    (identity.project === 'ttittulares' ? row.event_id : row.id) === identity.editorialId);
  if (!matches.length) return null;
  // Multiple rows can refer to the same editorial ID as the news develops.
  // Only the most recent identity is permitted, never an older revision.
  const latest = matches.sort((a, b) =>
    Number(b.revision ?? 0) - Number(a.revision ?? 0) ||
    String(b.explained_at || b.prepared_at || b.updated_at || '').localeCompare(
      String(a.explained_at || a.prepared_at || a.updated_at || '')))[0];
  if (Number(latest.revision ?? 0) !== identity.revision ||
      latest.rewrite_pending === true) return null;
  if (identity.project === 'ttendencias' &&
      String(latest.status || '').toLowerCase() !== 'explained') return null;
  const text = identity.project === 'ttittulares'
    ? latest.tweet?.text : latest.explanation;
  return typeof text === 'string' && text.trim() ? text : null;
}

function isClosed(decisions, identity, editorial) {
  if (!decisions || !Array.isArray(decisions.items)) throw new EditorialUnavailable();
  const key = identity.project === 'ttittulares' ? 'event_id' : 'id';
  // Match iOS' guard: a closure for an older revision, or a closure preceding
  // a new explained_at, cannot suppress a fresh independently reworked card.
  const candidates = editorial.items.filter(row =>
    (identity.project === 'ttittulares' ? row.event_id : row.id) === identity.editorialId &&
    Number(row.revision ?? 0) === identity.revision);
  const sourceTime = identity.project === 'ttendencias'
    ? Math.max(...candidates.map(x => Date.parse(x.explained_at || '') || 0))
    : 0;
  return decisions.items.some(row => {
    if (row[key] !== identity.editorialId ||
        !TERMINAL.has(String(row.status || '').toLowerCase())) return false;
    if (identity.project === 'ttittulares') return true;
    const closedRevision = Number.isSafeInteger(row.revision) ? row.revision : 0;
    if (closedRevision !== identity.revision) return closedRevision > identity.revision;
    const closedAt = Date.parse(row.deleted_at || row.dismissed_at ||
      row.published_at || row.removed_at || row.updated_at || row.delivered_at || row.decided_at || '');
    return !(Number.isFinite(closedAt) && sourceTime > 0 && closedAt < sourceTime - 60_000);
  });
}

async function freshMain(path, fetchFn, token) {
  let response;
  try {
    response = await fetchFn(`https://api.github.com/repos/fabricelop/europapress-rss/contents/${path}?ref=main`, {
      headers: { Authorization: 'Bearer ' + token,
        Accept: 'application/vnd.github.raw+json', 'Cache-Control': 'no-cache',
        'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'TTActualidad-Approval-Gate' },
      cache: 'no-store', redirect: 'error',
    });
  } catch { throw new EditorialUnavailable(); }
  if (!response || !response.ok) throw new EditorialUnavailable();
  try {
    const text = await response.text();
    // The active trends ledger is already several MB. Treat the documented
    // range as valid while bounding memory and rejecting truncated/non-JSON.
    if (!text || text.length > 12_000_000) throw new Error('source too large');
    const body = JSON.parse(text);
    if (!body || !Array.isArray(body.items)) throw new Error('malformed source');
    return body;
  } catch { throw new EditorialUnavailable(); }
}

// Three-valued verdict: 'current' / 'stale' / exception (network unavailable).
// Use a fresh main read at approval and AGAIN before any public write.
export async function verifyEditorialNow(identity, editorialText, fetchFn = fetch, githubToken = null) {
  const path = PAGES[identity.project], decisionPath = DECISIONS[identity.project];
  if (!path || !decisionPath || !githubToken || typeof githubToken !== 'string') {
    throw new EditorialUnavailable();
  }
  const [body, decisions] = await Promise.all([
    freshMain(path, fetchFn, githubToken),
    freshMain(decisionPath, fetchFn, githubToken),
  ]);
  if (isClosed(decisions, identity, body)) return 'stale';
  return readyTextFromMain(body, identity) === editorialText ? 'current' : 'stale';
}
