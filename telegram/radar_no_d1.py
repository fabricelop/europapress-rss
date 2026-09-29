import json, base64,re,unicodedata,urllib.request,urllib.parse,urllib.error,html,os,hashlib,concurrent.futures,sys
from functools import lru_cache
from itertools import combinations
from pathlib import Path
from datetime import datetime,timezone,timedelta
from source_telemetry import update_source_telemetry
from source_publication import feed_publication, enrich_html_rows

SOURCES=[
("Europa Press","https://www.europapress.es/noticias/","html"),
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
("El Mundo","https://www.elmundo.es/ultimas-noticias.html","html"),
("Antena 3 Noticias","https://www.antena3.com/noticias/ultimas-noticias/","html"),
("laSexta Noticias","https://www.lasexta.com/noticias/","html"),
("Onda Cero","https://www.ondacero.es/noticias/","html"),
("Telecinco Noticias","https://www.telecinco.es/noticias/","html"),
("Noticias Cuatro","https://www.cuatro.com/noticias/","html")
]
SPORT_SOURCES=[
("AS","https://as.com/ultimas-noticias/","html"),
("MARCA","https://www.marca.com/","html"),
("Mundo Deportivo","https://www.mundodeportivo.com/","html"),
("SPORT","https://www.sport.es/es/","html"),
("EFE Deportes","https://efe.com/deportes/","html")
]
# Fuentes internacionales suplementarias SOLO para detección y agrupación.
# No cuentan para el umbral de 4 ni alteran el 14/14 de fuentes generales.
DISCOVERY_SOURCES=[
("Reuters Radar","https://news.google.com/rss/search?q=site%3Areuters.com&hl=es&gl=ES&ceid=ES:es","xml"),
("AP Radar","https://news.google.com/rss/search?q=site%3Aapnews.com&hl=es&gl=ES&ceid=ES:es","xml"),
("Público · Tremending","https://www.publico.es/tremending/","html")
]
DISCOVERY_SOURCE_KINDS={"Público · Tremending":"social"}
SOURCE_DOMAINS={
 "Europa Press":"europapress.es",
 "EL PAÍS":"elpais.com",
 "La Vanguardia":"lavanguardia.com",
 "Cadena SER":"cadenaser.com",
 "RTVE":"rtve.es",
 "El HuffPost":"huffingtonpost.es",
 "20minutos":"20minutos.es",
 "ABC":"abc.es",
 "COPE":"cope.es",
 "EFE":"efe.com",
 "Servimedia":"servimedia.es",
 "elDiario.es":"eldiario.es",
 "Público":"publico.es",
 "El Mundo":"elmundo.es",
 "Antena 3 Noticias":"antena3.com",
 "laSexta Noticias":"lasexta.com",
 "Onda Cero":"ondacero.es",
 "Telecinco Noticias":"telecinco.es",
 "Noticias Cuatro":"cuatro.com",
 "AS":"as.com",
 "MARCA":"marca.com",
 "Mundo Deportivo":"mundodeportivo.com",
 "SPORT":"sport.es",
 "EFE Deportes":"efe.com"
}
def google_news_fallback(src):
 domain=SOURCE_DOMAINS.get(src)
 if not domain:return None
 q=urllib.parse.quote("site:"+domain)
 return "https://news.google.com/rss/search?q="+q+"&hl=es&gl=ES&ceid=ES:es"

def google_news_recovery(src,hours=24):
 # Ventana retrospectiva explícita por CADA una de las 14 fuentes.
 # Sirve para recuperar huecos del scheduler aunque la portada/RSS actual
 # ya haya desplazado noticias publicadas durante el parón.
 domain=SOURCE_DOMAINS.get(src)
 if not domain:return None
 q=urllib.parse.quote("site:"+domain+" when:"+str(int(hours))+"h")
 return "https://news.google.com/rss/search?q="+q+"&hl=es&gl=ES&ceid=ES:es"

SOURCE_FALLBACKS={
 "Europa Press":["https://raw.githubusercontent.com/fabricelop/europapress-rss/main/recent.json"],
 "EL PAÍS":["https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/ultimas-noticias/portada","https://elpais.com/ultimas-noticias/"],
 "La Vanguardia":["https://www.lavanguardia.com/rss/home.xml","https://www.lavanguardia.com/"],
 "Cadena SER":["https://cadenaser.com/","https://cadenaser.com/nacional/","https://cadenaser.com/autor/redaccion_ser/a/"],
 "RTVE":["https://www.rtve.es/rss/temas_noticias.xml","https://www.rtve.es/noticias/"],
 "El HuffPost":["https://www.huffingtonpost.es/feeds/index.xml","https://www.huffingtonpost.es/"],
 "20minutos":["https://www.20minutos.es/ultima-hora/","https://www.20minutos.es/"],
 "ABC":["https://www.abc.es/ultima-hora/","https://www.abc.es/"],
 "COPE":["https://www.cope.es/rss/home.xml","https://www.cope.es/"],
 "EFE":["https://efe.com/espana/feed/","https://efe.com/espana/","https://efe.com/"],
 "Servimedia":["https://www.servimedia.es/ultima-hora","https://www.servimedia.es/"],
 "elDiario.es":["https://www.eldiario.es/ultimas-noticias/","https://www.eldiario.es/rss/","https://www.eldiario.es/"],
 "Público":["https://www.publico.es/","https://www.publico.es/rss"],
 "El Mundo":["https://www.elmundo.es/ultimas-noticias.html","https://www.elmundo.es/"],
 "Antena 3 Noticias":["https://www.antena3.com/noticias/ultimas-noticias/","https://www.antena3.com/noticias/"],
 "laSexta Noticias":["https://www.lasexta.com/noticias/","https://www.lasexta.com/temas/noticias_ultima_hora-1"],
 "Onda Cero":["https://www.ondacero.es/noticias/","https://www.ondacero.es/noticias/espana/"],
 "Telecinco Noticias":["https://www.telecinco.es/noticias/","https://www.telecinco.es/ultimas-noticias/"],
 "Noticias Cuatro":["https://www.cuatro.com/noticias/","https://www.cuatro.com/"],
 "Público · Tremending":["https://www.publico.es/tremending/"],
 "AS":["https://as.com/ultimas-noticias/","https://as.com/"],
 "MARCA":["https://www.marca.com/","https://www.marca.com/futbol.html"],
 "Mundo Deportivo":["https://www.mundodeportivo.com/","https://www.mundodeportivo.com/futbol"],
 "SPORT":["https://www.sport.es/es/","https://www.sport.es/es/futbol/"],
 "EFE Deportes":["https://efe.com/deportes/feed/","https://efe.com/deportes/"]
}

SOURCE_FAMILIES={
 "Antena 3 Noticias":"Atresmedia",
 "laSexta Noticias":"Atresmedia",
 "Onda Cero":"Atresmedia",
 "Telecinco Noticias":"Mediaset",
 "Noticias Cuatro":"Mediaset",
 "Público · Tremending":"Público",
}
def source_family(src): return SOURCE_FAMILIES.get(src,src)

TOTAL_SOURCES=len(SOURCES)
TOTAL_SOURCE_FAMILIES=len({source_family(name) for name,_,_ in SOURCES})
REVIEW_MIN=4
FAST_TRACK_MIN=4
FAST_TRACK_WINDOW_MIN=30
WAIT_HOURS=24
MIN_HEALTHY_SOURCES=14
MAX_PROCESSED=2000
STOP=set("a al algo ante bajo con contra de del desde el ella en entre era es esta este esto ha hay la las lo los mas muy no o para pero por que se sin sobre su sus un una y ya".split())
MATERIAL=set("muere muerto fallece fallecido dimite dimision detenido detencion sentencia condena absuelto absuelve gana ganador pierde derrota confirma confirmado acuerdo aprueba aprobado cancela cancelado rompe ruptura rescata rescatado desaparecido encontrado hospitalizado alta cesado cese nombrado nombramiento".split())

EVENTS=Path("telegram/events.json")
PROCESSED=Path("telegram/processed-events.json")
EDITORIAL_PROCESSING=Path("telegram/editorial-processing.json")
PREPARED=Path("ttittulares/prepared.json")
DECISIONS=Path("ttittulares/decisions.json")
CONTROL_MODE=Path("ttittulares/control-mode.json")

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
def save(path,obj):
 data=json.dumps(obj,ensure_ascii=False,indent=2)+"\n"
 if path==EVENTS and (not isinstance(obj,dict) or not isinstance(obj.get("events"),list)):
  raise RuntimeError("Estado events.json inválido: no se escribirá")
 tmp=path.with_suffix(path.suffix+".tmp")
 tmp.write_text(data,encoding="utf-8")
 tmp.replace(path)
