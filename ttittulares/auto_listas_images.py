#!/usr/bin/env python3
"""Idempotent, bounded LISTAS ImageGen enqueuer for the existing Windows bridge.

Only writes command-scoped jobs on the existing GitHub control branch. Does
NOT call ImageGen, publish images, approve them, restart a PC, or alter an iOS
application. Uses durable per-target job files as the one source of enqueue
truth; a lost index write is repaired, never regenerated.
"""
from __future__ import annotations
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = "fabricelop/europapress-rss"
BRANCH = "control/ttittulares-run-trigger-v2"
INDEX = "ttittulares/image-runs/index.json"
JOB_DIR = "ttittulares/image-runs/jobs"
SRC_PREPARED = "ttittulares/prepared.json"
SRC_DECISIONS = "ttittulares/decisions.json"
SRC_CATALOG = "ttittulares/site-ai-images.json"
POLICY_FILE = Path(__file__).with_name("auto_listas_images_policy.json")
VALID_ID = re.compile(r"^[A-Za-z0-9_-]{3,160}$")
FINAL = {"DONE", "ERROR", "FAILED", "CANCELLED", "SUPERSEDED", "LAUNCHED", "PUBLISHED"}
CLOSED = {"published", "dismissed", "deleted", "removed", "delete_pending"}
STYLE_BANK = [
    ("tinta_acuarela", "Caricatura editorial expresiva con línea de tinta y acuarela controlada."),
    ("comic_europeo", "Cómic europeo de línea precisa, volumen sólido y gestos expresivos."),
    ("poster_grafico", "Póster editorial gráfico de formas contundentes y composición limpia."),
    ("absurdo_semirrealista", "Absurdo semirrealista con materiales cuidados y un único gag."),
    ("stop_motion", "Diorama artesanal stop-motion con personajes expresivos."),
    ("retro_60s", "Ilustración publicitaria retro de los 60, elegante y satírica."),
    ("grabado_moderno", "Linograbado moderno de contraste controlado y foco narrativo."),
    ("pop_art", "Pop art editorial refinado, pocas figuras y tramas controladas."),
    ("cartoon_3d", "Cartoon 3D editorial de materiales pulidos y escena sencilla."),
    ("novela_grafica", "Novela gráfica satírica con sombras sobrias y dibujo cuidado."),
]
NO_PEPPER = ("El emoji 🌶️ es solo un marcador tipográfico: PROHIBIDO dibujar guindillas, "
             "chiles, pimientos picantes, su icono, silueta o mascota. "
             "Representa la IDEA del remate, nunca el emoji.")


def iso_now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def when(value):
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def main_story(row, closed_ids, assigned, policy):
    if not isinstance(row, dict):
        return False, "invalid"
    target, revision = row.get("event_id"), row.get("revision")
    if not isinstance(target, str) or not VALID_ID.fullmatch(target) or type(revision) is not int or revision < 0:
        return False, "invalid_identity"
    if (target, revision) in closed_ids or (target, None) in closed_ids or row.get("rewrite_pending") is True:
        return False, "closed_or_rewriting"
    if row.get("with_image") is not True or row.get("disable_ai_image") is True or row.get("sensitive_editorial") is True:
        return False, "image_disabled_or_sensitive"
    if str(row.get("image_mode") or "").lower() in ("fallback_only", "archive_only", "tweet_capture_only", "none"):
        return False, "image_mode_excluded"
    if str(row.get("ai_image_status") or "").lower() in ("ready", "disabled", "failed", "running", "requested", "queued"):
        return False, "already_processed"
    if (target, revision) in assigned:
        return False, "catalog_has_image"
    raster = row.get("image") if isinstance(row.get("image"), dict) else {}
    if row.get("ai_image") or raster.get("generated") or row.get("ai_image_tool_called_at") or row.get("ai_image_attempt") or row.get("ai_image_regenerate_requested"):
        return False, "existing_image_or_attempt"
    tweet = row.get("tweet") or {}
    if not (str(tweet.get("text") or "").strip() and str(tweet.get("remate") or "").strip() and str(row.get("title") or "").strip()):
        return False, "missing_exact_editorial_context"
    prepared = when(row.get("prepared_at"))
    cutoff = when(policy.get("automatic_start_at"))
    if not prepared or not cutoff:
        return False, "missing_prepared_time"
    if prepared < cutoff and target not in policy.get("one_time_backfill_ids", []):
        return False, "before_cutover"
    return True, "eligible"


