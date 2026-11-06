'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { canonicalIdentity, imageApprovalKey, authoritativeMatch,
        decideImage, mayPublish, pendingInboxItems } = require('../shared/image-approval-policy.cjs');
const candidate = Object.freeze({
  project: 'ttendencias', editorialId: 'b88d2954e28e', revision: 0,
  episodeFingerprint: 'a'.repeat(64), commandId: 'tr-img-auto-b88d2954e28e-r0-a1',
  rasterSHA256: 'b'.repeat(64), status: 'pending', inboxVisible: true,
});
const ctx = (extra = {}) => ({ candidate, current: candidate, action: 'approve', actor: 'editor', decidedAt: '2026-11-02T21:00:00+01:00', ...extra });
const changes = [
  ['revision', {revision: 1}], ['episode (r0 reuse)', {episodeFingerprint:'c'.repeat(64)}],
  ['raster', {rasterSHA256:'d'.repeat(64)}], ['command', {commandId:'different'}],
  ['project', {project:'ttittulares'}], ['editorial id', {editorialId:'other'}],
];
test('full exact identity and deterministic key', () => {
  assert.deepEqual(canonicalIdentity(candidate), canonicalIdentity({...candidate}));
  assert.equal(imageApprovalKey(candidate), imageApprovalKey({...candidate}));
  for (const [, v] of changes) assert.notEqual(imageApprovalKey(candidate), imageApprovalKey({...candidate,...v}));
});
test('approval creates private intent only (zero catalog writes)', () => {
  const result = decideImage(ctx());
  assert.equal(result.kind, 'approved_awaiting_publication');
  assert.equal(result.next.inboxVisible, false);
  assert.deepEqual(result.catalogWrites, []);
  assert.equal(result.publishIntent.approvalKey, imageApprovalKey(candidate));
});
test('reject merely empties inbox; never deletes raster or alters catalogs', () => {
  const result = decideImage(ctx({action:'reject',current:null}));
  assert.equal(result.kind, 'rejected');
  assert.deepEqual(result.catalogWrites, []);
  assert.equal(result.next.rasterSHA256, candidate.rasterSHA256);
  assert.deepEqual(pendingInboxItems([candidate,result.next]),[candidate]);
  assert.equal(decideImage(ctx({action:'reject',candidate:result.next})).kind,'no-op');
});
test('cannot approve a stale identity; each key dimension fails closed', () => {
  assert.equal(authoritativeMatch(candidate,candidate),true);
  for (const [name, delta] of changes) {
    const changed = {...candidate,...delta};
    assert.equal(authoritativeMatch(candidate,changed),false,name);
    assert.throws(()=>decideImage(ctx({current:changed})), {code:'STALE_IMAGE'}, name);
  }
});
test('publication requires approval + revalidation + original bytes SHA', () => {
  const approved=decideImage(ctx()).next;
  const intent=approved.approval.approvalKey;
  assert.equal(mayPublish({candidate,current:candidate,actualRasterSHA256:candidate.rasterSHA256,approvalKey:intent}),false);
  const valid={candidate:approved,current:candidate,actualRasterSHA256:candidate.rasterSHA256,approvalKey:intent};
  assert.equal(mayPublish(valid),true);
  assert.equal(mayPublish({...valid,actualRasterSHA256:'f'.repeat(64)}),false);
  assert.equal(mayPublish({...valid,approvalKey:'wrong'}),false);
  assert.equal(mayPublish({...valid,current:{...candidate,revision:2}}),false);
});
test('approval is idempotent, but opposite decision is conflict',()=>{
  const approved=decideImage(ctx()).next;
  assert.equal(decideImage(ctx({candidate:approved})).kind,'no-op');
  assert.throws(()=>decideImage(ctx({candidate:approved,action:'reject'})), {code:'ALREADY_DECIDED'});
  const rejected=decideImage(ctx({action:'reject'})).next;
  assert.throws(()=>decideImage(ctx({candidate:rejected,action:'approve'})), {code:'ALREADY_DECIDED'});
});
test('invalid inputs fail closed',()=>{
  assert.throws(()=>imageApprovalKey({...candidate,rasterSHA256:'preview-url'}), {code:'INVALID_CANDIDATE'});
  assert.throws(()=>imageApprovalKey({...candidate,revision:-1}), {code:'INVALID_CANDIDATE'});
  assert.throws(()=>decideImage(ctx({action:'publish-web'})), {code:'INVALID_ACTION'});
});