import json,re,unicodedata,urllib.request,urllib.parse,html,os,hashlib
from pathlib import Path
from datetime import datetime,timezone,timedelta

SOURCES=[
("Europa Press","https://raw.githubusercontent.com/fabricelop/europapress-rss/main/recent.json","json"),
("EL PAÍS","https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/ultimas-noticias/portada","xml"),
("La Vanguardia","https://www.lavanguardia.com/rss/home.xml","xml"),
("Cadena SER","https://cadenaser.com/autor/redaccion_ser/a/","html"),
("RTVE","https://www.rtve.es/noticias/","html"),
("El HuffPost","https://www.huffingtonpost.es/feeds/index.xml","xml"),
("20minutos","https://www.20minutos.es/ultima-hora/","html"),
("ABC","https://www.abc.es/ultima-hora/","html"),
("COPE","https://www.cope.es/rss/home.xml","xml"),
("EFE","https://efe.com/espana/","html"),
("Servimedia","https://www.servimedia.es/ultima-hora","html"),
("elDiario.es","https://www.eldiario.es/ultimas-noticias/","html"),
("Público","https://www.publico.es/","html"),
("El Mundo","https://www.elmundo.es/ultimas-noticias.html","html")
]
TOTAL_SOURCES=len(SOURCES)
REVIEW_MIN=3
AUTO_MIN=5
WAIT_HOURS=12
MAX_PROCESSED=2000
STOP=set("a al algo ante bajo con contra de del desde el ella en entre era es esta este esto ha hay la las lo los mas muy no o para pero por que se sin sobre su sus un una y ya".split())
MATERIAL=set("muere muerto fallece fallecido dimite dimision detenido detencion sentencia condena absuelto absuelve gana ganador pierde derrota confirma confirmado acuerdo aprueba aprobado cancela cancelado rompe ruptura rescata rescatado desaparecido encontrado hospitalizado alta cesado cese nombrado nombramiento".split())

EVENTS=Path("telegram/events.json")
PROCESSED=Path("telegram/processed-events.json")
EDITORIAL=Path("telegram/editorial-processing.json")

def utcnow(): return datetime.now(timezone.utc)
def iso(d): return d.astimezone(timezone.utc).isoformat().replace("+00:00","Z")
def dtv(s):
 try:return datetime.fromisoformat(str(s).replace("Z","+00:00"))
 except:return datetime.min.replace(tzinfo=timezone.utc)
def load(path,default):
 try:
  raw=path.read_text(encoding="utf-8").strip()
  return json.loads(raw) if raw else default
 except:return default
def save(path,obj): path.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
def get(url):
 r=urllib.request.Request(url,headers={"User-Agent":"TTiTTulares-Radar/3.0"})
 return urllib.request.urlopen(r,timeout=20).read().decode("utf-8","ignore")
def clean(s): return re.sub(r"\s+"," ",html.unescape(re.sub("<[^>]+>"," ",str(s)))).strip()
def norm(s):
 s=''.join(c for c in unicodedata.normalize("NFKD",str(s).lower()) if not unicodedata.combining(c))
 return [x for x in re.findall(r"[a-z0-9]+",s) if len(x)>2 and x not in STOP]
def fp(s): return set(norm(s))
def score(a,b):
 A,B=fp(a),fp(b)
 if not A or not B:return 0
 inter=len(A&B)
 return max(inter/max(1,min(len(A),len(B))),inter/max(1,len(A|B)))
def make_id(title):
 return hashlib.sha1(" ".join(sorted(fp(title))).encode()).hexdigest()[:12]

def fetch_items():
 out=[];healthy=[]
 for src,url,kind in SOURCES:
  try:
   body=get(url);healthy.append(src)
   if kind=="json":
    j=json.loads(body);rows=j if isinstance(j,list) else j.get("items",[])
    for x in rows[:120]:
     t=str(x.get("title") or x.get("titulo") or "").strip();u=str(x.get("url") or x.get("link") or "")
     if t and u:out.append({"source":src,"title":t,"url":u})
   elif kind=="xml":
    for b in re.findall(r"<(?:item|entry)\b[\s\S]*?</(?:item|entry)>",body,re.I)[:80]:
     tm=re.search(r"<title[^>]*>([\s\S]*?)</title>",b,re.I)
     lm=re.search(r"<link[^>]*href=[\"']([^\"']+)",b,re.I) or re.search(r"<link[^>]*>([\s\S]*?)</link>",b,re.I)
     if tm and lm:
      t=clean(tm.group(1));u=clean(lm.group(1))
      if t and u:out.append({"source":src,"title":t,"url":u})
   else:
    n=0
    for u,t in re.findall(r"<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>([\s\S]*?)</a>",body,re.I):
     t=clean(t)
     if 35<=len(t)<=240:
      if u.startswith("/"):u=urllib.parse.urljoin(url,u)
      if u.startswith("http"):
       out.append({"source":src,"title":t,"url":u});n+=1
      if n>=60:break
  except Exception as e:print("SOURCE_FAIL",src,str(e))
 return out,healthy

