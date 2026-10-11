#!/usr/bin/env python3
"""Evaluaciones locales SLR. Requiere Ollama, sin tareas ChatGPT."""
import json, os, re, sys, urllib.request
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT=Path(__file__).resolve().parent
REQUESTS=ROOT/'requests.json'
OUTPUT=ROOT/'assistant-output.json'
STATE=ROOT/'assistant-state.json'
MODEL=os.environ.get('SR_OLLAMA_MODEL','qwen2.5:7b')
URL=os.environ.get('SR_OLLAMA_URL','http://127.0.0.1:11434/api/generate')
REMINDER=re.compile(r'\b(le recordamos|se lo recordamos|recuerde|queda recordado|recordamos|recordarle|recordarte|se lo recuerda)\b',re.I)
def load(p,default):
    try: return json.loads(p.read_text(encoding='utf-8'))
    except FileNotFoundError: return default
def save(p,data):
    temp=p.with_suffix(p.suffix+'.tmp')
    temp.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    temp.replace(p)
def key(req):
    if req.get('type')=='evaluate' and req.get('tweet_id'): return 'evaluate:'+str(req['tweet_id'])
    if req.get('type')=='telegram_instruction' and req.get('telegram_update_id') is not None: return 'telegram_instruction:'+str(req['telegram_update_id'])
    return ''
def madrid(iso):
    try: return datetime.fromisoformat(iso.replace('Z','+00:00')).astimezone(ZoneInfo('Europe/Madrid')).strftime('%d/%m/%Y %H:%M')
    except Exception: return 'fecha/hora no disponible'
def generate(req):
    instruction=str(req.get('instruction','')).strip()
    prompt=(
      'Eres el redactor de SeLoRecordamos. Genera exactamente cuatro propuestas ingeniosas, '
      'breves, originales y diferenciadas para citar en X. Cada una debe incluir una acción explícita '
      'de recordar (por ejemplo, "Le recordamos" o "Se lo recordamos"). '
      'No inventes datos externos ni ataques personales gratuitos. '
      'No repitas la misma broma. Máximo 256 caracteres por propuesta. '
      'Devuelve SOLO JSON con la forma {"alternatives":["...","...","...","..."]}.\n'
      'Usuario: '+str(req.get('user',''))+'\nTexto: '+str(req.get('text',''))+
      ('\nInstrucción adicional del usuario: '+instruction if instruction else '')
    )
    payload=json.dumps({'model':MODEL,'prompt':prompt,'stream':False,'format':'json','options':{'temperature':0.8}},ensure_ascii=False).encode()
    request=urllib.request.Request(URL,payload,{'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=180) as res:
        result=json.load(res)
    alternatives=json.loads(result['response'])['alternatives']
    if not isinstance(alternatives,list) or len(alternatives)!=4: raise ValueError('El modelo no devolvió cuatro propuestas')
    for index,a in enumerate(alternatives):
        if not isinstance(a,str) or not a.strip() or len(a)>256 or not REMINDER.search(a):
            raise ValueError('Propuesta '+str(index+1)+' no válida')
    return alternatives
def main():
    reqs=load(REQUESTS,{'requests':[]}).get('requests',[])
    doc=load(OUTPUT,{'outputs':[]}); state=load(STATE,{'processed':[]})
    outputs=doc.setdefault('outputs',[]); processed=set(state.setdefault('processed',[]))
    existing={str(x.get('request_key')) for x in outputs if x.get('request_key')}
    count=0; errors=0
    for req in reqs:
        k=key(req)
        if not k or k in existing or k in processed: continue
        try:
            alts=generate(req)
            header=('🧠 SeLoRecordamos · '+str(req.get('user',''))+' · '+madrid(req.get('datetime',''))+
                   '\n\n'+str(req.get('text',''))+
                   ('\n\nInstrucción: '+str(req['instruction']) if req.get('instruction') else ''))
            content=header+'\n\nPropuestas para CITAR en X:\n\n'+'\n\n'.join(f'{letter}) {alt}' for letter,alt in zip('ABCD',alts))
            output={'request_key':k,'original_url':req.get('url',''),
                    'created_at':datetime.now(timezone.utc).isoformat(),
                    'send_to_telegram':True,'telegram_text':content,'alternatives':alts}
            outputs.append(output); state['processed'].append(k); processed.add(k); existing.add(k)
            # Persistir cada candidato para recuperar incluso tras una interrupción.
            save(OUTPUT,doc); save(STATE,state); count+=1
            print('OK',k,flush=True)
        except Exception as exc:
            errors+=1
            print('PENDIENTE',k,str(exc),file=sys.stderr,flush=True)
            # No generar respuestas inventadas ni marcar solicitudes como procesadas.
            if 'urlopen error' in str(exc).lower() or 'connection refused' in str(exc).lower(): break
    print(json.dumps({'completed':count,'errors':errors},ensure_ascii=False))
    return 1 if errors else 0
if __name__=='__main__': sys.exit(main())
