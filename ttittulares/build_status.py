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
three = 0
for event in events_doc.get("events",[]):
    event_id = str(event.get("id") or "")
    if not event_id:
        continue
    count = int(event.get("source_count") or 0)
    if count == 3 and str(event.get("status") or "") in {"WAITING","UPDATE_WAITING"}:
        three += 1
    event_map[event_id] = {
        "title": str(event.get("canonical_title") or event.get("title") or ""),
        "source_count": count,
        "sources": list(event.get("sources") or []),
        "status": str(event.get("status") or ""),
        "last_seen": event.get("last_seen"),
        "revision": int(event.get("revision") or 1),
        "parent_event_id": event.get("parent_event_id"),
    }

processing_count = sum(1 for x in processing.get("items",[]) if str(x.get("status") or "") == "PROCESSING")
ready_count = len(prepared.get("items",[]))
stamp = datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
out = {
    "project":"TTiTTulares",
    "updated_at":stamp,
    "radar_at":events_doc.get("last_run"),
    "three_sources_count":three,
    "processing_count":processing_count,
    "ready_count":ready_count,
    "healthy_source_count":events_doc.get("healthy_source_count"),
    "configured_sources":events_doc.get("configured_sources"),
    "events":event_map,
}
save(TT / "status.json", out)
print("STATUS", "three=",three,"processing=",processing_count,"ready=",ready_count)
