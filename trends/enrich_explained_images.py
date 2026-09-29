#!/usr/bin/env python3
"""Nonblocking real-photo enrichment of TTendencias explanations.

No AI images or tweet rewriting. Never waits for a photo before explanation
publication. A selected Tremending tweet capture always takes precedence.
Safe to rerun: ready/none are terminal for the explained revision.
"""
from __future__ import annotations

import argparse
import ipaddress
import io
import json
import re
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler

ROOT = Path(__file__).resolve().parents[1]
EXPLAINED = ROOT / "trends" / "telegram-manual-explained.json"
TREMENDING = ROOT / "ttittulares" / "tremending" / "items.json"
MAX_ITEMS_PER_PASS = 12
USER_AGENT = "TTendencias-RealPhoto/1.0 (+https://github.com/fabricelop/europapress-rss)"


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def save(path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def safe_https(url):
    try:
        parsed = urlsplit(str(url or "").strip())
        host = str(parsed.hostname or "").lower().rstrip(".")
        if parsed.scheme != "https" or not host or parsed.username or parsed.password:
            return False
        if parsed.port not in (None, 443) or host == "localhost" or host.endswith((".localhost", ".local", ".internal")):
            return False
        try:
            return ipaddress.ip_address(host).is_global
        except ValueError:
            return "." in host and len(host) <= 253
    except ValueError:
        return False


class SafeRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not safe_https(newurl):
            raise ValueError("redirect a dirección no pública o no HTTPS")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = build_opener(SafeRedirects())


class MetaImages(HTMLParser):
    def __init__(self):
        super().__init__()
        self.images = []

    def handle_starttag(self, tag, attrs):
        if tag.casefold() != "meta":
            return
        attr = dict(attrs)
        key = str(attr.get("property") or attr.get("name") or "").lower()
        if key in {"og:image", "og:image:secure_url", "twitter:image", "twitter:image:src"}:
            value = str(attr.get("content") or "").strip()
            if value and value not in self.images:
                self.images.append(value)


def get(url, accept, limit, timeout):
    if not safe_https(url):
        raise ValueError("URL no HTTPS/pública")
    req = Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    with OPENER.open(req, timeout=timeout) as response:
        final = response.geturl()
        if not safe_https(final):
            raise ValueError("destino no HTTPS/público")
        mime = str(response.headers.get("content-type") or "").split(";", 1)[0].strip().lower()
        size = response.headers.get("content-length")
        if size and int(size) > limit:
            raise ValueError("respuesta supera el límite de bytes")
        body = response.read(limit + 1)
        if len(body) > limit:
            raise ValueError("respuesta supera el límite de bytes")
        return final, mime, body


def raster_ok(url):
    from PIL import Image, UnidentifiedImageError
    try:
        _, mime, body = get(url, "image/png,image/jpeg,image/webp", 8_000_000, 7)
        if mime not in {"image/png", "image/jpeg", "image/webp"}:
            return False
        with Image.open(io.BytesIO(body)) as probe:
            if probe.format not in {"PNG", "JPEG", "WEBP"}:
                return False
            probe.verify()
        with Image.open(io.BytesIO(body)) as im:
            im.load()
            w, h = im.size
            return w >= 480 and h >= 260 and (max(w, h) / max(1, min(w, h))) <= 5
    except (ValueError, OSError, UnidentifiedImageError, TimeoutError, TypeError):
        return False
    except Exception:
        # A broken external image must never fail the editorial run.
        return False


def page_photo(page_url):
    try:
        final, mime, body = get(page_url, "text/html,application/xhtml+xml", 1_200_000, 6)
        if mime not in {"text/html", "application/xhtml+xml"}:
            return None
        parser = MetaImages()
        parser.feed(body.decode("utf-8", "replace"))
        for raw in parser.images[:6]:
            candidate = urljoin(final, raw)
            if safe_https(candidate) and raster_ok(candidate):
                return candidate
    except Exception:
        pass
    return None


def primary_rank(source, url):
    name = str(source or "").casefold()
    host = urlsplit(url).hostname or ""
    return 0 if (any(x in name for x in ("oficial", "ministerio", "gobierno", "institución", "federación")) or
                 host.endswith((".gob.es", ".gov", ".europa.eu"))) else 1


def verified_source_pages(row):
    rows = []
    for source in row.get("verification_sources") or []:
        if not isinstance(source, dict):
            continue
        url = str(source.get("url") or "").strip()
        if safe_https(url):
            rows.append((url, str(source.get("source") or urlsplit(url).hostname or "Fuente")))
    fallback = str(row.get("source_url") or "").strip()
    if safe_https(fallback):
        rows.append((fallback, "Fuente de la tendencia"))
    unique, found = [], set()
    for url, source in sorted(rows, key=lambda r: primary_rank(r[1], r[0])):
        if url in found:
            continue
        found.add(url)
        unique.append((url, source))
    return unique[:3]


def tremending_photo(row, entry, exists=lambda p: p.is_file()):
    capture = (entry or {}).get("image") or {}
    tweet = row.get("selected_tweet") or {}
    tweet_id = str(tweet.get("id") or "")
    static = str(capture.get("static_path") or "")
    url = str(capture.get("url") or "")
    if (capture.get("status") != "ready" or not tweet_id or
        str(capture.get("tweet_id") or "") != tweet_id or
        not re.fullmatch(r"ttittulares/tremending-images/[0-9]+\.png", static) or
        not url.endswith("/" + tweet_id + ".png") or
        not url.startswith("https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/tremending-images/") or
        not exists(ROOT / static)):
        return None
    return {
        "url": url,
        "source": "Público · Tremending / tuit elegido",
        "source_url": str(tweet.get("url") or capture.get("tweet_url") or ""),
        "alt": "Captura del tuit seleccionado para " + str(row.get("name") or "Tremending"),
        "kind": "tremending_tweet_capture",
        "tweet_id": tweet_id,
        "rights_status": "third_party_unverified",
        "generated": False,
    }


def enrich(row, by_tremending, photo_finder=page_photo, exists=lambda p: p.is_file()):
    if str(row.get("status") or "") != "explained" or not str(row.get("explanation") or "").strip():
        return False
    if str(row.get("image_status") or "") in {"ready", "none"}:
        return False
    before = json.dumps(row, ensure_ascii=False, sort_keys=True)
    if row.get("tremending_origin"):
        entry = by_tremending.get(str(row.get("tremending_id") or ""))
        image = tremending_photo(row, entry, exists)
        row["image_strategy"] = "tremending_tweet_capture"
        if image:
            row["image"] = image
            row["image_status"] = "ready"
            row["image_pending"] = False
            row.pop("image_failure_reason", None)
        else:
            row["image_status"] = "pending_capture"
            row["image_pending"] = True
    else:
        row["image_strategy"] = "existing_web_image"
        row.pop("image", None)
        for page, source in verified_source_pages(row):
            image_url = photo_finder(page)
            if not image_url or not safe_https(image_url):
                continue
            row["image"] = {
                "url": image_url,
                "source": source,
                "source_url": page,
                "alt": "Imagen relacionada con " + str(row.get("name") or "la tendencia"),
                "rights_status": "unverified",
                "generated": False,
            }
            row["image_status"] = "ready"
            row["image_pending"] = False
            row.pop("image_failure_reason", None)
            break
        else:
            row["image_status"] = "none"
            row["image_pending"] = False
            row["image_failure_reason"] = "No se encontró una fotografía raster HTTPS verificable en las fuentes de esta explicación."
    return json.dumps(row, ensure_ascii=False, sort_keys=True) != before


def selftest():
    sample = {
        "id": "tremending-example", "name": "Nogueras e Intxaurrondo",
        "status": "explained", "explanation": "Nogueras e Intxaurrondo es tendencia por una entrevista.",
        "tremending_origin": True, "tremending_id": "entry",
        "selected_tweet": {"id": "123", "url": "https://x.com/example/status/123"},
    }
    assert enrich(sample, {}) and sample["image_status"] == "pending_capture"
    by_id = {"entry": {"image": {
        "status": "ready", "tweet_id": "123",
        "url": "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/tremending-images/123.png",
        "static_path": "ttittulares/tremending-images/123.png"}}}
    assert enrich(sample, by_id, exists=lambda _: True)
    assert sample["image_status"] == "ready" and sample["image"]["tweet_id"] == "123"
    assert not enrich(sample, by_id, exists=lambda _: True)
    normal = {"id": "normal", "name": "Tema", "status": "explained",
              "explanation": "TT#1 Tema es tendencia por un acontecimiento.", "verification_sources": []}
    assert enrich(normal, {}) and normal["image_status"] == "none"
    assert not enrich(normal, {})
    assert not safe_https("http://example.com") and not safe_https("https://127.0.0.1/photo.jpg")
    print("TTENDENCIAS_REAL_PHOTO_SELFTEST_OK")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    doc = read(EXPLAINED)
    state = read(TREMENDING)
    by_id = {str(x.get("id") or ""): x for x in state.get("items") or []}
    cutoff = datetime.now(timezone.utc) - timedelta(hours=48)
    changed, attempted, ready, absent, capture_pending = 0, 0, 0, 0, 0
    for row in reversed((doc.get("items") or [])[-90:]):
        if attempted >= MAX_ITEMS_PER_PASS:
            break
        if row.get("image_status") in {"ready", "none"}:
            continue
        try:
            at = datetime.fromisoformat(str(row.get("explained_at") or "").replace("Z", "+00:00"))
            if at.tzinfo is None:
                at = at.replace(tzinfo=timezone.utc)
            if at.astimezone(timezone.utc) < cutoff:
                continue
        except ValueError:
            continue
        if str(row.get("status") or "") != "explained":
            continue
        attempted += 1
        if enrich(row, by_id):
            changed += 1
        state_name = row.get("image_status")
        ready += state_name == "ready"
        absent += state_name == "none"
        capture_pending += state_name == "pending_capture"
    if changed:
        doc["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        save(EXPLAINED, doc)
    print(json.dumps({"enriched": changed, "examined": attempted, "ready": ready,
                      "none": absent, "pending_capture": capture_pending}, ensure_ascii=False))


if __name__ == "__main__":
    main()
