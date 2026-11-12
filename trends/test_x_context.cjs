'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { makeSearchUrl, chooseTargets, validPost, usableEvidence, assembleEvidence } = require('./x_context.js');
const now = Date.parse('2026-11-12T16:00:00Z');
const one = { id: 'a1b2c3d4e5f6', revision: 2, name: 'Aurá', status: 'preparing' };
const queue = { items: [one, { id: 'b1b2c3d4e5f6', revision: 0, name: '#Tema', status: 'problematic' }, { ...one, id:'c1b2c3d4e5f6', status: 'published' }] };
const post = { id:'123', author:'@ejemplo', url:'https://x.com/ejemplo/status/123', datetime:'2026-11-12T15:00:00Z', text:'Texto real de ejemplo' };
test('consulta X exacta y codificada', () => {
  const url = new URL(makeSearchUrl('Aurá "ejemplo"'));
  assert.equal(url.hostname, 'x.com');
  assert.equal(url.searchParams.get('q'), '"Aurá ejemplo"');
  assert.equal(url.searchParams.get('f'), 'live');
});
test('trabajos vigentes; caché por ID y revisión', () => {
  assert.equal(chooseTargets(queue, {items:[]}, now).length, 2);
  const cache = {items:[{...one, status:'ok', searched_at:'2026-11-12T15:30:00Z', posts:[post]}]};
  assert.deepEqual(chooseTargets(queue, cache, now).map(x => x.id), ['b1b2c3d4e5f6']);
  assert.equal(chooseTargets({items:[{...one,revision:3}]},cache,now).length, 1);
  assert.ok(usableEvidence(cache,one,now));
  assert.equal(usableEvidence(cache,{...one,revision:3},now),null);
  assert.equal(usableEvidence(cache,one,now+2*3600000),null);
});
test('solo publicaciones reales recientes con URL X', () => {
  assert.equal(validPost(post, now),true);
  assert.equal(validPost({...post,url:'https://fake.example/status/123'},now),false);
  assert.equal(validPost({...post,datetime:'2026-01-01T00:00:00Z'},now),false);
});
test('resultados independientes y cola no mutada', () => {
  const doc = assembleEvidence({items:[]}, [{...one,searched_at:'2026-11-12T15:30:00Z',posts:[post]}],now);
  assert.equal(doc.schema_version,1); assert.equal(doc.items.length,1);
  assert.equal(queue.items[0].status,'preparing');
});
