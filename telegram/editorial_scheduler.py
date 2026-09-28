import json, os, urllib.request
from datetime import datetime, timezone
from pathlib import Path

p=Path("telegram/editorial-processing.json")
d=json.loads(p.read_text(encoding="utf-8"))
pending=[x for x in d.get("items",[]) if x.get("status")=="PROCESSING"]
now=datetime.now(timezone.utc).isoformat()
state={"requested_at":now,"pending_count":len(pending),"event_ids":[str(x.get("event_id")) for x in pending]}
Path("telegram/editorial-schedule-state.json").write_text(json.dumps(state,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
if not pending:
 print("Sin noticias PROCESSING")
 raise SystemExit(0)
# Este workflow deja una solicitud durable y visible. La redaccion editorial real
# sigue siendo el agente que procesa PROCESSING; nunca fingimos READY sin redactar.
for x in pending:
 x.setdefault("automatic_redaction_requested_at",now)
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("Solicitudes de redaccion:",len(pending))
