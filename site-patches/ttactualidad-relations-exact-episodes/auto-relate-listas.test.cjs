'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {planIncomingReady,onReadyInListas,recentFiveForTrend,stateFor}=require('./auto-relate-listas.cjs');
const trend={id:'tr1',revision:2,episodeFingerprint:'t1'};
const news={id:'n1',revision:1,episodeFingerprint:'n1',ready:true,
  text:'Texto validado',listedAt:'2026-11-12T16:00:00Z'};
const evidence={eventDescription:'Mismo acontecimiento contrastado con fuentes',
  distinctiveFacts:['actor específico','hecho verificado'],
  independentSources:['fuente independiente A','fuente independiente B']};
const match={news,trend,confidence:0.96,sameEvent:true,evidence};
const row=(n,t,state,origin='automatic_verified')=>({news:n,trend:t,state,origin});
const plan=(opts={})=>planIncomingReady({readyNews:news,trends:[trend],
  matches:[match],snapshot:{items:[]},...opts});
test('READY verificado: asociación exacta',()=>{
  assert.deepEqual(plan().links.map(z=>z.key),['n1:r1<->tr1:r2']);
});
test('nombre o rumor sin acontecimiento y pruebas NO se autovincula',()=>{
  for(const candidate of [{...match,sameEvent:false},{...match,confidence:0.69},
    {...match,evidence:{...evidence,distinctiveFacts:['un dato']}}]){
    assert.equal(plan({matches:[candidate]}).links.length,0);
  }
});
test('IDs, revisión y fingerprint distintos NO se vinculan',()=>{
  for(const candidate of [{...match,news:{...news,revision:2}},
    {...match,trend:{...trend,revision:3}},
    {...match,trend:{...trend,episodeFingerprint:'falsificado'}}])
    assert.equal(plan({matches:[candidate]}).links.length,0);
});
test('bloqueo manual gana a relación automática anterior',()=>{
  const items=[row(news,trend,'linked'),row(news,trend,'blocked','manual')];
  assert.equal(stateFor(items,news,trend),'blocked');
  assert.equal(plan({snapshot:{items}}).links.length,0);
  assert.equal(plan({snapshot:{items}}).skipped[0].reason,'blocked');
});
test('no duplica vínculos ya guardados ni candidatos repetidos',()=>{
  assert.equal(plan({matches:[match,match],snapshot:{
    items:[row(news,trend,'linked','manual')]}}).skipped.length,1);
  assert.equal(plan({snapshot:{items:[row(news,trend,'linked')]}}).links.length,0);
});
test('máximo 5 visibles ordenados por fecha, sin borrar histórico',()=>{
  const old=[0,1,2,3,4].map(i=>row({id:'old'+i,revision:0,
    listedAt:'2026-11-12T'+String(15-i).padStart(2,'0')+':00:00Z'},trend,'linked'));
  const visible=recentFiveForTrend(old,trend,[news]);
  assert.equal(visible.length,5);
  assert.equal(visible[0].id,'n1');
  assert.ok(!visible.some(n=>n.id==='old4'));
  assert.equal(old.length,5); // No silent auto unlink or manual block.
  const ancient={...news,id:'ancient',listedAt:'2026-11-01T00:00:00Z'};
  assert.equal(plan({readyNews:ancient,matches:[{...match,news:ancient}],
    snapshot:{items:old}}).skipped[0].reason,'not_among_five_newest');
});
test('Site: escritura con mismo ledger, recibo y relectura; idempotencia',async()=>{
  const items=[];let writes=0;
  const callbacks={news,trends:[trend],findTrustedMatches:async()=>[match],
    readReadyEpisode:async()=>news,readSnapshot:async()=>({items:[...items]}),
    commandIdFor:async()=> 'uuid-estable-del-servidor',
    writeDecision:async d=>{
      writes++;assert.equal(d.onlyIfUnblocked,true);
      items.push(row(news,trend,'linked'));return {state:'linked',relationId:'site-1'};
    }};
  const first=await onReadyInListas(callbacks);
  assert.equal(first.state,'verified');assert.equal(first.linked.length,1);
  const second=await onReadyInListas(callbacks);
  assert.equal(second.linked.length,0);assert.equal(writes,1);
});
test('bloqueo manual posterior a descubrir evita POST',async()=>{
  let reads=0,writes=0;
  const result=await onReadyInListas({news,trends:[trend],
    findTrustedMatches:async()=>[match],readReadyEpisode:async()=>news,
    readSnapshot:async()=>({items:++reads>1?[row(news,trend,'blocked','manual')]:[]}),
    commandIdFor:async()=> 'uuid',
    writeDecision:async()=>{writes++;return {state:'linked',relationId:'x'};}});
  assert.equal(writes,0);assert.equal(result.skipped[0].reason,'blocked');
});
test('sin GET confirmado no afirma que se haya guardado',async()=>{
  const result=await onReadyInListas({news,trends:[trend],
    findTrustedMatches:async()=>[match],readReadyEpisode:async()=>news,
    readSnapshot:async()=>({items:[]}),commandIdFor:async()=> 'uuid',
    writeDecision:async()=>({state:'linked',relationId:'site-1'})});
  assert.equal(result.state,'partial');
  assert.equal(result.linked.length,0);
  assert.equal(result.errors[0].reason,'missing_site_readback');
});
test('cambio de revisión o salida de READY impide escribir',async()=>{
  let writes=0;
  const result=await onReadyInListas({news,trends:[trend],
    findTrustedMatches:async()=>[match],
    readReadyEpisode:async()=>({...news,ready:false}),
    readSnapshot:async()=>({items:[]}),commandIdFor:async()=> 'uuid',
    writeDecision:async()=>{writes++;}});
  assert.equal(result.state,'stale_news');assert.equal(writes,0);
});
