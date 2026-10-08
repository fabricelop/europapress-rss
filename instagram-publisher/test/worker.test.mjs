import test from "node:test";
import assert from "node:assert/strict";
import worker,{authorize,inputCheck} from "../src/index.js";

const img="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/example-r1.jpg";
const item={source:"ttittulares",event_id:"abcde123",revision:1,telegram_message_id:200,image_url:img,caption:"Texto aprobado\n\nIlustración generada con IA."};
const secret="only-test-not-a-production-credential-1234";

test("health never declares the Instagram publisher activated",async()=>{
  const r=await worker.fetch(new Request("https://example.com/health"),{});
  assert.equal(r.status,200);
  assert.equal((await r.json()).active,false);
});
test("no anonymous or short-secret publication",async()=>{
  const req=new Request("https://example.com/publish",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(item)});
  const r=await worker.fetch(req,{INSTAGRAM_INTERNAL_SECRET:secret});
  assert.equal(r.status,401);
  assert.equal(authorize(new Request("https://example.com",{headers:{authorization:"Bearer abc"}}),{INSTAGRAM_INTERNAL_SECRET:"abc"}),false);
});
test("valid inputs and restricted image host",()=>{
  const validated=inputCheck(item);
  assert.equal(validated.key,"ttittulares:abcde123");
  for(const image of ["https://evil.test/img.jpg","https://raw.githubusercontent.com/other/repo/main/ttittulares/generated-images/a.jpg","https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/a.png"]){
    assert.throws(()=>inputCheck({...item,image_url:image}));
  }
  assert.throws(()=>inputCheck({...item,caption:""}));
  assert.throws(()=>inputCheck({...item,telegram_message_id:0}));
  assert.throws(()=>inputCheck({...item,source:"other"}));
});
test("authenticated but unconfigured publisher fails closed",async()=>{
  const req=new Request("https://example.com/publish",{method:"POST",headers:{"content-type":"application/json",authorization:"Bearer "+secret},body:JSON.stringify(item)});
  const r=await worker.fetch(req,{INSTAGRAM_INTERNAL_SECRET:secret});
  assert.equal(r.status,503);
  assert.equal((await r.json()).error,"NOT_CONFIGURED");
});
