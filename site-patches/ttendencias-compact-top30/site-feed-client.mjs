/**
 * Site-only client adapter. No writes. One small published JSON feed replaces
 * parsing the ~1.3MB manual ledger and 7MB requests ledger in every browser.
 */
export const FEED_URL =
  'https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/site-top30-current.json';

export async function loadCurrentEditorialTop30({
  fetchImpl = fetch, signal, now = Date.now(),
} = {}) {
  // GitHub raw content may be cached by intermediate CDNs; unique window URL.
  const cacheWindow = Math.floor(now / 120_000);
  const res = await fetchImpl(FEED_URL + '?v=' + cacheWindow, {
    method: 'GET', signal, cache: 'no-store',
    headers: { Accept: 'application/json' },
  });
  if (!res.ok) throw new Error('TTendencias editorial feed HTTP ' + res.status);
  const payload = await res.json();
  if (payload?.schema_version !== 1 || !Array.isArray(payload.items) ||
      !(payload.items.length >= 1 && payload.items.length <= 30) ||
      payload.count !== payload.items.length) {
    throw new Error('TTendencias editorial feed invalid schema');
  }
  if (!Number.isFinite(Date.parse(payload.generated_at))) {
    throw new Error('TTendencias editorial feed lacks generation timestamp');
  }
  // Never silently fallback to older explanation without a visible warning.
  const generatedAt = Date.parse(payload.generated_at);
  const stale = now - generatedAt > 15 * 60_000 || generatedAt - now > 5 * 60_000;
  return { ...payload, stale };
}

export function feedToCompactCards(feed, imageActuallyVerified = () => false) {
  return feed.items.map(row => ({
    cardId: row.card_id,
    rank: row.rank,
    name: row.name,
    explainedAt: row.explained_at || null,
    groupLabel: row.group_title || '',
    searchTerms: [],
    // Only the exact catalog record can be a candidate, and only site-side
    // verified storage/association should turn on the small image indicator.
    imageUrl: row.image?.url ?? null,
    imageVerified: row.image?.status === 'catalog_recorded' &&
      imageActuallyVerified(row),
    source: {
      ...row,
      id: row.editorial_id,
      explanation: row.explanation,
      explained_at: row.explained_at,
      verification_sources: row.verification_sources,
    },
  }));
}
