import json
import re
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import parse_qs, unquote, urlparse
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parent
RECENT = ROOT / "recent.json"
REQUESTS = ROOT / "requests.json"
TTITTULARES_STATUS = ROOT.parent / "ttittulares" / "status.json"
TTITTULARES_EVENTS = ROOT.parent / "telegram" / "events.json"
MADRID = ZoneInfo("Europe/Madrid")
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124 Safari/537.36",
    "Accept-Language": "es-ES,es;q=0.9,en;q=0.7",
    "Cache-Control": "no-cache",
    "Pragma": "no-cache",
}
SOURCES = {
    "trends24": "https://trends24.in/spain/index.html",
    "getdaytrends": "https://getdaytrends.com/es/spain/",
    "tweets24": "https://tweets24.com/trending-on-twitter-in-spain",
    "superx": "https://superx.so/twitter-trends/spain",
    "twtdata": "https://twtdata.com/twitter-trends/spain/",
    "snaplytics": "https://twitter-trends.snaplytics.io/spain/",
    "whatstrends": "https://whatstrends.com/spain/",
    "cyberkendra": "https://trends.cyberkendra.com/spain/",
    "xtrendsiamrohit": "https://xtrends.iamrohit.in/spain",
    "trendswe": "https://trendswe.com/twitter/spain/",
    "xtrendssaroj": "https://xtrends.sarojmeher.com/spain",
    # Additional independent public rankings. A source only influences the
    # radar if its parse succeeds and the existing freshness checks pass.
    "playersells": "https://playersells.com/es/tools/twitter-trends/spain",
    "fowtools": "https://fowtools.com/x-trends/spain",
}

def clean(text):
    return re.sub(r"\s+", " ", (text or "")).strip()

def clean_term(text):
    text = clean(text)
    text = re.sub(r"\s+N/?A$", "", text, flags=re.I)
    text = re.sub(r"\s+(?:Less than )?\d+(?:[.,]\d+)?[KMB]?\s+(?:tweets|posts)$", "", text, flags=re.I)
    text = re.sub(r"\s+(?:View posts on X|Open on X|Copy)$", "", text, flags=re.I)
    return text.strip()

def term_key(text):
    # Algunos agregadores anteponen # incluso a temas que no son hashtags.
    # Ignoramos un # inicial solo para comparar fuentes; conservamos el nombre
    # real de la fuente elegida para mostrarlo.
    folded = unicodedata.normalize("NFD", clean_term(text).casefold().lstrip("#"))
    return "".join(ch for ch in folded if unicodedata.category(ch) != "Mn")

def unique(values):
    out, seen = [], set()
    for value in values:
        value = clean_term(value)
        key = term_key(value)
        if not value or key in seen or len(value) > 100:
            continue
        seen.add(key)
        out.append(value)
    return out

def get(url):
    # No añadir parámetros artificiales a URLs de terceros: varias fuentes
    # rechazan ?_=timestamp con 403/404 aunque la URL canónica funcione.
    r = requests.get(url, headers=HEADERS, timeout=30)
    r.raise_for_status()
    return r.content.decode("utf-8", errors="replace")

def parse_trends24(html):
    soup = BeautifulSoup(html, "html.parser")
    for selector in (".trend-card__list li a", ".trend-card li a", ".trend-card ol li a"):
        vals = unique(a.get_text(" ", strip=True) for a in soup.select(selector))
        if len(vals) >= 10:
            return vals[:50]
    card = soup.select_one(".trend-card")
    if card:
        vals = unique(a.get_text(" ", strip=True) for a in card.find_all("a"))
        if len(vals) >= 10:
            return vals[:50]
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
            return unique(rows)[:50]
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
        return unique(name for _, name in ranked)[:50]

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
    return unique(name for _, name in vals)[:50]


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
            return vals[:50]
    vals = unique(fallback)
    return vals[:50] if len(vals) >= 10 else []


def parse_superx(html):
    return parse_x_search_links(html)


