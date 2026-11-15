#!/usr/bin/env python3
"""Consumidor RE V2: D1 privada -> GitHub V2 (sin X, V1 ni Chrome).

Se ejecuta desde GitHub Actions con el token temporal del propio repositorio.
Una solicitud solo se confirma en D1 tras verificar cola y proyección V2.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from .re_request_v2 import request_reexplanation
from .web_top30_v2 import build

REPO = "fabricelop/europapress-rss"
BRANCH = "feature/ttactualidad-v2-clean"
DIR = "v2/ttendencias/state/"


def request_json(url, *, token, method="GET", payload=None):
    headers = {"Authorization": "Bearer " + token,
               "Accept": "application/json", "User-Agent": "TTActualidadV2-RE"}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, method=method, headers=headers,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def github_read(token, filename):
    url = "https://api.github.com/repos/" + REPO + "/contents/" + DIR + filename
    result = request_json(url + "?ref=" + urllib.parse.quote(BRANCH, safe=""), token=token)
    return json.loads(base64.b64decode(result["content"])), result["sha"]


def github_write(token, filename, content, sha):
    payload = {"branch": BRANCH, "sha": sha,
        "message": "V2 RE: actualizar " + filename + " sin publicación",
        "content": base64.b64encode((json.dumps(content, ensure_ascii=False, indent=2) + "\n").encode("utf-8")).decode("ascii")}
    url = "https://api.github.com/repos/" + REPO + "/contents/" + DIR + filename
    result = request_json(url, token=token, method="PUT", payload=payload)
    if not result.get("commit", {}).get("sha"):
        raise RuntimeError("GitHub no confirmó " + filename)


def d1_database(cf_token, cf_account):
    path = "https://api.cloudflare.com/client/v4/accounts/" + cf_account + "/d1/database"
    result = request_json(path + "?per_page=100", token=cf_token)
    if result.get("success") is not True:
        raise RuntimeError("No se pudo enumerar D1 V2")
    matches = [row["uuid"] for row in result.get("result", [])
               if row.get("name") == "ttactualidad-v2-marks" and row.get("uuid")]
    if len(matches) != 1:
        raise RuntimeError("No se ha encontrado D1 V2 de manera inequívoca")
    return path + "/" + matches[0] + "/query"


def d1_sql(url, token, sql, params=None):
    result = request_json(url, token=token, method="POST", payload={"sql": sql, "params": params or []})
    if result.get("success") is not True or not isinstance(result.get("result"), list):
        raise RuntimeError("Consulta D1 no confirmada")
    if not all(entry.get("success") is True for entry in result["result"]):
        raise RuntimeError("D1 notificó error de consulta")
    return result["result"][0].get("results", []) if result["result"] else []


def process_one(gh_token, d1_url, cf_token, row):
    if not isinstance(row, dict) or not all(row.get(k) for k in (
       "trend_id", "base_revision", "entered_top30_at", "requested_at")):
        raise ValueError("Solicitud D1 incompleta")
    queue, sha = github_read(gh_token, "editorial-queue.json")
    history, _ = github_read(gh_token, "history.json")
    updated, action = request_reexplanation(queue, history,
        trend_id=row["trend_id"], base_revision=row["base_revision"],
        entered_top30_at=row["entered_top30_at"], requested_at=row["requested_at"])
    if action == "ENQUEUED":
        github_write(gh_token, "editorial-queue.json", updated, sha)
    # Otro flujo puede haber actualizado el ranking mientras se escribía la cola.
    # Solo se proyecta si la pareja historia/cola sigue siendo consistente.
    latest, _ = github_read(gh_token, "editorial-queue.json")
    current_history, _ = github_read(gh_token, "history.json")
    current_row = latest["items"].get(row["trend_id"]) or {}
    if current_row.get("revision", 0) <= row["base_revision"]:
        raise RuntimeError("GitHub no conservó la revisión RE")
    web, web_sha = github_read(gh_token, "web-top30.json")
    projected = build(current_history, latest)
    if projected != web:
        github_write(gh_token, "web-top30.json", projected, web_sha)
    verify, _ = github_read(gh_token, "web-top30.json")
    assert verify.get("captured_at") == current_history.get("observed_at")
    expected_rev = current_row["revision"]
    displayed = next((x for x in verify.get("items", []) if x.get("trend_id") == row["trend_id"]), None)
    # The trend can have left Top30. In that case it must *not* be projected
    # into today's ranking, but the queued review must still be acknowledged.
    known = [topic for topic in current_history.get("topics", {}).values()
             if topic.get("trend_id") == row["trend_id"]]
    if len(known) != 1 or (displayed is not None and
            displayed.get("revision") not in (expected_rev, row["base_revision"])):
        raise RuntimeError("No se verificó la proyección del RE")
    d1_sql(d1_url, cf_token, "UPDATE re_requests SET status='applied', applied_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE trend_id=? AND base_revision=? AND status='requested'",
           [row["trend_id"], row["base_revision"]])
    print("TT_V2_RE_APPLIED=" + row["trend_id"] + " revision=" + str(expected_rev))


def main():
    gh = os.environ["GH_TOKEN"]
    cf = os.environ["CLOUDFLARE_API_TOKEN"]
    account = os.environ["CLOUDFLARE_ACCOUNT_ID"]
    url = d1_database(cf, account)
    requests = d1_sql(url, cf, "SELECT trend_id, base_revision, entered_top30_at, requested_at FROM re_requests WHERE status='requested' ORDER BY requested_at LIMIT 10")
    print("TT_V2_RE_PENDING=" + str(len(requests)))
    errors=[]
    for item in requests:
        try:
            # The V2 branch is written by the 15-minute radar, editorial
            # workers and image workers concurrently. GitHub may reject an
            # otherwise safe CAS update with 409: reread the latest state.
            for attempt in range(6):
                try:
                    process_one(gh,url,cf,item)
                    break
                except urllib.error.HTTPError as conflict:
                    if conflict.code != 409 or attempt == 5:
                        raise
                    print("TT_V2_RE_CONCURRENT_RETRY=" + str(attempt + 1),flush=True)
                    time.sleep(min(3, (attempt + 1) * 0.5))
        except (ValueError,RuntimeError,urllib.error.HTTPError,urllib.error.URLError,KeyError,AssertionError) as exc:
            errors.append(str(exc))
            print("TT_V2_RE_NOT_APPLIED=" + item.get("trend_id", "?") + ":" + str(exc), file=sys.stderr)
    if errors:
        raise RuntimeError(str(len(errors)) + " solicitudes RE pendientes de reintento")


if __name__ == "__main__":
    main()
