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
    if failures: problems.append(f"fuentes_fallidas_{len(failures)}")
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
                if now-since > timedelta(minutes=35):
                    stuck.append(str(item.get("event_id","?")))
            except Exception:
                stuck.append(str(item.get("event_id","?")))
        if stuck:
            problems.append("elaborando_atascado_"+str(len(stuck)))
    q=load(PROCESSED,{})
    if not isinstance(q,(dict,list)): problems.append("processed_events_invalido")
    return d,problems

before,problems=inspect()
actions=[]
if "events_json_demasiado_grande" in problems:
    p=run("python3","telegram/prune_events.py")
    actions.append("poda_events:"+str(p.returncode))

# Si el radar quedó degradado, repetir una vez desde estado ya podado.
if any(x.startswith("fuentes_sanas_") or x.startswith("fuentes_fallidas_") or x=="events_json_invalido" for x in problems):
    p=run("python3","telegram/radar_no_d1.py")
    actions.append("reintento_radar:"+str(p.returncode))
    if p.returncode==0:
        run("python3","telegram/prune_events.py")

after,remaining=inspect()

# Un PROCESSING antiguo significa que la selección llegó a Elaborando pero no
# existe un redactor/entregador activo que la consuma. No lo ocultamos como
# saludable: lo dejamos explícitamente bloqueante para evitar colas silenciosas.

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
    key="|".join(sorted(remaining))
    state=load(ALERT_STATE,{})
    last_key=state.get("key")
    try:
        last_at=datetime.fromisoformat(str(state.get("sent_at","")).replace("Z","+00:00"))
    except Exception:
        last_at=datetime.min.replace(tzinfo=timezone.utc)
    now=datetime.now(timezone.utc)
    if key!=last_key or now-last_at>timedelta(hours=2):
        telegram("🚨 TTiTTulares · fallo bloqueante tras auto-reparación\n"+", ".join(remaining))
        ALERT_STATE.write_text(json.dumps({"key":key,"sent_at":now.isoformat()},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    # El autocheck informa del bloqueo, pero no aborta el barrido: abortarlo
    # impedía persistir la poda/deduplicación y provocaba el reenvío de noticias.
    print("AUTOCHECK_BLOCKING", ", ".join(remaining))