def parse_playersells(html):
    # Public, ordered X-search links, then ordinary ranked tables as fallback.
    # Do not infer a ranking from unnumbered recommendation/sidebar links.
    names = parse_x_search_links(html)
    return names if len(names) >= 10 else parse_generic_ranked(html)


def parse_fowtools(html):
    # The Spain page presents a 50-row "# | Trend | Type | Actions" table.
    # Keep its observed ordering; never synthesize missing ranks or keywords.
    names = parse_ranked_table(html)
    return names if len(names) >= 10 else parse_x_search_links(html)


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
    return unique(name for _, name in rows)[:50]


def page_update_hint(html):
    soup = BeautifulSoup(html, "html.parser")
    text = clean(soup.get_text(" ", strip=True))
    patterns = [
        # Preferir marcas temporales explícitas antes que textos genéricos
        # del tipo "updated hourly", que no permiten calcular frescura.
        r"(Trending now\s+[A-Z][a-z]{2}\s+\d{1,2},\s+\d{4}\s+\d{1,2}:\d{2}\s+UTC)",
        r"(updated\s+\d+\s+(?:minutes?|hours?)\s+ago)",
        r"(Actualizado\s+hace\s+\d+\s+(?:minutos?|horas?))",
        r"(Updated\s*:\s*[A-Z][a-z]+\s+\d{1,2},\s+\d{4}\s+at\s+\d{1,2}:\d{2}\s+[AP]M)",
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
    spanish_age = re.search(r"Actualizado\s+hace\s+(\d+)\s+(minutos?|horas?)", hint, flags=re.I)
    if spanish_age:
        n = int(spanish_age.group(1))
        return float(n if spanish_age.group(2).lower().startswith("minut") else n * 60)

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
            rank_match = re.match(r"^(\d{1,3})[.)]?$", first)
            if not rank_match:
                continue
            rank = int(rank_match.group(1))
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
    return unique(name for _, name in rows)[:50]

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
    return unique(name for _, name in vals)[:50]

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
    for item in trends[:50]:
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
            "playersells": parse_playersells,
            "fowtools": parse_fowtools,
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

def reconcile_source_freshness(source_data, previous_doc, now):
    """Detect stale relative timestamps and corroborated live changes.

    Some aggregators repeatedly serve the identical list with the same
    'updated N minutes ago' label. A new fetch must not reset that age.
    Conversely, an un-timestamped provider that changes between captures
    can be used if an independent, dated source corroborates its list.
    """
    previous_sources = previous_doc.get("sources") or {}
    now_iso = now.isoformat(timespec="seconds")

    def elapsed_minutes(value):
        try:
            dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=MADRID)
            return max(0.0, (now - dt.astimezone(MADRID)).total_seconds() / 60)
        except (TypeError, ValueError):
            return float("inf")

    for name, row in source_data.items():
        if not row.get("ok"):
            continue
        prior = previous_sources.get(name) or {}
        same_list = bool(
            prior.get("ok")
            and [term_key(x) for x in (row.get("trends") or [])[:30]]
            == [term_key(x) for x in (prior.get("trends") or [])[:30]]
        )
        last_change = (
            prior.get("last_list_change_at") or previous_doc.get("captured_at")
            if same_list else now_iso
        )
        row["last_list_change_at"] = last_change
        row["list_unchanged_minutes"] = round(elapsed_minutes(last_change), 1)

        # A relative timestamp should advance when nothing is refreshed.
        # A frozen timestamp AND unchanged ranking across a whole refresh
        # cycle (>=10 min) makes the claimed freshness unreliable. A freshly
        # downloaded HTML page is not proof that its source ranking is fresh.
        hint = str(row.get("update_hint") or "")
        same_relative_hint = bool(
            same_list and prior.get("update_hint") == hint
            and re.search(r"\b\d+\s+(?:minutes?|hours?)\s+ago\b", hint, flags=re.I)
        )
        hint_since = (
            prior.get("relative_hint_unchanged_since") or previous_doc.get("captured_at")
            if same_relative_hint else now_iso
        )
        row["relative_hint_unchanged_since"] = hint_since
        if same_relative_hint and elapsed_minutes(hint_since) >= 10:
            if row.get("freshness") == "fresh":
                row["freshness"] = "stale"
                row["freshness_note"] = "frozen-relative-update-label"

    # A live, changing, undated snapshot may be treated as corroborated
    # only if it agrees with a separate source that has a known age <=90m.
    for name, row in source_data.items():
        if not row.get("ok") or row.get("freshness") != "unknown":
            continue
        prior = previous_sources.get(name) or {}
        if not prior.get("ok") or row.get("list_unchanged_minutes", 9999) > 20:
            continue
        # The first continuity-aware run may only know the preceding
        # capture time as last change. Accept that recent evidence for the
        # visual radar if a dated independent feed agrees. Sources older
        # than 90m can corroborate only the display, never auto-editorial.
        peers = [
            other_name for other_name, other in source_data.items()
            if other_name != name and other.get("ok")
            and (
                other.get("freshness") in {"fresh", "aging"}
                or (
                    other.get("age_minutes") is not None
                    and float(other["age_minutes"]) <= 120
                )
            )
            and overlap(row.get("trends") or [], other.get("trends") or []) >= 0.25
        ]
        if peers:
            row["freshness"] = "corroborated-change"
            row["corroborating_sources"] = peers


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
        for idx, term in enumerate(trends[:50], 1):
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

    def corroboration(item, pool):
        name, data = item
        # Anti-echo: two heavily overlapping aggregators must not drown out
        # independent, current observations from several other providers.
        # Cap each peer's contribution; breadth of corroboration matters more
        # than one nearly duplicated ranked list. Preserve raw overlaps for
        # the supporter threshold and the remaining selection safeguards.
        return sum(
            min(0.30, overlap(data["trends"], other["trends"]))
            for oname, other in pool.items()
            if oname != name
        )

    # No votar con snapshots caducados: aunque el HTML se descargue hoy,
    # una lista marcada stale puede coincidir con una fuente retrasada y
    # desbancar a dos fuentes actuales que sí se corroboran entre ellas.
    non_stale = {n: d for n, d in good.items() if d.get("freshness") != "stale"}
    fresh = {n: d for n, d in good.items() if d.get("freshness") in {"fresh", "corroborated-change"}}
    if fresh:
        # Preferir una fuente fresca corroborada por otras NO obsoletas.
        # En empate, elegir el snapshot con menor antigüedad comprobable.
        anchor_name, anchor = max(
            fresh.items(),
            key=lambda item: (
                corroboration(item, non_stale),
                -float(item[1].get("age_minutes") if item[1].get("age_minutes") is not None else 9999),
            ),
        )
        # A timestamped hourly snapshot can be 46-90 min old while several
        # independent live aggregators have already converged on its topics.
        # Override a single fresh, echoed source only with a CLEAR and broad
        # corroboration advantage. This avoids switching away from a valid
        # fresh anchor merely because one aging provider has one close mirror.
        aging_candidates = {n: d for n, d in good.items() if d.get("freshness") == "aging"}
        if aging_candidates:
            aged_name, aged = max(
                aging_candidates.items(),
                key=lambda item: (
                    corroboration(item, non_stale),
                    -float(item[1].get("age_minutes") if item[1].get("age_minutes") is not None else 9999),
                ),
            )
            aged_support = corroboration((aged_name, aged), non_stale)
            fresh_support = corroboration((anchor_name, anchor), non_stale)
            independent_supporters = [
                name for name, data in non_stale.items()
                if name != aged_name
                and overlap(aged["trends"], data["trends"]) >= 0.15
            ]
            if aged_support >= fresh_support + 0.15 and len(independent_supporters) >= 3:
                return (
                    aged["trends"][:10],
                    [aged_name] + independent_supporters,
                    aged_name,
                    "aging-anchor",
                )
        supporters = [
            name for name, data in good.items()
            if name == anchor_name
            or (
                data.get("freshness") != "stale"
                and overlap(anchor["trends"], data["trends"]) >= 0.35
            )
        ]
        return anchor["trends"][:10], supporters, anchor_name, ("corroborated-anchor" if anchor.get("freshness") == "corroborated-change" else "fresh-anchor")

    aging = {n: d for n, d in good.items() if d.get("freshness") == "aging"}
    if aging:
        # Si no hay fuente fresca, una fuente con hora conocida y <=90 min
        # es preferible a una fuente sin marca temporal que podría estar cacheada.
        anchor_name, anchor = max(
            aging.items(),
            key=lambda item: (
                corroboration(item, non_stale),
                -float(item[1].get("age_minutes") if item[1].get("age_minutes") is not None else 9999),
            ),
        )
        supporters = [
            name for name, data in good.items()
            if name == anchor_name
            or (
                data.get("freshness") != "stale"
                and overlap(anchor["trends"], data["trends"]) >= 0.35
            )
        ]
        return anchor["trends"][:10], supporters, anchor_name, "aging-anchor"

    unknown = {n: d for n, d in good.items() if d.get("freshness") == "unknown"}
    corroborated_unknown = {
        name: data
        for name, data in unknown.items()
        if any(
            oname != name and overlap(data["trends"], other["trends"]) >= 0.35
            for oname, other in unknown.items()
        )
    }
    if len(corroborated_unknown) >= 2:
        return (
            consensus_fallback({n: d["trends"] for n, d in corroborated_unknown.items()}),
            list(corroborated_unknown),
            "consensus",
            "consensus",
        )

    # Nunca sustituir un Top 10 válido por una única fuente sin fecha.
    # Si las fuentes actuales no se corroboran, conservamos el último Top 10
    # y esperamos al siguiente barrido en vez de reintroducir tendencias viejas.
    previous = previous_top10()
    if len(previous) >= 10:
        return previous[:10], [], "previous", "hold-last-good"

    # Arranque en frío: si no existe snapshot previo, usamos la fuente obsoleta
    # menos antigua solo como visualización. auto_queue_new.py impide encolarla.
    stale = [
        (name, data)
        for name, data in good.items()
        if data.get("freshness") == "stale" and data.get("age_minutes") is not None
    ]
    if stale:
        name, data = min(stale, key=lambda item: float(item[1].get("age_minutes") or 9999))
        return data["trends"][:10], [name], name, "stale-fallback"

    return [], [], "none", "none"


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

