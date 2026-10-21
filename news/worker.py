#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["feedparser>=6.0.11,<7"]
# ///
"""One-request JSON worker; no publisher HTML or network-loaded resources reach the UI."""
from __future__ import annotations

import calendar
from contextlib import contextmanager
from dataclasses import dataclass
from html.parser import HTMLParser
import http.client
import importlib.util
import ipaddress
import json
import math
from pathlib import Path
import re
import signal
import socket
import sqlite3
import ssl
import sys
import time
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit

import feedparser

_anthropic_spec = importlib.util.spec_from_file_location("tern_news_anthropic", Path(__file__).with_name("anthropic.py"))
_anthropic = importlib.util.module_from_spec(_anthropic_spec)
sys.modules[_anthropic_spec.name] = _anthropic
_anthropic_spec.loader.exec_module(_anthropic)

_arxiv_spec = importlib.util.spec_from_file_location("tern_news_arxiv", Path(__file__).with_name("arxiv.py"))
_arxiv = importlib.util.module_from_spec(_arxiv_spec)
sys.modules[_arxiv_spec.name] = _arxiv
_arxiv_spec.loader.exec_module(_arxiv)

MAX_REQUEST = 64 * 1024
MAX_FEED_BYTES = 2 * 1024 * 1024
MAX_SOURCES = 11
MAX_FEED_ENTRIES = 200
HN_WEEK_SECONDS = 7 * 86400
HN_STORIES = 100
MAX_STORIES = 2000
MAX_SNAPSHOT = 1000
FETCH_SECONDS = 10
REFRESH_SECONDS = 90
REDIRECTS = {301, 302, 303, 307, 308}
CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]")
TRACKING_QUERY = {"fbclid", "gclid", "dclid", "mc_cid", "mc_eid"}


class NewsError(Exception):
    pass


def text(value, limit):
    return CONTROL_CHARS.sub("", str(value or ""))[:limit].strip()


class PlainHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "noscript", "template", "iframe", "object", "svg"}:
            self.hidden += 1
        elif not self.hidden and tag in {"p", "div", "br", "li", "h1", "h2", "h3"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"script", "style", "noscript", "template", "iframe", "object", "svg"}:
            self.hidden = max(0, self.hidden - 1)
        elif not self.hidden and tag in {"p", "div", "li"}:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def plain_html(value, limit):
    parser = PlainHTML()
    parser.feed(str(value or "")[:MAX_FEED_BYTES])
    return text(re.sub(r"[ \t]+", " ", "".join(parser.parts)), limit)


def normalize_url(value):
    """Normalize identity without rewriting meaningful publisher query parameters."""
    if not isinstance(value, str) or len(value) > 8192 or re.search(r"[\x00-\x20\x7f\\]", value):
        raise NewsError("Invalid HTTP(S) URL")
    try:
        parts = urlsplit(value)
        if parts.scheme.lower() not in {"http", "https"} or not parts.hostname:
            raise ValueError()
        if parts.username is not None or parts.password is not None:
            raise ValueError()
        host = parts.hostname.encode("idna").decode("ascii").lower().rstrip(".")
        if not host or "%" in host:
            raise ValueError()
        port = parts.port
    except (ValueError, UnicodeError):
        raise NewsError("Invalid HTTP(S) URL") from None
    scheme = parts.scheme.lower()
    authority = f"[{host}]" if ":" in host else host
    if port is not None and port != (443 if scheme == "https" else 80):
        authority += f":{port}"
    # Preserve original query encoding/order unless a tracking parameter is removed.
    query = parts.query
    pairs = parse_qsl(query, keep_blank_values=True)
    kept = [(key, val) for key, val in pairs if not key.lower().startswith("utm_") and key.lower() not in TRACKING_QUERY]
    if len(kept) != len(pairs):
        query = urlencode(kept)
    return urlunsplit((scheme, authority, parts.path or "/", query, ""))


@contextmanager
def deadline(seconds):
    """Bound DNS, socket reads and parsing, not merely individual socket operations.

    The CLI and injected test calls execute on the main thread. Restoring an outer
    alarm preserves the refresh budget when individual requests install a deadline.
    """
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_delay, previous_interval = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()

    def expired(signum, frame):
        raise NewsError("Operation timed out")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, min(seconds, previous_delay) if previous_delay else seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_delay:
            signal.setitimer(signal.ITIMER_REAL, max(0.001, previous_delay - (time.monotonic() - started)), previous_interval)


