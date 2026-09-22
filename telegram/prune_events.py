import json
from datetime import datetime, timezone, timedelta
from pathlib import Path

PATH = Path("telegram/events.json")
TTL_HOURS = 24

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
doc["events"] = [e for e in events if parse_dt(e.get("first_seen")) >= cutoff]
doc["active_retention_hours"] = TTL_HOURS
doc["pruned_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

tmp = PATH.with_suffix(".json.tmp")
tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.replace(PATH)
print(f"EVENTS_PRUNED {before} -> {len(doc['events'])}")
