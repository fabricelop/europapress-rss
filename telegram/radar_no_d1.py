import json,re,unicodedata,urllib.request,urllib.parse,html,os,hashlib
from pathlib import Path
from datetime import datetime,timezone,timedelta

SOURCES=[
("Europa Press","https://raw.githubusercontent.com/fabricelop/europapress-rss/main/recent.json","json"),
("EL PAÍS","https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/ultimas-noticias/portada","xml"),
("La Vanguardia","https://www.lavanguardia.com/rss/home.xml","xml"),
("Cadena SER","https://cadenaser.com/rss/","xml"),("RTVE","https://www.rtve.es/noticias/","html"),
("El HuffPost","https://www.huffingtonpost.es/feeds/index.xml","xml"),("20minutos","https://www.20minutos.es/ultima-hora/","html"),
("ABC","https://www.abc.es/ultima-hora/","html"),("COPE","https://www.cope.es/rss/home.xml","xml")]
STOP=set("a al algo ante bajo con contra de del desde el ella en entre era es esta este esto ha hay la las lo los mas muy no o para pero por que se sin sobre su sus un una y ya".split())
def get(url):
 r=urllib.request.Request(url,headers={"User-Agent":"TT-Control-Radar/2.0"});return urllib.request.urlopen(r,timeout=20).read().decode("utf-8","ignore")
def clean(s): return re.sub(r"\s+"," ",html.unescape(re.sub("<[^>]+>"," ",s))).strip()
def norm(s):
 s=''.join(c for c in unicodedata.normalize("NFKD",s.lower()) if not unicodedata.combining(c))
 return [x for x in re.findall(r"[a-z0-9áéíóúñü]+",s) if len(x)>2 and x not in STOP]
def fp(s): return set(norm(s))
def score(a,b):
 A,B=fp(a),fp(b)
 if not A or not B:return 0
 inter=len(A&B); return max(inter/max(1,min(len(A),len(B))),inter/max(1,len(A|B)))
def items():
 out=[]; healthy=[]
 for src,url,kind in SOURCES:
  try:
   body=get(url); healthy.append(src)
   if kind=="json":
    j=json.loads(body); rows=j if isinstance(j,list) else j.get("items",[])
    for x in rows[:80]:
     t=str(x.get("title") or x.get("titulo") or "").strip();u=str(x.get("url") or x.get("link") or "")
     if t and u:out.append((src,t,u))
   elif kind=="xml":
    for b in re.findall(r"<(?:item|entry)\b[\s\S]*?</(?:item|entry)>",body,re.I)[:50]:
     tm=re.search(r"<title[^>]*>([\s\S]*?)</title>",b,re.I); lm=re.search(r"<link[^>]*href=[\"']([^\"']+)",b,re.I) or re.search(r"<link[^>]*>([\s\S]*?)</link>",b,re.I)
     if tm and lm: out.append((src,clean(tm.group(1)),clean(lm.group(1))))
   else:
    n=0
    for u,t in re.findall(r"<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>([\s\S]*?)</a>",body,re.I):
     t=clean(t)
     if 35<=len(t)<=240:
      if u.startswith("/"): u=urllib.parse.urljoin(url,u)
      if u.startswith("http"):out.append((src,t,u));n+=1
      if n>=35:break
  except Exception as e: print("SOURCE_FAIL",src,str(e))
 return out,healthy
statep=Path("telegram/events.json")
raw=statep.read_text(encoding="utf-8").strip()
try:
 state=json.loads(raw)
except json.JSONDecodeError:
 state,_=json.JSONDecoder().raw_decode(raw)
 print("STATE_REPAIRED trailing JSON data ignored")
ev=state.get("events",[])
now=datetime.now(timezone.utc); cutoff=now-timedelta(hours=24)
ev=[e for e in ev if e.get("status") in ("PREPARED","EVALUATE","PUBLISHED","DISMISSED") or datetime.fromisoformat(e["last_seen"].replace("Z","+00:00"))>=cutoff]
rows,healthy_sources=items()
active_den=max(1,len(set(healthy_sources)))
print("SOURCES_OK",active_den,sorted(set(healthy_sources)))
for src,title,url in rows:
 best=None;bs=0
 for e in ev:
  s=score(title,e["title"])
  if s>bs:bs=s;best=e
 # Strict lexical anchor first; ambiguous 0.30-.49 remains separate rather than risky overmerge.
 if best and bs>=.50:
  if src not in best["sources"]:best["sources"].append(src)
  best["last_seen"]=now.isoformat().replace("+00:00","Z")
  best["source_count"]=len(best["sources"])
 else:
  key=hashlib.sha1((" ".join(sorted(fp(title)))+url.split("?")[0]).encode()).hexdigest()[:12]
  ev.append({"id":key,"title":title,"url":url,"sources":[src],"source_count":1,"first_seen":now.isoformat().replace("+00:00","Z"),"last_seen":now.isoformat().replace("+00:00","Z"),"status":"NEW","notified":False})
token=os.environ.get("TELEGRAM_BOT_TOKEN");chat=os.environ.get("TELEGRAM_CHAT_ID")
def send(e,status):
 txt=("📰 TT Control · "+("PREPARAR" if status=="PREPARED" else "PARA VALORAR")+" · "+str(e["source_count"])+"/"+str(active_den)+"\n\n"+e["title"]+"\n\nFuentes: "+", ".join(e["sources"]))
 buttons=[[{"text":"PREPARAR","callback_data":"emergency:prepare:"+e["id"]},{"text":"🗑️ BORRAR","callback_data":"delete:message"}]]
 buttons.append([{"text":"ABRIR FUENTE","url":e["url"]}])
 payload={"chat_id":chat,"text":txt,"disable_web_page_preview":True,"reply_markup":{"inline_keyboard":buttons}}
 req=urllib.request.Request("https://api.telegram.org/bot"+token+"/sendMessage",data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"})
 urllib.request.urlopen(req,timeout=15).read()
for e in ev:
 n=len(set(e["sources"]));e["source_count"]=n
 target="PREPARED" if n>=5 else ("EVALUATE" if n>=3 else "NEW")
 if e.get("status")=="NEW" and target!="NEW":
  e["status"]=target
  if not e.get("notified"):
   send(e,target);e["notified"]=True
state["events"]=ev[-500:];state["last_run"]=now.isoformat().replace("+00:00","Z")
statep.write_text(json.dumps(state,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print("items/events",len(ev))
