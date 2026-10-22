#!/usr/bin/env python3
"""Regression from Spain TT radar's diverging 2026-10-22 23:41 local snapshots.
Prevent a near-duplicate provider pair from outweighing diverse newer trends.
These synthetic test fixtures are fixed, not fetched at runtime.
"""
import importlib.util
from pathlib import Path

src = Path(__file__).resolve().parents[2] / "trends" / "update_trends.py"
spec = importlib.util.spec_from_file_location("trends_live", src)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

sources = {
  "getdaytrends": {
    "ok": True,
    "freshness": "unknown",
    "age_minutes": None,
    "trends": [
      "#SánchezEnLaRevuelta",
      "#SVGala7",
      "Javi Rodríguez",
      "#Horizonte",
      "Broncano",
      "Bordalás",
      "Tom Skerritt",
      "Lugano",
      "#RealSociedad",
      "Jimena",
      "Maccabi",
      "Felipe González",
      "Top Gun",
      "#CelticCelta",
      "Celtic Park"
    ]
  },
  "superx": {
    "ok": True,
    "freshness": "unknown",
    "age_minutes": None,
    "trends": [
      "Milei",
      "#LaIslaDeLasTentaciones14",
      "Argentina",
      "Bioware",
      "Coruña",
      "Broncano",
      "#FelizJueves",
      "Mass Effect",
      "Abascal",
      "#Mañaneros22O",
      "#ZurdosYOrgullosos",
      "#EnBocaDeTodos",
      "Nico Paz",
      "Avilés",
      "Cabrera",
      "San Juan Pablo II",
      "Barça",
      "Galicia",
      "Jordi Wild",
      "Diomande"
    ]
  },
  "snaplytics": {
    "ok": True,
    "freshness": "fresh",
    "age_minutes": 41.6,
    "trends": [
      "#SánchezEnLaRevuelta",
      "#SVGala7",
      "Milei",
      "#Horizonte",
      "Javi Rodríguez",
      "Argentina",
      "#LaIslaDeLasTentaciones14",
      "BioWare",
      "Omar",
      "Jordi Wild",
      "Coruña",
      "#TEM22O",
      "Celta",
      "Mass Effect",
      "Abascal",
      "Avilés",
      "Bordalás",
      "Tom Skerritt",
      "Marrero",
      "Zurdos"
    ]
  },
  "whatstrends": {
    "ok": True,
    "freshness": "fresh",
    "age_minutes": 19,
    "trends": [
      "Milei",
      "Argentina",
      "#LaIslaDeLasTentaciones14",
      "Broncano",
      "BioWare",
      "Coruña",
      "Mass Effect",
      "#FelizJueves",
      "Abascal",
      "#TEM22O",
      "Jordi Wild",
      "La Revuelta",
      "Avilés",
      "Zurdos",
      "Abqar",
      "Cabrera",
      "San Juan Pablo II",
      "Felipe González",
      "Teruel",
      "Nico Paz"
    ]
  },
  "cyberkendra": {
    "ok": True,
    "freshness": "unknown",
    "age_minutes": None,
    "trends": [
      "#SánchezEnLaRevuelta",
      "#SVGala7",
      "#Horizonte",
      "Javi Rodríguez",
      "Broncano",
      "Tom Skerritt",
      "Bordalás",
      "Lugano",
      "Felipe González",
      "Jimena",
      "Maccabi",
      "Top Gun",
      "Coalición Canaria",
      "Abqar",
      "Martina",
      "Conference",
      "Chiara",
      "#UECL",
      "Europa League",
      "Glasgow"
    ]
  }
}
top10, supporters, name, method = module.choose_top10(sources)
assert (name, method) == ("snaplytics", "fresh-anchor"), (name, method, supporters, top10)
assert top10[:2] == ["#SánchezEnLaRevuelta", "#SVGala7"], top10
assert "Javi Rodríguez" in top10 and "#Horizonte" in top10, top10

# Even if many providers appear in the pool, an explicitly stale aggregator
# must never count as evidence to switch or hold the current editorial radar.
sources["old_mirror"] = dict(sources["whatstrends"], freshness="stale", age_minutes=170)
assert module.choose_top10(sources)[2] == "snaplytics"

# When two independent current observations split 50/50, the fresher wins.
fresh_a = {"ok": True, "freshness": "fresh", "age_minutes": 10,
           "trends": [f"A-{i}" for i in range(20)]}
fresh_b = {"ok": True, "freshness": "fresh", "age_minutes": 30,
           "trends": [f"B-{i}" for i in range(20)]}
assert module.choose_top10({"a": fresh_a, "b": fresh_b})[2] == "a"
print("TT_RADAR_SOURCE_DIVERSITY_OK")
