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
    if status not in FAILED:
        return False  # Unknown phases fail closed.

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
