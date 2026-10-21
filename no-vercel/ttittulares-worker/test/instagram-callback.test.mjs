import test from "node:test";
import {readFileSync} from "node:fs";
import assert from "node:assert/strict";
import worker,{parseTtiCallback} from "../src/index.js";

const update=(action)=>({
  update_id:218639500,
  callback_query:{
    id:"7650439579279999999",
    data:"tt:"+action+":abc123def012",
    message:{message_id:3091,chat:{id:-1002345678910}}
  }
});

test("Instagram tt:i callback has its own action type, not X publish or dismiss",()=>{
  const parsed=parseTtiCallback(update("i"));
  assert.ok(parsed);
  assert.equal(parsed.type,"instagram_action");
  assert.equal(parsed.text,"tti_ig|abc123def012");
  for(const action of ["p","d"]){
    const x=parseTtiCallback(update(action));
    assert.equal(x.type,"emergency_action");
    assert.equal(x.text,(action==="p"?"ttp":"ttd")+"|abc123def012");
  }
  assert.equal(parseTtiCallback(update("unknown")),null);
});

test("unverified Telegram Instagram callbacks cannot reach Meta publisher",async()=>{
  const originalFetch=globalThis.fetch;
  let requests=0;
  globalThis.fetch=async()=>{requests++;throw new Error("No external request expected");};
  try{
    const result=await worker.fetch(new Request("https://example.test/api/ttittulares-telegram-callback",{
      method:"POST",headers:{"content-type":"application/json"},
      body:JSON.stringify(update("i"))
    }),{});
    assert.equal(result.status,503);
    assert.equal(requests,0);
  }finally{globalThis.fetch=originalFetch;}
});

test("new Instagram callback preflight is read-only and leaves X routing untouched",async()=>{
  const marker=await worker.fetch(new Request("https://worker.example/api/ttittulares-instagram-route-version"),{});
  assert.equal(marker.status,200);
  const data=await marker.json();
  assert.equal(data.version,"instagram-callback-preflight-v1");
  assert.equal(data.telegram_callback,"tt:i");
  assert.equal(data.status,"disabled_until_credentials");
  const existing=await worker.fetch(new Request("https://worker.example/api/ttittulares-telegram-pipeline-version"),{});
  assert.equal(existing.status,200);
  assert.equal((await existing.json()).version,"immediate-decision-delete-v2");
});

test("Instagram cleanup callback carries only the original Telegram message ID",()=>{
  const cb=update("i");
  cb.callback_query.data="tt:igdel:3091";
  cb.callback_query.message.message_id=4100;
  const parsed=parseTtiCallback(cb);
  assert.equal(parsed.type,"instagram_delete");
  assert.equal(parsed.original_message_id,3091);
  assert.equal(parsed.message_id,4100);
  cb.callback_query.data="tt:igdel:not-a-number";
  assert.equal(parseTtiCallback(cb),null);
});

test("Instagram cleanup verifies linked reply and retains confirmation on failure",()=>{
  const source=readFileSync(new URL("../src/index.js",import.meta.url),"utf8");
  assert.match(source,/async function deleteInstagramTelegramPair\(/);
  assert.match(source,/replyId>0&&replyId!==originalId/);
  assert.match(source,/const confirmationDeleted=originalDeleted\?await remove\(confirmationId\):false/);
  assert.match(source,/originalId===confirmationId/);
  assert.match(source,/callback_data:"tt:igdel:"\+messageId/);
  assert.match(source,/event.type==="instagram_delete"/);
});

test("Instagram callback errors notify Telegram; X handlers stay separate",()=>{
  const source=readFileSync(new URL("../src/index.js",import.meta.url),"utf8");
  assert.match(source,/async function instagramTelegramNotice\(/);
  assert.match(source,/TTActualidad-TTiTTulares\/1\.0/);
  assert.match(source,/result\.meta_error_code/);
  assert.match(source,/No se ha podido confirmar la publicaci[oó]n/);
  assert.match(source,/await instagramTelegramNotice\(env,update/);
  assert.match(source,/if\(event\.type==="instagram_action"\)/);
  assert.match(source,/TTITTULARES_INSTAGRAM_BUTTON_EDIT_FAILED/);
  assert.match(source,/TTITTULARES_INSTAGRAM_SUCCESS_NOTICE_FAILED/);
  assert.match(source,/await instagramTelegramNotice\(env,update,"Publicado en Instagram: "/);
  assert.match(source,/match\[1\]==="i"\?"instagram_action":"emergency_action"/);
});

test("Instagram preflight requires bearer secret and never publishes",async()=>{
 const url="https://worker.example/api/ttittulares-instagram-preflight";
 const denied=await worker.fetch(new Request(url),{});
 assert.equal(denied.status,401);
 const secret="test-secret-with-at-least-thirty-two-characters";
 const prev=globalThis.fetch;
 globalThis.fetch=async()=>{throw Error("Network fetch is forbidden; service binding only")};
 try{
  const result=await worker.fetch(new Request(url+"?chat_id=-100222333444",{headers:{authorization:"Bearer "+secret}}),{
   INSTAGRAM_INTERNAL_SECRET:secret,
   INSTAGRAM_ALLOWED_CHAT_ID:"-100222333444",
   INSTAGRAM_PUBLISHER_URL:"https://tt-actualidad-instagram-pilot.fabricelop.workers.dev",
   GITHUB_TOKEN:"test",
   TTITTULARES_CALLBACK_DECRYPT_KEY:"test",
   INSTAGRAM_PUBLISHER:{fetch:async request=>{
     assert.equal(new URL(request.url).pathname,"/meta-preflight");
     return Response.json({ok:true,active:true});
   }}
  });
  assert.equal(result.status,200);
  const d=await result.json();
  assert.equal(d.chat_matches,true);
  assert.equal(d.publisher_authenticated,true);
  assert.equal(d.ok,true);
 }finally{globalThis.fetch=prev}
});

test("Instagram publisher calls are routed by same-account Cloudflare service binding",()=>{
 const source=readFileSync(new URL("../src/index.js",import.meta.url),"utf8");
 const config=JSON.parse(readFileSync(new URL("../wrangler.jsonc",import.meta.url),"utf8"));
 assert.deepEqual(config.services,[{binding:"INSTAGRAM_PUBLISHER",service:"tt-actualidad-instagram-pilot"}]);
 assert.match(source,/env\.INSTAGRAM_PUBLISHER\.fetch\(new Request\(endpoint,options\)\)/);
 assert.match(source,/await callInstagramPublisher\(env,endpoint,\{method:"POST"/);
 assert.match(source,/await callInstagramPublisher\(env,publisher\+"\/meta-preflight"/);
 assert.doesNotMatch(source,/await fetch\(endpoint,\{method:"POST"/);
});

test("A published Instagram image always triggers Telegram reply, not only a button edit",()=>{
 const source=readFileSync(new URL("../src/index.js",import.meta.url),"utf8");
 const published=source.slice(source.indexOf('if(result.state==="published"&&result.permalink?'));
 const success=published.slice(0,published.indexOf("// Never delete Telegram"));
 assert.match(success,/await instagramTelegramNotice\(env,update,"Publicado en Instagram: "\+result.permalink,/);
 assert.match(success,/return json\(\{ok:true,state:"published",permalink:result.permalink\}\)/);
 assert.match(success,/TTITTULARES_INSTAGRAM_SUCCESS_NOTICE_FAILED/);
});
