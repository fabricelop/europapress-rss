#!/usr/bin/env python3
"""Regression: the anticipation radar must retain observations across refreshes."""
import importlib.util
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

src = Path(__file__).resolve().parents[2] / "trends" / "update_trends.py"
spec = importlib.util.spec_from_file_location("tt_update_trends", src)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# Spelling/accent variants refer to the same real-world topic.
assert module.term_key("Mazón") == module.term_key("Mazon")
assert module.term_key("#PSGbarca") == module.term_key("#PSGBarça")
assert module.unique(["Mazón", "Mazon", "#PSGbarca", "#PSGBarça"]) == ["Mazón", "#PSGbarca"]
now = datetime.now(ZoneInfo("Europe/Madrid"))
visible = ["Visible"]
names = ["Relleno A", "Relleno B", "Emergente", "Conocida"]
def sources(order):
    return {
        "social_a": {"ok": True, "freshness": "fresh", "trends": list(order)},
        "social_b": {"ok": True, "freshness": "unknown", "trends": list(order)},
    }
def capture(order, prev, tick):
    return module.build_upcoming(
        sources(order), visible, prev, {"events": {}}, {},
        now + timedelta(minutes=10 * tick),
    )
prev = {
    "captured_at": (now - timedelta(minutes=10)).isoformat(timespec="seconds"),
    "top30": ["Conocida"], "top10": ["Conocida"], "upcoming": [],
}
first, state1 = capture(names, prev, 0)
assert any(x["name"] == "Emergente" and x["movement"] == "new" for x in first), first
assert not any(x["name"] == "Conocida" and x["movement"] == "new" for x in first), first

prev1 = {"captured_at": now.isoformat(timespec="seconds"), "top30": visible,
         "top10": visible, "upcoming": first, "radar_history": state1}
second, state2 = capture(names, prev1, 1)
assert not second, second  # All existing signals are flat: no false 'new'.

prev2 = {"captured_at": (now + timedelta(minutes=10)).isoformat(timespec="seconds"),
         "top30": visible, "top10": visible, "upcoming": second,
         "radar_history": state2}
changed = ["Emergente", "Relleno A", "Relleno B", "Conocida"]
third, state3 = capture(changed, prev2, 2)
promoted = next(x for x in third if x["name"] == "Emergente")
assert promoted["movement"] == "up", promoted
assert promoted["observations"] == 3, promoted

# An omitted signal remains in history even after leaving the upcoming view.
empty, state4 = module.build_upcoming(
    {}, visible, {"captured_at": now.isoformat(), "top30": visible,
                 "top10": visible, "upcoming": third, "radar_history": state3},
    {"events": {}}, {}, now + timedelta(minutes=30))
assert not empty, empty
assert "emergente" in state4, state4
again, state5 = capture(changed, {"captured_at": now.isoformat(),
                                 "top30": visible, "top10": visible,
                                 "upcoming": [], "radar_history": state4}, 4)
assert not any(x["name"] == "Emergente" and x["movement"] == "new" for x in again), again
assert len(state5["emergente"]["rank_history"]) == 4, state5["emergente"]

# A later Top 10 entry is anticipated even when the previous radar VIEW is empty.
prior = {"top10": visible, "top30": visible, "upcoming": [], "radar_history": state5}
anticipated = module.anticipated_entries(
    ["Emergente"], prior, now + timedelta(minutes=50))
assert len(anticipated) == 1 and anticipated[0]["name"] == "Emergente", anticipated
prior["top10"] = ["Emergente"]
assert not module.anticipated_entries(
    ["Emergente"], prior, now + timedelta(minutes=60))
print("TT_RADAR_HISTORY_OK: continuity, movement, Top30 exits and promotion")
