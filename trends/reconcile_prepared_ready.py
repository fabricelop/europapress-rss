"""Reconcile fully-written TTendencias READY documents into the editorial Listas ledger.

Image relay is intentionally independent. Do not let a missing image or a
legacy Telegram delivery prevent a verified text-only Listas card.
"""
from __future__ import annotations

from datetime import datetime


TERMINAL = {"deleted", "dismissed", "published", "removed", "delete_pending", "delete_failed"}


def _time(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def reconcile_prepared_ready(requests_doc, prepared_doc, explained_doc, now):
    """Return number of newly completed READY rows; mutate passed dicts in place.

    Match by exact (id, revision) and a source-generated timestamp no earlier
    than the request. Respect every terminal decision or later request.
    Existing explained ledger records are authoritative and never overwritten.
    """
    requests = requests_doc.get("requests") or []
    prepared = prepared_doc.get("items") or []
    explained = explained_doc.setdefault("items", [])
    by_key = {
        (str(x.get("id") or ""), int(x.get("revision") or 0)): x
        for x in prepared if isinstance(x, dict) and x.get("id")
    }
    completed = 0
    for req in requests:
        if req.get("anticipation_request"):
            continue
        if str(req.get("status") or "").lower() != "ready":
            continue
        ident = str(req.get("id") or "")
        revision = int(req.get("revision") or 0)
        if not ident or revision < 0:
            continue
        item = by_key.get((ident, revision))
        if not item:
            continue
        if any(
            str(x.get("id") or "") == ident and
            int(x.get("revision") or 0) >= revision and
            str(x.get("status") or "").lower() in TERMINAL
            for x in explained
        ):
            continue
        if any(
            str(x.get("id") or "") == ident and
            int(x.get("revision") or 0) == revision
            for x in explained
        ):
            continue
        if any(
            str(x.get("id") or "") == ident and
            int(x.get("revision") or 0) > revision
            for x in requests
        ):
            continue
        produced_at = _time(item.get("generated_at"))
        requested_at = _time(req.get("requested_at"))
        if not produced_at or not requested_at or produced_at.tzinfo is None or requested_at.tzinfo is None:
            continue
        if (produced_at - requested_at).total_seconds() < -60:
            continue
        explanation = str(item.get("explanation") or (item.get("primary") or {}).get("text") or "").strip()
        closer = str(item.get("closer_text") or "").strip()
        if not explanation.startswith("TT#") or len(explanation) >= 280:
            continue
        if closer and (not closer.startswith("🌶️ ") or explanation.count(closer) != 1):
            continue

        leader = str(item.get("group_leader_id") or ident)
        if leader != ident:
            # Group members become explained through their leader, never
            # independently create duplicate editorial cards.
            continue
        entry = {
            "id": ident, "name": str(req.get("name") or item.get("trend_name") or ""),
            "revision": revision, "status": "explained",
            "explained_at": item.get("generated_at"), "explanation": explanation,
            "closer_text": closer, "rank": item.get("rank", req.get("rank")),
            "rank_at_explanation": item.get("rank", req.get("rank")),
            "category": item.get("category") or "Otros",
            "source": "editorial_prepared_reconciled",
            "editorial_engine": "chat-direct",
            "verification_sources": item.get("sources") or [],
            "news_disposition": item.get("news_disposition") or "ignored",
            "news_note": item.get("news_note") or "",
            "group_id": item.get("group_id") or "",
            "explanation_group_id": item.get("explanation_group_id") or item.get("group_id") or "",
            "group_title": item.get("group_title") or str(req.get("name") or ""),
            "group_leader_id": ident,
            "trend_names": item.get("trend_names") or [str(req.get("name") or "")],
            "grouped_member_revisions": item.get("grouped_member_revisions") or [
                {"id": ident, "revision": revision}
            ],
            "with_image": bool(item.get("with_image")),
            "image_pending": False,
            "image_strategy": item.get("image_strategy") or "ai_plus_fallback",
        }
        explained.append(entry)
        req.update({
            "status": "explained", "explained_at": item.get("generated_at"),
            "explanation": explanation, "closer_text": closer,
            "rank_at_explanation": entry["rank"],
            "source": entry["source"], "group_id": entry["group_id"],
            "explanation_group_id": entry["explanation_group_id"],
            "group_leader_id": ident, "trend_names": entry["trend_names"],
            "verification_sources": entry["verification_sources"],
            "news_disposition": entry["news_disposition"],
            "news_note": entry["news_note"], "reexplain": False,
            "rewrite_pending": False, "image_pending": False,
        })
        completed += 1
    if completed:
        explained_doc["updated_at"] = now
        requests_doc["updated_at"] = now
    return completed
