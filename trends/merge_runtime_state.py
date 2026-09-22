#!/usr/bin/env python3
import argparse, json
from pathlib import Path

STATUS_ORDER = {"preparing": 1, "update": 1, "ready": 2, "explained": 3}

def load(path, default):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return default

def norm(s):
    return " ".join(str(s or "").split()).casefold()

def noise_name(s):
    v = norm(s)
    return (
        v.startswith("explore why ")
        or (" is trending " in (" " + v + " ") and "latest viral tweets" in v)
        or "real-time buzz from twitter" in v
    )

def merge_requests(remote, local):
    out = []
    by_key = {}
    order = []

    def key(item):
        return str(item.get("id") or "") or ("name:" + norm(item.get("name")))

    for src in (remote.get("requests", []), local.get("requests", [])):
        for item in src:
            if noise_name(item.get("name")):
                continue
            k = key(item)
            if not k:
                continue
            if k not in by_key:
                by_key[k] = dict(item)
                order.append(k)
                continue
            cur = by_key[k]
            cur_status = cur.get("status")
            new_status = item.get("status")
            cur_revision = int(cur.get("revision") or 0)
            new_revision = int(item.get("revision") or 0)

            # Una reexplicación explícita abre una revisión nueva. Esa revisión
            # debe ganar incluso frente a un "explained" antiguo que siga vivo
            # en un listener concurrente. Dentro de la misma revisión sí
            # mantenemos la progresión preparing/update -> ready -> explained.
            if new_revision > cur_revision:
                merged = dict(cur)
                merged.update(item)
                by_key[k] = merged
            elif new_revision < cur_revision:
                merged = dict(item)
                merged.update(cur)
                by_key[k] = merged
            elif STATUS_ORDER.get(new_status, 0) >= STATUS_ORDER.get(cur_status, 0):
                merged = dict(cur)
                merged.update(item)
                by_key[k] = merged
            else:
                # Preserve useful metadata from the lower-priority writer without
                # allowing a state regression within the same revision.
                merged = dict(item)
                merged.update(cur)
                by_key[k] = merged

    for k in order:
        out.append(by_key[k])
    return {"requests": out}

def merge_manual(remote, local):
    seen = set()
    items = []
    for src in (remote.get("items", []), local.get("items", [])):
        for item in src:
            if noise_name(item.get("name")):
                continue
            k = norm(item.get("name"))
            if not k:
                continue
            if k in seen:
                # Keep the latest timestamp when available.
                for i, old in enumerate(items):
                    if norm(old.get("name")) == k and str(item.get("explained_at") or "") > str(old.get("explained_at") or ""):
                        items[i] = dict(item)
                continue
            seen.add(k)
            items.append(dict(item))
    base = dict(remote or local or {})
    base["items"] = items
    return base

def merge_listener(remote, local):
    out = dict(remote or {})
    out.update(local or {})
    out["last_update_id"] = max(
        int((remote or {}).get("last_update_id") or 0),
        int((local or {}).get("last_update_id") or 0),
    )
    return out

def merge_bot_state(remote, local, merged_requests):
    # Remote carries the freshest user actions. Local may carry newly sent message IDs.
    out = dict(remote or {})
    for k, v in (local or {}).items():
        if k == "pending":
            continue
        if k not in out or out.get(k) in (None, "", [], {}):
            out[k] = v

    explained = {
        norm(x.get("name")) for x in merged_requests.get("requests", [])
        if x.get("status") == "explained"
    }
    pending = {}
    for src in ((remote or {}).get("pending", {}), (local or {}).get("pending", {})):
        for key, item in src.items():
            related = [norm(x) for x in item.get("related_trends", []) if norm(x)]
            if not related and item.get("name"):
                related = [norm(item.get("name"))]
            if related and all(x in explained for x in related):
                continue
            pending[key] = item
    out["pending"] = pending
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--local-requests")
    ap.add_argument("--local-state")
    ap.add_argument("--local-manual")
    ap.add_argument("--local-listener")
    ap.add_argument("--local-health")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent

    remote_requests = load(root / "requests.json", {"requests": []})
    local_requests = load(args.local_requests, {"requests": []}) if args.local_requests else {"requests": []}
    merged_requests = merge_requests(remote_requests, local_requests)
    (root / "requests.json").write_text(json.dumps(merged_requests, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if args.local_state:
        remote_state = load(root / "telegram-bot-state.json", {})
        local_state = load(args.local_state, {})
        merged_state = merge_bot_state(remote_state, local_state, merged_requests)
        (root / "telegram-bot-state.json").write_text(json.dumps(merged_state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if args.local_manual:
        remote_manual = load(root / "telegram-manual-explained.json", {"items": []})
        local_manual = load(args.local_manual, {"items": []})
        merged_manual = merge_manual(remote_manual, local_manual)
        (root / "telegram-manual-explained.json").write_text(json.dumps(merged_manual, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if args.local_listener:
        remote_listener = load(root / "telegram-listener-state.json", {})
        local_listener = load(args.local_listener, {})
        merged_listener = merge_listener(remote_listener, local_listener)
        (root / "telegram-listener-state.json").write_text(json.dumps(merged_listener, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if args.local_health:
        local_health = load(args.local_health, None)
        if local_health is not None:
            (root / "health-status.json").write_text(json.dumps(local_health, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()
