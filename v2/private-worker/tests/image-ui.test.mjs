import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

test("private Top30 displays revision-bound original only after opening card",()=>{
 const src=readFileSync(new URL("../web-source/app.js",import.meta.url),"utf8");
 assert.match(src,/function attachGeneratedImage\(card,item\)/);
 assert.match(src,/item.status!=="explicada"/);
 assert.match(src,/picture.src="\/api\/image\/"\+encodeURIComponent\(item.trend_id\)\+"\?revision="\+item.revision/);
 assert.match(src,/card.addEventListener\("toggle",openImage\)/);
 assert.match(src,/attachGeneratedImage\(card,item\);/);
 assert.doesNotMatch(src,/picture.src="https:\/\/raw.githubusercontent.com/);
});
