import json
import os
import re
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parent
RECENT = ROOT / "recent.json"
NOTIFIED = ROOT / "notified.json"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124 Safari/537.36",
    "Accept-Language": "es-ES,es;q=0.9,en;q=0.7",
    "Cache-Control": "no-cache",
}
SOURCES = {
    "trends24": "https://trends24.in/spain/",
    "getdaytrends": "https://getdaytrends.com/es/spain/",
    "tweets24": "https://tweets24.com/trending-on-twitter-in-spain",
}


def clean(text):
    return re.sub(r"\s+", " ", (text or "")).strip()


def unique(values):
    out, seen = [], set()
    for value in values:
        value = clean(value)
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
                name = clean(cells[1].get_text(" ", strip=True))
                if name:
                    rows.append(name)
        if len(rows) >= 10:
            return unique(rows)[:20]
    return []


def parse_tweets24(html):
    soup = BeautifulSoup(html, "html.parser")
    text = clean(soup.get_text(" ", strip=True))
    marker = "Live Twitter Trending Topics in Spain"
    if marker in text:
        text = text.split(marker, 1)[1]
    parts = re.split(r"\s+(?=\d{1,2}\s+)", text)
    vals = []
    for part in parts:
        m = re.match(r"(\d{1,2})\s+(.+?)(?:\s+Explore why|\s+##|$)", part)
        if m and 1 <= int(m.group(1)) <= 50:
            vals.append(clean(m.group(2)))
    return unique(vals)[:20]


def fetch_source(name):
    try:
        parser = {"trends24": parse_trends24, "getdaytrends": parse_getdaytrends, "tweets24": parse_tweets24}[name]
        trends = parser(get(SOURCES[name]))
        return {"ok": len(trends) >= 10, "trends": trends, "error": None}
    except Exception as e:
        return {"ok": False, "trends": [], "error": f"{type(e).__name__}: {e}"}


def previous_top10():
    try:
        return json.loads(RECENT.read_text(encoding="utf-8")).get("top10", [])
    except Exception:
        return []


def notified_top10():
    try:
        return json.loads(NOTIFIED.read_text(encoding="utf-8")).get("notified_top10", [])
    except Exception:
        return []


def send_alert(top10, new_names, now):
    token = os.getenv("TELEGRAM_BOT_TOKEN")
    chat_id = os.getenv("TELEGRAM_CHAT_ID")
    if not token or not chat_id:
        print("Aviso: faltan TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID; no se envía alerta.")
        return False
    rank = {name.casefold(): i + 1 for i, name in enumerate(top10)}
    lines = ["🔔 Nuevas tendencias detectadas:"]
    for name in new_names:
        lines.append(f"T{rank[name.casefold()]} · {name}")
    lines.append("\nSi quieres prepararlas, pulsa el botón o escribe: Ejecuta TT")
    payload = {
        "chat_id": chat_id,
        "text": "\n".join(lines),
        "disable_web_page_preview": True,
        "reply_markup": {
            "inline_keyboard": [[{"text": "▶️ Ejecutar TTendencias", "callback_data": "run:trends"}]]
        },
    }
    r = requests.post(f"https://api.telegram.org/bot{token}/sendMessage", json=payload, timeout=30)
    r.raise_for_status()
    result = r.json()
    if not result.get("ok"):
        raise RuntimeError(result)
    NOTIFIED.write_text(json.dumps({
        "notified_top10": top10,
        "notified_at": now.isoformat(timespec="seconds")
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Alerta Telegram enviada: {', '.join(new_names)}")
    return True


def main():
    now = datetime.now(ZoneInfo("Europe/Madrid"))
    previous = previous_top10()
    already_notified = notified_top10()
    primary = fetch_source("trends24")
    secondary = fetch_source("getdaytrends")
    chosen_name = "trends24" if primary["ok"] else "getdaytrends"
    chosen = primary if primary["ok"] else secondary
    third = None
    if not chosen["ok"]:
        third = fetch_source("tweets24")
        chosen_name, chosen = "tweets24", third
    top10 = chosen["trends"][:10]
    unchanged = [x.casefold() for x in top10] == [x.casefold() for x in previous]
    if unchanged and third is None:
        third = fetch_source("tweets24")
    if len(top10) < 10:
        raise RuntimeError("No se pudo obtener un Top 10 fiable de ninguna fuente")
    source_data = {"trends24": primary, "getdaytrends": secondary}
    if third is not None:
        source_data["tweets24"] = third
    payload = {
        "project": "TTendencias",
        "country": "ES",
        "captured_at": now.isoformat(timespec="seconds"),
        "primary_source": chosen_name,
        "top10": top10,
        "items": [{"rank": i + 1, "name": name} for i, name in enumerate(top10)],
        "unchanged_from_previous": unchanged,
        "sources": source_data,
    }
    RECENT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    notified_keys = {x.casefold() for x in already_notified}
    new_names = [x for x in top10 if x.casefold() not in notified_keys]
    if new_names:
        send_alert(top10, new_names, now)
    print(f"TTendencias: {chosen_name}; Top 10: {', '.join(top10)}")


if __name__ == "__main__":
    main()
