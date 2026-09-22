import json
import re
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parent
RECENT = ROOT / "recent.json"
MADRID = ZoneInfo("Europe/Madrid")
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124 Safari/537.36",
    "Accept-Language": "es-ES,es;q=0.9,en;q=0.7",
    "Cache-Control": "no-cache",
}
SOURCES = {
    "trends24": "https://trends24.in/spain/",
    "getdaytrends": "https://getdaytrends.com/es/spain/",
    "tweets24": "https://tweets24.com/trending-on-twitter-in-spain",
    "superx": "https://superx.so/twitter-trends/spain",
    "twtdata": "https://twtdata.com/twitter-trends/spain/",
    "snaplytics": "https://twitter-trends.snaplytics.io/spain/",
    "fowtools": "https://fowtools.com/x-trends/spain",
    "cyberkendra": "https://trends.cyberkendra.com/spain/",
    "globaltwittertrends": "https://globaltwittertrends.com/spain/",
    "trendswe": "https://trendswe.com/twitter/spain/",
    "twittertrending": "https://www.twitter-trending.com/spain/es",
}

def clean(text):
    return re.sub(r"\s+", " ", (text or "")).strip()

def clean_term(text):
    text = clean(text)
    text = re.sub(r"\s+N/?A$", "", text, flags=re.I)
    text = re.sub(r"\s+(?:Less than )?\d+(?:[.,]\d+)?[KMB]?\s+(?:tweets|posts)$", "", text, flags=re.I)
    return text.strip()

def term_key(text):
    # Algunos agregadores anteponen # incluso a temas que no son hashtags.
    # Ignoramos un # inicial solo para comparar fuentes; conservamos el nombre
    # real de la fuente elegida para mostrarlo.
    return clean_term(text).casefold().lstrip("#")

def unique(values):
    out, seen = [], set()
    for value in values:
        value = clean_term(value)
        key = value.casefold()
        if not value or key in seen or len(value) > 100:
            continue
        seen.add(key)
        out.append(value)
    return out

def get(url):
    r = requests.get(url, headers=HEADERS, timeout=30, params={"_": int(datetime.now().timestamp())})
    r.raise_for_status()
    return r.content.decode("utf-8", errors="replace")

def parse_trends24(html):
    soup = BeautifulSoup(html, "html.parser")
    for selector in (".trend-card__list li a", ".trend-card li a", ".trend-card ol li a"):
        vals = unique(a.get_text(" ", strip=True) for a in soup.select(selector))
        if len(vals) >= 10:
            return vals[:20]
    card = soup.select_one(".trend-card")
    if card:
        vals = unique(a.get_text(" ", strip=True) for a in card.find_all("a"))
        if len(vals) >= 10:
            return vals[:20]
    return []

def parse_getdaytrends(html):
    soup = BeautifulSoup(html, "html.parser")
    for table in soup.find_all("table"):
        rows = []
        for tr in table.find_all("tr"):
            cells = tr.find_all(["td", "th"])
            if len(cells) < 2:
                continue
            first = clean(cells[0].get_text(" ", strip=True))
            if first.isdigit():
                name = clean_term(cells[1].get_text(" ", strip=True))
                if name:
                    rows.append(name)
        if len(rows) >= 10:
            return unique(rows)[:20]
    return []

def parse_tweets24(html):
    soup = BeautifulSoup(html, "html.parser")

    # Tweets24 presenta cada tendencia como un enlace del tipo:
    # "1 Berlín Explore why Berlín is trending — ...".
    # Extraer cada fila desde su enlace evita que el texto auxiliar "Explore why"
    # se interprete accidentalmente como una tendencia independiente.
    ranked = []
    for a in soup.find_all("a"):
        label = clean(a.get_text(" ", strip=True))
        m = re.match(r"^(\d{1,2})\s+(.+?)\s+Explore why\b", label, flags=re.I)
        if not m:
            continue
        rank = int(m.group(1))
        name = clean_term(m.group(2))
        if 1 <= rank <= 50 and name:
            ranked.append((rank, name))
    if len(ranked) >= 10:
        ranked.sort(key=lambda x: x[0])
        return unique(name for _, name in ranked)[:20]

    # Fallback defensivo para cambios menores de HTML.
    text = clean(soup.get_text(" ", strip=True))
    marker = "Live Twitter Trending Topics in Spain"
    if marker in text:
        text = text.split(marker, 1)[1]
    vals = []
    for m in re.finditer(r"(?:^|\s)(\d{1,2})\s+(.+?)\s+Explore why\b", text, flags=re.I):
        rank = int(m.group(1))
        name = clean_term(m.group(2))
        if 1 <= rank <= 50 and name:
            vals.append((rank, name))
    vals.sort(key=lambda x: x[0])
    return unique(name for _, name in vals)[:20]


