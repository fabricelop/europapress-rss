import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import vm from "node:vm";
const source=readFileSync(new URL("../lib/ttittulares-run-status-handler.js",import.meta.url),"utf8");
const start=source.indexOf("let commentsCache="),end=source.indexOf("async function triggerReady()",start);
test("RUNTRACE recupera el final de una lista paginada de >100 comentarios",async()=>{
 const calls=[];
 const response=(items,link="")=>({ok:true,headers:{get:()=>link},json:async()=>items});
 const tr=(id,at,st)=>({id,created_at:at,body:"TTITTULARES_RUNTRACE_V1\n"+JSON.stringify({run_id:id,started_at:at,status:st})});
 const link='<https://api.github.com/repos/fabricelop/europapress-rss/issues/2/comments?per_page=100&page=4>; rel="last"';
 const gh=async url=>{calls.push(url);return url.endsWith("&page=3")?response([tr(201,"2026-10-09T16:00:00Z","ERROR")]):url.endsWith("&page=4")?response([tr(202,"2026-10-09T17:37:36Z","DONE")]):response(Array.from({length:100},(_,i)=>tr(i+1,"2026-10-09T14:00:00Z","ERROR")),link)};
 const ctx={gh,Date,Map,URL,Number,Math,encodeURIComponent,REPO:"fabricelop/europapress-rss",PR:2,TRACE_PREFIX:"TTITTULARES_RUNTRACE_V1\n"};
 vm.createContext(ctx);vm.runInContext(source.slice(start,end),ctx);
 const result=await ctx.comments();assert.equal(result.length,2);assert.equal(result.at(-1).id,202);assert.equal(calls.length,3);
 await ctx.comments();assert.equal(calls.length,3);
});
test("Se distinguen errores antiguos y datos no verificables",()=>{
 const html=readFileSync(new URL("../ttittulares/index.html",import.meta.url),"utf8");
 assert.match(html,/HISTORICAL_RUN_MS=45\*60\*1000/);
 assert.match(html,/Ver diagnóstico anterior/);
 assert.match(html,/Estado editorial sin confirmar/);
});
