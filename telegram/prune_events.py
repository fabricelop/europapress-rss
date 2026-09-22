import json
from datetime import datetime, timezone, timedelta
from pathlib import Path

PATH = Path("telegram/events.json")
TTL_HOURS = 24
MAX_ACTIVE_EVENTS = 700

def parse_dt(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return datetime.min.replace(tzinfo=timezone.utc)

raw = PATH.read_text(encoding="utf-8").strip()
if not raw:
    raise RuntimeError("events.json vacío: no se sobrescribe")

doc = json.loads(raw)
events = doc.get("events")
if not isinstance(events, list):
    raise RuntimeError("events.json inválido: events no es una lista")

cutoff = datetime.now(timezone.utc) - timedelta(hours=TTL_HOURS)
before = len(events)

# El modelo actual conserva/actualiza eventos durante 24 h. Algunos registros
# históricos no tienen first_seen fiable (o usan otros campos temporales), y
# antes la poda los dejaba crecer indefinidamente. Tomamos la mejor marca
# disponible y descartamos lo que no pueda demostrarse activo en la ventana.
def event_dt(e):
    candidates = [
        e.get("last_seen"), e.get("updated_at"), e.get("first_seen"),
        e.get("created_at"), e.get("published_at"), e.get("timestamp"),
    ]
    parsed = [parse_dt(v) for v in candidates if v]
    parsed = [v for v in parsed if v != datetime.min.replace(tzinfo=timezone.utc)]
    return max(parsed) if parsed else datetime.min.replace(tzinfo=timezone.utc)

active = [e for e in events if event_dt(e) >= cutoff]
# events.json es estado operativo, no archivo histórico. Incluso con mucha
# actividad en 24 h debe mantenerse acotado para no bloquear Git/Actions.
# Conservamos los eventos más recientes; el histórico ya vive en archivos
# separados y processed-events.json.
active.sort(key=event_dt, reverse=True)
doc["events"] = active[:MAX_ACTIVE_EVENTS]
doc["active_retention_hours"] = TTL_HOURS
doc["active_event_cap"] = MAX_ACTIVE_EVENTS
doc["pruned_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

tmp = PATH.with_suffix(".json.tmp")
tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.replace(PATH)
print(f"EVENTS_PRUNED {before} -> {len(doc['events'])}")
