#!/usr/bin/env python3
"""One alert per project ONLY when verified Listas pass from zero to positive.

Do not infer zero from partial GitHub reads. First run only establishes baseline.
Delivery is explicitly disabled until GitHub secret TT_ACTUALIDAD_NTFY_TOPIC exists.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import tempfile
from urllib import request

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "pilot" / "ttactualidad-listas-alert-state.json"
TERMINAL = {"deleted", "dismissed", "published", "removed", "delete_pending"}
ACTIVE_QUEUE = {"preparing", "update"}


def load(path: str) -> dict:
    obj = json.loads((ROOT / path).read_text(encoding="utf-8"))
    if not isinstance(obj, dict):
        raise ValueError(f"Invalid JSON object: {path}")
    return obj


def rows(doc: dict, field: str = "items") -> list:
    items = doc.get(field)
    if not isinstance(items, list) or not all(isinstance(x, dict) for x in items):
        raise ValueError(f"Missing/malformed {field}")
    return items


def dt(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone(timezone.utc)
    except (ValueError, TypeError):
        return None


def val(row, key):
    return str(row.get(key) or "")


def rev(row):
    try:
        return int(row.get("revision") or 0)
    except (TypeError, ValueError):
        return 0


def latest(items, key):
    output = {}
    for x in items:
        ident = val(x, key)
        if not ident:
            continue
        prior = output.get(ident)
        if prior is None or rev(x) > rev(prior):
            output[ident] = x
        elif rev(x) == rev(prior):
            keys = ("updated_at", "deleted_at", "explained_at", "requested_at")
            a = next((dt(x.get(k)) for k in keys if dt(x.get(k))), datetime.min.replace(tzinfo=timezone.utc))
            b = next((dt(prior.get(k)) for k in keys if dt(prior.get(k))), datetime.min.replace(tzinfo=timezone.utc))
            if a >= b:
                output[ident] = x
    return output


def terminal_after(row, when, revision):
    if val(row, "status").lower() not in TERMINAL:
        return False
    r = rev(row)
    if r != revision:
        return r > revision
    keys = ("deleted_at", "dismissed_at", "published_at", "removed_at",
            "updated_at", "delivered_at", "decided_at")
    closed_at = next((dt(row.get(k)) for k in keys if dt(row.get(k))), None)
    return closed_at is None or (closed_at - when).total_seconds() >= -60


def counts(now=None):
    """Keep the same inclusion/closing rules as iOS LiveCountsSource.load()."""
    now = now or datetime.now(timezone.utc)
    prepared = rows(load("ttittulares/prepared.json"))
    decisions = rows(load("ttittulares/decisions.json"))
    closed_news = {val(x, "event_id") for x in decisions
                   if val(x, "status").lower() in TERMINAL}
    news = sum(1 for x in prepared if val(x, "event_id")
               and val(x, "event_id") not in closed_news)

    manual = latest(rows(load("trends/telegram-manual-explained.json")), "id")
    requests = latest(rows(load("trends/requests.json"), "requests"), "id")
    deliveries = latest(rows(load("trends/telegram-image-deliveries.json")), "event_id")
    closures = [x for x in rows(load("trends/mobile-decisions.json"))
                if val(x, "status").lower() in TERMINAL]
    queue = rows(load("trends/editorial-queue.json"))
    trends = 0
    for ident, item in manual.items():
        if val(item, "status").lower() != "explained" or not val(item, "explanation").strip():
            continue
        explained = dt(item.get("explained_at"))
        if explained is None or not -3600 <= (now - explained).total_seconds() <= 48 * 3600:
            continue
        leader = val(item, "group_leader_id")
        if leader and leader != ident:
            continue
        revision = rev(item)
        req = requests.get(ident, {})
        delivery = deliveries.get(ident, {})
        req_status = val(req, "status").lower()
        if req and rev(req) > revision:
            continue
        requested = dt(req.get("requested_at"))
        ready_after_request = requested is None or (explained - requested).total_seconds() >= -60
        if req_status in {"preparing", "update", "ready"} and rev(req) >= revision and not ready_after_request:
            continue
        if any(val(x, "id") == ident and val(x, "status").lower() in ACTIVE_QUEUE
               and rev(x) > revision for x in queue):
            continue
        if any(val(x, "status").lower() in TERMINAL for x in (item, req)):
            continue
        if val(item, "telegram_package_status").lower() in TERMINAL or val(req, "telegram_package_status").lower() in TERMINAL:
            continue
        if any((val(x, "id") == ident or val(x, "event_id") == ident)
               and terminal_after(x, explained, revision) for x in closures):
            continue
        if terminal_after(delivery, explained, revision):
            continue
        trends += 1
    return {"ttittulares": news, "ttendencias": trends}


def reconcile(state, current, at, enabled):
    """Pure state reducer: first read silent, 0 -> 1 alert, >0 -> >0 silent."""
    state = json.loads(json.dumps(state))
    if not state.get("initialized"):
        state.update({"version": 1, "initialized": True,
                      "lists": {k: {"count": v, "armed": v == 0, "sequence": 0}
                                for k, v in current.items()}, "outbox": []})
        return state, []
    new_events = []
    for project, count in current.items():
        row = state.setdefault("lists", {}).setdefault(
            project, {"count": count, "armed": count == 0, "sequence": 0})
        previous = int(row.get("count", 0))
        armed = bool(row.get("armed", previous == 0))
        if count == 0:
            row["armed"] = True
        elif previous == 0 and armed:
            row["armed"] = False
            row["sequence"] = int(row.get("sequence", 0)) + 1
            if enabled:
                event = {"id": f"{project}-{row['sequence']}", "project": project,
                         "count": count, "at": at.isoformat(), "status": "pending"}
                state.setdefault("outbox", []).append(event)
                new_events.append(event)
        else:
            row["armed"] = False
        row["count"] = count
    state["outbox"] = state.get("outbox", [])[-50:]
    return state, new_events


def persist(state):
    STATE.parent.mkdir(exist_ok=True, parents=True)
    STATE.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n",
                     encoding="utf-8")


def prepare():
    current = counts()
    old = json.loads(STATE.read_text(encoding="utf-8")) if STATE.exists() else {}
    new, events = reconcile(old, current, datetime.now(timezone.utc),
                            bool(os.environ.get("TT_ACTUALIDAD_NTFY_TOPIC")))
    if new != old:
        persist(new)
    print("TT_LISTAS_CHECK", json.dumps({
        "counts": current, "new_event_ids": [e["id"] for e in events],
        "delivery_enabled": bool(os.environ.get("TT_ACTUALIDAD_NTFY_TOPIC"))
    }))


def deliver():
    topic = os.environ.get("TT_ACTUALIDAD_NTFY_TOPIC", "")
    if not topic:
        print("TT_LISTAS_DELIVERY_DISABLED: no receiver configured")
        return
    if not re.fullmatch(r"[A-Za-z0-9_-]{12,128}", topic):
        raise ValueError("Invalid secret ntfy topic")
    if not STATE.exists():
        return
    state = json.loads(STATE.read_text(encoding="utf-8"))
    at = datetime.now(timezone.utc)
    changed = False
    for event in state.get("outbox", []):
        if event.get("status") != "pending":
            continue
        created = dt(event.get("at"))
        if (created is None or at - created > timedelta(hours=2)
                or state.get("lists", {}).get(event.get("project"), {}).get("count", 0) == 0):
            event["status"] = "expired"
            changed = True
            continue
        label = "Noticias" if event["project"] == "ttittulares" else "Tendencias"
        payload = f"Hay {label.lower()} en Listas. Abre TTActualidad para revisarlas.".encode()
        req = request.Request("https://ntfy.sh/" + topic, data=payload, method="POST",
                              headers={"Title": f"TTActualidad - {label} en Listas",
                                       "Priority": "default",
                                       "X-Sequence-ID": "ttactualidad-" + event["id"]})
        with request.urlopen(req, timeout=15) as response:
            if response.status // 100 != 2:
                raise RuntimeError(f"ntfy HTTP {response.status}")
        event["status"] = "sent"
        event["sent_at"] = at.isoformat()
        changed = True
        print("TT_LISTAS_SENT", event["project"], event["id"])
    if changed:
        persist(state)


def merge_ack(path):
    """Restore only delivery acknowledgements after concurrent main updates."""
    if not STATE.exists():
        return
    sent = json.loads(Path(path).read_text(encoding="utf8"))
    state = json.loads(STATE.read_text(encoding="utf8"))
    by_id = {x.get("id"): x for x in sent.get("outbox", [])
             if x.get("status") in {"sent", "expired"}}
    changed = False
    for row in state.get("outbox", []):
        source = by_id.get(row.get("id"))
        if source and row.get("status") == "pending":
            row["status"] = source["status"]
            if source.get("sent_at"):
                row["sent_at"] = source["sent_at"]
            changed = True
    if changed:
        persist(state)


def selftest():
    at = datetime(2026, 10, 28, 8, tzinfo=timezone.utc)
    state, events = reconcile({}, {"ttittulares": 2, "ttendencias": 1}, at, True)
    assert not events, "Initial nonempty state must be silent"
    state, events = reconcile(state, {"ttittulares": 8, "ttendencias": 5}, at, True)
    assert not events, "Additional stories in nonempty Listas are silent"
    state, events = reconcile(state, {"ttittulares": 0, "ttendencias": 5}, at, True)
    assert not events
    state, events = reconcile(state, {"ttittulares": 1, "ttendencias": 5}, at, True)
    assert [x["project"] for x in events] == ["ttittulares"]
    state, events = reconcile(state, {"ttittulares": 7, "ttendencias": 5}, at, True)
    assert not events
    state, events = reconcile(state, {"ttittulares": 0, "ttendencias": 0}, at, True)
    assert not events
    state, events = reconcile(state, {"ttittulares": 1, "ttendencias": 1}, at, True)
    assert len(events) == 2 and {x["project"] for x in events} == {"ttittulares", "ttendencias"}
    state, _ = reconcile(state, {"ttittulares": 0, "ttendencias": 0}, at, False)
    state, events = reconcile(state, {"ttittulares": 1, "ttendencias": 1}, at, False)
    assert not events, "No notification without opted-in destination"
    state, events = reconcile(state, {"ttittulares": 3, "ttendencias": 5}, at, True)
    assert not events, "Configuring destination cannot notify retroactively"
    assert len(state["outbox"]) == 3
    global ROOT
    old_root = ROOT
    try:
        with tempfile.TemporaryDirectory() as folder:
            ROOT = Path(folder)
            (ROOT / "ttittulares").mkdir()
            (ROOT / "trends").mkdir()
            fixtures = {
                "ttittulares/prepared.json": {"items": [
                    {"event_id": "open"}, {"event_id": "closed"}]},
                "ttittulares/decisions.json": {"items": [
                    {"event_id": "closed", "status": "deleted"}]},
                "trends/telegram-manual-explained.json": {"items": [
                    {"id": "current", "status": "explained", "revision": 0,
                     "explanation": "Factual trend", "explained_at": at.isoformat()},
                    {"id": "old", "status": "explained", "revision": 0,
                     "explanation": "Old trend", "explained_at": (at-timedelta(days=3)).isoformat()},
                    {"id": "grouped", "group_leader_id": "current", "status": "explained",
                     "revision": 0, "explanation": "Grouped", "explained_at": at.isoformat()},
                    {"id": "published", "status": "explained", "revision": 0,
                     "explanation": "Published", "explained_at": at.isoformat()}]},
                "trends/requests.json": {"requests": []},
                "trends/telegram-image-deliveries.json": {"items": []},
                "trends/editorial-queue.json": {"items": []},
                "trends/mobile-decisions.json": {"items": [
                    {"id": "published", "status": "published", "revision": 0,
                     "published_at": at.isoformat()}]}
            }
            for path, data in fixtures.items():
                target = ROOT / path
                target.write_text(json.dumps(data), encoding="utf8")
            assert counts(at) == {"ttittulares": 1, "ttendencias": 1}
    finally:
        ROOT = old_root
    print("TT_ACTUALIDAD_LISTAS_ALERT_SELFTEST_OK")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["prepare", "deliver", "merge-ack", "selftest"])
    parser.add_argument("path", nargs="?")
    args = parser.parse_args()
    if args.command == "merge-ack":
        if not args.path:
            parser.error("merge-ack requires path")
        merge_ack(args.path)
    else:
        {"prepare": prepare, "deliver": deliver, "selftest": selftest}[args.command]()
