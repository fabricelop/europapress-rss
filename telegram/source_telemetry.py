"""Rolling per-source statistics for the TTiTTulares radar; editorial logic unchanged.

"Last news" is the last *new headline retrieved by the radar*, not feed poll
time or a guessed publication date. The 24 h count deduplicates headlines per
source across runs. This telemetry lives inside telegram/events.json, which both
normal radar workflows already persist atomically.
"""
from __future__ import annotations

import hashlib
import re
import unicodedata
from datetime import datetime, timedelta, timezone
from source_publication import parse_publication_date


def timestamp(value):
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return dt.astimezone(timezone.utc) if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError, OverflowError):
        return None


def utc_iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def article_key(title):
    title = unicodedata.normalize("NFKD", str(title or "")).casefold()
    title = "".join(c for c in title if not unicodedata.combining(c))
    title = " ".join(re.findall(r"[a-z0-9]+", title))
    return hashlib.sha1(title.encode("utf-8")).hexdigest() if title else ""


def update_source_telemetry(rows, statuses, previous, events, now):
    """Mutates source-status rows only, returns a new persisted telemetry object.

    first run: seeds known historical appearances so they are not counted as
    brand new merely because statistics were installed today.
    """
    now = now.astimezone(timezone.utc)
    metrics = previous if isinstance(previous, dict) and previous.get("version") == 1 else {}
    state = {"version": 1, "started_at": metrics.get("started_at") or utc_iso(now),
             "by_source": metrics.get("by_source") or {}}
    cutoff = now - timedelta(hours=24)
    keep = now - timedelta(days=7)
    known = state["by_source"]
    new_sources = {str(s.get("source") or "") for s in statuses if s.get("source")}
    for source in new_sources:
        record = known.get(source)
        if not isinstance(record, dict):
            record = {}
            known[source] = record
        seen = record.get("seen")
        if not isinstance(seen, dict):
            seen = {}
            record["seen"] = seen
        # The last observation never resets on an empty/error cycle.
        if "last_article_at" not in record:
            record["last_article_at"] = None
            record["last_article_title"] = None
        # Separate clocks: first retrieval != the publisher's publication date.
        record.setdefault("last_published_at", None)
        record.setdefault("last_published_title", None)
        record.setdefault("publication_date_source", None)

    if not metrics:
        # Preserve the first-seen time of headlines already in the rolling
        # editorial radar; "last_seen" refreshes are intentionally ignored.
        for event in events or []:
            for appearance in event.get("appearances") or []:
                source = str(appearance.get("source") or "")
                title = str(appearance.get("title") or "")
                at = timestamp(appearance.get("first_seen"))
                key = article_key(title)
                if source not in new_sources or not key or not at or at < keep or at > now:
                    continue
                record = known[source]
                old = timestamp(record["seen"].get(key))
                if old is None or at < old:
                    record["seen"][key] = utc_iso(at)
                latest = timestamp(record.get("last_article_at"))
                if latest is None or at > latest:
                    record["last_article_at"] = utc_iso(at)
                    record["last_article_title"] = title

    # Only a genuinely unseen, distinct headline advances the "last news" time.
    # The same article on a repeatedly polled page/RSS does not reset the clock.
    for row in rows or []:
        source = str(row.get("source") or "")
        title = str(row.get("title") or "")
        key = article_key(title)
        if source not in new_sources or not key:
            continue
        record = known[source]
        # Trust a timezone-aware date directly from the publisher's RSS or
        # original article metadata. Never infer publication from polling.
        published = parse_publication_date(row.get("published_at"), now)
        prev = timestamp(record.get("last_published_at"))
        if published and (prev is None or published > prev):
            record["last_published_at"] = utc_iso(published)
            record["last_published_title"] = title
            record["publication_date_source"] = row.get("publication_date_source") or "publisher"
        if key not in record["seen"]:
            record["seen"][key] = utc_iso(now)
            record["last_article_at"] = utc_iso(now)
            record["last_article_title"] = title

    # A separately checked official publisher feed can supply a verified
    # publication timestamp even when editorial headlines use Google News.
    # Do not substitute the latter's syndication timestamp.
    for status in statuses:
        source = str(status.get("source") or "")
        record = known.get(source)
        if not record:
            continue
        published = parse_publication_date(status.get("verified_publisher_published_at"), now)
        old = timestamp(record.get("last_published_at"))
        if published and (old is None or published > old):
            record["last_published_at"] = utc_iso(published)
            record["last_published_title"] = status.get("verified_publisher_title") or ""
            record["publication_date_source"] = (
                status.get("verified_publisher_date_source") or "publisher_feed"
            )

    # Keep seven days of fingerprints so a static homepage does not produce a
    # phantom "new article" every 24 h, while counting only the last 24 hours.
    for status in statuses:
        source = str(status.get("source") or "")
        record = known.get(source) or {}
        seen = record.get("seen") or {}
        kept = {k: v for k, v in seen.items()
                if (t := timestamp(v)) is not None and keep <= t <= now}
        record["seen"] = kept
        status["articles_24h"] = sum(1 for value in kept.values()
                                     if (t := timestamp(value)) is not None and t >= cutoff)
        status["last_article_at"] = record.get("last_article_at")
        status["last_article_title"] = record.get("last_article_title")
        status["last_published_at"] = record.get("last_published_at")
        status["last_published_title"] = record.get("last_published_title")
        status["publication_date_source"] = record.get("publication_date_source")
        status["articles_24h_window_started_at"] = state["started_at"]

    # Sources no longer configured must not accumulate indefinitely.
    state["by_source"] = {name: known[name] for name in sorted(new_sources)}
    return state


