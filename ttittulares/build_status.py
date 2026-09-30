#!/usr/bin/env python3
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TT = ROOT / "ttittulares"
TG = ROOT / "telegram"

def load(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default

def save(path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

events_doc = load(TG / "events.json", {"events":[]})
processing = load(TG / "editorial-processing.json", {"items":[]})
prepared = load(TT / "prepared.json", {"items":[]})
trend_candidates_doc = load(TT / "trend-candidates.json", {"items":[]})
# TTendencias bridge: candidate stories stay separate until user promotes them.

event_map = {}
for event in events_doc.get("events", []):
    event_id = str(event.get("id") or "")
    if not event_id:
        continue
    event_map[event_id] = {
        "title": str(event.get("canonical_title") or event.get("title") or ""),
        "source_count": int(event.get("source_count") or 0),
        "outlet_count": int(event.get("outlet_count") or len(event.get("sources") or [])),
        "sources": list(event.get("sources") or []),
        "source_families": list(event.get("source_families") or []),
        "status": str(event.get("status") or ""),
        "last_seen": event.get("last_seen"),
        "revision": int(event.get("revision") or 1),
        "parent_event_id": event.get("parent_event_id"),
    }

processing_items = []
for item in processing.get("items", []):
    if str(item.get("status") or "") != "PROCESSING":
        continue
    event_id = str(item.get("event_id") or "")
    ev = event_map.get(event_id, {})
    processing_items.append({
        "event_id": event_id,
        "title": str(item.get("title") or ev.get("title") or ""),
        "url": str(item.get("url") or ""),
        "selected_at": item.get("selected_at"),
        "selection_mode": item.get("selection_mode"),
        "rewrite_version": item.get("rewrite_version"),
        "source_count": int(ev.get("source_count") or item.get("source_count") or 0),
        "sources": list(ev.get("sources") or item.get("sources") or []),
    })

processing_items.sort(key=lambda x: str(x.get("selected_at") or ""), reverse=True)

problematic_items = []
for item in processing.get("items", []):
    if str(item.get("status") or "") != "PROBLEMATIC":
        continue
    event_id = str(item.get("event_id") or "")
    ev = event_map.get(event_id, {})
    problematic_items.append({
        "event_id": event_id,
        "title": str(item.get("title") or ev.get("title") or ""),
        "url": str(item.get("url") or ""),
        "selected_at": item.get("selected_at"),
        "problematic_at": item.get("problematic_at"),
        "problem_reason": str(item.get("problem_reason") or ""),
        "problematic_attempts": int(item.get("problematic_attempts") or 1),
        "user_validated": bool(item.get("user_validated")),
        "user_validated_at": item.get("user_validated_at"),
        "revision": int(item.get("revision") or ev.get("revision") or 1),
        "source_count": int(ev.get("source_count") or item.get("source_count") or 0),
        "sources": list(ev.get("sources") or item.get("sources") or []),
    })
problematic_items.sort(key=lambda x: str(x.get("problematic_at") or x.get("selected_at") or ""), reverse=True)

trend_candidates = []
for item in trend_candidates_doc.get("items", []):
    if str(item.get("status") or "candidate").lower() not in {"candidate", "pending", ""}:
        continue
    trend_candidates.append({
        "candidate_id": str(item.get("candidate_id") or item.get("id") or ""),
        "event_id": str(item.get("event_id") or item.get("ttittulares_event_id") or ""),
        "title": str(item.get("title") or item.get("news_title") or "Posible noticia desde TTendencias"),
        "explanation": str(item.get("explanation") or ""),
        "url": str(item.get("url") or item.get("source_url") or ""),
        "trend_names": list(item.get("trend_names") or []),
        "trend_context": list(item.get("trend_context") or []),
        "search_terms": list(item.get("search_terms") or item.get("trend_names") or []),
        "source_count": int(item.get("source_count") or len(item.get("sources") or [])),
        "sources": list(item.get("sources") or []),
        "source_evidence": list(item.get("source_evidence") or []),
        "detected_at": item.get("detected_at") or item.get("created_at") or item.get("updated_at"),
        "origin": "TTendencias",
    })
trend_candidates.sort(key=lambda x: str(x.get("detected_at") or ""), reverse=True)

def parse_dt(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return None

three_source_items = []
for event in events_doc.get("events", []):
    if int(event.get("source_count") or 0) != 3:
        continue
    if str(event.get("status") or "") not in {"WAITING", "UPDATE_WAITING"}:
        continue
    event_id = str(event.get("id") or "")
    if not event_id:
        continue
    sources = list(event.get("sources") or [])
    source_times = []
    for appearance in event.get("appearances") or []:
        if str(appearance.get("source") or "") not in sources:
            continue
        dt = parse_dt(appearance.get("first_seen"))
        if dt:
            source_times.append(dt)
    source3_minutes = None
    if len(source_times) >= 3:
        source_times.sort()
        source3_minutes = max(0, round((source_times[2] - source_times[0]).total_seconds() / 60))
    three_source_items.append({
        "event_id": event_id,
        "title": str(event.get("canonical_title") or event.get("title") or ""),
        "url": str(event.get("url") or ""),
        "status": str(event.get("status") or ""),
        "revision": int(event.get("revision") or 1),
        "source_count": 3,
        "sources": sources,
        "source3_minutes": source3_minutes,
        "first_seen": event.get("first_seen"),
        "last_seen": event.get("last_seen"),
    })

three_source_items.sort(
    key=lambda x: (
        str(x.get("last_seen") or ""),
        str(x.get("first_seen") or ""),
    ),
    reverse=True,
)

stamp = datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
out = {
    "project":"TTiTTulares",
    "updated_at":stamp,
    "radar_at":events_doc.get("last_run"),
    "processing_count":len(processing_items),
    "processing_items":processing_items,
    "ready_count":len(prepared.get("items", [])),
    "problematic_count":len(problematic_items) + len(trend_candidates),
    "problematic_items":problematic_items,
    "trend_candidates_count":len(trend_candidates),
    "trend_candidates":trend_candidates,
    "three_source_count":len(three_source_items),
    "three_source_items":three_source_items,
    "healthy_source_count":events_doc.get("healthy_source_count"),
    "configured_sources":events_doc.get("configured_sources"),
    "healthy_source_family_count":events_doc.get("healthy_source_family_count"),
    "configured_source_families":events_doc.get("configured_source_families"),
    "source_status":events_doc.get("source_status", []),
    "source_metrics_started_at":(events_doc.get("source_article_telemetry") or {}).get("started_at"),
    "source_failures":events_doc.get("source_failures", []),
    "events":event_map,
}
save(TT / "status.json", out)
print("STATUS", "sources=",out["healthy_source_count"],"/",out["configured_sources"],"processing=",out["processing_count"],"trends=",out["trend_candidates_count"],"ready=",out["ready_count"])
