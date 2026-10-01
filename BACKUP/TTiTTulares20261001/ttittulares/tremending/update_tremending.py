#!/usr/bin/env python3
"""Accumulative Público/Tremending collector for the TTiTTulares inbox."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable
from urllib.parse import urljoin, urlparse, urlunparse

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parents[2]
STATE_PATH = ROOT / "ttittulares" / "tremending" / "items.json"
BASE_URL = "https://www.publico.es/tremending"
USER_AGENT = "TTiTTulares-Tremending/1.0 (+https://github.com/fabricelop/europapress-rss)"
STATUS_RE = re.compile(r"https?://(?:www\.)?(?:x|twitter)\.com/([^/?#]+)/status/(\d+)", re.I)
CAPTURE_FROM_DEFAULT = "2026-09-29T22:00:00Z"  # frontera UTC equivalente
CAPTURE_LOCAL_DATE_DEFAULT = "2026-09-30"  # fecha visible de Público en Europe/Madrid


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except Exception:
        return None


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def canonical_article_url(raw: str) -> str:
    parsed = urlparse(urljoin(BASE_URL + "/", str(raw or "").strip()))
    if parsed.scheme not in {"http", "https"} or parsed.netloc.lower() not in {"publico.es", "www.publico.es"}:
        return ""
    path = re.sub(r"/{2,}", "/", parsed.path).rstrip("/")
    if not path.startswith("/tremending/") or not path.endswith(".html"):
        return ""
    return urlunparse(("https", "www.publico.es", path, "", "", ""))


def entry_id(url: str) -> str:
    return "tremending-" + hashlib.sha256(canonical_article_url(url).encode("utf-8")).hexdigest()[:16]


def canonical_tweet(raw: str) -> dict | None:
    match = STATUS_RE.search(str(raw or ""))
    if not match:
        return None
    user, tweet_id = match.group(1), match.group(2)
    return {
        "id": tweet_id,
        "author": "@" + user,
        "url": f"https://x.com/{user}/status/{tweet_id}",
        "embed_url": f"https://platform.twitter.com/embed/Tweet.html?id={tweet_id}&dnt=true",
    }


def extract_listing(html: str) -> list[dict]:
    soup = BeautifulSoup(html, "html.parser")
    found: dict[str, dict] = {}
    for link in soup.select("a[href]"):
        url = canonical_article_url(link.get("href", ""))
        if not url:
            continue
        title = " ".join(link.get_text(" ", strip=True).split())
        if len(title) < 12:
            title = " ".join(str(link.get("title") or "").split())
        if len(title) < 12:
            heading = link.find_parent(["h1", "h2", "h3", "h4"])
            title = " ".join(heading.get_text(" ", strip=True).split()) if heading else ""
        current = found.get(url)
        if current is None or len(title) > len(current.get("title", "")):
            found[url] = {"url": url, "title": title}
    return list(found.values())


def _body_candidates(soup: BeautifulSoup) -> Iterable:
    # Prefer the first specific selector that exists. Broadening to <article>
    # after finding articleBody could pull in an aside and turn unrelated embeds
    # into false candidates.
    selectors = ["[itemprop='articleBody']", "article .article-body", "article .article__body", "article .content-body"]
    for selector in selectors:
        nodes = soup.select(selector)
        if nodes:
            yield from nodes
            return
    node = soup.select_one("article") or soup.select_one("main")
    if node:
        yield node


def extract_article(html: str, url: str) -> dict:
    soup = BeautifulSoup(html, "html.parser")
    title_node = soup.select_one("meta[property='og:title']")
    title = str(title_node.get("content") or "").strip() if title_node else ""
    if not title and soup.title:
        title = soup.title.get_text(" ", strip=True).split(" | ")[0]
    published_node = soup.select_one("meta[property='article:published_time'], meta[name='date'], time[datetime]")
    published_at = ""
    if published_node:
        published_at = str(published_node.get("content") or published_node.get("datetime") or "").strip()

    # Público uses official blockquote.twitter-tweet embeds in the article body.
    # Limiting candidates to a body node prevents related/recommended modules
    # from being presented to the editor as if they belonged to the article.
    best: list[dict] = []
    for node in _body_candidates(soup):
        candidates: dict[str, dict] = {}
        for block in node.select("blockquote.twitter-tweet"):
            if block.find_parent(["aside", "nav", "footer"]):
                continue
            for link in block.select("a[href]"):
                tweet = canonical_tweet(link.get("href", ""))
                if tweet:
                    candidates.setdefault(tweet["id"], tweet)
        if len(candidates) > len(best):
            best = list(candidates.values())
    if not best:
        candidates = {}
        for block in soup.select("blockquote.twitter-tweet"):
            tweet = canonical_tweet(str(block))
            if tweet:
                candidates.setdefault(tweet["id"], tweet)
        best = list(candidates.values())

    description_node = soup.select_one("meta[property='og:description'], meta[name='description']")
    description = str(description_node.get("content") or "").strip() if description_node else ""
    return {
        "title": title,
        "description": description,
        "published_at": published_at or None,
        "tweets": best,
        "tweet_count": len(best),
        "url": canonical_article_url(url),
    }


def default_state() -> dict:
    return {
        "project": "TTiTTulares",
        "source": "Público · Tremending",
        "version": 1,
        "updated_at": None,
        "scan": {"last_run_at": None, "last_success_at": None, "recent_pages": 8, "recovery_page": None, "capture_from": CAPTURE_FROM_DEFAULT, "capture_local_date": CAPTURE_LOCAL_DATE_DEFAULT, "last_error": None},
        "items": [],
    }


def load_state(path: Path) -> dict:
    if not path.exists():
        return default_state()
    state = json.loads(path.read_text(encoding="utf-8"))
    base = default_state()
    base.update(state if isinstance(state, dict) else {})
    base["scan"] = {**default_state()["scan"], **(base.get("scan") or {})}
    base["items"] = list(base.get("items") or [])
    return base


def listing_url(page: int) -> str:
    return BASE_URL if page <= 1 else f"{BASE_URL}/{page}"


def fetch(session: requests.Session, url: str) -> str:
    response = session.get(url, timeout=35, headers={"User-Agent": USER_AGENT, "Accept-Language": "es-ES,es;q=0.9"})
    response.raise_for_status()
    response.encoding = "utf-8"
    return response.text


def merge_listing_item(existing: dict | None, candidate: dict, seen_at: str) -> dict:
    item = dict(existing or {})
    item.setdefault("id", entry_id(candidate["url"]))
    item["url"] = canonical_article_url(candidate["url"])
    if candidate.get("title") and (not item.get("title") or len(candidate["title"]) > len(item.get("title", ""))):
        item["title"] = candidate["title"]
    item.setdefault("first_seen_at", seen_at)
    item["last_seen_at"] = seen_at
    item.setdefault("status", "pending")
    item.setdefault("destinations", [])
    item.setdefault("tweets", [])
    item.setdefault("selected_tweet_id", None)
    item.setdefault("selected_tweet_url", None)
    item.setdefault("image", {"status": "not_selected"})
    return item


def update_state(state: dict, session: requests.Session, recent_pages: int, max_articles: int) -> dict:
    stamp = now_iso()
    scan = state.setdefault("scan", {})
    capture_from = str(scan.get("capture_from") or CAPTURE_FROM_DEFAULT)
    capture_from_changed = scan.get("capture_from") != capture_from
    scan["capture_from"] = capture_from
    cutoff = parse_iso(capture_from)
    capture_local_date = str(scan.get("capture_local_date") or CAPTURE_LOCAL_DATE_DEFAULT)
    scan["capture_local_date"] = capture_local_date
    if cutoff is None:
        raise ValueError(f"capture_from inválido: {capture_from}")

    # Desde la activación controlada del 30/09/2026 solo se incorporan artículos
    # publicados a partir de la frontera indicada. Las URLs históricas ya vistas
    # se conservan como conocidas, pero una URL nueva no se marca como vista hasta
    # haber sido incorporada o confirmada explícitamente como anterior al corte.
    seen_urls = set(scan.get("seen_urls") or [])
    pages = list(range(1, recent_pages + 1))
    by_url = {
        canonical_article_url(item.get("url", "")): item
        for item in state.get("items", [])
        if canonical_article_url(item.get("url", ""))
    }
    discovered: list[str] = []
    observed_urls: set[str] = set()
    newly_seen: set[str] = set()
    page_errors: list[str] = []
    candidate_errors: list[str] = []
    evaluated = 0
    filtered_before_cutoff = 0

    for page in pages:
        try:
            rows = extract_listing(fetch(session, listing_url(page)))
            if not rows:
                page_errors.append(f"página {page}: sin entradas")
                continue
            for row in rows:
                url = row["url"]
                if url in observed_urls:
                    continue
                observed_urls.add(url)

                # Decisiones editoriales existentes y URLs históricas confirmadas
                # se preservan sin volver a introducirlas.
                if url in by_url or url in seen_urls:
                    continue

                # Si se supera el presupuesto de artículos, la URL queda sin marcar
                # y por tanto será reintentada en la siguiente pasada.
                if evaluated >= max_articles:
                    continue

                try:
                    article = extract_article(fetch(session, url), url)
                    evaluated += 1
                    published_raw = str(article.get("published_at") or "")
                    published = parse_iso(published_raw)
                    if published is None or len(published_raw) < 10:
                        candidate_errors.append(f"{url}: sin fecha de publicación verificable")
                        continue

                    # Público muestra la hora editorial en Madrid; para la frontera
                    # de medianoche manda la fecha local visible del artículo.
                    if published_raw[:10] < capture_local_date:
                        newly_seen.add(url)
                        filtered_before_cutoff += 1
                        continue

                    item = merge_listing_item(None, row, stamp)
                    if article.get("title"):
                        item["title"] = article["title"]
                    item["description"] = article.get("description") or ""
                    item["published_at"] = article.get("published_at")
                    item["tweets"] = article["tweets"]
                    item["tweet_count"] = article["tweet_count"]
                    item["article_status"] = "ready"
                    item["article_fetched_at"] = stamp
                    by_url[url] = item
                    discovered.append(url)
                    newly_seen.add(url)
                except Exception as exc:
                    candidate_errors.append(f"{url}: {exc}")
        except Exception as exc:  # one listing failure must not erase or block the inbox
            page_errors.append(f"página {page}: {exc}")

    pending_fetch = [
        item for item in by_url.values()
        if item.get("article_status") != "ready" or not isinstance(item.get("tweets"), list)
    ]
    pending_fetch.sort(key=lambda item: (item.get("article_status") == "ready", item.get("first_seen_at") or ""))

    remaining_budget = max(0, max_articles - evaluated)
    for item in pending_fetch[:remaining_budget]:
        try:
            article = extract_article(fetch(session, item["url"]), item["url"])
            if article.get("title"):
                item["title"] = article["title"]
            item["description"] = article.get("description") or item.get("description") or ""
            item["published_at"] = article.get("published_at") or item.get("published_at")
            item["tweets"] = article["tweets"]
            item["tweet_count"] = article["tweet_count"]
            item["article_status"] = "ready"
            item["article_fetched_at"] = stamp
            item.pop("article_error", None)
            newly_seen.add(item["url"])
        except Exception as exc:
            item["article_status"] = "retry"
            item["article_error"] = str(exc)[:500]
            item["article_last_attempt_at"] = stamp

    all_errors = page_errors + candidate_errors
    current_error = "; ".join(all_errors)[:1000] if all_errors else None

    # No se escribe un commit vacío. La única excepción es la primera pasada tras
    # introducir capture_from o cuando se ha confirmado alguna URL histórica nueva.
    if (
        not discovered
        and not pending_fetch
        and not newly_seen
        and not capture_from_changed
        and scan.get("last_error") == current_error
    ):
        print("Tremending: sin nuevas entradas dentro de la ventana; estado editorial sin cambios")
        return state

    items = list(by_url.values())
    items.sort(key=lambda item: (item.get("published_at") or item.get("first_seen_at") or "", item.get("id") or ""), reverse=True)
    state["items"] = items
    state["updated_at"] = stamp
    scan["seen_urls"] = sorted(seen_urls | newly_seen | set(by_url.keys()))
    scan.update({
        "last_run_at": stamp,
        "last_success_at": stamp if not page_errors else scan.get("last_success_at"),
        "recent_pages": recent_pages,
        "recovery_page": None,
        "capture_from": capture_from,
        "capture_local_date": capture_local_date,
        "last_error": current_error,
        "last_discovered_count": len(discovered),
        "last_evaluated_count": evaluated,
        "last_filtered_before_cutoff": filtered_before_cutoff,
        "total_items": len(items),
    })
    return state

def selftest() -> None:
    listing = """<h2><a href='/tremending/uno-largo.html'>Título suficientemente largo</a></h2>
    <a href='https://www.publico.es/politica/no.html'>No</a>
    <a href='/tremending/uno-largo.html?utm_source=x'>Duplicado</a>"""
    rows = extract_listing(listing)
    assert len(rows) == 1 and rows[0]["url"].endswith("uno-largo.html")
    article = """<html><head><meta property='og:title' content='Prueba'></head><body>
    <article><div itemprop='articleBody'>
    <blockquote class='twitter-tweet'><a href='https://x.com/SparrowAntifa/status/2104511140961341531?s=20'>x</a></blockquote>
    <blockquote class='twitter-tweet'><a href='https://twitter.com/otra/status/12345'>x</a></blockquote>
    </div><aside><blockquote class='twitter-tweet'><a href='https://x.com/ajena/status/999'>x</a></blockquote></aside></article>
    </body></html>"""
    parsed = extract_article(article, "https://www.publico.es/tremending/prueba.html")
    assert [x["id"] for x in parsed["tweets"]] == ["2104511140961341531", "12345"]
    old = {"url": rows[0]["url"], "status": "postponed", "selected_tweet_id": "123"}
    merged = merge_listing_item(old, rows[0], now_iso())
    assert merged["status"] == "postponed" and merged["selected_tweet_id"] == "123"
    assert parse_iso("2026-09-29T22:00:00Z") == parse_iso(CAPTURE_FROM_DEFAULT)
    assert parse_iso("2026-09-30T00:00:00+02:00") == parse_iso(CAPTURE_FROM_DEFAULT)
    print("TREMENDING_SELFTEST_OK")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, default=STATE_PATH)
    parser.add_argument("--recent-pages", type=int, default=8)
    parser.add_argument("--max-articles", type=int, default=40)
    parser.add_argument("--article-url", help="Parse one article and print JSON without changing state")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return 0
    session = requests.Session()
    if args.article_url:
        print(json.dumps(extract_article(fetch(session, args.article_url), args.article_url), ensure_ascii=False, indent=2))
        return 0
    state = update_state(load_state(args.state), session, max(1, args.recent_pages), max(1, args.max_articles))
    args.state.parent.mkdir(parents=True, exist_ok=True)
    args.state.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Tremending: {len(state['items'])} entradas acumuladas; recuperación p{state['scan']['recovery_page']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
