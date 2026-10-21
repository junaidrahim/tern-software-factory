"""Offline behavior fixtures for complete rolling-week arXiv CS results."""
import calendar
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
from xml.sax.saxutils import escape


SPEC = importlib.util.spec_from_file_location(
    "arxiv_feed", Path(__file__).resolve().parents[1] / "news" / "arxiv.py"
)
arxiv = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(arxiv)

BASE_URL = "https://export.arxiv.org/api/query"
MAX_BYTES = 2 * 1024 * 1024
NOW = datetime(2026, 10, 20, 12, 34, 56, tzinfo=timezone.utc).timestamp()


def paper(number=1, *, published="2026-10-19T12:00:00Z", updated="2026-10-20T10:00:00Z",
          categories=("cs.AI",), identifier=None, title=" A paper about tools & agents "):
    identifier = identifier if identifier is not None else f"http://arxiv.org/abs/2610.{number:05d}v2"
    published_xml = "" if published is None else f"<published>{escape(published)}</published>"
    return ("<entry>" + f"<id>{escape(identifier)}</id><title>{escape(title)}</title>"
            + published_xml + f"<updated>{escape(updated)}</updated>"
            + '<link href="https://arxiv.org/pdf/2610.00001" rel="related" type="application/pdf"/>'
            + '<arxiv:primary_category term="stat.ML"/>'
            + "".join(f'<category term="{escape(category)}"/>' for category in categories)
            + "</entry>")


def feed(entries=(), *, total=None, start=0):
    entries = list(entries)
    if total is None:
        total = len(entries)
    return ('<?xml version="1.0" encoding="UTF-8"?>'
            '<feed xmlns="http://www.w3.org/2005/Atom" '
            'xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/" '
            'xmlns:arxiv="http://arxiv.org/schemas/atom">'
            '<title>ArXiv Query</title><id>http://arxiv.org/api/query-result</id>'
            '<updated>2026-10-20T00:00:00Z</updated>'
            f'<opensearch:totalResults>{escape(str(total))}</opensearch:totalResults>'
            f'<opensearch:startIndex>{escape(str(start))}</opensearch:startIndex>'
            '<opensearch:itemsPerPage>500</opensearch:itemsPerPage>'
            + "".join(entries) + '</feed>').encode()