def decision_closures(decisions):
    closed = set()
    for d in decisions.get("items", []):
        if not isinstance(d, dict) or str(d.get("status") or "").lower() not in CLOSED:
            continue
        key = d.get("event_id")
        if key:
            closed.add((key, d.get("revision") if type(d.get("revision")) is int else None))
    return closed


def catalog_assignments(catalog):
    return {(x.get("target_id"), x.get("revision")) for x in catalog.get("images", [])
            if isinstance(x, dict) and isinstance(x.get("image_url"), str) and x["image_url"]}


def candidates(prepared, decisions, catalog, policy):
    closed = decision_closures(decisions)
    assigned = catalog_assignments(catalog)
    rows = []
    for row in prepared.get("items", []):
        ok, _ = main_story(row, closed, assigned, policy)
        if ok:
            rows.append(row)
    # A one-time explicit backlog is limited to the three user-reported IDs.
    # New articles use the natural Listas order, oldest first to avoid starvation.
    wanted = {x: i for i, x in enumerate(policy.get("one_time_backfill_ids", []))}
    rows.sort(key=lambda x: (0, wanted[x["event_id"]]) if x["event_id"] in wanted
              else (1, str(x.get("prepared_at") or ""), x["event_id"]))
    return rows


def make_job(row, now=None):
    target = row["event_id"]
    revision = row["revision"]
    now = now or iso_now()
    ms = int(when(now).timestamp() * 1000)
    command = f"tt-img-auto-{target}-r{revision}-a1-{ms}"
    digest = hashlib.sha256(f"ttittulares|{target}|r{revision}".encode()).digest()
    index = int.from_bytes(digest[:4], "big") % len(STYLE_BANK)
    name, detail = STYLE_BANK[index]
    style = ("PRINCIPIO FIJO: más gag, menos barroquismo. Un único chiste visual "
             "claro en 1-2 segundos, pocos elementos y excelente acabado de dibujo. "
             + NO_PEPPER + " ESTILO ASIGNADO: " + detail)
    tweet = row["tweet"]
    factual = str(row.get("factual_summary") or row.get("explanation") or "")
    context = {
        "title": row["title"], "revision": revision,
        "factual_summary": factual,
        "tweet_text": tweet["text"], "remate": tweet["remate"],
        "url": str(row.get("url") or ""),
        "citations": (row.get("citations") or [])[:8],
        "image_style": style, "image_style_name": name,
        "image_style_index": index, "editorial_image_mode": "humor",
    }
    instructions = {
        "scope": "Una sola noticia y UNA sola imagen IA, sin duplicados.",
        "exact_input": "Conserva literalmente el texto editorial y el remate; no los reescribas.",
        "visual": style,
        "prohibitions": NO_PEPPER + " No hagas infografía, collage, interfaz, diagrama ni captura de pantalla.",
        "lifecycle": "Solo lanzar ImageGen en la pestaña fija y confirmar LAUNCHED; nunca publicar, aprobar o regenerar automáticamente."
    }
    job = {
        "version": 1, "command_id": command, "requested_at": now, "updated_at": now,
        "status": "REQUESTED", "phase": "queued", "mode": "automatic_ready_repair",
        "delivery_mode": "launch_only", "editorial_image_mode": "humor",
        "executor": "pc_chat_ttittulares_dedicated", "project": "ttittulares",
        "task": "image", "target_id": target, "event_id": target,
        "target_name": row["title"], "revision": revision,
        "regenerate": False, "auto_repair": True, "auto_repair_attempt": 1,
        "manual_retry_version": 0, "chat_command_version": 7,
        "instruction_profile": "ttittulares_gag_v9_varied_style_single_gag",
        "context_snapshot": context, "instructions": instructions,
        "message": "Solicitud automática única desde Listas; esperando al PC."
    }
    item = {
        "command_id": command, "target_id": target, "event_id": target,
        "target_name": row["title"], "revision": revision,
        "requested_at": now,
        "status_path": f"{JOB_DIR}/{target}.json",
        "executor": "pc_chat_ttittulares_dedicated",
        "auto_repair": True, "auto_repair_attempt": 1,
    }
    return job, item


