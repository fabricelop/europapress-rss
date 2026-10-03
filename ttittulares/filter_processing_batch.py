#!/usr/bin/env python3
import json
from datetime import datetime, timezone
from pathlib import Path
from auto_queue import same_story, evidence_for, terminal_map, base_id, is_material_update, MIN_SOURCES

ROOT=Path(__file__).resolve().parents[1]
Q=ROOT/'telegram'/'editorial-processing.json'
P=ROOT/'ttittulares'/'prepared.json'
D=ROOT/'ttittulares'/'decisions.json'

def load(p,default):
 try: return json.loads(p.read_text(encoding='utf-8'))
 except Exception: return default

def normrow(x): return {'title':str(x.get('title') or x.get('canonical_title') or ''),'url':str(x.get('url') or '')}

def main():
 q=load(Q,{'items':[]}); p=load(P,{'items':[]}); d=load(D,{'items':[]})
 prepared=list(p.get('items') or []); terminal=terminal_map(d)
 changed=[]; kept=[]; active_kept=[]
 # Conserva el orden actual: la primera versión válida gana frente a duplicados posteriores.
 for row in q.get('items') or []:
  if row.get('status')!='PROCESSING' or row.get('selection_mode')!='AUTO_WEB':
   continue
  eid=str(row.get('event_id') or '')
  if eid in terminal:
   row['status']='SKIPPED_DUPLICATE'; row['filter_reason']='terminal_decision_same_event'; changed.append(eid); continue
  bid=base_id(eid)
  if bid!=eid and bid in terminal and not is_material_update(row):
   row['status']='SKIPPED_DUPLICATE'; row['duplicate_of_event_id']=bid; row['filter_reason']='non_material_revision_of_terminal_story'; changed.append(eid); continue
  dup=None
  for old in prepared+active_kept:
   if str(old.get('event_id') or '')==eid: continue
   if same_story(normrow(row),normrow(old)):
    dup=str(old.get('event_id') or ''); break
  if dup:
   row['status']='SKIPPED_DUPLICATE'; row['duplicate_of_event_id']=dup; row['filter_reason']='already_prepared_or_processing_same_story'; changed.append(eid); continue
  evidence=evidence_for(row)
  sources=[]
  for ev in evidence:
   s=str(ev.get('source') or '').strip()
   if s and s not in sources: sources.append(s)
  if len(sources)<MIN_SOURCES:
   row['status']='DISMISSED'; row['filter_reason']='insufficient_matching_source_evidence'; row['matching_source_count']=len(sources); changed.append(eid); continue
  row['source_evidence']=evidence; row['sources']=sources; row['source_count']=len(sources); row['verified_source_count']=len(sources)
  active_kept.append(row); kept.append(eid)
 if changed:
  q['updated_at']=datetime.now(timezone.utc).isoformat().replace('+00:00','Z')
  Q.write_text(json.dumps(q,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 print(json.dumps({'changed':changed,'kept':kept,'changed_count':len(changed),'kept_count':len(kept)},ensure_ascii=False))

if __name__=='__main__': main()
