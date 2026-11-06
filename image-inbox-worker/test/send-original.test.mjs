import test from 'node:test';
import assert from 'node:assert/strict';
import { prepare, sendPendingImage, validateDestination } from '../tools/send-original.mjs';
const bytes = new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1]);
const metadata = {identity:{project:'ttendencias',editorialId:'tr-123',revision:0,commandId:'tr-img-123'},title:'One',editorialText:'Factual text'};
test('requires validated HTTPS private origin',()=>{
 assert.equal(validateDestination('https://inbox.example.com/'),'https://inbox.example.com');
 for(const invalid of ['http://inbox.example.com','https://inbox.example.com/path','https://user:pass@inbox.example.com','https://inbox.example.com?token=x'])assert.throws(()=>validateDestination(invalid));
});
test('rejects edited or fake image bytes',async()=>{
 await assert.rejects(prepare(new Uint8Array(24),metadata));
});
test('rejects mismatching supplied SHA',async()=>{
 await assert.rejects(prepare(bytes,{...metadata,identity:{...metadata.identity,rasterSHA256:'a'.repeat(64)}}));
});
test('actual raster SHA transmitted with original, never a preview or public catalog write',async()=>{
 let captured;
 const result=await sendPendingImage({baseURL:'https://inbox.example.com/',secret:'secret'.repeat(8),originalBytes:bytes,metadata,
  fetchFn:async (url,options)=>{
    captured={url,options};return new Response(JSON.stringify({id:'a'.repeat(64),state:'pending'}),{status:201});
  }});
 assert.equal(result.state,'pending');
 assert.equal(captured.url,'https://inbox.example.com/v1/images/ingest');
 assert.equal(captured.options.method,'POST');
 const given=JSON.parse(captured.options.body.get('metadata'));
 assert.equal(given.identity.rasterSHA256,result.rasterSHA256);
 assert.match(given.identity.episodeFingerprint,/^[a-f0-9]{64}$/);
 assert.equal((await captured.options.body.get('image').arrayBuffer()).byteLength,bytes.length);
});

test('rejects a wrong supplied episode fingerprint',async()=>{
 await assert.rejects(prepare(bytes,{...metadata,identity:{...metadata.identity,episodeFingerprint:'f'.repeat(64)}}));
});