import json
import re
import unicodedata
from urllib.parse import parse_qs, unquote, urlparse
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parent
RECENT = ROOT / "recent.json"
TTITTULARES_STATUS = ROOT.parent / "ttittulares" / "status.json"
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


def parse_x_search_links(html):
    """Extrae tendencias de enlaces directos de búsqueda en X/Twitter.
    Es más robusto que depender del texto visible, que suele mezclar rango,
    categoría y volumen de publicaciones."""
    soup = BeautifulSoup(html, "html.parser")
    ranked = []
    fallback = []
    for a in soup.find_all("a", href=True):
        href = str(a.get("href") or "")
        if "x.com" not in href and "twitter.com" not in href:
            continue
        parsed = urlparse(href)
        query = parse_qs(parsed.query)
        q = unquote((query.get("q") or [""])[0]).strip()
        label = clean(a.get_text(" ", strip=True))
        rank_m = re.match(r"^#?(\d{1,2})\s*", label)
        if q:
            # Algunos enlaces añaden operadores de búsqueda. Para una tendencia
            # queremos el término limpio mostrado por la propia página.
            term = q
            term = re.sub(r"\s+(?:filter:|lang:|since:|until:).*$", "", term, flags=re.I)
            term = clean_term(term.strip('"'))
            if term and len(term) <= 100:
                if rank_m:
                    ranked.append((int(rank_m.group(1)), term))
                else:
                    fallback.append(term)
            continue

        # SuperX suele llevar el rango pegado al texto del enlace (1Granada).
        if rank_m:
            term = clean_term(label[rank_m.end():])
            if term and len(term) <= 100:
                ranked.append((int(rank_m.group(1)), term))

    if ranked:
        ranked = [(r, n) for r, n in ranked if 1 <= r <= 100]
        ranked.sort(key=lambda x: x[0])
        vals = unique(name for _, name in ranked)
        if len(vals) >= 10:
            return vals[:20]
    vals = unique(fallback)
    return vals[:20] if len(vals) >= 10 else []


def parse_superx(html):
    return parse_x_search_links(html)


def parse_snaplytics(html):
    vals = parse_x_search_links(html)
    if len(vals) >= 10:
        return vals
    # Fallback: la página expone filas como "#1 #SVGala2".
    soup = BeautifulSoup(html, "html.parser")
    rows = []
    for line in soup.get_text("\n", strip=True).splitlines():
        line = clean(line)
        m = re.match(r"^#?(\d{1,2})\s+(.+)$", line)
        if not m:
            continue
        rank = int(m.group(1))
        if not 1 <= rank <= 100:
            continue
        name = clean_term(m.group(2))
        name = re.split(r"\s*[·|]\s*(?:Politics|Football|Only on X|La Liga|NFL|Pop|Strategy games|Survival competition)\b", name, 1, flags=re.I)[0]
        if name:
            rows.append((rank, name))
    rows.sort(key=lambda x: x[0])
    return unique(name for _, name in rows)[:20]


