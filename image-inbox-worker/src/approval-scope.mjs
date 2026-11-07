// Eligibility is editorial membership only; never a date or visible count.
export function currentTop30Episodes(snapshot, aiCatalog) {
  if (!snapshot || !Array.isArray(snapshot.items) || snapshot.items.length < 1 ||
      snapshot.items.length > 30 || !aiCatalog || !Array.isArray(aiCatalog.images)) {
    throw new Error('TOP30_OR_AI_CATALOG_UNAVAILABLE');
  }
  const result = new Map();
  for (const row of snapshot.items) {
    if (!row || typeof row.editorial_id !== 'string' ||
        !/^[A-Za-z0-9_-]{3,160}$/.test(row.editorial_id) ||
        !Number.isSafeInteger(row.revision) || row.revision < 0) continue;
    const hasAssignedAI = aiCatalog.images.some(image =>
      image.target_id === row.editorial_id &&
      image.revision === row.revision &&
      image.explanation === (row.explanation || '') &&
      typeof image.image_url === 'string' && image.image_url.length > 0);
    if (hasAssignedAI) continue;
    // The current ranking is not the episode identity.
    result.set(row.editorial_id + ':r' + row.revision,
      {editorialId:row.editorial_id,revision:row.revision});
  }
  return [...result.values()];
}

export function currentListasNewsEpisodes(prepared, decisions) {
  if (!prepared || !Array.isArray(prepared.items) ||
      !decisions || !Array.isArray(decisions.items)) {
    throw new Error('NEWS_LISTAS_UNAVAILABLE');
  }
  const closed = new Set();
  for (const row of decisions.items) {
    const state = String(row.status || '').toLowerCase();
    if (['deleted','dismissed','published','removed','delete_pending'].includes(state)) {
      closed.add(row.event_id + ':r' + row.revision);
    }
  }
  const episodes = new Map();
  for (const row of prepared.items) {
    if (typeof row.event_id !== 'string' || !/^[A-Za-z0-9_-]{3,160}$/.test(row.event_id) ||
        !Number.isSafeInteger(row.revision) || row.revision < 0 ||
        row.rewrite_pending === true) continue;
    const key = row.event_id + ':r' + row.revision;
    if (!closed.has(key)) episodes.set(key,
      {editorialId:row.event_id,revision:row.revision});
  }
  return [...episodes.values()];
}

export function inApprovalScope(row, trends, news) {
  const target = row.project === 'ttendencias' ? trends :
                 row.project === 'ttittulares' ? news : null;
  return Array.isArray(target) && target.some(ep =>
    ep.editorialId === row.editorial_id && ep.revision === row.revision);
}

// No cutover, no 20-image cap, no hidden per-episode deduplication.
// Only pending images still belonging to an eligible editorial episode.
export function filterVisibleCandidates(rows, trends, news, before = null) {
  return [...rows].filter(row => row.status === 'pending' &&
      inApprovalScope(row, trends, news) &&
      (!before || row.created_at < before.createdAt ||
       (row.created_at === before.createdAt && row.id < before.id)))
    .sort((a,b) => (b.created_at || '').localeCompare(a.created_at || '') ||
                   b.id.localeCompare(a.id));
}