def best_news_signal(term, status_doc, full_events):
    best = None
    for event_id, event in (status_doc.get("events") or {}).items():
        if str(event.get("status") or "") == "DISMISSED":
            continue
        if not term_matches_title(term, event.get("title")):
            continue
        full_event = full_events.get(str(event_id), {})
        first_seen = full_event.get("first_seen")
        if not first_seen:
            seen_values = [a.get("first_seen") for a in (full_event.get("appearances") or []) if a.get("first_seen")]
            first_seen = min(seen_values) if seen_values else None
        row = {
            "event_id": event_id,
            "title": str(event.get("title") or ""),
            "source_count": int(event.get("source_count") or 0),
            "status": str(event.get("status") or ""),
            "first_seen": first_seen,
            "last_seen": event.get("last_seen"),
        }
        if best is None or row["source_count"] > best["source_count"]:
            best = row
    return best

def lower_rank_stats(source_data, top30):
    # El radar de anticipación excluye TODOS los puestos del Top 30 visible.
    top_keys = {term_key(x) for x in top30}
    stats = {}
    for source, data in source_data.items():
        if not data.get("ok") or data.get("freshness") in {"stale", "invalid", "error"}:
            continue
        for rank, term in enumerate((data.get("trends") or [])[:50], 1):
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

