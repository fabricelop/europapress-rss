'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const src=fs.readFileSync(path.join(__dirname,'..','Reparar-TT-Editorial-20261111.ps1'),'utf8');
test('a healthy idle browser above 18 tabs does not block both editorial queues',()=>{
 assert.match(src,/pages\.length>48\)fail\('TOO_MANY_TABS_HARD_CAP/);
 assert.match(src,/pages\.length>18\)note\('EDITORIAL_TAB_SOFT_PRESSURE/);
 assert.doesNotMatch(src,/pages\.length>18\)fail\('TOO_MANY_TABS /);
});
test('new checks still fail closed for active/untracked work',()=>{
 assert.match(src,/busy\.length>1\|\|busy\.some\(t=>!confirmedIds\.has\(t\.id\)\)/);
 assert.match(src,/pinIds\(\)/);
 assert.match(src,/DRAFT_NOT_VERIFIED/);
 assert.match(src,/AMBIGUOUS_PREVIOUS_SEND/);
 assert.match(src,/if\(pp\.length>48\)fail\('NO_PROBE/);
});
