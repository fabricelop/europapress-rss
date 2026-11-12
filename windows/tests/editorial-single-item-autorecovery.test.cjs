'use strict';
const test=require('node:test'), assert=require('node:assert/strict');
const fs=require('node:fs'), path=require('node:path');
const root=path.resolve(__dirname,'../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const trends=read('windows/TTendenciasDedicatedListener.ps1');
const news=read('windows/TTiTTularesDedicatedListener.ps1');
const rescue=read('windows/Reparar-TT-Editorial-20261111.ps1');
const guard=read('shared/tt_editorial_run_guard.py');
test('trends prompt exposes guarded command marker and one exact review only',()=>{
 assert.match(trends,/TTENDENCIAS_EDITORIAL_JOB_V2 \$CommandId \| TT_ACTUALIDAD_MANUAL_EDITORIAL_V1/);
 assert.match(trends,/\$editorialMarker = "TTENDENCIAS_EDITORIAL_JOB_V2 \$commandId"/);
 assert.match(trends,/\$targetId=\[string\]\$Control\.target_id/);
 assert.match(trends,/No proceses otras tendencias ni hagas imágenes/);
});
test('news prompt targets one revision, no unbounded batch',()=>{
 assert.match(news,/function Build-EditorialMessage\(\[string\]\$CommandId,\$Control\)/);
 assert.match(news,/\$targetId=\[string\]\$Control\.target_id/);
 assert.match(news,/TTITTULARES_EDITORIAL_JOB_V2 \$CommandId/);
 assert.match(news,/\$messageSent = Launch-TTiTTulares \$commandId \$doc/);
 assert.match(news,/No proceses otras noticias en este encargo/);
 assert.doesNotMatch(news,/Procesa TODOS los PROCESSING activos/);
});
test('watchdog requests exact revision in BOTH projects and only advances after queue closure',()=>{
 assert.match(guard,/pending_rows=pending\(project\)/);
 assert.match(guard,/target_finished=\(bool\(target_id\)/);
 assert.match(guard,/old_target_finished=\(bool\(old_target\)/);
 assert.match(guard,/target_revision=int\(target\["revision"\]\)/);
});
test('bot-owned new Chrome tab never overwrites a draft; waits for verified composer',()=>{
 assert.match(rescue,/PROJECT_LANDING_HISTORY; NAVIGATE_BOT_OWNED_TAB_HOME/);
 assert.match(rescue,/s\.editorLength===0 && \(s\.users>0\|\|s\.assistants>0\)/);
 assert.match(rescue,/const focused=await c\.eval/);
 assert.match(rescue,/if\(!focused\)fail\('COMPOSER_NOT_FOCUSED/);
 assert.match(rescue,/let validated=false/);
 assert.match(rescue,/DRAFT_NOT_OURS: preserve unexpected draft/);
 assert.match(rescue,/if\(!validated\)fail\('DRAFT_NOT_VERIFIED/);
 assert.match(rescue,/AMBIGUOUS_PREVIOUS_SEND/);
});
