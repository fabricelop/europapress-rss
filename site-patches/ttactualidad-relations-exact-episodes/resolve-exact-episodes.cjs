"use strict";

/**
 * Exact editorial-episode resolution for the existing ChatGPT Site
 * /api/editorial-relations/v1/decisions handler.
 *
 * This is an integration helper, NOT a deployed API, relation database, or
 * alternate publication flow. The existing authenticated Site service must
 * call this with trusted server-side catalog data, then persist decisions in
 * its current relation store with its existing commandId idempotency.
 */

class EpisodeResolutionError extends Error {
  constructor(status, code) {
    super(code);
    this.name = "EpisodeResolutionError";
    this.status = status;
    this.code = code;
  }
}

function key(id, revision) {
  return String(id) + ":r" + String(revision);
}

function identity(value) {
  if (!value || typeof value !== "object" ||
      typeof value.id !== "string" ||
      !/^[a-zA-Z0-9_-]{6,128}$/.test(value.id) ||
      !Number.isSafeInteger(value.revision) || value.revision < 0) {
    throw new EpisodeResolutionError(400, "invalid_episode_identity");
  }
  const fp = value.episodeFingerprint;
  if (fp != null && (typeof fp !== "string" || fp.length > 256)) {
    throw new EpisodeResolutionError(400, "invalid_fingerprint");
  }
  return {id: value.id, revision: value.revision,
          episodeFingerprint: fp || null};
}

function makeTrustedNewsIndex({
  processing, prepared, status, treated, publicationEvents, existing
} = {}) {
  // The caller must fetch these from authoritative GitHub main or its own
  // authenticated editorial store. NEVER accept documents from the iPhone.
  const result = new Map();
  const ingest = (id, revision, title, fingerprint = null) => {
    if (typeof id !== "string" || !id || !Number.isSafeInteger(revision) ||
        revision < 0 || typeof title !== "string" || !title.trim()) return;
    const k = key(id, revision);
    const old = result.get(k);
    // Retain a server-issued fingerprint if one already exists. Do not
    // derive a new one from a display title, rank or changing editorial text.
    const episodeFingerprint =
      (old && old.episodeFingerprint) || fingerprint || null;
    result.set(k, {id, revision, episodeFingerprint,
                   title: title.length > (old?.title?.length || 0) ? title : old.title});
  };
  for (const row of (processing?.items || [])) {
    ingest(row.event_id || row.id, row.revision, row.title || row.canonical_title);
  }
  for (const row of (prepared?.items || [])) {
    ingest(row.event_id || row.id, row.revision, row.title);
  }
  for (const [id, row] of Object.entries(status?.events || {})) {
    ingest(id, row?.revision, row?.title);
  }
  for (const row of (treated?.items || [])) {
    if (Number.isSafeInteger(row.revision)) {
      ingest(row.event_id, row.revision, row.title);
    }
  }
  // A published article does not stop being linkable when it leaves Listas
  // or a rolling editorial queue. Only accept trusted server-side records
  // that actually contain the article identity and title.
  for (const row of (publicationEvents?.items || [])) {
    if (row.project === "ttittulares") {
      ingest(row.event_id, row.revision, row.title || row.canonical_title);
    }
  }
  // The current Site snapshots and persisted links are authoritative for
  // opaque fingerprints already issued. Process these LAST.
  for (const row of (existing || [])) {
    // Site snapshots may contain endpoints or persisted relation wrappers.
    // Preserve the server-issued exact identity, never link by title alone.
    const episode = row?.news || row;
    ingest(episode?.id, episode?.revision, episode?.title,
           typeof episode?.episodeFingerprint === "string" ?
           episode.episodeFingerprint : null);
  }
  return result;
}

function makeTrustedTrendIndex({siteTop30, existing, explained} = {}) {
  const result = new Map();
  const ingest = (id, revision, title, fingerprint) => {
    if (typeof id !== "string" || !id || !Number.isSafeInteger(revision) ||
        revision < 0 || typeof title !== "string" || !title.trim()) return;
    const k = key(id, revision);
    const previous = result.get(k);
    result.set(k, {id, revision, title,
      episodeFingerprint: fingerprint || previous?.episodeFingerprint || null});
  };
  // Historical episodes must remain addressable after leaving the Top 30.
  for (const row of (explained || [])) {
    ingest(row.id || row.editorial_id, row.revision, row.title || row.name,
           row.episodeFingerprint);
  }
  for (const row of (siteTop30?.items || [])) {
    ingest(row.editorial_id, row.revision, row.name, null);
  }
  // Never discard persisted historical identities.
  for (const row of (existing || [])) {
    const episode = row?.trend || row;
    ingest(episode?.id, episode?.revision, episode?.title,
           episode?.episodeFingerprint);
  }
  return result;
}

