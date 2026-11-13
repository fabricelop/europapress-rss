#!/usr/bin/env python3
"""Prueba local sin Chrome: valida el diagnóstico recuperado contra cola V2.

No requiere token GitHub, no escribe en GitHub ni altera archivos de V2.
"""
import json
import os
import pathlib
import sys
import urllib.request
from v2.ttendencias.editorial_capture_state import stage_capture

ROOT = pathlib.Path(os.environ["LOCALAPPDATA"]) / "TTActualidadV2"
DIAG = ROOT / "diagnostics" / "recover-svfinal-cdp.json"
QUEUE_URL = (
    "https://raw.githubusercontent.com/fabricelop/europapress-rss/"
    "feature/ttactualidad-v2-clean/v2/ttendencias/state/editorial-queue.json"
)

def main():
    diag = json.loads(DIAG.read_text(encoding="utf-8"))
    if not diag.get("reply_captured") or not diag.get("cleanup_verified"):
        raise ValueError("No se ha confirmado captura y cierre de Chrome")
    if diag.get("status") != "captured_needs_editorial_validation":
        raise ValueError("Estado de captura inesperado")
    if diag.get("validation") != "paired_turn_id_revision_footer_and_stable_idle":
        raise ValueError("Captura no validada con el extractor actual")
    if diag.get("message_sent") or diag.get("queue_modified") or diag.get("published"):
        raise ValueError("El diagnóstico contiene efectos inesperados")
    req = urllib.request.Request(QUEUE_URL, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=20) as response:
        queue = json.load(response)
    staged, status = stage_capture(
        queue, trend_id=diag["trend_id"], revision=diag["revision"],
        answer=diag["answer"], chat_url=diag["chat_url"], validated_capture=True,
        observed_at=diag.get("observed_at"))
    item = staged["items"][diag["trend_id"]]
    print("TT_V2_STAGE_DRY_RUN=YES")
    print("TT_V2_STAGE_STATUS=" + status)
    print("TT_V2_TREND_ID=" + diag["trend_id"])
    print("TT_V2_REVISION=" + str(diag["revision"]))
    print("TT_V2_ANSWER_CHARS=" + str(len(item["capture"]["answer"])))
    print("TT_V2_ANSWER_SHA256=" + item["capture"]["sha256"])
    print("TT_V2_PREVIEW_STATUS=" + item["status"])
    print("TT_V2_GITHUB_WRITE=NO")
    print("TT_V2_PUBLISHED=NO")

if __name__ == "__main__":
    main()