class GitHubFailure(RuntimeError):
    def __init__(self, code, detail):
        super().__init__(f"GitHub HTTP {code}: {str(detail)[:240]}")
        self.code = code


class GitHubClient:
    def __init__(self, token):
        if not token:
            raise RuntimeError("GITHUB_TOKEN required for --apply")
        self.token = token
        self.base = f"https://api.github.com/repos/{REPO}/contents/"

    def call(self, method, path, branch, payload=None):
        url = self.base + urllib.parse.quote(path, safe="/")
        if method == "GET":
            url += "?ref=" + urllib.parse.quote(branch)
        headers = {"Authorization": "Bearer " + self.token,
                   "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28",
                   "User-Agent": "TTiTTulares-Auto-Listas-Images",
                   "Cache-Control": "no-cache"}
        data = json.dumps(payload).encode() if payload else None
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=22) as result:
                return json.load(result)
        except urllib.error.HTTPError as exc:
            if method == "GET" and exc.code == 404:
                return None
            raise GitHubFailure(exc.code, exc.read().decode(errors="replace")) from exc

    def get(self, path, branch=BRANCH):
        result = self.call("GET", path, branch)
        if result is None:
            return None, None
        raw = base64.b64decode(result["content"].replace("\n", ""))
        return json.loads(raw), result["sha"]

    def put(self, path, doc, sha=None, branch=BRANCH):
        raw = json.dumps(doc, ensure_ascii=False, indent=2).encode() + b"\n"
        payload = {"branch": branch, "message": "TTiTTulares: encolar una sola imagen de Listas verificada",
                   "content": base64.b64encode(raw).decode()}
        if sha:
            payload["sha"] = sha
        return self.call("PUT", path, branch, payload)


def is_active(job, now):
    if not isinstance(job, dict):
        return False
    state = str(job.get("status") or "").upper()
    if state in FINAL or (str(job.get("delivery_mode")) == "launch_only" and job.get("pc_launched_at")):
        return False
    if state not in ("REQUESTED", "RUNNING", "GENERATING", "PERSISTING"):
        return False
    issued = when(job.get("requested_at"))
    if not issued:
        return False
    return 0 <= (now-issued).total_seconds() < 45*60


def ensure_index(client, item):
    """Repair an orphan job or append a new one with optimistic CAS retries."""
    for n in range(5):
        idx, sha = client.get(INDEX)
        idx = idx or {"version": 1, "jobs": []}
        rows = list(idx.get("jobs") or [])
        if any(str(x.get("command_id")) == str(item["command_id"]) for x in rows):
            return "already_indexed"
        # Never clobber a later manual image command for this event ID.
        if any(str(x.get("target_id")) == str(item["target_id"]) and
               str(x.get("command_id")) != str(item["command_id"]) for x in rows):
            return "other_command_present"
        rows.append(item)
        nxt = {"version": 1, "updated_at": iso_now(), "jobs": rows[-60:]}
        try:
            client.put(INDEX, nxt, sha)
            return "indexed"
        except GitHubFailure as e:
            if e.code not in (409, 422) or n == 4:
                raise
            time.sleep(0.15*(n+1))
    raise RuntimeError("index_write_failed")


def reconcile_orphan(client, candidate):
    path = f"{JOB_DIR}/{candidate['event_id']}.json"
    job, _ = client.get(path)
    if not job:
        return False
    # Old, manually rejected or completed jobs are never re-issued by this task.
    command = job.get("command_id")
    if command and str(job.get("target_id")) == candidate["event_id"] and \
       int(job.get("revision", -1)) == candidate["revision"] and \
       when(job.get("requested_at")) and \
       0 <= (dt.datetime.now(dt.timezone.utc)-when(job["requested_at"])).total_seconds() < 12*3600:
        item = {"command_id": command, "target_id": candidate["event_id"],
                "event_id": candidate["event_id"],
                "target_name": job.get("target_name", candidate.get("title", "")),
                "revision": job.get("revision", candidate["revision"]),
                "requested_at": job.get("requested_at"),
                "status_path": path,
                "executor": job.get("executor", "pc_chat_ttittulares_dedicated"),
                "auto_repair": bool(job.get("auto_repair", False)),
                "auto_repair_attempt": job.get("auto_repair_attempt", 0)}
        ensure_index(client, item)
    return True


