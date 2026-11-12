'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {runOne}=require('./browser-lifecycle.cjs');
const job={trend_id:'trv2-example',revision:1,token:'test-token'};
test('éxito: guardar, verificar, cerrar, en ese orden',async()=>{
  const order=[];
  const result=await runOne({job,browserFactory:async()=>({execute:async()=>{order.push('execute');return 'Texto contrastado';},close:async()=>order.push('close')}),persistAndVerify:async()=>{order.push('persist_verify');return true;}});
  assert.equal(result.status,'ready');
  assert.deepEqual(order,['execute','persist_verify','close']);
});
test('fallo editorial: cerrar sin persistir',async()=>{
  let closed=false;
  await assert.rejects(runOne({job,browserFactory:async()=>({execute:async()=>{throw Error('editor_failed')},close:async()=>{closed=true}}),persistAndVerify:async()=>{throw Error('must_not_persist')}}),/editor_failed/);
  assert.equal(closed,true);
});
test('resultado no verificado: cerrar y no declarar ready',async()=>{
  let closed=false;
  await assert.rejects(runOne({job,browserFactory:async()=>({execute:async()=> 'texto',close:async()=>{closed=true}}),persistAndVerify:async()=>false}),/result_not_verified/);
  assert.equal(closed,true);
});
test('timeout: cerrar navegador',async()=>{
  let closed=false;
  await assert.rejects(runOne({job,browserFactory:async()=>({execute:async()=>new Promise(()=>{}),close:async()=>{closed=true}}),persistAndVerify:async()=>true,timeoutMs:10}),/editorial_timeout/);
  assert.equal(closed,true);
});
test('error de cierre: no declarar éxito',async()=>{
  await assert.rejects(runOne({job,browserFactory:async()=>({execute:async()=> 'texto',close:async()=>{throw Error('close_failed')}}),persistAndVerify:async()=>true}),/close_failed/);
});
test('nunca abrir navegador para una reserva incompleta',async()=>{
  let opened=false;
  await assert.rejects(runOne({job:{trend_id:'x'},browserFactory:async()=>{opened=true},persistAndVerify:async()=>true}),/invalid_job/);
  assert.equal(opened,false);
});
