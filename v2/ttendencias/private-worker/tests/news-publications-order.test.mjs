import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {dirname,join} from "node:path";

const app=readFileSync(join(dirname(fileURLToPath(import.meta.url)),"../web-source/app.js"),"utf8");
const helper=app.match(/function publicationEventsForDisplay\(events,news\)\{[\s\S]*?\n\}/)?.[0];
assert.ok(helper,"publication display ordering helper should exist");
const order=new Function(helper+"\nreturn publicationEventsForDisplay;")();

test("Noticias PUB history shows the oldest entry first without mutating the API response",()=>{
 const events=[{pressed_at_ms:300,name:"last"},{pressed_at_ms:100,name:"first"},{pressed_at_ms:200,name:"middle"}];
 assert.deepEqual(order(events,true).map(x=>x.name),["first","middle","last"]);
 assert.deepEqual(events.map(x=>x.name),["last","first","middle"]);
 assert.deepEqual(order(events,false),events,"Tendencias PU ordering is unchanged");
 assert.match(app,/for\(const event of publicationEventsForDisplay\(data\.events,newsViewMode\)\)/);
});