def get(url,timeout=12):
 headers={
  "User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151 Safari/537.36",
  "Accept":"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language":"es-ES,es;q=0.9,en;q=0.7"
 }
 r=urllib.request.Request(url,headers=headers)
 return urllib.request.urlopen(r,timeout=timeout).read().decode("utf-8","ignore")
def clean(s): return re.sub(r"\s+"," ",html.unescape(re.sub("<[^>]+>"," ",str(s)))).strip()
# Regression guard: Macklemore/Free Palestine vs protesta de Ed Sheeran (2026-09-24)
TOKEN_ALIASES={
 "frontera":"frontera","fronteras":"frontera","fronterizo":"frontera","fronteriza":"frontera","fronterizos":"frontera","fronterizas":"frontera",
 "pide":"pedir","pidio":"pedir","pedir":"pedir","pedido":"pedir","pidiendo":"pedir","solicita":"pedir","solicito":"pedir",
 "explicacion":"explicacion","explicaciones":"explicacion","respuesta":"explicacion","respuestas":"explicacion",
 "falla":"fallar","fallo":"fallar","fallar":"fallar","fallido":"fallar","fallida":"fallar","fallaron":"fallar",
 "detenido":"detener","detenida":"detener","detencion":"detener","detenciones":"detener",
 "muere":"morir","murio":"morir","muerto":"morir","muerta":"morir","fallece":"morir","fallecio":"morir",
 "cerrada":"cerrar","cerrado":"cerrar","cierra":"cerrar","cierre":"cerrar",
 "sanidad":"salud","salud":"salud",
 "australia":"australia","australiana":"australia","australiano":"australia","australianas":"australia","australianos":"australia",
 "autorizacion":"permiso","autorizado":"permiso","autorizada":"permiso","permiso":"permiso",
 "accede":"acceder","accedio":"acceder","acceder":"acceder","hackeo":"acceder","hackear":"acceder","cuela":"acceder","colarse":"acceder",
 # Equivalencias ES/EN y de formato para el mismo hecho cultural. Son deliberadamente
 # estrechas: ayudan a unir coberturas traducidas sin relajar los umbrales globales.
 "palestine":"palestina",
 "tour":"gira","tours":"gira",
 # Variantes frecuentes que estaban fragmentando el mismo acontecimiento entre medios.
 "caza":"caza","cazas":"caza",
 "dron":"dron","drones":"dron",
 "espanol":"espanol","espanoles":"espanol","espanola":"espanol","espanolas":"espanol","espaoles":"espanol","espaola":"espanol",
 "rumania":"rumania","rumana":"rumania","rumano":"rumania",
 "ruso":"ruso","rusos":"ruso","rusa":"ruso","rusas":"ruso",
 "malaga":"malaga","malagueno":"malaga","malaguena":"malaga","malagueño":"malaga","malagueña":"malaga",
 "confina":"confinar","confinan":"confinar","confinado":"confinar","confinada":"confinar","confinamiento":"confinar","confinar":"confinar",
 "moviliza":"movilizar","movilizan":"movilizar","movilizado":"movilizar","movilizados":"movilizar","movilizar":"movilizar",
 "activa":"activar","activan":"activar","activar":"activar","despliega":"desplegar","despliegan":"desplegar","desplegar":"desplegar",
}
EVENT_ACTION_ALIASES={
 "reunion":"reunion","reunirse":"reunion","reunen":"reunion","reune":"reunion","renen":"reunion","encuentro":"reunion","entrevista":"reunion",
 "cumbre":"reunion","recibe":"reunion","recibir":"reunion","visita":"reunion","recibimiento":"reunion",
 "firmar":"acuerdo","firma":"acuerdo","acuerdo":"acuerdo","pacto":"acuerdo",
 "demandar":"demanda","demanda":"demanda","denunciar":"denuncia","denuncia":"denuncia",
 "detener":"detencion","detenido":"detencion","detenida":"detencion","arresto":"detencion",
 "morir":"muerte","muere":"muerte","fallecer":"muerte","fallece":"muerte",
 "dimitir":"dimision","dimite":"dimision","renunciar":"dimision","renuncia":"dimision","cese":"dimision","cesar":"dimision","relevo":"dimision","abandona":"dimision","abandonar":"dimision",
 "ganar":"victoria","gana":"victoria","vencer":"victoria","vence":"victoria",
 "perder":"derrota","pierde":"derrota","derrota":"derrota",
 "aprobar":"aprobacion","aprueba":"aprobacion","avalar":"aprobacion","avala":"aprobacion",
 "prohibir":"prohibicion","prohibe":"prohibicion","vetar":"prohibicion","veta":"prohibicion",
 "movilizar":"movilizacion","desplegar":"movilizacion",
 "confinar":"confinamiento",
}
@lru_cache(maxsize=50000)
def event_actions(s):
 out=set()
 tokens=set(norm(s))
 for x in tokens:
  if x in EVENT_ACTION_ALIASES: out.add(EVENT_ACTION_ALIASES[x])
 # "activar" es demasiado genérico por sí solo (activar una operación, alarma,
 # protocolo...). Solo equivale a movilización si el propio titular habla de
 # cazas/F-18/fuerzas militares.
 if "activar" in tokens and ({"caza","f18","fuerza","avion"} & tokens):
  out.add("movilizacion")
 return out

PROPER_GENERIC={"nueva","york","estados","unidos","casa","blanca","onu","europa","espana","gobierno","congreso","senado"}
@lru_cache(maxsize=50000)
def proper_tokens(s):
 out=set()
 for raw in re.findall(r"\b[A-ZÁÉÍÓÚÜÑ][A-Za-zÁÉÍÓÚÜÑáéíóúüñ]{1,}\b",str(s)):
  tok="".join(c for c in unicodedata.normalize("NFKD",raw.lower()) if not unicodedata.combining(c))
  tok=TOKEN_ALIASES.get(tok,tok)
  if tok not in STOP and tok not in PROPER_GENERIC and tok not in GENERIC_MATCH: out.add(tok)
 return out

def same_event_semantic(a,b):
 # Dos nombres propios compartidos son la primera barrera. A partir de ahí,
 # aceptamos la misma acción canónica o un solapamiento léxico distintivo fuerte.
 # Esto une reformulaciones muy diferentes del mismo hecho (p. ej. una cabecera
 # habla de "llegada" y otra de "alfombra roja") sin mezclar sucesos genéricos.
 common=proper_tokens(a)&proper_tokens(b)
 distinctive=(fp(a)&fp(b))-GENERIC_MATCH
 common_actions=event_actions(a)&event_actions(b)
 if len(common)>=2 and common_actions:
  return True
 if len(common)>=2 and len(distinctive)>=3:
  return True
 # Un único nombre propio + la misma acción canónica + tres anclas concretas
 # permite unir titulares muy reformulados sin convertir un tema general en evento.
 if len(common)>=1 and common_actions and len(distinctive)>=3:
  return True
 # Un único nombre propio también basta cuando hay muchas anclas concretas
 # compartidas; útil para titulares que traducen/reformulan el mismo incidente.
 if len(common)>=1 and len(distinctive)>=5:
  return True
 return False

@lru_cache(maxsize=50000)
def norm(s):
 s=''.join(c for c in unicodedata.normalize("NFKD",str(s).lower()) if not unicodedata.combining(c))
 # "F-18", "F 18" y "F18" deben ser la misma ancla; el tokenizador anterior
 # perdía la variante con guion al separar "f" y "18".
 s=re.sub(r"\bf\s*[- ]\s*18\b","f18",s)
 out=[]
 for x in re.findall(r"[a-z0-9]+",s):
  if len(x)<=2 or x in STOP: continue
  out.append(TOKEN_ALIASES.get(x,x))
 return out
@lru_cache(maxsize=50000)
def fp(s): return frozenset(norm(s))
GENERIC_MATCH=set("""
morir hombre mujer persona personas anos herido herida heridos heridas incendio forestal
detener detenido detenida caer tres dos uno noticia ultima directo crisis actualidad
nueva york reunion encuentro reunir reunirse delegacion
""".split())
def score(a,b):
 A,B=fp(a),fp(b)
 if not A or not B:return 0
 common=A&B
 inter=len(common)
 if inter<2:return 0
 # No basta con compartir una plantilla de sucesos ("muere un hombre ... incendio").
 # En títulos medianos/largos exigimos al menos dos anclas concretas comunes:
 # lugar, protagonista, institución, objeto específico, etc.
 distinctive=common-GENERIC_MATCH
 if min(len(A),len(B))>=5 and len(distinctive)<2:return 0
 overlap=inter/max(1,min(len(A),len(B)))
 jaccard=inter/max(1,len(A|B))
 if min(len(A),len(B))<=4 and overlap<0.60:return 0
 if inter==2 and overlap<0.80:return 0
 if overlap<0.65 and jaccard<0.35:return 0
 return 0.55*overlap+0.45*jaccard
