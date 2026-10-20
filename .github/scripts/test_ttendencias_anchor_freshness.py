#!/usr/bin/env python3
"""Regression: a stale aggregator must not choose an older TTendencias Top 10."""
import importlib.util
from pathlib import Path

src = Path(__file__).resolve().parents[2] / "trends" / "update_trends.py"
spec = importlib.util.spec_from_file_location("tt_update_trends", src)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

old = [f"old-{n}" for n in range(1, 21)]
current = [f"current-{n}" for n in range(1, 21)]
def row(names, freshness, age=None):
    return {"ok": True, "trends": names, "freshness": freshness,
            "age_minutes": age}

# Before the fix, old_anchor won because stale_mirror gave it an
# extra corroboration vote, even though current_anchor matched a
# distinct live aggregator perfectly.
sources = {
    "old_anchor": row(old, "fresh", 21),
    "old_partial": row(old[:18] + current[:2], "unknown"),
    "stale_mirror": row(old, "stale", 92),
    "current_anchor": row(current, "fresh", 19),
    "current_peer": row(current, "unknown"),
}
top10, peers, chosen, method = module.choose_top10(sources)
assert chosen == "current_anchor", (chosen, peers, top10)
assert method == "fresh-anchor", method
assert top10 == current[:10], top10
assert "stale_mirror" not in peers, peers

# A clear freshness tie is broken by younger observation age.
tie = {
    "older": row(old, "fresh", 30),
    "newer": row(current, "fresh", 10),
}
top10, _, chosen, _ = module.choose_top10(tie)
assert chosen == "newer" and top10 == current[:10], (chosen, top10)

# When every available source is stale, keep the existing fallback
# policy; stale evidence alone must not be promoted as fresh.
assert module.overlap(old, current) == 0.0
print("TT_FRESH_ANCHOR_OK: stale votes excluded and fresher anchor preferred")
