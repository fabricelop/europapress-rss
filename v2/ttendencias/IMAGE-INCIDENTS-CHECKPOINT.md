# DRAFT checkpoint: image incident I control

User requested an I button in both Tendencias and Noticias that reveals the actual recorded image generation failure. Do not infer a failure from a missing image.

This branch is a checkpoint, NOT deployed. The UI has 98 passing Node tests (88 previous + 10 new image incident API/DOM regressions). Build/browser QA and deployment still need verification. The two Python image-worker/projection edits passed py_compile and 40 prior regression tests; dedicated new persistence/privacy/race tests remain to be added before activation. No Windows installation or real failed-image run was verified here.

Private endpoint GET /api/image-incidents?project=ttendencias-v2|ttittulares-v2&id=<exactID>&revision=<N> is authenticated and reads exact persisted revision/hash lazily. No per-card polling and no automatic image resend. UI only offers I when image_incident_available is explicitly projected. News has no active image worker yet: absent jobs mean no recorded incident, never a fabricated cause.

Tendencias durable metadata: row.image_incident={project,trend_id,revision,editorial_sha256,command_id,code,at,detail_safe,retry_mode}. command_id stays internal; the API returns only safe code/time/detail/retry-mode. Web projection hides an old incident when its revision/hash is stale, an exact image is saved, or a new attempt is active.

Sources: UI files refreshed at feature commit aaaf0e53be2aae44bdd7f6545569d0470ddedd95. Python edits based on 2e494d8c4033d24c3e954cf88dd7699f7495739b. Original blobs: image_worker_v2.py bb3478c3dfd661fc6085331fc7c787260da9b411; web_top30_v2.py 8d112090f89b1a86105ee831fca880bd8cf6c042. Before applying this checkpoint, reread current feature head and apply only this commit's explicit files/diffs without replacing other changes. Master memory is maintained separately by root.
