import datetime as dt
import json, os, subprocess, time, urllib.parse, urllib.request, urllib.error
from pathlib import Path

TOKEN=os.environ["TELEGRAM_BOT_TOKEN"]
CHAT=str(os.environ["TELEGRAM_CHAT_ID"])
BASE=f"https://api.telegram.org/bot{TOKEN}"
ROOT=Path(".")
STATE=Path("telegram/telegram-state.json")
REQ=Path("telegram/emergency-requests.json")
EVENTS=Path("telegram/events.json")
PROC=Path("telegram/editorial-processing.json")
PROCESSED=Path("telegram/processed-events.json")
TARGET_MINUTES={10,25,40,55}
END=time.time()+85*60

def load_json(path, default):
    if not path.exists(): return default
    raw=path.read_text(encoding="utf-8").strip()
    if not raw: return default
    try: return json.loads(raw)
    except json.JSONDecodeError:
        obj,_=json.JSONDecoder().raw_decode(raw)
        return obj

def write_json(path, obj):
    path.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def api(method,payload=None,timeout=30):
    data=json.dumps(payload).encode() if payload is not None else None
    req=urllib.request.Request(f"{BASE}/{method}",data=data,headers={"Content-Type":"application/json"} if data else {})
    try:
        with urllib.request.urlopen(req,timeout=timeout) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body=e.read().decode()
        print("TELEGRAM_HTTP",method,e.code,body,flush=True)
        return {"ok":False,"description":body}

def safe_ack(cqid,text):
    if cqid: api("answerCallbackQuery",{"callback_query_id":cqid,"text":text})

def safe_delete(mid):
    if mid: api("deleteMessage",{"chat_id":CHAT,"message_id":int(mid)})

def git(*args,check=True):
    return subprocess.run(["git",*args],text=True,capture_output=True,check=check)

def sync_repo():
    git("pull","--rebase","--autostash","origin","main",check=False)

def commit_paths(paths,message):
    git("add",*paths,check=False)
    if git("diff","--cached","--quiet",check=False).returncode==0: return
    git("commit","-m",message,check=False)
    p=git("push","origin","HEAD:main",check=False)
    if p.returncode!=0:
        git("pull","--rebase","--autostash","origin","main",check=False)
        git("push","origin","HEAD:main",check=False)

def persist_callback(update):
    sync_repo()
    state=load_json(STATE,{})
    q=load_json(REQ,{"requests":[]}); q.setdefault("requests",[])
    events_doc=load_json(EVENTS,{"events":[]})
    events=events_doc.get("events",[]) if isinstance(events_doc,dict) else events_doc
    proc=load_json(PROC,{"items":[]}); proc.setdefault("items",[])
    uid=int(update["update_id"])
    cq=update.get("callback_query") or {}
    msg=cq.get("message") or {}
    data=str(cq.get("data") or "")
    mid=msg.get("message_id")
    now=dt.datetime.now(dt.timezone.utc).isoformat()
    state["offset"]=max(int(state.get("offset",0) or 0),uid+1)

    if data.startswith("dg:"):
        mids=[int(x) for x in data[3:].split(",") if x.isdigit()]
        if mid and int(mid) not in mids: mids.append(int(mid))
        for m in mids: safe_delete(m)
        safe_ack(cq.get("id"),f"🗑️ Borrados {len(mids)} mensajes.")
    elif data=="delete:message":
        safe_ack(cq.get("id"),"🗑️ Mensaje borrado.")
        safe_delete(mid)
    else:
        action=idv=""
        if data.startswith("emergency:"):
            p=data.split(":"); action=p[1] if len(p)>1 else ""; idv=":".join(p[2:])
        elif data.startswith("prepare:"):
            action="prepare"; idv=data.split(":",1)[1]
        elif data.startswith("dismiss:"):
            action="dismiss"; idv=data.split(":",1)[1]
        if action in ("prepare","dismiss") and idv:
            if not any(int(x.get("update_id",-1))==uid for x in q["requests"]):
                q["requests"].append({"update_id":uid,"action":action,"id":idv,"at":now,"chat":CHAT,"message_id":mid})
            ev=next((e for e in events if str(e.get("id"))==idv),None)
            if ev:
                ev["status"]="PROCESSING" if action=="prepare" else "DISMISSED"
                if action=="prepare" and not any(str(x.get("event_id"))==idv for x in proc["items"]):
                    proc["items"].append({"event_id":idv,"title":ev.get("title",""),"url":ev.get("url",""),"sources":ev.get("sources",[]),"source_count":ev.get("source_count",len(ev.get("sources",[]))),"selected_at":now,"status":"PROCESSING"})
            safe_ack(cq.get("id"),"🧠 Enviada a Elaborando." if action=="prepare" else "🗑️ Desestimada.")
            safe_delete(mid)
    q["requests"]=q["requests"][-200:]
    write_json(STATE,state); write_json(REQ,q); write_json(EVENTS,events_doc); write_json(PROC,proc)
    commit_paths([str(STATE),str(REQ),str(EVENTS),str(PROC)],"Procesar botón Telegram")
    return state["offset"]

def run_radar(slot):
    print("RADAR_START",slot,flush=True)
    sync_repo()
    p=subprocess.run(["python3","telegram/radar_no_d1.py"],text=True,capture_output=True)
    print(p.stdout,flush=True)
    if p.stderr: print(p.stderr,flush=True)
    if p.returncode==0:
        commit_paths([str(EVENTS),str(PROCESSED),str(PROC)],"Actualizar estado radar editorial")
        print("RADAR_OK",slot,flush=True)
    else:
        print("RADAR_ERROR",slot,p.returncode,flush=True)

api("deleteWebhook",{"drop_pending_updates":False})
state=load_json(STATE,{})
offset=int(state.get("offset",0) or 0)
last_slot=""
print("TT_CONTROL_LISTENER_READY offset",offset,flush=True)

while time.time()<END:
    now=dt.datetime.now(dt.timezone.utc)
    slot=now.strftime("%Y%m%d%H%M")
    if now.minute in TARGET_MINUTES and slot!=last_slot:
        run_radar(slot); last_slot=slot
    params=urllib.parse.urlencode({"offset":offset,"timeout":20,"allowed_updates":json.dumps(["callback_query"])})
    try:
        with urllib.request.urlopen(f"{BASE}/getUpdates?{params}",timeout=25) as r:
            updates=json.loads(r.read().decode()).get("result",[])
    except Exception as e:
        print("GETUPDATES_ERROR",e,flush=True); time.sleep(2); continue
    for u in updates:
        cq=u.get("callback_query") or {}; msg=cq.get("message") or {}
        if str((msg.get("chat") or {}).get("id",""))!=CHAT:
            offset=max(offset,int(u["update_id"])+1); continue
        offset=persist_callback(u)
print("TT_CONTROL_LISTENER_RESTART",flush=True)
