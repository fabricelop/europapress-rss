#!/usr/bin/env python3
"""Add one user-supplied TTActualidad news item to the existing GitHub editorial queues.
No Telegram, TTImages, Web radar or readiness state is modified.
"""
from __future__ import annotations
import json
import os
import re
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parents[1]
PROCESSING = "telegram/editorial-processing.json"
COMPACT = "ttittulares/editorial-queue.json"
PREPARED = "ttittulares/prepared.json"
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.I)


def clean_text(value, max_length):
    if not isinstance(value, str):
        raise ValueError("Texto no válido")
    return re.sub(r"\s+", " ", value).strip()[:max_length]


def normalize(value):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", value).casefold()).strip()


def clean_url(value):
    url = clean_text(value, 2100)
    if not url:
        return ""
    if len(url) > 2000:
        raise ValueError("Enlace demasiado largo")
    parsed = urlsplit(url)
    if parsed.scheme.lower() != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Solo enlaces HTTPS válidos")
    return urlunsplit((parsed.scheme.lower(), parsed.netloc.lower(), parsed.path, parsed.query, ""))


def validate(payload):
    if not isinstance(payload, dict) or payload.get("project") != "ttittulares":
        raise ValueError("Proyecto no válido")
    request_id = str(payload.get("request_id") or "")
    if not UUID.fullmatch(request_id):
        raise ValueError("Identificador de solicitud inválido")
    title = clean_text(payload.get("title", ""), 240)
    url = clean_url(payload.get("url", ""))
    instructions = clean_text(payload.get("instructions", ""), 1000)
    if not title and not url:
        raise ValueError("Se requiere un titular o un enlace")
    if title and len(title) < 5:
        raise ValueError("Titular demasiado corto")
    if not title:
        title = "Investigar noticia del enlace: " + urlsplit(url).hostname
    return {"event_id": "manual-" + request_id.lower(), "title": title,
            "url": url, "instructions": instructions}


def read(path):
    value = json.loads((ROOT / path).read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("items"), list):
        raise ValueError("Estado editorial no válido: " + path)
    return value


def apply(payload, at=None):
    news = validate(payload)
    processing, compact, prepared = read(PROCESSING), read(COMPACT), read(PREPARED)
    rows = processing["items"]
    eid, title, url = news["event_id"], news["title"], news["url"]
    # Idempotent on retries; do not resurrect or overwrite completed revisions.
    if any(str(x.get("event_id") or "") == eid for data in (processing, compact, prepared)
           for x in data["items"]):
        return "already_received", eid
    for x in [*rows, *compact["items"], *prepared["items"]]:
        if str(x.get("status") or "").upper() not in ("PROCESSING", "UPDATE_PROCESSING", "READY", ""):
            continue
        old_url = str(x.get("url") or "").strip()
        old_title = str(x.get("title") or "").strip()
        if (url and old_url and clean_url(old_url) == url) or (
                not url and not old_url and title and old_title and normalize(title) == normalize(old_title)):
            return "already_exists", str(x.get("event_id") or "")
    now = at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    row = {
        "event_id": eid, "title": title, "url": url, "status": "PROCESSING",
        "revision": 1, "selected_at": now, "requested_at": now,
        "selection_mode": "TTACTUALIDAD_MANUAL", "manual_submission": True,
        "manual_investigation_requested": True, "force_user_elaborate": True,
        "allow_zero_initial_sources": True, "source_count": 0,
        "verified_source_count": 0, "sources": [],
        "user_instructions": news["instructions"],
        "rewrite_request": news["instructions"],
        "with_image": True, "image_mode": "ai_plus_fallback",
        "image_instruction": "TT_STYLE_A_V1: imagen editorial adecuada al hecho confirmado; imagen opcional, nunca bloquea READY.",
    }
    # The full processing record and the compact view MUST share event_id/revision.
    rows.append(row)
    compact["items"].append({k: row[k] for k in (
        "event_id", "title", "url", "sources", "source_count", "selected_at",
        "selection_mode", "status", "revision", "rewrite_request", "with_image",
        "image_mode", "image_instruction")})
    compact["items"][-1]["manual_investigation_requested"] = True
    compact["items"][-1]["allow_zero_initial_sources"] = True
    processing["updated_at"] = compact["updated_at"] = now
    compact["count"] = sum(x.get("status") in ("PROCESSING", "UPDATE_PROCESSING")
                           for x in compact["items"])
    for path, value in ((PROCESSING, processing), (COMPACT, compact)):
        (ROOT / path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n",
                                encoding="utf-8")
    return "added", eid


def main():
    payload = json.loads(os.environ["TT_ACTUALIDAD_MANUAL_JSON"])
    outcome, eid = apply(payload)
    print("TTACTUALIDAD_MANUAL", outcome, eid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
