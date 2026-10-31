import test from 'node:test';
import assert from 'node:assert/strict';
import {filteredTop30,normalizeSearch,matchesTop30Query,validateCards,nextOpenCardId,isVerifiedSiteImage,formatMadridExplainedAt} from './model.mjs';
const image='/images/ttendencias/abc-r0-aaaaaaaaaaaa.png';
const cards=[
  {cardId:'entry-1',rank:1,name:'Óscar Puente',groupLabel:'Urda',searchTerms:['Transportes'],explainedAt:'2026-10-31T22:00:00Z',imageVerified:true,imageUrl:image},
  {cardId:'entry-2',rank:2,name:'#Lamine',groupLabel:'Barça Alavés',explainedAt:null,imageVerified:false,imageUrl:image},
  {cardId:'entry-3',rank:3,name:'Mazón',groupLabel:'Urda',explainedAt:'2026-10-31T22:00:00Z',imageVerified:true,imageUrl:'https://example.org/fake.png'},
];
test('search normalized accent, case, hashtags and group; no ranking mutation',()=>{
 assert.equal(normalizeSearch(' ÁLAVÉS '),'alaves');
 assert.deepEqual(filteredTop30(cards,'oscar transportes').map(x=>x.cardId),['entry-1']);
 assert.deepEqual(filteredTop30(cards,'barca #lamine').map(x=>x.cardId),['entry-2']);
 assert.deepEqual(filteredTop30(cards,'urda').map(x=>x.cardId),['entry-1','entry-3']);
 assert.equal(matchesTop30Query(cards[0],''),true);
});
test('one open row; close on second click; groups can share context but separate cardId',()=>{
 let state=null;state=nextOpenCardId(state,'entry-1');assert.equal(state,'entry-1');
 state=nextOpenCardId(state,'entry-2');assert.equal(state,'entry-2');
 state=nextOpenCardId(state,'entry-2');assert.equal(state,null);
});
test('reject duplicated or missing stable row identities',()=>{
 assert.throws(()=>validateCards([cards[0],{...cards[0]}]),/Duplicate/);
 assert.throws(()=>validateCards([{rank:1}]),/cardId/);
 assert.throws(()=>validateCards([{cardId:'x',rank:31}]),/rank/);
});
test('image icon requires verified image at exact Site host',()=>{
 assert.equal(isVerifiedSiteImage(cards[0]),true);
 assert.equal(isVerifiedSiteImage(cards[1]),false);
 assert.equal(isVerifiedSiteImage(cards[2]),false);
 assert.equal(isVerifiedSiteImage({...cards[0],imageUrl:'https://ttactualidad-tendencias.rainyraven22.chatgpt.site.evil.org/images/ttendencias/x.png'}),false);
 assert.equal(isVerifiedSiteImage({...cards[0],imageUrl:'/images/ttendencias/x.png?foo=1'}),false);
});
test('explanation timestamp shown in Europe/Madrid, pending safe',()=>{
 assert.match(formatMadridExplainedAt('2026-10-31T22:00:00Z'),/31\/10\s+23:00/);
 assert.equal(formatMadridExplainedAt(null),'Pendiente');
 assert.equal(formatMadridExplainedAt('invalid'),'Pendiente');
});
