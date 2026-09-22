import json, os, subprocess, urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

EVENTS=Path("telegram/events.json")
PROC=Path("telegram/editorial-processing.json")
PROCESSED=Path("telegram/processed-events.json")
MIN_HEALTHY=10
MAX_BYTES=900000
ALERT_STATE=Path("telegram/autocheck-alert-state.json")

def load(path, default):
    try:
        raw=path.read_text(encoding="utf-8").strip()
        return json.loads(raw) if raw else default
    except Exception:
        return default

def run(*args):
    return subprocess.run(args,text=True,capture_output=True)

def telegram(text):
    token=os.getenv("TELEGRAM_BOT_TOKEN","")
    chat=os.getenv("TELEGRAM_CHAT_ID","")
    if not token or not chat: return False
    data=json.dumps({"chat_id":chat,"text":text}).encode()
    req=urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage",data=data,headers={"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req,timeout=20) as r:
            return json.loads(r.read().decode()).get("ok",False)
    except Exception:
        return False

def inspect():
    d=load(EVENTS,{})
    problems=[]
    if not isinstance(d,dict) or not isinstance(d.get("events"),list):
        problems.append("events_json_invalido")
    healthy=int(d.get("healthy_source_count",0) or 0) if isinstance(d,dict) else 0
    if healthy<MIN_HEALTHY: problems.append(f"fuentes_sanas_{healthy}")
    failures=d.get("source_failures",[]) if isinstance(d,dict) else []
    # Un fallo individual de fuente NO es bloqueante si el radar conserva
    # suficiente cobertura general. El propio radar aplica fallbacks/recuperación.
    # Solo alertar por degradación real: menos de MIN_HEALTHY fuentes sanas.
    if EVENTS.exists() and EVENTS.stat().st_size>MAX_BYTES: problems.append("events_json_demasiado_grande")
    p=load(PROC,{})
    if not isinstance(p,dict) or not isinstance(p.get("items"),list):
        problems.append("editorial_processing_invalido")
    else:
        now=datetime.now(timezone.utc)
        stuck=[]
        for item in p.get("items",[]):
            if item.get("status")!="PROCESSING": continue
            try:
                since=datetime.fromisoformat(str(item.get("selected_at","")).replace("Z","+00:00"))
                if now-since > timedelta(minutes=75):
                    stuck.append(str(item.get("event_id","?")))
            except Exception:
                stuck.append(str(item.get("event_id","?")))
        if stuck:
            problems.append("elaborando_bloqueado_"+str(len(stuck)))
    q=load(PROCESSED,{})
    if not isinstance(q,(dict,list)): problems.append("processed_events_invalido")
    return d,problems

before,problems=inspect()
actions=[]
if "events_json_demasiado_grande" in problems:
    p=run("python3","telegram/prune_events.py")
    actions.append("poda_events:"+str(p.returncode))

# La recuperación de fuentes ya ocurre dentro del barrido, en paralelo.
# El autocheck solo observa y reporta: nunca relanza el radar por una fuente caída.

after,remaining=inspect()

# La redacción programada corre a :15 y :45. Un PROCESSING es normal mientras
# espera su siguiente turno. Solo lo consideramos bloqueo tras 75 minutos:
# eso implica que ha perdido al menos dos oportunidades razonables de redacción.

report={
 "checked_at":datetime.now(timezone.utc).isoformat(),
 "before":problems,
 "repair_actions":actions,
 "remaining":remaining,
 "healthy_source_count":after.get("healthy_source_count",0) if isinstance(after,dict) else 0,
 "source_failures":after.get("source_failures",[]) if isinstance(after,dict) else [],
 "events_bytes":EVENTS.stat().st_size if EVENTS.exists() else 0,
 "ok":not remaining
}
Path("telegram/autocheck-status.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print(json.dumps(report,ensure_ascii=False))
if remaining:
    # Evitar inundar Telegram con el mismo error en cada barrido.
    # Clave estable por COMPONENTE, no por contador variable. Así una oscilación
    # (p.ej. 4->5->2 fuentes) no genera una alerta nueva cada pocos minutos.
    def alert_family(x):
        if x.startswith("fuentes_sanas_"): return "fuentes_degradadas"
        if x.startswith("elaborando_bloqueado_"): return "elaborando_bloqueado"
        return x
    key="|".join(sorted(set(alert_family(x) for x in remaining)))
    state=load(ALERT_STATE,{})
    last_key=state.get("key")
    try:
        last_at=datetime.fromisoformat(str(state.get("sent_at","")).replace("Z","+00:00"))
    except Exception:
        last_at=datetime.min.replace(tzinfo=timezone.utc)
    now=datetime.now(timezone.utc)
    if key!=last_key or now-last_at>timedelta(hours=2):
        telegram("⚠️ TTiTTulares · incidencia detectada\n"+", ".join(remaining))
        ALERT_STATE.write_text(json.dumps({"key":key,"sent_at":now.isoformat()},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    # El autocheck informa de la incidencia, pero no aborta el barrido: abortarlo
    # impedía persistir la poda/deduplicación y provocaba el reenvío de noticias.
    print("AUTOCHECK_BLOCKING", ", ".join(remaining))
else:
    # Si el servicio se recuperó, olvidar la alerta anterior para que una recaída
    # real posterior se notifique inmediatamente.
    if ALERT_STATE.exists():
        ALERT_STATE.write_text(json.dumps({"key":"","cleared_at":datetime.now(timezone.utc).isoformat()},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
