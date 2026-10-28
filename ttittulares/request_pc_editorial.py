#!/usr/bin/env python3
"""Request the existing dedicated Windows/ChatGPT TTiTTulares editorial run.

Called ONLY after an authoritative mobile queue update is committed to main.
This writes the SAME GitHub control-branch trigger used by the installed iPhone
and Windows listener. It cannot itself run ChatGPT or claim editorial success.
"""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = "fabricelop/europapress-rss"
PR = 2
FILE = "ttittulares/run-now-trigger.json"
ROOT = Path(__file__).resolve().parent.parent
ACTIVE = {"PROCESSING", "UPDATE_PROCESSING"}


def read_json(path: Path, default: dict) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else default
    except (OSError, ValueError):
        return default


def pending_ids(root: Path = ROOT) -> list[str]:
    """Use authoritative revisioned work only, never a stale dashboard count."""
    queue = read_json(root / "ttittulares/editorial-queue.json", {"items": []})
    ready = read_json(root / "ttittulares/prepared.json", {"items": []})
    results = set()
    for row in queue.get("items", []):
        if not isinstance(row, dict) or str(row.get("status", "")).upper() not in ACTIVE:
            continue
        ident = str(row.get("event_id") or "")
        if ident:
            results.add(f"{ident}:r{row.get('revision', 0)}")
    for row in ready.get("items", []):
        if not isinstance(row, dict) or not row.get("rewrite_pending"):
            continue
        ident = str(row.get("event_id") or "")
        if ident:
            results.add(f"{ident}:r{row.get('rewrite_target_revision', row.get('revision', 0))}")
    return sorted(results)


def parse_timestamp(raw: object):
    if not isinstance(raw, str) or not raw:
        return None
    try:
        value = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        return value.astimezone(timezone.utc) if value.tzinfo else None
    except ValueError:
        return None


def already_requested(previous: dict, ids: list[str], at: datetime) -> bool:
    when = parse_timestamp(previous.get("requested_at"))
    return bool(
        ids and when and 0 <= (at - when).total_seconds() < 90
        and previous.get("executor") == "pc_chat_ttittulares_dedicated"
        and set(ids).issubset(set(previous.get("pending_ids") or []))
    )


def api(url: str, token: str, doc=None, method="GET"):
    payload = json.dumps(doc, ensure_ascii=False).encode("utf-8") if doc is not None else None
    req = urllib.request.Request(
        url, data=payload, method=method,
        headers={"Authorization": "Bearer " + token,
                 "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json",
                 "User-Agent": "TTActualidad-Urgent-Editorial-Trigger"},
    )
    with urllib.request.urlopen(req, timeout=25) as response:
        return json.load(response)


def active_pr_branch(token: str) -> str:
    pr = api(f"https://api.github.com/repos/{REPO}/pulls/{PR}", token)
    head = pr.get("head") or {}
    name = head.get("ref") or ""
    if (pr.get("state") != "open"
            or not name.startswith("control/ttittulares-run-trigger")
            or (head.get("repo") or {}).get("full_name") != REPO):
        raise RuntimeError("Permanent TTiTTulares PR #2 head is not trusted/open")
    return name


def trigger(token: str, root: Path = ROOT) -> str | None:
    ids = pending_ids(root)
    if not ids:
        print("TT_NEWS_URGENT_NO_PENDING: no PROCESSING or rewrite_pending; no trigger")
        return None
    if not token:
        raise RuntimeError("GH_TOKEN missing: cannot request immediate editorial run")
    branch = active_pr_branch(token)
    api_url = f"https://api.github.com/repos/{REPO}/contents/{FILE}"
    for attempt in range(6):
        existing = api(api_url + "?ref=" + urllib.parse.quote(branch, safe=""), token)
        previous = json.loads(base64.b64decode(existing["content"]))
        at = datetime.now(timezone.utc)
        ids = pending_ids(root)
        if not ids:
            print("TT_NEWS_URGENT_NO_PENDING: work disappeared while preparing trigger")
            return None
        if already_requested(previous, ids, at):
            print("TT_NEWS_URGENT_REUSED", previous.get("command_id"), len(ids))
            return previous.get("command_id")
        command_id = "tt-urgent-" + str(int(at.timestamp() * 1000))
        doc = {
            "version": 2, "command_id": command_id,
            "requested_at": at.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "mode": "manual_pc_chat", "executor": "pc_chat_ttittulares_dedicated",
            "project": "ttittulares", "launcher_arg": "titulares",
            "task": "editorial", "auto_image_followup": False,
            "source": "ttactualidad_mobile_immediate",
            "pending_ids": ids,
        }
        content = json.dumps(doc, ensure_ascii=False, indent=2) + "\n"
        payload = {
            "branch": branch, "sha": existing["sha"],
            "message": "TTActualidad: elaborar noticias urgentes " + command_id,
            "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
        }
        try:
            api(api_url, token, payload, method="PUT")
            print("TT_NEWS_URGENT_TRIGGERED", command_id, "items=" + str(len(ids)))
            return command_id
        except urllib.error.HTTPError as error:
            if error.code not in (409, 422) or attempt == 5:
                raise
            time.sleep(0.5 * (attempt + 1))
    raise RuntimeError("Unable to persist immediate editorial trigger")


def selftest():
    from tempfile import TemporaryDirectory
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "ttittulares").mkdir()
        queue_path = root / "ttittulares" / "editorial-queue.json"
        ready_path = root / "ttittulares" / "prepared.json"
        queue_path.write_text(json.dumps({"items": [
            {"event_id": "urgent-a", "revision": 1, "status": "PROCESSING"},
            {"event_id": "urgent-b", "revision": 2, "status": "UPDATE_PROCESSING"},
            {"event_id": "waiting", "revision": 1, "status": "WAITING"},
        ]}), encoding="utf8")
        ready_path.write_text(json.dumps({"items": [
            {"event_id": "rewrite-c", "revision": 1,
             "rewrite_target_revision": 2, "rewrite_pending": True},
            {"event_id": "ready-d", "revision": 1, "status": "READY"},
        ]}), encoding="utf8")
        ids = pending_ids(root)
        assert ids == ["rewrite-c:r2", "urgent-a:r1", "urgent-b:r2"], ids
        now = datetime.now(timezone.utc)
        current = {"requested_at": now.isoformat(),
                   "executor": "pc_chat_ttittulares_dedicated",
                   "pending_ids": ids}
        assert already_requested(current, ids, now)
        assert not already_requested(current, ids + ["urgent-new:r1"], now)
        assert not already_requested({**current, "pending_ids": []}, ids, now)
        assert not already_requested({**current, "requested_at":
                       "2026-10-01T00:00:00Z"}, ids, now)
        assert not already_requested({**current, "executor": "other"}, ids, now)
        queue_path.write_text('{"items":[]}', encoding="utf8")
        ready_path.write_text('{"items":[]}', encoding="utf8")
        assert not pending_ids(root)
        assert trigger("", root) is None
    print("TT_NEWS_URGENT_SELFTEST_OK")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    elif "--trigger" in sys.argv:
        trigger(os.environ.get("GH_TOKEN", ""))
    else:
        raise SystemExit("Use --selftest or --trigger")
