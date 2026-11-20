import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {dirname,join} from "node:path";

const base=join(dirname(fileURLToPath(import.meta.url)),"..");
const app=readFileSync(join(base,"web-source/app.js"),"utf8");
const built=readFileSync(join(base,"dist/app.js"),"utf8");
const html=readFileSync(join(base,"dist/index.html"),"utf8");
const css=readFileSync(join(base,"dist/styles.css"),"utf8");
const start=app.indexOf("function countTop30WithoutR(items,marks)");
const end=app.indexOf("\nfunction updateTop30WithoutRCounter()",start);
assert.ok(start>0&&end>start,"counter helper exists");
const count=new Function(app.slice(start,end)+"\nreturn countTop30WithoutR;")();
const top=Array.from({length:30},(_,i)=>({rank:i+1,trend_id:"trv2-"+String(i+1).padStart(24,"0")}));

test("unmarked count uses current Top 30 and the same persisted R state",()=>{
 assert.equal(count(top,{}),30);
 const marks=Object.fromEntries(top.slice(0,12).map(x=>[x.trend_id,"old-entry-stamp"]));
 marks["trv2-old-id-not-in-top30"]="yesterday";
 assert.equal(count(top,marks),18);
 assert.equal(count(top,{...marks,[top[12].trend_id]:"now"}),17);
 assert.equal(count(top,{...marks,[top[0].trend_id]:undefined}),18,"presence is an R mark");
 const without={...marks};delete without[top[0].trend_id];
 assert.equal(count(top,without),19);
 assert.equal(count([...top,{rank:31,trend_id:"outside"}],marks),18);
 assert.equal(count(top.slice(0,29),marks),null,"incomplete ranking cannot claim 30");
});

test("two distinct counters sit to the right of both tabs in a sticky double header",()=>{
 assert.match(html, /class="sticky-shell"><header id="top-bar"/);
 assert.match(html, /id="nav-news"[^>]*>Noticias<\/a><div class="nav-counters"><span id="top30-without-r"/);
 assert.match(html, /id="top30-without-r"[^>]*aria-live="polite" hidden/);
 assert.match(html, /id="news-after-red"[^>]*aria-live="polite" hidden/);
 assert.match(css, /\.sticky-shell\{position:sticky;top:env\(safe-area-inset-top\)/);
 assert.match(css, /\.section-nav \.nav-counters\{margin-left:auto/);
 assert.match(css, /\.section-nav \.news-after-red\{/);
 assert.match(built, /function countTop30WithoutR\(items,marks\)/);
 assert.match(app, /button\.title=next\?"Quitar marca roja":"Marcar en rojo";\s*updateTop30WithoutRCounter\(\)/);
 assert.match(app, /root\.append\(card\);\s*}\s*updateTop30WithoutRCounter\(\)/);
 assert.match(app, /if\(!node\)return/);
 assert.match(app, /if\(!newsViewMode\)try\{await loadNewsAfterRedCounter\(\)\}catch\{\}/);
});