@dataclass
class Response:
    status: int
    body: bytes
    headers: dict
    url: str


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, address, port, timeout):
        super().__init__(host, port=port, timeout=timeout, context=ssl.create_default_context())
        self.address = address

    def connect(self):
        raw = socket.create_connection((self.address, self.port), self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


class HTTPFetcher:
    """Resolve/validate every redirect, then pin the validated address for the socket.

    Private networking is an explicit constructor-only test facility, never a JSON
    request option. No proxy environment, cookies, credentials, or automatic redirects.
    """
    def __init__(self, *, allow_private=False, resolver=socket.getaddrinfo):
        self.allow_private = allow_private
        self.resolver = resolver

    def addresses(self, host, port):
        records = self.resolver(host, port, type=socket.SOCK_STREAM)
        addresses = list(dict.fromkeys(record[4][0] for record in records))
        if not addresses:
            raise NewsError("Publisher DNS returned no addresses")
        for address in addresses:
            parsed = ipaddress.ip_address(address)
            mapped = getattr(parsed, "ipv4_mapped", None)
            unsafe = not parsed.is_global or parsed.is_multicast or parsed.is_reserved
            unsafe = unsafe or (mapped is not None and (not mapped.is_global or mapped.is_multicast or mapped.is_reserved))
            unsafe = unsafe or getattr(parsed, "sixtofour", None) is not None or getattr(parsed, "teredo", None) is not None
            if not self.allow_private and unsafe:
                raise NewsError("Private or local network addresses are not allowed")
        return addresses

    def __call__(self, url, headers, max_bytes):
        with deadline(FETCH_SECONDS):
            current = normalize_url(url)
            request_headers = dict(headers)
            for redirect in range(4):
                parts = urlsplit(current)
                port = parts.port or (443 if parts.scheme == "https" else 80)
                address = self.addresses(parts.hostname, port)[0]
                if parts.scheme == "https":
                    connection = PinnedHTTPSConnection(parts.hostname, address, port, 5)
                else:
                    connection = http.client.HTTPConnection(address, port, timeout=5)
                try:
                    connection.request("GET", urlunsplit(("", "", parts.path, parts.query, "")), headers={
                        "Host": parts.netloc,
                        "User-Agent": "Tern-News/1.0 (RSS reader)",
                        "Accept": "application/atom+xml, application/rss+xml, application/xml, text/html, text/plain;q=0.8, */*;q=0.1",
                        "Accept-Encoding": "identity",
                        **request_headers,
                    })
                    response = connection.getresponse()
                    response_headers = {key.lower(): value for key, value in response.getheaders()}
                    if response.status in REDIRECTS:
                        location = response_headers.get("location")
                        if not location or redirect == 3:
                            raise NewsError("Invalid or excessive publisher redirects")
                        target = normalize_url(urljoin(current, location))
                        if urlsplit(target).netloc != parts.netloc:
                            request_headers = {}
                        current = target
                        continue
                    if response.status == 304:
                        return Response(304, b"", response_headers, current)
                    if response.status != 200:
                        raise NewsError(f"Publisher returned HTTP {response.status}")
                    if response_headers.get("content-encoding", "identity").lower() not in {"", "identity"}:
                        raise NewsError("Unsupported publisher content encoding")
                    length = response_headers.get("content-length")
                    if length and (not length.isdigit() or int(length) > max_bytes):
                        raise NewsError("Publisher response exceeds size limit")
                    body = response.read(max_bytes + 1)
                    if len(body) > max_bytes:
                        raise NewsError("Publisher response exceeds size limit")
                    return Response(200, body, response_headers, current)
                finally:
                    connection.close()
        raise NewsError("Unable to fetch publisher")


def source_config(sources):
    if not isinstance(sources, list) or len(sources) > MAX_SOURCES:
        raise NewsError(f"Expected at most {MAX_SOURCES} sources")
    result = []
    seen = set()
    for source in sources:
        if not isinstance(source, dict):
            raise NewsError("Invalid source configuration")
        identifier = source.get("id")
        if not isinstance(identifier, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", identifier) or identifier in seen:
            raise NewsError("Invalid or duplicate source ID")
        seen.add(identifier)
        interval = source.get("interval_seconds", 3600)
        if isinstance(interval, bool) or not isinstance(interval, (float, int)) or not math.isfinite(interval):
            raise NewsError("Invalid source refresh interval")
        kind = source.get("kind", "rss")
        if kind not in ("rss", "hn_weekly", "anthropic_engineering", "arxiv_weekly"):
            raise NewsError("Invalid source kind")
        category = source.get("category", "")
        if not isinstance(category, str) or len(category) > 120:
            raise NewsError("Invalid source category")
        window_days = source.get("window_days", 7 if kind == "arxiv_weekly" else 0)
        if type(window_days) is not int or not 0 <= window_days <= 365:
            raise NewsError("Invalid source age window")
        if kind == "arxiv_weekly" and window_days != 7:
            raise NewsError("arXiv requires a seven-day source age window")
        result.append({"id": identifier, "name": text(source.get("name") or identifier, 120),
                       "url": normalize_url(source.get("url")), "enabled": bool(source.get("enabled", True)),
                       "kind": kind, "category": category.strip().casefold(), "window_seconds": window_days * 86400,
                       "interval": max(60, min(86400, int(interval)))})
    return result


SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS feeds (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, url TEXT NOT NULL, enabled INTEGER NOT NULL,
    interval INTEGER NOT NULL, etag TEXT, modified TEXT, last_success REAL,
    next_refresh REAL, error TEXT, kind TEXT NOT NULL DEFAULT 'rss',
    window_seconds INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS stories (
    id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
    published_at REAL NOT NULL, first_seen_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS story_sources (
    story_id INTEGER NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
    source_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
    guid TEXT, rank INTEGER, published_at REAL,
    PRIMARY KEY(story_id, source_id)
);
CREATE INDEX IF NOT EXISTS stories_published ON stories(published_at DESC, id DESC);
"""


class Worker:
    def __init__(self, db, sources, *, fetcher=None, clock=time.time):
        if not isinstance(db, str) or not Path(db).is_absolute():
            raise NewsError("Database path must be absolute")
        self.sources = source_config(sources)
        self.clock = clock
        self.fetch = fetcher if fetcher is not None else HTTPFetcher()
        path = Path(db)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=5)
        path.chmod(0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        for table, additions in (
            ("feeds", (("kind", "TEXT NOT NULL DEFAULT 'rss'"), ("window_seconds", "INTEGER NOT NULL DEFAULT 0"))),
            ("story_sources", (("rank", "INTEGER"), ("published_at", "REAL"))),
        ):
            columns = {column["name"] for column in self.db.execute(f"PRAGMA table_info({table})")}
            for name, declaration in additions:
                if name not in columns:
                    self.db.execute(f"ALTER TABLE {table} ADD COLUMN {name} {declaration}")
        self.db.execute("DROP TABLE IF EXISTS articles")
        columns = {column["name"] for column in self.db.execute("PRAGMA table_info(stories)")}
        for name in ("is_read", "excerpt"):
            if name in columns:
                self.db.execute(f"ALTER TABLE stories DROP COLUMN {name}")
        self.db.execute("UPDATE feeds SET enabled = 0")
        for source in self.sources:
            self.db.execute("""INSERT INTO feeds(id,name,url,enabled,interval,kind,window_seconds)
                VALUES(:id,:name,:url,:enabled,:interval,:kind,:window_seconds)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name, enabled=excluded.enabled,
                interval=excluded.interval,
                etag=CASE WHEN url=excluded.url AND kind=excluded.kind AND window_seconds=excluded.window_seconds THEN etag END,
                modified=CASE WHEN url=excluded.url AND kind=excluded.kind AND window_seconds=excluded.window_seconds THEN modified END,
                last_success=CASE WHEN url=excluded.url AND kind=excluded.kind AND window_seconds=excluded.window_seconds THEN last_success END,
                next_refresh=CASE WHEN url=excluded.url AND kind=excluded.kind AND window_seconds=excluded.window_seconds THEN next_refresh END,
                error=CASE WHEN url=excluded.url AND kind=excluded.kind AND window_seconds=excluded.window_seconds THEN error END,
                url=excluded.url, kind=excluded.kind, window_seconds=excluded.window_seconds""", source)
        self.db.commit()

    def close(self):
        self.db.close()

    def snapshot(self):
        now = self.clock()
        # Legacy RSS memberships lack submission timestamps and survive a failed
        # cutover. A successful weekly edition replaces them, never backfills from
        # a possibly unrelated publisher's canonical story timestamp.
        active = """SELECT ss.*, f.id, f.name, f.kind, f.window_seconds FROM story_sources ss
            JOIN feeds f ON f.id=ss.source_id WHERE f.enabled=1
            AND (f.kind!='hn_weekly' OR ss.published_at IS NULL
                 OR ss.published_at BETWEEN ? AND ?)
            AND (f.window_seconds=0 OR ss.published_at BETWEEN ?-f.window_seconds AND ?)"""
        bounds = (now - HN_WEEK_SECONDS, now, now, now)
        # A complete arXiv edition is additional to the ordinary feed allowance.
        # Excluding it from that allowance also protects older shared stories.
        stories = self.db.execute(f"""WITH active AS ({active}),
            weekly AS (SELECT story_id FROM active WHERE kind='arxiv_weekly'),
            ordinary AS (
                SELECT s.id FROM stories s WHERE s.id NOT IN (SELECT story_id FROM weekly)
                AND EXISTS (SELECT 1 FROM active a WHERE a.story_id=s.id)
                ORDER BY EXISTS (SELECT 1 FROM active a
                    WHERE a.story_id=s.id AND a.kind='hn_weekly') DESC,
                    s.published_at DESC, s.id DESC LIMIT ?)
            SELECT * FROM stories WHERE id IN (SELECT story_id FROM weekly)
                OR id IN (SELECT id FROM ordinary)
            ORDER BY published_at DESC, id DESC""", (*bounds, MAX_SNAPSHOT)).fetchall()
        attribution = {}
        for row in self.db.execute(active + " ORDER BY f.id", bounds):
            source = {"id": row["id"], "name": row["name"], "guid": row["guid"]}
            if row["kind"] == "hn_weekly" and row["rank"] is not None:
                source.update(rank=row["rank"], published_at=row["published_at"])
            elif row["window_seconds"]:
                source["published_at"] = row["published_at"]
            attribution.setdefault(row["story_id"], []).append(source)
        feeds = []
        for source in self.sources:
            row = self.db.execute("SELECT * FROM feeds WHERE id=?", (source["id"],)).fetchone()
            feeds.append({key: row[key] for key in ("id", "name", "url", "last_success", "error", "next_refresh")})
        return {"stories": [{"id": str(row["id"]), "title": row["title"], "url": row["url"],
                             "sources": attribution.get(row["id"], []), "published_at": row["published_at"],
                             "first_seen_at": row["first_seen_at"]} for row in stories],
                "feeds": feeds, "now": now}

    def ingest(self, response, source, now):
        with deadline(5):
            if source["kind"] == "anthropic_engineering":
                articles = _anthropic.parse_engineering(response.body, response.url)
                entries = ({"link": article["url"], "title": article["title"],
                            "published_parsed": time.gmtime(article["published_at"])} for article in articles)
            else:
                if re.search(br"<!\s*(?:DOCTYPE|ENTITY)\b", response.body.replace(b"\x00", b""), re.IGNORECASE):
                    raise NewsError("Feed contains unsupported XML declarations")
                parsed = feedparser.parse(response.body)
                if not parsed.get("version") or (parsed.get("bozo") and not parsed.get("entries")):
                    raise NewsError("Publisher did not return a usable RSS or Atom feed")
                entries = parsed.entries
                if source["category"]:
                    entries = (entry for entry in entries if any(
                        tag.get("term", "").strip().casefold() == source["category"]
                        for tag in entry.get("tags", [])))
            self.ingest_entries(entries, response.url, source, now)

    def ingest_entries(self, entries, base_url, source, now):
        for index, entry in enumerate(entries):
            if source["kind"] != "arxiv_weekly" and index >= MAX_FEED_ENTRIES:
                break
            raw_url = entry.get("link")
            if not raw_url:
                continue
            try:
                url = normalize_url(urljoin(base_url, raw_url))
            except (NewsError, ValueError):
                continue
            title = plain_html(entry.get("title"), 500) or url
            timestamp = None
            stamp = entry.get("published_parsed") or entry.get("updated_parsed")
            if stamp:
                try:
                    candidate = calendar.timegm(stamp)
                    if 0 < candidate <= now + 86400:
                        timestamp = candidate
                except (ValueError, OverflowError, TypeError):
                    pass
            if source["window_seconds"] and (
                    timestamp is None or not now - source["window_seconds"] <= timestamp <= now):
                continue
            published = timestamp if timestamp is not None else now
            self.db.execute("""INSERT INTO stories(url,title,published_at,first_seen_at)
                VALUES(?,?,?,?) ON CONFLICT(url) DO NOTHING""", (url, title, published, now))
            story = self.db.execute("SELECT id FROM stories WHERE url=?", (url,)).fetchone()
            self.db.execute("""INSERT INTO story_sources(story_id,source_id,guid,published_at) VALUES(?,?,?,?)
                ON CONFLICT(story_id,source_id) DO UPDATE SET guid=excluded.guid,published_at=excluded.published_at""",
                (story["id"], source["id"], text(entry.get("id") or entry.get("guid"), 1024) or None, timestamp))

    def ingest_arxiv_weekly(self, source, now):
        """Replace memberships only after every page of the edition is fetched."""
        entries = _arxiv.fetch_week(self.fetch, source["url"], now, MAX_FEED_BYTES)
        self.db.execute("DELETE FROM story_sources WHERE source_id=?", (source["id"],))
        self.ingest_entries(entries, source["url"], source, now)

    def ingest_hn_weekly(self, source, now):
        """Fetch a complete edition before changing any cached memberships."""
        endpoint = urlsplit(source["url"])
        entries = {}
        page = 0
        while True:
            query = urlencode({
                "query": "", "tags": "story",
                "numericFilters": f"created_at_i>={math.ceil(now - HN_WEEK_SECONDS)},created_at_i<={math.floor(now)}",
                "hitsPerPage": HN_STORIES, "page": page,
            })
            url = urlunsplit((endpoint.scheme, endpoint.netloc, endpoint.path, query, ""))
            # The rolling query is a new resource each time; RSS validators must
            # never turn it into a 304 for a different weekly window.
            response = self.fetch(url, {"Accept": "application/json"}, MAX_FEED_BYTES)
            if response.status != 200:
                raise NewsError(f"Hacker News returned HTTP {response.status}")
            if len(response.body) > MAX_FEED_BYTES:
                raise NewsError("Hacker News response exceeds size limit")
            try:
                payload = json.loads(response.body)
            except (ValueError, UnicodeError):
                raise NewsError("Hacker News did not return usable JSON") from None
            if not isinstance(payload, dict) or not isinstance(payload.get("hits"), list):
                raise NewsError("Hacker News returned an invalid search result")
            pages = payload.get("nbPages", 1)
            if type(pages) is not int or not 0 <= pages <= 1000:
                raise NewsError("Hacker News returned invalid pagination")
            for hit in payload["hits"]:
                if not isinstance(hit, dict):
                    raise NewsError("Hacker News returned an invalid story")
                identifier, points, published = hit.get("objectID"), hit.get("points"), hit.get("created_at_i")
                if (not isinstance(identifier, str) or not re.fullmatch(r"[0-9]{1,20}", identifier)
                        or type(points) is not int or points < 0
                        or type(published) is not int or published <= 0):
                    raise NewsError("Hacker News returned invalid story metadata")
                if not now - HN_WEEK_SECONDS <= published <= now:
                    continue
                if not isinstance(hit.get("title"), str):
                    continue
                title = plain_html(hit["title"], 500)
                if not title:
                    continue
                raw_url = hit.get("url")
                if raw_url is None or raw_url == "":
                    raw_url = f"https://news.ycombinator.com/item?id={identifier}"
                try:
                    canonical = normalize_url(raw_url)
                except NewsError:
                    continue
                order = (-points, -published, int(identifier))
                candidate = (order, canonical, title, published, identifier)
                if canonical not in entries or order < entries[canonical][0]:
                    entries[canonical] = candidate
            page += 1
            if len(entries) >= HN_STORIES or page >= pages:
                break
        ranked = sorted(entries.values())[:HN_STORIES]
        self.db.execute("DELETE FROM story_sources WHERE source_id=?", (source["id"],))
        for rank, (_, url, title, published, identifier) in enumerate(ranked, 1):
            self.db.execute("""INSERT INTO stories(url,title,published_at,first_seen_at)
                VALUES(?,?,?,?) ON CONFLICT(url) DO NOTHING""", (url, title, published, now))
            story = self.db.execute("SELECT id FROM stories WHERE url=?", (url,)).fetchone()
            self.db.execute("""INSERT INTO story_sources(story_id,source_id,guid,rank,published_at)
                VALUES(?,?,?,?,?)""", (story["id"], source["id"], identifier, rank, published))

    def refresh(self, force=False):
        started = time.monotonic()
        for source in self.sources:
            if not source["enabled"]:
                continue
            row = self.db.execute("SELECT * FROM feeds WHERE id=?", (source["id"],)).fetchone()
            now = self.clock()
            if not force and row["next_refresh"] and row["next_refresh"] > now:
                continue
            remaining = REFRESH_SECONDS - (time.monotonic() - started)
            if remaining <= 0:
                break
            try:
                headers = {}
                if row["etag"]:
                    headers["If-None-Match"] = row["etag"]
                if row["modified"]:
                    headers["If-Modified-Since"] = row["modified"]
                with deadline(remaining):
                    if source["kind"] == "hn_weekly":
                        self.ingest_hn_weekly(source, now)
                        etag = modified = None
                    elif source["kind"] == "arxiv_weekly":
                        self.ingest_arxiv_weekly(source, now)
                        etag = modified = None
                    else:
                        response = self.fetch(source["url"], headers, MAX_FEED_BYTES)
                        if response.status == 304 and row["last_success"] is None:
                            raise NewsError("Publisher returned not-modified without a cached feed")
                        if response.status == 200:
                            self.ingest(response, source, now)
                        elif response.status != 304:
                            raise NewsError(f"Publisher returned HTTP {response.status}")
                        etag = text(response.headers.get("etag"), 1024) or (row["etag"] if response.status == 304 else None)
                        modified = text(response.headers.get("last-modified"), 1024) or (row["modified"] if response.status == 304 else None)
                    self.db.execute("""UPDATE feeds SET last_success=?,next_refresh=?,error=NULL,etag=?,modified=? WHERE id=?""",
                                    (now, now + source["interval"], etag, modified, source["id"]))
                    self.db.commit()
            except Exception as error:
                self.db.rollback()
                self.db.execute("UPDATE feeds SET error=?,next_refresh=? WHERE id=?",
                                (text(str(error) or type(error).__name__, 300), now + min(source["interval"], 300), source["id"]))
                self.db.commit()
        now = self.clock()
        # Active arXiv memberships do not spend the other feeds' retention budget.
        self.db.execute("""WITH weekly AS (
            SELECT ss.story_id FROM story_sources ss JOIN feeds f ON f.id=ss.source_id
            WHERE f.enabled=1 AND f.kind='arxiv_weekly'
                AND ss.published_at BETWEEN ?-f.window_seconds AND ?)
            DELETE FROM stories WHERE id IN (
                SELECT s.id FROM stories s WHERE s.id NOT IN (SELECT story_id FROM weekly)
                ORDER BY EXISTS (
                    SELECT 1 FROM story_sources ss JOIN feeds f ON f.id=ss.source_id
                    WHERE ss.story_id=s.id AND f.enabled=1 AND f.kind='hn_weekly'
                    AND ss.published_at BETWEEN ? AND ?) DESC,
                s.published_at DESC,s.id DESC LIMIT -1 OFFSET ?)""",
            (now, now, now - HN_WEEK_SECONDS, now, MAX_STORIES))
        self.db.commit()


def execute(request, *, fetcher=None, clock=time.time):
    """Python entry point exposes only an explicit test-injected network boundary."""
    worker = None
    try:
        if not isinstance(request, dict) or request.get("action") not in {"snapshot", "refresh"}:
            raise NewsError("Unknown News action")
        worker = Worker(request.get("db"), request.get("sources", []), fetcher=fetcher, clock=clock)
        if request["action"] == "refresh":
            worker.refresh(request.get("force") is True)
        return {"ok": True, "snapshot": worker.snapshot()}
    except Exception as error:
        return {"ok": False, "error": text(str(error) or type(error).__name__, 300)}
    finally:
        if worker is not None:
            worker.close()


def main():
    try:
        raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
        if len(raw) > MAX_REQUEST:
            raise NewsError("News request exceeds size limit")
        request = json.loads(raw)
        result = execute(request)
    except Exception as error:
        result = {"ok": False, "error": text(str(error) or type(error).__name__, 300)}
    sys.stdout.write(json.dumps(result, ensure_ascii=True, allow_nan=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
