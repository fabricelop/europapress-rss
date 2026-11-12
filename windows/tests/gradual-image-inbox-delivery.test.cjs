'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const script=fs.readFileSync(path.join(__dirname,'../Instalar-Entrega-IA-Gradual-TT.ps1'),'utf8');
const receiver=fs.readFileSync(path.join(__dirname,'../TTImageApprovalReceiver.cjs'),'utf8');
test('dry-run default; no task changed without an explicit Apply',()=>{
 assert.match(script,/param\(\[switch\]\$Apply\)/);
 assert.match(script,/if\(-not \$Apply\)\s*\{/);
 assert.match(script,/Note 'DRY_RUN'/);
 assert.match(script,/OLD_RECEIVER_MUST_REMAIN_DISABLED/);
 assert.match(script,/TASK_NAME_CONFLICT/);
});
test('safe 15-minute cadence, one instance, single existing receiver',()=>{
 assert.match(script,/TT Actualidad - Entrega IA gradual/);
 assert.match(script,/RepetitionInterval \(New-TimeSpan -Minutes 15\)/);
 assert.match(script,/MultipleInstances IgnoreNew/);
 assert.match(script,/ExecutionTimeLimit \(New-TimeSpan -Minutes 12\)/);
 assert.match(script,/Start-ScheduledTask -TaskName \$newTaskName/);
 assert.match(script,/\& \$node \$receiver \*>> \$log/);
 assert.doesNotMatch(script,/Stop-Process|taskkill|Restart-Computer|Restart-Service|Stop-ScheduledTask/i);
});
test('manual approval and exact episode are still enforced end to end',()=>{
 assert.match(script,/manual_approval_required/);
 assert.match(script,/MAX_NEW_RELAY_TABS_PER_CYCLE=1/);
 assert.match(script,/MAX_RELAY_PAGE_TARGETS=6/);
 assert.match(receiver,/function metadata\(task,job\)/);
 assert.match(receiver,/const episode=m=>sha/);
 assert.match(receiver,/m\.episodeFingerprint=episode\(m\)/);
 assert.match(receiver,/meta=\{\.\.\.meta,rasterSHA256:sha\(bytes\)\}/);
 assert.match(receiver,/receipt\.state==='rejected'/);
 assert.match(script,/NO_APPROVAL_NO_PUBLICATION/);
});
test('only known paused consumers are accepted and upload is private',()=>{
 assert.match(script,/RequireMarkers \$receiver/);
 assert.match(script,/TTendenciasWebImages.cjs/);
 assert.match(script,/TTiTTularesWebImages.cjs/);
 assert.match(receiver,/\/api\/image-inbox\/v1\/images\/ingest/);
 assert.doesNotMatch(script,/api\.telegram\.org|buffer\.com|api\/image_upload|gh\s+api/);
});

test('installer preflight matches the deployed exact-image receiver, not retired Top30 logic',()=>{
 const start=script.indexOf('RequireMarkers $receiver @(');
 const end=script.indexOf(") 'RECEIVER'",start);
 assert(start>=0&&end>start);
 const block=script.slice(start,end);
 const required=[...block.matchAll(/^\s*'([^']+)'\s*,?\s*$/gm)].map(x=>x[1]);
 assert(required.includes('function provesExactNewImageJob(task,job)'));
 assert(!required.includes('function provesTop30AtImageCreation'));
 for(const mark of required)assert(receiver.includes(mark),'receiver missing marker '+mark);
 assert.match(script,/OLD_RECEIVER_MUST_REMAIN_DISABLED/);
 assert.match(script,/NO_APPROVAL_NO_PUBLICATION/);
});

test('absent legacy receiver is safe; enabled legacy receiver blocks a parallel schedule',()=>{
 assert.match(script,/\$old=Get-ScheduledTask -TaskName \$oldTaskName -ErrorAction SilentlyContinue/);
 assert.match(script,/if\(\$old -and \$old\.State -ne 'Disabled'\)/);
 assert.match(script,/\$oldAfter=Get-ScheduledTask -TaskName \$oldTaskName -ErrorAction SilentlyContinue/);
 assert.match(script,/if\(\$oldAfter -and \$oldAfter\.State -ne 'Disabled'\)/);
 assert.match(script,/Disable-ScheduledTask -TaskName \$newTaskName/);
 assert.doesNotMatch(script,/Enable-ScheduledTask -TaskName \$oldTaskName/);
});