def make_id(title):
 return hashlib.sha1(" ".join(sorted(fp(title))).encode()).hexdigest()[:12]

SPORT_IMPORTANT=[
 "mundial","eurocopa","champions","europa league","conference league","laliga","liga de campeones",
 "copa del rey","supercopa","seleccion espanola","espana","real madrid","barcelona","atletico de madrid",
 "alcaraz","sinner","djokovic","nadal","wimbledon","roland garros","us open","australian open","masters 1000",
 "formula 1","f1","motogp","marquez","alonso","sainz","ciclismo","tour de france","giro","vuelta a espana",
 "pogacar","vingegaard","evenepoel","juegos olimpicos","olimpicos","mundial de atletismo","record mundial",
 "nba","euroliga","acb","real madrid baloncesto","barcelona baloncesto","copa davis","billie jean king",
 "fallece","muere","lesion grave","retirada","sancion","dopaje","record","campeon","campeona","titulo mundial"
]
SPORT_MINOR=[
 "segunda division","laliga hypertmotion","primera rfef","segunda rfef","tercera rfef","juvenil","cadete",
 "grupo 1","grupo 2","grupo 3","grupo 4","grupo 5","resultados, partidos y clasificacion","resultados y clasificacion"
]
def sport_important(title):
 n=" ".join(norm(title))
 if any(x in n for x in SPORT_MINOR): return False
 return any(x in n for x in SPORT_IMPORTANT)

def parse_source(src,url,kind,sport=False,recovery=False):
 gn=google_news_fallback(src)
 if recovery:
  urls=[gn] if gn else []
 else:
  urls=[url]+[u for u in SOURCE_FALLBACKS.get(src,[]) if u!=url]
  # Añadimos SIEMPRE una ventana retrospectiva de 24 h de la MISMA fuente.
  # No cuenta como fuente adicional: conserva src y solo amplía cobertura.
  # Así un parón del scheduler no pierde titulares que ya salieron de portada.
  recovery_url=google_news_recovery(src,24)
  if recovery_url and recovery_url not in urls: urls.append(recovery_url)
  # Si además falla el origen, queda el fallback general de la misma fuente.
  if gn and gn not in urls: urls.append(gn)
 last=None
 for candidate in urls:
  try:
   body=get(candidate); out=[]
   effective_kind="xml" if (candidate.rstrip("/").endswith("/feed") or candidate.endswith("/feed/") or candidate.lower().endswith(".xml") or re.search(r"<(?:rss|feed)\b",body[:1000],re.I)) else kind
   if effective_kind=="json":
    j=json.loads(body);rows=j if isinstance(j,list) else j.get("items",[])
    for x in rows[:120]:
     t=str(x.get("title") or x.get("titulo") or "").strip();u=str(x.get("url") or x.get("link") or "")
     if t and u and (not sport or sport_important(t)):out.append({"source":src,"title":t,"url":u,"source_type":"sport" if sport else "general"})
   elif effective_kind=="xml":
    for b in re.findall(r"<(?:item|entry)\b[\s\S]*?</(?:item|entry)>",body,re.I)[:100]:
     tm=re.search(r"<title[^>]*>([\s\S]*?)</title>",b,re.I)
     lm=re.search(r"<link[^>]*href=[\"']([^\"']+)",b,re.I) or re.search(r"<link[^>]*>([\s\S]*?)</link>",b,re.I)
     if tm and lm:
      t=clean(tm.group(1));u=clean(lm.group(1))
      if "news.google.com" in candidate:
       t=re.sub(r"\\s+-\\s+[^-]{2,80}$","",t).strip()
      if t and u and (not sport or sport_important(t)):
       row={"source":src,"title":t,"url":u,"source_type":"sport" if sport else "general"}
       # Google News's pubDate is an aggregation timestamp, not the publisher's.
       # Only use date metadata in a direct publisher RSS/Atom feed.
       if urllib.parse.urlparse(candidate).hostname not in {"news.google.com"}:
        published=feed_publication(b)
        if published:
         row["published_at"]=published
         row["publication_date_source"]="publisher_feed"
       out.append(row)
   else:
    n=0
    for u,t in re.findall(r"<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>([\s\S]*?)</a>",body,re.I):
     t=clean(t)
     if 35<=len(t)<=240:
      if u.startswith("/"):u=urllib.parse.urljoin(candidate,u)
      if u.startswith("http") and (not sport or sport_important(t)):
       out.append({"source":src,"title":t,"url":u,"source_type":"sport" if sport else "general"});n+=1
      if n>=80:break
   if out:
    # For publisher HTML listings, retrieve the original publication metadata
    # of up to three directly linked articles. Never use the listing poll time.
    # Failure here is telemetry-only and cannot block article retrieval.
    if effective_kind=="html":
     enrich_html_rows(out,SOURCE_DOMAINS.get(src),get,limit=3)
    return src,out,candidate,None
   last="0 artículos extraídos en "+candidate
  except Exception as e:last=str(e)
 return src,[],None,last

def fetch_items():
 out=[];healthy=[];sport_healthy=[];failures=[];source_status=[]
 jobs=[]
 with concurrent.futures.ThreadPoolExecutor(max_workers=len(SOURCES)+len(SPORT_SOURCES)+len(DISCOVERY_SOURCES)) as ex:
  for spec in SOURCES: jobs.append(("general",ex.submit(parse_source,*spec,False,False)))
  for spec in SPORT_SOURCES: jobs.append(("sport",ex.submit(parse_source,*spec,True,False)))
  for spec in DISCOVERY_SOURCES: jobs.append(("discovery",ex.submit(parse_source,*spec,False,False)))
  for source_type,fut in jobs:
   try:
    src,rows,used,err=fut.result()
    if source_type=="discovery":
     subtype=DISCOVERY_SOURCE_KINDS.get(src,"discovery")
     for row in rows: row["source_type"]=subtype
     if used and rows:
      out.extend(rows)
      source_status.append({"source":src,"type":subtype,"ok":True,"items":len(rows),"url":used,"error":None,"recovered":False})
      print("DISCOVERY_STATUS",src,"OK",len(rows),used)
     else:
      source_status.append({"source":src,"type":subtype,"ok":False,"items":0,"url":used,"error":err or "0 artículos extraídos","recovered":False})
      print("DISCOVERY_STATUS",src,"FAIL",err or "0 artículos extraídos")
     continue
    is_sport=source_type=="sport"
    if used and rows:
     (sport_healthy if is_sport else healthy).append(src)
     out.extend(rows)
     primary=next((u for n,u,k in (SPORT_SOURCES if is_sport else SOURCES) if n==src),used)
     recovered=used!=primary
     source_status.append({"source":src,"type":"sport" if is_sport else "general","ok":True,"items":len(rows),"url":used,"error":None,"recovered":recovered})
     print("SOURCE_STATUS",src,"OK",len(rows),used)
     if recovered:
      print("SOURCE_RECOVERED",src,used)
    else:
     failures.append({"source":src,"type":"sport" if is_sport else "general","error":err or "0 artículos extraídos"})
     source_status.append({"source":src,"type":"sport" if is_sport else "general","ok":False,"items":0,"url":used,"error":err or "0 artículos extraídos"})
     print("SOURCE_STATUS",src,"FAIL",err or "0 artículos extraídos")
   except Exception as e:
    print("SOURCE_FAIL_WORKER",source_type,str(e))

 recovered_names=[x["source"] for x in source_status if x.get("recovered")]
 failed_names=[x["source"] for x in source_status if not x.get("ok")]
 recovery={
  "triggered": bool(recovered_names or failed_names),
  "threshold": MIN_HEALTHY_SOURCES,
  "attempted": sorted(set(recovered_names+failed_names)),
  "recovered": recovered_names,
  "remaining_failed": failed_names,
  "mode": "inline_parallel_fallback",
 }
 # No hay una segunda fase bloqueante de reparación. Cada fuente prueba sus
 # alternativas dentro de su worker concurrente; el resto del radar sigue.
 return out,sorted(set(healthy)),sorted(set(sport_healthy)),failures,source_status,recovery

