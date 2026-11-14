#!/usr/bin/env python3
"""GitHub issue -> authenticated V2 E request. Only for GitHub Actions.

No local browser is opened, no V1 data written, no publication. GitHub token
is supplied by Actions and is never embedded in the public page.
"""
import base64
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

from reelaboration_v2 import apply, request, ID_PATTERN

REPO = "fabricelop/europapress-rss"
BRANCH = "feature/ttactualidad-v2-clean"
QUEUE = "v2/ttendencias/state/editorial-queue.json"
TITLE = re.compile(r"^V2-REELABORAR:(trv2-[a-f0-9]{24}):r([1-9][0-9]*)$")
TOKEN = os.environ.get("GITHUB_TOKEN") or ""
API = "https://api.github.com/repos/" + REPO
HEADERS = {
    "Accept": "application/vnd.github+json",
    "Authorization": "Bearer " + TOKEN,
    "User-Agent": "TTActualidadV2-Reelaboration",
    "X-GitHub-Api-Version": "2022-11-28",
}


def api(method, uri, obj=None):
    if not TOKEN:
        raise RuntimeError("Falta GITHUB_TOKEN de Actions")
    data = json.dumps(obj).encode("utf-8") if obj is not None else None
    headers = dict(HEADERS)
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + uri, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=35) as res:
            body = res.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        if error.code in (409, 422):
            raise ValueError("CONFLICT_HTTP_" + str(error.code)) from None
        raise RuntimeError("Github HTTP " + str(error.code)) from None


def read():
    from urllib.parse import quote
    doc = api("GET", "/contents/" + QUEUE + "?ref=" + quote(BRANCH, safe=""))
    return json.loads(base64.b64decode(doc["content"])), doc["sha"]


def write(doc, sha):
    content = base64.b64encode((json.dumps(doc, ensure_ascii=False, indent=2)
                                + "\n").encode("utf-8")).decode("ascii")
    return api("PUT", "/contents/" + QUEUE,
               {"message": "v2: accept/apply authenticated reelaboration E",
                "branch": BRANCH, "sha": sha, "content": content})


def update(mutator):
    for attempt in range(7):
        doc, sha = read()
        revised, action = mutator(doc)
        if revised == doc:
            return action
        try:
            write(revised, sha)
        except ValueError as error:
            if not str(error).startswith("CONFLICT_HTTP_") or attempt == 6:
                raise
            time.sleep(1 + attempt)
            continue
        verified, _ = read()
        if verified == revised:
            return action
        if attempt == 6:
            raise RuntimeError("No se verifico la revision tras la escritura")
    raise RuntimeError("No se pudo completar E tras siete intentos")


def notify_issue(issue_number, body, close=False):
    api("POST", "/issues/" + str(issue_number) + "/comments", {"body": body})
    if close:
        api("PATCH", "/issues/" + str(issue_number), {"state": "closed"})


def new_issue():
    event_path = pathlib.Path(os.environ["GITHUB_EVENT_PATH"])
    event = json.loads(event_path.read_text(encoding="utf-8"))
    issue = event.get("issue") or {}
    title = str(issue.get("title") or "")
    match = TITLE.fullmatch(title)
    sender = (event.get("sender") or {}).get("login")
    author = (issue.get("user") or {}).get("login")
    if sender != "fabricelop" or author != "fabricelop" or not match:
        print("TT_V2_E_ISSUE_IGNORED=YES")
        return
    tid, revision = match.group(1), int(match.group(2))
    number = issue.get("number")
    if not isinstance(number, int) or number <= 0:
        raise ValueError("Issue no identificado")
    print("TT_V2_E_ISSUE=" + str(number))
    recorded = update(lambda q: request(q, trend_id=tid, expected_revision=revision,
                                        issue_number=number, requested_by="fabricelop"))
    print("TT_V2_E_REQUEST=" + recorded)
    if recorded not in ("recorded", "already_requested"):
        raise RuntimeError("No se pudo registrar solicitud E")
    result = update(lambda q: apply(q, trend_id=tid))
    print("TT_V2_E_RESULT=" + result)
    if result == "applied":
        notify_issue(number, "Reelaboración V2 aceptada: nueva revisión pendiente. La anterior se conserva íntegra. No hay publicación automática.", True)
    elif result == "deferred_active_chat":
        notify_issue(number, "E registrada. Se mantiene pendiente mientras exista una conversación o recuperación activa; no se interrumpe ningún envío.")
    else:
        notify_issue(number, "E registrada; revisar cola V2. Estado: " + result)


def process_deferred():
    doc, _ = read()
    targets = [(tid, (row.get("reelaboration_requested") or {}).get("issue_number"))
               for tid, row in doc.get("items", {}).items()
               if row.get("reelaboration_requested")]
    print("TT_V2_E_DEFERRED_COUNT=" + str(len(targets)))
    for tid, issue_number in targets:
        if not ID_PATTERN.fullmatch(tid):
            continue
        try:
            status = update(lambda q, t=tid: apply(q, trend_id=t))
            print("TT_V2_E_DEFERRED=" + tid + ":" + status)
            if status == "applied" and type(issue_number) is int:
                notify_issue(issue_number, "Reelaboración V2 iniciada en una nueva revisión; historial anterior conservado.", True)
        except ValueError as error:
            print("TT_V2_E_DEFERRED_CONFLICT=" + tid + ":" + str(error))


def main():
    kind = os.environ.get("GITHUB_EVENT_NAME", "")
    if kind == "issues":
        new_issue()
    elif kind in ("schedule", "workflow_dispatch"):
        process_deferred()
    else:
        raise RuntimeError("Evento no autorizado: " + kind)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        print("TT_V2_E_ERROR=" + str(err), file=sys.stderr)
        sys.exit(1)
