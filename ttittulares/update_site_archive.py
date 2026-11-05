#!/usr/bin/env python3
"""Accumulate every committed prepared.json snapshot. Never write editorial queues."""
import argparse, datetime as dt, hashlib, json, os, pathlib, re, time, unicodedata
from urllib.request import Request, urlopen
from urllib.parse import urlencode, urlparse
from zoneinfo import ZoneInfo
REPO='fabricelop/europapress-rss'
ROOT=pathlib.Path(__file__).resolve().parents[1]
ARCHIVE=ROOT/'ttittulares/site-archive.json'
CURSOR=ROOT/'ttittulares/site-archive-cursor.json'
CATEGORIES=['Política','Internacional','Economía','Sociedad','Sucesos','Deportes','Tecnología','Ciencia y salud','Cultura','Medioambiente','Otras noticias']
RULES=[('Deportes',r'futbol|laliga|liga de campeones|tenis|formula 1|motogp|baloncesto|atletico|real madrid|barca|seleccion|deportes'),('Internacional',r'internacional|ucrania|rusia|trump|bolsonaro|gaza|israel|netanyahu|zelenski|eeuu|estados unidos|iran|lula'),('Economía',r'economia|ibex|banco|inflacion|pib|desempleo|impuestos|presupuestos'),('Sucesos',r'accidente|fallec|asesin|muere|detenid|policia|guardia civil|jueza|tribunal|incendio|inundacion'),('Política',r'politica|sanchez|ayuso|feijoo|psoe|sumar|vox|partido popular|congreso|gobierno|elecciones'),('Tecnología',r'tecnologia|inteligencia artificial|ciber|iphone|microsoft|google'),('Ciencia y salud',r'salud|ciencia|medic|hospital|vacuna|cancer|sanidad'),('Cultura',r'cultura|actor|actriz|cine|musica|escultor|pintor|cantante|pelicula|libro'),('Medioambiente',r'medioambiente|clima|aemet|meteorolog|biodiversidad'),('Sociedad',r'sociedad|vivienda|educacion|escuela|universidad|halloween|todos los santos')]
def fold(s):return ''.join(c for c in unicodedata.normalize('NFD',str(s or '')) if not unicodedata.combining(c)).lower()
def safe_url(s):
 try:return str(s) if urlparse(str(s)).scheme in ('https','http') else ''
 except ValueError:return ''
def request(url,as_json=True):
 headers={'User-Agent':'TTActualidad-archive','Accept':'application/vnd.github+json'}
 token=os.environ.get('GITHUB_TOKEN')
 if token and urlparse(url).hostname=='api.github.com':headers['Authorization']='Bearer '+token
 for n in range(3):
  try:
   with urlopen(Request(url,headers=headers),timeout=35) as r:data=r.read()
   return json.loads(data) if as_json else data
  except Exception:
   if n==2:raise
   time.sleep(n+1)
def load(p,default):return json.loads(p.read_text()) if p.exists() else default
def save(p,obj):
 p.parent.mkdir(parents=True,exist_ok=True);tmp=p.with_suffix(p.suffix+'.tmp');tmp.write_text(json.dumps(obj,ensure_ascii=False,separators=(',',':'))+'\n');tmp.replace(p)
