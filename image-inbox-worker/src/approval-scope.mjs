// TTActualidad editorial decision: 2026-11-06 09:43 Europe/Paris.
// Keep old R2/D1 originals, but NEVER expose the old 500-image backlog in
// APP > Imagenes pendientes or accept additional stale news image jobs.
export const NEWS_CUTOVER_ISO = '2026-11-06T08:43:00.000Z';
export const VISIBLE_INBOX_LIMIT = 20;
const CUTOVER = Date.parse(NEWS_CUTOVER_ISO);

export function editorialTime(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(value)) return null;
  const instant = Date.parse(value);
  if (!Number.isFinite(instant) || instant > Date.now() + 5 * 60_000) return null;
  return instant;
}

export function recentNewsEpisode(value) {
  const instant = editorialTime(value);
  return instant !== null && instant >= CUTOVER;
}

export function currentTop30Episodes(snapshot) {
  if (!snapshot || !Array.isArray(snapshot.items) || snapshot.items.length > 30 ||
      snapshot.items.length < 1) {
    throw new Error('TOP30_UNAVAILABLE');
  }
  const seen = new Map();
  for (const row of snapshot.items) {
    if (!row || typeof row.editorial_id !== 'string' ||
        !/^[A-Za-z0-9_-]{3,160}$/.test(row.editorial_id) ||
        !Number.isSafeInteger(row.revision) || row.revision < 0 ||
        !(row.explanation || '').trim()) continue;
    // A rank is never an identity; only the actual editor-issued ID/revision
    // pair is authorized. Exclude elaboration cards without editorial episodes.
    seen.set(row.editorial_id + ':r' + row.revision,
      { editorialId: row.editorial_id, revision: row.revision });
  }
  return [...seen.values()];
}

export function inApprovalScope(row, episodes) {
  if (row.project === 'ttendencias') {
    return episodes.some(ep => ep.editorialId === row.editorial_id &&
      ep.revision === row.revision);
  }
  return row.project === 'ttittulares' && recentNewsEpisode(row.editorial_at);
}

// Only display one image candidate per exact editorial episode. If the most
// recently received image was rejected/approved, an older PNG cannot surface
// again and force the editor through a second decision.
export function filterVisibleCandidates(rows, episodes, limit = VISIBLE_INBOX_LIMIT,
                                        before = null) {
  const sorted = [...rows].sort((a,b) =>
    (b.created_at || '').localeCompare(a.created_at || '') || b.id.localeCompare(a.id));
  const seen = new Set(), visible = [];
  for (const row of sorted) {
    if (!inApprovalScope(row, episodes)) continue;
    const key = row.project + ':' + row.editorial_id + ':r' + row.revision;
    if (seen.has(key)) continue;
    seen.add(key);
    if (row.status !== 'pending') continue;
    if (before && !(row.created_at < before.createdAt ||
         (row.created_at === before.createdAt && row.id < before.id))) continue;
    visible.push(row);
    if (visible.length >= limit) break;
  }
  return visible;
}