def page_update_hint(html):
    soup = BeautifulSoup(html, "html.parser")
    text = clean(soup.get_text(" ", strip=True))
    patterns = [
        # Preferir marcas temporales explícitas antes que textos genéricos
        # del tipo "updated hourly", que no permiten calcular frescura.
        r"(Trending now\s+[A-Z][a-z]{2}\s+\d{1,2},\s+\d{4}\s+\d{1,2}:\d{2}\s+UTC)",
        r"(updated\s+\d+\s+(?:minutes?|hours?)\s+ago)",
        r"(Last updated\s*:?\s*[^|•]{1,80})",
        r"(Updated\s*:?\s*[^|•]{1,80})",
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
            "superx": parse_superx,
            "snaplytics": parse_snaplytics,
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


def load_json(path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {} if default is None else default

def fold_text(value):
    text = unicodedata.normalize("NFD", str(value or ""))
    text = "".join(ch for ch in text if unicodedata.category(ch) != "Mn")
    text = text.casefold().lstrip("#")
    text = re.sub(r"[^\w]+", " ", text, flags=re.UNICODE)
    return clean(text)

def term_matches_title(term, title):
    term_fold = fold_text(term)
    title_fold = fold_text(title)
    words = [w for w in term_fold.split() if len(w) >= 3]
    if not words:
        return False
    if len(words) == 1:
        return re.search(rf"(?:^|\s){re.escape(words[0])}(?:\s|$)", title_fold) is not None
    return all(re.search(rf"(?:^|\s){re.escape(word)}(?:\s|$)", title_fold) for word in words)

def best_news_signal(term, status_doc):
    best = None
    for event_id, event in (status_doc.get("events") or {}).items():
        if str(event.get("status") or "") == "DISMISSED":
            continue
        if not term_matches_title(term, event.get("title")):
            continue
        row = {
            "event_id": event_id,
            "title": str(event.get("title") or ""),
            "source_count": int(event.get("source_count") or 0),
            "status": str(event.get("status") or ""),
            "last_seen": event.get("last_seen"),
        }
        if best is None or row["source_count"] > best["source_count"]:
            best = row
    return best

def lower_rank_stats(source_data, top10):
    top_keys = {term_key(x) for x in top10}
    stats = {}
    for source, data in source_data.items():
        if not data.get("ok") or data.get("freshness") in {"stale", "invalid", "error"}:
            continue
        for rank, term in enumerate((data.get("trends") or [])[:20], 1):
            if rank <= 10:
                continue
            key = term_key(term)
            if not key or key in top_keys:
                continue
            row = stats.setdefault(key, {
                "name": term,
                "social_source_count": 0,
                "social_sources": [],
                "ranks": [],
                "best_observed_rank": 999,
            })
            row["social_source_count"] += 1
            row["social_sources"].append(source)
            row["ranks"].append(rank)
            row["best_observed_rank"] = min(row["best_observed_rank"], rank)
    return stats

def build_upcoming(source_data, top10, previous_doc, status_doc, now):
    stats = lower_rank_stats(source_data, top10)
    previous = {term_key(x.get("name")): x for x in (previous_doc.get("upcoming") or []) if x.get("name")}
    rows = []
    for key, row in stats.items():
        news = best_news_signal(row["name"], status_doc)
        news_count = int((news or {}).get("source_count") or 0)
        social_count = int(row["social_source_count"])
        if social_count < 2 and not (social_count >= 1 and news_count >= 4):
            continue

        prev = previous.get(key)
        previous_rank = int((prev or {}).get("best_observed_rank") or 999)
        previous_support = int((prev or {}).get("social_source_count") or 0)
        if prev is None:
            movement = "new"
        elif row["best_observed_rank"] < previous_rank or social_count > previous_support:
            movement = "up"
        elif row["best_observed_rank"] > previous_rank or social_count < previous_support:
            movement = "down"
        else:
            movement = "flat"

        # La puntuación solo ordena internamente las señales. La interfaz muestra
        # los datos observados (fuentes, posición y cobertura), no una probabilidad.
        score = (
            social_count * 20
            + max(0, 21 - int(row["best_observed_rank"])) * 2
            + min(news_count, 14) * 3
            + (6 if movement == "up" else 0)
        )
        rows.append({
            "name": row["name"],
            "social_source_count": social_count,
            "social_sources": sorted(set(row["social_sources"])),
            "best_observed_rank": int(row["best_observed_rank"]),
            "mean_observed_rank": round(sum(row["ranks"]) / max(1, len(row["ranks"])), 1),
            "movement": movement,
            "first_detected_at": (prev or {}).get("first_detected_at") or now.isoformat(timespec="seconds"),
            "news_source_count": news_count,
            "news_event_id": (news or {}).get("event_id"),
            "news_title": (news or {}).get("title"),
            "news_status": (news or {}).get("status"),
            "_score": score,
        })

    rows.sort(key=lambda x: (-x["_score"], -x["social_source_count"], x["best_observed_rank"], x["name"].casefold()))
    for row in rows:
        row.pop("_score", None)
    return rows[:8]

def anticipated_entries(top10, previous_doc, now):
    prior = {term_key(x.get("name")): x for x in (previous_doc.get("upcoming") or []) if x.get("name")}
    out = []
    for name in top10:
        row = prior.get(term_key(name))
        if not row:
            continue
        detected = row.get("first_detected_at")
        lead = None
        try:
            start = datetime.fromisoformat(str(detected).replace("Z", "+00:00"))
            if start.tzinfo is None:
                start = start.replace(tzinfo=MADRID)
            lead = max(0, round((now - start.astimezone(MADRID)).total_seconds() / 60))
        except Exception:
            pass
        out.append({
            "name": name,
            "first_detected_at": detected,
            "entered_top10_at": now.isoformat(timespec="seconds"),
            "lead_minutes": lead,
        })
    return out

def main():
    now = datetime.now(MADRID)
    previous_doc = load_json(RECENT, {})
    previous = previous_doc.get("top10", [])
    source_data = {name: fetch_source(name) for name in SOURCES}

    top10, sources_used, chosen_name, method = choose_top10(source_data)
    if len(top10) < 10:
        raise RuntimeError("No se pudo obtener un Top 10 fiable de las fuentes disponibles")

    unchanged = [x.casefold() for x in top10] == [x.casefold() for x in previous]
    previous_keys = {term_key(x) for x in previous}
    new_entries = [x for x in top10 if term_key(x) not in previous_keys]
    valid = [n for n, d in source_data.items() if d.get("ok")]
    non_stale = [n for n, d in source_data.items() if d.get("ok") and d.get("freshness") != "stale"]
    fresh = [n for n, d in source_data.items() if d.get("ok") and d.get("freshness") == "fresh"]
    reliability = "high" if len(non_stale) >= 6 else ("medium" if len(non_stale) >= 3 else "fallback")
    ttittulares_status = load_json(TTITTULARES_STATUS, {})
    upcoming = build_upcoming(source_data, top10, previous_doc, ttittulares_status, now)
    anticipated = anticipated_entries(top10, previous_doc, now)

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
        "new_entries": new_entries,
        "upcoming": upcoming,
        "anticipated_entries": anticipated,
        "upcoming_method": "social-ranks-11-20 + TTiTTulares coverage",
        "sources": source_data,
    }
    RECENT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        f"TTendencias: {chosen_name} via {method}; valid={len(valid)}/{len(SOURCES)}, "
        f"non_stale={len(non_stale)}, fresh={len(fresh)}, reliability={reliability}; "
        f"Top 10: {', '.join(top10)}; upcoming={len(upcoming)}"
    )

if __name__ == "__main__":
    main()
