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

event_map = {}
for event in events_doc.get("events", []):
    event_id = str(event.get("id") or "")
    if not event_id:
        continue
    event_map[event_id] = {
        "title": str(event.get("canonical_title") or event.get("title") or ""),
        "source_count": int(event.get("source_count") or 0),
        "sources": list(event.get("sources") or []),
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

stamp = datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
out = {
    "project":"TTiTTulares",
    "updated_at":stamp,
    "radar_at":events_doc.get("last_run"),
    "processing_count":len(processing_items),
    "processing_items":processing_items,
    "ready_count":len(prepared.get("items", [])),
    "three_source_count":sum(
        1 for event in events_doc.get("events", [])
        if int(event.get("source_count") or 0) == 3
        and str(event.get("status") or "") in {"WAITING","UPDATE_WAITING"}
    ),
    "healthy_source_count":events_doc.get("healthy_source_count"),
    "configured_sources":events_doc.get("configured_sources"),
    "source_failures":events_doc.get("source_failures", []),
    "events":event_map,
}
save(TT / "status.json", out)
print("STATUS", "sources=",out["healthy_source_count"],"/",out["configured_sources"],"processing=",out["processing_count"],"ready=",out["ready_count"])
