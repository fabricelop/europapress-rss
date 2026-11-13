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

function makeTrustedNewsIndex({processing, prepared, status, treated, existing} = {}) {
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
  // The current Site snapshots and persisted links are authoritative for
  // opaque fingerprints already issued. Process these LAST.
  for (const row of (existing || [])) {
    ingest(row.id, row.revision, row.title,
           typeof row.episodeFingerprint === "string" ? row.episodeFingerprint : null);
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
    ingest(row.id, row.revision, row.title, row.episodeFingerprint);
  }
  return result;
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

module.exports = {
  EpisodeResolutionError, makeTrustedNewsIndex, makeTrustedTrendIndex,
  resolveValidatedPair
};
