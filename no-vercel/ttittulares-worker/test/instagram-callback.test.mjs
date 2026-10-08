import test from "node:test";
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
