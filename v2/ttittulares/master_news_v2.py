"""Read-only projection of verified radar stories into one news feed.

There is no editorial job, ChatGPT session, image or revision in this feed.
Only a radar event with four independent general-source families can enter.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from .selection_v1_parity_v2 import same_editorial_fact

RETENTION_DAYS = 30
MIN_FAMILIES = 4


def _when(raw):
    if not isinstance(raw, str):
        return None
    try:
        value = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return value.astimezone(timezone.utc) if value.tzinfo else None


def _sources(event):
    sources = {}
    for appearance in event.get("appearances") or []:
        if appearance.get("source_type") != "general":
            continue
        family = appearance.get("source_family")
        url = appearance.get("url")
        if not family or not isinstance(url, str) or not url.startswith("https://"):
            continue
        # One representative article per independent family.
        sources.setdefault(family, {
            "source": appearance.get("source"),
            "family": family,
            "title": appearance.get("title"),
            "url": url,
            "published_at": appearance.get("published_at"),
        })
    return list(sources.values())


def project_master_news(radar_state, *, now=None):
    """Return a deterministic, 30-day master list from proven radar events.

    Every scan recomputes this projection from the durable radar history.
    Publication/suppression controls belong to the serving DB, not this feed.
    """
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        raise ValueError("NOW_MUST_BE_TIMEZONE_AWARE")
    current = current.astimezone(timezone.utc)
    cutoff = current - timedelta(days=RETENTION_DAYS)
    items = radar_state.get("items") or {}
    if not isinstance(items, dict):
        raise ValueError("RADAR_ITEMS_MUST_BE_MAPPING")
    candidates = []
    for event_id, event in items.items():
        if event.get("status") != "eligible" or event.get("event_id") != event_id:
            continue
        verified_at = _when(event.get("eligible_at"))
        if not verified_at or not cutoff <= verified_at <= current:
            continue
        if int(event.get("source_count") or 0) < MIN_FAMILIES:
            continue
        # Radar already required corroborating, independent headlines when
        # setting 'eligible'. Re-checking combinations every poll is wasteful.
        sources = _sources(event)
        if len(sources) < MIN_FAMILIES:
            continue
        candidates.append({
            "id": event_id,
            "title": event.get("canonical_title") or "",
            "url": event.get("canonical_url") or sources[0]["url"],
            "first_seen_at": event.get("first_seen_at"),
            "verified_at": event.get("eligible_at"),
            "last_seen_at": event.get("last_seen_at"),
            "source_count": len(sources),
            "sources": sources,
        })
    # Keep the first verified version of the same fact as the stable identity.
    candidates.sort(key=lambda item: (item["verified_at"], item["id"]))
    selected = []
    for item in candidates:
        when = _when(item["verified_at"])
        duplicate = False
        for prior in reversed(selected):
            if when - _when(prior["verified_at"]) > timedelta(hours=48):
                break
            if (same_editorial_fact(item["title"], prior["title"])
                    or (item["url"] and item["url"] == prior["url"])):
                duplicate = True
                break
        if duplicate:
            continue
        selected.append(item)
    selected.reverse()
    return {
        "schema_version": 1,
        "project": "ttittulares-v2",
        "kind": "master_news",
        "observed_at": radar_state.get("observed_at"),
        "retention_days": RETENTION_DAYS,
        "minimum_independent_families": MIN_FAMILIES,
        "count": len(selected),
        "items": selected,
    }