// The real authenticated Site handler supplies trusted server-side JSON
// sources and its persisted snapshot. No writes, auth bypass, or second
// relation database are performed here.
function buildTrustedRelationIndexes({
  processing, prepared, status, treated, publicationEvents,
  siteTop30, explained, snapshot
} = {}) {
  const oldLinks = snapshot?.items || [];
  return {
    news: makeTrustedNewsIndex({
      processing, prepared, status, treated, publicationEvents,
      existing: [...(snapshot?.news || []), ...oldLinks]
    }),
    trends: makeTrustedTrendIndex({
      siteTop30, explained,
      existing: [...(snapshot?.trends || []), ...oldLinks]
    })
  };
}

function resolve(index, request) {
  const expected = identity(request);
  const episode = index.get(key(expected.id, expected.revision));
  if (!episode) {
    // 409 means a missing, stale or unrecognized episode identity;
    // the editor keeps the checked choice until the backend is updated.
    throw new EpisodeResolutionError(409, "episode_not_in_authoritative_catalog");
  }
  if (expected.episodeFingerprint &&
      (!episode.episodeFingerprint ||
       expected.episodeFingerprint !== episode.episodeFingerprint)) {
    throw new EpisodeResolutionError(409, "episode_fingerprint_conflict");
  }
  return episode;
}

function resolveValidatedPair(decision, indexes) {
  if (!decision || !["link", "unlink", "dismiss"].includes(decision.action) ||
      typeof decision.commandId !== "string" ||
      !/^[a-zA-Z0-9_-]{8,128}$/.test(decision.commandId)) {
    throw new EpisodeResolutionError(400, "invalid_relation_decision");
  }
  if (!(indexes?.news instanceof Map) || !(indexes?.trends instanceof Map)) {
    throw new Error("Trusted catalogs missing: fail closed.");
  }
  return {
    action: decision.action, commandId: decision.commandId,
    news: resolve(indexes.news, decision.expectedNews),
    trend: resolve(indexes.trends, decision.expectedTrend)
  };
}


/**
 * Optional GET /v1/snapshot integration for the existing private Site service.
 * It exposes the same authoritative news/trend episodes accepted by POST,
 * including WAITING, READY, archived and published articles. It NEVER creates
 * relation items: only the existing relation store supplies snapshot.items.
 * On wire use an empty string for an as-yet-unissued fingerprint so existing
 * iOS Codable endpoints can decode it; POST still resolves by ID/revision.
 */
function exposeLinkableEpisodes(snapshot, indexes) {
  if (!(indexes?.news instanceof Map) || !(indexes?.trends instanceof Map)) {
    throw new Error("Trusted catalogs missing: fail closed.");
  }
  const original = snapshot || {items: [], news: [], trends: []};
  const canonical = (rows, index) => {
    const result = new Map();
    for (const row of index.values()) {
      result.set(key(row.id, row.revision), {
        id: row.id, revision: row.revision,
        episodeFingerprint: row.episodeFingerprint || "",
        title: row.title || "", text: row.text || "",
        path: row.path || null, listedAt: row.listedAt || null
      });
    }
    // The existing Site snapshot is authoritative for full endpoint payload,
    // including genuine stored fingerprints, text, paths and timestamps.
    for (const row of rows || []) {
      if (!row || !index.has(key(row.id, row.revision))) continue;
      const k = key(row.id, row.revision);
      const candidate = result.get(k);
      result.set(k, {
        ...candidate, ...row,
        episodeFingerprint: row.episodeFingerprint || candidate.episodeFingerprint
      });
    }
    return [...result.values()];
  };
  return {
    ...original,
    items: [...(original.items || [])],
    news: canonical(original.news, indexes.news),
    trends: canonical(original.trends, indexes.trends)
  };
}

/**
 * Drop-in validation entrypoint for Site's EXISTING authenticated decision
 * handler, before invoking its normal idempotent relation-store writes.
 * Authorization, persistence, and receipt production stay in the Site.
 */
function resolveManualDecision(decision, trustedCatalogs) {
  return resolveValidatedPair(
    decision, buildTrustedRelationIndexes(trustedCatalogs));
}

module.exports = {
  EpisodeResolutionError, makeTrustedNewsIndex, makeTrustedTrendIndex,
  buildTrustedRelationIndexes, exposeLinkableEpisodes,
  resolveManualDecision, resolveValidatedPair
};
