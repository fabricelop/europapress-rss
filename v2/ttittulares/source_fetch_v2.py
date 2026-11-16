#!/usr/bin/env python3
"""Real, bounded and source-isolated HTTP adapters for TTiTTulares V2.

This module performs read-only GET requests only. It never persists state, calls
GitHub, starts ChatGPT/Chrome, or publishes. Every source owns its fallback chain;
fallback URLs retain the original source/family identity.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path

try:
    from .source_catalog_v2 import load_catalog, fallback_chain, source_map
    from .source_publication_v2 import (
        article_publication, clean_feed_value, feed_publication,
        parse_publication_date, utc_iso, same_publisher_article
    )
    from .content_filters_v2 import sport_important
except ImportError:
    from source_catalog_v2 import load_catalog, fallback_chain, source_map
    from source_publication_v2 import (
        article_publication, clean_feed_value, feed_publication,
        parse_publication_date, utc_iso, same_publisher_article
    )
    from content_filters_v2 import sport_important

ROOT = Path(__file__).resolve().parent
DEFAULT_TIMEOUT_SECONDS = 10
DEFAULT_WORKERS = 8
MAX_WORKERS = 16
MAX_BODY_BYTES = 4_000_000
MAX_ROWS_PER_SOURCE = 80
MAX_ARTICLE_DATE_ENRICHMENTS = 3
SER_MAX_AGE_HOURS = 12
USER_AGENT = "TTiTTularesV2-NewsRadar/1.0 (+https://github.com/fabricelop/europapress-rss)"


class FetchError(RuntimeError):
    def __init__(self, code, message, http_status=None):
        super().__init__(str(message)[:300])
        self.code = str(code)
        self.http_status = http_status


class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Only follow HTTPS redirects within the source's known host set."""
    def __init__(self, allowed_hosts, allowed_roots):
        super().__init__()
        self.allowed_hosts = set(allowed_hosts)
        self.allowed_roots = tuple(allowed_roots)

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parts = urllib.parse.urlsplit(str(newurl))
        host = (parts.hostname or "").lower().rstrip(".")
        allowed = (parts.scheme.lower() == "https" and
                   (host in self.allowed_hosts or
                    any(host == root or host.endswith("." + root) for root in self.allowed_roots)))
        if not allowed:
            raise FetchError("redirect_blocked", "Redirect outside the configured HTTPS host allowlist")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class _AnchorExtractor(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows = []
        self.href = None
        self.parts = []
        self.depth = 0

    def handle_starttag(self, tag, attrs):
        tag = tag.casefold()
        values = {str(k).lower(): v for k, v in attrs if k}
        if tag == "a" and self.href is None:
            self.href = values.get("href")
            self.parts = []
            self.depth = 1
        elif self.href is not None and tag not in {"script", "style"}:
            self.depth += 1

    def handle_data(self, data):
        if self.href is not None:
            self.parts.append(data)

    def handle_endtag(self, tag):
        if self.href is None:
            return
        if tag.casefold() == "a":
            self.rows.append((self.href, clean_feed_value(" ".join(self.parts))))
            self.href = None
            self.parts = []
            self.depth = 0
        elif self.depth:
            self.depth = max(1, self.depth - 1)


def _host_allowed(url, source, catalog):
    try:
        parts = urllib.parse.urlsplit(str(url))
        host = (parts.hostname or "").lower().rstrip(".")
        if parts.scheme.lower() != "https" or not host or parts.username or parts.password:
            return False
        if parts.port not in (None, 443):
            return False
    except (TypeError, ValueError):
        return False
    definition = source_map(catalog).get(source)
    if not definition:
        return False
    domain = str(definition.get("domain") or "").lower().rstrip(".")
    configured_hosts = set()
    for candidate in fallback_chain(source, catalog=catalog):
        try:
            candidate_host = urllib.parse.urlsplit(candidate).hostname
            if candidate_host:
                configured_hosts.add(candidate_host.lower().rstrip("."))
        except ValueError:
            continue
    return (host in configured_hosts or
            bool(domain and (host == domain or host.endswith("." + domain))))


def _allowed_hosts(source, catalog):
    exact = set()
    roots = set()
    definition = source_map(catalog)[source]
    if definition.get("domain"):
        roots.add(str(definition["domain"]).lower().rstrip("."))
    for url in fallback_chain(source, catalog=catalog):
        try:
            host = urllib.parse.urlsplit(url).hostname
            if host:
                exact.add(host.lower().rstrip("."))
        except ValueError:
            pass
    return exact, roots


def http_get(url, source, timeout=DEFAULT_TIMEOUT_SECONDS, *, catalog=None):
    catalog = catalog or load_catalog()
    if not _host_allowed(url, source, catalog):
        raise FetchError("url_not_allowlisted", "URL is outside the configured HTTPS source allowlist")
    exact, roots = _allowed_hosts(source, catalog)
    opener = urllib.request.build_opener(_SafeRedirectHandler(exact, roots))
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/rss+xml, application/atom+xml, application/json, text/html, */*;q=0.5",
            "Accept-Language": "es-ES,es;q=0.9,en;q=0.5",
            "Cache-Control": "no-cache",
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=timeout) as response:
            body_bytes = response.read(MAX_BODY_BYTES + 1)
            status = int(response.getcode() or 200)
            final_url = response.geturl()
            headers = response.headers
    except urllib.error.HTTPError as exc:
        raise FetchError("http_error", f"HTTP {exc.code}", int(exc.code)) from exc
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", exc)
        raise FetchError("network_error", str(reason)) from exc
    except TimeoutError as exc:
        raise FetchError("timeout", "Source request timed out") from exc
    if len(body_bytes) > MAX_BODY_BYTES:
        raise FetchError("response_too_large", f"Response exceeds {MAX_BODY_BYTES} bytes", status)
    if not _host_allowed(final_url, source, catalog):
        raise FetchError("final_url_not_allowlisted", "Final URL is outside the configured HTTPS source allowlist", status)
    charset = None
    try:
        charset = headers.get_content_charset()
    except Exception:
        charset = None
    try:
        body = body_bytes.decode(charset or "utf-8", errors="replace")
    except LookupError:
        body = body_bytes.decode("utf-8", errors="replace")
    if not body.strip():
        raise FetchError("empty_response", "Source returned an empty response", status)
    return {
        "body": body,
        "http_status": status,
        "final_url": final_url,
        "content_type": headers.get("Content-Type", "") if headers else "",
        "bytes": len(body_bytes),
    }


def _local_name(tag):
    return str(tag or "").rsplit("}", 1)[-1].split(":")[-1].casefold()


def _element_text(element):
    return clean_feed_value(" ".join(element.itertext())) if element is not None else ""


def _same_publisher_url(url, definition):
    try:
        parts = urllib.parse.urlsplit(str(url))
        host = (parts.hostname or "").lower()
    except ValueError:
        return False
    domain = str(definition.get("domain") or "").lower()
    if domain and (host == domain or host.endswith("." + domain)):
        return parts.scheme.lower() == "https" and not parts.username and not parts.password
    return host == "news.google.com" and parts.scheme.lower() == "https"


def _google_title(title):
    # V1 trims only the final " - Publisher" suffix used by Google News RSS.
    return re.sub(r"\s+-\s+[^-]{2,80}$", "", str(title or "")).strip()


def parse_json_rows(body, source, definition, now):
    try:
        payload = json.loads(body)
    except (TypeError, ValueError) as exc:
        raise FetchError("invalid_json", "Source JSON could not be decoded") from exc
    if isinstance(payload, list):
        items = payload
    elif isinstance(payload, dict):
        items = payload.get("items")
        if not isinstance(items, list):
            items = payload.get("news")
        if not isinstance(items, list):
            items = payload.get("results")
        if not isinstance(items, list):
            raise FetchError("json_items_missing", "JSON response has no items/news/results array")
    else:
        raise FetchError("json_root_invalid", "JSON root must be an array or object")
    result = []
    for item in items[:MAX_ROWS_PER_SOURCE]:
        if not isinstance(item, dict):
            continue
        title = clean_feed_value(item.get("title") or item.get("titulo") or item.get("headline") or "")
        url = str(item.get("url") or item.get("link") or item.get("canonical_url") or "").strip()
        if not title or not _same_publisher_url(url, definition):
            continue
        row = {"source": source, "title": title, "url": url,
               "source_type": definition["type"]}
        published_raw = item.get("published_at") or item.get("published") or item.get("pubDate")
        date_source = str(item.get("publication_date_source") or "")
        trusted_date_sources = {"publisher_feed", "publisher_article_metadata", "publisher"}
        date = (parse_publication_date(str(published_raw), now)
                if published_raw and date_source in trusted_date_sources else None)
        if definition["type"] == "general" and date:
            row["published_at"] = utc_iso(date)
            row["publication_date_source"] = date_source
        if definition["type"] == "sport" and not sport_important(title):
            continue
        result.append(row)
    return result


def parse_xml_rows(body, source, definition, request_url, now):
    try:
        root = ET.fromstring(body)
    except ET.ParseError as exc:
        raise FetchError("invalid_xml", "RSS/Atom response could not be parsed") from exc
    is_google = urllib.parse.urlsplit(request_url).hostname == "news.google.com"
    result = []
    for item in (node for node in root.iter() if _local_name(node.tag) in {"item", "entry"}):
        title_node = next((node for node in item if _local_name(node.tag) == "title"), None)
        title = _element_text(title_node)
        link = ""
        for node in item:
            if _local_name(node.tag) != "link":
                continue
            rel = str(node.attrib.get("rel") or "alternate").lower()
            if rel not in {"alternate", ""}:
                continue
            link = str(node.attrib.get("href") or _element_text(node)).strip()
            if link:
                break
        if not title or not link:
            continue
        link = urllib.parse.urljoin(request_url, link)
        if not _same_publisher_url(link, definition):
            continue
        if is_google:
            title = _google_title(title)
        if not title:
            continue
        row = {"source": source, "title": title, "url": link,
               "source_type": definition["type"]}
        if not is_google and definition["type"] == "general":
            item_xml = ET.tostring(item, encoding="unicode")
            published = feed_publication(item_xml, now)
            if published:
                row["published_at"] = published
                row["publication_date_source"] = "publisher_feed"
        if definition["type"] == "sport" and not sport_important(title):
            continue
        result.append(row)
        if len(result) >= MAX_ROWS_PER_SOURCE:
            break
    return result


def parse_html_rows(body, source, definition, page_url):
    parser = _AnchorExtractor()
    try:
        parser.feed(str(body or "")[:MAX_BODY_BYTES])
    except Exception as exc:
        raise FetchError("invalid_html", "HTML listing could not be parsed") from exc
    result = []
    for href, title in parser.rows:
        if not (35 <= len(title) <= 240):
            continue
        url = urllib.parse.urljoin(page_url, str(href or "").strip())
        if not _same_publisher_url(url, definition):
            continue
        if source == "Cadena SER":
            parts = urllib.parse.urlsplit(url)
            if not re.search(r"/20\d{2}/\d{2}/\d{2}/[^/]+", parts.path):
                continue
        if definition["type"] == "sport" and not sport_important(title):
            continue
        result.append({"source": source, "title": title, "url": url,
                       "source_type": definition["type"]})
        if len(result) >= MAX_ROWS_PER_SOURCE:
            break
    return result


def parse_response(body, source, definition, request_url, now):
    path = urllib.parse.urlsplit(request_url).path.lower()
    if path.endswith(".json"):
        return parse_json_rows(body, source, definition, now)
    content_start = str(body or "")[:1000].lower()
    if path.endswith(".xml") or path.endswith("/feed") or "<rss" in content_start or "<feed" in content_start:
        return parse_xml_rows(body, source, definition, request_url, now)
    return parse_html_rows(body, source, definition, request_url)


def _enrich_html_dates(rows, definition, fetcher, timeout, now):
    enriched = 0
    domain = definition.get("domain")
    for row in rows:
        if enriched >= MAX_ARTICLE_DATE_ENRICHMENTS:
            break
        if not same_publisher_article(row.get("url"), domain):
            continue
        enriched += 1
        try:
            response = fetcher(row["url"], row["source"], min(5, timeout))
            published = article_publication(response["body"], now)
            if published:
                row["published_at"] = published
                row["publication_date_source"] = "publisher_article_metadata"
        except Exception:
            # Article-date enrichment is telemetry-only; it never discards a good listing.
            continue
    return rows


def _source_attempt(source, definition, catalog, fetcher, timeout, now):
    started = time.monotonic()
    urls = fallback_chain(source, include_recovery=True, catalog=catalog)
    attempted = []
    last_error = None
    stale_backup = None
    for depth, url in enumerate(urls):
        attempt = {"url": url, "http_status": None, "items": 0, "error": None}
        attempted.append(attempt)
        try:
            response = fetcher(url, source, timeout)
            attempt["http_status"] = response.get("http_status")
            rows = parse_response(response["body"], source, definition, response.get("final_url") or url, now)
            if not rows:
                attempt["error"] = "zero_valid_items"
                last_error = FetchError("zero_valid_items", "No valid articles extracted from this endpoint",
                                        response.get("http_status"))
                continue
            if definition["format"] == "html" and urllib.parse.urlsplit(url).hostname != "news.google.com":
                rows = _enrich_html_dates(rows, definition, fetcher, timeout, now)
            attempt["items"] = len(rows)
            if source == "Cadena SER" and urllib.parse.urlsplit(url).hostname != "news.google.com":
                dates = [parse_publication_date(row.get("published_at"), now)
                         for row in rows if row.get("published_at")]
                dates = [value for value in dates if value]
                latest = max(dates) if dates else None
                if latest is None or latest < now - timedelta(hours=SER_MAX_AGE_HOURS):
                    stale_backup = stale_backup or (rows, response, url)
                    attempt["error"] = "stale_publisher_page"
                    last_error = FetchError("stale_publisher_page",
                        "Cadena SER page has no verified publisher article from the last 12 hours")
                    continue
            elapsed = int((time.monotonic() - started) * 1000)
            fallback_depth = depth
            recovered = depth > 0
            status = {
                "source": source, "type": definition["type"], "family": definition["family"],
                "ok": True, "degraded": False, "items": len(rows),
                "url": response.get("final_url") or url, "fallback_used": recovered,
                "fallback_depth": fallback_depth, "attempts": len(attempted),
                "attempted_urls": [x["url"] for x in attempted],
                "http_status": response.get("http_status"), "response_bytes": response.get("bytes"),
                "latency_ms": elapsed, "fetched_at": utc_iso(now), "error": None,
                "recovered": recovered,
            }
            return rows, status
        except FetchError as exc:
            attempt["error"] = exc.code
            attempt["http_status"] = exc.http_status
            last_error = exc
        except Exception as exc:
            attempt["error"] = "unexpected_error"
            last_error = FetchError("unexpected_error", str(exc))
    elapsed = int((time.monotonic() - started) * 1000)
    if source == "Cadena SER" and stale_backup:
        rows, response, url = stale_backup
        status = {
            "source": source, "type": definition["type"], "family": definition["family"],
            "ok": False, "degraded": True, "items": len(rows),
            "url": response.get("final_url") or url, "fallback_used": True,
            "fallback_depth": max(0, len(attempted) - 1), "attempts": len(attempted),
            "attempted_urls": [x["url"] for x in attempted],
            "http_status": response.get("http_status"), "response_bytes": response.get("bytes"),
            "latency_ms": elapsed, "fetched_at": utc_iso(now),
            "error": "stale_publisher_page_no_fresh_alternative",
            "error_code": "stale_publisher_page", "recovered": False,
        }
        return rows, status
    status = {
        "source": source, "type": definition["type"], "family": definition["family"],
        "ok": False, "degraded": False, "items": 0,
        "url": None, "fallback_used": len(attempted) > 1,
        "fallback_depth": max(0, len(attempted) - 1), "attempts": len(attempted),
        "attempted_urls": [x["url"] for x in attempted],
        "http_status": getattr(last_error, "http_status", None),
        "response_bytes": None, "latency_ms": elapsed, "fetched_at": utc_iso(now),
        "error": str(last_error or "no_source_response")[:240],
        "error_code": getattr(last_error, "code", "no_source_response"),
        "recovered": False,
    }
    return [], status


def fetch_one_source(source, *, catalog=None, timeout=DEFAULT_TIMEOUT_SECONDS, now=None, fetcher=None):
    catalog = catalog or load_catalog()
    definition = source_map(catalog).get(source)
    if not definition:
        raise ValueError("SOURCE_NOT_IN_CATALOG")
    clock = now.astimezone(timezone.utc) if now else datetime.now(timezone.utc)
    if clock.tzinfo is None:
        raise ValueError("NOW_MUST_BE_TIMEZONE_AWARE")
    active_fetcher = fetcher or (lambda url, name, seconds: http_get(
        url, name, seconds, catalog=catalog))
    return _source_attempt(source, definition, catalog, active_fetcher, timeout, clock)


def fetch_all_sources(*, catalog=None, timeout=DEFAULT_TIMEOUT_SECONDS,
                      workers=DEFAULT_WORKERS, now=None, fetcher=None, source_names=None):
    """Fetch each configured source concurrently; fallbacks remain sequential per source."""
    catalog = catalog or load_catalog()
    clock = now.astimezone(timezone.utc) if now else datetime.now(timezone.utc)
    if clock.tzinfo is None:
        raise ValueError("NOW_MUST_BE_TIMEZONE_AWARE")
    workers = max(1, min(int(workers), MAX_WORKERS, len(catalog["sources"]) or 1))
    definitions = source_map(catalog)
    names = list(source_names) if source_names is not None else [x["name"] for x in catalog["sources"]]
    if any(name not in definitions for name in names):
        raise ValueError("UNKNOWN_SOURCE_IN_REQUEST")
    ordered = {name: index for index, name in enumerate(names)}
    rows_by_source = {}
    statuses_by_source = {}
    active_fetcher = fetcher or (lambda url, name, seconds: http_get(
        url, name, seconds, catalog=catalog))

    def task(name):
        return name, _source_attempt(name, definitions[name], catalog, active_fetcher, timeout, clock)

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers, thread_name_prefix="ttn2-source") as pool:
        futures = [pool.submit(task, name) for name in names]
        for future in concurrent.futures.as_completed(futures):
            name, (rows, status) = future.result()
            rows_by_source[name] = rows
            statuses_by_source[name] = status

    rows = []
    statuses = []
    for name in names:
        source_rows = rows_by_source.get(name, [])
        rows.extend(source_rows)
        statuses.append(statuses_by_source[name])
    failures = [x for x in statuses if not x.get("ok")]
    return {
        "rows": rows,
        "source_statuses": statuses,
        "source_failures": failures,
        "metrics": {
            "configured_sources": len(names),
            "successful_sources": sum(1 for x in statuses if x.get("ok")),
            "degraded_sources": sum(1 for x in statuses if x.get("degraded")),
            "failed_sources": sum(1 for x in statuses if not x.get("ok") and not x.get("degraded")),
            "retrieved_rows": len(rows),
            "fallback_sources": sum(1 for x in statuses if x.get("fallback_used")),
            "parallel_workers": workers,
        },
        "effects_enabled": False,
    }


def main():
    parser = argparse.ArgumentParser(description="Read-only live source fetch for TTiTTulares V2")
    parser.add_argument("--live", action="store_true", help="Allow read-only HTTPS GET requests to the configured sources")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SECONDS)
    parser.add_argument("--output", help="Optional JSON output path, restricted to v2/ttittulares/state/")
    args = parser.parse_args()
    if not args.live:
        parser.error("Use --live explicitly to request live source reads")
    result = fetch_all_sources(workers=args.workers, timeout=args.timeout)
    summary = {"metrics": result["metrics"], "source_statuses": result["source_statuses"],
               "publication_enabled": False, "persistence_enabled": bool(args.output)}
    if args.output:
        output = Path(args.output).resolve()
        allowed = (ROOT / "state").resolve()
        if allowed not in output.parents:
            raise ValueError("OUTPUT_MUST_REMAIN_UNDER_V2_TTITTULARES_STATE")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps({
            "schema_version": 1, "project": "ttittulares-v2",
            "fetched_at": utc_iso(datetime.now(timezone.utc)),
            "rows": result["rows"], "source_statuses": result["source_statuses"],
            "metrics": result["metrics"], "effects_enabled": False,
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