class ArxivFeedTests(unittest.TestCase):
    def setUp(self):
        self.sleep = patch.object(arxiv.time, "sleep").start()
        self.addCleanup(patch.stopall)
        self.requests = []

    def fetcher(self, bodies, *, status=200):
        responses = iter(bodies)

        def fetch(url, headers, max_bytes):
            self.requests.append((url, headers, max_bytes))
            return SimpleNamespace(status=status, body=next(responses), headers={}, url=url)

        return fetch

    def parse(self, body, *, status=200, max_bytes=MAX_BYTES):
        return arxiv.fetch_week(self.fetcher([body], status=status), BASE_URL, NOW, max_bytes)

    def test_fetches_every_page_and_returns_canonical_abstract_links(self):
        records = [paper(index, published=f"2026-10-{14 + index % 6:02d}T12:00:00Z")
                   for index in range(1, 1102)]
        bodies = [feed(records[start:start + 500], total=1101, start=start) for start in (0, 500, 1000)]
        result = arxiv.fetch_week(self.fetcher(bodies), BASE_URL, NOW, MAX_BYTES)
        self.assertEqual(len(result), 1101)
        self.assertEqual({entry["link"] for entry in result},
                         {f"https://arxiv.org/abs/2610.{index:05d}" for index in range(1, 1102)})
        self.assertEqual(len({entry["id"] for entry in result}), 1101)
        self.assertTrue(all(entry["id"] == entry["link"] for entry in result))
        self.assertTrue(all(entry["title"] == "A paper about tools & agents" for entry in result))
        timestamps = [calendar.timegm(entry["published_parsed"]) for entry in result]
        self.assertEqual(timestamps, sorted(timestamps, reverse=True))
        self.assertEqual(self.sleep.call_args_list, [unittest.mock.call(3), unittest.mock.call(3)])
        for request, start in zip(self.requests, (0, 500, 1000)):
            url, headers, max_bytes = request
            query = parse_qs(urlsplit(url).query)
            self.assertEqual(query, {
                "search_query": ["cat:cs.* AND submittedDate:[202610131234 TO 202610201234]"],
                "sortBy": ["submittedDate"], "sortOrder": ["descending"],
                "start": [str(start)], "max_results": ["500"],
            })
            self.assertEqual(headers["Accept"], "application/atom+xml")
            self.assertEqual(max_bytes, MAX_BYTES)

    def test_cutoff_and_now_are_inclusive_without_minute_rounding_leaks(self):
        dates = ["2026-10-13T12:34:55Z", "2026-10-13T12:34:56Z", "2026-10-20T12:34:56Z",
                 "2026-10-20T12:34:57Z", "2026-10-13T14:34:56+02:00"]
        result = self.parse(feed(paper(index, published=date) for index, date in enumerate(dates, 1)))
        self.assertEqual({entry["id"] for entry in result},
                         {f"https://arxiv.org/abs/2610.{index:05d}" for index in (2, 3, 5)})
        self.assertEqual([calendar.timegm(entry["published_parsed"]) for entry in result],
                         [NOW, NOW - 7 * 86400, NOW - 7 * 86400])

    def test_old_first_submission_is_not_revived_by_recent_update(self):
        result = self.parse(feed([paper(1, published="2025-01-01T00:00:00Z"), paper(2)]))
        self.assertEqual([entry["link"] for entry in result], ["https://arxiv.org/abs/2610.00002"])

    def test_cross_lists_and_all_cs_subcategories_are_included(self):
        categories = ["AI", "AR", "CC", "CE", "CG", "CL", "CR", "CV", "CY", "DB", "DC", "DL",
                      "DM", "DS", "ET", "FL", "GL", "GR", "GT", "HC", "IR", "IT", "LG", "LO",
                      "MA", "MM", "MS", "NA", "NE", "NI", "OH", "OS", "PF", "PL", "RO", "SC",
                      "SD", "SE", "SI", "SY"]
        records = [paper(index, categories=("stat.ML", "cs." + category))
                   for index, category in enumerate(categories, 1)]
        records += [paper(100 + index, categories=(category,))
                    for index, category in enumerate(("stat.ML", "cs", "cs.*", "cs.INVALID", "CS.AI", "cs.AI.extra"))]
        result = self.parse(feed(records))
        self.assertEqual({entry["id"] for entry in result},
                         {f"https://arxiv.org/abs/2610.{index:05d}" for index in range(1, 41)})

    def test_empty_week_requires_explicit_zero_total(self):
        self.assertEqual(self.parse(feed()), [])
        self.sleep.assert_not_called()
        for body in (feed(total=1), feed().replace(b"<opensearch:totalResults>0</opensearch:totalResults>", b"")):
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.parse(body)

    def test_rejects_missing_or_invalid_first_submission_even_with_recent_update(self):
        for published in (None, "", "not a timestamp", "2026-10-19", "2026-02-30T00:00:00Z",
                          "2026-10-19T12:00:00", "2026-10-19T12:00:00+99:00"):
            with self.subTest(published=published), self.assertRaises(ValueError):
                self.parse(feed([paper(published=published)]))

    def test_rejects_invalid_identity_title_and_missing_categories(self):
        for identifier in ("https://evil.example/abs/2610.00001", "https://arxiv.org/pdf/2610.00001",
                           "https://arxiv.org/abs/not-a-paper", "https://arxiv.org/abs/2613.00001",
                           "https://arxiv.org/abs/2610.00001?download=1",
                           "https://arxiv.org/abs/2610.00001#section", "https://arxiv.org/abs/2610.00001v0",
                           "https://arxiv.org@evil.example/abs/2610.00001"):
            with self.subTest(identifier=identifier), self.assertRaisesRegex(ValueError, "paper ID"):
                self.parse(feed([paper(identifier=identifier)]))
        for record in (paper(title="  "), paper(categories=()), paper(categories=("",))):
            with self.subTest(record=record), self.assertRaises(ValueError):
                self.parse(feed([record]))

    def test_unversioned_and_legacy_ids_resolve_to_abstracts(self):
        result = self.parse(feed([paper(identifier="https://arxiv.org/abs/2610.00001"),
                                  paper(identifier="http://arxiv.org/abs/cs/9901001v3")]))
        self.assertEqual({entry["link"] for entry in result},
                         {"https://arxiv.org/abs/2610.00001", "https://arxiv.org/abs/cs/9901001"})

    def test_api_error_feed_is_not_a_successful_empty_or_partial_week(self):
        error = '<entry><id>http://arxiv.org/api/errors#incorrect_id_format</id><title>Error</title></entry>'
        for body in (feed([error]), feed([paper(), error]),
                     feed([error]).replace(b"<opensearch:totalResults>1</opensearch:totalResults>", b"")):
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "API error"):
                self.parse(body)

    def test_api_ceiling_is_explicit_not_silent_truncation(self):
        with self.assertRaisesRegex(ValueError, "30000"):
            self.parse(feed(total=30001))

    def test_pagination_metadata_is_required_and_numeric(self):
        for total in (-1, "unknown", "1.0", ""):
            with self.subTest(total=total), self.assertRaises(ValueError):
                self.parse(feed([paper()], total=total))
        for body in (feed([paper()], start=1),
                     feed([paper()]).replace(b"<opensearch:startIndex>0</opensearch:startIndex>", b""),
                     feed([paper()]).replace(b"</feed>", b"<opensearch:totalResults>1</opensearch:totalResults></feed>")):
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.parse(body)

    def test_second_page_failure_never_returns_the_first_partial_page(self):
        first = feed([paper(index) for index in range(1, 501)], total=502)
        last = [paper(501), paper(502)]
        broken_pages = [feed(last[:1], total=502, start=500), feed([], total=502, start=500),
                        feed(last, total=502, start=0), feed(last, total=503, start=500),
                        feed(last, total=502, start=500)[:-8],
                        feed([paper(1), paper(502)], total=502, start=500),
                        feed([paper(identifier="https://arxiv.org/abs/2610.00001v3"), paper(502)], total=502, start=500),
                        feed(['<entry><id>http://arxiv.org/api/errors</id><title>Error</title></entry>'], total=502, start=500)]
        for second in broken_pages:
            with self.subTest(second=second[-150:]), self.assertRaises(ValueError):
                arxiv.fetch_week(self.fetcher([first, second]), BASE_URL, NOW, MAX_BYTES)

    def test_duplicate_paper_versions_cannot_hide_missing_search_results(self):
        with self.assertRaisesRegex(ValueError, "duplicate paper ID"):
            self.parse(feed([paper(), paper(identifier="https://arxiv.org/abs/2610.00001v4")]))

    def test_unexpected_status_size_and_non_feed_responses_fail(self):
        for status in (204, 304, 403, 429, 500):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "HTTP status"):
                self.parse(feed(), status=status)
        with self.assertRaisesRegex(ValueError, "size"):
            self.parse(feed([paper()]), max_bytes=10)
        for body in (b"", "not bytes", b"<html>Denied</html>", b"<feed>", b"\xff", b"<rss/>",
                     feed().replace(b'encoding="UTF-8"', b'encoding="unknown-encoding"'),
                     feed([paper()])[:-7], feed([paper()]).replace(b"</entry>", b"")):
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.parse(body)

    def test_dangerous_xml_declarations_are_rejected_before_parsing(self):
        declarations = [
            '<!DOCTYPE feed [<!ENTITY local SYSTEM "file:///etc/passwd">]>',
            '<!DOCTYPE feed SYSTEM "https://evil.example/external.dtd">',
            '<!ENTITY remote SYSTEM "https://evil.example/entity">',
        ]
        for declaration in declarations:
            text = declaration + feed().decode().split("?>", 1)[1]
            for encoding in ("utf-8", "utf-16", "utf-32"):
                with self.subTest(declaration=declaration, encoding=encoding):
                    with self.assertRaisesRegex(ValueError, "unsupported XML declarations"):
                        self.parse(text.encode(encoding))


if __name__ == "__main__":
    unittest.main()