def page_update_hint(html):
    soup = BeautifulSoup(html, "html.parser")
    text = clean(soup.get_text(" ", strip=True))
    patterns = [
        r"(Updated\s*:?\s*[^|•]{1,80})",
        r"(Last updated\s*:?\s*[^|•]{1,80})",
        r"(updated\s+\d+\s+(?:minutes?|hours?)\s+ago)",
        r"(Trending now\s+[A-Z][a-z]{2}\s+\d{1,2},\s+\d{4}\s+\d{1,2}:\d{2}\s+UTC)",
        r"(\d{1,2}\s+[A-Z][a-z]+\s+\d{4},\s+\d{1,2}:\d{2}\s+[AP]M\s+[A-Z]{2,4})",
    ]
    for pattern in patterns:
        m = re.search(pattern, text, flags=re.I)
        if m:
            return clean(m.group(1))[:120]
    return None

def hint_age_minutes(hint, now):
    if not hint:
        return None
    m = re.search(r"(\d+)\s+(minutes?|hours?)\s+ago", hint, flags=re.I)
    if m:
        n = int(m.group(1))
        return float(n if m.group(2).lower().startswith("minute") else n * 60)

    value = re.sub(r"^(?:Last\s+)?Updated\s*:?\s*", "", hint, flags=re.I)
    value = re.sub(r"^Trending now\s*", "", value, flags=re.I)
    value = re.split(r"\s+#\s*Trend\b", value, maxsplit=1, flags=re.I)[0]
    value = clean(value)
    is_utc = bool(re.search(r"\bUTC\b", value, flags=re.I))
    value = re.sub(r"\s+UTC\b", "", value, flags=re.I)
    value = re.sub(r"\bat\b", "", value, flags=re.I)
    value = clean(value)
    for fmt in ("%B %d, %Y %I:%M %p", "%B %d, %Y %H:%M", "%b %d, %Y %H:%M"):
        try:
            tz = timezone.utc if is_utc else MADRID
            dt = datetime.strptime(value, fmt).replace(tzinfo=tz).astimezone(MADRID)
            return max(0.0, (now - dt).total_seconds() / 60)
        except ValueError:
            pass
    return None

def parse_ranked_table(html):
    soup = BeautifulSoup(html, "html.parser")
    candidates = []
    for table in soup.find_all("table"):
        rows = []
        for tr in table.find_all("tr"):
            cells = tr.find_all(["td", "th"])
            if len(cells) < 2:
                continue
            first = clean(cells[0].get_text(" ", strip=True)).lstrip("#")
            if not first.isdigit():
                continue
            rank = int(first)
            if not 1 <= rank <= 100:
                continue
            name = clean(cells[1].get_text(" ", strip=True))
            name = re.sub(r"^(?:#\s*)?(\d{1,3})\s+", "", name)
            if name and len(name) <= 100:
                rows.append((rank, name))
        if len(rows) >= 10:
            candidates.append(rows)
    if not candidates:
        return []
    rows = max(candidates, key=len)
    rows.sort(key=lambda x: x[0])
    return unique(name for _, name in rows)[:20]

def parse_ranked_text(html):
    soup = BeautifulSoup(html, "html.parser")
    text = soup.get_text("\n", strip=True)
    vals = []
    for line in text.splitlines():
        line = clean(line)
        m = re.match(r"^(\d{1,2})[.)#\s-]+(.+)$", line)
        if not m:
            continue
        rank = int(m.group(1))
        if not 1 <= rank <= 50:
            continue
        name = clean_term(m.group(2))
        name = re.split(r"\s+(?:Explore why|Less than|N/A|Football|Politics|Video games|Open on X)\b", name, 1)[0]
        if name and len(name) <= 100:
            vals.append((rank, name))
    vals.sort(key=lambda x: x[0])
    return unique(name for _, name in vals)[:20]

def parse_generic_ranked(html):
    vals = parse_ranked_table(html)
    if len(vals) >= 10:
        return vals
    return parse_ranked_text(html)

def sane_trend_list(trends):
    if len(trends) < 10:
        return False
    bad = 0
    noise = re.compile(
        r"\b(?:hour|hours|minute|minutes)\s+ago\b|\bUTC\b|^Updated\b|^Last updated\b"
        r"|^Explore why\b|\bis trending\s+[—-]\s+latest viral tweets\b|\breal-time buzz from Twitter\b",
        flags=re.I,
    )
    for item in trends[:20]:
        if noise.search(item):
            bad += 1
    return bad == 0

