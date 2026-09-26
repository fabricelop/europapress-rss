#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTBOX = ROOT / "ttittulares" / "editorial-outbox"
PREFIX = "TTITTULARES_OUTBOX_V1"
EVENT_RE = re.compile(r"^[A-Za-z0-9._-]{3,120}$")


def fail(msg: str) -> int:
    print(f"ERROR: {msg}", file=sys.stderr)
    return 2


def main() -> int:
    event_path = os.environ.get("GITHUB_EVENT_PATH", "").strip()
    if not event_path:
        return fail("GITHUB_EVENT_PATH ausente")
    event = json.loads(Path(event_path).read_text(encoding="utf-8"))

    issue = event.get("issue") or {}
    comment = event.get("comment") or {}
    repo = event.get("repository") or {}

    if int(issue.get("number") or 0) != 2 or not issue.get("pull_request"):
        print("IGNORED: no es PR #2")
        return 0
    if str(repo.get("full_name") or "") != "fabricelop/europapress-rss":
        return fail("repositorio inesperado")

    author = str((comment.get("user") or {}).get("login") or "")
    assoc = str(comment.get("author_association") or "")
    if author != "fabricelop" and assoc not in {"OWNER"}:
        print(f"IGNORED: autor no autorizado: {author}/{assoc}")
        return 0

    body = str(comment.get("body") or "").strip()
    if not body.startswith(PREFIX):
        print("IGNORED: comentario no transporta outbox")
        return 0

    encoded = body[len(PREFIX):].strip()
    if encoded.startswith("\n"):
        encoded = encoded[1:].strip()
    encoded = "".join(encoded.split())
    if not encoded:
        return fail("payload vacío")

    try:
        raw = base64.b64decode(encoded, validate=True)
        payload = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        return fail(f"payload inválido: {type(exc).__name__}: {exc}")

    if not isinstance(payload, dict):
        return fail("payload no es objeto JSON")
    event_id = str(payload.get("event_id") or "")
    if not EVENT_RE.fullmatch(event_id):
        return fail("event_id inválido")
    try:
        revision = int(payload.get("revision") or 1)
    except Exception:
        return fail("revision inválida")
    if revision < 1 or revision > 9999:
        return fail("revision fuera de rango")
    status = str(payload.get("status") or "")
    if status not in {"ready", "problematic"}:
        return fail("status inválido")

    # Evita transportar un outbox ready que no corresponda al item.
    if status == "ready":
        item = payload.get("prepared_item")
        if not isinstance(item, dict):
            return fail("prepared_item ausente")
        if str(item.get("event_id") or "") != event_id:
            return fail("prepared_item.event_id no coincide")
        if int(item.get("revision") or revision) != revision:
            return fail("prepared_item.revision no coincide")

    OUTBOX.mkdir(parents=True, exist_ok=True)
    path = OUTBOX / f"{event_id}-r{revision}.json"
    data = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"

    if path.exists() and path.read_text(encoding="utf-8") == data:
        print(f"IDEMPOTENT: {path.relative_to(ROOT)} ya coincide")
        return 0

    path.write_text(data, encoding="utf-8")
    print(f"INGESTED: {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
