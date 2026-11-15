#!/usr/bin/env python3
"""Build self-contained V2 ImageGen jobs from a persisted editorial record.

The source editorial chat is deliberately irrelevant. A new chat and its URL
belong only to the image worker, which attaches that URL after sending.
"""
from __future__ import annotations
import argparse
import json
import hashlib
import pathlib
import secrets
import sys

try:
    from .image_intake_v2 import validate_job, fingerprint
except ImportError:
    from image_intake_v2 import validate_job, fingerprint

def proposed_job(row, *, attempt=1, nonce=None):
    if row.get("status") not in ("captured_review","ready"):
        raise ValueError("V2_IMAGE_EDITORIAL_NOT_CAPTURED")
    tid=row.get("trend_id")
    revision=row.get("revision")
    capture=row.get("capture") or {}
    answer=capture.get("answer")
    if (not isinstance(answer,str) or not answer.strip() or
        capture.get("revision")!=revision or
        (capture.get("sha256") is not None and
         capture["sha256"]!=fingerprint(answer))):
        raise ValueError("V2_IMAGE_SOURCE_CAPTURE_INVALID")
    if type(attempt) is not int or not 1<=attempt<=99:
        raise ValueError("V2_IMAGE_ATTEMPT_INVALID")
    if nonce is None:nonce=secrets.token_hex(12)
    if not isinstance(nonce,str) or not 8<=len(nonce)<=60 or not all(ch.isalnum() or ch in "_-" for ch in nonce):
        raise ValueError("V2_IMAGE_NONCE_INVALID")
    command="v2-img-"+tid+"-r"+str(revision)+"-a"+str(attempt)+"-"+nonce
    # Texto contrastado ya guardado en GitHub; no se pide al chat de imagen que
    # investigue ni que reescriba la explicación. No se consulta su chat origen.
    brief=" ".join(answer.split())[:6000]
    # Referencia V1: trends/editorial-style.md, escena narrativa tipo Cleveland.
    styles=("cómic europeo editorial con personajes expresivos y dibujo nítido",
            "grabado moderno con volumen, luces y humor narrativo",
            "tinta y acuarela con profundidad, textura y una escena viva",
            "caricatura editorial 3D con iluminación cinematográfica")
    style=styles[int.from_bytes(hashlib.sha256(tid.encode("utf-8")).digest()[:2],"big")%len(styles)]
    prompt=("TT_V2_IMAGE_JOB_V1 "+command+" "+tid+" | "
            "Usa ImageGen AHORA y genera UNA SOLA imagen GAG original. "
            "Este es un CHAT NUEVO e independiente: no busques ni abras la conversación "
            "donde se redactó el texto, no investigues ni reescribas la explicación. "
            "Tendencia: "+str(row.get("name") or tid)+". "
            "Identificador: "+tid+". Revisión: "+str(revision)+". "
            "TEXTO EDITORIAL YA EXPLICADO (fuente del gag; no lo reescribas): "+brief+". "
            "DIRECCIÓN VISUAL: "+style+". Aplica el estilo editorial V1: "
            "escena narrativa única con protagonistas, acción reconocible, una metáfora "
            "o exageración visual relacionada con el hecho, expresiones, profundidad, "
            "iluminación y textura. Una sola idea que se entienda sin leer texto, "
            "en 1-2 segundos; más gag, menos barroquismo. Acabado profesional "
            "y mínimo 1024px de anchura. No esquemas, infografías, flechas, "
            "conectores, medallones, avatares flotantes, paneles, marcadores, "
            "dashboards ni collage. Cero titulares, hashtags, rótulos, marcas "
            "de agua o texto superpuesto; no dibujes guindillas, chiles ni símbolos 🌶️. "
            "En sucesos graves no hagas humor a costa de víctimas. Si la causa "
            "de la tendencia no está confirmada, evita presentar hipótesis como hechos. "
            "No publiques en redes ni modifiques GitHub.")
    result={"version":1,"trend_id":tid,"revision":revision,"attempt":attempt,
            "command_id":command,
            "editorial_sha256":fingerprint(answer),"prompt":prompt,
            "state":"pending_imagegen"}
    validate_job(result)
    return result

def stage(directory,row,*,attempt=1):
    root=pathlib.Path(directory)
    root.mkdir(parents=True,exist_ok=True)
    tid,revision=row.get("trend_id"),row.get("revision")
    index=root/(tid+"-r"+str(revision)+".index.json")
    if index.exists():
        previous=json.loads(index.read_text(encoding="utf-8"))
        validate_job(previous)
        if previous["trend_id"]!=tid or previous["revision"]!=revision or previous["editorial_sha256"]!=fingerprint((row.get("capture") or {}).get("answer") or ""):
            raise ValueError("V2_IMAGE_INDEX_CONTEXT_CHANGED")
        return previous,"already_staged"
    job=proposed_job(row,attempt=attempt)
    path=root/(job["command_id"]+".json")
    with path.open("x",encoding="utf-8") as handle:json.dump(job,handle,ensure_ascii=False,indent=2)
    try:
        with index.open("x",encoding="utf-8") as handle:json.dump(job,handle,ensure_ascii=False,indent=2)
    except FileExistsError:
        path.unlink(missing_ok=True)
        raise ValueError("V2_IMAGE_INDEX_CONCURRENT_REQUEST")
    return job,"staged"

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--trend-id",required=True)
    parser.add_argument("--revision",type=int,required=True)
    parser.add_argument("--request",action="store_true")
    args=parser.parse_args()
    from editorial_run_v2 import queue_read,module,ROOT
    api=module("persist_capture_github.py","v2_image_jobs_github")
    q,_=queue_read(api,api.token())
    row=q["items"].get(args.trend_id)
    if not row or row.get("revision")!=args.revision:raise ValueError("V2_IMAGE_REVISION_NOT_CURRENT")
    if not args.request:
        planned=proposed_job(row,nonce="dryrun12345678")
        print("TT_V2_IMAGE_JOB_DRY_RUN="+planned["command_id"])
        return
    job,status=stage(ROOT/"image-jobs",row)
    print("TT_V2_IMAGE_JOB_STATE="+status)
    print("TT_V2_IMAGE_JOB_ID="+job["command_id"])
    print("TT_V2_IMAGE_PUBLISHED=NO")

if __name__=="__main__":
    try:main()
    except Exception as exc:
        print("TT_V2_IMAGE_JOB_ERROR="+str(exc)[:150],file=sys.stderr)
        sys.exit(1)
