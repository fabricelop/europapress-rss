#!/usr/bin/env python3
"""Read-only audit of possible duplicate stories across both TT accounts.

It never writes repository state and never publishes anything. It compares:
- TTiTTulares prepared items; and
- TTendencias current explained rows when available, plus published explanation
  history from explained-copy-state.json.

The output is only a candidate report for tuning before any integration.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from shared.cross_account_story_matcher import classify_story_pair\nfrom shared.cross_account_x_search import build_x_account_search_url

ROOT = Path(__file__).resolve().parents[1]\nCONFIG = load_config_path = ROOT / "shared" / "cross_account_story_config.json"


def load_json(path: Path, default):
    try:
        raw = path.read_text(encoding="utf-8").strip()
        return json.loads(raw) if raw else default
    except Exception:
        return default


def account_handles():\n    cfg = load_json(CONFIG, {})\n    accounts = cfg.get("accounts") or {}\n    return {\n        "ttittulares": str((accounts.get("ttittulares") or {}).get("handle") or "ttittulares"),\n        "ttendencias": str((accounts.get("ttendencias") or {}).get("handle") or "ttendenciasesp"),\n    }\n\n\ndef news_rows():
    doc = load_json(ROOT / "ttittulares" / "prepared.json", {"items": []})
    for row in doc.get("items", []):
        tweet = row.get("tweet") or {}
        text = " ".join(
            str(x or "").strip()
            for x in (
                row.get("title"),
                row.get("factual_summary"),
                tweet.get("text"),
            )
            if str(x or "").strip()
        )
        if text:
            yield {
                "id": str(row.get("event_id") or ""),
                "revision": int(row.get("revision") or 0),
                "label": str(row.get("title") or ""),
                "text": text,
            }


def trend_rows():
    seen = set()

    manual = load_json(
        ROOT / "trends" / "telegram-manual-explained.json",
        {"items": []},
    )
    for row in manual.get("items", []):
        tid = str(row.get("id") or row.get("item_id") or "")
        rev = int(row.get("revision") or 0)
        key = (tid, rev)
        explanation = str(row.get("explanation") or "").strip()
        subject = str(row.get("name") or "").strip()
        if not subject:
            names = row.get("trend_names") or []
            subject = str(names[0] if names else "").strip()
        if tid and explanation:
            seen.add(key)
            yield {
                "id": tid,
                "revision": rev,
                "label": subject,
                "subject": subject,
                "text": explanation,
                "source": "current",
            }

    history = load_json(
        ROOT / "trends" / "explained-copy-state.json",
        {"items": []},
    )
    for row in history.get("items", []):
        tid = str(row.get("item_id") or row.get("id") or "")
        rev = int(row.get("revision") or 0)
        key = (tid, rev)
        if not tid or key in seen:
            continue
        explanation = str(row.get("explanation") or "").strip()
        names = row.get("trend_names") or []
        subject = str(
            (names[0] if names else None)
            or row.get("group_title")
            or row.get("name")
            or ""
        ).strip()
        if explanation:
            yield {
                "id": tid,
                "revision": rev,
                "label": subject,
                "subject": subject,
                "text": explanation,
                "source": "history",
            }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--same-story", type=float, default=0.55)
    parser.add_argument("--same-topic", type=float, default=0.34)
    parser.add_argument("--minimum", choices=["same_story", "same_topic"], default="same_topic")
    args = parser.parse_args()

    rank = {"independent": 0, "same_topic": 1, "same_story": 2}
    minimum = rank[args.minimum]

    news = list(news_rows())
    trends = list(trend_rows())
    matches = []\n    handles = account_handles()

    for n in news:
        for t in trends:
            result = classify_story_pair(
                n["text"],
                t["text"],
                subject=t.get("subject") or "",
                same_story_threshold=args.same_story,
                same_topic_threshold=args.same_topic,
            )
            if rank[result.classification] < minimum:
                continue
            matches.append({
                "classification": result.classification,
                "score": result.score,
                "news_id": n["id"],
                "news": n["label"],
                "trend_id": t["id"],
                "trend": t["label"],
                "trend_source": t["source"],
                "anchors": list(result.shared_anchors),\n                "search_original_if_ttittulares_first": build_x_account_search_url(\n                    handles["ttittulares"], n["label"], t["label"], *result.shared_anchors\n                ),\n                "search_original_if_ttendencias_first": build_x_account_search_url(\n                    handles["ttendencias"], t["label"], n["label"], *result.shared_anchors\n                ),
            })

    matches.sort(key=lambda x: (-x["score"], x["news_id"], x["trend_id"]))
    print(json.dumps({
        "mode": "read_only_audit",
        "news_count": len(news),
        "trend_count": len(trends),
        "matches": matches,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