def selftest():
    t = datetime(2026, 9, 29, 20, tzinfo=timezone.utc)
    row = {"source": "Europa Press", "title": "Noticia A", "url": "https://example.com/a"}
    statuses = [{"source": "Europa Press", "ok": True, "items": 1},
                {"source": "RTVE", "ok": False, "items": 0}]
    state = update_source_telemetry([row, row], statuses, {}, [], t)
    assert statuses[0]["articles_24h"] == 1 and statuses[1]["articles_24h"] == 0
    last = statuses[0]["last_article_at"]
    next_status = [{"source": "Europa Press", "ok": True},
                   {"source": "RTVE", "ok": False}]
    state = update_source_telemetry([row], next_status, state, [], t + timedelta(hours=13))
    assert next_status[0]["articles_24h"] == 1
    assert next_status[0]["last_article_at"] == last, "Polling is NOT new news"
    assert next_status[1]["articles_24h"] == 0 and next_status[1]["last_article_at"] is None
    second = {"source": "Europa Press", "title": "Noticia B"}
    state = update_source_telemetry([row, second], next_status, state, [], t + timedelta(hours=23))
    assert next_status[0]["articles_24h"] == 2
    assert next_status[0]["last_article_at"] == utc_iso(t + timedelta(hours=23))
    state = update_source_telemetry([row, second], next_status, state, [], t + timedelta(hours=25))
    assert next_status[0]["articles_24h"] == 1, "24 h sliding window"
    assert next_status[0]["last_article_at"] == utc_iso(t + timedelta(hours=23))
    # Bootstrap from the radar's genuine first-seen avoids counting an old
    # matching headline as just recovered on installation.
    old = [{"appearances": [{"source": "Europa Press", "title": "Noticia histórica",
                             "first_seen": utc_iso(t - timedelta(hours=17))}]}]
    status = [{"source": "Europa Press", "ok": True}]
    seeded = update_source_telemetry([{"source": "Europa Press", "title": "Noticia histórica"}],
                                     status, {}, old, t)
    assert status[0]["articles_24h"] == 1
    assert status[0]["last_article_at"] == utc_iso(t - timedelta(hours=17))
    assert article_key("MÁLAGA: una noticia") == article_key("Malaga una noticia")
    assert status[0]["last_published_at"] is None, "First discovery must not pretend to be publication"
    dated = [
        {"source": "Europa Press", "title": "Noticia publicada a las 14:20",
         "published_at": "2026-09-29T14:20:00Z", "publication_date_source": "publisher_feed"},
        {"source": "Europa Press", "title": "Reimpresión de una noticia antigua",
         "published_at": "2026-09-27T14:00:00Z", "publication_date_source": "publisher_feed"},
    ]
    state = update_source_telemetry(dated,status,seeded,[],t)
    assert status[0]["last_published_at"] == "2026-09-29T14:20:00Z"
    assert status[0]["publication_date_source"] == "publisher_feed"
    # Repeated retrieval later must NOT advance the publisher timestamp.
    update_source_telemetry(dated,status,state,[],t + timedelta(hours=2))
    assert status[0]["last_published_at"] == "2026-09-29T14:20:00Z"
    # A publisher date from the future cannot advance the clock.
    update_source_telemetry([{"source": "Europa Press", "title": "Futura",
      "published_at": "2026-09-30T17:00:00Z"}],status,state,[],t)
    assert status[0]["last_published_at"] == "2026-09-29T14:20:00Z"
    from_feed = [{"source": "COPE", "ok": True, "verified_publisher_published_at": "2026-09-29T19:38:00Z",
                  "verified_publisher_title": "Última noticia COPE",
                  "verified_publisher_date_source": "publisher_feed"}]
    update_source_telemetry([], from_feed, {}, [], t)
    assert from_feed[0]["last_published_at"] == "2026-09-29T19:38:00Z"
    assert from_feed[0]["last_published_title"] == "Última noticia COPE"
    print("TTITTULARES_SOURCE_TELEMETRY_SELFTEST_OK")


if __name__ == "__main__":
    selftest()
