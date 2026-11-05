"""Prevent a returning Top30 label from silently creating a second editorial card.

The ranking is a signal to INVESTIGATE, not evidence of a new news episode.
Only explicit editorial new-episode requests can bypass a previously treated
term. The durable ledgers are consulted even when the transient explained
snapshot is compacted or the latest request status is 'inactive'.
"""
from __future__ import annotations

import unicodedata


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
