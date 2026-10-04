#!/usr/bin/env python3
import json, sys, re, unicodedata
from difflib import SequenceMatcher
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
RADAR=ROOT/'telegram'/'events.json'
QUEUE=ROOT/'telegram'/'editorial-processing.json'
DECISIONS=ROOT/'ttittulares'/'decisions.json'
PREPARED=ROOT/'ttittulares'/'prepared.json'
CONTROL_MODE=ROOT/'ttittulares'/'control-mode.json'
CONFIG=ROOT/'ttittulares'/'config.json'
MIN_SOURCES=4

STOP={'de','del','la','las','el','los','un','una','unos','unas','y','o','en','a','por','para','con','sin','sobre','que','se','su','sus','al','es','tras','ante','como','más','mas','ya','hoy','este','esta','estos','estas'}

SOURCE_FAMILIES={
    'Antena 3 Noticias':'Atresmedia','laSexta Noticias':'Atresmedia','Onda Cero':'Atresmedia',
    'Telecinco Noticias':'Mediaset','Noticias Cuatro':'Mediaset','Público · Tremending':'Público',
}

def load(path, default, required=False):
    if not path.exists():
        if required: raise RuntimeError(f'Falta el archivo requerido: {path}')
        return default
    try: value=json.loads(path.read_text(encoding='utf-8'))
    except Exception as exc: raise RuntimeError(f'JSON inválido en {path}: {exc}') from exc
    if not isinstance(value,dict): raise RuntimeError(f'Esquema inválido en {path}: se esperaba un objeto JSON')
    return value

def validate_radar(radar):
    if not isinstance(radar.get('events'),list):
        raise RuntimeError("Esquema inválido en telegram/events.json: 'events' debe ser una lista")
    for pos,row in enumerate(radar['events']):
        if not isinstance(row,dict): raise RuntimeError(f'events[{pos}] no es un objeto')
        if str(row.get('status') or '') in {'ELIGIBLE','ELIGIBLE_UPDATE'}:
            if not row.get('id') or not isinstance(row.get('appearances'),list):
                raise RuntimeError(f'events[{pos}] apto necesita id y appearances')
    return radar

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

def source_family(source): return SOURCE_FAMILIES.get(source,source)

def evidence_for(row):
    # ELIGIBLE/ELIGIBLE_UPDATE ya ha superado en radar_no_d1.py el consenso de
    # evidencia independiente y la poda de outliers. No volvemos a exigir que
    # cada paráfrasis coincida directamente con el título canónico: esa segunda
    # barrera era más estricta que el radar y bloqueaba noticias válidas justo
    # después de declararlas ELIGIBLE. Conservamos una sola aparición por
    # familia independiente, que es exactamente la unidad del umbral editorial.
    matched=[]; seen=set()
    evidence=row.get('appearances')
    if evidence is None: evidence=row.get('source_evidence')
    for ev in evidence or []:
        if not isinstance(ev,dict) or str(ev.get('source_type') or 'general')!='general': continue
        src=str(ev.get('source') or '').strip()
        family=source_family(src)
        if not src or family in seen: continue
        seen.add(family)
        item=dict(ev); item['source_family']=family; matched.append(item)
    return matched

def is_material_update(row):
    if str(row.get('status') or '')!='ELIGIBLE_UPDATE': return True
    ctx=row.get('update_context') or {}
    return bool(row.get('material_update') is True or ctx.get('material_update') is True or ctx.get('material_change') is True)

def is_current(row, hours=24):
    raw=row.get('last_seen') or row.get('eligible_at') or row.get('first_seen')
    if not raw: return True
    try:
        seen=datetime.fromisoformat(str(raw).replace('Z','+00:00'))
        if seen.tzinfo is None: seen=seen.replace(tzinfo=timezone.utc)
    except Exception:
        return True
    return seen.astimezone(timezone.utc) >= datetime.now(timezone.utc)-timedelta(hours=hours)

LOTTERY_GAMES=('bonoloto','euromillones','la primitiva','gordo de la primitiva','eurojackpot','eurodreams','loteria nacional','loteria de navidad','loteria del nino','cupon once','cupon diario','cuponazo','sueldazo','super once','triplex','mi dia','lototurf','quinigol','quiniela')
ROUTINE_DRAW=('comprobar','resultado','resultados','combinacion ganadora','numero premiado','numeros premiados','numeros ganadores','sorteo de hoy','sorteo hoy','sorteo del','sorteo de la','combinacion del','premios de hoy')
MATERIAL_LOTTERY=('acertante','un ganador','una ganadora','reparte','repartido','vendido en','cae en','premio record','fraude','estafa','detenido','detenida','investiga','investigacion','error','fallo','cancelado','suspendido','cambio de reglas','cambio normativo','nueva norma','nuevo sistema')

def is_routine_lottery_result(row):
    title=norm(row_title(row))
    if not title or not any(term in title for term in LOTTERY_GAMES): return False
    if any(term in title for term in MATERIAL_LOTTERY): return False
    return any(term in title for term in ROUTINE_DRAW)

