"""Read Anthropic's engineering articles from its server-rendered CMS data.

The official index embeds Sanity ``engineeringArticle`` records in Next.js
Flight scripts. Their ``publishedOn`` dates include the featured article, even
when its visible card has no date. Only data is decoded; JavaScript is never run.
"""
from __future__ import annotations

from datetime import datetime, timezone
from html import unescape
from html.parser import HTMLParser
import json
import re
from urllib.parse import urljoin, urlsplit


_FLIGHT_PUSH = re.compile(r"self\.__next_f\.push\s*\(\s*")
_SLUG = re.compile(r"[A-Za-z0-9_-]+\Z")
_ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}(?:T.*)?\Z")


class _FlightScripts(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.scripts = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            self.current = []

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.current is not None:
            self.scripts.append("".join(self.current))
            self.current = None


def _flight_records(scripts):
    decoder = json.JSONDecoder()
    chunks = []
    for script in scripts:
        position = 0
        while match := _FLIGHT_PUSH.search(script, position):
            try:
                payload, position = decoder.raw_decode(script, match.end())
            except (ValueError, RecursionError) as error:
                raise ValueError("Malformed Anthropic engineering data") from error
            if not script[position:].lstrip().startswith(")"):
                raise ValueError("Malformed Anthropic engineering data")
            if isinstance(payload, list) and len(payload) == 2 and payload[0] == 1:
                if not isinstance(payload[1], str):
                    raise ValueError("Malformed Anthropic engineering data")
                chunks.append(payload[1])
    # Flight can split a JSON record across script elements. Its delimiter is
    # ASCII newline, not splitlines(): CMS strings can contain literal U+2028.
    for line in "".join(chunks).split("\n"):
        record_id, separator, data = line.partition(":")
        if not separator or not re.fullmatch(r"[0-9a-fA-F]+", record_id):
            continue
        data = data.lstrip()
        if not data.startswith(("[", "{")):
            continue  # Imports, hints, and other non-JSON Flight record types.
        try:
            yield json.loads(data)
        except (ValueError, RecursionError) as error:
            raise ValueError("Malformed Anthropic engineering record") from error


def _article_nodes(record):
    pending = [record]
    while pending:
        node = pending.pop()
        if isinstance(node, dict):
            if node.get("_type") == "engineeringArticle":
                yield node
            else:
                pending.extend(reversed(list(node.values())))
        elif isinstance(node, list):
            pending.extend(reversed(node))


def _published_at(value):
    if not isinstance(value, str) or not _ISO_DATE.fullmatch(value):
        raise ValueError("Engineering article has no valid publication date")
    try:
        published = datetime.fromisoformat(value.replace("Z", "+00:00"))
        # Date-only CMS fields describe a publication day, in UTC, not fetch time.
        if published.tzinfo is None:
            published = published.replace(tzinfo=timezone.utc)
        return int(published.timestamp())
    except (ValueError, OverflowError, OSError) as error:
        raise ValueError("Engineering article has no valid publication date") from error


def parse_engineering(body: bytes, base_url: str) -> list[dict]:
    """Return unique original engineering articles, or reject unusable content.

    Missing or invalid article metadata fails the fetch instead of replacing a
    cached index with a partial list or inventing publication dates. Navigation,
    news, and research records are excluded by their CMS type, not page layout.
    """
    origin = urlsplit(base_url)
    if origin.scheme not in {"http", "https"} or not origin.hostname:
        raise ValueError("Invalid Anthropic engineering base URL")
    parser = _FlightScripts()
    try:
        parser.feed(body.decode("utf-8-sig"))
        parser.close()
    except (UnicodeError, RecursionError) as error:
        raise ValueError("Invalid Anthropic engineering HTML") from error
    if parser.current is not None:
        raise ValueError("Truncated Anthropic engineering HTML")
    articles = {}
    for record in _flight_records(parser.scripts):
        for node in _article_nodes(record):
            title = node.get("title")
            slug = node.get("slug")
            slug = slug.get("current") if isinstance(slug, dict) else None
            if not isinstance(title, str) or not isinstance(slug, str) or not _SLUG.fullmatch(slug):
                raise ValueError("Engineering article has invalid title or URL")
            title = " ".join(unescape(title).split())
            if not title:
                raise ValueError("Engineering article has an empty title")
            url = urljoin(base_url, "/engineering/" + slug)
            article = {"url": url, "title": title, "published_at": _published_at(node.get("publishedOn"))}
            if url in articles and articles[url] != article:
                raise ValueError("Engineering article has conflicting metadata")
            articles[url] = article
    if not articles:
        raise ValueError("No Anthropic engineering articles found")
    return list(articles.values())