def build_upcoming(source_data, top30, previous_doc, status_doc, full_events, now):
    """Radar de señales fuera del Top 30 con continuidad entre capturas.

    upcoming es una *vista filtrada*, no un historial. Conservar exclusivamente
    esa vista hacía que cualquier señal estable, al desaparecer de la vista,
    regresara falsamente como 'new' y con una sola observación.
    """
    stats = lower_rank_stats(source_data, top30)
    now_iso = now.isoformat(timespec="seconds")
    expiry = now - timedelta(hours=72)
    previous_radar = previous_doc.get("radar_history") or {}
    previous_upcoming = {
        term_key(x.get("name")): x
        for x in (previous_doc.get("upcoming") or [])
        if x.get("name")
    }
    history = {}

    def recently_seen(item):
        raw = item.get("last_seen_at") or item.get("captured_at") or previous_doc.get("captured_at")
        try:
            dt = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=MADRID)
            return dt >= expiry
        except (TypeError, ValueError):
            return False

    for key, item in previous_radar.items():
        if isinstance(item, dict) and recently_seen(item):
            history[key] = dict(item)

    # Migración sin pérdida desde la vista anterior a la persistencia nueva.
    for key, item in previous_upcoming.items():
        if key not in history:
            history[key] = {
                "name": item["name"],
                "best_observed_rank": item.get("best_observed_rank"),
                "social_source_count": item.get("social_source_count"),
                "rank_history": item.get("rank_history") or [],
                "first_detected_at": item.get("first_detected_at"),
                "last_seen_at": previous_doc.get("captured_at") or now_iso,
                "inside_top30": False,
                "radar_qualified": True,
            }

    # Un tema que estaba en el Top 30 en la captura anterior no puede
    # llamarse 'nuevo' al salir del Top 30 por un cambio de fuente ancla.
    for name in (previous_doc.get("top30") or []):
        key = term_key(name)
        if key and key not in history:
            history[key] = {
                "name": name,
                "inside_top30": True,
                "last_seen_at": previous_doc.get("captured_at") or now_iso,
            }

    for name in top30:
        key = term_key(name)
        if not key:
            continue
        item = dict(history.get(key) or {})
        item.update(name=name, inside_top30=True, last_seen_at=now_iso)
        history[key] = item

    rows = []
    for key, row in stats.items():
        news = best_news_signal(row["name"], status_doc, full_events)
        news_count = int((news or {}).get("source_count") or 0)
        social_count = int(row["social_source_count"])
        prev = history.get(key)
        previously_in_top30 = bool((prev or {}).get("inside_top30"))
        previous_rank = int((prev or {}).get("best_observed_rank") or 999)
        previous_support = int((prev or {}).get("social_source_count") or 0)
        previous_history = list((prev or {}).get("rank_history") or [])
        current_observation = {
            "captured_at": now_iso,
            "best_rank": int(row["best_observed_rank"]),
            "source_count": social_count,
        }
        rank_history = (previous_history + [current_observation])[-8:]

        if previously_in_top30:
            movement = "down"
        elif prev is None:
            movement = "new"
        elif row["best_observed_rank"] < previous_rank or social_count > previous_support:
            movement = "up"
        elif row["best_observed_rank"] > previous_rank or social_count < previous_support:
            movement = "down"
        else:
            movement = "flat"

        first_detected = (prev or {}).get("first_detected_at") or now_iso
        history[key] = {
            "name": row["name"],
            "best_observed_rank": int(row["best_observed_rank"]),
            "social_source_count": social_count,
            "rank_history": rank_history,
            "first_detected_at": first_detected,
            "last_seen_at": now_iso,
            "inside_top30": False,
            "radar_qualified": (social_count >= 2 or (social_count >= 1 and news_count >= 4)),
        }

        if social_count < 2 and not (social_count >= 1 and news_count >= 4):
            continue

        # Una señal estable o descendente NO debe renacer como 'new' tras
        # desaparecer temporalmente de upcoming, que es solo una vista.
        if movement not in {"new", "up"}:
            continue

        score = (
            social_count * 20
            + max(0, 51 - int(row["best_observed_rank"])) * 2
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
            "rank_history": rank_history,
            "observations": len(rank_history),
            "first_detected_at": first_detected,
            "news_source_count": news_count,
            "news_event_id": (news or {}).get("event_id"),
            "news_title": (news or {}).get("title"),
            "news_status": (news or {}).get("status"),
            "news_first_seen": (news or {}).get("first_seen"),
            "_score": score,
        })

    rows.sort(key=lambda x: (-x["_score"], -x["social_source_count"], x["best_observed_rank"], x["name"].casefold()))
    for row in rows:
        row.pop("_score", None)
    # Estado acotado: tres días de observaciones y como máximo 300 señales.
    trimmed_history = dict(
        sorted(history.items(), key=lambda item: item[1].get("last_seen_at") or "", reverse=True)[:300]
    )
    return rows[:20], trimmed_history

