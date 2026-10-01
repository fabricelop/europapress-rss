#!/usr/bin/env python3
"""Completa fotos de archivo/fallback para noticias READY sin bloquearlas."""
from __future__ import annotations
import json
from apply_editorial_outbox import PREP, QUEUE, EVENTS, load, save, _enrich_prepared_images

def main():
    prepared=load(PREP,{"project":"TTiTTulares","items":[]})
    queue=load(QUEUE,{"items":[]})
    events=load(EVENTS,{"events":[]})
    changed=_enrich_prepared_images(prepared,queue,events)
    if changed: save(PREP,prepared)
    print(json.dumps({"changed":bool(changed)},ensure_ascii=False))
    return 0

if __name__=="__main__":
    raise SystemExit(main())