def title_match_value(a,b):
 s=score(a,b)
 if same_event_semantic(a,b):s=max(s,.72)
 return s

def best_match(title,events,threshold=.50):
 best=None;bs=0
 for e in events:
  canonical=e.get("canonical_title") or e.get("title","")
  canonical_score=title_match_value(title,canonical)
  variant_scores=[title_match_value(title,a.get("title","")) for a in e.get("appearances",[])[-8:] if a.get("title")]
  hits=[s for s in variant_scores if s>=threshold]
  # Evitar el efecto cadena: cuando un evento ya tiene varias cabeceras, un
  # titular nuevo no entra solo por parecerse a UNA aparición periférica.
  # Debe coincidir con el título representativo o con al menos dos cabeceras.
  if len(variant_scores)>=3 and canonical_score<threshold and len(hits)<2:
   s=0
  else:
   s=max([canonical_score]+variant_scores+[0])
  if s>bs:best=e;bs=s
 return (best,bs) if best and bs>=threshold else (None,bs)

def add_appearance(e,row,now):
 apps=e.setdefault("appearances",[])
 src=row["source"]
 source_type=row.get("source_type","general")
 same=next((a for a in apps if a.get("source")==src),None)
 if same:
  same.update({"title":row["title"],"url":row["url"],"last_seen":iso(now)})
 else:
  apps.append({"source":src,"source_type":source_type,"title":row["title"],"url":row["url"],"first_seen":iso(now),"last_seen":iso(now)})
 recalc_event_sources(e)
 e["last_seen"]=iso(now)
 if not e.get("url"):e["url"]=row["url"]

def titles_match(a,b):
 return score(a,b)>=0.50 or same_event_semantic(a,b)

def evidence_title_eligible(title):
 tokens=fp(title);distinctive=tokens-GENERIC_MATCH
 lowered=" ".join(norm(title))
 # Etiquetas de sección, portadas y titulares temáticos genéricos no corroboran
 # por sí solos un acontecimiento concreto. "Última hora" sí puede encabezar
 # un titular específico y no debe invalidar el resto de su evidencia.
 if len(tokens)<5 or len(distinctive)<3:return False
 if lowered.startswith(("portada ","noticias ","guerra ")):return False
 return True

def has_independent_evidence_consensus(e,min_families):
 # Cruzar el umbral exige un subconjunto conectado de familias independientes,
 # no una clique perfecta. Una clique bloqueaba paráfrasis inequívocas porque
 # dos titulares periféricos pueden describir el mismo hecho con vocabularios
 # distintos. Conservamos una barrera contra el efecto cadena: para cuatro
 # fuentes exigimos al menos cuatro coincidencias, o una estrella completa con
 # una ancla distintiva compartida por los cuatro titulares.
 apps=[a for a in e.get("appearances",[]) if a.get("source_type","general")=="general" and a.get("source") and evidence_title_eligible(a.get("title",""))]
 if len({source_family(a["source"]) for a in apps})<min_families:return False
 for group in combinations(apps,min_families):
  if len({source_family(a["source"]) for a in group})!=min_families:continue
  edges=[];degree=[0]*len(group)
  for i,j in combinations(range(len(group)),2):
   if titles_match(group[i].get("title",""),group[j].get("title","")):
    edges.append((i,j));degree[i]+=1;degree[j]+=1
  if len(edges)>=min_families:return True
  if len(edges)==min_families-1 and max(degree)==min_families-1:
   shared=set.intersection(*(set(fp(a.get("title","")))-GENERIC_MATCH for a in group))
   if any(len(token)>=5 for token in shared):return True
 return False

def run_grouping_regressions():
 def event(rows):return {"appearances":[{"source":s,"source_type":"general","title":t} for s,t in rows]}
 ceuta=event([
  ("EL PAÍS","El Gobierno ultima el cese del delegado en Ceuta"),
  ("laSexta Noticias","El Ejecutivo ultima el cese del delegado del Gobierno en Ceuta"),
  ("Público","El delegado del Gobierno en Ceuta abandona el cargo"),
  ("Europa Press","El Gobierno prepara el relevo del delegado del Gobierno en Ceuta tras comunicar su deseo de no continuar en el cargo"),
 ])
 kyiv=event([
  ("Europa Press","Al menos dos muertos y ocho heridos en Kiev tras otra noche de ataques rusos con drones y misiles"),
  ("laSexta Noticias","Rusia boicotea ayuda humanitaria a la ciudad ocupada de Oleshki y dispara el riesgo de hambruna"),
  ("EFE","Guerra de Ucrania"),
  ("La Vanguardia","¿Estamos en guerra?"),
 ])
 generic=event([
  ("El Mundo","Portada de EL MUNDO del lunes 28 de septiembre de 2026"),
  ("20minutos","Tu horóscopo diario: lunes 28 de septiembre de 2026"),
  ("Europa Press","El tiempo en La Rioja para hoy, lunes 28 de septiembre de 2026"),
  ("Antena 3 Noticias","Noticias de hoy, domingo 27 de septiembre de 2026"),
 ])
 gabieto=event([
  ("elDiario.es","Hallan muerto cerca del pico Gabieto a un montañero de Castellón desaparecido en Francia"),
  ("ABC","Localizan el cadáver del montañero de Castellón desaparecido en el Pico Gabieto de Huesca"),
  ("Telecinco Noticias","Encuentran muerto en el pico Gabieto a un montañero que desapareció en Francia"),
  ("20minutos","Muere un montañero de 69 años tras caer desde 200 metros en el pico Gabieto"),
 ])
 ultima_hora=event([
  ("20minutos","La Policía inicia el desalojo de la playa Benítez y el traslado de los inmigrantes"),
  ("ABC","La Policía desmantela el asentamiento de inmigrantes en la playa de Benítez en Ceuta"),
  ("Público","La Policía inicia el desalojo de los migrantes de la playa de Benítez en Ceuta"),
  ("Antena 3 Noticias","Última hora de la crisis migratoria en Ceuta: comienza el desalojo de la playa Benítez"),
 ])
 mixed=event([
  ("20minutos","Almeida celebra la vuelta de Maricarmen a su casa con intermediación del Ayuntamiento"),
  ("COPE","Antonio Jiménez comenta la vuelta de Maricarmen a casa y critica a Sánchez, Almeida y Ayuso"),
  ("Público","Activistas por la vivienda protestan contra Ayuso y Almeida en Madrid"),
  ("Onda Cero","El Ayuntamiento de Madrid rechazó una vivienda ofrecida por Urbagestión"),
 ])
 if not has_independent_evidence_consensus(ceuta,4):raise RuntimeError("Regresión: el caso Ceuta debería ser coherente")
 if not has_independent_evidence_consensus(gabieto,4):raise RuntimeError("Regresión: las paráfrasis de Gabieto deberían ser coherentes")
 if not has_independent_evidence_consensus(ultima_hora,4):raise RuntimeError("Regresión: un prefijo de última hora no invalida evidencia específica")
 if has_independent_evidence_consensus(kyiv,4):raise RuntimeError("Regresión: se mezclaron hechos distintos sobre Ucrania")
 if has_independent_evidence_consensus(generic,4):raise RuntimeError("Regresión: se mezclaron portada, horóscopo y tiempo")
 if has_independent_evidence_consensus(mixed,4):raise RuntimeError("Regresión: se mezclaron ángulos distintos de vivienda")

run_grouping_regressions()

def event_variants(e):
 out=[e.get("canonical_title","")]
 out.extend(a.get("title","") for a in e.get("appearances",[]) if a.get("title"))
 return [x for x in out if x]

def events_match(e,k):
 # El canónico representativo puede unir directamente dos fragmentos.
 if titles_match(e.get("canonical_title",""),k.get("canonical_title","")):
  return True
 # Si no, exigimos dos apoyos cruzados cuando hay suficiente evidencia.
 # Así evitamos fusionar dos historias enteras por una única cabecera puente.
 matches=0
 for a in event_variants(e)[-10:]:
  for b in event_variants(k)[-10:]:
   if titles_match(a,b):
    matches+=1
    if matches>=2:return True
 return False

