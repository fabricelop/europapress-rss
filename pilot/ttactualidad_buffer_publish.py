#!/usr/bin/env python3
"""TTActualidad: manual one-tap Buffer publishing, independently of the legacy X button.

Run ONLY from the dedicated repository_dispatch workflow on the default branch.
The Buffer key lives in the GitHub Actions secret, never in the IPA or repository.
No post is sent unless an exact editorial id/revision AND matching generated image
have been verified from the current checkout of main.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import uuid

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "pilot/ttactualidad-buffer-posts.json"
CLOSED = {"published", "deleted", "dismissed", "removed", "delete_pending"}
PROJECT_ACCOUNT = {"ttittulares": "ttittulares", "ttendencias": "ttendenciasesp"}
API = "https://api.buffer.com"


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def rows(path, key="items"):
    raw = json.loads((ROOT / path).read_text(encoding="utf-8"))
    return raw.get(key, []) if isinstance(raw, dict) else []


def ledger():
    if not LEDGER.exists():
        return {"version": 1, "items": []}
    data = json.loads(LEDGER.read_text(encoding="utf-8"))
    assert isinstance(data.get("items"), list)
    return data


def run(*args):
    return subprocess.run(args, cwd=ROOT, text=True, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def save(data, reason):
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    LEDGER.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    run("git", "add", "--", str(LEDGER.relative_to(ROOT)))
    if not subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=ROOT).returncode:
        run("git", "commit", "-m", "TTActualidad Buffer: " + reason)
        # Workflow concurrency serializes Buffer writers; other app jobs may
        # concurrently touch main, but not this ledger. Rebase without force.
        for attempt in range(5):
            try:
                run("git", "fetch", "--quiet", "origin", "main")
                run("git", "rebase", "origin/main")
                run("git", "push", "origin", "HEAD:main")
                return
            except subprocess.CalledProcessError:
                if attempt == 4:
                    raise RuntimeError("No se pudo confirmar el registro en GitHub")
                time.sleep(2 + attempt * 2)


def graphql(key, query, variables=None):
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    request = Request(API, data=body, method="POST", headers={
        "Authorization": "Bearer " + key, "Content-Type": "application/json",
        "Accept": "application/json"
    })
    try:
        with urlopen(request, timeout=30) as response:
            obj = json.load(response)
    except HTTPError as exc:
        raise RuntimeError("Buffer respondió HTTP " + str(exc.code)) from exc
    except (URLError, TimeoutError) as exc:
        raise RuntimeError("No se pudo confirmar respuesta de Buffer") from exc
    if obj.get("errors"):
        raise ValueError("; ".join(str(e.get("message", "Error GraphQL"))
                                   for e in obj["errors"])[:250])
    return obj.get("data") or {}


def target_channel(key, account):
    orgs = graphql(key, "query { account { organizations { id name } } }")
    organizations = (orgs.get("account") or {}).get("organizations") or []
    found = []
    for org in organizations:
        orgid = org.get("id", "")
        if not orgid:
            continue
        query = """query { channels(input: { organizationId: %s }) {
          id name displayName service externalLink
        } }""" % json.dumps(orgid)
        channels = graphql(key, query).get("channels") or []
        for channel in channels:
            if str(channel.get("service", "")).lower() != "twitter":
                continue
            names = [str(channel.get(x) or "") for x in ("name", "displayName")]
            url = str(channel.get("externalLink") or "")
            if url:
                names.append(urlparse(url).path.strip("/").split("/")[-1])
            if account in {name.strip().lower().lstrip("@") for name in names}:
                found.append(channel["id"])
    if len(set(found)) != 1:
        raise ValueError("Conecta en Buffer exactamente la cuenta X @" + account
                         + " (no se ha seleccionado ninguna cuenta por aproximación)")
    return found[0]


def check_image(url, expected_hash, project):
    parsed = urlparse(url)
    prefix = "/fabricelop/europapress-rss/main/" + project + "/generated-images/"
    if (parsed.scheme != "https" or parsed.hostname != "raw.githubusercontent.com"
        or not parsed.path.startswith(prefix)
        or not parsed.path.lower().endswith((".png", ".jpeg", ".jpg", ".webp"))
        or parsed.query or parsed.fragment or
        not re.fullmatch(r"[a-f0-9]{64}", str(expected_hash))):
        raise ValueError("Imagen IA no verificada: URL o SHA-256 inválidos")
    req = Request(url, headers={"User-Agent": "TTActualidad-BufferPublisher/1"})
    with urlopen(req, timeout=30) as response:
        data = response.read(12 * 1024 * 1024 + 1)
        if len(data) > 12 * 1024 * 1024:
            raise ValueError("Imagen IA supera 12 MB")
    if hashlib.sha256(data).hexdigest() != expected_hash:
        raise ValueError("Imagen IA no coincide con el SHA-256 editorial")
    return url


def editorial(project, event_id, revision):
    if project == "ttittulares":
        prepared = [x for x in rows("ttittulares/prepared.json")
                    if x.get("event_id") == event_id and x.get("revision") == revision]
        if len(prepared) != 1:
            raise ValueError("Noticia o revisión ya no está preparada en main")
        item = prepared[0]
        if any(x.get("event_id") == event_id and
               str(x.get("status", "")).lower() in CLOSED
               for x in rows("ttittulares/decisions.json")):
            raise ValueError("Noticia ya cerrada en Listas")
        text = str((item.get("tweet") or {}).get("text") or "")
        catalog = rows("ttittulares/site-ai-images.json", "images")
        matched = [x for x in catalog if x.get("target_id") == event_id
                   and x.get("revision") == revision and x.get("editorial_text") == text]
    else:
        explained = [x for x in rows("trends/telegram-manual-explained.json")
                     if x.get("id") == event_id and x.get("revision") == revision
                     and x.get("status") == "explained"]
        if len(explained) != 1:
            raise ValueError("Tendencia o revisión ya no está explicada en main")
        item = explained[0]
        text = str(item.get("explanation") or "")
        catalog = rows("trends/site-ai-images.json", "images")
        matched = [x for x in catalog if x.get("target_id") == event_id
                   and x.get("revision") == revision
                   and x.get("explanation") == text
                   and x.get("explained_at") == item.get("explained_at")]
        if any((x.get("id") == event_id or x.get("event_id") == event_id)
               and str(x.get("status", "")).lower() in CLOSED
               and int(x.get("revision") or 0) >= revision
               for x in rows("trends/mobile-decisions.json")):
            raise ValueError("Tendencia ya cerrada en Listas")
    if not text.strip() or len(text) > 600:
        raise ValueError("Texto no disponible o demasiado largo para publicación directa")
    if len(matched) != 1:
        raise ValueError("Falta imagen GAG IA verificada para esta revisión y texto")
    img = matched[0]
    return text, check_image(str(img.get("image_url") or ""),
                             str(img.get("sha256") or ""), project)


def set_state(row, state, **extra):
    row["state"] = state
    row["checked_at"] = utc_now()
    row.update(extra)


def reconcile(data, key):
    changed = False
    for item in data["items"]:
        if item.get("state") != "pending" or not item.get("buffer_post_id"):
            continue
        post_id = item["buffer_post_id"]
        try:
            result = graphql(key, "query($input: PostInput!) { post(input: $input) {"
                             " id status sentAt externalLink channelId } }",
                             {"input": {"id": post_id}})
            post = result.get("post") or {}
            if post.get("id") != post_id or post.get("channelId") != item.get("channel_id"):
                continue
            status = str(post.get("status") or "").lower()
            if status == "sent":
                set_state(item, "sent", sent_at=post.get("sentAt") or utc_now(),
                          post_url=post.get("externalLink") or "")
                changed = True
            elif status in ("error", "failed"):
                set_state(item, "failed", error="Buffer marcó error de publicación")
                changed = True
        except (ValueError, RuntimeError, HTTPError, URLError) as exc:
            print("Comprobación Buffer pendiente para " + post_id + ": " + str(exc))
    if changed:
        save(data, "confirmar estados de X")
    # Close canonical Listas only after Buffer confirmed the destination post.
    for item in data["items"]:
        if item.get("state") != "sent" or item.get("closure_dispatched"):
            continue
        token = os.getenv("GH_TOKEN", "")
        if not token:
            continue
        payload = {"event_type": "ttactualidad_action_v1", "client_payload": {
            "project": item["project"], "event_id": item["event_id"],
            "revision": item["revision"], "decision": "published",
            "request_id": str(uuid.uuid4()),
            "trend_name": "", "trend_rank": 0
        }}
        request = Request(
            "https://api.github.com/repos/fabricelop/europapress-rss/dispatches",
            data=json.dumps(payload).encode(), method="POST",
            headers={"Authorization": "Bearer " + token,
                     "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28",
                     "User-Agent": "TTActualidad-BufferPublisher"}
        )
        try:
            with urlopen(request, timeout=20) as response:
                if response.status != 204:
                    continue
            item["closure_dispatched"] = True
            save(data, "pedir cierre editorial confirmado")
        except (HTTPError, URLError, RuntimeError) as exc:
            print("Cierre editorial pendiente: " + str(exc))


def publish(data, payload, key):
    project, event_id, revision = (payload.get("project"),
                                   payload.get("event_id"), payload.get("revision"))
    request_id = payload.get("request_id")
    if (project not in PROJECT_ACCOUNT or not isinstance(event_id, str)
        or not re.fullmatch(r"[A-Za-z0-9_-]{6,100}", event_id)
        or type(revision) is not int or revision < 0
        or not isinstance(request_id, str)
        or not re.fullmatch(r"[0-9a-f-]{36}", request_id)):
        raise ValueError("Orden editorial mal formada")
    if any(x.get("project") == project and x.get("event_id") == event_id
           and x.get("revision") == revision and
           x.get("state") in ("reserved", "unknown", "pending", "sent")
           for x in data["items"]):
        print("Publicación ya registrada: no repetir envío a X")
        return
    row = {"request_id": request_id, "project": project, "event_id": event_id,
           "revision": revision, "account": PROJECT_ACCOUNT[project],
           "state": "failed", "requested_at": utc_now()}
    # Before reserving, verify main editorial text and exact AI image plus
    # the target account. Any preflight error cannot publish anything.
    try:
        if not key:
            raise ValueError("Falta BUFFER_API_KEY en GitHub Actions Secrets")
        text, image_url = editorial(project, event_id, revision)
        channel = target_channel(key, PROJECT_ACCOUNT[project])
    except Exception as exc:
        set_state(row, "failed", error=str(exc)[:230])
        data["items"].append(row)
        save(data, "registrar precontrol sin publicar")
        print("No publicado: " + row["error"])
        return
    # Reservation is committed to main before calling external API. If an
    # error occurs after this point, NEVER retry this item blindly.
    row["channel_id"] = channel
    set_state(row, "reserved")
    data["items"].append(row)
    save(data, "reservar publicación sin duplicados")
    mutation = """mutation($input: CreatePostInput!) {
      createPost(input: $input) {
        ... on PostActionSuccess { post { id status sentAt externalLink channelId } }
        ... on MutationError { message }
      }
    }"""
    try:
        result = graphql(key, mutation, {"input": {
            "text": text, "channelId": channel,
            "schedulingType": "automatic", "mode": "shareNow",
            "assets": [{"image": {"url": image_url}}], "source": "TTActualidad"
        }})
        outcome = result.get("createPost") or {}
        post = outcome.get("post")
        if not post:
            set_state(row, "failed", error=str(outcome.get("message") or
                                               "Buffer rechazó la publicación")[:230])
        elif post.get("id") and post.get("channelId") == channel:
            state = "sent" if str(post.get("status")).lower() == "sent" else "pending"
            set_state(row, state, buffer_post_id=post["id"],
                      sent_at=(post.get("sentAt") or utc_now()) if state == "sent" else None,
                      post_url=post.get("externalLink") or "")
        else:
            set_state(row, "unknown", error="Respuesta de Buffer no identificable")
    except Exception as exc:
        # Network errors and malformed responses may happen AFTER publication.
        # Do not allow a second click to create a duplicate post.
        set_state(row, "unknown", error=("Confirmación de Buffer incierta: " + str(exc))[:230])
    save(data, "registrar resultado Buffer")
    print("Buffer: estado " + row["state"])


def main():
    run("git", "config", "user.name", "ttactualidad-buffer[bot]")
    run("git", "config", "user.email", "ttactualidad-buffer[bot]@users.noreply.github.com")
    data = ledger()
    key = os.getenv("BUFFER_API_KEY", "").strip()
    payload = json.loads(os.getenv("TT_BUFFER_REQUEST_JSON", "{}") or "{}")
    if payload:
        publish(data, payload, key)
    if key and any(x.get("state") == "pending" or
                   (x.get("state") == "sent" and not x.get("closure_dispatched"))
                   for x in data["items"]):
        reconcile(data, key)


if __name__ == "__main__":
    main()
