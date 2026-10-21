import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const secret="test-only-secret-must-never-be-used-in-production-012345";
const sample={
  source:"ttittulares",
  event_id:"abcde123",
  revision:1,
  telegram_message_id:234,
  image_url:"https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/instagram-images/ig-abcde123-r1-sample.jpg",
  caption:"Contenido editorial con imagen IA."
};
function request(){
  return new Request("https://pilot.test/publish",{
    method:"POST",headers:{authorization:"Bearer "+secret,"content-type":"application/json"},
    body:JSON.stringify(sample)
  });
}
test("even valid-looking configured credentials cannot post while explicit switch is off",async()=>{
  const env={
    INSTAGRAM_INTERNAL_SECRET:secret,
    INSTAGRAM_PAGE_ACCESS_TOKEN:"test-page-token",
    INSTAGRAM_USER_ID:"17841414511690117",
    IG_DB:{prepare(){throw Error("D1 must not be called when disabled");}}
  };
  const oldFetch=globalThis.fetch;
  globalThis.fetch=async()=>{throw Error("Meta must not be called when disabled");};
  try{
    const status=await (await worker.fetch(new Request("https://pilot.test/health"),env)).json();
    assert.equal(status.active,false);
    const response=await worker.fetch(request(),env);
    assert.equal(response.status,503);
    assert.equal((await response.json()).error,"PILOT_DISABLED");
  }finally{globalThis.fetch=oldFetch;}
});
test("health indicates activation only if explicit flag and required bindings are present",async()=>{
  const env={
    INSTAGRAM_INTERNAL_SECRET:secret,
    INSTAGRAM_PAGE_ACCESS_TOKEN:"test-page-token",
    INSTAGRAM_USER_ID:"17841414511690117",
    IG_DB:{},
    INSTAGRAM_PUBLISH_ENABLED:"1"
  };
  assert.equal((await (await worker.fetch(new Request("https://pilot.test/health"),env)).json()).active,true);
  delete env.INSTAGRAM_PAGE_ACCESS_TOKEN;
  assert.equal((await (await worker.fetch(new Request("https://pilot.test/health"),env)).json()).active,false);
});
