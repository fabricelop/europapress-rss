#!/usr/bin/env python3
"""TTActualidad: manual one-tap Buffer publishing, independently of the legacy X button.

Run ONLY from the dedicated repository_dispatch workflow on the default branch.
The Buffer key lives in the GitHub Actions secret, never in the IPA or repository.
No post is sent without checking its exact editorial id/revision in main.
Media priority: exact verified AI image; assigned archive image; text only.
"""
import hashlib
import ipaddress
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
SECTION_URL = {
    "ttittulares": "https://ttactualidad.rainyraven22.chatgpt.site/noticias",
    "ttendencias": "https://ttactualidad.rainyraven22.chatgpt.site/tendencias",
}


def x_weight(value):
    """Conservatively emulate TTActualidadXPost's X weighting for iPhone."""
    weight = 0
    for character in value:
        scalar = ord(character)
        # Ignore X's zero-width joins/variation selectors; count supplementary
        # emoji components as two, and do not undercount complex graphemes.
        if scalar in (0xFE0F, 0x200D):
            continue
        if scalar <= 0x10FF or 0x2000 <= scalar <= 0x201F or 0x2032 <= scalar <= 0x2037:
            weight += 1
        else:
            weight += 2
    return weight


def x_shorten(value, budget):
    if x_weight(value) <= budget:
        return value
    if budget < 3:
        return ""
    out = []
    consumed = 0
    for character in value:
        units = x_weight(character)
        if consumed + units + 2 > budget:
            break
        out.append(character)
        consumed += units
    return "".join(out).strip() + "…"


def x_payload(project, editorial):
    """Same section URL and 280-weight text budget as the existing X button."""
    site_url = SECTION_URL[project]
    text = editorial.strip()
    if text.endswith(site_url):
        text = text[:-len(site_url)].strip()
    content_budget = 280 - 23 - x_weight("\n\n")
    if x_weight(text) > content_budget:
        suffix_at = text.rfind("\n\n#")
        if suffix_at < 0:
            suffix_at = text.rfind("\n🌶️")
        if suffix_at >= 0:
            prefix, suffix = text[:suffix_at], text[suffix_at:]
            if x_weight(suffix) < content_budget - 35:
                text = x_shorten(prefix, content_budget - x_weight(suffix)) + suffix
            else:
                text = x_shorten(text, content_budget)
        else:
            text = x_shorten(text, content_budget)
    result = text + "\n\n" + site_url
    if x_weight(text) > content_budget:
        raise ValueError("Texto de X aún excede el límite de caracteres")
    return result

API = "https://api.buffer.com"
# One shared Buffer API-key/MCP budget for every channel in the organization.
# Not per-photo and not independently allocated to @ttittulares / @ttendenciasesp.
LAST_API_QUOTA = None


def observe_rate_limits(headers):
    """Read the actual rolling 30-day aggregate limit, never assume 1,000 per account."""
    global LAST_API_QUOTA
    if headers is None:
        return
    def all_values(name):
        if hasattr(headers, "get_all"):
            values = headers.get_all(name)
            if values is not None:
                return values
        value = headers.get(name) if hasattr(headers, "get") else None
        return [value] if value else []
    # A proxy might combine the three structured fields with commas.
    policies = ",".join(all_values("RateLimit-Policy"))
    limits = ",".join(all_values("RateLimit"))
    selected_quota = None
    selected_name = None
    for match in re.finditer(r'"([^"]+)"\s*;\s*q\s*=\s*(\d+)\s*;\s*w\s*=\s*(\d+)', policies):
        if int(match.group(3)) == 2592000:
            selected_name = match.group(1)
            selected_quota = int(match.group(2))
            break
    if selected_quota is None:
        return
    for match in re.finditer(r'"([^"]+)"\s*;\s*r\s*=\s*(\d+)\s*;\s*t\s*=\s*(\d+)', limits):
        # Match the exact name returned by the 30-day policy selected by
        # window length. Buffer may rename the policy without notice.
        if match.group(1) == selected_name:
            remaining = min(selected_quota, int(match.group(2)))
            LAST_API_QUOTA = {
                "limit": selected_quota, "remaining": remaining,
                "used": max(0, selected_quota - remaining),
                "window_seconds": 2592000,
                "resets_in_seconds": int(match.group(3)),
                "observed_at": utc_now(),
            }
            return


