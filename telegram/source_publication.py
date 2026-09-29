"""Trusted publisher-side publication timestamps for TTiTTulares source health.

Never substitute the time of the radar scan, the first time we saw a headline,
an article modification time, or Google News aggregation for publication time.
Unverifiable articles have no published_at and display an em dash in the UI.
"""
from __future__ import annotations

import html
import re
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from urllib.parse import urlsplit


def parse_publication_date(raw, now=None):
    """Return UTC publication time only for a timezone-aware and plausible date."""
    if not raw or not isinstance(raw, str):
        return None
    value = html.unescape(raw.strip()).strip('"\' ')
    if not value:
        return None
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError, OverflowError):
        try:
            result = parsedate_to_datetime(value)
        except (TypeError, ValueError, OverflowError, IndexError):
            return None
    if result is None or result.tzinfo is None or result.utcoffset() is None:
        return None
    result = result.astimezone(timezone.utc)
    current = now.astimezone(timezone.utc) if now is not None else datetime.now(timezone.utc)
    if result < datetime(2000, 1, 1, tzinfo=timezone.utc) or result > current + timedelta(minutes=5):
        return None
    return result


def utc_iso(date):
    return date.isoformat(timespec="seconds").replace("+00:00", "Z") if date else None


def feed_publication(item_xml, now=None):
    """Read only publisher publication tags; never use atom:updated."""
    for key in ("pubDate", "published", "dc:date", "dcterms:issued", "datePublished"):
        tag = re.escape(key)
        matches = re.findall(
            rf"<(?:[A-Za-z_][\w.-]*:)?{tag}(?:\s[^>]*)?>([\s\S]*?)</(?:[A-Za-z_][\w.-]*:)?{tag}\s*>",
            item_xml, re.I,
        )
        for value in matches:
            cleaned = re.sub(r"<!\[CDATA\[([\s\S]*?)\]\]>", r"\1", value).strip()
            date = parse_publication_date(cleaned, now)
            if date:
                return utc_iso(date)
    return None


class _PublisherMeta(HTMLParser):
    KEYS = {
        "article:published_time", "article:published", "datepublished",
        "citation_publication_date", "pubdate", "dc.date.issued", "dc.date.created",
    }

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.values = []

    def handle_starttag(self, tag, attrs):
        attrs = {str(k).lower(): v for k, v in attrs if k}
        if tag.casefold() == "meta":
            name = str(attrs.get("property") or attrs.get("name") or attrs.get("itemprop") or "").lower()
            if name in self.KEYS and attrs.get("content"):
                self.values.append(str(attrs["content"]))
        elif tag.casefold() == "time" and str(attrs.get("itemprop") or "").lower() == "datepublished":
            if attrs.get("datetime"):
                self.values.append(str(attrs["datetime"]))


def article_publication(page_html, now=None):
    """Only an article's own publication field (never modified_time/og:updated)."""
    parser = _PublisherMeta()
    try:
        parser.feed(str(page_html or "")[:1_500_000])
    except Exception:
        pass
    for value in parser.values:
        date = parse_publication_date(value, now)
        if date:
            return utc_iso(date)
    # Some publishers only expose datePublished in JSON-LD, not in meta tags.
    for script in re.findall(
        r'<script\b[^>]*type\s*=\s*["\']application/ld\+json["\'][^>]*>([\s\S]*?)</script>',
        str(page_html or "")[:1_500_000], re.I,
    ):
        match = re.search(r'"datePublished"\s*:\s*"([^"]+)"', script, re.I)
        if match:
            date = parse_publication_date(match.group(1), now)
            if date:
                return utc_iso(date)
    return None


def same_publisher_article(url, publisher_domain):
    """Only fetch article metadata directly from the known publisher domain."""
    try:
        parts = urlsplit(str(url))
        host = str(parts.hostname or "").lower()
        domain = str(publisher_domain or "").lower()
        if (parts.scheme != "https" or parts.username or parts.password or
                parts.port not in (None, 443) or
                not domain or not (host == domain or host.endswith("." + domain))):
            return False
        path = parts.path.rstrip("/").lower()
        return path not in ("", "/noticias", "/ultima-hora", "/ultimas-noticias", "/deportes")
    except ValueError:
        return False


def enrich_html_rows(rows, publisher_domain, fetch, limit=3, now=None):
    """Try a few actual article pages when an HTML listing has no RSS pubDate.

    The fetch callback takes (url, timeout) and must use a short timeout. Network
    failure has no impact on editorial processing or source health.
    """
    attempted = set()
    for row in rows or []:
        if len(attempted) >= limit:
            break
        url = str(row.get("url") or "")
        if not same_publisher_article(url, publisher_domain) or url in attempted:
            continue
        attempted.add(url)
        try:
            published = article_publication(fetch(url, 5), now)
            if published:
                row["published_at"] = published
                row["publication_date_source"] = "publisher_article_metadata"
        except Exception:
            continue
    return rows


def selftest():
    clock = datetime(2026, 9, 29, 21, tzinfo=timezone.utc)
    assert feed_publication(
        "<item><pubDate>Tue, 29 Sep 2026 18:42:00 GMT</pubDate><title>A</title></item>",
        clock,
    ) == "2026-09-29T18:42:00Z"
    assert feed_publication(
        "<entry><published>2026-09-29T20:30:00+02:00</published><updated>2026-09-29T21:30:00+02:00</updated></entry>",
        clock,
    ) == "2026-09-29T18:30:00Z"
    assert feed_publication("<entry><updated>2026-09-29T20:00:00Z</updated></entry>", clock) is None
    assert article_publication(
        """<meta content="2026-09-29T20:55:00+02:00" property="article:published_time">
        <meta property="article:modified_time" content="2026-09-29T22:00:00+02:00">""",
        clock,
    ) == "2026-09-29T18:55:00Z"
    assert article_publication(
        """<script type="application/ld+json">{"@type":"NewsArticle","datePublished":"2026-09-29T19:50:00+02:00"}</script>""",
        clock,
    ) == "2026-09-29T17:50:00Z"
    assert article_publication("<meta property='article:modified_time' content='2026-09-29T19:00:00Z'>", clock) is None
    assert parse_publication_date("2026-09-29T22:00:00Z", clock) is None, "Reject future publication"
    assert parse_publication_date("2026-09-29 20:00:00", clock) is None, "No invented timezone"
    assert same_publisher_article("https://news.example.com/es/noticia-123", "example.com")
    assert not same_publisher_article("https://news.google.com/rss/articles/abc", "example.com")
    fake = lambda _url, _timeout: '<meta property="article:published_time" content="2026-09-29T19:00:00Z">'
    rows = [{"url":"https://www.example.com/es/actualidad/noticia-123","title":"Noticia"}]
    enrich_html_rows(rows,"example.com",fake,now=clock)
    assert rows[0]["published_at"] == "2026-09-29T19:00:00Z"
    print("TTITTULARES_PUBLISHER_DATES_SELFTEST_OK")


if __name__ == "__main__":
    selftest()
