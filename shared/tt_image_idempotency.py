"""Conservative, side-effect-aware image request gate for TTActualidad.

The durable source of truth is each project's control-branch jobs/<id>.json.
An ERROR after PC pickup is NOT evidence that ChatGPT Images did not run.
The Git ref fast-forward push (not a rebase) is the cross-run CAS.
No Chrome, listener, or new resident service is involved.
"""
from __future__ import annotations

TERMINAL = {"DONE", "LAUNCHED", "READY", "COMPLETED"}
ACTIVE = {"REQUESTED", "RUNNING", "GENERATING", "PERSISTING", "PICKED_UP", "UNCERTAIN"}
FAILED = {"ERROR", "FAILED", "CANCELLED"}
SAFE_PRE_SUBMIT_PHASES = {"pc_preflight_failed", "pc_pickup_failed", "queued_failed"}


def _revision(job: dict, fallback: int) -> int:
    try:
        return int(job["revision"]) if job.get("revision") is not None else fallback
    except (TypeError, ValueError):
        # An invalid existing record must not be silently replaced.
        return fallback + 1



def is_new_editorial_episode(old: dict | None, revision: int, candidate: dict) -> bool:
    """Recognize genuinely different episodes when a trend ID/revision is reused.

    TTendencias can auto-queue the same trend weeks later as revision zero.
    Its old image job may be LAUNCHED/ERROR: blocking that *new* story is wrong,
    but replaying a prompt for the *same* story would be unsafe. Require both
    a strictly newer explained_at and different factual text from the job's
    durable context snapshot. Missing evidence fails closed.
    """
    from datetime import datetime, timezone

    if not old:
        return False
    # New automated episodes may restart at r0 after a prior event reached r1
    # or r2. Compare immutable editorial timestamps and text, not counters.
    context = old.get("context_snapshot")
    if not isinstance(context, dict):
        return False
    previous_text = str(context.get("explanation") or "").strip()
    current_text = str(candidate.get("explanation") or "").strip()
    previous_at = context.get("explained_at")
    current_at = candidate.get("explained_at")
    if not (previous_text and current_text and previous_text != current_text
            and previous_at and current_at):
        return False
    try:
        def moment(value):
            parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                return None
            return parsed.astimezone(timezone.utc)
        old_dt, new_dt = moment(previous_at), moment(current_at)
        return bool(old_dt and new_dt and new_dt > old_dt)
    except (ValueError, TypeError):
        return False

def may_enqueue_image_job(
    old: dict | None,
    revision: int,
    *,
    manual_retry_version: int = 0,
    max_automatic_safe_retries: int = 3,
) -> bool:
    """Permit a new claim only for a new revision or *provably unsubmitted* failure.

    A missing ACK, timeout, unverified send, or visible generating indicator is
    an indeterminate side effect and MUST NEVER schedule a duplicate prompt.
    Manual retry tokens cannot override an active or launched job.
    """
    if not old:
        return True
    old_revision = _revision(old, revision)
    if old_revision > revision:
        return False  # A stale editorial snapshot cannot replace a newer image.
    if old_revision < revision:
        return True   # Express editorial rework is a new identity.

    status = str(old.get("status") or "").upper()
    if old.get("pc_launched_at") or old.get("pc_submitted_at"):
        return False
    if status in TERMINAL or status in ACTIVE:
        return False
    # The server explicitly cancelled BEFORE opening ChatGPT Images because a
    # stale historical archive was mistaken for the current episode. Unlike a
    # CDP timeout/ERROR, this outcome proves that no prompt was submitted.
    if (status == "CANCELLED" and str(old.get("phase") or "").lower() == "stale_target"
            and str(old.get("message") or "").startswith("Cancelado antes de abrir chat:")
            and not old.get("pc_picked_up_at") and not old.get("pc_submitted_at")):
        attempts = int(old.get("auto_repair_attempt") or 0)
        consumed = int(old.get("manual_retry_version") or 0)
        return attempts < max_automatic_safe_retries or int(manual_retry_version or 0) > consumed
    if status not in FAILED:
        return False  # Unknown phases fail closed.

    # TTendencias' initial openFreshDedicatedConversation boundary is before
    # prompt injection. v31 labels it explicitly; the two legacy diagnostics
    # below also originate exclusively in that initial composer/tab preflight.
    # Do not classify arbitrary Runtime.evaluate timeouts after sending as safe.
    message = str(old.get("message") or "").strip()
    trends_preflight = (
        old.get("project") == "ttendencias"
        and old.get("delivery_mode") == "launch_only"
        and str(old.get("phase") or "").lower() == "pc_launch_failed"
        and old.get("pc_picked_up_at")
        and not any(old.get(key) for key in (
            "pc_submitted_at", "pc_image_submitted_at", "image_generated_at", "upload_sha256"))
        and (message.startswith("TTENDENCIAS_PRE_SUBMIT_FAILED ")
             or message == "El target dedicado sigue abierto; no se creará otra pestaña"
             or message.startswith("La pestaña dedicada no mostró compositor en 60000 ms; "))
    )
    if trends_preflight:
        return int(old.get("auto_repair_attempt") or 0) < max_automatic_safe_retries

    # One precisely classified PC failure is provably pre-submission:
    # ChatGPT Images had no usable composer, so the bridge could not type the
    # prompt. This is NOT a generic CDP/timeout error. Never replay a job
    # with any launch/submission marker or evidence that generation began.
    if (status == "ERROR"
            and str(old.get("phase") or "").lower() == "pc_launch_failed"
            and str(old.get("message") or "").strip() in {
                "No hay compositor visible utilizable para fallback found=1",
                # Known missing helper in the TTendencias fixed-tab recovery:
                # called exclusively from openFreshDedicatedConversation()
                # BEFORE the prompt can be typed or submitted.
                "closeFixedTargetById is not defined",
            }
            and old.get("pc_picked_up_at")
            and not any(old.get(key) for key in (
                "pc_launched_at", "pc_submitted_at", "pc_image_submitted_at",
                "image_generated_at"))):
        consumed = int(old.get("manual_retry_version") or 0)
        return (int(old.get("auto_repair_attempt") or 0) < max_automatic_safe_retries
                or int(manual_retry_version or 0) > consumed)

    # A PC ERROR (including "No hubo evidencia suficiente" and CDP errors)
    # must not be equated with failure before image generation.
    if old.get("retry_safe_before_submit") is not True:
        return False
    if str(old.get("phase") or "").lower() not in SAFE_PRE_SUBMIT_PHASES:
        return False
    evidence = str(old.get("message") or "").lower().replace(" ", "")
    if any(s in evidence for s in ('"generating":true', '"submitted":true',
                                   "promptenviado", "imagegenenprogreso")):
        return False
    consumed = int(old.get("manual_retry_version") or 0)
    manual_retry = int(manual_retry_version or 0) > consumed
    attempts = int(old.get("auto_repair_attempt") or 0)
    return manual_retry or attempts < max_automatic_safe_retries
