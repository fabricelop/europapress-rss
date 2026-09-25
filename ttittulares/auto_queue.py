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

def dtv(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z","+00:00")).astimezone(timezone.utc)
    except Exception:
        return datetime.min.replace(tzinfo=timezone.utc)

def queue_eligible(events_doc, processing, decisions, minimum, stamp, mode="web", parallel_since=None):
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

    mode = str(mode or "telegram").lower()
    cutoff = dtv(parallel_since) if parallel_since else datetime.max.replace(tzinfo=timezone.utc)
    queued = []

    for event in events_doc.get("events", []):
        event_id = str(event.get("id") or "")
        if not event_id or int(event.get("source_count") or 0) < minimum:
            continue

        status = str(event.get("status") or "")
        if mode == "web":
            if status not in {"ELIGIBLE", "ELIGIBLE_UPDATE"}:
                continue
        elif mode == "parallel":
            # En paralelo el radar conserva el circuito Telegram y deja el evento
            # en SENT_REVIEW. Solo espejamos noticias NUEVAS desde parallel_since:
            # nunca importamos el backlog antiguo de Telegram.
            if status != "SENT_REVIEW":
                continue
            claimed = dtv(event.get("notification_claimed_at"))
            if claimed < cutoff:
                continue
        else:
            continue

        decision = decision_by_event.get(event_id)
        if decision and str(decision.get("status") or "") in {"published", "dismissed"}:
            continue

        current = existing.get(event_id)
        if current and str(current.get("status") or "") in {"PROCESSING", "READY", "PUBLISHED", "DISMISSED", "PROBLEMATIC"}:
            continue

        row = current or {"event_id": event_id}
        row.update({
            "event_id": event_id,
            "title": str(event.get("canonical_title") or event.get("title") or "").strip(),
            "url": str(event.get("url") or ""),
            "sources": list(event.get("sources") or []),
            "source_count": int(event.get("source_count") or 0),
            "drafted_source_count": int(event.get("source_count") or 0),
            "source_evidence": [
                {
                    "source": str(a.get("source") or ""),
                    "title": str(a.get("title") or ""),
                    "url": str(a.get("url") or ""),
                    "first_seen": a.get("first_seen"),
                }
                for a in (event.get("appearances") or [])
                if str(a.get("source") or "") in set(event.get("sources") or [])
            ][:16],
            "selected_at": stamp,
            "status": "PROCESSING",
            "selection_mode": "AUTO_PARALLEL" if mode == "parallel" else "AUTO_WEB",
            "revision": int(event.get("revision") or row.get("revision") or 1),
            "parent_event_id": event.get("parent_event_id"),
            "update_context": event.get("update_context"),
            "parallel_source_claimed_at": event.get("notification_claimed_at") if mode == "parallel" else None,
            "with_image": True,
            "image_mode": "existing_web_image",
        })
        if current is None:
            items.append(row)
            existing[event_id] = row
        queued.append(event_id)

    processing["updated_at"] = stamp
    return processing, queued

def selftest():
    stamp="2026-09-22T22:05:00Z"
    events={"events":[
        {"id":"under","canonical_title":"Tres fuentes","source_count":3,"status":"WAITING","sources":["A","B","C"]},
        {"id":"web-ok","canonical_title":"Cuatro fuentes web","source_count":4,"status":"ELIGIBLE","sources":["A","B","C","D"]},
        {"id":"parallel-old","canonical_title":"Telegram antiguo","source_count":6,"status":"SENT_REVIEW","sources":["A","B","C","D","E","F"],"notification_claimed_at":"2026-09-22T21:50:00Z"},
        {"id":"parallel-new","canonical_title":"Telegram nuevo","source_count":5,"status":"SENT_REVIEW","sources":["A","B","C","D","E"],"notification_claimed_at":"2026-09-22T22:01:00Z"},
        {"id":"published","canonical_title":"Ya publicada","source_count":5,"status":"ELIGIBLE","sources":["A","B","C","D","E"]},
        {"id":"revision-r2","canonical_title":"Actualización material","source_count":4,"status":"ELIGIBLE_UPDATE","sources":["A","B","C","D"],"revision":2,"parent_event_id":"revision"},
    ]}
    decisions={"items":[{"event_id":"published","status":"published"}]}

    out_web,queued_web=queue_eligible(events,{"items":[]},decisions,4,stamp,"web")
    assert queued_web==["web-ok","revision-r2"], queued_web

    out_parallel,queued_parallel=queue_eligible(
        events,{"items":[]},decisions,4,stamp,"parallel","2026-09-22T22:00:00Z"
    )
    assert queued_parallel==["parallel-new"], queued_parallel
    assert out_parallel["items"][0]["selection_mode"]=="AUTO_PARALLEL"

    # Cuarentena: un evento PROBLEMATIC no vuelve a PROCESSING en otra pasada
    # del radar. Debe requerir una acción explícita/revisión distinta para reintentarse.
    problematic_state={"items":[{"event_id":"web-ok","status":"PROBLEMATIC","revision":1,"problem_reason":"sin verificación suficiente"}]}
    out_problematic,queued_problematic=queue_eligible(events,problematic_state,decisions,4,stamp,"web")
    assert queued_problematic==["revision-r2"], queued_problematic
    assert out_problematic["items"][0]["status"]=="PROBLEMATIC", out_problematic

    # Idempotencia: una segunda pasada no vuelve a encolar el mismo evento.
    out2,queued2=queue_eligible(
        events,out_parallel,decisions,4,stamp,"parallel","2026-09-22T22:00:00Z"
    )
    assert queued2==[], queued2
    print("AUTO_QUEUE_SELFTEST_OK",queued_web,queued_parallel)
    return 0

if "--selftest" in sys.argv:
    raise SystemExit(selftest())

mode_doc = load(TT / "control-mode.json", {"mode": "telegram"})
mode = str(mode_doc.get("mode") or "telegram").lower()
if mode not in {"web","parallel"}:
    print("TTiTTulares sigue en modo Telegram puro: no se encola automáticamente.")
    raise SystemExit(0)

config = load(TT / "config.json", {})
minimum = int(config.get("radar", {}).get("minimum_sources", 4))
events_doc = load(TG / "events.json", {"events": []})
processing = load(TG / "editorial-processing.json", {"items": []})
decisions = load(TT / "decisions.json", {"items": []})

processing, queued = queue_eligible(
    events_doc, processing, decisions, minimum, now_iso(),
    mode=mode, parallel_since=mode_doc.get("parallel_since")
)
save(TG / "editorial-processing.json", processing)
print(("AUTO_PARALLEL_QUEUED" if mode=="parallel" else "AUTO_WEB_QUEUED"), len(queued), queued)
