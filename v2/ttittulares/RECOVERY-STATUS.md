# News V2: recovery checkpoint after master v312

Updated 16 November 2026, after confirmed original-response recovery.
The master remains libfile_c244fcbdb29c8191a1d37f82a7ba3aa5, version 312.
This operational continuation note must be reconciled into that same document.

## Original Alcaraz pilot recovered and verified

Job ttn2-0e0e7c7ebd494a7a753590d9-r1-editorial is now ready, phase done,
with no lease or problem. Original command: news-bfc6017515a34ca09d010afdd74a1d96.
Original local journal: 0e90ad3bc3f84f79ab222b762a1a7d70.
The user supplied the existing original chat response and local journal proof:
sent=true, captured=false, cleanup_verified=true, original error
NEWS_SUBMISSION_UNCONFIRMED_NO_RESEND. The response was recovered without
opening ChatGPT, sending another message, regenerating, or enabling publication.

Code commit aa69a0482abd16c7dd821e13e09addce9fc1d6d8 adds a fenced
recover_capture operation and six recovery tests. Exact command, original journal,
cleanup proof, answer hash, global three-slot capacity, immutable READY and
idempotent replay are enforced. Recovery run 43960209171 passed 197 tests,
validated the supplied reply, and persisted/read back the real record successfully.
The full editorial check run 43960209128 also succeeded on Linux and Windows,
with installer checks and the real read-only FIFO preview.
Record origin commit: 786dc47f91e0a077d7361703386e0392f760b9b2.
Final READY transition commit: 15634eef945ab27374c2f9a10858d742645d82d4.
Record: v2/ttittulares/records/ttn2-0e0e7c7ebd494a7a753590d9/r1.json
Tweet length: 243 characters. Queue verified: 61 pending, 0 active, 1 ready.
The original send_intent prepared_at remains 2026-11-16T20:51:18Z;
submitted/captured audit times record recovery observation, not a new send.

## Consumer robustness and remaining local handoff

Commit 78714553e4f621bcb403919348b5546c8a285fc2 previously passed 191 tests on
Linux and Windows, installer syntax checks and read-only real FIFO preview
(run 43956595706). It checks exact ID/revision/command across owned browser pages,
uses a bounded localized user/assistant transcript fallback when role DOM is absent,
rejects conflicting matching chats, and never sends in its confirmation loop.
Future ambiguous attempts retain their private profile and local page diagnostics
after their own processes close. Private URLs are not written to GitHub.
No local installation of this confirmation fix is confirmed yet.

Next: run the updated Install-News-Editorial-V2.ps1 on Windows. It downloads a
hash-verified fixed branch snapshot, runs checks, and pilots the next pending story.
It enables the three-worker scheduler only after the pilot validates and its own
Chrome cleanup is confirmed. Do not reset or requeue the recovered Alcaraz job.

## Image incident reporting and V1 retirement confirmed

The I button is deployed (Cloudflare fc2a7992-f8e1-4cff-bbf8-62f1ff786b02).
The user confirmed Update-V2-ImageIncidents.ps1 installed reporting for NEW jobs:
TT_V2_IMAGE_INCIDENT_REPORTING_COMMIT=577734d2bccc3eb2ac58e2c0b61b70c469a2c1a0
Backup: C:\Users\I052279\AppData\Local\TTActualidadV2\Backup-Image-Incidents-20261116-221559-346
Chrome tasks and running jobs were unchanged. No live new image failure has yet
been independently observed. News image generation and persistent Archive remain
future work.

V1 watchdog selective retirement is installed and reloaded (PID 40148),
backup C:\TTiTTulares\Backup-Watchdog-V1-20261116-213443-189.
Shared Chrome 9223, supervisor and SeLoRecordamos remain intentionally available.
Do not stop their Chrome merely because it remains open.

Radar freshness remains unverified: latest observed capture was
2026-11-16T19:11:32Z. A configured timer alone does not prove current ingestion.

## Master document limitation

The execution runtime is unavailable. Repository changes and checks use GitHub
Actions. The native master document cannot currently be replaced because its
replacement API requires a real local file. Do not claim a new master version.
Reconcile this checkpoint into the same master with version checking when file
execution becomes available.
