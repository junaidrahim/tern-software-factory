"""Fetch complete weekly first-submission results from the official arXiv API."""
from __future__ import annotations

from datetime import datetime, timezone
import re
import time
from urllib.parse import urlencode, urlsplit, urlunsplit
from xml.etree import ElementTree

import feedparser


_ATOM = "{http://www.w3.org/2005/Atom}"
_OPEN_SEARCH = "{http://a9.com/-/spec/opensearch/1.1/}"
_PAGE_SIZE = 500
_MAX_RESULTS = 30000
_WEEK_SECONDS = 7 * 86400
_CS_CATEGORIES = frozenset("cs." + suffix for suffix in (
    "AI AR CC CE CG CL CR CV CY DB DC DL DM DS ET FL GL GR GT HC IR IT LG LO "
    "MA MM MS NA NE NI OH OS PF PL RO SC SD SE SI SY"
).split())
_PAPER_ID = re.compile(
    r"(?P<paper>[0-9]{2}(?:0[1-9]|1[0-2])\.[0-9]{4,5}|[A-Za-z][A-Za-z.-]*/[0-9]{7})"
    r"(?:v[1-9][0-9]*)?\Z"
)
_TIMESTAMP = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\Z"
)


def _text(node, tag):
    elements = node.findall(tag)
    if len(elements) != 1 or not elements[0].text or len(elements[0]):
        raise ValueError("arXiv response has missing or invalid metadata")
    return elements[0].text.strip()


def _count(root, name):
    value = _text(root, _OPEN_SEARCH + name)
    if not re.fullmatch(r"[0-9]{1,10}", value):
        raise ValueError("arXiv response has invalid pagination metadata")
    return int(value)


def _page(response, max_bytes):
    if getattr(response, "status", None) != 200:
        raise ValueError(f"arXiv returned unexpected HTTP status {getattr(response, 'status', None)}")
    body = getattr(response, "body", None)
    if not isinstance(body, bytes) or not body or len(body) > max_bytes:
        raise ValueError("arXiv response has invalid or excessive size")
    # Match the worker's XML guard, including UTF-16/32 declarations. Neither
    # parser receives a URL, so the injected safe fetcher is the only network path.
    if re.search(br"<!\s*(?:DOCTYPE|ENTITY)\b", body.replace(b"\x00", b""), re.IGNORECASE):
        raise ValueError("arXiv feed contains unsupported XML declarations")
    try:
        root = ElementTree.fromstring(body)
    except (ElementTree.ParseError, ValueError, LookupError) as error:
        raise ValueError("arXiv returned invalid or incomplete XML") from error
    if root.tag != _ATOM + "feed":
        raise ValueError("arXiv did not return an Atom feed")
    nodes = root.findall(_ATOM + "entry")
    for node in nodes:
        identifier = _text(node, _ATOM + "id")
        if re.match(r"https?://(?:export\.)?arxiv\.org/api/errors(?:[#/?]|$)", identifier):
            raise ValueError("arXiv API error: " + _text(node, _ATOM + "title"))
    parsed = feedparser.parse(body)
    if parsed.get("bozo") or parsed.get("version") != "atom10" or len(parsed.entries) != len(nodes):
        raise ValueError("arXiv returned invalid or incomplete Atom data")
    return root, nodes, parsed.entries


def fetch_week(fetch, url, now, max_bytes):
    """Return every CS first submission in the exact inclusive rolling week.

    API searches have minute precision; publication timestamps enforce the exact
    cutoff afterward. All pages must be present and consistent before returning,
    so callers can replace cached membership atomically, even for an empty week.
    """
    cutoff = now - _WEEK_SECONDS
    lower = datetime.fromtimestamp(cutoff, timezone.utc).strftime("%Y%m%d%H%M")
    upper = datetime.fromtimestamp(now, timezone.utc).strftime("%Y%m%d%H%M")
    endpoint = urlsplit(url)
    start = 0
    total = None
    seen = set()
    entries = []
    while True:
        query = urlencode({
            "search_query": f"cat:cs.* AND submittedDate:[{lower} TO {upper}]",
            "sortBy": "submittedDate", "sortOrder": "descending",
            "start": start, "max_results": _PAGE_SIZE,
        })
        page_url = urlunsplit((endpoint.scheme, endpoint.netloc, endpoint.path, query, ""))
        if start:
            time.sleep(3)
        response = fetch(page_url, {"Accept": "application/atom+xml"}, max_bytes)
        root, nodes, parsed_entries = _page(response, max_bytes)
        page_total = _count(root, "totalResults")
        if page_total > _MAX_RESULTS:
            raise ValueError("arXiv weekly query exceeds the 30000-result API ceiling")
        if total is None:
            total = page_total
        if page_total != total or _count(root, "startIndex") != start:
            raise ValueError("arXiv pagination changed or returned an unexpected page")
        expected = min(_PAGE_SIZE, total - start)
        if len(nodes) != expected:
            raise ValueError("arXiv returned an incomplete result page")
        for node, entry in zip(nodes, parsed_entries):
            identifier = _text(node, _ATOM + "id")
            parts = urlsplit(identifier)
            match = _PAPER_ID.fullmatch(parts.path.removeprefix("/abs/"))
            if (parts.scheme not in {"http", "https"} or parts.netloc != "arxiv.org"
                    or not parts.path.startswith("/abs/") or parts.query or parts.fragment or not match):
                raise ValueError("arXiv entry has an invalid paper ID")
            paper = match.group("paper")
            # Search results represent unique papers, not versions. Overlap can
            # conceal a missing paper even if every page's entry count is correct.
            if paper in seen:
                raise ValueError("arXiv pagination contains a duplicate paper ID")
            seen.add(paper)
            published = _text(node, _ATOM + "published")
            if not _TIMESTAMP.fullmatch(published):
                raise ValueError("arXiv entry has an invalid first-submission timestamp")
            try:
                stamp = datetime.fromisoformat(published.replace("Z", "+00:00")).timestamp()
            except (ValueError, OverflowError, OSError) as error:
                raise ValueError("arXiv entry has an invalid first-submission timestamp") from error
            title = entry.get("title")
            if not isinstance(title, str) or not title.strip():
                raise ValueError("arXiv entry has an invalid title")
            categories = node.findall(_ATOM + "category")
            if not categories or any(not category.get("term") for category in categories):
                raise ValueError("arXiv entry has missing category metadata")
            if not any(category.get("term") in _CS_CATEGORIES for category in categories):
                continue
            if not cutoff <= stamp <= now:
                continue
            canonical = "https://arxiv.org/abs/" + paper
            entries.append({"id": canonical, "link": canonical, "title": " ".join(title.split()),
                            "published_parsed": time.gmtime(stamp)})
        start += len(nodes)
        if start == total:
            break
    entries.sort(key=lambda entry: (entry["published_parsed"], entry["id"]), reverse=True)
    return entries
