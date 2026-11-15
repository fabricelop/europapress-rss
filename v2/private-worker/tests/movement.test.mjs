import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { runInNewContext } from "node:vm";

const source=readFileSync(resolve(import.meta.dirname,"../web-source/app.js"),"utf8");
const extractMovement = input => input.match(/function movementIndicator\(item\)\{[\s\S]*?\r?\n\}\r?\nfunction top30Since/);
const match=extractMovement(source);
assert.ok(match,"movementIndicator debe existir");
function indicator(item,rankingUnchanged=false,rankingChangeAt=null){
 const state={rankingUnchanged,rankingChangeAt};
 const el=(tag,className,label)=>({tag,className,label,setAttribute(k,v){this[k]=v;}});
 const spanishStamp=(value)=>value;
 const fn=runInNewContext(match[0].replace(/\r?\nfunction top30Since$/,"")+"\nmovementIndicator",{state,el,spanishStamp});
 return fn({...item,_rankingMeta:state});
}
test("flechas con número correcto sin mostrar cero artificial",()=>{
 assert.equal(indicator({rank:2,previous_rank:7}).label,"↑ 5");
 assert.equal(indicator({rank:7,previous_rank:2}).label,"↓ 5");
 assert.equal(indicator({rank:4,previous_rank:4}).label,"—");
});
test("ranking idéntico retiene la flecha pero indica que no hay clasificación nueva",()=>{
 const row=indicator({rank:2,previous_rank:7},true,"2026-11-14T22:41:00Z");
 assert.equal(row.label,"↑ 5");
 assert.match(row.title,/Top 30 idéntico/);
 assert.match(row.title,/2026-11-14/);
 assert.match(row.className,/held/);
});
test("sin comparación válida no genera flechas falsas",()=>{
 const row=indicator({rank:4,previous_rank:null,movement:"unverified"},true,null);
 assert.equal(row.label,"—");
 assert.doesNotMatch(row.label,/0/);
});

test("Windows CRLF checkout preserves the movement indicator extractor",()=>{
 const windowsSource=source.replace(/\r?\n/g,"\r\n");
 assert.ok(extractMovement(windowsSource),"CRLF must not hide movementIndicator");
});