def best_match(title,events,threshold=.50):
 best=None;bs=0
 for e in events:
  s=score(title,e.get("canonical_title") or e.get("title",""))
  for a in e.get("appearances",[])[-8:]:
   s=max(s,score(title,a.get("title","")))
  if s>bs:best=e;bs=s
 return (best,bs) if best and bs>=threshold else (None,bs)

def add_appearance(e,row,now):
 apps=e.setdefault("appearances",[])
 src=row["source"]
 same=next((a for a in apps if a.get("source")==src),None)
 if same:
  same.update({"title":row["title"],"url":row["url"],"last_seen":iso(now)})
 else:
  apps.append({"source":src,"title":row["title"],"url":row["url"],"first_seen":iso(now),"last_seen":iso(now)})
 e["sources"]=sorted({a["source"] for a in apps})
 e["source_count"]=len(e["sources"])
 e["percentage"]=round(100*e["source_count"]/TOTAL_SOURCES,1)
 e["last_seen"]=iso(now)
 if not e.get("url"):e["url"]=row["url"]

def processed_snapshot(e,kind,now,revision=None):
 return {
  "event_id":e["id"],"canonical_title":e["canonical_title"],"first_seen":e["first_seen"],
  "processed_at":iso(now),"kind":kind,"revision":revision or int(e.get("revision",1)),
  "sources":list(e.get("sources",[])),"source_count":e.get("source_count",0),
  "percentage":e.get("percentage",0),"fact_tokens":sorted(fp(e["canonical_title"])),
  "last_titles":[a.get("title","") for a in e.get("appearances",[])][-10:]
 }

