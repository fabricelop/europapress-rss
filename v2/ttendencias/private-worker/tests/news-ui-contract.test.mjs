import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const js=readFileSync(new URL('../web-source/news.js',import.meta.url),'utf8');

test('all news mutations carry the same security header as Trends',()=>{
 const posts=js.match(/fetch\("\/api\/news-master-action"[^;]*/g)||[];
 assert.equal(posts.length,2);
 for(const post of posts)assert.match(post,/"x-ttv2-action":"1"/);
});

test('news uses fixed cards, without source links or green Noticia status',()=>{
 assert.match(js,/node\("article","news-card"\)/);
 assert.doesNotMatch(js,/node\("details","news-card"\)/);
 assert.doesNotMatch(js,/node\("ul","news-sources"\)/);
 assert.doesNotMatch(js,/"news-status ready"/);
});

test('P-X links to the Site, never to the original article',()=>{
 assert.match(js,/const publicSite="https:\/\/ttactualidad\.rainyraven22\.chatgpt\.site\/"/);
 assert.match(js,/const caption=item\.title\.slice\([^\n]+\+publicSite/);
 assert.doesNotMatch(js,/const caption=[^\n]+item\.url/);
 assert.match(js,/"PU ✓":"PU"/);
});
