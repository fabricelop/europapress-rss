#!/usr/bin/env python3
import json
from datetime import datetime, timezone
from pathlib import Path
from auto_queue import same_story

ROOT=Path(__file__).resolve().parents[1]
Q=ROOT/'telegram'/'editorial-processing.json'
P=ROOT/'ttittulares'/'prepared.json'
D=ROOT/'ttittulares'/'decisions.json'
BATCH='2026-10-03T16:42:18.978756Z'
MIN_SOURCES=4

def load(p): return json.loads(p.read_text(encoding='utf-8'))
def normrow(x): return {'title':str(x.get('title') or x.get('canonical_title') or ''),'url':str(x.get('url') or '')}

def main():
 q,p,d=load(Q),load(P),load(D)
 prepared=list(p.get('items') or [])
 terminal={str(x.get('event_id') or ''):str(x.get('status') or '').lower() for x in d.get('items') or []}
 changed=[]; kept=[]
 for row in q.get('items') or []:
  if row.get('status')!='PROCESSING' or row.get('selection_mode')!='AUTO_WEB' or row.get('selected_at')!=BATCH:
   continue
  eid=str(row.get('event_id') or '')
  # 1) nunca reelaborar una entrada ya publicada/desestimada con el mismo id.
  if terminal.get(eid) in {'published','dismissed'}:
   row['status']='SKIPPED_DUPLICATE'; row['duplicate_of_event_id']=eid; row['filter_reason']='terminal_decision_same_event'; changed.append(eid); continue
  # 2) comparar contra Listas/READY/PUBLISHED ya materializadas.
  dup=None
  for old in prepared:
   if str(old.get('event_id') or '')==eid: continue
   if same_story(normrow(row),normrow(old)):
    dup=str(old.get('event_id') or ''); break
  if dup:
   row['status']='SKIPPED_DUPLICATE'; row['duplicate_of_event_id']=dup; row['filter_reason']='already_prepared_same_story'; changed.append(eid); continue
  # 3) detectar agrupaciones contaminadas: solo cuentan evidencias cuyo titular pertenece realmente a la historia.
  matched=set()
  candidate=normrow(row)
  for ev in row.get('source_evidence') or []:
   if same_story(candidate,normrow(ev)):
    s=str(ev.get('source') or '').strip()
    if s: matched.add(s)
  if len(matched)<MIN_SOURCES:
   row['status']='DISMISSED'; row['filter_reason']='insufficient_matching_source_evidence'; row['matching_source_count']=len(matched); changed.append(eid); continue
  row['verified_source_count']=len(matched); kept.append(eid)
 if changed:
  q['updated_at']=datetime.now(timezone.utc).isoformat().replace('+00:00','Z')
  Q.write_text(json.dumps(q,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 print(json.dumps({'changed':changed,'kept':kept,'changed_count':len(changed),'kept_count':len(kept)},ensure_ascii=False))

if __name__=='__main__': main()