def fetch_source(name):
    fetched_at = datetime.now(MADRID)
    try:
        parsers = {
            "trends24": parse_trends24,
            "getdaytrends": parse_getdaytrends,
            "tweets24": parse_tweets24,
        }
        html = get(SOURCES[name])
        parser = parsers.get(name, parse_generic_ranked)
        trends = parser(html)
        hint = page_update_hint(html)
        age = hint_age_minutes(hint, fetched_at)
        ok = sane_trend_list(trends)
        if age is None:
            freshness = "unknown"
        elif age <= 45:
            freshness = "fresh"
        elif age <= 90:
            freshness = "aging"
        else:
            freshness = "stale"
        return {
            "ok": ok,
            "trends": trends if ok else [],
            "error": None if ok else f"Lista no válida ({len(trends)} elementos parseados)",
            "update_hint": hint,
            "age_minutes": round(age, 1) if age is not None else None,
            "freshness": freshness if ok else "invalid",
            "fetched_at": fetched_at.isoformat(timespec="seconds"),
        }
    except Exception as e:
        return {
            "ok": False,
            "trends": [],
            "error": f"{type(e).__name__}: {e}",
            "update_hint": None,
            "age_minutes": None,
            "freshness": "error",
            "fetched_at": fetched_at.isoformat(timespec="seconds"),
        }

def previous_top10():
    try:
        return json.loads(RECENT.read_text(encoding="utf-8")).get("top10", [])
    except Exception:
        return []

def overlap(a, b, limit=20):
    aa = {term_key(x) for x in a[:limit]}
    bb = {term_key(x) for x in b[:limit]}
    return len(aa & bb) / max(1, len(aa | bb))

def consensus_fallback(good):
    stats = {}
    for source, trends in good.items():
        for idx, term in enumerate(trends[:20], 1):
            key = term_key(term)
            row = stats.setdefault(key, {"name": term, "support": 0, "score": 0, "best_rank": 999})
            row["support"] += 1
            row["score"] += max(1, 21 - idx)
            row["best_rank"] = min(row["best_rank"], idx)
    ranked = sorted(
        stats.values(),
        key=lambda x: (-x["support"], -x["score"], x["best_rank"], x["name"].casefold()),
    )
    return [x["name"] for x in ranked[:10]]

def choose_top10(source_data):
    good = {n: d for n, d in source_data.items() if d.get("ok")}
    if not good:
        return [], [], "none", "none"

    fresh = {n: d for n, d in good.items() if d.get("freshness") == "fresh"}
    if fresh:
        # La frescura manda: elegimos la fuente fresca más corroborada por las demás.
        def fresh_score(item):
            name, data = item
            return sum(overlap(data["trends"], other["trends"]) for oname, other in good.items() if oname != name)
        anchor_name, anchor = max(fresh.items(), key=fresh_score)
        supporters = [
            name for name, data in good.items()
            if name == anchor_name or overlap(anchor["trends"], data["trends"]) >= 0.35
        ]
        return anchor["trends"][:10], supporters, anchor_name, "fresh-anchor"

    usable = {n: d["trends"] for n, d in good.items() if d.get("freshness") != "stale"}
    if not usable:
        usable = {n: d["trends"] for n, d in good.items()}
    if len(usable) == 1:
        name, trends = next(iter(usable.items()))
        return trends[:10], [name], name, "fallback"
    return consensus_fallback(usable), list(usable), "consensus", "consensus"

def main():
    now = datetime.now(MADRID)
    previous = previous_top10()
    source_data = {name: fetch_source(name) for name in SOURCES}

    top10, sources_used, chosen_name, method = choose_top10(source_data)
    if len(top10) < 10:
        raise RuntimeError("No se pudo obtener un Top 10 fiable de las fuentes disponibles")

    unchanged = [x.casefold() for x in top10] == [x.casefold() for x in previous]
    valid = [n for n, d in source_data.items() if d.get("ok")]
    non_stale = [n for n, d in source_data.items() if d.get("ok") and d.get("freshness") != "stale"]
    fresh = [n for n, d in source_data.items() if d.get("ok") and d.get("freshness") == "fresh"]
    reliability = "high" if len(non_stale) >= 6 else ("medium" if len(non_stale) >= 3 else "fallback")

    payload = {
        "project": "TTendencias",
        "country": "ES",
        "captured_at": now.isoformat(timespec="seconds"),
        "primary_source": chosen_name,
        "selection_method": method,
        "sources_used": sources_used,
        "source_count": len(valid),
        "non_stale_source_count": len(non_stale),
        "fresh_sources": fresh,
        "reliability": reliability,
        "top10": top10,
        "items": [{"rank": i + 1, "name": name} for i, name in enumerate(top10)],
        "unchanged_from_previous": unchanged,
        "sources": source_data,
    }
    RECENT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        f"TTendencias: {chosen_name} via {method}; valid={len(valid)}/{len(SOURCES)}, "
        f"non_stale={len(non_stale)}, fresh={len(fresh)}, reliability={reliability}; "
        f"Top 10: {', '.join(top10)}"
    )

if __name__ == "__main__":
    main()
