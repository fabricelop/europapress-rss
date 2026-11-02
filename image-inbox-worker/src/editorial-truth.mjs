// The approval gate only trusts the exact current READY text, ID and revision
// returned from GitHub main. Rank/title similarity and cached preview URLs are
// NEVER identity. The publisher must perform the same check once more.
const encoder = new TextEncoder();
const PAGES = Object.freeze({
  ttittulares: 'ttittulares/prepared.json',
  ttendencias: 'trends/prepared.json',
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

export function readyTextFromMain(data, identity) {
  if (!data || !Array.isArray(data.items)) throw new EditorialUnavailable();
  const matches = data.items.filter(row => (
    (identity.project === 'ttittulares' ? row.event_id : row.id) === identity.editorialId &&
    row.revision === identity.revision
  ));
  if (matches.length !== 1) return null; // not READY or ambiguous = stale
  const row = matches[0];
  const text = identity.project === 'ttittulares' ? row.tweet?.text : row.explanation;
  return typeof text === 'string' && text.trim() ? text : null;
}

// Three-valued verdict: 'current' / 'stale' / exception (network unavailable).
// Use a fresh main read at approval and AGAIN before any public write.
export async function verifyEditorialNow(identity, editorialText, fetchFn = fetch, githubToken = null) {
  const path = PAGES[identity.project];
  if (!path || !githubToken || typeof githubToken !== 'string') throw new EditorialUnavailable();
  let response;
  try {
    response = await fetchFn(`https://api.github.com/repos/fabricelop/europapress-rss/contents/${path}?ref=main`, {
      headers: { 'Authorization': 'Bearer ' + githubToken,
        'Accept': 'application/vnd.github.raw+json', 'Cache-Control': 'no-cache',
        'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'TTActualidad-Approval-Gate' },
      cache: 'no-store', redirect: 'error',
    });
  } catch { throw new EditorialUnavailable(); }
  if (!response || !response.ok) throw new EditorialUnavailable();
  let body;
  try {
    const text = await response.text();
    if (text.length > 3_000_000) throw new Error('too large');
    body = JSON.parse(text);
  } catch { throw new EditorialUnavailable(); }
  return readyTextFromMain(body, identity) === editorialText ? 'current' : 'stale';
}