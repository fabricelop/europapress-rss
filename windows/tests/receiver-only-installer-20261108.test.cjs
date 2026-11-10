"use strict";
const test=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");
const path=require("node:path");
const installer=fs.readFileSync(path.join(__dirname,"../Actualizar-Solo-Receptor-Imagenes-TT.ps1"),"utf8");
const receiver=fs.readFileSync(path.join(__dirname,"../TTImageApprovalReceiver.cjs"),"utf8");

test("receiver-only installer accepts the real 7-Nov installed SHA, but no unknown version",()=>{
  assert.match(installer,/340c1d28024d532310c51648794331a541bf93299e4db7a2365d6095b94129f1/);
  assert.match(installer,/RECEIVER_UNKNOWN_SHA/);
  assert.match(installer,/Get-CanonicalSourceHash \$live/);
  assert.match(installer,/\$accepted -notcontains \$before/);
});
test("installer downloads exactly the audited receiver revision, verifies bytes, preserves rollback",()=>{
  assert.match(installer,/96001f9053dfc674dd69c1a60535f9cde42744a8/);
  assert.match(installer,/cbef9c4091c8328aa14e6fde7d662ce05b2aa7505bb159396739a7b12f0abef4/);
  assert.match(installer,/d311fb31975a96c71aab9b14239089d5f55b75d4f2fe23ae55d1525023ac5ca1/);
  assert.match(installer,/RECEIVER_DOWNLOAD_SHA_INVALID/);
  assert.match(installer,/\[IO\.File\]::Replace/);
  assert.match(installer,/RECEIVER_DEPENDENCY_UNKNOWN/);
  assert.match(installer,/RECEIVER_APPROVAL_PAUSE_MISSING/);
  assert.doesNotMatch(installer,/(?:Disable-ScheduledTask|Stop-Process|Stop-ScheduledTask|taskkill|Restart-Computer)/i);
});
test("target receiver admits new jobs without editorial filters, bounded Chrome tabs",()=>{
  assert.doesNotMatch(receiver,/const NEWS_CUTOFF=/);
  assert.match(receiver,/new_image_jobs_only_no_listas_or_top30/);
  assert.match(receiver,/MAX_ORIGINAL_CHECKS_PER_CYCLE=16/);
  assert.match(receiver,/MAX_IMAGE_AGE_MS=48\*60\*60\*1000/);
  assert.match(installer,/new_image_jobs_only_no_listas_or_top30/);
  assert.match(receiver,/MAX_NEW_RELAY_TABS_PER_CYCLE=1/);
  assert.match(receiver,/RELAY_CLEANUP_UNCONFIRMED/);
});
