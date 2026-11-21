'use strict';

// Pure, side-effect-free contract for the future TTActualidad private image inbox.
// Do not import this module as an ingestion or publishing service: it intentionally
// does not write files, catalogs, Sites records, or public URLs.
const { createHash } = require('node:crypto');
const SHA256 = /^[0-9a-f]{64}$/;
const PROJECTS = new Set(['ttendencias', 'ttittulares']);

class ImageApprovalError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ImageApprovalError';
    this.code = code;
  }
}

function requiredString(value, field) {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new ImageApprovalError('INVALID_CANDIDATE', `${field} is required`);
  }
  return value;
}

function canonicalIdentity(candidate) {
  if (!candidate || typeof candidate !== 'object') {
    throw new ImageApprovalError('INVALID_CANDIDATE', 'Missing candidate');
  }
  const project = requiredString(candidate.project, 'project');
  if (!PROJECTS.has(project)) {
    throw new ImageApprovalError('INVALID_CANDIDATE', 'Unsupported project');
  }
  const editorialId = requiredString(candidate.editorialId, 'editorialId');
  const revision = candidate.revision;
  if (!Number.isSafeInteger(revision) || revision < 0) {
    throw new ImageApprovalError('INVALID_CANDIDATE', 'Invalid revision');
  }
  const episodeFingerprint = requiredString(candidate.episodeFingerprint, 'episodeFingerprint').toLowerCase();
  const commandId = requiredString(candidate.commandId, 'commandId');
  const rasterSHA256 = requiredString(candidate.rasterSHA256, 'rasterSHA256').toLowerCase();
  if (!SHA256.test(episodeFingerprint) || !SHA256.test(rasterSHA256)) {
    throw new ImageApprovalError('INVALID_CANDIDATE', 'Invalid fingerprint');
  }
  return { project, editorialId, revision, episodeFingerprint, commandId, rasterSHA256 };
}

function imageApprovalKey(candidate) {
  const identity = canonicalIdentity(candidate);
  return createHash('sha256').update(JSON.stringify(identity), 'utf8').digest('hex');
}

function authoritativeMatch(candidate, current) {
  if (!current) return false;
  // Compare the complete identity; reusing r0 for a different episode is stale.
  try {
    return imageApprovalKey(candidate) === imageApprovalKey(current);
  } catch { return false; }
}

function decideImage({ candidate, current, action, actor, decidedAt }) {
  const key = imageApprovalKey(candidate);
  if (action !== 'approve' && action !== 'reject') {
    throw new ImageApprovalError('INVALID_ACTION', 'Only approve/reject are allowed');
  }
  requiredString(actor, 'actor');
  requiredString(decidedAt, 'decidedAt');
  const status = candidate.status || 'pending';
  if (status === 'rejected' && action === 'reject') {
    return { kind: 'no-op', key, next: candidate, catalogWrites: [] };
  }
  if (status === 'approved_awaiting_publication' && action === 'approve') {
    if (!authoritativeMatch(candidate, current)) {
      throw new ImageApprovalError('STALE_IMAGE', 'The approved identity is no longer authoritative');
    }
    return { kind: 'no-op', key, next: candidate, catalogWrites: [] };
  }
  if (status !== 'pending') {
    throw new ImageApprovalError('ALREADY_DECIDED', 'A different decision is already recorded');
  }
  if (action === 'reject') {
    // Only remove this candidate from the private inbox. Keep the original raster,
    // any existing published image, historical decisions and all catalogs unchanged.
    return {
      kind: 'rejected', key,
      next: { ...candidate, status: 'rejected', inboxVisible: false,
              rejection: { actor, decidedAt, approvalKey: key } },
      catalogWrites: [],
    };
  }
  if (!authoritativeMatch(candidate, current)) {
    throw new ImageApprovalError('STALE_IMAGE', 'Editorial identity, revision, command or raster changed');
  }
  // Approval is NOT publication: the publisher must independently revalidate the
  // current identity and SHA-256 against the retained original bytes before any
  // catalog or public media write. This transition only issues an intent.
  return {
    kind: 'approved_awaiting_publication', key,
    next: { ...candidate, status: 'approved_awaiting_publication', inboxVisible: false,
            approval: { actor, decidedAt, approvalKey: key } },
    catalogWrites: [],
    publishIntent: { approvalKey: key, identity: canonicalIdentity(candidate) },
  };
}

function mayPublish({ candidate, current, actualRasterSHA256, approvalKey }) {
  if (!candidate || candidate.status !== 'approved_awaiting_publication') return false;
  if (!candidate.approval || candidate.approval.approvalKey !== imageApprovalKey(candidate)) return false;
  if (approvalKey !== candidate.approval.approvalKey) return false;
  if (!authoritativeMatch(candidate, current)) return false;
  return typeof actualRasterSHA256 === 'string' &&
    actualRasterSHA256.toLowerCase() === canonicalIdentity(candidate).rasterSHA256;
}

function pendingInboxItems(candidates) {
  if (!Array.isArray(candidates)) return [];
  // Inbox clients should receive this result only from an authenticated PRIVATE API.
  return candidates.filter(c => c && (c.status || 'pending') === 'pending' && c.inboxVisible !== false);
}

module.exports = {
  ImageApprovalError,
  canonicalIdentity,
  imageApprovalKey,
  authoritativeMatch,
  decideImage,
  mayPublish,
  pendingInboxItems,
};