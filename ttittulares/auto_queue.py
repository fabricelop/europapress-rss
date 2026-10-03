#!/usr/bin/env python3
import json, sys, re, unicodedata
from difflib import SequenceMatcher
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
RADAR=ROOT/'telegram'/'radar-events.json'
QUEUE=ROOT/'telegram'/'editorial-processing.json'
DECISIONS=ROOT/'ttittulares'/'decisions.json'
PREPARED=ROOT/'ttittulares'/'prepared.json'
MIN_SOURCES=4

STOP={'de','del','la','las','el','los','un','una','unos','unas','y','o','en','a','por','para','con','sin','sobre','que','se','su','sus','al','es','tras','ante','como','más','mas','ya','hoy','este','esta','estos','estas'}

def load(path, default):
    try: return json.loads(path.read_text(encoding='utf-8'))
    except Exception: return default

def save(path, obj):
    path.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

def norm(s):
    s=unicodedata.normalize('NFKD',str(s or '')).encode('ascii','ignore').decode().lower()
    return re.sub(r'[^a-z0-9]+',' ',s).strip()

def tokens(s):
    return {x for x in norm(s).split() if len(x)>2 and x not in STOP}

def row_title(x): return str(x.get('title') or x.get('canonical_title') or '')
def row_url(x): return str(x.get('url') or '')

def same_story(a,b):
    ua,ub=row_url(a),row_url(b)
    if ua and ub and ua==ub: return True
    ta,tb=norm(row_title(a)),norm(row_title(b))
    if not ta or not tb: return False
    A,B=tokens(ta),tokens(tb)
    common=A&B
    # Dos titulares de una misma historia suelen compartir al menos 3 palabras
    # informativas; para titulares cortos aceptamos 2 con alta similitud.
    if len(common)>=3:
        overlap=len(common)/max(1,min(len(A),len(B)))
        if overlap>=0.42: return True
    if len(common)>=2 and SequenceMatcher(None,ta,tb).ratio()>=0.68: return True
    return SequenceMatcher(None,ta,tb).ratio()>=0.78

def terminal_map(decisions):
    out={}
    for d in decisions.get('items') or []:
        eid=str(d.get('event_id') or '')
        st=str(d.get('status') or '').lower()
        if eid and st in {'published','dismissed'}: out[eid]=st
    return out

def base_id(eid): return re.sub(r'-r\d+$','',str(eid or ''))

def evidence_for(row):
    matched=[]; seen=set()
    for ev in row.get('source_evidence') or []:
        if not same_story(row,ev): continue
        src=str(ev.get('source') or '').strip()
        if not src or src in seen: continue
        seen.add(src); matched.append(ev)
    return matched

def is_material_update(row):
    if str(row.get('status') or '')!='ELIGIBLE_UPDATE': return True
    ctx=row.get('update_context') or {}
    # Una revisión no vuelve a PROCESSING solo porque haya nuevas fuentes/URLs.
    # Debe venir marcada explícitamente como cambio material por el radar.
    return bool(row.get('material_update') is True or ctx.get('material_update') is True or ctx.get('material_change') is True)

def queue_eligible(radar, queue, decisions, prepared=None, verbose=False):
    prepared=prepared or {'items':[]}
    qitems=queue.get('items') or []
    terminal=terminal_map(decisions)
    active=[x for x in qitems if str(x.get('status') or '') in {'PROCESSING','READY'}]
    history=list(prepared.get('items') or [])
    added=[]
    for row in radar.get('events') or []:
        st=str(row.get('status') or '')
        if st not in {'ELIGIBLE','ELIGIBLE_UPDATE'}: continue
        eid=str(row.get('event_id') or '')
        if not eid: continue
        if eid in terminal: 
            if verbose: print('AUTO_QUEUE_TERMINAL_SKIPPED',eid,terminal[eid].upper())
            continue
        # Revisiones de una historia terminal solo entran si el radar certifica
        # que existe una novedad material, no por simple refresco de fuentes.
        bid=base_id(eid)
        if bid!=eid and bid in terminal and not is_material_update(row):
            if verbose: print('AUTO_QUEUE_REVISION_SKIPPED',eid,'base_terminal',bid)
            continue
        if not is_material_update(row):
            if verbose: print('AUTO_QUEUE_NON_MATERIAL_UPDATE_SKIPPED',eid)
            continue
        if any(str(x.get('event_id') or '')==eid for x in qitems): continue
        # Barrera anti-contaminación: las 4 fuentes deben hablar realmente del
        # mismo hecho. source_count agregado por el radar ya no es suficiente.
        evidence=evidence_for(row)
        sources=[]
        for ev in evidence:
            s=str(ev.get('source') or '').strip()
            if s and s not in sources: sources.append(s)
        if len(sources)<MIN_SOURCES:
            if verbose: print('AUTO_QUEUE_EVIDENCE_SKIPPED',eid,len(sources))
            continue
        # No reintroducir una historia ya activa o ya materializada en Listas.
        dup=None
        for old in active+history:
            if str(old.get('event_id') or '')==eid: continue
            if same_story(row,old):
                dup=str(old.get('event_id') or ''); break
        if dup:
            if verbose: print('AUTO_QUEUE_DUPLICATE_SKIPPED',eid,'duplicate_of',dup)
            continue
        now=datetime.now(timezone.utc).isoformat().replace('+00:00','Z')
        q=dict(row)
        q['status']='PROCESSING'; q['selection_mode']='AUTO_WEB'; q['selected_at']=now
        q['source_evidence']=evidence; q['sources']=sources; q['source_count']=len(sources)
        q['verified_source_count']=len(sources)
        qitems.append(q); active.append(q); added.append(eid)
    queue['items']=qitems
    if added: queue['updated_at']=datetime.now(timezone.utc).isoformat().replace('+00:00','Z')
    return added

def selftest():
    a={'title':'Garamendi ve ilegal una huelga general por la vivienda','url':'u1'}
    b={'title':'Garamendi considera ilegal la huelga general de vivienda','url':'u2'}
    c={'title':'Verstappen logra la pole en Sepang','url':'u3'}
    assert same_story(a,b) and not same_story(a,c)
    radar={'events':[dict(a,event_id='x',status='ELIGIBLE',source_evidence=[
        {'title':b['title'],'source':'A'},{'title':b['title'],'source':'B'},
        {'title':b['title'],'source':'C'},{'title':b['title'],'source':'D'},
        {'title':c['title'],'source':'RUIDO'}]) ]}
    q={'items':[]}; d={'items':[]}
    added=queue_eligible(radar,q,d,{'items':[]})
    assert added==['x'] and q['items'][0]['source_count']==4
    # una revisión sin novedad material de una historia publicada no reentra
    r2={'events':[dict(a,event_id='x-r2',status='ELIGIBLE_UPDATE',source_evidence=radar['events'][0]['source_evidence'])]}
    assert queue_eligible(r2,{'items':[]},{'items':[{'event_id':'x','status':'PUBLISHED'}]},{'items':[]})==[]
    print('AUTO_QUEUE_SELFTEST_OK')

def main():
    if '--selftest' in sys.argv: return selftest()
    radar=load(RADAR,{'events':[]}); queue=load(QUEUE,{'items':[]})
    decisions=load(DECISIONS,{'items':[]}); prepared=load(PREPARED,{'items':[]})
    added=queue_eligible(radar,queue,decisions,prepared,verbose=True)
    if added: save(QUEUE,queue)
    print('AUTO_WEB_QUEUED',len(added),added)

if __name__=='__main__': main()
