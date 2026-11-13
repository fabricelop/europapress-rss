#!/usr/bin/env python3
"""TTActualidad V2: consumidor editorial continuo, aislado y sin publicación.

SOLO con --run y bandera local de instalación. Elige desde el Top30 vigente
por puesto 1..30. Cada tendencia se entrega al ciclo ChatGPT existente,
con navegador y chat efímeros, captura y verificación GitHub.
No hace polling de V1 ni publica, nunca reenvía un ID/revisión dudoso.
"""
import argparse
import json
import pathlib
import sys
import time
from datetime import datetime, timezone

import editorial_run_v2 as core
from batch_contract_v2 import verify_persisted
from process_lock_v2 import AlreadyRunning, exclusive_v2_lock
from select_current_top30_v2 import read_history
from auto_editorial_policy_v2 import eligible_plan, enabled_text

ROOT = core.ROOT
LOCK = ROOT / "editorial_batch_v2.lock"
ENABLED = ROOT / "auto-editorial-v2.enabled"
STATUS = ROOT / "daemon-status.json"
SENTINEL = "TT_V2_AUTO_EDITORIAL_ENABLED=YES"


def flag_is_enabled(path=ENABLED):
    try:
        return enabled_text(pathlib.Path(path).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return False


def report(state, **kwargs):
    """Diario operativo LOCAL. Nunca registrar tokens, prompts ni respuestas."""
    event = {"service": "ttactualidad-v2", "at": datetime.now(timezone.utc).isoformat(),
             "state": state, "publication_allowed": False}
    for name in ("trend_id", "revision", "top30_age_minutes", "last_error",
                 "completed", "skipped_local_journals"):
        if name in kwargs:
            event[name] = kwargs[name]
    core.store(STATUS, event)
    safe = {key: value for key,value in event.items() if key not in ("last_error",)}
    print("TT_V2_AUTO_STATE=" + state, flush=True)
    print("TT_V2_AUTO_STATUS=" + json.dumps(safe, ensure_ascii=False), flush=True)


def check(api, auth, *, directory=core.DIAG_DIR, now=None):
    queue, _ = core.queue_read(api, auth)
    history = read_history(auth)
    return eligible_plan(queue, history, directory=directory, now=now)


def run_forever(poll_seconds=90, max_jobs=0):
    if not flag_is_enabled():
        raise RuntimeError("AUTORUN BLOQUEADO: instalar y habilitar primero V2")
    api = core.module("persist_capture_github.py", "ttv2_auto_github")
    state = core.module("editorial_capture_state.py", "ttv2_auto_state")
    transcript = core.module("chatgpt_transcript.py", "ttv2_auto_transcript")
    auth = api.token()
    completed = 0
    with exclusive_v2_lock(LOCK):
        report("STARTED", completed=completed)
        print("TT_V2_AUTO_START=YES", flush=True)
        print("TT_V2_AUTO_PUBLICATION=NO", flush=True)
        while flag_is_enabled():
            if max_jobs and completed >= max_jobs:
                report("LIMIT_REACHED", completed=completed)
                break
            try:
                if core.profile_pids():
                    report("WAIT_EXISTING_V2_CHROME", completed=completed)
                    time.sleep(poll_seconds)
                    continue
                # Los errores no se acumulan indefinidamente. Antes de crear
                # cualquier chat nuevo, intentar rescatar la conversación
                # anterior de la incidencia y, si no se puede, crear una
                # nueva revisión con el historial anterior intacto.
                incident_worker = core.module("incident_worker_v2.py", "ttv2_incident_worker")
                if incident_worker.process_one(api, auth):
                    print("TT_V2_AUTO_INCIDENT_PROCESSED=YES", flush=True)
                    continue
                item, age, blocked = check(api, auth)
            except Exception as exc:
                # Captura antigua, caída de GitHub o desfase de fuentes:
                # esperar a la siguiente observación; jamás caer al backlog.
                report("WAIT_SOURCE", completed=completed,
                       last_error=str(exc)[:180])
                time.sleep(poll_seconds)
                continue
            if item is None:
                report("WAIT_NO_CURRENT_JOB", completed=completed,
                       top30_age_minutes=age,
                       skipped_local_journals=len(blocked))
                time.sleep(poll_seconds)
                continue
            trend_id, revision = item["trend_id"], item["revision"]
            report("WORKING", trend_id=trend_id, revision=revision,
                   top30_age_minutes=age, completed=completed)
            print("TT_V2_AUTO_START_JOB=%s:r%d" % (trend_id, revision), flush=True)
            try:
                # Revalidación CAS y un único envío dentro del core.
                # Si el ranking cambia al iniciar, el trabajo YA seleccionado
                # se termina; solo se bloquea revisión/sesión obsoleta.
                core.run_one(api, state, transcript, auth, item)
                final, _ = core.queue_read(api, auth)
                journal = core.DIAG_DIR / (
                    "run-" + trend_id + "-r" + str(revision) + ".json")
                record = json.loads(journal.read_text(encoding="utf-8-sig"))
                digest = verify_persisted(final, record)
                if core.profile_pids():
                    raise RuntimeError("Chrome V2 vivo tras persistir; detener")
                completed += 1
                print("TT_V2_AUTO_COMPLETED=%s:%s" % (trend_id, digest), flush=True)
                report("COMPLETED", trend_id=trend_id, revision=revision,
                       completed=completed)
                # Releer Top30 desde GitHub para dar prioridad a los nuevos
                # puestos en la próxima vuelta; nunca repetir el anterior.
            except Exception as exc:
                # Si quedó send_intent o un diario, el selector no lo reenvía.
                # Los otros puestos siguen siendo elegibles.
                report("JOB_NEEDS_REVIEW", trend_id=trend_id, revision=revision,
                       completed=completed, last_error=str(exc)[:180])
                print("TT_V2_AUTO_JOB_NO_RESEND=%s:r%d" % (trend_id, revision),
                      flush=True)
                try:
                    if core.profile_pids():
                        raise RuntimeError("Chrome V2 no cerrado; parar consumidor")
                except Exception as safety:
                    report("STOP_CHROME_SAFETY", completed=completed,
                           last_error=str(safety)[:180])
                    raise
                time.sleep(poll_seconds)
                continue
            time.sleep(2)
    report("STOPPED", completed=completed)
    print("TT_V2_AUTO_STOPPED=YES", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true",
                        help="Inicio real continuo; requiere bandera local de instalación")
    parser.add_argument("--poll-seconds", type=int, default=90)
    parser.add_argument("--max-jobs", type=int, default=0,
                        help="0 = ilimitado, otros valores para pruebas controladas")
    args = parser.parse_args()
    if not 30 <= args.poll_seconds <= 600 or args.max_jobs < 0:
        parser.error("poll-seconds entre 30 y 600; max-jobs >= 0")
    if not args.run:
        api = core.module("persist_capture_github.py", "ttv2_auto_preflight")
        try:
            item, age, blocked = check(api, api.token())
            print("TT_V2_AUTO_MODE=DRY_RUN", flush=True)
            print("TT_V2_AUTO_ENABLED=" + ("YES" if flag_is_enabled() else "NO"), flush=True)
            print("TT_V2_AUTO_TOP30_AGE_MINUTES=" + str(age), flush=True)
            print("TT_V2_AUTO_NEXT=" + (item["trend_id"] if item else "NONE"), flush=True)
            print("TT_V2_AUTO_SKIP_LOCAL_JOURNALS=" + str(len(blocked)), flush=True)
            print("TT_V2_GITHUB_WRITE=NO", flush=True)
            print("TT_V2_MESSAGE_SENT=NO", flush=True)
            print("TT_V2_PUBLISHED=NO", flush=True)
        except Exception as exc:
            print("TT_V2_AUTO_PREFLIGHT_ERROR=" + str(exc), file=sys.stderr, flush=True)
            raise
        return
    print("TT_V2_AUTO_MODE=RUN", flush=True)
    run_forever(args.poll_seconds, args.max_jobs)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AlreadyRunning, ValueError) as exc:
        print("TT_V2_AUTO_ERROR=" + str(exc), file=sys.stderr, flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        sys.exit(1)
