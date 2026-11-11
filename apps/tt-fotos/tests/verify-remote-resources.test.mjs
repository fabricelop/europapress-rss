import test from 'node:test';
import assert from 'node:assert/strict';
import {verifyRemoteBindings} from '../scripts/verify-remote-resources.mjs';
const id='e0d8a9fa-5335-4cda-a18c-e109dffbca92';
const goodDb=[{uuid:id,name:'tt-fotos-private'},{uuid:'11111111-2222-3333-4444-555555555555',name:'other-service'}];
const goodR2={name:'tt-fotos-originals-private',creation_date:'2026-11-11T20:20:00Z'};
test('dedicated Cloudflare D1 UUID and R2 bucket are verified without writes',()=>{
 assert.deepEqual(verifyRemoteBindings(goodDb,goodR2,id),{database:'tt-fotos-private',bucket:'tt-fotos-originals-private',validated:true});
 assert.equal(verifyRemoteBindings({databases:goodDb},{bucket:goodR2},id).validated,true);
});
test('wrong Cloudflare account, database name and ID must fail before mutation',()=>{
 for(const dbs of [[],[{uuid:id,name:'a-production-db'}],[{uuid:'99999999-2222-3333-4444-555555555555',name:'tt-fotos-private'}],null,'not json']){
  assert.throws(()=>verifyRemoteBindings(dbs,goodR2,id));
 }
 assert.throws(()=>verifyRemoteBindings(goodDb,goodR2,'not-a-uuid'));
 assert.throws(()=>verifyRemoteBindings([goodDb[0],goodDb[0]],goodR2,id));
});
test('missing or unintended R2 bucket blocks deployment',()=>{
 for(const r2 of [null,{},[],{name:'production-pictures'},{bucket:{name:'ttactualidad-images'}}]){
  assert.throws(()=>verifyRemoteBindings(goodDb,r2,id));
 }
});