def queue_eligible(radar, queue, decisions, prepared=None, verbose=False, minimum=MIN_SOURCES):
    prepared=prepared or {'items':[]}
    qitems=queue.get('items') or []
    terminal=terminal_map(decisions)
    active=[x for x in qitems if str(x.get('status') or '') in {'PROCESSING','READY'}]
    history=list(prepared.get('items') or [])
    prepared_ids={str(x.get('event_id') or '') for x in history if x.get('event_id')}
    added=[]
    for row in radar.get('events') or []:
        st=str(row.get('status') or '')
        if st not in {'ELIGIBLE','ELIGIBLE_UPDATE'}: continue
        eid=str(row.get('id') or row.get('event_id') or '')
        if not eid: continue
        if is_routine_lottery_result(row):
            if verbose: print('AUTO_QUEUE_ROUTINE_DRAW_SKIPPED',eid)
            continue
        if eid in terminal:
            if verbose: print('AUTO_QUEUE_TERMINAL_SKIPPED',eid,terminal[eid].upper())
            continue
        if eid in prepared_ids:
            if verbose: print('AUTO_QUEUE_PREPARED_SKIPPED',eid)
            continue
        if not is_current(row):
            if verbose: print('AUTO_QUEUE_STALE_SKIPPED',eid,row.get('last_seen') or row.get('eligible_at'))
            continue
        bid=base_id(eid)
        if bid!=eid and bid in terminal and not is_material_update(row):
            if verbose: print('AUTO_QUEUE_REVISION_SKIPPED',eid,'base_terminal',bid)
            continue
        if not is_material_update(row):
            if verbose: print('AUTO_QUEUE_NON_MATERIAL_UPDATE_SKIPPED',eid)
            continue
        if any(str(x.get('event_id') or '')==eid for x in qitems): continue
        evidence=evidence_for(row)
        sources=[]
        for ev in evidence:
            s=str(ev.get('source') or '').strip()
            if s and s not in sources: sources.append(s)
        if len(sources)<minimum:
            if verbose: print('AUTO_QUEUE_EVIDENCE_SKIPPED',eid,len(sources))
            continue
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
        q['event_id']=eid
        q['title']=row_title(row)
        q['status']='PROCESSING'; q['selection_mode']='AUTO_WEB'; q['selected_at']=now
        q['source_evidence']=evidence; q['sources']=sources; q['source_count']=len(sources)
        q['source_families']=[str(ev.get('source_family') or '') for ev in evidence]
        q['drafted_source_count']=len(sources)
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
    radar={'events':[dict(a,id='x',status='ELIGIBLE',appearances=[
        {'title':b['title'],'source':'A'},{'title':b['title'],'source':'B'},
        {'title':b['title'],'source':'C'},{'title':b['title'],'source':'D'}]) ]}
    validate_radar(radar)
    q={'items':[]}; d={'items':[]}
    added=queue_eligible(radar,q,d,{'items':[]})
    assert added==['x'] and q['items'][0]['event_id']=='x' and q['items'][0]['source_count']==4
    lottery={'events':[dict(a,id='lottery',title='Comprobar Lotería Nacional: resultados de hoy',status='ELIGIBLE',appearances=radar['events'][0]['appearances'])]}
    assert queue_eligible(lottery,{'items':[]},d,{'items':[]})==[]
    same_family={'events':[dict(a,id='family',status='ELIGIBLE',appearances=[
        {'title':b['title'],'source':'Antena 3 Noticias'},
        {'title':b['title'],'source':'laSexta Noticias'},
        {'title':b['title'],'source':'Onda Cero'},
        {'title':b['title'],'source':'RTVE'}]) ]}
    assert queue_eligible(same_family,{'items':[]},d,{'items':[]})==[]
    # Regresión: el radar puede validar paráfrasis conectadas aunque alguna no
    # coincida directamente con el canónico. Auto-queue no debe bloquearlas.
    paraphrases={'events':[dict(a,id='paraphrases',status='ELIGIBLE',appearances=[
        {'title':'El temporal deja dos muertos en Cataluña','source':'RTVE'},
        {'title':'Dos fallecidos por las fuertes lluvias catalanas','source':'COPE'},
        {'title':'La tormenta causa dos víctimas mortales en Barcelona','source':'ABC'},
        {'title':'Cataluña afronta un temporal mortal con dos fallecidos','source':'20minutos'}]) ]}
    assert queue_eligible(paraphrases,{'items':[]},d,{'items':[]})==['paraphrases']
    r2={'events':[dict(a,id='x-r2',status='ELIGIBLE_UPDATE',appearances=radar['events'][0]['appearances'])]}
    assert queue_eligible(r2,{'items':[]},{'items':[{'event_id':'x','status':'PUBLISHED'}]},{'items':[]})==[]
    prepared_same={'items':[{'event_id':'x','title':'Título ya preparado'}]}
    assert queue_eligible(radar,{'items':[]},d,prepared_same)==[], 'un event_id preparado no puede reencolarse'
    stale={'events':[dict(a,id='stale',status='ELIGIBLE',last_seen='2026-01-01T00:00:00Z',appearances=radar['events'][0]['appearances'])]}
    assert queue_eligible(stale,{'items':[]},d,{'items':[]})==[], 'un ELIGIBLE caducado no puede reencolarse'
    print('AUTO_QUEUE_SELFTEST_OK')

def main():
    if '--selftest' in sys.argv: return selftest()
    mode_doc=load(CONTROL_MODE,{'mode':'telegram'})
    mode=str(mode_doc.get('mode') or 'telegram').lower()
    if mode!='web':
        print('TTiTTulares no está en modo web: no se encola automáticamente.')
        return 0
    config=load(CONFIG,{})
    minimum=int((config.get('radar') or {}).get('minimum_sources',MIN_SOURCES))
    radar=validate_radar(load(RADAR,{'events':[]},required=True)); queue=load(QUEUE,{'items':[]})
    decisions=load(DECISIONS,{'items':[]}); prepared=load(PREPARED,{'items':[]})
    added=queue_eligible(radar,queue,decisions,prepared,verbose=True,minimum=minimum)
    if added and '--dry-run' not in sys.argv: save(QUEUE,queue)
    print('AUTO_WEB_QUEUED',len(added),added,'DRY_RUN' if '--dry-run' in sys.argv else '')

if __name__=='__main__': main()
