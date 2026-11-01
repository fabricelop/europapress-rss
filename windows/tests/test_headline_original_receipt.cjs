"use strict";
// Offline, no CDP, no Telegram, no ImageGen, no external writes.
const assert=require("node:assert/strict");
const {test}=require("node:test");
const fs=require("node:fs");
const path=require("node:path");
const mod=require("../TTiTTularesWebImages.cjs");
const snapshot={tweet_text:"Titular y remate verificables",factual_summary:"Hechos comprobados",remate:"Un solo remate"};
const job={command_id:"tt-img-test-r1",target_id:"newsABC",revision:1,context_snapshot:snapshot};
const base={command_id:job.command_id,target_id:job.target_id,revision:job.revision,
  editorial_sha256:mod.headlineFingerprint(snapshot)};
test("Fingerprint ties exact tweet/facts/remate to job and revision",()=>{
 assert.match(base.editorial_sha256,/^[a-f0-9]{64}$/);
 assert.equal(mod.sameContext(base,job),true);
 assert.equal(mod.sameContext({...base,target_id:"other"},job),false);
 assert.equal(mod.sameContext({...base,revision:2},job),false);
 assert.equal(mod.sameContext(base,{...job,context_snapshot:{...snapshot,remate:"Otro"}}),false);
 assert.equal(mod.sameContext({...base,command_id:"new-job"},job),false);
});
test("No attachment based on a previous or missing image turn",()=>{
 const probe=mod.rasterProbe(job.command_id);
 assert(probe.includes("later_user_turn"));
 assert(probe.includes("ambiguous_or_missing_raster"));
 assert(probe.includes("naturalWidth>=1024"));
 assert(!probe.includes("SITE_RETURN"));
});
test("Only newest eligible pending command is recovered",()=>{
 const now=Date.now();
 const task=(id,command,age,status="waiting")=>({task:{
  target_id:id,command_id:command,revision:1,editorial_sha256:base.editorial_sha256,
  created_at:new Date(now-age).toISOString(),status
 }});
 const old=task("newsABC","first",40000),newer=task("newsABC","second",20000);
 const another=task("newsXYZ","other",30000),done=task("newsDEF","done",1000,"published");
 const active=mod.dueTasks([old,newer,another,done],now);
 assert.deepEqual(new Set(active.map(x=>x.task.command_id)),new Set(["second","other"]));
});
test("Consumer is a receiver only, never posts a second generation prompt",()=>{
 const source=fs.readFileSync(path.join(__dirname,"..","TTiTTularesWebImages.cjs"),"utf8");
 assert(source.includes("web_image_upload"));
 assert(source.includes("context_editorial_sha256"));
 assert(!source.includes("Input.insertText"));
 assert(!source.includes("Input.dispatchKeyEvent"));
 assert(!source.includes("SITE_RETURN_AFTER_IMAGE"));
 const backend=fs.readFileSync(path.join(__dirname,"..","..","vercel-webhook","lib","ttittulares-run-handler.js"),"utf8");
 assert(backend.includes("validHeadlineWebReceipt"));
 assert(backend.includes('rawTask==="web_image_upload"'));
 assert(backend.includes("upload_sha256"));
 assert(backend.includes('["DONE","PERSISTING"].includes'));
});