def choose_representative_title(e):
 apps=[a for a in e.get("appearances",[]) if a.get("title")]
 if len(apps)<2:return
 best=None
 for a in apps:
  title=a.get("title","")
  support=0
  strength=0.0
  for b in apps:
   if a is b:continue
   other=b.get("title","")
   s=score(title,other)
   semantic=same_event_semantic(title,other)
   if s>=0.50 or semantic:
    support+=1
    strength+=max(s,0.72 if semantic else 0)
  key=(support,round(strength,4),len(title))
  if best is None or key>best[0]:
   best=(key,a)
 if best and best[0][0]>=1:
  chosen=best[1]
  e["canonical_title"]=chosen.get("title") or e.get("canonical_title","")
  if chosen.get("url"):e["url"]=chosen["url"]

def recalc_event_sources(e):
 apps=e.get("appearances",[])
 e["sources"]=sorted({a["source"] for a in apps if a.get("source_type","general")=="general"})
 e["sport_sources"]=sorted({a["source"] for a in apps if a.get("source_type")=="sport"})
 e["social_sources"]=sorted({a["source"] for a in apps if a.get("source_type")=="social"})
 e["discovery_sources"]=sorted({a["source"] for a in apps if a.get("source_type")=="discovery"})
 e["source_families"]=sorted({source_family(src) for src in e["sources"]})
 e["source_count"]=len(e["source_families"])
 e["outlet_count"]=len(e["sources"])
 e["sport_source_count"]=len(e["sport_sources"])
 e["percentage"]=round(100*e["source_count"]/TOTAL_SOURCE_FAMILIES,1)
 choose_representative_title(e)

def prune_event_outliers(e):
 # Si un evento tiene un núcleo de varias cabeceras conectadas y alguna
 # aparición aislada, eliminamos solo esos outliers. No se toca un evento de
 # 1-2 fuentes porque no hay evidencia suficiente para decidir cuál sobra.
 apps=list(e.get("appearances",[]))
 if len(apps)<3:return 0
 graph={i:set() for i in range(len(apps))}
 for i in range(len(apps)):
  for j in range(i+1,len(apps)):
   if titles_match(apps[i].get("title",""),apps[j].get("title","")):
    graph[i].add(j);graph[j].add(i)
 seen=set();components=[]
 for i in range(len(apps)):
  if i in seen:continue
  stack=[i];comp=set()
  while stack:
   x=stack.pop()
   if x in comp:continue
   comp.add(x);seen.add(x);stack.extend(graph[x]-comp)
  components.append(comp)
 components.sort(key=len,reverse=True)
 core=components[0] if components else set()
 if len(core)<2 or len(core)*2<=len(apps):return 0
 kept=[apps[i] for i in sorted(core)]
 removed=len(apps)-len(kept)
 if not removed:return 0
 e["appearances"]=kept
 recalc_event_sources(e)
 # Si el canónico era precisamente el outlier, escoger una cabecera del núcleo.
 if not any(titles_match(e.get("canonical_title",""),a.get("title","")) for a in kept):
  e["canonical_title"]=max((a.get("title","") for a in kept),key=len,default=e.get("canonical_title",""))
  best=next((a for a in kept if a.get("title")==e["canonical_title"]),None)
  if best and best.get("url"):e["url"]=best["url"]
 print("EVENT_OUTLIERS_PRUNED",e.get("id"),removed)
 return removed

def merge_duplicate_active_events(events):
 # Segunda barrera contra duplicados: si dos eventos activos representan
 # claramente el mismo hecho, se fusionan ANTES de evaluar el umbral de 4.
 active={"WAITING","UPDATE_WAITING"}
 repairable={"WAITING","UPDATE_WAITING","ELIGIBLE","ELIGIBLE_UPDATE"}
 kept=[]
 merged=0
 for e in sorted(events,key=lambda x:dtv(x.get("first_seen"))):
  if e.get("status") not in active:
   kept.append(e);continue
  target=None
  for k in kept:
   if k.get("status") not in active: continue
   # No mezclar una revisión material con su noticia padre ni revisiones distintas.
   if bool(e.get("parent_event_id"))!=bool(k.get("parent_event_id")): continue
   if e.get("parent_event_id") and e.get("parent_event_id")!=k.get("parent_event_id"): continue
   if events_match(e,k):
    target=k;break
  if not target:
   kept.append(e);continue

  # Fusionar apariciones conservando las horas originales de cada medio.
  by_source={}
  for a in list(target.get("appearances",[]))+list(e.get("appearances",[])):
   src=str(a.get("source") or "")
   if not src: continue
   cur=by_source.get(src)
   if cur is None:
    by_source[src]=dict(a);continue
   if dtv(a.get("first_seen"))<dtv(cur.get("first_seen")):
    cur["first_seen"]=a.get("first_seen")
   if dtv(a.get("last_seen"))>dtv(cur.get("last_seen")):
    cur.update({"last_seen":a.get("last_seen"),"title":a.get("title") or cur.get("title"),"url":a.get("url") or cur.get("url"),"source_type":a.get("source_type",cur.get("source_type","general"))})
  target["appearances"]=list(by_source.values())
  recalc_event_sources(target)
  # Nunca degradar un evento ya elegible al fusionarlo con un fragmento WAITING.
  if e.get("status") in {"ELIGIBLE","ELIGIBLE_UPDATE"} and target.get("status") in {"WAITING","UPDATE_WAITING"}:
   target["status"]=e.get("status")
   target["eligible_at"]=target.get("eligible_at") or e.get("eligible_at")

  if len(e.get("canonical_title",""))>len(target.get("canonical_title","")):
   target["canonical_title"]=e.get("canonical_title","")
  if dtv(e.get("first_seen"))<dtv(target.get("first_seen")):
   target["first_seen"]=e.get("first_seen")
  if dtv(e.get("last_seen"))>dtv(target.get("last_seen")):
   target["last_seen"]=e.get("last_seen")
  if not target.get("url"): target["url"]=e.get("url","")
  merged+=1
  print("EVENT_MERGED_DUPLICATE",e.get("id"),"->",target.get("id"))
 pruned=0
 for item in kept:
  if item.get("status") in repairable:
   pruned+=prune_event_outliers(item)
   recalc_event_sources(item)
 print("EVENT_MERGE_SUMMARY",merged,"outliers_pruned",pruned)
 return kept

def source_gather_minutes(e,count=None):
 general=set(e.get("sources",[]))
 seen={}
 for a in e.get("appearances",[]):
  if a.get("source") not in general or a.get("source_type","general")!="general" or not a.get("first_seen"):continue
  t=dtv(a.get("first_seen"))
  family=source_family(a.get("source"))
  if family not in seen or t<seen[family]:seen[family]=t
 if not seen:return None
 times=sorted(seen.values())
 need=count or len(times)
 if len(times)<need:return None
 return (times[need-1]-times[0]).total_seconds()/60

def format_duration_minutes(mins):
 if mins is None:return ""
 mins=max(0,int(round(mins)))
 if mins<60:return str(mins)+" min"
 h,m=divmod(mins,60)
 if m==0:return str(h)+" h"
 return str(h)+" h "+str(m)+" min"

def fast_track_minutes(e):
 general=set(e.get("sources",[]))
 families={source_family(x) for x in general}
 if len(families)<FAST_TRACK_MIN:return None
 return source_gather_minutes(e,FAST_TRACK_MIN)

def processed_snapshot(e,kind,now,revision=None):
 return {
  "event_id":e["id"],"canonical_title":e["canonical_title"],"first_seen":e["first_seen"],
  "processed_at":iso(now),"kind":kind,"revision":revision or int(e.get("revision",1)),
  "sources":list(e.get("sources",[])),"source_count":e.get("source_count",0),
  "percentage":e.get("percentage",0),"fact_tokens":sorted(fp(e["canonical_title"])),
  "last_titles":[a.get("title","") for a in e.get("appearances",[])][-10:]
 }

def processed_match(title,proc_index):
 # Dedupe conservador por acontecimiento ya tratado. best_match usa títulos y
 # variantes históricas; aquí bajamos ligeramente el umbral para evitar que una
 # reformulación de otra cabecera vuelva a crear/notificar el mismo hecho.
 pe,psc=best_match(title,proc_index,.42)
 return pe,psc

def update_is_material(title,snap):
 old=set(snap.get("fact_tokens",[]))
 new=fp(title)
 novelty=new-old
 # Más fuentes, otra URL o una reformulación nunca bastan. Solo abrimos una
 # actualización automática si aparece un término inequívocamente material.
 return bool(novelty&MATERIAL)

