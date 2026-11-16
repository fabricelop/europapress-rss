#!/usr/bin/env python3
"""Source catalogue helpers for TTittulares V2. No network access or writes."""
from __future__ import annotations
import json
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent
CATALOG_PATH = ROOT / "source_catalog_v2.json"


def load_catalog():
    data = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    validate_catalog(data)
    return data


def validate_catalog(data):
    if data.get("project") != "ttittulares-v2" or data.get("schema_version") != 1:
        raise ValueError("CATALOG_VERSION_INVALID")
    rows = data.get("sources")
    if not isinstance(rows, list):
        raise ValueError("CATALOG_SOURCES_INVALID")
    names = [str(row.get("name") or "") for row in rows]
    if not all(names) or len(names) != len(set(names)):
        raise ValueError("CATALOG_SOURCE_NAMES_INVALID")
    general = [row for row in rows if row.get("type") == "general"]
    sport = [row for row in rows if row.get("type") == "sport"]
    discovery = [row for row in rows if row.get("type") in ("discovery", "social")]
    families = {row["family"] for row in general}
    policy = data.get("policy") or {}
    if (len(general) != policy.get("general_sources")
            or len(families) != policy.get("general_families")
            or len(sport) != policy.get("sport_sources")
            or len(discovery) != policy.get("discovery_sources")):
        raise ValueError("CATALOG_COUNTS_DO_NOT_MATCH_POLICY")
    if policy.get("minimum_general_families") != 4 or policy.get("waiting_ttl_hours") != 24:
        raise ValueError("CATALOG_EDITORIAL_THRESHOLD_INVALID")
    return True


def source_map(catalog=None):
    catalog = catalog or load_catalog()
    return {row["name"]: row for row in catalog["sources"]}


def source_family(source, catalog=None):
    row = source_map(catalog).get(str(source or ""))
    return row.get("family", str(source)) if row else str(source or "")


def fallback_chain(source, *, include_recovery=True, catalog=None):
    """Return source-preserving URLs; Google News remains the same source family."""
    row = source_map(catalog).get(source)
    if not row:
        return []
    urls = []
    for value in [row.get("url")] + list(row.get("fallback_urls") or []):
        if value and value not in urls:
            urls.append(value)
    domain = row.get("domain")
    if domain and row.get("type") in ("general", "sport"):
        query = quote("site:" + domain)
        fallback = "https://news.google.com/rss/search?q=" + query + "&hl=es&gl=ES&ceid=ES:es"
        if fallback not in urls:
            urls.append(fallback)
        if include_recovery:
            recovery_query = quote("site:" + domain + " when:24h")
            recovery = "https://news.google.com/rss/search?q=" + recovery_query + "&hl=es&gl=ES&ceid=ES:es"
            if recovery not in urls:
                urls.append(recovery)
    return urls


if __name__ == "__main__":
    c = load_catalog()
    print("TTN2_CATALOG_OK", len(c["sources"]),
          "general", c["policy"]["general_sources"],
          "families", c["policy"]["general_families"],
          "sport", c["policy"]["sport_sources"],
          "discovery", c["policy"]["discovery_sources"])
