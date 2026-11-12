'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const src=fs.readFileSync(path.join(__dirname,'..','TT-LocalWatchdog.ps1'),'utf8');
const guard=src.slice(src.indexOf('function EnsureEditorialGuardCapacity{'),src.indexOf('function EnsureEditorialScheduledWake{'));
const wake=src.slice(src.indexOf('function EnsureEditorialScheduledWake{'),src.indexOf('function EnsureScheduledTasks{'));
test('obsolete 18-tab guard is repaired atomically and only when no runner is active',()=>{
 assert.match(guard,/Test-EditorialRunnerBusy/);
 assert.match(guard,/TOO_MANY_TABS_HARD_CAP/);
 assert.match(guard,/pre-tabcap-20261112\.bak/);
 assert.match(guard,/--check \$tmp/);
 assert.match(guard,/Move-Item -LiteralPath \$tmp -Destination \$p -Force/);
 assert.doesNotMatch(guard,/Stop-Process|\/json\/close|Remove-Item.*Chrome/);
});
test('watchdog checks BOTH authoritative queues, never starts two jobs together',()=>{
 assert.match(wake,/ttittulares\/editorial-queue\.json/);
 assert.match(wake,/trends\/editorial-queue\.json/);
 assert.match(wake,/TTiTTulares Local/);
 assert.match(wake,/TTendencias Local/);
 assert.match(wake,/Test-ChatOperationBusy/);
 assert.match(wake,/Test-EditorialRunnerBusy/);
 assert.match(wake,/\.TotalMinutes -lt 20/);
 assert.match(wake,/Start-ScheduledTask -TaskName \$task\.TaskName/);
 assert.match(wake,/break # Never start both editors concurrently/);
 assert.doesNotMatch(wake,/Stop-Process|Invoke-RestMethod\s+-Method Post|ImageGen|git push/);
});
test('watchdog calls both new checks without disrupting image recovery',()=>{
 assert.match(src,/EnsureEditorialGuardCapacity\s+EnsureEditorialScheduledWake\s+EnsureInternetRecovery/);
 assert.match(src,/EnsureTTitRequestedImageRecovery/);
});
