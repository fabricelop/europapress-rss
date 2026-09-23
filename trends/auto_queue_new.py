#!/usr/bin/env python3
import hashlib
import json
import unicodedata
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
MADRID = ZoneInfo("Europe/Madrid")

def load(name, default):
    path = ROOT / name
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default

def save(name, obj):
    (ROOT / name).write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def norm(value):
    text = unicodedata.normalize("NFD", str(value or ""))
    text = "".join(ch for ch in text if unicodedata.category(ch) != "Mn")
    return " ".join(text.casefold().split())

recent = load("recent.json", {"items": []})
requests_doc = load("requests.json", {"requests": []})
explained_doc = load("telegram-manual-explained.json", {"items": []})

requests = requests_doc.setdefault("requests", [])
explained = {norm(x.get("name")) for x in explained_doc.get("items", []) if x.get("name")}
by_name = {}
for req in requests:
    key = norm(req.get("name"))
    if key:
        by_name[key] = req

current = []
for item in (recent.get("items") or [])[:10]:
    name = str(item.get("name") or "").strip()
    if name:
        current.append({"name": name, "rank": int(item.get("rank") or 0)})

to_queue = []
for item in current:
    key = norm(item["name"])
    req = by_name.get(key)
    status = str((req or {}).get("status") or "")
    if req:
        # Cualquier decisión/estado vigente se conserva. Una tendencia
        # desestimada o problemática solo se reabre por acción del usuario.
        if status in {"preparing", "update", "ready", "explained", "dismissed", "problematic"}:
            continue
    elif key in explained:
        continue
    to_queue.append(item)

if not to_queue:
    print("Sin tendencias nuevas que encolar")
    raise SystemExit(0)

now = datetime.now(MADRID).isoformat(timespec="seconds")
names = [x["name"] for x in to_queue]
batch_id = hashlib.sha256((" | ".join(names) + " | " + now).encode("utf-8")).hexdigest()[:12]

for item in to_queue:
    name = item["name"]
    key = norm(name)
    req = by_name.get(key)
    req_id = str((req or {}).get("id") or hashlib.sha256(name.encode("utf-8")).hexdigest()[:12])
    new_req = {
        "id": req_id,
        "name": name,
        "rank": item["rank"],
        "status": "preparing",
        "requested_at": now,
        "revision": int((req or {}).get("revision") or 0),
        "reexplain": False,
        "with_image": False,
        "alternatives_target": 3,
        "batch_id": batch_id,
        # Auto-queueing at the same capture time is NOT evidence that trends
        # belong to the same story. Keep semantic grouping conservative.
        "requested_together": [name],
        "captured_with": names,
        "auto_queued": True,
    }
    if req is None:
        requests.append(new_req)
        by_name[key] = new_req
    else:
        req.clear()
        req.update(new_req)

requests_doc["updated_at"] = now
save("requests.json", requests_doc)
print("Encoladas automáticamente:", ", ".join(names))
