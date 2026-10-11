#!/usr/bin/env python3
"""Repair missing original headlines from the captured radar, without editorial invention.

Idempotent, run after radar capture and before Telegram delivery. A missing
headline stays in PROCESSING; the read-only distributor blocks sending it.
"""
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GENERIC = {"", "noticia", "sin título", "sin titulo", "actualidad", "titular pendiente"}

def read(path, default):
    try:
        return json.loads((ROOT / path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default

def write(path, document):
    (ROOT / path).write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def genuine(value):
    title = str(value or "").strip()
    return title if title.casefold().strip(" .:–-") not in GENERIC else ""

def article_metadata(row):
    title = genuine(row.get("canonical_title") or row.get("title"))
    url = str(row.get("url") or "")
    appearances = [a for a in row.get("appearances") or [] if isinstance(a, dict)]
    source = next((str(a.get("source")) for a in appearances
                   if str(a.get("url") or "") == url and a.get("source")), "")
    if not source:
        source = next((str(a.get("source")) for a in appearances if a.get("source")), "")
    if not url.startswith("https://"):
        url = next((str(a.get("url")) for a in appearances
                    if str(a.get("url") or "").startswith("https://")), "")
    return title, url, source

def repair(doc, events):
    changed, missing = [], []
    for item in doc.get("items") or []:
        if str(item.get("status") or "").upper() not in {"PROCESSING", "READY"}:
            continue
        eid = str(item.get("event_id") or "")
        if not eid or genuine(item.get("title")):
            continue
        original = events.get(eid)
        title, url, source = article_metadata(original) if original else ("", "", "")
        if not title:
            missing.append(eid)
            continue
        item["title"] = title
        if url and not str(item.get("url") or "").startswith("https://"):
            item["url"] = url
        if source and not item.get("source"):
            item["source"] = source
        item["headline_recovered_from"] = "telegram/events.json"
        changed.append(eid)
    return changed, missing

def run():
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    radar = read("telegram/events.json", {"events": []})
    events = {str(x.get("id") or ""): x for x in radar.get("events") or []}
    total_changed, unresolved = [], set()
    for path in ("telegram/editorial-processing.json", "ttittulares/editorial-queue.json"):
        doc = read(path, {"items": []})
        changed, missing = repair(doc, events)
        if changed:
            doc["updated_at"] = now
            write(path, doc)
            total_changed.extend(changed)
        unresolved.update(missing)
    if unresolved:
        path = "ttittulares/execution-errors.json"
        errors = read(path, {"items": []})
        rows = errors.setdefault("items", [])
        known = {(r.get("event_id"), r.get("phase"), r.get("reason")) for r in rows}
        for eid in sorted(unresolved):
            signature = (eid, "telegram_provisional", "original_headline_missing")
            if signature not in known:
                rows.append({"at": now, "event_id": eid, "phase": signature[1],
                             "reason": signature[2],
                             "remediation_prompt": "Recuperar título RSS/captura antes de enviar Telegram; no generar titular."})
        write(path, errors)
    print("TTI_AUTHENTIC_HEADLINE_RECOVERY", sorted(set(total_changed)),
          "UNRESOLVED_BLOCKED", sorted(unresolved))
    return total_changed, sorted(unresolved)

def selftest():
    doc = {"items": [{"event_id":"abc","status":"PROCESSING","title":"Noticia"},
                     {"event_id":"deleted","status":"DELETED","title":"Noticia"},
                     {"event_id":"other","status":"PROCESSING","title":"Sin título"}]}
    events = {"abc":{"id":"abc","canonical_title":"Titular RSS auténtico",
                     "url":"https://example.org/story","appearances":[{"source":"Medio","url":"https://example.org/story"}]}}
    changed, missing = repair(doc, events)
    assert changed == ["abc"] and missing == ["other"]
    assert doc["items"][0]["title"] == "Titular RSS auténtico"
    assert doc["items"][0]["source"] == "Medio"
    assert doc["items"][0]["url"] == "https://example.org/story"
    assert doc["items"][1]["title"] == "Noticia"
    assert repair(doc, events) == ([], ["other"])
    print("TTI_HEADLINE_RECOVERY_SELFTEST_OK")

if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        selftest()
    else:
        run()