def send_review(e,token,chat):
 txt=("📰 TTiTTulares · PARA VALORAR · "+str(e["source_count"])+"/"+str(TOTAL_SOURCES)+
      " ("+str(e["percentage"])+"%)\n\n"+e["canonical_title"]+"\n\nFuentes: "+", ".join(e["sources"]))
 buttons=[[{"text":"PREPARAR","callback_data":"emergency:prepare:"+e["id"]},{"text":"DESESTIMAR","callback_data":"emergency:dismiss:"+e["id"]}],
          [{"text":"ABRIR FUENTE","url":e["url"]}]]
 payload={"chat_id":chat,"text":txt,"disable_web_page_preview":True,"reply_markup":{"inline_keyboard":buttons}}
 req=urllib.request.Request("https://api.telegram.org/bot"+token+"/sendMessage",data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"})
 urllib.request.urlopen(req,timeout=15).read()

def queue_editorial(e,editorial,kind):
 items=editorial.setdefault("items",[])
 existing=next((x for x in items if str(x.get("event_id"))==str(e["id"]) and x.get("status")=="PROCESSING"),None)
 if existing:return
 items.append({
  "event_id":e["id"],"title":e["canonical_title"],"url":e["url"],"sources":e["sources"],
  "source_count":e["source_count"],"selected_at":iso(utcnow()),"status":"PROCESSING",
  "selection_mode":kind,"revision":int(e.get("revision",1)),
  "update_context":e.get("update_context")
 })

now=utcnow()
events_doc=load(EVENTS,{"version":3,"events":[]})
events=events_doc.get("events",[])
processed_doc=load(PROCESSED,{"version":1,"events":[]})
processed=processed_doc.get("events",[])
editorial=load(EDITORIAL,{"news":[],"items":[]})

# Migración suave de eventos antiguos.
for e in events:
 if "canonical_title" not in e:e["canonical_title"]=e.get("title","")
 if "appearances" not in e:
  e["appearances"]=[{"source":s,"title":e["canonical_title"],"url":e.get("url",""),"first_seen":e.get("first_seen"),"last_seen":e.get("last_seen")} for s in e.get("sources",[])]
 e["sources"]=sorted(set(e.get("sources",[])))
 e["source_count"]=len(e["sources"]);e["percentage"]=round(100*e["source_count"]/TOTAL_SOURCES,1)

# Solo WAITING caduca; lo ya tratado queda en processed-events.json.
cutoff=now-timedelta(hours=WAIT_HOURS)
events=[e for e in events if e.get("status")!="WAITING" or dtv(e.get("first_seen"))>=cutoff]

rows,healthy=fetch_items()
print("SOURCES_OK",len(set(healthy)),sorted(set(healthy)))
print("SOURCES_CONFIGURED",TOTAL_SOURCES)

# Index de procesadas como eventos sintéticos para reconocer ecos posteriores.
proc_index=[]
for p in processed:
 proc_index.append({"id":p.get("event_id"),"canonical_title":p.get("canonical_title",""),"appearances":[{"title":t} for t in p.get("last_titles",[])],"snapshot":p})

for row in rows:
 # 1) intentar agregar a evento activo.
 e,sc=best_match(row["title"],events,.50)
 if e:
  add_appearance(e,row,now);continue
 # 2) si coincide con una ya procesada, no recrearla; solo evaluar posible actualización.
 pe,psc=best_match(row["title"],proc_index,.50)
 if pe:
  snap=pe["snapshot"]
  seen_sources=set(snap.get("sources",[]))
  novelty=fp(row["title"])-set(snap.get("fact_tokens",[]))
  material_hint=bool(novelty&MATERIAL)
  new_source=row["source"] not in seen_sources
  key=str(snap.get("event_id"))
  upd=next((x for x in events if x.get("parent_event_id")==key and x.get("status")=="UPDATE_WAITING"),None)
  if not upd and new_source and (material_hint or len(novelty)>=3):
   rev=int(snap.get("revision",1))+1
   upd={"id":key+"-r"+str(rev),"parent_event_id":key,"revision":rev,"canonical_title":row["title"],"url":row["url"],
        "appearances":[],"sources":[],"source_count":0,"percentage":0,"first_seen":iso(now),"last_seen":iso(now),
        "status":"UPDATE_WAITING","notified":False,
        "update_context":{"previous_title":snap.get("canonical_title"),"previous_processed_at":snap.get("processed_at"),"candidate_reason":"Nuevos hechos/términos detectados; la redacción debe verificar si la actualización es material."}}
   events.append(upd)
  if upd:add_appearance(upd,row,now)
  continue
 # 3) evento nuevo.
 eid=make_id(row["title"])
 if any(x.get("id")==eid for x in events):eid=hashlib.sha1((eid+row["url"]).encode()).hexdigest()[:12]
 e={"id":eid,"canonical_title":row["title"],"url":row["url"],"appearances":[],"sources":[],"source_count":0,"percentage":0,
    "first_seen":iso(now),"last_seen":iso(now),"status":"WAITING","notified":False,"revision":1}
 add_appearance(e,row,now);events.append(e)

token=os.environ.get("TELEGRAM_BOT_TOKEN");chat=os.environ.get("TELEGRAM_CHAT_ID")
sent=0;auto=0;expired=0
new_processed=[]

for e in list(events):
 n=e.get("source_count",0)
 status=e.get("status")
 if status=="WAITING":
  if n>=AUTO_MIN:
   e["status"]="AUTO_PROCESSING";e["notified"]=True
   queue_editorial(e,editorial,"AUTO_SELECTED")
   new_processed.append(processed_snapshot(e,"AUTO_SELECTED",now))
   auto+=1
  elif n>=REVIEW_MIN:
   if token and chat:send_review(e,token,chat)
   e["status"]="SENT_REVIEW";e["notified"]=True
   new_processed.append(processed_snapshot(e,"SENT_REVIEW",now))
   sent+=1
 elif status=="UPDATE_WAITING":
  # Una actualización nunca se publica automáticamente por heurística.
  # Con 2 fuentes nuevas, pasa a redacción, que verificará si es material.
  if n>=2:
   e["status"]="UPDATE_VERIFY";e["notified"]=True
   queue_editorial(e,editorial,"UPDATE_VERIFY")
   new_processed.append(processed_snapshot(e,"UPDATE_VERIFY",now,e.get("revision",2)))
   auto+=1

# Eliminar WAITING caducadas tras la evaluación.
kept=[]
for e in events:
 if e.get("status")=="WAITING" and dtv(e.get("first_seen"))<cutoff:
  expired+=1
 else:kept.append(e)
events=kept

# Append-only lógico de procesadas por event_id+revision+kind.
keys={(str(x.get("event_id")),int(x.get("revision",1)),str(x.get("kind"))) for x in processed}
for p in new_processed:
 k=(str(p.get("event_id")),int(p.get("revision",1)),str(p.get("kind")))
 if k not in keys:processed.append(p);keys.add(k)
processed=processed[-MAX_PROCESSED:]

events_doc={"version":3,"configured_sources":TOTAL_SOURCES,"review_min_sources":REVIEW_MIN,"auto_min_sources":AUTO_MIN,
            "waiting_ttl_hours":WAIT_HOURS,"last_run":iso(now),"healthy_sources":sorted(set(healthy)),"events":events}
processed_doc={"version":1,"updated_at":iso(now),"events":processed}
save(EVENTS,events_doc);save(PROCESSED,processed_doc);save(EDITORIAL,editorial)
print("RESULT rows",len(rows),"active_events",len(events),"review_sent",sent,"auto_queued",auto,"expired",expired)
