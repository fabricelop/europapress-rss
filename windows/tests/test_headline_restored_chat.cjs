'use strict';
// Regression: only an exact command can rescue a restored ChatGPT tab.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const receiver=fs.readFileSync(path.join(__dirname,'..','TTiTTularesWebImages.cjs'),'utf8');
const rescue=fs.readFileSync(path.join(__dirname,'..','Recuperar-TTImages-Noticias-Chat-Existente-Safe.ps1'),'utf8');
test('Recovered conversations can have a different Chrome target ID',()=>{
 assert.match(receiver,/const chatPages=pages\.filter\(x=>x\.type==='page'&&x\.webSocketDebuggerUrl&&chatURL\(x\.url\)\)/);
 assert.match(receiver,/new Set\(\[\.\.\.preferred,\.\.\.chatPages\.slice\(0,20\)\.map/);
 assert.match(receiver,/cdp\.evaluate\(conversationProbe\(commandId,diagnostic\)\)/);
 assert.match(receiver,/if\(url&&url===chatURL\(own\.url\)\)/);
 assert.match(receiver,/no_chatgpt_conversation_tab/);
});
test('Manual rescue opens a new tab but never navigates another one',()=>{
 assert.match(rescue,/\[switch\]\$Apply/);
 assert.match(rescue,/\$r\.target_id -eq \$NewsId/);
 assert.match(rescue,/\$r\.status -eq 'waiting'/);
 assert.match(rescue,/Invoke-RestMethod -Method Put -Uri \(\$base\+'\/json\/new\?'\+\$encoded\)/);
 assert.match(rescue,/--once-id \$NewsId/);
 assert.doesNotMatch(rescue,/Target\.closeTarget|Page\.navigate|Stop-Process|Restart-Service|Start-Process/);
});
