import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const env={
 AUTH_PASSWORD:"long-enough-private-test-password",
 SESSION_SECRET:"unit-test-session-secret-is-at-least-32-chars-long",
 ASSETS:{fetch:async()=>new Response("private v2")}
};
test("the retired R2 ingestion routes are disabled with no bucket binding",async()=>{
 const a=await worker.fetch(new Request(origin+"/api/image-ingest-ready"),env);
 const b=await worker.fetch(new Request(origin+"/api/image-ingest",
   {method:"POST",body:"no_image_upload"}),env);
 assert.equal(a.status,410);
 assert.equal(b.status,410);
 assert.equal((await a.json()).error,"image_backend_migrated_to_github");
 assert.equal((await b.json()).error,"image_backend_migrated_to_github");
});
test("health reports the zero-extra-cost GitHub image backend",async()=>{
 const r=await worker.fetch(new Request(origin+"/health"),env);
 assert.equal(r.status,200);
 const body=await r.json();
 assert.equal(body.image_storage,"github");
 assert.equal(body.image_flow,"same-chat");
 assert.equal(body.configured,true);
});
