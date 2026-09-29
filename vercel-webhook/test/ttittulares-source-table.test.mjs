import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html=fs.readFileSync(new URL("../ttittulares/index.html", import.meta.url), "utf8");
const inline=html.match(/<script>([\s\S]*?)<\/script>/i)?.[1];
assert.ok(inline,"TTiTTulares inline script must exist");
new vm.Script(inline,{filename:"ttittulares/index.inline.js"});
const functionMatch=inline.match(/function sourceAgeInfo\(value,nowMs=Date\.now\(\)\)\{[\s\S]*?\n\}(?=\nfunction renderSourcesSheet)/);
assert.ok(functionMatch,"Source elapsed time formatter missing");
const sourceAge=vm.runInNewContext(functionMatch[0]+"\nsourceAgeInfo",{Date,Number,Math,String});

test("elapsed time shows HH:MM with precise green/orange/red thresholds",()=>{
 const now=Date.UTC(2026,8,29,20,0);
 const past=mins=>new Date(now-mins*60000).toISOString();
 assert.deepEqual({...sourceAge(past(719),now)},{text:"11:59",level:"fresh",minutes:719});
 assert.deepEqual({...sourceAge(past(720),now)},{text:"12:00",level:"warning",minutes:720});
 assert.deepEqual({...sourceAge(past(1439),now)},{text:"23:59",level:"warning",minutes:1439});
 assert.deepEqual({...sourceAge(past(1440),now)},{text:"24:00",level:"stale",minutes:1440});
 assert.deepEqual({...sourceAge(past(1501),now)},{text:"25:01",level:"stale",minutes:1501});
 assert.equal(sourceAge(null,now).level,"unknown");
 assert.equal(sourceAge("not-a-time",now).text,"—");
});
test("table uses persisted 24h count, not the current sweep count",()=>{
 assert.match(inline,/x\.articles_24h!=null\?Number\(x\.articles_24h\):NaN/);
 assert.match(inline,/const age=sourceAgeInfo\(x\.last_article_at\|\|x\.last_contribution_at\)/);
 assert.match(inline,/for\(const value of \["Fuente","Hace hh:mm","Art\. 24 h","Estado"\]\)/);
 assert.match(inline,/table\.setAttribute\("aria-label"/);
 assert.match(inline,/x\.recovered\?"● Altern\.":"● OK"/);
 assert.match(html,/max-height:62vh/);
});
