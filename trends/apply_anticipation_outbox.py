#!/usr/bin/env python3
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from anticipation import apply_result, metrics as anticipation_metrics
from requests_json import dumps_for_path

ROOT = Path(__file__).resolve().parent
OUTBOX = ROOT / "anticipation-outbox"
MADRID = ZoneInfo("Europe/Madrid")

def load(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default

def save(path: Path, value):
    path.write_text(dumps_for_path(path, value), encoding="utf-8")

def main():
    requests_path = ROOT / "requests.json"
    metrics_path = ROOT / "anticipation-metrics.json"
    requests_doc = load(requests_path, {"requests": []})
    files = sorted(OUTBOX.glob("*.json")) if OUTBOX.exists() else []
    now = datetime.now(MADRID)
    changed = False
    applied_ids = []
    errors = []

    for path in files:
        payload = load(path, None)
        if not isinstance(payload, dict):
            errors.append(f"{path.name}: JSON inválido")
            continue
        try:
            candidate, applied = apply_result(requests_doc, payload, now)
        except Exception as exc:
            errors.append(f"{path.name}: {exc}")
            continue
        requests_doc = candidate
        if applied:
            changed = True
            applied_ids.append(str(payload.get("job_id") or path.stem))

    if changed:
        save(requests_path, requests_doc)

    jobs = [row for row in requests_doc.get("requests", []) if row.get("anticipation_request")]
    save(metrics_path, anticipation_metrics(jobs))

    print("TTENDENCIAS_ANTICIPATION_APPLY applied=" + ",".join(applied_ids) +
          " errors=" + str(len(errors)))
    for error in errors:
        print("ERROR", error)
    return 1 if errors else 0

if __name__ == "__main__":
    raise SystemExit(main())
