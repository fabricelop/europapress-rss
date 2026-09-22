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

def now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

mode = load(TT / "control-mode.json", {"mode":"telegram"})
if str(mode.get("mode") or "telegram").lower() != "web":
    print("TTiTTulares sigue en modo Telegram: no se encola automáticamente.")
    raise SystemExit(0)

config = load(TT / "config.json", {})
minimum = int(config.get("radar",{}).get("minimum_sources",4))
events_doc = load(TG / "events.json", {"events":[]})
processing = load(TG / "editorial-processing.json", {"items":[]})
decisions = load(TT / "decisions.json", {"items":[]})

items = processing.setdefault("items", [])
decision_by_event = {}
for d in decisions.get("items",[]):
    event_id = str(d.get("event_id") or "")
    if event_id:
        decision_by_event[event_id] = d

existing = {}
for item in items:
    event_id = str(item.get("event_id") or "")
    if event_id:
        existing[event_id] = item

eligible_status = {"WAITING","SENT_REVIEW","ELIGIBLE","UPDATE_WAITING","ELIGIBLE_UPDATE"}
queued = []
stamp = now_iso()

for event in events_doc.get("events",[]):
    event_id = str(event.get("id") or "")
    if not event_id:
        continue
    if int(event.get("source_count") or 0) < minimum:
        continue
    if str(event.get("status") or "") not in eligible_status:
        continue

    # Una revisión material del radar tiene su propio event_id (p.ej. -r2):
    # se trata como noticia nueva y nunca reabre la anterior.
    decision = decision_by_event.get(event_id)
    if decision and str(decision.get("status") or "") in {"published","dismissed"}:
        continue

    current = existing.get(event_id)
    if current and str(current.get("status") or "") in {"PROCESSING","READY","PUBLISHED","DISMISSED"}:
        continue

    row = current or {"event_id":event_id}
    row.update({
        "event_id": event_id,
        "title": str(event.get("canonical_title") or event.get("title") or "").strip(),
        "url": str(event.get("url") or ""),
        "sources": list(event.get("sources") or []),
        "source_count": int(event.get("source_count") or 0),
        "drafted_source_count": int(event.get("source_count") or 0),
        "selected_at": stamp,
        "status": "PROCESSING",
        "selection_mode": "AUTO_WEB",
        "revision": int(event.get("revision") or row.get("revision") or 1),
        "parent_event_id": event.get("parent_event_id"),
        "update_context": event.get("update_context"),
    })
    if current is None:
        items.append(row)
        existing[event_id] = row
    queued.append(event_id)

processing["updated_at"] = stamp
save(TG / "editorial-processing.json", processing)
print("AUTO_WEB_QUEUED", len(queued), queued)
