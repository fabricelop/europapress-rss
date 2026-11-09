#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline, NON-PUBLISHING SEO preview from the authoritative TTActualidad Top 30.

Usage (run from repository root):
  python3 seo-prep/ttactualidad/prepare_seo.py \
    --input trends/site-top30-current.json --out /tmp/ttactualidad-seo-preview \
    --names "Broncano,Golden Boy,James Gunn,#TEM9N,TikTok"

SECURITY: does not contact the Site, publish files, change GitHub editorial
state, request indexing or create a sitemap of unverified URLs. All previews
are explicitly noindex; output MUST be outside any deployed web directory.
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import json
from pathlib import Path
import re
import unicodedata
from urllib.parse import urlparse

CANONICAL_SITE = "https://ttactualidad.rainyraven22.chatgpt.site"
EDITORIAL_ID = re.compile(r"^[a-f0-9]{8,40}$")
DEFAULT_PILOT = ("Broncano", "Golden Boy", "James Gunn", "#TEM9N", "TikTok")


def slugify(name: str) -> str:
    normalized = unicodedata.normalize("NFKD", str(name)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", normalized).strip("-")[:75] or "tendencia"


def parse_date(value: object) -> str | None:
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return None
        return parsed.isoformat()
    except (TypeError, ValueError):
        return None


def valid_source(value: object) -> bool:
    if not isinstance(value, str):
        return False
    parsed = urlparse(value)
    return parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username


def clean_description(text: str, limit: int = 155) -> str:
    first_line = next((x.strip() for x in str(text).splitlines() if x.strip()), "")
    # A snippet must reflect the original explanation; never invent a cause.
    first_line = re.sub(r"^TT#\d+\s*", "", first_line)
    if len(first_line) <= limit:
        return first_line
    return first_line[:limit - 1].rsplit(" ", 1)[0].rstrip(" ,.;:") + "…"


def candidate(row: dict, site: str = CANONICAL_SITE) -> dict | None:
    if not isinstance(row, dict) or str(row.get("status", "")).upper() != "EXPLICADA":
        return None
    ident = str(row.get("editorial_id") or "").lower().strip()
    name = str(row.get("name") or "").strip()
    explanation = str(row.get("explanation") or "").strip()
    published_at = parse_date(row.get("explained_at"))
    try:
        revision = int(row.get("revision", 0))
    except (TypeError, ValueError):
        return None
    if not EDITORIAL_ID.fullmatch(ident) or not name or not explanation or not published_at or revision < 0:
        return None
    sources = list(dict.fromkeys(
        u for u in (row.get("verification_sources") or []) if valid_source(u)
    ))
    if not sources:
        return None
    # An editorial ID denotes the stable story/episode. Revision updates the
    # existing page; a materially distinct episode needs a DIFFERENT ID.
    path = "/tendencias/" + slugify(name) + "-" + ident + "/"
    proposed_url = site.rstrip("/") + path
    reviewed = parse_date(row.get("last_reviewed_at"))
    modified = reviewed if reviewed and reviewed >= published_at else published_at
    description = clean_description(explanation)
    title = "¿Por qué es tendencia " + name + "? | TTActualidad"
    if len(title) > 75:
        title = "Por qué es tendencia " + name + " | TTActualidad"
    return {
        "editorial_id": ident, "revision": revision, "name": name,
        "rank_in_snapshot": row.get("rank"),
        "title": title, "description": description,
        "explanation_verbatim": explanation,
        "closer_verbatim": str(row.get("closer_text") or "").strip(),
        "date_published": published_at, "date_modified": modified,
        "sources": sources, "proposed_path": path, "proposed_url_NOT_LIVE": proposed_url,
        "structured_data_CANDIDATE_NOT_PUBLISHED": {
            "@context": "https://schema.org", "@type": "Article",
            "headline": title.replace(" | TTActualidad", ""),
            "description": description,
            "datePublished": published_at, "dateModified": modified,
            "author": {"@type": "Organization", "name": "TTActualidad"},
            "publisher": {"@type": "Organization", "name": "TTActualidad"},
            "mainEntityOfPage": {"@type": "WebPage", "@id": proposed_url},
            "about": {"@type": "Thing", "name": name},
            "inLanguage": "es-ES",
        },
    }


def pick_pages(rows: list, names: tuple[str, ...], limit: int, site: str) -> list[dict]:
    by_name = {}
    for row in rows:
        entry = candidate(row, site=site)
        if entry is not None:
            by_name.setdefault(entry["name"].casefold(), entry)
    candidates = [by_name[name.casefold()] for name in names if name.casefold() in by_name]
    # Fallback only for data snapshots without one of the named pilot terms:
    # still select fully explained source-backed entries, never fabricate.
    if not candidates:
        candidates = list(by_name.values())
    unique = []
    ids = set()
    for entry in candidates:
        if entry["editorial_id"] not in ids:
            ids.add(entry["editorial_id"])
            unique.append(entry)
        if len(unique) >= limit:
            break
    return unique


def preview_page(page: dict, radar_verified: bool) -> str:
    esc = lambda x: html.escape(str(x), quote=True)
    paragraphs = "".join("<p>" + esc(p.strip()) + "</p>" for p in page["explanation_verbatim"].splitlines() if p.strip())
    sources = "".join('<li><a rel="noopener noreferrer" target="_blank" href="' +
                      esc(url) + '">' + esc(url) + '</a></li>' for url in page["sources"])
    note = ("El radar de la instantánea no estaba verificado en tiempo real; "
            "no presentar esta posición como ranking oficial de X."
            if not radar_verified else "Información editorial fechada: comprobar vigencia antes de publicar.")
    # All files are PREVIEWS, intentionally noindex and with NO canonical tag.
    # Work must materialize real 200-response URLs before adding canonical.
    return f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>{esc(page['title'])} · PREVISUALIZACIÓN NO PUBLICADA</title>
<meta name="description" content="{esc(page['description'])}">
<style>body{{font:16px/1.6 system-ui,sans-serif;max-width:760px;padding:20px;margin:auto}}
small{{color:#555}}header{{background:#fff4cf;padding:1rem;border:1px solid #d7b45e}}
article{{padding-top:1rem}}li{{overflow-wrap:anywhere}}</style></head><body>
<header><strong>PREVISUALIZACIÓN INTERNA · NO PUBLICADA NI INDEXABLE</strong>
<p>Propuesta de ruta: <code>{esc(page['proposed_path'])}</code></p></header>
<main><article><h1>{esc(page['title'].replace(' | TTActualidad', ''))}</h1>
<p><small>Explicación editorial: <time datetime="{esc(page['date_published'])}">{esc(page['date_published'])}</time></small></p>
<section aria-labelledby="explicacion"><h2 id="explicacion">¿Qué ocurre?</h2>{paragraphs}</section>
<section aria-labelledby="fuentes"><h2 id="fuentes">Fuentes citadas</h2><ul>{sources}</ul></section>
<p><small>{esc(note)}</small></p>
<p><a href="{esc(CANONICAL_SITE)}/">TTActualidad · Top 30</a></p>
</article></main></body></html>"""


def build(source: Path, out: Path, names: tuple[str, ...] = DEFAULT_PILOT,
          limit: int = 5, site: str = CANONICAL_SITE) -> dict:
    source_data = json.loads(source.read_text(encoding="utf-8"))
    rows = source_data.get("items")
    if not isinstance(rows, list) or limit <= 0:
        raise ValueError("Top 30 inválido o límite no positivo")
    parsed_site = urlparse(site)
    if parsed_site.scheme != "https" or not parsed_site.hostname or parsed_site.path not in ("", "/"):
        raise ValueError("URL del Site inválida")
    pages = pick_pages(rows, names, limit, site)
    if not pages:
        raise ValueError("Ninguna ficha EXPLICADA con fecha, ID y fuentes válidas")
    out.mkdir(parents=True, exist_ok=True)
    previews = out / "previews"
    previews.mkdir(exist_ok=True)
    verified = source_data.get("radar_live_verified") is True
    for page in pages:
        (previews / (page["editorial_id"] + ".html")).write_text(
            preview_page(page, verified), encoding="utf-8")
    manifest = {
        "status": "DRAFT_ONLY_NEVER_DEPLOYED",
        "source_file": str(source),
        "source_generated_at": source_data.get("generated_at"),
        "source_radar_live_verified": verified,
        "destination_proposed_NOT_VALIDATED": site,
        "rules": {
            "no_new_editorial_facts": True,
            "no_claim_of_live_radar_if_unverified": True,
            "no_urls_submitted_to_search_engines": True,
            "site_unchanged": True,
            "real_sitemap_requires_tested_HTTP_200_urls": True,
        },
        "pages": pages,
    }
    (out / "seo-pilot-DRAFT.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"SEO SOLO PREPARADO: {len(pages)} vistas noindex en {previews}; NO se ha cambiado el Site")
    return manifest


def cli() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path,
                        help="Directorio local SIN despliegue, preferiblemente /tmp")
    parser.add_argument("--names", default=",".join(DEFAULT_PILOT))
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument("--site", default=CANONICAL_SITE)
    args = parser.parse_args()
    build(args.input, args.out,
          tuple(x.strip() for x in args.names.split(",") if x.strip()),
          args.limit, args.site)


if __name__ == "__main__":
    cli()
