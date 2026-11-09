"""Research a dated Top30 reentry when the last explanation is older than 24h.

A ranking reentry is a reason to INVESTIGATE, never evidence of a new
publishable news event. Historical editorial IDs, decisions, photos and posts
are preserved. Mere rank movement and evergreen presence are not reentries.
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

# An explicitly observed Top30 entry is distinct from a rank change.
# The age is measured from the most recent VERIFIED explanation, not from a
# deletion, publication or subsequent ranking movement.
REVIEW_COOLDOWN = timedelta(hours=24)
ACTIVE_RESEARCH = frozenset({"preparing", "update", "ready", "problematic"})


def _date(value):
    if isinstance(value, datetime):
        return value if value.tzinfo else None
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else None
    except (TypeError, ValueError):
        return None


def latest_episode_activity(request, historical_at=None):
    """Compatibility helper for historical UI/audit consumers."""
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
    """One stable research token for a verified return >24h after explanation.

    entered_top30_at must be a real radar entry after the last explanation:
    last_changed_at/ranking changes, age alone, and missing dates NEVER
    authorize new work. The caller must check fresh Top30 evidence and
    idempotently reject already handled tokens. A new fact remains necessary
    before creating any new public-facing editorial card or image.
    """
    if key(name) not in treated:
        return None
    if not radar_item or not isinstance(now, datetime) or now.tzinfo is None:
        return None
    if request and str(request.get("status") or "").lower() in ACTIVE_RESEARCH:
        return None
    last_explained = _date(historical_at) or _date((request or {}).get("explained_at"))
    if not last_explained or last_explained > now:
        return None  # No verified explanation timestamp => no auto-research.
    entered = _date(radar_item.get("entered_top30_at"))
    if (not entered or entered > now
            or entered <= last_explained + REVIEW_COOLDOWN):
        return None
    return "reentry:" + entered.isoformat(timespec="seconds")
