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
dated = row(current, "fresh", 30)
dated["update_hint"] = "Trending now Oct 25, 2026 21:50 UTC"
source_data = {"frozen": frozen, "changing": changing, "dated": dated}
previous = {
    "captured_at": (now - timedelta(minutes=10)).isoformat(),
    "sources": {
        "frozen": {**row(old, "fresh", 11), "update_hint": frozen["update_hint"],
                   "last_list_change_at": (now - timedelta(minutes=70)).isoformat(),
                   "relative_hint_unchanged_since": (now - timedelta(minutes=40)).isoformat()},
        "changing": row(old, "unknown"),
        "dated": row(current, "fresh", 32),
    },
}
module.reconcile_source_freshness(source_data, previous, now)
assert source_data["frozen"]["freshness"] == "stale", source_data["frozen"]
assert source_data["changing"]["freshness"] == "corroborated-change", source_data["changing"]
top10, _, chosen, method = module.choose_top10(source_data)
assert chosen in {"dated", "changing"} and method in {"fresh-anchor", "corroborated-anchor"} and top10 == current[:10], (chosen, method, top10)
assert "dated" in source_data["changing"]["corroborating_sources"]
print("TT_SOURCE_CONTINUITY_OK: frozen feed excluded, corroborated changing feed selected")

# A stuck "11 minutes ago" label must be rejected on the next full refresh.
# An independent hourly source, even if just >90min old, may corroborate
# the VISUAL list, but the editorial queue must still require fresher proof.
now2 = datetime(2026, 10, 25, 23, 35, tzinfo=module.MADRID)
frozen2 = {**row(old, "fresh", 11), "update_hint": "Last updated: 11 minutes ago"}
live2 = {**row(current, "unknown"), "update_hint": None}
hourly2 = {**row(current, "stale", 95), "update_hint": "Trending now Oct 25, 2026 21:00 UTC"}
prev2 = {
    "captured_at": (now2 - timedelta(minutes=12)).isoformat(),
    "sources": {
        "whatstrends": {**frozen2, "last_list_change_at": (now2 - timedelta(minutes=52)).isoformat(),
                        "relative_hint_unchanged_since": (now2 - timedelta(minutes=12)).isoformat()},
        "getdaytrends": row(old, "unknown"),
        "snaplytics": hourly2,
    },
}
actual2 = {"whatstrends": frozen2, "getdaytrends": live2, "snaplytics": hourly2}
module.reconcile_source_freshness(actual2, prev2, now2)
assert actual2["whatstrends"]["freshness"] == "stale", actual2["whatstrends"]
assert actual2["getdaytrends"]["freshness"] == "unknown", actual2["getdaytrends"]
top10, supporters, chosen, method = module.choose_top10(actual2)
assert chosen != "getdaytrends" and method != "corroborated-anchor", (chosen, method, supporters)
print("TT_FAST_FROZEN_FEED_OK: 95-minute-old peer cannot certify a fresh undated feed")

# A 71-minute dated mirror agreeing with a new, undated page DOES NOT
# establish a live X ranking or authorize automated research.
now3 = datetime(2026, 11, 7, 23, 35, tzinfo=module.MADRID)
undated = {**row(current, "unknown"), "update_hint": None}
hourly = {**row(current, "aging", 71), "update_hint": "Updated: November 07, 2026 at 10:00 PM"}
sources3 = {"getdaytrends": undated, "fowtools": hourly}
prev3 = {"captured_at": (now3 - timedelta(minutes=11)).isoformat(),
         "sources": {"getdaytrends": row(old, "unknown"), "fowtools": hourly}}
module.reconcile_source_freshness(sources3, prev3, now3)
assert sources3["getdaytrends"]["freshness"] == "unknown"
assert not any(x.get("freshness") == "fresh" for x in sources3.values())
print("TT_UNDATED_AGE_GUARD_OK: no false corroboration from stale or aging providers")

# New independent Spanish provider: only sequential rank + exact Spain/X
# listing is parsed, sidebars and generic article links must not appear.
names = ["Koldo", "Paraguay", "Alcaraz", "Sivera", "Zelda",
         "Broncano", "Abascal", "Fritz", "Valencia", "Mestalla"]
fixture = ("<div>España</div><div>Últimos 7 días</div>"
           "<div>01 DÓNDE ESTÁ PASANDO</div>" +
           "".join(f"<div>{i}</div><div>{name}</div><div>Ver en X</div>"
                   for i, name in enumerate(names, 1)) +
           "<div>02 HACIA DÓNDE VA</div><div>1</div><div>NOISE</div><div>Ver en X</div>")
assert module.parse_gosocialsuite(fixture) == names
assert module.parse_gosocialsuite(fixture.replace("España", "Francia")) == []
print("TT_SPAIN_SOURCE_GUARD_OK: exact 1-10 country scope without extra noise")

# A source with NO observation timestamp cannot keep confirming a ranking
# after its exact top list has been frozen for hours. Previously SuperX
# remained "unknown" for >30h and could vote in consensus as a live peer.
now4 = datetime(2026, 11, 8, 15, 40, tzinfo=module.MADRID)
stuck = row(["Paraguay", "Cracovia"] + old, "unknown")
stuck["update_hint"] = None
changed = row(["Cracovia", "Paraguay"] + current, "unknown")
changed["update_hint"] = None
previous4 = {
    "captured_at": (now4 - timedelta(minutes=10)).isoformat(),
    "sources": {
        "superx": {**stuck, "last_list_change_at":
                   (now4 - timedelta(hours=4)).isoformat()},
        "getdaytrends": row(old, "unknown"),
    }
}
actual4 = {"superx": stuck, "getdaytrends": changed}
module.reconcile_source_freshness(actual4, previous4, now4)
assert actual4["superx"]["freshness"] == "stale", actual4["superx"]
assert actual4["superx"]["freshness_note"] == "undated-ranking-unchanged-90m"
assert actual4["getdaytrends"]["freshness"] == "unknown", actual4["getdaytrends"]
assert module.choose_top10(actual4)[2] != "superx", actual4
assert actual4["superx"]["trends"][:2] == ["Paraguay", "Cracovia"]
print("TT_UNDATED_FROZEN_FEED_OK: unchanged 4h undated ranking does not vote")