def persist_claim(event):
 # Claim atómico en GitHub. Si otra ejecución ya reclamó el mismo event_id,
 # esta ejecución NO vuelve a enviar el mensaje.
 gh=os.environ.get("GITHUB_TOKEN","").strip()
 repo=os.environ.get("GITHUB_REPOSITORY","").strip()
 if not gh or not repo:
  raise RuntimeError("GITHUB_TOKEN/GITHUB_REPOSITORY no disponibles para claim durable")
 api=f"https://api.github.com/repos/{repo}/contents/telegram/events.json"
 for attempt in range(1,6):
  req=urllib.request.Request(api,headers={"Authorization":f"Bearer {gh}","Accept":"application/vnd.github+json"})
  with urllib.request.urlopen(req,timeout=20) as r:
   cur=json.loads(r.read().decode())
  raw=base64.b64decode(cur["content"]).decode("utf-8")
  data=json.loads(raw)
  target=None
  for x in data.get("events",[]):
   if str(x.get("id"))==str(event.get("id")):
    target=x;break
  if target is None:
   raise RuntimeError("event_id no existe al reclamar")
  if target.get("notified") or target.get("notification_claimed_at"):
   print("CLAIM_ALREADY_TAKEN",event.get("id"),target.get("notification_claimed_at"))
   return False
  target["notified"]=True
  target["notification_claimed_at"]=event.get("notification_claimed_at")
  if event.get("fast_track_notified"): target["fast_track_notified"]=True
  body=json.dumps({
   "message":f"Claim Telegram {event.get('id')}",
   "content":base64.b64encode((json.dumps(data,ensure_ascii=False,indent=2)+"\n").encode()).decode(),
   "sha":cur["sha"],"branch":"main"
  }).encode()
  put=urllib.request.Request(api,data=body,method="PUT",headers={
   "Authorization":f"Bearer {gh}","Accept":"application/vnd.github+json","Content-Type":"application/json"
  })
  try:
   with urllib.request.urlopen(put,timeout=20) as r:r.read()
   print("CLAIM_ACQUIRED",event.get("id"))
   return True
  except urllib.error.HTTPError as ex:
   if ex.code not in (409,422): raise
   print("CLAIM_RACE_RETRY",event.get("id"),attempt)
   import time;time.sleep(attempt*0.15)
 return False

