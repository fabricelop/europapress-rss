#!/usr/bin/env python3
"""Publisher-owned publication timestamps. Poll time and aggregator time are not publication time."""
from __future__ import annotations
import html
import re
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from urllib.parse import urlsplit, urlunsplit


def parse_publication_date(raw, now=None):
    if not raw or not isinstance(raw, str):
        return None
    value = html.unescape(raw.strip()).strip("\"' ")
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
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if result < datetime(2000,1,1,tzinfo=timezone.utc) or result > current + timedelta(minutes=5):
        return None
    return result


def utc_iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00","Z") if value else None


def clean_feed_value(raw):
    value = re.sub(r"<!\[CDATA\[([\s\S]*?)\]\]>", lambda m:m.group(1), str(raw or ""))
    value = re.sub(r"<[^>]+>", " ", value)
    return re.sub(r"\s+", " ", html.unescape(value)).strip()


def feed_publication(item_xml, now=None):
    for key in ("pubDate","published","dc:date","dcterms:issued","datePublished"):
        tag = re.escape(key)
        matches = re.findall(
            rf"<(?:[A-Za-z_][\w.-]*:)?{tag}(?:\s[^>]*)?>([\s\S]*?)</(?:[A-Za-z_][\w.-]*:)?{tag}\s*>",
            item_xml, re.I)
        for value in matches:
            cleaned = re.sub(r"<!\[CDATA\[([\s\S]*?)\]\]>", r"\1", value).strip()
            date = parse_publication_date(cleaned, now)
            if date:
                return utc_iso(date)
    return None


class _PublisherMeta(HTMLParser):
    KEYS={"article:published_time","article:published","datepublished","citation_publication_date",
          "pubdate","dc.date.issued","dc.date.created"}
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.values=[]
    def handle_starttag(self, tag, attrs):
        attrs={str(k).lower():v for k,v in attrs if k}
        if tag.casefold()=="meta":
            name=str(attrs.get("property") or attrs.get("name") or attrs.get("itemprop") or "").lower()
            if name in self.KEYS and attrs.get("content"):
                self.values.append(str(attrs["content"]))
        elif tag.casefold()=="time" and str(attrs.get("itemprop") or "").lower()=="datepublished":
            if attrs.get("datetime"):
                self.values.append(str(attrs["datetime"]))


def article_publication(page_html, now=None):
    parser=_PublisherMeta()
    try:
        parser.feed(str(page_html or "")[:1_500_000])
    except Exception:
        pass
    for value in parser.values:
        date=parse_publication_date(value, now)
        if date:
            return utc_iso(date)
    for script in re.findall(
        r'<script\b[^>]*type\s*=\s*["\']application/ld\+json["\'][^>]*>([\s\S]*?)</script>',
        str(page_html or "")[:1_500_000], re.I):
        match=re.search(r'"datePublished"\s*:\s*"([^"]+)"',script,re.I)
        if match:
            date=parse_publication_date(match.group(1),now)
            if date:
                return utc_iso(date)
    return None


def same_publisher_article(url, publisher_domain):
    try:
        parts=urlsplit(str(url))
        host=str(parts.hostname or "").lower()
        domain=str(publisher_domain or "").lower()
        if (parts.scheme!="https" or parts.username or parts.password or parts.port not in (None,443)
                or not domain or not (host==domain or host.endswith("."+domain))):
            return False
        return parts.path.rstrip("/").lower() not in ("","/noticias","/ultima-hora","/ultimas-noticias","/deportes")
    except ValueError:
        return False


def latest_official_feed(body, publisher_domain, now=None, news_only=False):
    domain=str(publisher_domain or "").lower()
    if not domain:
        return None
    blocks=re.findall(r"<(?:item|entry)\b[\s\S]*?</(?:item|entry)>",str(body or ""),re.I)
    best=None
    for block in blocks[:400]:
        published=feed_publication(block,now)
        if not published:
            continue
        lm=re.search(r"<link(?:\s[^>]*)?>([\s\S]*?)</link>",block,re.I)
        tm=re.search(r"<title(?:\s[^>]*)?>([\s\S]*?)</title>",block,re.I)
        if not lm or not tm:
            continue
        url=html.unescape(re.sub(r"<!\[CDATA\[|\]\]>","",lm.group(1))).strip()
        title=clean_feed_value(tm.group(1))
        try:
            parts=urlsplit(url)
            host=str(parts.hostname or "").lower()
            if parts.scheme!="https" or not (host==domain or host.endswith("."+domain)):
                continue
            if news_only and "/noticias/" not in parts.path:
                continue
        except ValueError:
            continue
        if title and (best is None or published>best["published_at"]):
            best={"published_at":published,"title":title,"url":url,"publication_date_source":"publisher_feed"}
    return best