def execute(client, policy):
    if policy.get("enabled") is not True or policy.get("max_new_jobs_per_run") != 1 or policy.get("max_active_jobs") != 1:
        raise RuntimeError("policy must explicitly enable 1 job/run and 1 active job")
    prepared, _ = client.get(SRC_PREPARED, "main")
    decisions, _ = client.get(SRC_DECISIONS, "main")
    catalog, _ = client.get(SRC_CATALOG, "main")
    if not all(isinstance(x, dict) for x in (prepared, decisions, catalog)):
        raise RuntimeError("authoritative main documents missing")
    pending = candidates(prepared, decisions, catalog, policy)
    idx, _ = client.get(INDEX)
    if not isinstance(idx, dict) or not isinstance(idx.get("jobs"), list):
        raise RuntimeError("control image index unavailable; refusing new jobs")
    now = dt.datetime.now(dt.timezone.utc)
    active = 0
    indexed_targets = {str(x.get("target_id")) for x in idx["jobs"]}
    for item in idx["jobs"][-30:]:
        requested = when(item.get("requested_at"))
        if not requested or not 0 <= (now-requested).total_seconds() < 45*60:
            continue
        job, _ = client.get(str(item.get("status_path") or f"{JOB_DIR}/{item.get('target_id')}.json"))
        if is_active(job, now):
            active += 1
    actions = []
    # Repair a previously written job that failed only its index transaction.
    for row in pending:
        if row["event_id"] in indexed_targets:
            actions.append({"id": row["event_id"], "result": "already_in_index"})
            continue
        if reconcile_orphan(client, row):
            actions.append({"id": row["event_id"], "result": "prior_job_reused_or_index_repaired"})
            continue
        if active >= 1:
            actions.append({"id": row["event_id"], "result": "waiting_existing_active_job"})
            break
        # Re-read just before write: no stale revision, reused title or changed text.
        fresh, _ = client.get(SRC_PREPARED, "main")
        latest = next((x for x in fresh.get("items", []) if x.get("event_id") == row["event_id"]), None)
        if not latest or latest != row:
            actions.append({"id": row["event_id"], "result": "changed_before_enqueue"})
            continue
        job, idx_entry = make_job(row)
        path = f"{JOB_DIR}/{row['event_id']}.json"
        try:
            client.put(path, job, None)
        except GitHubFailure as e:
            if e.code == 422:  # writer race with existing manual/auto command
                actions.append({"id": row["event_id"], "result": "concurrent_job_exists"})
                reconcile_orphan(client, row)
                continue
            raise
        outcome = ensure_index(client, idx_entry)
        if outcome == "other_command_present":
            # No prompt should be sent until the index is reconciled manually.
            raise RuntimeError("index conflicting command after job create")
        actions.append({"id": row["event_id"], "result": "new_job_enqueued", "command_id": job["command_id"]})
        break
    return {"eligible": len(pending), "active": active, "actions": actions}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="Request one ImageGen job on control branch")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        from unittest import main as unittest_main
        unittest_main(module="tests.test_auto_listas_images", argv=[sys.argv[0]], exit=False)
        return
    policy = json.loads(POLICY_FILE.read_text(encoding="utf-8"))
    if not args.apply:
        root = Path(__file__).resolve().parents[1]
        prepared = json.loads((root / SRC_PREPARED).read_text())
        decisions = json.loads((root / SRC_DECISIONS).read_text())
        catalog = json.loads((root / SRC_CATALOG).read_text())
        print(json.dumps({"dry_run": True, "candidates": [x["event_id"] for x in candidates(prepared, decisions, catalog, policy)]}, ensure_ascii=False))
        return
    client = GitHubClient(os.environ.get("GITHUB_TOKEN"))
    print(json.dumps(execute(client, policy), ensure_ascii=False))


if __name__ == "__main__":
    main()