def filter_dismissed_upcoming(rows, requests_doc):
    """No resucitar en Radar una señal que el usuario acaba de desestimar.

    Solo se permite que vuelva si la noticia asociada apareció al menos 10
    minutos después del último descarte; de ese modo un hecho realmente nuevo
    puede volver al Radar, pero una noticia antigua no reaparece en cada
    refresco.
    """
    latest = {}
    for req in requests_doc.get("requests", []) or []:
        name = req.get("name")
        if name:
            latest[term_key(name)] = req

    kept = []
    for row in rows:
        req = latest.get(term_key(row.get("name")))
        if str((req or {}).get("status") or "") != "dismissed":
            kept.append(row)
            continue

        closed_raw = (req or {}).get("dismissed_at") or (req or {}).get("explained_at")
        first_raw = row.get("news_first_seen")
        if not closed_raw or not first_raw:
            continue
        try:
            closed = datetime.fromisoformat(str(closed_raw).replace("Z", "+00:00"))
            first = datetime.fromisoformat(str(first_raw).replace("Z", "+00:00"))
            if closed.tzinfo is None:
                closed = closed.replace(tzinfo=timezone.utc)
            if first.tzinfo is None:
                first = first.replace(tzinfo=timezone.utc)
            if (first - closed).total_seconds() > 10 * 60:
                kept.append(row)
        except Exception:
            # Ante fechas no parseables, prevalece el descarte del usuario.
            continue
    return kept

