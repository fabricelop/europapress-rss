#!/usr/bin/env python3
"""Read-only integration audit: already associated editor-uploaded PNGs."""
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ttactualidad_buffer_publish as publisher

root = Path(__file__).resolve().parents[1]
for project, manifest in [("ttendencias", "trends/site-ai-images.json"),
                          ("ttittulares", "ttittulares/site-ai-images.json")]:
    images = json.loads((root / manifest).read_text(encoding="utf-8"))["images"]
    candidates = [r for r in images if "raw.githubusercontent.com" in str(r.get("image_url"))
                  and "-manual-" in str(r.get("image_url"))]
    print("project", project, "manual_candidates", len(candidates))
    if not candidates:
        raise SystemExit("Missing manual uploaded samples for " + project)
    # Sample the latest several first, but do not publish or approve anything.
    passed = 0
    for row in candidates[:3]:
        try:
            validated = publisher.check_image(row["image_url"], row["sha256"],
                    project, row["target_id"], row["revision"])
            if validated != row["image_url"]:
                raise ValueError("Unexpected canonical redirect for GitHub original")
            passed += 1
        except Exception as exc:
            print("FAIL",project,row["target_id"],type(exc).__name__,str(exc)[:110])
            raise
    print("live_manual_uploads_verified",project,passed)
