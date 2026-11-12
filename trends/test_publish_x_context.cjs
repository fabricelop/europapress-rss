'use strict';
const { test } = require('node:test'), assert = require('node:assert/strict');
const { mergeForPublish } = require('./publish_x_context.js');
const at = Date.parse('2026-11-12T17:00:00Z');
const queue = {items:[{id:'f4fde19c25ea',revision:2,name:'Aurá',status:'preparing'},
  {id:'c6d918c2f68a',revision:1,name:'Finalizada',status:'published'}]};
function item(extra={}) {
  return {id:'f4fde19c25ea',revision:2,name:'Aurá',
    searched_at:'2026-11-12T16:45:00Z',source:'x_recent_posts_windows',
    status:'ok',posts:[{id:'123',author:'@user',text:'Una conversación sobre aura',
      datetime:'2026-11-12T16:43:00Z',url:'https://x.com/user/status/123'}],...extra};
}
test('only exact active ID/revision/name from a local Windows session',()=>{
  const x=mergeForPublish({items:[]},{items:[item()]},queue,at);
  assert.equal(x.updates.length,1);
  assert.equal(x.merged.items[0].source,'x_recent_posts_windows');
  assert.equal(x.merged.items[0].posts[0].url,'https://x.com/user/status/123');
  assert.equal(mergeForPublish({items:[]},{items:[item({revision:3})]},queue,at).updates.length,0);
  assert.equal(mergeForPublish({items:[]},{items:[item({name:'Otro'})]},queue,at).updates.length,0);
  assert.equal(mergeForPublish({items:[]},{items:[item({source:'x_recent_posts'})]},queue,at).updates.length,0);
});
test('do not publish published, terminal, stale or malicious fake URLs',()=>{
  assert.equal(mergeForPublish({items:[]},{items:[item({id:'c6d918c2f68a',revision:1,name:'Finalizada'})]},queue,at).updates.length,0);
  assert.equal(mergeForPublish({items:[]},{items:[item({searched_at:'2026-11-10T00:00:00Z'})]},queue,at).updates.length,0);
  const x=mergeForPublish({items:[]},{items:[item({posts:[{...item().posts[0],url:'https://fake.example/status/123'}]})]},queue,at);
  assert.equal(x.updates[0].status,'empty');
  assert.equal(x.updates[0].posts.length,0);
});
test('preserve newer remote evidence and unrelated revisions',()=>{
  const existing={items:[item({searched_at:'2026-11-12T16:50:00Z'}),
    item({id:'f4fde19c25ea',revision:1,searched_at:'2026-11-12T16:00:00Z',status:'error',posts:[]})]};
  const stale=mergeForPublish(existing,{items:[item()]},queue,at);
  assert.equal(stale.updates.length,0);
  const fresh=mergeForPublish(existing,{items:[item({searched_at:'2026-11-12T16:55:00Z'})]},queue,at);
  assert.equal(fresh.updates.length,1);
  assert.equal(fresh.merged.items.length,2);
  assert.equal(fresh.merged.items.find(x=>x.revision===2).searched_at,'2026-11-12T16:55:00Z');
});

test('publishes Windows X evidence for current unverified Top 30 card only',()=>{
 const card={id:'e160381847c4',revision:0,name:'Preparando',searched_at:'2026-11-12T16:45:00Z',
   source:'x_recent_posts_windows',search_url:'https://x.com/search?q=Preparando',
   status:'empty',posts:[]};
 const top30={items:[{editorial_id:card.id,revision:0,name:card.name,
   category:'Sin verificar',status:'EXPLICADA'}]};
 assert.equal(mergeForPublish({items:[]},{items:[card]},{items:[]},at,top30).updates.length,1);
 assert.equal(mergeForPublish({items:[]},{items:[card]},{items:[]},at,
   {items:[{...top30.items[0],category:'Actualidad'}]}).updates.length,0);
});
