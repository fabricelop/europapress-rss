// Node orchestration contract, deliberately NOT wired to any production sink.
// The caller must inject real, authenticated APP and Sites adapters. No credentials
// or default remote-writing behavior exist in this module.
import { createHash } from 'node:crypto';

const HEX_SHA = /^[0-9a-f]{64}$/;
const idKey = ({project, editorialId, revision, episodeFingerprint, commandId, rasterSHA256}) =>
  JSON.stringify({project, editorialId, revision, episodeFingerprint, commandId, rasterSHA256});
function completeIdentity(i) {
  return i && ['ttendencias','ttittulares'].includes(i.project) &&
    typeof i.editorialId === 'string' && i.editorialId.length > 0 &&
    Number.isSafeInteger(i.revision) && i.revision >= 0 &&
    HEX_SHA.test(i.episodeFingerprint || '') && HEX_SHA.test(i.rasterSHA256 || '') &&
    typeof i.commandId === 'string' && i.commandId.length >= 3;
}
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

export class PublicationBlocked extends Error {
  constructor(reason) { super(reason); this.name = 'PublicationBlocked'; this.code = reason; }
}

function assertCurrent(candidate, current) {
  if (!current || current.id !== candidate.identity.editorialId ||
      current.project !== candidate.identity.project ||
      current.revision !== candidate.identity.revision ||
      current.editorialText !== candidate.editorialText) {
    throw new PublicationBlocked('EDITORIAL_CHANGED_OR_NOT_READY');
  }
}

function assertReadback(candidate, entry) {
  if (!entry || idKey(entry.identity) !== idKey(candidate.identity) ||
      !entry.imageBytes || sha256(entry.imageBytes) !== candidate.identity.rasterSHA256) {
    throw new PublicationBlocked('DESTINATION_READBACK_MISMATCH');
  }
}

/**
 * One approved image. Every dependency is explicit: no default writes.
 * `privateInbox.list()` returns approved candidates ONLY; `download(id)` returns
 * the original bytes; `editorial.current(identity)` returns an authoritative
 * *fresh* main snapshot; destinations each have publish + readback methods;
 * receipts.record is a durable independent audit, not a publication action.
 */
export async function publishApprovedOnce({candidateID, privateInbox, editorial, app, sites, receipts}) {
  if (!HEX_SHA.test(candidateID || '') ||
      !privateInbox || !editorial || !app || !sites || !receipts ||
      !['list','download'].every(k => typeof privateInbox[k] === 'function') ||
      typeof editorial.current !== 'function' ||
      ![app,sites].every(s => typeof s.publish === 'function' && typeof s.readback === 'function') ||
      typeof receipts.record !== 'function') {
    throw new PublicationBlocked('INCOMPLETE_PRIVATE_PUBLISHER');
  }
  const rows = await privateInbox.list();
  const candidate = rows.find(x => x.id === candidateID && x.state === 'approved_awaiting_publication');
  if (!candidate || !completeIdentity(candidate.identity) ||
      sha256(Buffer.from(idKey(candidate.identity))) !== candidate.id ||
      typeof candidate.editorialText !== 'string' || !candidate.editorialText.trim()) {
    throw new PublicationBlocked('NO_EXACT_APPROVAL');
  }
  const original = await privateInbox.download(candidateID);
  if (!original || !original.bytes || sha256(original.bytes) !== candidate.identity.rasterSHA256 ||
      original.sha256 !== candidate.identity.rasterSHA256) {
    throw new PublicationBlocked('ORIGINAL_SHA_MISMATCH');
  }
  const current = () => editorial.current(candidate.identity);
  assertCurrent(candidate, await current());

  // Each destination writer must be idempotent and bind the exact identity.
  // A partial failure remains pending; never claim both destinations succeeded.
  await app.publish(candidate, original.bytes);
  assertReadback(candidate, await app.readback(candidate.identity));
  assertCurrent(candidate, await current());
  await sites.publish(candidate, original.bytes);
  assertReadback(candidate, await sites.readback(candidate.identity));
  assertCurrent(candidate, await current());
  const proof = { id: candidate.id, identity: candidate.identity,
    sha256: candidate.identity.rasterSHA256, appVerified: true, sitesVerified: true };
  await receipts.record(proof);
  return { state: 'verified_both_destinations', proof };
}