#!/usr/bin/env python3
"""Retira rasterizaciones SVG heredadas de los campos reservados a ImageGen."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
EXPLAINED = ROOT / "telegram-manual-explained.json"


def migrate_item(item: dict) -> bool:
    ai = item.get("ai_image") or {}
    if str(ai.get("provider") or "") != "chat-svg":
        return False

    technical = dict(ai)
    technical["source"] = "TTendencias / fallback técnico SVG heredado"
    technical["kind"] = "legacy_svg_raster"
    technical["generated"] = False
    technical["rights_status"] = "technical"
    item["technical_image"] = technical
    item.pop("ai_image", None)
    item["legacy_ai_attempt_count"] = int(item.get("ai_image_attempt") or ai.get("generation_attempt") or 1)
    item["ai_image_attempt"] = 1
    item["ai_image_status"] = "failed"
    item["ai_image_last_attempt_status"] = "failed"
    item["ai_image_failure_reason"] = "El resultado heredado era un SVG técnico, no una generación de ImageGen del chat."

    selected = item.get("image") or {}
    if str(selected.get("provider") or "") == "chat-svg" or item.get("image_choice") == "ai":
        fallback = item.get("fallback_image") or {}
        if str(fallback.get("url") or "").startswith("https://") and fallback.get("generated") is not True:
            item["image"] = dict(fallback)
            item["image_choice"] = "fallback"
            item["image_status"] = "ready"
        else:
            item.pop("image", None)
            item["image_choice"] = "none"
            item["image_status"] = "none"
        item["image_pending"] = False
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    doc = json.loads(EXPLAINED.read_text(encoding="utf-8"))
    changed = sum(1 for item in doc.get("items", []) if migrate_item(item))
    if args.check:
        if changed:
            raise SystemExit(f"Quedan {changed} ai_image heredadas con provider=chat-svg")
        print("NO_LEGACY_CHAT_SVG_AI_IMAGES")
        return 0
    if changed:
        EXPLAINED.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"migrated": changed}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
