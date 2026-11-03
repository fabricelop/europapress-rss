#!/usr/bin/env python3
"""Lossless serializer for the shared TTendencias editorial request history.

The image-approval Site currently validates the complete requests.json against
a 12-million UTF-16-unit budget. Any writer that emits indented JSON can
recreate an availability incident even after a successful capacity repair.
Only requests.json is compacted; every other editorial file keeps its prior
human-readable formatting.
"""
from __future__ import annotations

import json
from pathlib import Path


def dumps_for_path(path: str | Path, document: object) -> str:
    if Path(path).name != "requests.json":
        return json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    if not isinstance(document, dict) or not isinstance(document.get("requests"), list):
        raise ValueError("requests.json must contain the original requests list")
    return json.dumps(
        document,
        ensure_ascii=False,
        separators=(",", ":"),
        allow_nan=False,
    ) + "\n"