def normalize(item,sha,at):
 event_id=str(item.get('event_id') or '');revision=item.get('revision',1)
 if not event_id or not isinstance(revision,int) or revision<0 or not item.get('title'):return None
 tweet=item.get('tweet') or {};text=item.get('factual_summary') or item.get('explanation') or re.split(r'\n[#🌶]',tweet.get('text',''))[0]
 if not text:return None
 try:date=dt.datetime.fromisoformat((item.get('prepared_at') or at).replace('Z','+00:00'));assert date.tzinfo
 except (ValueError,AssertionError):return None
 category=item.get('category','');s=fold(item['title']+' '+category)
 if category not in CATEGORIES:category=next((c for c,r in RULES if re.search(r,s)),'Otras noticias')
 return {'event_id':event_id,'revision':revision,'title':item['title'],'summary':text,'body':item.get('explanation') or text,'remate':tweet.get('remate',''),'date':date.astimezone(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'),'date_label':'Entrada en Listas' if item.get('prepared_at') else 'Presencia verificada en Listas','day':date.astimezone(ZoneInfo('Europe/Madrid')).strftime('%Y-%m-%d'),'category':category,'tags':re.findall(r'#[\w]+',tweet.get('text','')),'sources':[{'name':s.get('source') or 'Fuente original','url':safe_url(s.get('url'))} for s in item.get('source_evidence',[]) if isinstance(s,dict) and safe_url(s.get('url'))],'url':safe_url(item.get('url')),'image':None,'proof':{'kind':'prepared_snapshot','commit':sha,'at':at,'path':'ttittulares/prepared.json'}}
def image_for(item):
 # Do not trust arbitrary image_status, external photographs with unverified rights,
 # or a generated image without an exact event/revision association.
 ai=item.get('ai_image') or {}
 if item.get('ai_image_status')=='ready' and ai.get('generated') is True and ai.get('rights_status')=='generated' and str(ai.get('event_id'))==str(item.get('event_id')) and ai.get('revision')==item.get('revision') and ai.get('sha256'):
  url=safe_url(ai.get('url'))
  if urlparse(url).hostname!='raw.githubusercontent.com':return None
  if not urlparse(url).path.startswith('/'+REPO+'/'):return None
  content=request(url,False)
  if len(content)>15000000 or hashlib.sha256(content).hexdigest()!=ai['sha256']:return None
  return {'kind':'ai','url':url,'sha256':ai['sha256'],'credit':ai.get('source') or 'TTActualidad','alt':ai.get('alt') or item['title'],'event_id':item['event_id'],'revision':item['revision'],'verified':True}
 return None
def merge(records,rows):
 for row in rows:
  key=(row['event_id'],row['revision']);old=records.get(key)
  if old:
   row=dict(row,date=old['date'],day=old['day'],date_label=old['date_label'],proof=old['proof'],image=row.get('image') or old.get('image'))
  records[key]=row
 return records

def run():
 archive=load(ARCHIVE,{'schema_version':1,'items':[]});cursor=load(CURSOR,{'since':'2026-11-01T14:36:51Z'})
 # Five-minute overlap survives boundary commits and makes retries idempotent.
 since=(dt.datetime.fromisoformat(cursor['since'].replace('Z','+00:00'))-dt.timedelta(minutes=5)).isoformat()
 commits=[]
 for page in range(1,101):
  rows=request('https://api.github.com/repos/'+REPO+'/commits?'+urlencode({'path':'ttittulares/prepared.json','sha':'main','since':since,'per_page':100,'page':page}))
  if not isinstance(rows,list):raise ValueError('Invalid commit list')
  commits.extend(rows)
  if len(rows)<100:break
 else:raise RuntimeError('History exceeds bounded pagination; cursor not advanced')
 records={(x['event_id'],x['revision']):x for x in archive['items']};failures=[]
 for c in reversed(commits):
  sha=c['sha'];at=c['commit']['committer']['date']
  try:
   snapshot=request(f'https://raw.githubusercontent.com/{REPO}/{sha}/ttittulares/prepared.json')
   if not isinstance(snapshot.get('items'),list):raise ValueError('Invalid prepared snapshot')
   rows=[]
   for item in snapshot['items']:
    row=normalize(item,sha,at)
    if row:
     try:row['image']=image_for(item)
     except Exception as e:failures.append({'commit':sha,'event_id':row['event_id'],'kind':'image','error':str(e)})
     rows.append(row)
   merge(records,rows)
  except Exception as e:
   # A missing snapshot must not be silently skipped by moving the cursor.
   failures.append({'commit':sha,'kind':'snapshot','error':str(e)})
   save(ROOT/'ttittulares/site-archive-errors.json',{'items':failures});raise
 updated=sorted(records.values(),key=lambda x:(x['date'],x['event_id'],x['revision']))
 changed=updated!=archive['items']
 archive['items']=updated
 if changed:archive['updated_at']=dt.datetime.now(dt.timezone.utc).isoformat()
 archive['report']={**archive.get('report',{}),'distinct_events':len(set(x['event_id'] for x in archive['items'])),'revisions':len(archive['items'])}
 save(ARCHIVE,archive)
 save(ROOT/'ttittulares/site-archive-errors.json',{'items':failures})
 if commits:save(CURSOR,{'since':max(c['commit']['committer']['date'] for c in commits)})
 print(f"Archived {len(archive['items'])} revisions; examined {len(commits)} snapshots")
if __name__=='__main__':run()