def anticipated_entries(top10, previous_doc, now):
    previous_top10 = {term_key(x) for x in (previous_doc.get("top10") or [])}
    previous_top30 = {term_key(x) for x in (previous_doc.get("top30") or [])}
    prior = {
        term_key(x.get("name")): x
        for x in (previous_doc.get("upcoming") or []) if x.get("name")
    }
    # La vista upcoming solo incluye 'new'/'up', de modo que una señal puede
    # desaparecer de esa vista antes de entrar en el Top 10. Su historial
    # cualificado permite reconocer una anticipación real sin inventarla.
    for key, row in (previous_doc.get("radar_history") or {}).items():
        if (isinstance(row, dict) and row.get("radar_qualified")
                and not row.get("inside_top30")):
            prior.setdefault(key, row)
    out = []
    for name in top10:
        key = term_key(name)
        if key in previous_top10 or key in previous_top30:
            continue
        row = prior.get(key)
        if not row:
            continue
        detected = row.get("first_detected_at")
        lead = None
        try:
            start = datetime.fromisoformat(str(detected).replace("Z", "+00:00"))
            if start.tzinfo is None:
                start = start.replace(tzinfo=MADRID)
            lead = max(0, round((now - start.astimezone(MADRID)).total_seconds() / 60))
        except (TypeError, ValueError):
            pass
        out.append({
            "name": name,
            "first_detected_at": detected,
            "entered_top10_at": now.isoformat(timespec="seconds"),
            "lead_minutes": lead,
        })
    return out

def fetch_sources(fetcher=None):
    # Four bounded workers; the same public sources, timeout and request count.
    # map preserves source order so completion timing cannot change tie-breaks.
    with ThreadPoolExecutor(max_workers=4) as pool:
        return dict(zip(SOURCES, pool.map(fetcher or fetch_source, SOURCES)))


