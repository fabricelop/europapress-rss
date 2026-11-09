"""Prevent a returning Top30 label from silently creating a second editorial card.

The ranking is a signal to INVESTIGATE, not evidence of a new news episode.
Only explicit editorial new-episode requests can bypass a previously treated
term. The durable ledgers are consulted even when the transient explained
snapshot is compacted or the latest request status is 'inactive'.
"""
from __future__ import annotations

import unicodedata
from datetime import datetime, timedelta


TREATED_STATUSES = frozenset({
    "explained", "published", "dismissed", "deleted", "removed",
    "delete_pending", "delete_failed",
})
EXPLICIT_EDITOR_SOURCES = frozenset({
    "github_pages_authorized_issue",
    "telegram_reexplain",
    "telegram_private_deeplink_native",
})


def key(value):
    text = unicodedata.normalize("NFD", str(value or ""))
    text = "".join(ch for ch in text if unicodedata.category(ch) != "Mn")
    return " ".join(text.casefold().split())


def treated_terms(requests, explained_items, deliveries=(), decisions=()):
    """Return normalized terms with a previously handled exact editorial ID.

    Identity/decision logs preserve evidence after an explained entry leaves
    current Listas or is compacted. A mere failed/problematic/PROCESSING request
    does NOT make a term treated.
    """
    resolved_ids = set()
    for item in tuple(deliveries) + tuple(decisions):
        if str(item.get("status") or "").lower() in TREATED_STATUSES:
            ident = item.get("event_id") or item.get("id")
            if ident:
                resolved_ids.add(str(ident))
    names = set()
    for item in explained_items:
        if not (item.get("explanation") or item.get("explained_at")):
            continue
        for name in [item.get("name"), *(item.get("trend_names") or [])]:
            if key(name):
                names.add(key(name))
    for item in requests:
        if item.get("red_review_request") or item.get("listas_grouping_request"):
            continue
        treated = (
            str(item.get("status") or "").lower() in TREATED_STATUSES
            or str(item.get("id") or "") in resolved_ids
            or bool(item.get("explained_at") and item.get("explanation"))
        )
        if treated:
            for name in [item.get("name"), *(item.get("trend_names") or [])]:
                if key(name):
                    names.add(key(name))
    return names


def editor_initiated(request):
    return bool(request and str(request.get("request_source") or "") in EXPLICIT_EDITOR_SOURCES
                and request.get("auto_queued") is not True)


def should_reopen_from_radar(name, history, request):
    """Never auto-create a second card solely because ranking reappeared."""
    return key(name) not in history or editor_initiated(request)

# A name is an entity/label, NOT an editorial episode ID. A fresh reentry
# or a 24h review can start fact checking again, never auto-publish an old event.
REENTRY_SEPARATION = timedelta(minutes=30)
REVIEW_COOLDOWN = timedelta(hours=24)
ACTIVE_RESEARCH = frozenset({"preparing", "update", "ready", "problematic"})


def _date(value):
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else None
    except (TypeError, ValueError):
        return None


def latest_episode_activity(request, historical_at=None):
    """Recent research/decision, not an arbitrary last-modified DB timestamp."""
    candidates = [historical_at] if historical_at else []
    if request:
        for field in ("review_completed_at", "reviewed_at", "requested_at",
                      "explained_at", "deleted_at", "published_at",
                      "dismissed_at", "removed_at", "decided_at"):
            d = _date(request.get(field))
            if d:
                candidates.append(d)
    return max(candidates) if candidates else None


def review_episode_token(name, radar_item, request, treated, now, historical_at=None):
    """Return a stable NEW research episode token or None.

    A term returning after an observed departure is a signal for investigation.
    If it has stayed ranked, a once-per-24h review may check for NEW facts.
    Neither a rank change nor a repeated label proves a new story, so callers
    must mark this as research-only and require distinct-event verification.
    """
    if key(name) not in treated:
        return None
    if not radar_item or not isinstance(now, datetime) or now.tzinfo is None:
        return None
    if request and str(request.get("status") or "").lower() in ACTIVE_RESEARCH:
        return None
    last = latest_episode_activity(request, historical_at)
    if not last or last.tzinfo is None:
        return None  # Never infer a new event from undated historical data.
    if last > now:
        return None
    entered = _date(radar_item.get("entered_top30_at"))
    if entered and entered <= now and entered >= last + REENTRY_SEPARATION:
        return "reentry:" + entered.isoformat(timespec="seconds")
    changed = _date(radar_item.get("last_changed_at"))
    if (now >= last + REVIEW_COOLDOWN and changed
            and last < changed <= now):
        # Require a genuinely observed fresh rank change; an unchanged
        # evergreen label plus elapsed time is not new-event evidence.
        # Even this signal only permits research, not another publication.
        return "daily-review:" + now.date().isoformat()
    return None
