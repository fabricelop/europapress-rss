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
  assert.match(installer,/0ebc716790e10402fb8ca10b72bb74d982bda551/);
  assert.match(installer,/5726f9aa5c543e4bfffd6b5a2451db2215c8a0f71c52d4f8142de65d1c5b2d0f/);
  assert.match(installer,/d311fb31975a96c71aab9b14239089d5f55b75d4f2fe23ae55d1525023ac5ca1/);
  assert.match(installer,/RECEIVER_DOWNLOAD_SHA_INVALID/);
  assert.match(installer,/\[IO\.File\]::Replace/);
  assert.match(installer,/RECEIVER_DEPENDENCY_UNKNOWN/);
  assert.match(installer,/RECEIVER_APPROVAL_PAUSE_MISSING/);
  assert.doesNotMatch(installer,/(?:Disable-ScheduledTask|Stop-Process|Stop-ScheduledTask|taskkill|Restart-Computer)/i);
});
test("target receiver remains scope based with a bounded number of new Chrome tabs",()=>{
  assert.doesNotMatch(receiver,/const NEWS_CUTOFF=/);
  assert.match(receiver,/listas_and_current_or_at_creation_top30_images_max_48h/);
  assert.match(receiver,/MAX_ORIGINAL_CHECKS_PER_CYCLE=16/);
  assert.match(receiver,/MAX_IMAGE_AGE_MS=48\*60\*60\*1000/);
  assert.match(installer,/listas_and_current_or_at_creation_top30_images_max_48h/);
  assert.match(receiver,/MAX_NEW_RELAY_TABS_PER_CYCLE=1/);
  assert.match(receiver,/RELAY_CLEANUP_UNCONFIRMED/);
});
