import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

const source=readFileSync(new URL("../src/index.js",import.meta.url),"utf8");
const implementation=source.match(/function editorialSnapshotTtlMs\(\)\{[\s\S]*?\n\}/)?.[0];

test("emergency read budget lasts only until D1 resets, then recovers normal freshness",()=>{
 assert.ok(implementation);
 const deadline=Date.parse("2026-11-22T00:00:00Z");
 const ttl=instant=>new Function("Date",implementation+";return editorialSnapshotTtlMs()")({now:()=>instant,parse:Date.parse});
 assert.equal(ttl(deadline-1),300000);
 assert.equal(ttl(deadline),45000);
 assert.equal(ttl(deadline+60000),45000);
});
