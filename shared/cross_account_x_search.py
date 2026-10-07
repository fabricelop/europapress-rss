"""Helpers for safe, manual cross-account X searches.

No X API is used. The generated URL opens X search already restricted to the
source account, so the operator can locate the original post and quote it.
"""

from __future__ import annotations

import re
import unicodedata
import urllib.parse

GENERIC = {
    "noticia","noticias","tendencia","porque","cuenta","explica","explican","dice",
    "segun","sobre","para","desde","hasta","entre","como","tras","esta","este",
    "estos","estas","unos","unas","del","las","los","una","con","sin","por","que",
    "ser","son","fue","han","hay","mas","muy","hoy","ayer","mañana"
}


def _ascii_key(value: str) -> str:
    return (
        unicodedata.normalize("NFKD", value or "")
        .encode("ascii", "ignore")
        .decode("ascii")
        .lower()
    )


def search_keywords(*texts: str, limit: int = 4) -> list[str]:
    words = []
    seen = set()
    for text in texts:
        for token in re.findall(r"[^\W_]+", text or "", flags=re.UNICODE):
            key = _ascii_key(token)
            if len(key) < 3 or key in GENERIC or key.isdigit() or key in seen:
                continue
            seen.add(key)
            words.append(token)
            if len(words) >= limit:
                return words
    return words


def build_x_account_search_url(handle: str, *texts: str) -> str:
    clean_handle = str(handle or "").strip().lstrip("@")
    if not clean_handle:
        raise ValueError("X handle is required")
    terms = search_keywords(*texts)
    query = " ".join([f"from:{clean_handle}", *terms]).strip()
    return "https://x.com/search?" + urllib.parse.urlencode({
        "q": query,
        "src": "typed_query",
        "f": "live",
    })
