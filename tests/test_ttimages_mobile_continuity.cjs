"use strict";
// Static continuity guarantees; no live service calls or credentials.
const assert=require("node:assert/strict");
const {test}=require("node:test");
const fs=require("node:fs");
const read=p=>fs.readFileSync(p,"utf8");

test("iOS editorial read path is GitHub and persists last good snapshots",()=>{
 const s=read("ios/ttactualidad/TTActualidad/EditorialStore.swift");
 assert(s.includes('"https://raw.githubusercontent.com/fabricelop/europapress-rss/main/" + path'));
 assert(s.includes('source = try? Data(contentsOf: cacheURL)'));
 assert(s.includes('message = "Datos incompletos: conservando los últimos contadores"'));
 const begin=s.indexOf("func refresh() async");
 const end=s.indexOf("static func ",begin);
 const refresh=s.slice(begin,end<0?begin+7500:end);
 assert(!refresh.includes("tt-control.fabricelop.workers.dev"));
 assert(!refresh.includes("ttittulares-no-vercel-test"));
});

test("both web presentations retain GitHub and local fallback",()=>{
 for(const p of ["pilot/ttactualidad-live/index.html","docs/ttactualidad/index.html"]){
  const s=read(p);
  assert(s.includes("const sources=[RAW+path,SITE_DATA+path]"),p);
  assert(s.includes("localStorage.getItem(key)"),p);
  assert(s.includes("localStorage.setItem(key"),p);
  assert(s.includes("return doc;"),p);
 }
});

test("Cloudflare receiver outage defers AI attachment, never changes READY or existing images",()=>{
 const s=read("windows/TTiTTularesWebImages.cjs");
 assert(s.includes("receiver_update_pending"));
 assert(s.includes("status:'waiting',reason:'receiver_update_pending'"));
 assert(s.includes("status:'needs_review'"));
 assert(s.includes("needs_review_preserved_original"));
 assert(!s.includes("status:'expired',reason:'image_not_confirmed_within_72h',secret_dpapi:undefined"));
 assert(!s.includes("Input.insertText"));
 assert(!s.includes("Input.dispatchKeyEvent"));
 const job=s.slice(s.indexOf("async function consume(task){"),s.indexOf("async function telemetry("));
 assert(job.includes("headlineFingerprint"));
 assert(job.includes("return {status:'obsolete',reason:'editorial_changed'}"));
});

test("web update never introduces Cloudflare into mobile read sources",()=>{
 const paths=["ios/ttactualidad/TTActualidad/EditorialStore.swift",
    "pilot/ttactualidad-live/index.html","docs/ttactualidad/index.html"];
 for(const p of paths){
  assert(!read(p).includes("web-image-contract"),p);
 }
});
