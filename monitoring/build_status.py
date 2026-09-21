#!/usr/bin/env python3
# Monitoring only: no production workflow logic is modified.
import json, os, subprocess, urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "monitoring" / "status.json"
REPO = os.environ.get("GITHUB_REPOSITORY", "fabricelop/europapress-rss")
TOKEN = os.environ.get("GITHUB_TOKEN", "")
NOW = datetime.now(timezone.utc)

def iso(dt):
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00","Z") if dt else None

def parse_dt(value):
    if not value: return None
    try: return datetime.fromisoformat(str(value).replace("Z","+00:00")).astimezone(timezone.utc)
    except Exception: return None

def age_minutes(dt):
    return None if not dt else round((NOW-dt).total_seconds()/60,1)

def api(path):
    headers={"Accept":"application/vnd.github+json","User-Agent":"project-status-monitor"}
    if TOKEN: headers["Authorization"]="Bearer "+TOKEN
    req=urllib.request.Request("https://api.github.com"+path,headers=headers)
    with urllib.request.urlopen(req,timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))

def workflow_state(filename, expected_minutes=None, warn_after=None, label=None):
    data=api(f"/repos/{REPO}/actions/workflows/{filename}/runs?per_page=20")
    completed=[r for r in data.get("workflow_runs",[]) if r.get("status")=="completed"]
    successes=[r for r in completed if r.get("conclusion")=="success"]
    failures=[r for r in completed if r.get("conclusion") not in ("success","skipped","neutral")]
    last=completed[0] if completed else None
    last_ok=successes[0] if successes else None
    last_err=failures[0] if failures else None
    ok_dt=parse_dt(last_ok.get("updated_at")) if last_ok else None
    err_dt=parse_dt(last_err.get("updated_at")) if last_err else None
    last_dt=parse_dt(last.get("updated_at")) if last else None
    stale_after=warn_after or (expected_minutes*2.5 if expected_minutes else None)
    status="green"; anomaly=None
    if last and last.get("conclusion") not in ("success","skipped","neutral"):
        status="orange" if ok_dt else "red"
        anomaly=f"Última ejecución terminó en {last.get('conclusion')}"
    if stale_after and ok_dt and age_minutes(ok_dt)>stale_after:
        status="orange" if age_minutes(ok_dt)<=stale_after*2 else "red"
        anomaly=f"Sin ejecución correcta desde hace {age_minutes(ok_dt)} min"
    if stale_after and not ok_dt:
        status="red"; anomaly="No hay ninguna ejecución correcta registrada"
    return {
        "label":label or filename,"kind":"workflow","workflow":filename,"status":status,
        "last_run":iso(last_dt),"last_ok":iso(ok_dt),"last_error":iso(err_dt),
        "last_conclusion":last.get("conclusion") if last else None,
        "age_minutes":age_minutes(ok_dt),"expected_minutes":expected_minutes,
        "anomaly":anomaly,"run_url":last.get("html_url") if last else None
    }

def git_last(path):
    try:
        s=subprocess.check_output(["git","log","-1","--format=%cI","--",path],cwd=ROOT,text=True).strip()
        return parse_dt(s)
    except Exception: return None

def json_timestamp(path, field, expected_minutes=None, label=None, ok_field=None):
    p=ROOT/path
    try: obj=json.loads(p.read_text(encoding="utf-8"))
    except Exception: obj={}
    dt=parse_dt(obj.get(field)) or git_last(path)
    status="green"; anomaly=None
    if expected_minutes and (not dt or age_minutes(dt)>expected_minutes*2.5):
        if not dt:
            status="red"; anomaly="No hay heartbeat verificable"
        else:
            status="orange" if age_minutes(dt)<=expected_minutes*5 else "red"
            anomaly=f"Sin actualización desde hace {age_minutes(dt)} min"
    if ok_field:
        reported=obj.get(ok_field)
        successful={None,"ok","OK","no_new_candidates","success","SUCCESS",True}
        if reported not in successful:
            status="orange"; anomaly=f"Estado reportado: {reported}"
    return {
        "label":label or str(path),"kind":"file","path":str(path),"status":status,
        "last_run":iso(dt),"last_ok":iso(dt) if status!="red" else None,"last_error":None,
        "age_minutes":age_minutes(dt),"expected_minutes":expected_minutes,"anomaly":anomaly
    }

def git_activity(path,label=None):
    dt=git_last(path)
    return {
        "label":label or path,"kind":"activity","path":path,
        "status":"green" if dt else "orange","last_run":iso(dt),"last_ok":iso(dt),
        "last_error":None,"age_minutes":age_minutes(dt),"expected_minutes":None,
        "anomaly":None if dt else "Sin actividad verificable"
    }

projects={
 "TTiTTulares":{
   "radar_noticias":workflow_state("telegram-listener.yml",60,150,"Radar de noticias"),
   "radar_manual":workflow_state("radar-no-d1.yml",None,None,"Barrido manual de radar"),
   "entrada_telegram":workflow_state("telegram-listener.yml",60,150,"Listener / entrada Telegram"),
   "envio_candidatos":workflow_state("send-telegram.yml",None,None,"Envío de candidatos a Telegram"),
   "redactor":git_activity("telegram/latest.json","Redactor / salida editorial"),
   "envio_redaccion":workflow_state("telegram-emergency.yml",None,None,"Envío de redacción a Telegram")
 },
 "TTendencias":{
   "captura_top10":workflow_state("ttendencias-refresh.yml",15,50,"Captura Top 10"),
   "listener_panel":workflow_state("ttendencias-listener.yml",30,80,"Listener / panel Telegram"),
   "redactor":git_activity("trends/latest.json","Redactor de tendencias"),
   "envio_telegram":workflow_state("send-trends-telegram.yml",None,None,"Envío de tendencias a Telegram")
 },
 "SeLoRecordamos":{
   "busqueda_x":json_timestamp("selorecordamos/search-report.json","generated_at",60,"Recuperación / búsqueda en X","status"),
   "postfiltro":json_timestamp("selorecordamos/search-report.json","generated_at",60,"Postfiltro / descartados","status"),
   "evaluacion":git_activity("selorecordamos/assistant-output.json","Evaluación / redacción"),
   "telegram_instrucciones":git_activity("selorecordamos/requests.json","Telegram / instrucciones")
 }
}
rank={"green":0,"orange":1,"red":2}
result={}
for project,mods in projects.items():
    worst=max((rank.get(m.get("status"),1) for m in mods.values()),default=1)
    result[project]={
        "status":["green","orange","red"][worst],
        "anomalies":[m["anomaly"] for m in mods.values() if m.get("anomaly")],
        "modules":mods
    }
OUT.parent.mkdir(parents=True,exist_ok=True)
OUT.write_text(json.dumps({"generated_at":iso(NOW),"repository":REPO,"projects":result},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("Estado escrito en",OUT)
