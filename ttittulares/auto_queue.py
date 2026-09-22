#!/usr/bin/env python3
import json, sys
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

def queue_eligible(events_doc, processing, decisions, minimum, stamp):
    items = processing.setdefault("items", [])
    decision_by_event = {}
    for d in decisions.get("items", []):
        event_id = str(d.get("event_id") or "")
        if event_id:
            decision_by_event[event_id] = d

    existing = {}
    for item in items:
        event_id = str(item.get("event_id") or "")
        if event_id:
            existing[event_id] = item

    eligible_status = {"ELIGIBLE", "ELIGIBLE_UPDATE"}
    queued = []

    for event in events_doc.get("events", []):
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
        if decision and str(decision.get("status") or "") in {"published", "dismissed"}:
            continue

        current = existing.get(event_id)
        if current and str(current.get("status") or "") in {"PROCESSING", "READY", "PUBLISHED", "DISMISSED"}:
            continue

        row = current or {"event_id": event_id}
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
    return processing, queued

def selftest():
    stamp="2026-09-22T20:00:00Z"
    events={"events":[
        {"id":"under","canonical_title":"Tres fuentes","source_count":3,"status":"WAITING","sources":["A","B","C"]},
        {"id":"ok","canonical_title":"Cuatro fuentes","source_count":4,"status":"ELIGIBLE","sources":["A","B","C","D"]},
        {"id":"oldtelegram","canonical_title":"Ya avisada Telegram","source_count":6,"status":"SENT_REVIEW","sources":["A","B","C","D","E","F"]},
        {"id":"published","canonical_title":"Ya publicada","source_count":5,"status":"ELIGIBLE","sources":["A","B","C","D","E"]},
        {"id":"revision-r2","canonical_title":"Actualización material","source_count":4,"status":"ELIGIBLE_UPDATE","sources":["A","B","C","D"],"revision":2,"parent_event_id":"revision"},
    ]}
    proc={"items":[]}
    decisions={"items":[{"event_id":"published","status":"published"}]}
    out,queued=queue_eligible(events,proc,decisions,4,stamp)
    assert queued==["ok","revision-r2"], queued
    assert all(x["source_count"]>=4 for x in out["items"])
    assert all(x["status"]=="PROCESSING" for x in out["items"])
    # Idempotencia: una segunda pasada no vuelve a encolar lo que ya está PROCESSING.
    out2,queued2=queue_eligible(events,out,decisions,4,stamp)
    assert queued2==[], queued2
    print("AUTO_QUEUE_SELFTEST_OK",queued)
    return 0

if "--selftest" in sys.argv:
    raise SystemExit(selftest())

mode = load(TT / "control-mode.json", {"mode": "telegram"})
if str(mode.get("mode") or "telegram").lower() != "web":
    print("TTiTTulares sigue en modo Telegram: no se encola automáticamente.")
    raise SystemExit(0)

config = load(TT / "config.json", {})
minimum = int(config.get("radar", {}).get("minimum_sources", 4))
events_doc = load(TG / "events.json", {"events": []})
processing = load(TG / "editorial-processing.json", {"items": []})
decisions = load(TT / "decisions.json", {"items": []})

processing, queued = queue_eligible(events_doc, processing, decisions, minimum, now_iso())
save(TG / "editorial-processing.json", processing)
print("AUTO_WEB_QUEUED", len(queued), queued)
