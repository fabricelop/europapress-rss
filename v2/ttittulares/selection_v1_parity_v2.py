"""V1's second editorial identity gate, adapted to V2's immutable authority.

Never rewrite old events, jobs, publications, or user decisions. This gate
prevents an *initial* editorial job for a fact already represented by a
persisted V2 editorial identity (including terminal decisions). Candidate
grouping and four independent families remain the responsibility of radar.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import unicodedata
from .identity_v2 import normalize, same_fact, title_match_value, tokens

BLOCK_WINDOW = timedelta(hours=48)
GENERIC = ("ultima hora", "en directo", "noticias de hoy", "actualidad politica")


def _when(value):
    if not isinstance(value, str):
        return None
    try:
        time = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return time.astimezone(timezone.utc) if time.tzinfo is not None else None


def same_editorial_fact(new_title, old_title):
    """High-confidence V1-like second barrier, avoiding loosely related news."""
    a, b = normalize(new_title), normalize(old_title)
    raw_a = "".join(c for c in unicodedata.normalize("NFKD", str(new_title).casefold())
                    if not unicodedata.combining(c))
    raw_b = "".join(c for c in unicodedata.normalize("NFKD", str(old_title).casefold())
                    if not unicodedata.combining(c))
    if not a or not b or any(raw_a.startswith(x) or raw_b.startswith(x) for x in GENERIC):
        return False
    if a == b:
        return True
    # Conservative title-variant guard. Do not merge contrary developments or
    # stories with differing numbers merely because their named actors match.
    nums = lambda text: {x for x in text.split() if x.isdigit()}
    if nums(a) != nums(b):
        return False
    ta, tb = tokens(new_title), tokens(old_title)
    if min(len(ta), len(tb)) < 5 or len(ta & tb) < 5:
        return False
    # The underlying V2 same_fact has already ported V1's semantic and
    # action-stage checks. Require a high overlap for blocking a NEW identity.
    return same_fact({"canonical_title": new_title}, {"canonical_title": old_title}) and (
        title_match_value(new_title, old_title) >= 0.78
    )


def existing_story(candidate, indexed_items, *, now):
    """Return the prior editorial identity or None; never block a material update."""
    if int(candidate.get("revision", 1)) != 1:
        return None
    title = candidate.get("canonical_title", "")
    if not title or now.tzinfo is None:
        return None
    candidate_first = _when(candidate.get("first_seen_at")) or now
    for old_id, item in indexed_items.items():
        if old_id == candidate.get("event_id"):
            continue
        # Radar-only MONITORING candidates have not been editorially
        # selected. They must never block a newly verified four-family story.
        if item.get("editorial_created") is not True and not item.get("revision_refs"):
            continue
        first = _when(item.get("first_seen_at"))
        if first is None or abs(candidate_first - first) > BLOCK_WINDOW:
            continue
        old_title = item.get("canonical_title", "")
        variants = [old_title] + list(item.get("aliases") or [])[:8]
        if any(same_editorial_fact(title, prior) for prior in variants):
            return old_id
    return None