def main():
    now = datetime.now(MADRID)
    previous_doc = load_json(RECENT, {})
    previous = previous_doc.get("top10", [])
    source_data = fetch_sources()
    reconcile_source_freshness(source_data, previous_doc, now)

    top10, sources_used, chosen_name, method = choose_top10(source_data)
    if len(top10) < 10:
        raise RuntimeError("No se pudo obtener un Top 10 fiable de las fuentes disponibles")

    # A trusted previous Top-10 may stay unchanged after an hourly dated
    # provider crosses 90m. Keep automatic INVESTIGATION moving for up to
    # 60m after the actual source last changed, but only when its names still
    # overlap a separately timestamped independent source. Never treat an
    # unrelated, frozen relative-time page as supporting evidence.
    if method == "hold-last-good":
        current_keys = {term_key(x) for x in top10}
        continuity = []
        for source_name, row in source_data.items():
            ranked = row.get("trends") or []
            if not row.get("ok") or len(ranked) < 10:
                continue
            agreeing = len(current_keys & {term_key(x) for x in ranked[:20]})
            try:
                unchanged_minutes = float(row.get("list_unchanged_minutes", 9999))
            except (TypeError, ValueError):
                unchanged_minutes = 9999
            if agreeing < 8 or unchanged_minutes > 60:
                continue
            peers = [
                peer_name for peer_name, peer in source_data.items()
                if peer_name != source_name and peer.get("ok")
                and peer.get("age_minutes") is not None
                and 0 <= float(peer["age_minutes"]) <= 150
                and overlap(ranked, peer.get("trends") or []) >= 0.20
            ]
            if peers:
                continuity.append((agreeing, -unchanged_minutes, source_name, peers))
        if continuity:
            continuity.sort(reverse=True)
            _, _, chosen_name, peers = continuity[0]
            method = "continuity-anchor"
            sources_used = [chosen_name] + peers
            source_data[chosen_name]["continuity_verified"] = True
            source_data[chosen_name]["continuity_peers"] = peers

    # Mostrar un Top 30, pero conservar top10 como única entrada a la
    # cola editorial automática. Los puestos 11-30 son opt-in.
    top30 = list(top10)
    seen_top30 = {term_key(x) for x in top30}
    def extend_ranked(names):
        for name in names:
            if len(top30) >= 30:
                break
            key = term_key(name)
            if key and key not in seen_top30:
                top30.append(name)
                seen_top30.add(key)
    # Mantener la fuente elegida como referencia para las posiciones,
    # sin presentar las señales de otras fuentes como posiciones verificadas.
    primary_ranked = (source_data.get(chosen_name) or {}).get("trends") or []
    # In hold-last-good the anchor name is "previous": there is no provider
    # called "previous". Preserve the real 1-10 ranking and complete 11-30
    # from an actual source that currently repeats at least 6 of those ten
    # names. Do not confuse unavailable anchor metadata with absent trends.
    if not primary_ranked:
        current_keys = {term_key(name) for name in top10}
        aligned = []
        for source_name, source_row in source_data.items():
            source_terms = source_row.get("trends") or []
            if not source_row.get("ok") or len(source_terms) < 30:
                continue
            aligned_count = len(current_keys & {term_key(name) for name in source_terms[:20]})
            if aligned_count < 6:
                continue
            aligned.append((aligned_count, source_name, source_row))
        if aligned:
            aligned.sort(key=lambda entry: (
                -entry[0],
                -int(entry[2].get("freshness") in {"fresh", "aging", "corroborated-change"}),
                float(entry[2].get("age_minutes") if entry[2].get("age_minutes") is not None else 9999),
            ))
            primary_ranked = aligned[0][2]["trends"]
            print("Top 30: puestos 11-30 observados en", aligned[0][1],
                  "con", aligned[0][0], "coincidencias actuales de Top 10")
    extend_ranked(primary_ranked[:30])
    if len(top30) < 30:
        # Prefer related, dated secondary snapshots. A disconnected
        # never-updating undated feed must not fill the remaining places.
        secondary = []
        for name, data in source_data.items():
            if name == chosen_name or not data.get("ok"):
                continue
            agreement = overlap(primary_ranked, data.get("trends") or [])
            age = data.get("age_minutes")
            dated_recent = age is not None and float(age) <= 120
            if agreement < 0.20:
                continue
            if data.get("freshness") == "stale" and not dated_recent:
                continue
            secondary.append((name, data, agreement))
        secondary.sort(key=lambda row: (
            -row[2],
            row[1].get("age_minutes") is None,
            float(row[1].get("age_minutes") or 9999),
        ))
        for name, data, _ in secondary:
            extend_ranked((data.get("trends") or [])[:50])
            if len(top30) >= 30:
                break
    # Si el radar no alcanza 30 entradas fiables, mostrar las observadas;
    # nunca fabricar nombres ni puestos para rellenar.

    unchanged = [term_key(x) for x in top10] == [term_key(x) for x in previous]
    previous_keys = {term_key(x) for x in previous}
    previous_rank_by_key = {term_key(name): i + 1 for i, name in enumerate(previous)}
    new_entries = [x for x in top10 if term_key(x) not in previous_keys]
    previous_items = {
        term_key(x.get("name")): x
        for x in (previous_doc.get("items") or [])
        if x.get("name")
    }
    requests_doc = load_json(REQUESTS, {"requests": []})
    request_history = {}
    for req in requests_doc.get("requests", []) or []:
        name = req.get("name")
        if name:
            request_history.setdefault(term_key(name), []).append(req)

    def entered_top10_at(name):
        key = term_key(name)
        if key not in previous_keys:
            return now.isoformat(timespec="seconds")
        prev = previous_items.get(key) or {}
        if prev.get("entered_top10_at"):
            return prev["entered_top10_at"]
        candidates = [r for r in request_history.get(key, []) if r.get("requested_at")]
        if candidates:
            candidates.sort(key=lambda r: str(r.get("requested_at") or ""), reverse=True)
            return candidates[0]["requested_at"]
        return previous_doc.get("captured_at") or now.isoformat(timespec="seconds")

    def top10_movement(name, current_rank):
        previous_rank = previous_rank_by_key.get(term_key(name))
        if previous_rank is None:
            return "new", None, None
        if current_rank < previous_rank:
            movement = "up"
        elif current_rank > previous_rank:
            movement = "down"
        else:
            movement = "flat"
        return movement, previous_rank, previous_rank - current_rank

    valid = [n for n, d in source_data.items() if d.get("ok")]
    non_stale = [n for n, d in source_data.items() if d.get("ok") and d.get("freshness") != "stale"]
    fresh = [n for n, d in source_data.items() if d.get("ok") and d.get("freshness") == "fresh"]
    reliability = "high" if len(non_stale) >= 6 else ("medium" if len(non_stale) >= 3 else "fallback")
    ttittulares_status = load_json(TTITTULARES_STATUS, {})
    ttittulares_events_doc = load_json(TTITTULARES_EVENTS, {})
    ttittulares_events = {str(x.get("id")): x for x in (ttittulares_events_doc.get("events") or []) if x.get("id")}
    upcoming, radar_history = build_upcoming(source_data, top30, previous_doc, ttittulares_status, ttittulares_events, now)
    upcoming = filter_dismissed_upcoming(upcoming, requests_doc)
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
        "top30": top30,
        "items": [
            {
                "rank": i + 1,
                "name": name,
                "entered_top10_at": entered_top10_at(name),
                "movement": top10_movement(name, i + 1)[0],
                "previous_rank": top10_movement(name, i + 1)[1],
                "rank_delta": top10_movement(name, i + 1)[2],
            }
            for i, name in enumerate(top30)
        ],
        "unchanged_from_previous": unchanged,
        "new_entries": new_entries,
        "upcoming": upcoming,
        "radar_history": radar_history,
        "anticipated_entries": anticipated,
        "upcoming_method": "outside-top30 + confirmed-social-support + rising-or-new",
        "sources": source_data,
    }
    RECENT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        f"TTendencias: {chosen_name} via {method}; valid={len(valid)}/{len(SOURCES)}, "
        f"non_stale={len(non_stale)}, fresh={len(fresh)}, reliability={reliability}; "
        f"Top 30: {', '.join(top30)}; top10 editoriales={len(top10)}; upcoming={len(upcoming)}"
    )

if __name__ == "__main__":
    main()
