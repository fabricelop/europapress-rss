import test from 'node:test';
import assert from 'node:assert/strict';
import {loadCurrentEditorialTop30,feedToCompactCards,FEED_URL} from './site-feed-client.mjs';

const instant=Date.parse('2026-10-31T23:50:00Z');
const feed = {
  schema_version:1,generated_at:'2026-10-31T23:50:00Z',
  count:2,items:[
    {card_id:'rank-1',rank:1,name:'Halloween',editorial_id:'ab65bc5a5cf7',
     explanation:'Actual de 19:29',explained_at:'2026-10-31T19:29:00+01:00',
     image:{url:'https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttendencias/x.png',status:'catalog_recorded'}},
    {card_id:'rank-2',rank:2,name:'Grimaldo',editorial_id:'0e9ddd785dc2',
     explanation:'Actual de 23:10',explained_at:'2026-10-31T23:10:00+01:00'},
  ]
};
test('reads only the small public Top30 feed, never original large manual ledger', async()=>{
 let seen;
 const result=await loadCurrentEditorialTop30({now:instant,fetchImpl:async(url,options)=>{
   seen={url,options};return {ok:true,json:async()=>feed};
 }});
 assert(seen.url.startsWith(FEED_URL+'?v='));
 assert.equal(result.stale,false);
 assert.equal(result.items[1].explanation,'Actual de 23:10');
});
test('stale state prevents silent legacy fallback and old response',async()=>{
 const result=await loadCurrentEditorialTop30({now:instant+16*60_000,fetchImpl:async()=>({ok:true,json:async()=>feed})});
 assert.equal(result.stale,true);
 await assert.rejects(()=>loadCurrentEditorialTop30({now:instant,fetchImpl:async()=>({ok:false,status:503})}),/503/);
});
test('card adapter preserves original exact editorial ID and explanation',()=>{
 const cards=feedToCompactCards(feed,row=>row.rank===1);
 assert.equal(cards[0].source.explanation,'Actual de 19:29');
 assert.equal(cards[0].source.id,'ab65bc5a5cf7');
 assert.equal(cards[1].source.id,'0e9ddd785dc2');
 assert.equal(cards[0].imageVerified,true);
 assert.equal(cards[1].imageVerified,false);
});
test('reject invalid feed schema and mismatched row count',async()=>{
 await assert.rejects(()=>loadCurrentEditorialTop30({now:instant,fetchImpl:async()=>({ok:true,json:async()=>({...feed,count:1})})}),/invalid schema/);
});
