import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

test("private Top30 displays revision-bound original only after opening card",()=>{
 const src=readFileSync(new URL("../web-source/app.js",import.meta.url),"utf8");
 assert.match(src,/function attachGeneratedImage\(card,item\)/);
 assert.match(src,/if\(!imageReady\(item\)\)return/);
 assert.match(src,/picture.src="\/api\/image\/"\+encodeURIComponent\(item.trend_id\)\+"\?revision="\+item.revision/);
 assert.match(src,/card.addEventListener\("toggle",openImage\)/);
 assert.match(src,/attachGeneratedImage\(card,item\);/);
 assert.doesNotMatch(src,/picture.src="https:\/\/raw.githubusercontent.com/);
});

test("collapsed card shows image indicator only when exact revision is bound",()=>{
 const src=readFileSync(new URL("../web-source/app.js",import.meta.url),"utf8");
 assert.match(src,/function imageReady\(item\)/);
 assert.match(src,/item\.image_available===true/);
 assert.match(src,/Number\.isSafeInteger\(item\.revision\)/);
 assert.match(src,/if\(imageReady\(item\)\)\{\s*const photo=el\("span","image-ready-icon"/);
});

test("P-X and P-IA are manual, revision-bound and never mark a V2 trend published",()=>{
 const src=readFileSync(new URL("../web-source/app.js",import.meta.url),"utf8");
 assert.match(src,/function makePublishButtons\(card,item\)/);
 assert.match(src,/"publish-action","P-X"/);
 assert.match(src,/"publish-action publish-with-image","P-IA"/);
 assert.match(src,/if\(imageReady\(item\)\)/);
 assert.match(src,/navigator\.canShare\?\.\(\{files:\[file\]\}\)/);
 assert.match(src,/"\/api\/image\/"\+encodeURIComponent\(item\.trend_id\)\+"\?revision="\+item\.revision/);
 assert.doesNotMatch(src,/\/api\/publish/);
 assert.doesNotMatch(src,/state\.items\[.*\]\.published/);
});
