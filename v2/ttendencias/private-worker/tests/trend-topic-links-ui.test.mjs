import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

const app=readFileSync(new URL("../web-source/app.js",import.meta.url),"utf8");
const css=readFileSync(new URL("../web-source/styles.css",import.meta.url),"utf8");

test("related trend icon names the published origin and does not open the trend card",()=>{
 assert.match(app,/function updateTopicIcons\(\)/);
 assert.match(app,/link\.origin_name/);
 assert.match(app,/window\.alert\("Relacionada con "/);
 assert.match(app,/event\.preventDefault\(\);event\.stopPropagation\(\)/);
 assert.match(app,/head\.insertBefore\(icon,head\.querySelector\("\.red-toggle"\)\)/);
 assert.match(css,/\.topic-link-icon\{/);
});

test("related trend icon disappears from reset rows and from sources no longer active",()=>{
 assert.match(app,/item\.re_in_progress===true\|\|reResetPending\(item\)/);
 assert.match(app,/source\?\.revision===link\.origin_revision/);
 assert.match(app,/source\.re_in_progress!==true&&!reResetPending\(source\)/);
 assert.match(app,/for\(const card of document\.querySelectorAll\("details\.trend"\)\)/);
});
