#!/usr/bin/env python3
"""TTActualidad V2: consumidor secuencial y acotado.

Sin --run: simula selección y no escribe en GitHub ni abre Chrome.
Con --run: ejecuta 1..3 tendencias, una por vez, crea Chrome exclusivo en cada
elaboración y exige lectura GitHub/verificación del diario ANTES de continuar.
Nunca publica ni cambia estados a ready.
"""
import argparse
import json
import os
import pathlib
import sys
import time
import importlib.util

import editorial_run_v2 as core
from batch_contract_v2 import verify_persisted, validate_frozen_job
from select_current_top30_v2 import read_history, select_current_top30
from process_lock_v2 import exclusive_v2_lock

LOCK = core.ROOT / "editorial_batch_v2.lock"



def read_journal(trend_id, revision):
    path = core.DIAG_DIR / ("run-" + trend_id + "-r" + str(revision) + ".json")
    if not path.exists():
        raise RuntimeError("Diario local no generado para " + trend_id)
    return json.loads(path.read_text(encoding="utf-8-sig"))


def run_batch(max_jobs, execute):
    api = core.module("persist_capture_github.py", "ttv2_batch_github")
    state = core.module("editorial_capture_state.py", "ttv2_batch_state")
    transcript = core.module("chatgpt_transcript.py", "ttv2_batch_transcript")
    # No token en el diagnóstico ni stdout.
    auth = api.token()
    queue, _ = core.queue_read(api, auth)
    history = read_history(auth)
    initial, age = select_current_top30(queue, history, max_jobs)
    print("TT_V2_BATCH_SOURCE=CURRENT_TOP30_RANK_ORDER_FROZEN", flush=True)
    print("TT_V2_TOP30_AGE_MINUTES=" + str(age), flush=True)
    print("TT_V2_BATCH_MODE=" + ("RUN" if execute else "DRY_RUN"), flush=True)
    print("TT_V2_BATCH_PLAN_COUNT=" + str(len(initial)), flush=True)
    for i, item in enumerate(initial, 1):
        print("TT_V2_BATCH_PLAN_%d=%s:%s:r%d" % (
            i, item["trend_id"], item["name"], item["revision"]), flush=True)
    if not execute:
        print("TT_V2_GITHUB_WRITE=NO", flush=True)
        print("TT_V2_MESSAGE_SENT=NO", flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        return
    if core.profile_pids():
        raise RuntimeError("Chrome V2 ya está abierto; abortar")
    # El orden se congela al INICIAR la tanda: 1 -> 30 del Top30 aceptado.
    # Si la captura cambia mientras ChatGPT investiga y un tema sale del Top30,
    # no cancelar, sustituir ni perder la ficha ya lanzada.
    completed = 0
    for item in initial:
        queue, _ = core.queue_read(api, auth)
        validate_frozen_job(queue, item)
        # La tendencia puede estar ya fuera del Top30: mantener el plan original.
        # run_one hace de nuevo reserva CAS y validaciones anti-duplicados.
        print("TT_V2_BATCH_START=%s:r%d" % (item["trend_id"], item["revision"]), flush=True)
        try:
            core.run_one(api, state, transcript, auth, item)
        except Exception:
            print("TT_V2_BATCH_STOP=RUN_FAILED_NO_RESEND", flush=True)
            raise
        # Un resultado de stdout por sí solo no es éxito: consultar GitHub.
        current, _ = core.queue_read(api, auth)
        journal = read_journal(item["trend_id"], item["revision"])
        digest = verify_persisted(current, journal)
        if core.profile_pids():
            raise RuntimeError("Chrome V2 sigue abierto; no procesar siguiente tendencia")
        completed += 1
        print("TT_V2_BATCH_VERIFIED=%s:%s" % (item["trend_id"], digest), flush=True)
        print("TT_V2_BATCH_COMPLETED=" + str(completed), flush=True)
        if completed < len(initial):
            # Dejar la sesión cerrada antes de abrir otro Chrome.
            time.sleep(2)
    print("TT_V2_BATCH_RESULT=SUCCESS", flush=True)
    print("TT_V2_BATCH_TOTAL=" + str(completed), flush=True)
    print("TT_V2_PUBLISHED=NO", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-jobs", type=int, default=2, choices=(1, 2, 3))
    parser.add_argument("--run", action="store_true",
                        help="Autoriza una tanda secuencial real; sin --run no hay efectos")
    args = parser.parse_args()
    if not args.run:
        run_batch(args.max_jobs, False)
        return
    with exclusive_v2_lock(LOCK):
        run_batch(args.max_jobs, True)

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("TT_V2_BATCH_ERROR=" + str(exc), file=sys.stderr, flush=True)
        print("TT_V2_BATCH_RESULT=FAILED", flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        sys.exit(1)
