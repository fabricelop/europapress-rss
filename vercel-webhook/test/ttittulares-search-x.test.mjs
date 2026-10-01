import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html=fs.readFileSync(new URL("../ttittulares/index.html",import.meta.url),"utf8");
const script=html.match(/<script>([\s\S]*?)<\/script>/)?.[1]||"";
assert.ok(script);
new vm.Script(script,{filename:"ttittulares-inline"});
const part=script.match(/function newsSearchKeywords\(item\)\{[\s\S]*?\r?\n\}\r?\nfunction quoteSearchUrl\(item\)\{[\s\S]*?\r?\n\}/);
assert.ok(part,"Missing concise X search");
const context=vm.createContext({String,Set,encodeURIComponent});
vm.runInContext(part[0],context);

test("X search uses only two or three event keywords",()=>{
 context.input={title:"Taylor Swift supera a Beyoncé como la artista más premiada de los MTV VMA"};
 const q=vm.runInContext("newsSearchKeywords(input)",context);
 assert.equal(q,"Taylor Swift Beyoncé");
 const url=vm.runInContext("quoteSearchUrl(input)",context);
 assert.equal(new URL(url).searchParams.get("q"),q);
 assert.ok(q.split(" ").length<=3);
 context.input={title:"Un centenar de personas acampa por la vivienda en Plaça Catalunya"};
 const local=vm.runInContext("newsSearchKeywords(input)",context);
 assert.equal(local,"vivienda Plaça Catalunya");
});
test("no selected tweet quotation panel, source button becomes Buscar en X",()=>{
 assert.doesNotMatch(script,/Tuit para citar|Buscar otro en X|Citar elegido|quoteCandidates\(/);
 assert.doesNotMatch(script,/Abrir fuente/);
 assert.match(script,/Buscar en X/);
 assert.match(script,/search.href=quoteSearchUrl\(item\)/);
 assert.match(script,/card.querySelector\("\.imgSource"\)/);
});
