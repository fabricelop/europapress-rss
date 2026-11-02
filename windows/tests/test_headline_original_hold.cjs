'use strict';
// No image generation, browser activity or network. Verify the handoff race
// cannot regress to 90 seconds when ImageGen needs > 2 minutes.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const bridge=fs.readFileSync(path.join(__dirname,'..','TTiTTularesImageBridge.js'),'utf8');
const receiver=fs.readFileSync(path.join(__dirname,'..','TTiTTularesWebImages.cjs'),'utf8');
test('News waits as long as Trends (6 minutes) for the real image receipt',()=>{
 assert.match(bridge,/async function holdForHeadlineOriginalReceipt\(handoff,job,maxMs=360000\)/);
 assert.match(bridge,/await holdForHeadlineOriginalReceipt\(webHandoff,job\)/);
 assert.doesNotMatch(bridge,/const until=Date\.now\(\)\+90000/);
 assert.match(bridge,/receipt\.github_outbox_committed_at\|\|receipt\.upload_accepted_at/);
 assert.match(bridge,/String\(receipt\.command_id\)===commandId/);
 assert.match(bridge,/Number\(receipt\.revision\|\|0\)===Number\(job\.revision\|\|0\)/);
 assert.match(bridge,/await optionalWebHandoff\(handoff,true\)/);
});
test('Retained original can be recovered by proven conversation URL if CDP tab ID changes',()=>{
 assert.match(receiver,/const candidates=pages\.filter/);
 assert.match(receiver,/chatURL\(x\.url\)===task\.conversation_url/);
 assert.match(receiver,/candidate\.evaluate\(conversationProbe\(task\.command_id\)\)/);
 assert.match(receiver,/if\(chatURL\(proven\)===task\.conversation_url\)/);
});
test('Detached receiver writes reason-only local diagnostic logs',()=>{
 assert.match(receiver,/receiver\.log/);
 assert.match(receiver,/receiver\.err\.log/);
 assert.match(receiver,/stdio:\['ignore',output,errors\]/);
});

test('Manual recovery retries only a previously enrolled exact news item',()=>{
 assert.match(receiver,/process\.argv\.indexOf\('--once-id'\)/);
 assert.match(receiver,/onlyTargetId\?newestActiveByTarget\(tasks,now\)\.get\(onlyTargetId\)/);
 assert.match(receiver,/if\(onlyTargetId&&!due\.length\)console\.log\('TTITTULARES_WEB_IMAGE_RECOVERY_NO_PENDING_RECEIPT '/);
 assert.match(receiver,/if\(onlyTargetId!==null&&!safeID\(onlyTargetId\)\)throw Error/);
});
