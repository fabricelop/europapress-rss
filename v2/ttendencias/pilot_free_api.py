#!/usr/bin/env python3
"""TTActualidad V2: prueba gratuita por API, un elemento, sin escrituras a producción.

Con GEMINI_API_KEY llama a Gemini en free tier. Sin clave solo valida la cola.
Guarda respuesta local para inspección; no toca main ni publica.
"""
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ID = "trv2-dd5de9a892ab6b7007ef26b6"
BRANCH = "feature/ttactualidad-v2-clean"
QUEUE_URL = f"https://raw.githubusercontent.com/fabricelop/europapress-rss/{BRANCH}/v2/ttendencias/state/editorial-queue.json"
MODEL = "gemini-2.5-flash"
API_BASE = "https://generativelanguage.googleapis.com/v1beta/models/"

def load_json(url, *, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=90) as response:
        return json.load(response)

def main():
    queue = load_json(QUEUE_URL)
    item = queue["items"].get(ID)
    if not item or item["status"] != "pending" or item["revision"] != 1:
        raise RuntimeError("revision o estado cambiados: no ejecutar")
    print("TT_V2_SELECTED=" + ID + " rev=1 name=" + item["name"])
    key = os.getenv("GEMINI_API_KEY")
    if not key:
        print("TT_V2_DRY_RUN=YES: falta GEMINI_API_KEY, ninguna llamada de IA realizada")
        return
    prompt = ("Trabajo editorial de prueba de TTActualidad V2, no publicar. "
              "Investiga por qué " + item["name"] + " es tendencia en España HOY. "
              "No inventes datos ni motivos: si no hay pruebas suficientes, dilo. "
              "Responde en español con explicación concisa, fecha, al menos dos fuentes con URL "
              "comprobables, hashtags relevantes y un remate breve. "
              "Incluye incertidumbre de forma explícita. "
              "Esta es una prueba y no debes modificar archivos ni publicar.")
    payload = {"contents":[{"role":"user","parts":[{"text":prompt}]}],
               "tools":[{"google_search":{}}],
               "generationConfig":{"temperature":0.2}}
    raw = json.dumps(payload).encode()
    req = urllib.request.Request(API_BASE + MODEL + ":generateContent",
        headers={"Content-Type":"application/json","x-goog-api-key":key},
        data=raw,method="POST")
    try:
        with urllib.request.urlopen(req,timeout=90) as response:
            result=json.load(response)
    except urllib.error.HTTPError as exc:
        details=exc.read().decode("utf-8","replace")
        print("TT_V2_API_ERROR_STATUS=" + str(exc.code))
        print("TT_V2_API_ERROR=" + details[:600])
        raise SystemExit(2)
    candidates=result.get("candidates") or []
    parts=((candidates[0].get("content") or {}).get("parts") or []) if candidates else []
    answer="\n".join(part.get("text","") for part in parts if part.get("text")).strip()
    if not answer:
        raise RuntimeError("No se obtuvo una explicación: no marcar READY")
    out=pathlib.Path("v2/ttendencias/state/pilot-free-api-result.json")
    out.parent.mkdir(parents=True,exist_ok=True)
    record={"trend_id":ID,"revision":1,"name":item["name"],
            "source":"gemini-2.5-flash","status":"manual_quality_review",
            "text":answer,"production_modified":False}
    out.write_text(json.dumps(record,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print("TT_V2_API_RESPONSE=YES")
    print("TT_V2_LOCAL_OUTPUT="+str(out))
    print("TT_V2_NOT_PUBLISHED=YES; TT_V2_QUEUE_UNCHANGED=YES")

if __name__=="__main__":
    main()
