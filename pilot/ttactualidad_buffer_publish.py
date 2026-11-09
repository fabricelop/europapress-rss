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
SITE_ROOT = "https://ttactualidad.rainyraven22.chatgpt.site/"
SECTION_URL = {"ttittulares": SITE_ROOT, "ttendencias": SITE_ROOT}
# Retire only managed obsolete footer links, not source URLs in editorial text.
LEGACY_FOOTER_URLS = (
    "https://ttactualidad.rainyraven22.chatgpt.site/noticias",
    "https://ttactualidad.rainyraven22.chatgpt.site/tendencias",
)


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


def x_post_assets(image_url):
    """Only attach a genuine editorial image; never create a website/XCard asset."""
    return [{"image": {"url": image_url}}] if image_url else []


def x_payload(project, editorial):
    """Same canonical homepage URL and 280-weight text budget as the X button."""
    site_url = SECTION_URL[project]
    text = editorial.strip()
    for footer in (*LEGACY_FOOTER_URLS, site_url, site_url.rstrip("/")):
        if text.endswith(footer):
            text = text[:-len(footer)].strip()
            break
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
        # Authenticated manual uploads use the physical GitHub folder
        # "trends" (not the editorial project slug "ttendencias").
        # Both are first-class approved images when recorded for the exact
        # editorial identity in site-ai-images.json.
        folder = "trends" if project == "ttendencias" else "ttittulares"
        prefix = "/fabricelop/europapress-rss/main/" + folder + "/generated-images/"
        if not parsed.path.startswith(prefix):
            raise ValueError("Origen IA no autorizado")
        if event_id is not None and revision is not None:
            if not filename.startswith(event_id + "-r" + str(revision) + "-"):
                raise ValueError("Imagen IA de una revisión diferente")
    elif parsed.hostname in (
        "ttactualidad-tendencias.rainyraven22.chatgpt.site",
        "ttactualidad.rainyraven22.chatgpt.site",
    ):
        if not (event_id is not None and revision is not None and
                parsed.path.startswith("/images/" + project + "/" + event_id
                                       + "-r" + str(revision) + "-") and
                sha[:12] in filename.lower()):
            raise ValueError("Imagen de Sites no coincide con la ficha")
    else:
        raise ValueError("Host de imagen IA no autorizado")
    req = Request(url, headers={"User-Agent": "TTActualidad-BufferPublisher/1"})
    with urlopen(req, timeout=30) as response:
        final = urlparse(response.geturl())
        # Site serves approved originals through its canonical image host.
        # Espanyol r0 proved the old host redirects to the canonical host
        # while preserving the complete PNG and its exact editorial SHA.
        # The raw GitHub origin still may NOT redirect to another host.
        site_hosts = {
            "ttactualidad-tendencias.rainyraven22.chatgpt.site",
            "ttactualidad.rainyraven22.chatgpt.site",
        }
        allowed_final_hosts = (site_hosts if parsed.hostname in site_hosts
                               else {parsed.hostname})
        if (final.scheme != "https" or final.hostname not in allowed_final_hosts
            or final.port is not None or final.username or final.password
            or final.fragment or final.query):
            raise ValueError("Redirección IA fuera de los orígenes autorizados")
        # The redirect must preserve the exact event/revision/SHA filename,
        # not just land somewhere on the same Site. Espanyol r0 was verified
        # live against its canonical PNG path and all 64 SHA-256 digits.
        if parsed.hostname in site_hosts:
            exact_prefix = ("/images/" + project + "/" + event_id
                            + "-r" + str(revision) + "-")
            if (not final.path.startswith(exact_prefix)
                or not final.path.lower().endswith((".png", ".jpeg", ".jpg", ".webp"))
                or sha[:12] not in final.path.split("/")[-1].lower()):
                raise ValueError("Redirección IA no conserva la ficha")
        elif final.path != parsed.path:
            raise ValueError("Redirección IA de GitHub a otra ruta")
        data = response.read(12 * 1024 * 1024 + 1)
        if len(data) > 12 * 1024 * 1024:
            raise ValueError("Imagen IA supera 12 MB")
    if hashlib.sha256(data).hexdigest() != sha:
        raise ValueError("Imagen IA no coincide con el SHA-256 editorial")
    # Give Buffer the already-verified canonical URL instead of forcing it to
    # follow a cross-host redirect. Nothing is published during verification.
    return final.geturl()


