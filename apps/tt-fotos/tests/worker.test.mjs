import test from 'node:test';
import assert from 'node:assert/strict';
import {createWorker} from '../src/worker.mjs';
const env={FOTOS_DB:{},FOTOS_R2:{},ASSETS:{fetch:async()=>new Response('<h1>Private gallery</h1>',{headers:{'content-type':'text/html'}})}};
const authorized=()=>({isEditor:true,email:'editor@example.org'});
const denied=()=>null;
const apiFactory=()=>async()=>new Response(JSON.stringify({ok:true,private:true}),{headers:{'content-type':'application/json'}});
test('standalone gallery denies anonymous access without serving any asset',async()=>{
 let called=0;const e={...env,ASSETS:{fetch:()=>{called++;return new Response('leaked')}}};
 const response=await createWorker({auth:denied,apiFactory}).fetch(new Request('https://tt-fotos.example/fotos'),e);
 assert.equal(response.status,403);assert.equal(called,0);
});
test('authorized editor receives private no-cache gallery',async()=>{
 const response=await createWorker({auth:authorized,apiFactory}).fetch(new Request('https://tt-fotos.example/fotos'),env);
 assert.equal(response.status,200);
 assert.equal(response.headers.get('cache-control'),'private, no-store');
 assert.equal(response.headers.get('x-frame-options'),'DENY');
 assert.match(await response.text(),/Private gallery/);
});
test('standalone API is dispatched only to its own namespace',async()=>{
 const app=createWorker({auth:authorized,apiFactory});
 const status=await app.fetch(new Request('https://tt-fotos.example/api/tt-fotos/v1/status'),env);
 assert.equal(status.status,200);
 assert.deepEqual(await status.json(),{ok:true,private:true});
 assert.equal((await app.fetch(new Request('https://tt-fotos.example/api/image-inbox/v1/images'),env)).status,404);
 assert.equal((await app.fetch(new Request('https://tt-fotos.example/ttactualidad'),env)).status,404);
});
test('unconfigured data storage fails closed',async()=>{
 const response=await createWorker({auth:authorized,apiFactory}).fetch(new Request('https://tt-fotos.example/fotos'),{ASSETS:env.ASSETS});
 assert.equal(response.status,503);
});