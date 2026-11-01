#!/usr/bin/env python3
"""Build the public archive-only photo index used by TTActualidad web.

Only *real* files already committed under archive-images are eligible.
ImageGen/TTImages/generated-images cannot enter this index. No network access.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "shared" / "archive-photo-index.json"
PATTERN = re.compile(
    r"^(ttittulares|trends)/archive-images/([A-Za-z0-9_-]+)-r([0-9]+)-"
    r"[A-Za-z0-9_-]+\.(?:png|jpe?g|webp)$", re.I
)
BASE = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"


def build(paths: list[str]) -> dict:
    result = {}
    for path in sorted(set(paths)):
        match = PATTERN.fullmatch(path)
        if not match:
            continue
        project, event_id, revision = match.groups()
        project = "ttittulares" if project == "ttittulares" else "ttendencias"
        key = f"{project}:{event_id}:r{int(revision)}"
        # Prefer an immutable in-repo raster, deterministic selection across runs.
        result.setdefault(key, BASE + path)
    return {"schema_version": 1, "kind": "archive_only", "photos": dict(sorted(result.items()))}


def main() -> int:
    tracked = subprocess.run(
        ["git", "ls-files", "--", "ttittulares/archive-images", "trends/archive-images"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    index = build(tracked)
    DEST.parent.mkdir(exist_ok=True)
    DEST.write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")
    print(f"ARCHIVE_INDEX_OK {len(index['photos'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
