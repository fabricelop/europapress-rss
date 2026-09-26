#!/usr/bin/env python3
"""Deliver materialized images whose public app URL is unavailable."""
import json
import mimetypes
import os
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
PREP=ROOT/'ttittulares/prepared.json'
ERRORS=ROOT/'ttittulares/execution-errors.json'
FILES=ROOT/'ttittulares/generated-images'

def save(path,obj):
    path.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

def available(url):
    if not url.startswith('https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/'):
        return False
    try:
        with urllib.request.urlopen(urllib.request.Request(url,headers={'Range':'bytes=0-32'}),timeout=8) as r:
            return r.status in (200,206) and r.headers.get('content-type','').startswith('image/') and bool(r.read(16))
    except Exception:
        return False

def send_photo(path,title):
    token=os.environ['TELEGRAM_BOT_TOKEN'];chat=os.environ['TELEGRAM_CHAT_ID']
    boundary='----ttittulares'+uuid.uuid4().hex
    fields={'chat_id':chat,'caption':('TTiTTulares · imagen\n'+title)[:1024],
            'reply_markup':json.dumps({'inline_keyboard':[[{'text':'🗑️ Borrar','callback_data':'delete:message'}]]})}
    body=b''
    for k,v in fields.items():
        body+=(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n').encode()
    mime=mimetypes.guess_type(path.name)[0] or 'image/jpeg'
    body+=(f'--{boundary}\r\nContent-Disposition: form-data; name="photo"; filename="{path.name}"\r\nContent-Type: {mime}\r\n\r\n').encode()+path.read_bytes()+f'\r\n--{boundary}--\r\n'.encode()
    req=urllib.request.Request(f'https://api.telegram.org/bot{token}/sendPhoto',data=body,headers={'Content-Type':f'multipart/form-data; boundary={boundary}'})
    with urllib.request.urlopen(req,timeout=30) as response:
        result=json.load(response)
    if not result.get('ok'): raise RuntimeError(str(result.get('description') or 'Telegram rechazó la foto'))
    return result['result']['message_id']

def main():
    prep=json.loads(PREP.read_text(encoding='utf-8'))
    errors=json.loads(ERRORS.read_text(encoding='utf-8'))
    changed=False
    for item in prep.get('items',[]):
        if item.get('image_status') not in ('ready','working') or item.get('image_telegram_delivered'):
            continue
        image=item.get('image') or {}
        if not image.get('generated') or not image.get('url') or available(str(image['url'])):
            continue
        eid=str(item.get('event_id') or '');revision=int(item.get('revision') or 1)
        candidates=list(FILES.glob(f'{eid}-r{revision}.*'))
        try:
            if not candidates: raise RuntimeError('raster no disponible para Telegram')
            mid=send_photo(candidates[0],str(item.get('title') or eid))
            item['image_status']='telegram';item['image_delivery']='telegram';item['image_app_available']=False
            item['image_pending']=False;item['image_telegram_delivered']=True
            item['image_telegram_message_id']=mid
            item['image_telegram_delivered_at']=datetime.now(timezone.utc).isoformat().replace('+00:00','Z')
            item.pop('image',None)
        except Exception as exc:
            reason=f'{type(exc).__name__}: {exc}'
            item['image_status']='none';item['image_delivery']='none';item['image_app_available']=False
            item['image_pending']=False;item['image_failure_reason']=reason
            item.pop('image',None)
            errors.setdefault('items',[]).append({'at':datetime.now(timezone.utc).isoformat().replace('+00:00','Z'),
                'event_id':eid,'phase':'telegram','reason':reason,
                'remediation_prompt':f'Revisa fallback Telegram de TTiTTulares para {eid}: {reason}. Corrige la causa antes del siguiente intento.'})
            print('IMAGE_FALLBACK_ERROR',eid,reason)
        changed=True
    if changed:
        errors['items']=errors.get('items',[])[-200:]
        save(PREP,prep);save(ERRORS,errors)

if __name__=='__main__': main()
