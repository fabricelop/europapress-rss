#!/usr/bin/env python3
"""Export the same current Top 30 explanation selection used by TTActualidad iOS.

Authoritative read-only inputs: recent.json + telegram-manual-explained.json
+ explained.json + requests.json, all from ONE GitHub main checkout.

The exported JSON is public, small and contains no PC jobs, tokens or editorial
actions. An entry being 'deleted' removes it from Listas, NOT from the
historical explanation candidates used by the iPhone's Top 30.
"""
from __future__ import annotations

import argparse
import json
import re
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "trends" / "site-top30-current.json"
SITE_HOST = "ttactualidad-tendencias.rainyraven22.chatgpt.site"
AGE_LIMIT = timedelta(hours=48)
FUTURE_LIMIT = timedelta(hours=1)


def norm(value):
    value = unicodedata.normalize("NFD", str(value or ""))
    value = "".join(char for char in value if unicodedata.category(char) != "Mn")
    return " ".join(value.casefold().split())


def when(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else None
    except ValueError:
        return None


def select_date(row, keys=("updated_at", "explained_at")):
    for key in keys:
        result = when(row.get(key))
        if result is not None:
            return result
    return None


def text(row, key):
    value = row.get(key, "")
    return value if isinstance(value, str) else ""


def rows(doc, key="items"):
    result = doc.get(key, []) if isinstance(doc, dict) else []
    return result if isinstance(result, list) else []


def explanation_names(row):
    names = [text(row, "name"), text(row, "display_name")]
    if text(row, "listas_group_role") != "joint":
        names.extend(n for n in row.get("trend_names", []) if isinstance(n, str))
        names.extend(text(t, "name") for t in row.get("trend_context", []) if isinstance(t, dict))
    return [name for name in names if name]


def best_explanations(manual, explained, requests):
    """Replicate Swift buildTop30 selection: source order and >= timestamp ties.

    IMPORTANT: do not filter status=deleted/published/covered. Those statuses
    govern Listas. Top30 iOS intentionally considers every explanatory row.
    """
    result = {}
    for row in rows(manual) + rows(explained) + rows(requests, "requests"):
        if not isinstance(row, dict) or not text(row, "explanation"):
            continue
        stamp = select_date(row)
        for name in explanation_names(row):
            key = norm(name)
            if not key:
                continue
            old = result.get(key)
            if old is None or (stamp or datetime.min.replace(tzinfo=timezone.utc)) >= (
                select_date(old) or datetime.min.replace(tzinfo=timezone.utc)
            ):
                result[key] = row
    return result


def request_statuses(requests):
    latest = {}
    for row in rows(requests, "requests"):
        if not isinstance(row, dict):
            continue
        key = norm(text(row, "name"))
        if not key:
            continue
        old = latest.get(key)
        # Swift isNewer uses revision before event time.
        if old is None or int(row.get("revision") or 0) > int(old.get("revision") or 0) or (
            int(row.get("revision") or 0) == int(old.get("revision") or 0)
            and (select_date(row, ("updated_at", "deleted_at", "explained_at", "requested_at")) or datetime.min.replace(tzinfo=timezone.utc))
                >= (select_date(old, ("updated_at", "deleted_at", "explained_at", "requested_at")) or datetime.min.replace(tzinfo=timezone.utc))
        ):
            latest[key] = row
    statuses = {}
    for key, row in latest.items():
        value = text(row, "status").lower()
        if value in {"preparing", "update", "ready"}:
            statuses[key] = "EN ELABORACIÓN"
        elif value in {"problematic", "inactive"} and text(row, "problem_reason"):
            statuses[key] = "SIN EXPLICACIÓN"
    return statuses


def image_index(catalog):
    index = {}
    for row in rows(catalog, "images"):
        if not isinstance(row, dict):
            continue
        try:
            revision = int(row.get("revision"))
        except (TypeError, ValueError):
            continue
        key = (text(row, "target_id"), revision)
        if key in index:
            index[key] = None  # ambiguity: do not show wrong image
        else:
            index[key] = row
    return index


def recorded_image(row, image_map):
    ident = (text(row, "id"), int(row.get("revision") or 0))
    candidate = image_map.get(ident)
    if not isinstance(candidate, dict):
        return None
    for key in ("explanation", "explained_at"):
        if text(candidate, key) != text(row, key):
            return None
    url = text(candidate, "image_url")
    digest = text(candidate, "sha256")
    u = urlparse(url)
    if not (u.scheme == "https" and u.netloc == SITE_HOST and
            u.path.startswith("/images/ttendencias/") and u.path.endswith(".png")
            and not (u.query or u.fragment or u.params)
            and re.fullmatch(r"[0-9a-f]{64}", digest)):
        return None
    # The catalog records an original, but only the Site/browser can verify
    # that the PNG still responds; never label this file as storage-verified.
    return {"url": url, "sha256": digest, "status": "catalog_recorded"}


def export_top30(recent, manual, explained, requests, catalog=None, now=None):
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    by_name = best_explanations(manual, explained, requests)
    statuses = request_statuses(requests)
    images = image_index(catalog or {})
    by_rank = {}
    movement = {}
    for idx, item in enumerate(rows(recent)):
        if not isinstance(item, dict):
            continue
        rank = item.get("rank") or idx + 1
        name = text(item, "name")
        if isinstance(rank, int) and 1 <= rank <= 30 and name:
            by_rank[rank] = name
            movement[rank] = item
    names = recent.get("top30", []) if isinstance(recent, dict) else []
    if isinstance(names, list):
        for rank, name in enumerate(names[:30], 1):
            if rank not in by_rank and isinstance(name, str) and name:
                by_rank[rank] = name
    if not by_rank:
        raise ValueError("No Top30 ranking from authoritative radar")
    output = []
    for rank in range(1, 31):
        name = by_rank.get(rank)
        if not name:
            continue
        key = norm(name)
        candidate = by_name.get(key, {})
        explained_at = when(candidate.get("explained_at"))
        fresh = bool(explained_at and now - explained_at <= AGE_LIMIT
                     and explained_at - now <= FUTURE_LIMIT)
        chosen = candidate if fresh else {}
        exp = text(chosen, "explanation")
        status = statuses.get(key, "EXPLICADA" if exp else "PENDIENTE")
        selected = {
            "card_id": f"rank-{rank}",  # visible row identity; never editorial identity
            "rank": rank, "name": name,
            "status": status,
            "explanation": exp,
            "explained_at": text(chosen, "explained_at"),
            "editorial_id": text(chosen, "id"),
            "revision": int(chosen.get("revision") or 0),
            "group_title": text(chosen, "group_title"),
            "image": recorded_image(chosen, images) if exp else None,
            "movement": text(movement.get(rank, {}), "movement"),
        }
        output.append(selected)
    return {
        "schema_version": 1,
        "source": "ttactualidad-ios-buildTop30-parity",
        "generated_at": now.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "radar_captured_at": text(recent, "captured_at"),
        "count": len(output),
        "items": output,
    }


def read(path):
    with (ROOT / path).open(encoding="utf-8") as stream:
        return json.load(stream)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=OUT)
    args = parser.parse_args()
    result = export_top30(
        read("trends/recent.json"),
        read("trends/telegram-manual-explained.json"),
        read("trends/explained.json"),
        read("trends/requests.json"),
        read("trends/site-ai-images.json"),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("TT_SITE_TOP30_EXPORTED", result["count"], args.output)


if __name__ == "__main__":
    main()