# The app's public, read-only catalog contains originals after the user
# has explicitly approved them. This catalog can be newer than the GitHub
# site-ai-images.json mirror; fetch the SAME source the iPhone reads.
APPROVED_CATALOG = "https://ttactualidad.rainyraven22.chatgpt.site/api/image-inbox/catalog"
APPROVED_PROJECT_ID = "appgprj_6ae4dcf7d7488191a574e5b649e67370"


def approved_catalog_candidates(project, event_id, revision, editorial_text, editorial_at):
    """Return only already-approved images for this exact ID/revision/text/date.

    A missing/private/stale Site feed must not block publication: the verified
    GitHub catalog remains the next AI source, then archive then text.
    """
    if project not in PROJECT_ACCOUNT:
        return []
    url = APPROVED_CATALOG + "?project=" + project
    try:
        request = Request(url, headers={
            "User-Agent": "TTActualidad-BufferPublisher/approved-v1",
            "Accept": "application/json", "Cache-Control": "no-store"})
        with urlopen(request, timeout=12) as response:
            if response.geturl() != url or getattr(response, "status", 200) != 200:
                return []
            payload = response.read(2_000_001)
        if len(payload) > 2_000_000:
            return []
        doc = json.loads(payload)
        if (not isinstance(doc, dict) or doc.get("schema_version") != 1
            or doc.get("project") != project
            or doc.get("project_id") != APPROVED_PROJECT_ID
            or not isinstance(doc.get("images"), list)
            or len(doc["images"]) > 1000):
            return []
        matched = []
        for row in doc["images"]:
            if not isinstance(row, dict):
                continue
            approval_id = str(row.get("approval_id") or "")
            if not re.fullmatch(r"[a-f0-9]{64}", approval_id):
                continue
            if row.get("target_id") != event_id or row.get("revision") != revision:
                continue
            text_key = "editorial_text" if project == "ttittulares" else "explanation"
            time_key = "prepared_at" if project == "ttittulares" else "explained_at"
            if row.get(text_key) != editorial_text:
                continue
            if editorial_at and row.get(time_key) != editorial_at:
                continue
            matched.append({"image_url": row.get("image_url"),
                            "sha256": row.get("sha256")})
        return matched
    except (ValueError, TypeError, HTTPError, URLError, OSError, TimeoutError):
        return []


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
        matched = approved_catalog_candidates(
            project, event_id, revision, text, item.get("prepared_at")) + [
            x for x in catalog if x.get("target_id") == event_id
            and x.get("revision") == revision and x.get("editorial_text") == text]
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
        matched = approved_catalog_candidates(
            project, event_id, revision, text, item.get("explained_at")) + [
            x for x in catalog if x.get("target_id") == event_id
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
    # Several manually approved originals can share the same editorial
    # identity. One stale/broken catalog entry must not hide a later valid AI
    # image and silently force an archive fallback. Still verify every byte
    # against its SHA-256 and exact ID/revision; never use a pending image.
    tested = set()
    for image in matched:
        url = str(image.get("image_url") or "")
        sha = str(image.get("sha256") or "").lower()
        if (url, sha) in tested:
            continue
        tested.add((url, sha))
        try:
            checked = check_image(url, sha, project, event_id, revision)
            return text, checked, "ai"
        except (ValueError, HTTPError, URLError, OSError, TimeoutError) as exc:
            print("Imagen IA candidata no utilizable: " + str(exc)[:160])
    if matched and tested:
        # An explicitly approved, exact IA is not an optional embellishment.
        # Silently changing it into archive/text is what happened with
        # Espanyol on 2026-11-07. Stop before Buffer; allow a later
        # deliberate retry after the image service recovers.
        raise ValueError(
            "Hay imagen IA aprobada para esta ficha, pero no supera la "
            "verificación de origen y SHA-256. Sin publicar; reintentar.")
    archived = archive_url(item, project, event_id, revision)
    if archived:
        return text, archived, "archive"
    return text, None, "text"


def set_state(row, state, **extra):
    row["state"] = state
    row["checked_at"] = utc_now()
    row.update(extra)


def verified_x_link(url, account):
    """Only a permalink for the EXACT destination account can confirm a post."""
    try:
        parsed = urlparse(str(url or "").strip())
        if (parsed.scheme != "https"
            or (parsed.hostname or "").lower()
            not in {"x.com", "www.x.com", "twitter.com", "www.twitter.com"}
            or parsed.username or parsed.password or parsed.port):
            return False
        components = parsed.path.strip("/").split("/")
        return (len(components) == 3 and
                components[0].lower() == str(account).lower().lstrip("@") and
                components[1].lower() == "status" and
                bool(re.fullmatch(r"[0-9]{5,25}", components[2])))
    except (ValueError, TypeError):
        return False


def sent_post_verified(post, item):
    """Buffer has to confirm status, channel, send-time and exact X permalink."""
    return (
        isinstance(post, dict) and
        post.get("id") == item.get("buffer_post_id") and
        post.get("channelId") == item.get("channel_id") and
        str(post.get("status") or "").lower() == "sent" and
        bool(str(post.get("sentAt") or "").strip()) and
        verified_x_link(post.get("externalLink"), item.get("account"))
    )


def closure_receipt(request_id):
    """Read GitHub's COMMITTED application receipt, not a dispatch HTTP 204."""
    if not request_id:
        return None
    try:
        run("git", "fetch", "--quiet", "origin", "main")
        raw = run("git", "show",
                  "origin/main:pilot/ttactualidad-action-receipts.json").stdout
        receipt = next((
            item for item in json.loads(raw).get("items", [])
            if item.get("request_id") == request_id
        ), None)
        return receipt
    except (subprocess.CalledProcessError, ValueError, KeyError):
        return None


def pending_check_due(item, now=None):
    """Budget-safe verification; never re-posts a pending X publication.

    The GitHub cron runs every 15 minutes. A pending item older than a few
    hours would otherwise consume up to 96 Buffer API requests every day
    forever, without additional publications. Back off stale checks but keep
    the original reservation and continue occasional readback.
    """
    if item.get("state") != "pending" or not item.get("buffer_post_id"):
        return False
    now = now or datetime.now(timezone.utc)
    def date(value):
        if not value:
            return None
        try:
            d = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            return d if d.tzinfo is not None else None
        except (ValueError, TypeError):
            return None
    since = date(item.get("requested_at"))
    if since is None:
        return True
    age = max(0, (now - since).total_seconds())
    interval = 15 * 60 if age < 60 * 60 else (
        60 * 60 if age < 6 * 60 * 60 else 12 * 60 * 60)
    last = date(item.get("last_buffer_check_at"))
    return last is None or (now - last).total_seconds() >= interval


def reconcile(data, key):
    changed = False
    for item in data["items"]:
        if not pending_check_due(item):
            continue
        post_id = item["buffer_post_id"]
        # Record the check even if Buffer times out; the next scheduled job
        # must respect the same backoff instead of hammering the quota.
        item["last_buffer_check_at"] = utc_now()
        item["buffer_poll_attempts"] = int(item.get("buffer_poll_attempts") or 0) + 1
        changed = True
        try:
            result = graphql(key, "query($input: PostInput!) { post(input: $input) {"
                             " id status sentAt externalLink channelId } }",
                             {"input": {"id": post_id}})
            post = result.get("post") or {}
            if post.get("id") != post_id or post.get("channelId") != item.get("channel_id"):
                continue
            status = str(post.get("status") or "").lower()
            if sent_post_verified(post, item):
                set_state(item, "sent", sent_at=post["sentAt"],
                          post_url=post["externalLink"])
                item.pop("verification_note", None)
                changed = True
            elif status == "sent":
                reason = "Buffer indicó enviado, sin enlace verificable a X de esta cuenta."
                if item.get("verification_note") != reason:
                    item["verification_note"] = reason
                    changed = True
            elif status in ("error", "failed"):
                set_state(item, "failed", error="Buffer marcó error de publicación")
                changed = True
        except (ValueError, RuntimeError, HTTPError, URLError) as exc:
            print("Comprobación Buffer pendiente para " + post_id + ": " + str(exc))
    attach_latest_quota(data)
    if changed or LAST_API_QUOTA is not None:
        save(data, "confirmar posts de X mediante enlace verificable")

    # Only a Buffer-verified X status + exact permalink authorizes the
    # existing editorial close workflow. The close itself also needs a
    # COMMITTED receipt before we claim Listas has been updated.
    for item in data["items"]:
        if item.get("state") != "sent" or item.get("closure_verified"):
            continue
        request_id = item.get("closure_request_id")
        if request_id:
            receipt = closure_receipt(request_id)
            if receipt and (
                receipt.get("project") != item.get("project")
                or receipt.get("event_id") != item.get("event_id")
                or receipt.get("revision") != item.get("revision")
                or receipt.get("decision") != "published"
            ):
                item["closure_error"] = "El recibo de cierre no coincide con esta ficha."
                save(data, "detectar recibo de cierre no coincidente")
                continue
            status = str((receipt or {}).get("status") or "").lower()
            if status in {"applied", "already_applied"}:
                item["closure_verified"] = True
                item["closure_error"] = ""
                save(data, "confirmar retirada de Listas con recibo real")
                continue
            if status in {"rejected", "failed"}:
                item["closure_error"] = "Cierre editorial rechazado; revisar en Listas."
                save(data, "registrar cierre editorial rechazado")
                continue
            if item.get("closure_dispatched"):
                continue
            # The request ID was persisted before a possible network timeout.
            # Never replay a potentially successful dispatch blindly.
            continue
        token = os.getenv("GH_TOKEN", "").strip()
        if not token:
            continue
        request_id = str(uuid.uuid4())
        item["closure_request_id"] = request_id
        item["closure_dispatched"] = False
        save(data, "reservar cierre de Listas sin duplicados")
        payload = {"event_type": "ttactualidad_action_v1", "client_payload": {
            "project": item["project"], "event_id": item["event_id"],
            "revision": item["revision"], "decision": "published",
            "request_id": request_id,
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
                    raise RuntimeError("GitHub no aceptó el cierre editorial")
            item["closure_dispatched"] = True
            save(data, "pedir cierre editorial sin darlo por aplicado")
        except (HTTPError, URLError, RuntimeError) as exc:
            # Ambiguous external result; keep the same ID on record and do
            # not send another request automatically.
            item["closure_error"] = "Resultado de cierre sin confirmar: " + str(exc)[:100]
            save(data, "guardar fallo o incertidumbre del cierre")

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
            "assets": x_post_assets(image_url),
            "needsApproval": False, "source": "TTActualidad"
        }})
        outcome = result.get("createPost") or {}
        post = outcome.get("post")
        if not post:
            set_state(row, "failed", error=str(outcome.get("message") or
                                               "Buffer rechazó la publicación")[:230])
        elif post.get("id") and post.get("channelId") == channel:
            # Mutation acknowledgement alone is NOT proof X has published.
            # A separate Buffer post readback must verify sentAt + X permalink.
            set_state(row, "pending", buffer_post_id=post["id"])
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
                   (x.get("state") == "sent" and not x.get("closure_verified"))
                   for x in data["items"]):
        reconcile(data, key)


if __name__ == "__main__":
    main()