def send_review(e,token,chat,fast=False):
 # Guardamos un claim DURABLE en GitHub antes de enviar. Esto evita el doble
 # Telegram cuando dos barridos se solapan: el segundo ve notified=true.
 e["notification_claimed_at"]=iso(utcnow())
 e["notified"]=True
 e["fast_track_notified"]=bool(fast or e.get("fast_track_notified"))
 try:
  if not persist_claim(e):
   print("Envio omitido: el evento ya estaba reclamado",e.get("id"))
   return False
 except Exception as ex:
  print("No se pudo persistir claim; se cancela envio para evitar duplicado:",ex)
  return False
 if fast:
  mins=fast_track_minutes(e)
  speed=(" · reunidas en "+format_duration_minutes(mins)) if mins is not None else ""
  txt=("⚡ TTiTTulares · ALERTA TEMPRANA · "+str(e["source_count"])+"/"+str(TOTAL_SOURCES)+speed+
       "\n\n"+e["canonical_title"]+"\n\nFuentes: "+", ".join(e["sources"]))
 else:
  gathered=source_gather_minutes(e,e.get("source_count",0))
  gathered_txt=(" · reunidas en "+format_duration_minutes(gathered)) if gathered is not None else ""
  txt=("📰 TTiTTulares · PARA VALORAR · "+str(e["source_count"])+"/"+str(TOTAL_SOURCES)+
       " ("+str(e["percentage"])+"%)"+gathered_txt+"\n\n"+e["canonical_title"]+"\n\nFuentes: "+", ".join(e["sources"]))
 buttons=[[{"text":"PREPARAR","callback_data":"emergency:prepare:"+e["id"]},{"text":"DESESTIMAR","callback_data":"emergency:dismiss:"+e["id"]}],
          [{"text":"ABRIR FUENTE","url":e["url"]}]]
 payload={"chat_id":chat,"text":txt,"disable_web_page_preview":True,"reply_markup":{"inline_keyboard":buttons}}
 req=urllib.request.Request("https://api.telegram.org/bot"+token+"/sendMessage",data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"})
 urllib.request.urlopen(req,timeout=15).read()
 return True

if "--selftest-dedupe" in sys.argv:
 tests=[
  (
   'Donald Trump y Delcy Rodriguez se reunen por primera vez en Nueva York',
   'Trump y Delcy Rodríguez sellan el deshielo con un encuentro a puerta cerrada en Nueva York',
   True,
   "misma reunión Trump/Delcy con redacción distinta",
  ),
  (
   'Sánchez pide explicaciones a Marruecos “porque su control de fronteras falló”',
   'Sánchez ve evidente que el control fronterizo de Marruecos falló en la crisis de Ceuta y asegura que pidió respuestas',
   True,
   "misma noticia Sánchez/Marruecos",
  ),
  (
   'Muere un hombre de 78 años que resultó herido en el incendio de Benahavís (Málaga)',
   'Muere un hombre de 76 años en un incendio forestal en Vizcaya',
   False,
   "incendios distintos Málaga/Vizcaya",
  ),
  (
   'Cerrada la estación de tren de Fabra i Puig por el desprendimiento del falso techo',
   'Tres heridos al caer un falso techo de la estación de Rodalies de Fabra i Puig en Barcelona',
   True,
   "mismo desprendimiento Fabra i Puig",
  ),
  (
   'El Congreso retira definitivamente la acreditación como redactor a Vito Quiles',
   'El Congreso de los Diputados retira de forma definitiva la acreditación a Vito Quiles',
   True,
   "misma noticia Vito Quiles",
  ),
  (
   'Alfombra roja, IA y desconfianza mutua: las claves de la cumbre entre Trump y Xi en EEUU',
   'Trump recibe a Xi con una alfombra roja en su primera visita de Estado en una década',
   True,
   "misma visita Trump Xi con enfoques distintos",
  ),
  (
   'El papel nuclear de la IA y otras claves de la cumbre de Xi y Trump en Washington',
   'Trump recibe a Xi con una alfombra roja en su primera visita de Estado en una década',
   True,
   "misma cumbre Trump Xi aunque cambie por completo el enfoque",
  ),
  (
   'Un agente de inteligencia artificial de OpenAI accede sin permiso a datos del sistema de salud de Australia',
   'Una IA de OpenAI se cuela sin permiso en la sanidad pública australiana',
   True,
   "mismo incidente OpenAI Australia con vocabulario distinto",
  ),
  (
   'El sistema de IA de OpenAI habría accedido a portales oficiales del Gobierno de Estados Unidos sin autorización',
   'La IA de OpenAI intentó acceder sin autorización a webs oficiales del Gobierno de EEUU',
   True,
   "mismo acceso no autorizado de OpenAI a webs oficiales de EEUU",
  ),
  (
   'El juez Peinado se jubila este domingo tras enviar a juicio con jurado popular a Begoña Gómez',
   'El BOE publica la jubilación forzosa por edad del juez Peinado cuatro días después de enviar a Begoña Gómez a juicio',
   True,
   "misma jubilación del juez Peinado",
  ),
  (
   'Macklemore anuncia conciertos a favor de Palestina y donará todo lo recaudado',
   'Macklemore anuncia la gira "Free Palestine" tras haber sido expulsado de la de Ed Sheeran',
   True,
   "misma gira de Macklemore traducida y enfocada de forma distinta",
  ),
  (
   'Ed Sheeran no se libra de la polémica: convocan una manifestación a las puertas de su concierto en Massachusetts',
   'Macklemore anuncia una gira benéfica en apoyo a Palestina tras su salida de la gira de Ed Sheeran',
   False,
   "manifestación contra Ed Sheeran no es la gira de Macklemore",
  ),
  (
   'Ed Sheeran no se libra de la polémica: convocan una manifestación a las puertas de su concierto en Massachusetts - El HuffPost',
   'Macklemore anuncia la gira "Free Palestine" tras haber sido expulsado de la de Ed Sheeran: "Mantenerse al margen mientras se produce un genocidio ya no funciona" - El HuffPost',
   False,
   "cabecera compartida no convierte la protesta de Ed Sheeran en la gira de Macklemore",
  ),
  (
   'Macklemore anuncia un nuevo disco de estudio para 2027',
   'Macklemore anuncia conciertos a favor de Palestina y donará todo lo recaudado',
   False,
   "mismo artista pero hechos distintos",
  ),
  (
   'La OTAN vuelve a activar cazas F18 españoles en Rumanía por la presencia de un dron ruso en la frontera con Ucrania',
   'Dos cazas españoles son movilizados en Rumanía ante una alerta de drones',
   True,
   "mismo despliegue de cazas españoles en Rumanía",
  ),
  (
   'La OTAN vuelve a activar cazas F18 españoles en Rumanía por la presencia de un dron ruso en la frontera con Ucrania',
   'F-18 españoles, a la caza de los drones kamikaze rusos que ponen a prueba a la OTAN',
   True,
   "mismo incidente F-18/drones con formato F-18",
  ),
  (
   'Rumanía anuncia la compra de nuevos cazas F-35 para modernizar su fuerza aérea',
   'Dos cazas españoles son movilizados en Rumanía ante una alerta de drones',
   False,
   "mismo país y cazas pero acontecimientos distintos",
  ),
  (
   'España busca ganar peso en la OTAN ante el repliegue de Estados Unidos',
   'F-18 españoles, a la caza de los drones kamikaze rusos que ponen a prueba a la OTAN',
   False,
   "tema OTAN compartido pero hechos distintos",
  ),
  (
   "Ucrania activa la 'Operación Vivaldi': sorprende lanzando robots terrestres tras las líneas enemigas y causa 3.000 bajas rusas",
   'La OTAN vuelve a activar cazas F18 españoles en Rumanía por la presencia de un dron ruso en la frontera con Ucrania',
   False,
   "Ucrania compartida no mezcla Operación Vivaldi con alerta F-18 en Rumanía",
  ),
  (
   'La OTAN vuelve a activar cazas F18 espaoles en Rumana por la presencia de un dron ruso en la frontera con Ucrania',
   'Dos cazas españoles son movilizados en Rumanía ante una alerta de drones',
   True,
   "mismo F-18 pese a caracteres perdidos en una fuente",
  ),
  (
   'Andalucía activa la emergencia por el incendio de Igualeja y confina el municipio malagueño',
   'El fuego de un incendio obliga a confinar Igualeja, en Málaga, y a cortar el tráfico en la carretera MA-7304',
   True,
   "mismo incendio y confinamiento de Igualeja",
  ),
  (
   'Incendio forestal en Marbella obliga a desalojar varias viviendas',
   'El fuego de un incendio obliga a confinar Igualeja, en Málaga, y a cortar el tráfico en la carretera MA-7304',
   False,
   "incendios distintos en Málaga",
  ),
 ]
 for a,b,should_match,label in tests:
  value=score(a,b)
  semantic=same_event_semantic(a,b)
  matched=value>=0.50 or semantic
  print("DEDUPE_SELFTEST",label,round(value,4),"semantic",semantic,matched)
  if matched!=should_match:
   raise SystemExit("Fallo deduplicación: "+label)
 chain_event={
  "canonical_title":"El 'Decreto Maricarmen': medidas por la vivienda durante la acampada en Sol",
  "appearances":[
   {"title":"Miles de personas acampan en Sol tras la manifestación por Maricarmen"},
   {"title":"La marcha por la vivienda se transforma en una acampada en la Puerta del Sol"},
   {"title":"Acampada en Sol contra los desahucios y por el derecho a la vivienda"},
   {"title":"El Sindicato de Inquilinas reclama el decreto Maricarmen durante la acampada"},
  ],
 }
 bad,_=best_match("El PP descarta activar el juicio a Pedro Sánchez por traición",[chain_event],.50)
 if bad:
  raise SystemExit("Fallo deduplicación: una cabecera política ajena entra por efecto cadena en el evento de Sol")
 chain_event2={
  "canonical_title":"Miles de personas marchan en Madrid en apoyo a Ceuta y para exigir elecciones",
  "appearances":[
   {"title":"La marcha en apoyo a Ceuta reúne a miles de manifestantes en Madrid"},
   {"title":"Una multitudinaria marcha recorre Madrid en apoyo a Ceuta y exige elecciones"},
   {"title":"PP y Vox apoyan una marcha en Madrid en defensa de Ceuta"},
  ],
 }
 bad2,_=best_match("Sánchez participa junto a Óscar López en la presentación de candidaturas de Madrid",[chain_event2],.50)
 if bad2:
  raise SystemExit("Fallo deduplicación: acto de candidaturas se mezcla con la marcha de Ceuta")
 print("DEDUPE_CHAIN_SELFTEST OK")
 raise SystemExit(0)

now=utcnow()
events_doc=load(EVENTS,{"version":3,"events":[]})
events=events_doc.get("events",[])
initial_event_count=len(events)
processed_doc=load(PROCESSED,{"version":1,"events":[]})
processed=processed_doc.get("events",[])

# Migración suave de eventos antiguos.
for e in events:
 if "canonical_title" not in e:e["canonical_title"]=e.get("title","")
 if "appearances" not in e:
  e["appearances"]=[{"source":s,"title":e["canonical_title"],"url":e.get("url",""),"first_seen":e.get("first_seen"),"last_seen":e.get("last_seen")} for s in e.get("sources",[])]
 recalc_event_sources(e)

# Activación segura: no enviar retroactivamente alertas rápidas de eventos que ya tenían 3+ fuentes.
if not events_doc.get("fast_track_initialized"):
 for e in events:
  if e.get("status")=="WAITING" and e.get("source_count",0)>=FAST_TRACK_MIN:
   e["fast_track_notified"]=True
 events_doc["fast_track_initialized"]=True
 events_doc["fast_track_initialized_at"]=iso(now)

# Los eventos que aún no han llegado al umbral caducan exactamente a las 24 h.
cutoff=now-timedelta(hours=WAIT_HOURS)
events=[e for e in events if e.get("status") not in {"WAITING","UPDATE_WAITING"} or dtv(e.get("first_seen"))>=cutoff]

rows,healthy,sport_healthy,source_failures,source_status,source_recovery=fetch_items()
# Telemetry ONLY. Count DISTINCT newly observed headlines per source in a rolling
# 24h window. A repeated article does not reset the time since last news.
# Persist within events.json, already written by both normal radar workflows.
source_article_telemetry=update_source_telemetry(
 rows,source_status,events_doc.get("source_article_telemetry"),events,now
)
print("SOURCES_OK",len(set(healthy)),sorted(set(healthy)))
print("SPORT_SOURCES_OK",len(set(sport_healthy)),sorted(set(sport_healthy)))
print("SOURCES_CONFIGURED",TOTAL_SOURCES)
print("SOURCE_HEALTH_SUMMARY",len(set(healthy)),"/",TOTAL_SOURCES,"general outlets;",len({source_family(x) for x in healthy}),"/",TOTAL_SOURCE_FAMILIES,"independent families;",len(set(sport_healthy)),"/",len(SPORT_SOURCES),"sport")
if len(set(healthy))<MIN_HEALTHY_SOURCES:
 print("SOURCE_HEALTH_DEGRADED correction process attempted; remaining failures:",[x["source"] for x in source_status if x["type"]=="general" and not x["ok"]])

# Índice durable de acontecimientos ya tratados o actualmente dentro del flujo
# editorial web. Si un ELIGIBLE desaparece de events.json al prepararse, debe
# seguir siendo deduplicable para que no renazca con otro event_id.
proc_index=[]
for p in processed:
 proc_index.append({"id":p.get("event_id"),"canonical_title":p.get("canonical_title",""),"appearances":[{"title":t} for t in p.get("last_titles",[])],"snapshot":p})

editorial_doc=load(EDITORIAL_PROCESSING,{"items":[]})
prepared_doc=load(PREPARED,{"items":[]})
decisions_doc=load(DECISIONS,{"items":[]})

def pipeline_snapshot(item,kind):
 title=item.get("title") or item.get("canonical_title") or ""
 sources=list(item.get("sources") or item.get("sources_at_draft") or [])
 evidence=item.get("source_evidence") or []
 last_titles=[x.get("title","") for x in evidence if isinstance(x,dict) and x.get("title")]
 return {"event_id":item.get("event_id"),"canonical_title":title,
  "first_seen":item.get("selected_at") or item.get("prepared_at") or item.get("published_at"),
  "processed_at":item.get("delivered_at") or item.get("prepared_at") or item.get("published_at") or iso(now),
  "kind":kind,"revision":int(item.get("revision",1) or 1),
  "sources":sources,"source_count":int(item.get("source_count") or item.get("drafted_source_count") or len(sources)),
  "fact_tokens":sorted(fp(title)),"last_titles":last_titles}

for kind,items in (
 ("EDITORIAL",(editorial_doc.get("items") or [])),
 ("PREPARED",(prepared_doc.get("items") or [])),
 ("DECISION",(decisions_doc.get("items") or decisions_doc.get("decisions") or [])),
):
 for item in items:
  eid=str(item.get("event_id") or "");title=item.get("title") or item.get("canonical_title") or ""
  if not eid or not title:continue
  snap=pipeline_snapshot(item,kind)
  proc_index.append({"id":eid,"canonical_title":title,"appearances":[{"title":t} for t in snap.get("last_titles",[])],"snapshot":snap})

# Poda de fragmentos WAITING que ya corresponden a una noticia presente en
# el flujo editorial web. Esto limpia recreaciones nacidas en un barrido anterior
# a la actualización del índice. UPDATE_WAITING se conserva porque representa
# una posible novedad material sobre un acontecimiento ya tratado.
deduped_waiting=[]
for e in events:
 if e.get("status")=="WAITING":
  pe,_=processed_match(e.get("canonical_title") or "",proc_index)
  if pe:
   print("WAITING_PIPELINE_DUPLICATE_DROPPED",e.get("id"),"duplicate_of",pe.get("id"))
   continue
 deduped_waiting.append(e)
events=deduped_waiting

CLUSTERABLE_STATUSES={"WAITING","UPDATE_WAITING"}
for row in rows:
 # 1) intentar agregar solo a eventos todavía clusterizables.
 # Nunca adjuntar titulares nuevos a PUBLISHED/DISMISSED/SENT_REVIEW históricos:
 # eso contaminaba eventos antiguos y además robaba fuentes a noticias nuevas.
 clusterable=[x for x in events if x.get("status") in CLUSTERABLE_STATUSES]
 e,sc=best_match(row["title"],clusterable,.50)
 if e:
  add_appearance(e,row,now);continue
 # 1b) si el acontecimiento ya alcanzó el umbral, queda congelado: no añadimos
 # más cabeceras, pero evitamos recrear un duplicado cuando el canónico coincide.
 frozen=[x for x in events if x.get("status") in {"ELIGIBLE","ELIGIBLE_UPDATE"}]
 duplicate_frozen=False
 for done in frozen:
  title=done.get("canonical_title") or done.get("title","")
  s=score(row["title"],title)
  if s>=0.58 or same_event_semantic(row["title"],title):
   duplicate_frozen=True;break
 if duplicate_frozen:continue
 # 2) si coincide con una ya procesada, no recrearla; solo evaluar posible actualización.
 pe,psc=processed_match(row["title"],proc_index)
 if pe:
  snap=pe["snapshot"]
  seen_sources=set(snap.get("sources",[]))
  material_hint=update_is_material(row["title"],snap)
  new_source=row["source"] not in seen_sources
  key=str(snap.get("event_id"))
  upd=next((x for x in events if x.get("parent_event_id")==key and x.get("status")=="UPDATE_WAITING"),None)
  if not upd and new_source and material_hint:
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

events=merge_duplicate_active_events(events)

control_mode=load(CONTROL_MODE,{"mode":"telegram"})
web_mode=str(control_mode.get("mode") or "telegram").strip().lower()=="web"
token=None if web_mode else os.environ.get("TELEGRAM_BOT_TOKEN")
chat=None if web_mode else os.environ.get("TELEGRAM_CHAT_ID")
sent=0;expired=0
new_processed=[]

for e in list(events):
 n=e.get("source_count",0)
 status=e.get("status")
 if status=="WAITING" and n>=REVIEW_MIN and has_independent_evidence_consensus(e,REVIEW_MIN):
  if web_mode:
   e["status"]="ELIGIBLE"
   e["eligible_at"]=e.get("eligible_at") or iso(now)
  else:
   # Si ya se avisó a 3 fuentes por aceleración, no duplicar el aviso al llegar a 4.
   if not e.get("fast_track_notified") and not e.get("notified"):
    did_send=bool(token and chat and send_review(e,token,chat))
    if did_send: sent+=1
   e["status"]="SENT_REVIEW";e["notified"]=True
   new_processed.append(processed_snapshot(e,"SENT_REVIEW",now))
 elif (not web_mode) and status=="WAITING" and n==FAST_TRACK_MIN and has_independent_evidence_consensus(e,FAST_TRACK_MIN) and not e.get("fast_track_notified") and not e.get("notified"):
  mins=fast_track_minutes(e)
  if mins is not None and mins<=FAST_TRACK_WINDOW_MIN:
   # FAST_TRACK y revisión normal son una sola notificación editorial.
   # Marcar notified evita que otro proceso/ejecución envíe el mismo event_id.
   e["notified"]=True
   did_send=bool(token and chat and send_review(e,token,chat,True))
   e["fast_track_notified"]=True
   e["fast_track_notified_at"]=iso(now)
   e["fast_track_minutes"]=round(mins,1)
   new_processed.append(processed_snapshot(e,"FAST_TRACK_ALERT",now))
   if did_send: sent+=1
 elif status=="UPDATE_WAITING" and n>=REVIEW_MIN and has_independent_evidence_consensus(e,REVIEW_MIN):
  if web_mode:
   e["status"]="ELIGIBLE_UPDATE"
   e["eligible_at"]=e.get("eligible_at") or iso(now)
  else:
   did_send=bool(token and chat and send_review(e,token,chat))
   e["status"]="SENT_REVIEW";e["notified"]=True
   new_processed.append(processed_snapshot(e,"UPDATE_SENT_REVIEW",now,e.get("revision",2)))
   if did_send: sent+=1

# Segunda poda por si el ciclo acaba de cruzar el límite de 24 h.
kept=[]
for e in events:
 if e.get("status") in {"WAITING","UPDATE_WAITING"} and dtv(e.get("first_seen"))<cutoff:
  expired+=1
 else:kept.append(e)
events=kept

# Append-only lógico de procesadas por event_id+revision+kind.
keys={(str(x.get("event_id")),int(x.get("revision",1)),str(x.get("kind"))) for x in processed}
for p in new_processed:
 k=(str(p.get("event_id")),int(p.get("revision",1)),str(p.get("kind")))
 if k not in keys:processed.append(p);keys.add(k)
processed=processed[-MAX_PROCESSED:]

if initial_event_count>0 and len(events)==0:
 raise RuntimeError("Protección de estado: el barrido intentó vaciar todos los eventos")

# Diagnóstico por fuente para la app: última aportación REAL (first_seen de una
# aparición), no el simple refresco de un artículo que continúa en portada.
last_contribution={}
for e in events:
 for a in e.get("appearances",[]):
  src=str(a.get("source") or "")
  when=a.get("first_seen")
  if not src or not when:continue
  cur=last_contribution.get(src)
  if cur is None or dtv(when)>dtv(cur.get("at")):
   last_contribution[src]={"at":when,"title":a.get("title") or e.get("canonical_title",""),"event_id":e.get("id")}
for item in source_status:
 src=item.get("source")
 last=last_contribution.get(src,{})
 item["family"]=source_family(src)
 item["counts_for_threshold"]=item.get("type")=="general"
 item["last_contribution_at"]=last.get("at")
 item["last_event_title"]=last.get("title")
 item["last_event_id"]=last.get("event_id")

healthy_families=sorted({source_family(src) for src in healthy})
events_doc={"version":6,"configured_sources":TOTAL_SOURCES,"configured_source_families":TOTAL_SOURCE_FAMILIES,"review_min_sources":REVIEW_MIN,
            "fast_track_min_sources":FAST_TRACK_MIN,"fast_track_window_minutes":FAST_TRACK_WINDOW_MIN,
            "fast_track_initialized":True,"fast_track_initialized_at":events_doc.get("fast_track_initialized_at") or iso(now),
            "automatic_processing":False,"waiting_ttl_hours":WAIT_HOURS,"min_healthy_sources":MIN_HEALTHY_SOURCES,"last_run":iso(now),
            "healthy_sources":sorted(set(healthy)),"healthy_source_count":len(set(healthy)),
            "healthy_source_families":healthy_families,"healthy_source_family_count":len(healthy_families),
            "healthy_sport_sources":sorted(set(sport_healthy)),"source_failures":source_failures,
            "source_status":source_status,"source_article_telemetry":source_article_telemetry,"source_recovery":source_recovery,"discovery_sources":[x[0] for x in DISCOVERY_SOURCES],"events":events}
processed_doc={"version":1,"updated_at":iso(now),"events":processed}
save(EVENTS,events_doc);save(PROCESSED,processed_doc)
print("RESULT rows",len(rows),"active_events",len(events),"review_sent",sent,"auto_queued",0,"expired",expired)
