# News V2: recovery checkpoint after v312

16 November 2026. This is an operational continuation note, not a second master memory.
The master remains libfile_c244fcbdb29c8191a1d37f82a7ba3aa5, version312.

## Confirmed current state

The second local pilot started Chrome and recorded send_intent at 2026-11-16T20:51:18Z.
It could not verify the sent user turn. Job ttn2-0e0e7c7ebd494a7a753590d9-r1-editorial
is problematic, code NEWS_SUBMISSION_UNCONFIRMED_NO_RESEND, retry_mode recover_same_chat.
There are61 pending,0 active. submission_count0 does NOT prove that no prompt was sent:
its submission_state is uncertain. Do not reset/requeue this job or rerun its prompt.
The existing local journal ID is 0e90ad3bc3f84f79ab222b762a1a7d70.
The command ID is news-bfc6017515a34ca09d010afdd74a1d96.

The earlier browser code saved a chat URL only after successful confirmation, then
removed its job profile on close. Therefore the original ambiguous attempt may
lack a local URL. Recover the same conversation from the account history; inspect
its exact user command and response. Absence from a history search alone is not
proof that submission never occurred. Do not invent a cause without its DOM/log.

## Patch now under CI

Confirmation checks the exact ID/revision/command across owned browser pages,
uses bounded localized user/assistant transcript when role DOM is missing, and
rejects multiple different matching chats. It never sends in the confirmation loop.
Ambiguous future attempts retain their private profile and locally recorded page
URLs/counts, after closing and checking their processes. No private URLs go to GitHub.
Installer preparation may proceed, but another pilot is refused while a current
recover_same_chat incident remains unresolved. This is a future robustness patch,
not proof that it repairs or recovers the already closed conversation.

## Remaining local handoff

Find the existing chat by its unique command above using ChatGPT history search.
Inspect the existing response; do not click send, regenerate or retry the news job.
A recovery tool must fence the problematic job before persisting a validated
record. No such job reset or READY write has been performed by this patch.

The I button is deployed (Cloudflarefc2a7992-f8e1-4cff-bbf8-62f1ff786b02).
Update-V2-ImageIncidents.ps1 still needs local application for new image failures.
News image generation and persistent Archive remain future work.

The runtime for this chat is unavailable. Code and tests are saved through GitHub
and checked in Actions; the master Library file cannot be rewritten from a local
path in this environment. Reconcile this note into the same master when file
execution becomes available; preserve version checking and identity.
