import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {dirname,join} from "node:path";

const base=join(dirname(fileURLToPath(import.meta.url)),"..");
const app=readFileSync(join(base,"web-source/app.js"),"utf8");
const built=readFileSync(join(base,"dist/app.js"),"utf8");
const index=readFileSync(join(base,"dist/index.html"),"utf8");
const css=readFileSync(join(base,"dist/styles.css"),"utf8");

const start=app.indexOf("function movementIndicator(item)");
const end=app.indexOf("\nfunction top30Since(item)",start);
assert.ok(start>=0&&end>start,"movement indicator is present in the private source");
const el=(tag,cls,value)=>({tag,className:cls,textContent:String(value),title:"",setAttribute(key,val){this[key]=val}});
const move=new Function("el",app.slice(start,end)+"\nreturn movementIndicator;")(el);

test("each private Top 30 rank displays the real previous-snapshot position delta",()=>{
 const up=move({rank:1,previous_rank:5,movement:"up"});
 assert.equal(up.textContent,"↑ 4");
 assert.match(up.className,/up/);
 const down=move({rank:8,previous_rank:5,movement:"down"});
 assert.equal(down.textContent,"↓ 3");
 assert.match(down.className,/down/);
 const same=move({rank:3,previous_rank:3,movement:"unchanged"});
 assert.equal(same.textContent,"—");
 assert.match(same.className,/same/);
 assert.equal(move({rank:1,previous_rank:null,movement:"entry"}).textContent,"Nueva");
 assert.equal(move({rank:1,previous_rank:null,movement:"short_return"}).textContent,"Vuelve");
 assert.equal(move({rank:1,previous_rank:null,movement:"reentry"}).textContent,"Vuelve");
 assert.equal(move({rank:1,previous_rank:null,movement:"baseline"}).textContent,"—");
});

test("private site shows entry date, explanation date, and full radar date",()=>{
 const since=app.indexOf("function top30Since(item)");
 const tail=app.indexOf("\nfunction render()",since);
 assert.ok(since>=0&&tail>since);
 assert.match(app.slice(since,tail),/entered_top30_at/);
 assert.match(app,/title\.append\(entered\)/);
 assert.match(app,/title\.append\(time\)/);
 assert.match(built,/function movementIndicator\(item\)/);
 assert.match(built,/function top30Since\(item\)/);
 assert.match(built,/updateRadar\(state\.captured\)/);
 assert.match(built,/weekday:"short"/);
 assert.match(css,/\.movement-indicator\.up/);
 assert.match(css,/\.movement-indicator\.down/);
 assert.match(css,/\.movement-indicator\.return/);
 assert.match(app,/Regresó el /);
 assert.match(index,/styles\.css/);
});

test("private app only loads state through its authorized Worker proxy",()=>{
 assert.match(built,/const BASE="\/api\/state\/"/);
 assert.doesNotMatch(built,/const BASE="https:\/\/raw\.githubusercontent\.com/);
 assert.doesNotMatch(built,/localStorage\.setItem\(MARKS_KEY/);
 assert.match(built,/\/api\/marks/);
});

test("R remains clickable in collapsed card without toggling its disclosure",()=>{
 const r=app.indexOf('const flag=el("button","red-toggle","R");');
 const end=app.indexOf('const body=el("div","explanation"',r);
 assert.ok(r>=0&&end>r,"R control is part of every Top30 item");
 const block=app.slice(r,end);
 assert.match(block,/event\.preventDefault\(\)/);
 assert.match(block,/event\.stopPropagation\(\)/);
 assert.match(block,/head\.append\(flag\)/);
 assert.doesNotMatch(block,/card\.append\(flag\)/);
 assert.match(css,/\.trend\.marked-red\{background:/);
 assert.match(css,/\.red-toggle\{position:static;flex:none/);
 assert.match(built,/head\.append\(flag\)/);
});

test("RE requested has visible pending state and hides previous explanation and image",()=>{
 assert.match(app,/function reResetPending\(item\)/);
 assert.match(app,/const reset=reResetPending\(item\)/);
 assert.match(app,/RE solicitada · reinicio pendiente/);
 assert.match(app,/En revisión · nueva explicación en preparación/);
 assert.match(app,/const time=reset\?null:explanationTime\(item\)/);
 assert.match(app,/if\(!reset&&\(imageReady\(item\)\|\|item\.image_suppressed===true\)\)/);
 assert.match(app,/if\(!reset\)\{makePublishButtons\(card,item\);attachGeneratedImage\(card,item\);\}/);
 assert.match(css,/\.review-state/);
});
