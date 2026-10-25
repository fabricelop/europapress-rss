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

# Regression: frozen relative hint must not repeatedly reset source freshness.
from datetime import datetime, timedelta
now = datetime(2026, 10, 25, 23, 20, tzinfo=module.MADRID)
frozen = row(old, "fresh", 11)
frozen["update_hint"] = "Last updated: 11 minutes ago"
changing = row(current, "unknown")
changing["update_hint"] = None
dated = row(current, "aging", 70)
dated["update_hint"] = "Trending now Oct 25, 2026 21:00 UTC"
source_data = {"frozen": frozen, "changing": changing, "dated": dated}
previous = {
    "captured_at": (now - timedelta(minutes=10)).isoformat(),
    "sources": {
        "frozen": {**row(old, "fresh", 11), "update_hint": frozen["update_hint"],
                   "last_list_change_at": (now - timedelta(minutes=70)).isoformat(),
                   "relative_hint_unchanged_since": (now - timedelta(minutes=40)).isoformat()},
        "changing": row(old, "unknown"),
        "dated": row(current, "aging", 60),
    },
}
module.reconcile_source_freshness(source_data, previous, now)
assert source_data["frozen"]["freshness"] == "stale", source_data["frozen"]
assert source_data["changing"]["freshness"] == "corroborated-change", source_data["changing"]
top10, _, chosen, method = module.choose_top10(source_data)
assert chosen == "changing" and method == "corroborated-anchor" and top10 == current[:10], (chosen, method, top10)
print("TT_SOURCE_CONTINUITY_OK: frozen feed excluded, corroborated changing feed selected")