def attach_latest_quota(data):
    """Store one global usage snapshot alongside per-account post receipts."""
    if LAST_API_QUOTA is not None:
        data["api_quota"] = dict(LAST_API_QUOTA)




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
    if subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=ROOT).returncode != 0:
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
            observe_rate_limits(response.headers)
            obj = json.load(response)
    except HTTPError as exc:
        observe_rate_limits(exc.headers)
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
          id name displayName service externalLink isDisconnected isLocked
        } }""" % json.dumps(orgid)
        channels = graphql(key, query).get("channels") or []
        for channel in channels:
            if str(channel.get("service", "")).lower() != "twitter":
                continue
            if channel.get("isDisconnected") or channel.get("isLocked"):
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


def check_image(url, expected_hash, project, event_id=None, revision=None):
    """Verify exact generated bytes and editorial source before using an AI image."""
    parsed = urlparse(url)
    sha = str(expected_hash).lower()
    if (parsed.scheme != "https" or parsed.username or parsed.password or parsed.port
        or parsed.query or parsed.fragment or
        not re.fullmatch(r"[a-f0-9]{64}", sha)
        or not parsed.path.lower().endswith((".png", ".jpeg", ".jpg", ".webp"))):
        raise ValueError("Imagen IA no verificada: URL o SHA-256 inválidos")
    filename = parsed.path.split("/")[-1]
    if parsed.hostname == "raw.githubusercontent.com":
        prefix = "/fabricelop/europapress-rss/main/" + project + "/generated-images/"
        if not parsed.path.startswith(prefix):
            raise ValueError("Origen IA no autorizado")
        if event_id is not None and revision is not None:
            if not filename.startswith(event_id + "-r" + str(revision) + "-"):
                raise ValueError("Imagen IA de una revisión diferente")
    elif parsed.hostname == "ttactualidad-tendencias.rainyraven22.chatgpt.site":
        if not (event_id is not None and revision is not None and
                parsed.path.startswith("/images/" + project + "/" + event_id
                                       + "-r" + str(revision) + "-") and
                sha[:12] in filename.lower()):
            raise ValueError("Imagen de Sites no coincide con la ficha")
    else:
        raise ValueError("Host de imagen IA no autorizado")
    req = Request(url, headers={"User-Agent": "TTActualidad-BufferPublisher/1"})
    with urlopen(req, timeout=30) as response:
        if urlparse(response.geturl()).hostname != parsed.hostname:
            raise ValueError("Redirección IA fuera del origen verificado")
        data = response.read(12 * 1024 * 1024 + 1)
        if len(data) > 12 * 1024 * 1024:
            raise ValueError("Imagen IA supera 12 MB")
    if hashlib.sha256(data).hexdigest() != sha:
        raise ValueError("Imagen IA no coincide con el SHA-256 editorial")
    return url


def archive_url(item, project, event_id, revision):
    """Match the iOS archive gallery: same story ID and latest valid revision."""
    restricted = {"denied", "forbidden", "rejected", "no_permission", "restricted"}
    associated = [item.get(field) for field in ("archive_image", "fallback_image")]
    # Never bypass a source's explicit rights veto by substituting a cached
    # raster of the same article without a separate rights review.
    if any(isinstance(image, dict) and
           str(image.get("rights_status") or "").lower() in restricted
           for image in associated):
        return None
    directory = ROOT / ("ttittulares" if project == "ttittulares" else "trends") / "archive-images"
    if directory.is_dir():
        options = []
        for photo in directory.glob(event_id + "-r*"):
            if not photo.is_file() or photo.is_symlink():
                continue
            match = re.fullmatch(
                re.escape(event_id) + r"-r(\d+)-[^/]+\.(?:png|jpe?g|webp)",
                photo.name, flags=re.IGNORECASE
            )
            if not match or int(match.group(1)) > revision:
                continue
            if not (0 < photo.stat().st_size <= 12 * 1024 * 1024):
                continue
            options.append((int(match.group(1)), photo))
        if options:
            # Prefer exact revision, otherwise closest earlier archive
            # photo, as in ArchivePhotoCatalog on the iPhone.
            _, chosen = max(options, key=lambda pair: (pair[0], pair[1].name))
            return ("https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
                    + chosen.relative_to(ROOT).as_posix())
    for field in ("archive_image", "fallback_image"):
        image = item.get(field)
        if not isinstance(image, dict):
            continue
        if str(image.get("rights_status") or "").lower() in (
            "denied", "forbidden", "rejected", "no_permission", "restricted"
        ):
            continue
        url = image.get("url")
        if not isinstance(url, str):
            continue
        parsed = urlparse(url)
        host = parsed.hostname or ""
        if parsed.scheme != "https" or not host or parsed.username or parsed.password:
            continue
        if parsed.port not in (None, 443) or parsed.fragment or len(url) > 3000:
            continue
        if host == "localhost" or host.endswith((".localhost", ".local", ".internal")):
            continue
        try:
            if not ipaddress.ip_address(host).is_global:
                continue
        except ValueError:
            pass
        return url
    return None


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
                   and x.get("revision") == revision and
                   x.get("editorial_text") == text]
        # An original can be ready before it appears in the public index.
        if not matched and item.get("ai_image_status") == "ready":
            ai = item.get("ai_image") or {}
            if (isinstance(ai, dict) and ai.get("generated") is True and
                    ai.get("provider") == "chat-imagegen" and ai.get("sha256")):
                matched = [{"image_url": ai.get("url"), "sha256": ai["sha256"]}]
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
    for image in matched[:1]:
        try:
            checked = check_image(str(image.get("image_url") or ""),
                                  str(image.get("sha256") or ""), project,
                                  event_id, revision)
            return text, checked, "ai"
        except (ValueError, HTTPError, URLError, OSError, TimeoutError) as exc:
            print("Imagen IA no utilizable; buscando foto de archivo: " + str(exc)[:160])
    archived = archive_url(item, project, event_id, revision)
    if archived:
        return text, archived, "archive"
    return text, None, "text"


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
    attach_latest_quota(data)
    if changed or LAST_API_QUOTA is not None:
        save(data, "confirmar estados de X y cuota API global")
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
        text, image_url, media_type = editorial(project, event_id, revision)
        text = x_payload(project, text)
        channel = target_channel(key, PROJECT_ACCOUNT[project])
    except Exception as exc:
        set_state(row, "failed", error=str(exc)[:230])
        data["items"].append(row)
        attach_latest_quota(data)
        save(data, "registrar precontrol sin publicar")
        print("No publicado: " + row["error"])
        return
    # Reservation is committed to main before calling external API. If an
    # error occurs after this point, NEVER retry this item blindly.
    row["channel_id"] = channel
    row["media_type"] = media_type
    set_state(row, "reserved")
    data["items"].append(row)
    attach_latest_quota(data)
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
            "assets": [{"image": {"url": image_url}}] if image_url else [],
            "needsApproval": False, "source": "TTActualidad"
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
    attach_latest_quota(data)
    save(data, "registrar resultado Buffer y cuota global")
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
