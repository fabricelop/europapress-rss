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

// Historical editorial truth, not just current Listas. An original selected
// by the editor can be attached AFTER a card is published/removed; this never
// requeues the card or changes its publication status.
export function readyTextFromMain(data, identity) {
  if (!data || !Array.isArray(data.items)) throw new EditorialUnavailable();
  const key = identity.project === 'ttittulares' ? 'event_id' : 'id';
  // The exact older revision is still valid after a newer rewrite exists.
  const sameRevision = data.items.filter(row =>
    row[key] === identity.editorialId &&
    Number(row.revision ?? 0) === identity.revision);
  if (!sameRevision.length) return null;
  const latest = sameRevision.sort((a, b) =>
    String(b.explained_at || b.prepared_at || b.updated_at || '').localeCompare(
      String(a.explained_at || a.prepared_at || a.updated_at || '')))[0];
  // An actual dated editorial entry is required. Rank/title similarity or
  // another name is never sufficient to attach a manual original.
  const issuedAt = identity.project === 'ttendencias'
    ? latest.explained_at : latest.prepared_at;
  if (typeof issuedAt !== 'string' || !issuedAt.trim()) return null;
  const text = identity.project === 'ttittulares'
    ? (latest.tweet?.text || latest.explanation || latest.factual_summary)
    : latest.explanation;
  return typeof text === 'string' && text.trim() ? text : null;
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

// Both upload and approval compare the original ID/revision/text against
// current GitHub history. A removal from Listas is not an image prohibition.
export async function verifyEditorialNow(identity, editorialText, fetchFn = fetch, githubToken = null) {
  const path = PAGES[identity.project];
  if (!path || !githubToken || typeof githubToken !== 'string') {
    throw new EditorialUnavailable();
  }
  const historical = await freshMain(path, fetchFn, githubToken);
  return readyTextFromMain(historical, identity) === editorialText
    ? 'current' : 'stale';
}
