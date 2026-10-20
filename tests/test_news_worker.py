"""Run with: uv run --with feedparser python -m unittest discover -s tests -p test_news_worker.py

All network fixtures are loopback-only and enabled explicitly in Python, never in
worker JSON. No test contacts a publisher or uses the user's persistent cache.
"""
from contextlib import closing, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from email.utils import formatdate
import importlib.util
import io
import json
from pathlib import Path
import socket
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlencode, urlsplit
from xml.sax.saxutils import escape


SPEC = importlib.util.spec_from_file_location("news_worker", Path(__file__).resolve().parents[1] / "news" / "worker.py")
worker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = worker
SPEC.loader.exec_module(worker)


def rss(items):
    body = "".join(
        "<item><title>{}</title><link>{}</link><description>{}</description>"
        "<pubDate>Tue, 14 Nov 2023 22:13:20 GMT</pubDate></item>".format(
            escape(title), escape(url), escape(excerpt))
        for title, url, excerpt in items
    )
    return ("<?xml version='1.0'?><rss version='2.0'><channel><title>Fixture</title>"
            "<link>https://publisher.example/</link><description>Fixture feed</description>"
            + body + "</channel></rss>").encode()


def atom(url):
    return ("<?xml version='1.0'?><feed xmlns='http://www.w3.org/2005/Atom'>"
            "<title>Atom Fixture</title><id>urn:fixture</id><updated>2023-11-14T22:13:20Z</updated>"
            "<entry><id>urn:story</id><title>Other headline</title>"
            "<updated>2023-11-14T22:13:20Z</updated><link href='" + escape(url, {"'": "&apos;"}) + "'/>"
            "<summary type='html'>&lt;p&gt;Atom excerpt with attribution.&lt;/p&gt;</summary>"
            "</entry></feed>").encode()


def anthropic_html(slug="source-control", title="<b>Source control</b>", published="2026-10-13"):
    record = {"articles": [{"_type": "engineeringArticle", "title": title,
                            "publishedOn": published, "slug": {"current": slug}}]}
    flight = json.dumps([1, "6:" + json.dumps(record) + "\n"])
    return ("<!DOCTYPE html><html><script>self.__next_f.push(" + flight + ")</script></html>").encode()


class NewsWorkerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.db = str(Path(self.directory.name) / "news.sqlite3")
        self.now = 1_800_000_000.0
        self.routes = {}
        self.requests = []
        routes, requests = self.routes, self.requests

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append((self.path, dict(self.headers)))
                route = routes.get(self.path, (404, {}, b"Not found"))
                status, headers, body = route(self.headers) if callable(route) else route
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                if "Content-Length" not in headers:
                    self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.fetcher = worker.HTTPFetcher(allow_private=True)
        self.sources = [{"id": "rss", "name": "RSS Fixture", "url": self.origin + "/rss", "enabled": True, "interval_seconds": 300}]
        self.routes["/rss"] = (200, {"Content-Type": "application/rss+xml"}, rss([
            ("Fixture story", self.origin + "/article", "<p>Feed excerpt only.</p>")]))

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def call(self, action, **kwargs):
        result = worker.execute({"action": action, "db": self.db, "sources": self.sources, **kwargs},
                                fetcher=self.fetcher, clock=lambda: self.now)
        self.assertTrue(result["ok"], result)
        return result

    def story(self):
        return self.call("refresh")["snapshot"]["stories"][0]

    def hn_source(self):
        return {"id": "hn", "name": "Hacker News", "kind": "hn_weekly",
                "url": self.origin + "/search", "interval_seconds": 3600}

    def hn_hit(self, identifier, *, points=10, published=None, url=None):
        return {"objectID": str(identifier), "title": f"Story {identifier}", "points": points,
                "created_at_i": int(self.now) if published is None else published,
                "url": self.origin + f"/story/{identifier}" if url is None else url}

    def hn_route(self, hits, *, page=0, pages=1):
        query = urlencode({
            "query": "", "tags": "story",
            "numericFilters": f"created_at_i>={worker.math.ceil(self.now - worker.HN_WEEK_SECONDS)},created_at_i<={worker.math.floor(self.now)}",
            "hitsPerPage": 100, "page": page,
        })
        path = "/search?" + query
        self.routes[path] = (200, {"Content-Type": "application/json", "ETag": '"weekly"'},
                             json.dumps({"hits": hits, "nbPages": pages}).encode())
        return path

    def test_weekly_hn_rolling_bounds_and_hourly_unconditional_requests(self):
        self.sources = [self.hn_source()]
        self.now += 0.5
        oldest = worker.math.ceil(self.now - worker.HN_WEEK_SECONDS)
        newest = int(self.now)
        self.hn_route([self.hn_hit(1, published=oldest), self.hn_hit(2, published=newest),
                       self.hn_hit(3, published=oldest - 1), self.hn_hit(4, published=newest + 1)])
        first = self.call("refresh")["snapshot"]
        self.assertEqual({s["sources"][0]["guid"] for s in first["stories"]}, {"1", "2"})
        self.assertEqual(first["feeds"][0]["next_refresh"], self.now + 3600)
        query = parse_qs(urlsplit(self.requests[0][0]).query, keep_blank_values=True)
        self.assertEqual(query, {"query": [""], "tags": ["story"], "hitsPerPage": ["100"], "page": ["0"],
                                 "numericFilters": [f"created_at_i>={oldest},created_at_i<={newest}"]})
        self.assertEqual(self.requests[0][1]["Accept"], "application/json")
        self.now += 3599
        self.call("refresh")
        self.assertEqual(len(self.requests), 1)
        self.now += 1
        self.hn_route([self.hn_hit(2)])
        refreshed = self.call("refresh")["snapshot"]
        self.assertEqual(len(self.requests), 2)
        self.assertNotEqual(self.requests[0][0], self.requests[1][0])
        self.assertNotIn("If-None-Match", self.requests[1][1])
        self.assertNotIn("If-Modified-Since", self.requests[1][1])
        self.assertEqual(refreshed["stories"][0]["id"], next(
            s["id"] for s in first["stories"] if s["sources"][0]["guid"] == "2"))

    def test_weekly_hn_rank_limit_and_deterministic_ties(self):
        self.sources = [self.hn_source()]
        hits = [self.hn_hit(i, points=i, published=int(self.now) - i) for i in range(1, 106)]
        hits.extend([self.hn_hit(200, points=105, published=int(self.now) - 105),
                     self.hn_hit(201, points=105, published=int(self.now) - 1)])
        self.hn_route(list(reversed(hits)))
        snapshot = self.call("refresh")["snapshot"]
        stories = snapshot["stories"]
        self.assertEqual(len(stories), 100)
        ranked = sorted(stories, key=lambda s: s["sources"][0]["rank"])
        self.assertEqual([s["sources"][0]["rank"] for s in ranked], list(range(1, 101)))
        self.assertEqual([s["sources"][0]["guid"] for s in ranked[:4]], ["201", "105", "200", "104"])
        self.assertEqual([s["published_at"] for s in stories],
                         sorted((s["published_at"] for s in stories), reverse=True))
        first_ranks = {s["id"]: s["sources"][0]["rank"] for s in stories}
        self.hn_route(hits)
        again = self.call("refresh", force=True)["snapshot"]["stories"]
        self.assertEqual({s["id"]: s["sources"][0]["rank"] for s in again}, first_ranks)

    def test_weekly_hn_pages_past_invalid_links_and_canonical_duplicates(self):
        self.sources = [self.hn_source()]
        hits = [self.hn_hit(i, points=1000 - i) for i in range(1, 101)]
        hits[0]["url"] = "javascript:unsafe()"
        hits[1]["url"] = hits[2]["url"] + "?utm_source=hn"
        self.hn_route(hits, pages=2)
        self.hn_route([self.hn_hit(101, url=""), self.hn_hit(102)], page=1, pages=2)
        stories = self.call("refresh")["snapshot"]["stories"]
        self.assertEqual(len(stories), 100)
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(parse_qs(urlsplit(self.requests[1][0]).query)["page"], ["1"])
        duplicate = next(s for s in stories if s["url"] == self.origin + "/story/3")
        self.assertEqual(duplicate["sources"][0]["guid"], "2")
        self_post = next(s for s in stories if s["sources"][0]["guid"] == "101")
        self.assertEqual(self_post["url"], "https://news.ycombinator.com/item?id=101")

    def test_weekly_hn_preserves_canonical_story_and_other_source_when_expiring(self):
        rss_story = self.story()
        self.sources.append(self.hn_source())
        submitted = int(self.now) - worker.HN_WEEK_SECONDS + 60
        self.hn_route([self.hn_hit(1, published=submitted, url=rss_story["url"] + "?utm_source=hn"),
                       self.hn_hit(2, published=submitted)])
        stories = self.call("refresh")["snapshot"]["stories"]
        shared = next(s for s in stories if s["id"] == rss_story["id"])
        self.assertEqual(shared["published_at"], rss_story["published_at"])
        self.assertEqual(shared["first_seen_at"], rss_story["first_seen_at"])
        self.assertEqual(shared["title"], rss_story["title"])
        self.assertEqual(next(s for s in shared["sources"] if s["id"] == "rss"), rss_story["sources"][0])
        hn = next(s for s in shared["sources"] if s["id"] == "hn")
        self.assertEqual(hn["published_at"], submitted)
        self.assertIsInstance(hn["rank"], int)
        self.now += 61
        expired = self.call("snapshot")["snapshot"]["stories"]
        self.assertEqual(expired, [rss_story])
        with closing(sqlite3.connect(self.db)) as database:
            self.assertEqual(database.execute("SELECT count(*) FROM story_sources WHERE source_id='hn'").fetchone()[0], 2)
            self.assertEqual(database.execute("SELECT title FROM stories WHERE id=?", (shared["id"],)).fetchone()[0],
                             rss_story["title"])

    def test_weekly_hn_successful_empty_result_replaces_only_its_memberships(self):
        rss_story = self.story()
        self.sources.append(self.hn_source())
        self.hn_route([self.hn_hit(1, url=rss_story["url"]), self.hn_hit(2)])
        self.call("refresh")
        self.hn_route([])
        snapshot = self.call("refresh", force=True)["snapshot"]
        self.assertEqual(snapshot["stories"], [rss_story])
        self.assertIsNone(snapshot["feeds"][1]["error"])
        with closing(sqlite3.connect(self.db)) as database:
            self.assertEqual(database.execute("SELECT count(*) FROM story_sources WHERE source_id='hn'").fetchone()[0], 0)
            self.assertEqual(database.execute("SELECT count(*) FROM stories").fetchone()[0], 2)

    def test_weekly_hn_payload_and_network_failures_preserve_edition(self):
        self.sources = [self.hn_source()]
        path = self.hn_route([self.hn_hit(1)])
        first = self.call("refresh")["snapshot"]
        invalid_hit = self.hn_hit(2)
        invalid_hit["points"] = True
        failures = [
            (503, {}, b"Unavailable"), (304, {}, b""),
            (200, {}, b"not JSON"), (200, {}, b'{"hits":{}}'),
            (200, {}, json.dumps({"hits": [self.hn_hit(3), invalid_hit]}).encode()),
            (200, {}, b'{"hits":[],"nbPages":true}'),
            (200, {}, b"x" * (worker.MAX_FEED_BYTES + 1)),
        ]
        for route in failures:
            with self.subTest(route=route[:2]):
                self.routes[path] = route
                snapshot = self.call("refresh", force=True)["snapshot"]
                self.assertEqual(snapshot["stories"], first["stories"])
                self.assertEqual(snapshot["feeds"][0]["last_success"], first["feeds"][0]["last_success"])
                self.assertTrue(snapshot["feeds"][0]["error"])
        self.hn_route([self.hn_hit(3)], pages=2)
        next_path = self.hn_route([], page=1, pages=2)
        self.routes[next_path] = (200, {}, b'{"hits":null}')
        snapshot = self.call("refresh", force=True)["snapshot"]
        self.assertEqual(snapshot["stories"], first["stories"])
        self.assertTrue(snapshot["feeds"][0]["error"])

    def test_weekly_hn_membership_replacement_rolls_back_on_write_failure(self):
        self.sources = [self.hn_source()]
        self.hn_route([self.hn_hit(1)])
        first = self.call("refresh")["snapshot"]
        with closing(sqlite3.connect(self.db)) as database:
            database.execute("""CREATE TRIGGER fail_weekly_insert BEFORE INSERT ON story_sources
                WHEN NEW.rank=2 BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END""")
            database.commit()
        self.hn_route([self.hn_hit(2), self.hn_hit(3)])
        snapshot = self.call("refresh", force=True)["snapshot"]
        self.assertEqual(snapshot["stories"], first["stories"])
        self.assertIn("fixture write failure", snapshot["feeds"][0]["error"])
        with closing(sqlite3.connect(self.db)) as database:
            self.assertEqual(database.execute("SELECT count(*) FROM stories").fetchone()[0], 1)

    def test_weekly_hn_migrates_legacy_frontpage_without_losing_shared_cache(self):
        self.sources.append({"id": "hn", "name": "Hacker News", "url": self.origin + "/frontpage"})
        self.routes["/frontpage"] = (200, {"ETag": '"frontpage"'}, rss([
            ("Shared", self.origin + "/article", ""), ("Former frontpage", self.origin + "/former", "")]))
        legacy = self.call("refresh")["snapshot"]
        shared = next(s for s in legacy["stories"] if s["url"] == self.origin + "/article")
        with closing(sqlite3.connect(self.db)) as database:
            database.execute("ALTER TABLE feeds DROP COLUMN kind")
            database.execute("ALTER TABLE story_sources DROP COLUMN rank")
            database.execute("ALTER TABLE story_sources DROP COLUMN published_at")
            database.commit()
        self.sources[1] = self.hn_source()
        before_refresh = self.call("snapshot")["snapshot"]
        self.assertEqual(before_refresh["stories"], legacy["stories"])
        failed = self.call("refresh")["snapshot"]
        self.assertEqual(failed["stories"], legacy["stories"])
        self.assertTrue(failed["feeds"][1]["error"])
        self.hn_route([self.hn_hit(100, url=self.origin + "/new")])
        snapshot = self.call("refresh", force=True)["snapshot"]
        self.assertEqual({s["url"] for s in snapshot["stories"]}, {self.origin + "/new", shared["url"]})
        remaining = next(s for s in snapshot["stories"] if s["id"] == shared["id"])
        self.assertEqual([s["id"] for s in remaining["sources"]], ["rss"])
        self.assertEqual(remaining["title"], shared["title"])
        self.assertEqual(remaining["first_seen_at"], shared["first_seen_at"])
        with closing(sqlite3.connect(self.db)) as database:
            self.assertEqual(database.execute("SELECT kind FROM feeds WHERE id='hn'").fetchone()[0], "hn_weekly")
            self.assertEqual(database.execute("SELECT count(*) FROM story_sources WHERE source_id='hn'").fetchone()[0], 1)
            self.assertEqual(database.execute("SELECT count(*) FROM stories").fetchone()[0], 3)

    def test_weekly_hn_old_canonical_dates_survive_snapshot_and_cache_caps(self):
        shared = self.story()
        self.sources.append(self.hn_source())
        self.hn_route([self.hn_hit(1, url=shared["url"])])
        self.routes["/rss"] = (200, {}, rss([
            (f"Recent {i}", self.origin + f"/recent/{i}", "") for i in range(5)]))
        with closing(sqlite3.connect(self.db)) as database:
            database.execute("UPDATE stories SET published_at=1 WHERE id=?", (shared["id"],))
            database.commit()
        with patch.object(worker, "MAX_SNAPSHOT", 2), patch.object(worker, "MAX_STORIES", 3):
            snapshot = self.call("refresh", force=True)["snapshot"]
        self.assertEqual(len(snapshot["stories"]), 2)
        self.assertEqual(snapshot["stories"][-1]["id"], shared["id"])
        self.assertEqual(snapshot["stories"][-1]["published_at"], 1)
        self.assertEqual(next(s for s in snapshot["stories"][-1]["sources"] if s["id"] == "hn")["rank"], 1)
        with closing(sqlite3.connect(self.db)) as database:
            self.assertEqual(database.execute("SELECT count(*) FROM stories").fetchone()[0], 3)

    def test_weekly_hn_uses_public_only_fetcher_by_default(self):
        self.sources = [self.hn_source()]
        result = worker.execute({"action": "refresh", "db": self.db, "sources": self.sources},
                                clock=lambda: self.now)
        self.assertTrue(result["ok"])
        self.assertIn("Private or local", result["snapshot"]["feeds"][0]["error"])
        self.assertEqual(self.requests, [])

    def test_source_kind_defaults_to_rss_and_rejects_unknown_adapters(self):
        self.assertEqual(worker.source_config(self.sources)[0]["kind"], "rss")
        self.assertEqual(worker.source_config([self.hn_source()])[0]["kind"], "hn_weekly")
        for invalid in ["other", "", None, {}]:
            with self.subTest(kind=invalid), self.assertRaisesRegex(worker.NewsError, "source kind"):
                worker.source_config([{**self.sources[0], "kind": invalid}])

    def test_ten_sources_and_engineering_configuration(self):
        sources = [{**self.sources[0], "id": f"source-{index}"} for index in range(10)]
        self.assertEqual(len(worker.source_config(sources)), 10)
        with self.assertRaisesRegex(worker.NewsError, "at most"):
            worker.source_config(sources + [{**self.sources[0], "id": "overflow"}])
        self.assertEqual(worker.source_config([
            {**self.sources[0], "kind": "anthropic_engineering"}])[0]["kind"], "anthropic_engineering")
        self.assertEqual(worker.source_config([
            {**self.sources[0], "category": "Engineering"}])[0]["category"], "engineering")
        for invalid in [None, [], True, "x" * 121]:
            with self.subTest(category=invalid), self.assertRaisesRegex(worker.NewsError, "source category"):
                worker.source_config([{**self.sources[0], "category": invalid}])

    def test_engineering_category_filter_precedes_entry_limit(self):
        self.sources = [{**self.sources[0], "id": "openai-engineering",
                         "name": "OpenAI Engineering", "category": "Engineering"}]
        items = []
        for index in range(worker.MAX_FEED_ENTRIES):
            items.append(f"<item><title>Engineering headline {index}</title>"
                         f"<link>https://openai.com/index/research-{index}</link>"
                         "<category>Research</category><category>Engineering News</category></item>")
        items.append("<item><title>Engineering without category</title>"
                     "<link>https://openai.com/index/no-category</link></item>")
        for index in range(worker.MAX_FEED_ENTRIES + 1):
            items.append(f"<item><title>Storage {index}</title>"
                         f"<link>https://openai.com/index/storage-{index}</link>"
                         "<category>Company</category><category>eNgInEeRiNg</category>"
                         "<pubDate>Tue, 14 Nov 2023 22:13:20 GMT</pubDate></item>")
        body = rss([]).replace(b"</channel>", "".join(items).encode() + b"</channel>")
        self.routes["/rss"] = (200, {}, body)
        snapshot = self.call("refresh")["snapshot"]
        self.assertIsNone(snapshot["feeds"][0]["error"])
        self.assertEqual(len(snapshot["stories"]), worker.MAX_FEED_ENTRIES)
        self.assertEqual({story["url"] for story in snapshot["stories"]},
                         {f"https://openai.com/index/storage-{index}" for index in range(worker.MAX_FEED_ENTRIES)})
        self.assertTrue(all(story["published_at"] == 1_700_000_000 for story in snapshot["stories"]))

    def test_rolling_window_expires_cached_memberships_without_hiding_other_feeds(self):
        window = 90 * 86400
        entries = []
        for slug, stamp in [("boundary", self.now - window), ("old", self.now - window - 1),
                            ("recent", self.now - 1), ("future", self.now + 1), ("undated", None)]:
            date = "" if stamp is None else f"<pubDate>{formatdate(stamp, usegmt=True)}</pubDate>"
            entries.append(f"<item><title>{slug}</title><link>{self.origin}/{slug}</link>"
                           f"<category>Engineering</category>{date}</item>")
        self.routes["/window"] = (200, {}, rss([]).replace(
            b"</channel>", "".join(entries).encode() + b"</channel>"))
        self.routes["/other"] = (200, {}, rss([("Other feed", self.origin + "/boundary", "")]))
        self.sources = [
            {"id": "openai-engineering", "name": "OpenAI Engineering", "url": self.origin + "/window",
             "category": "Engineering", "window_days": 90},
            {"id": "other", "name": "Other", "url": self.origin + "/other"},
        ]
        initial = self.call("refresh")["snapshot"]
        by_url = {story["url"]: story for story in initial["stories"]}
        self.assertEqual(set(by_url), {self.origin + "/boundary", self.origin + "/recent"})
        self.assertEqual({source["id"] for source in by_url[self.origin + "/boundary"]["sources"]},
                         {"openai-engineering", "other"})
        requests = len(self.requests)
        self.now += 2
        expired = self.call("snapshot")["snapshot"]
        boundary = next(story for story in expired["stories"] if story["url"].endswith("/boundary"))
        self.assertEqual([source["id"] for source in boundary["sources"]], ["other"])
        self.assertEqual(len(self.requests), requests, "Expiration must not require a network refresh")
        self.now += window
        self.assertEqual([story["url"] for story in self.call("snapshot")["snapshot"]["stories"]],
                         [self.origin + "/boundary"])

    def test_anthropic_html_and_claude_rss_keep_independent_caches_and_errors(self):
        self.sources = [
            {"id": "anthropic-engineering", "name": "Anthropic Engineering", "kind": "anthropic_engineering",
             "url": self.origin + "/engineering", "tab": "anthropic", "tab_name": "Anthropic"},
            {"id": "claude-dev", "name": "claude.dev", "url": self.origin + "/claude.xml",
             "tab": "anthropic", "tab_name": "Anthropic"},
        ]
        self.routes["/engineering"] = (200, {"ETag": '"engineering"'}, anthropic_html())
        self.routes["/claude.xml"] = (200, {"ETag": '"claude"'}, rss([
            ("Code review", "https://claude.dev/blog/code-review/", "")]))
        first = self.call("refresh")["snapshot"]
        self.assertEqual(len(first["stories"]), 2)
        self.assertTrue(all(feed["error"] is None for feed in first["feeds"]))
        engineering = next(story for story in first["stories"] if story["sources"][0]["id"] == "anthropic-engineering")
        self.assertEqual(engineering["title"], "Source control")
        self.assertEqual(engineering["url"], self.origin + "/engineering/source-control")
        self.assertEqual(engineering["published_at"], worker.calendar.timegm((2026, 10, 13, 0, 0, 0)))
        self.assertEqual(engineering["sources"][0]["name"], "Anthropic Engineering")
        claude = next(story for story in first["stories"] if story["sources"][0]["id"] == "claude-dev")
        self.assertEqual(claude["url"], "https://claude.dev/blog/code-review/")
        self.assertEqual(claude["published_at"], 1_700_000_000)
        self.assertEqual(claude["sources"][0]["name"], "claude.dev")
        self.call("refresh")
        self.assertEqual(len(self.requests), 2, "Each new feed retains the hourly refresh interval")
        self.now += 3600
        self.routes["/engineering"] = (200, {"ETag": '"engineering-next"'}, anthropic_html("new-engineering"))
        self.routes["/claude.xml"] = (503, {}, b"Unavailable")
        second = self.call("refresh")["snapshot"]
        self.assertEqual(len(second["stories"]), 3)
        self.assertIn(claude, second["stories"])
        self.assertIsNone(second["feeds"][0]["error"])
        self.assertIn("503", second["feeds"][1]["error"])
        self.assertEqual(self.requests[2][1]["If-None-Match"], '"engineering"')
        self.assertEqual(self.requests[3][1]["If-None-Match"], '"claude"')
        self.now += 3600
        self.routes["/engineering"] = (200, {}, b"<!DOCTYPE html><html>No usable data</html>")
        self.routes["/claude.xml"] = (200, {"ETag": '"claude-next"'}, rss([
            ("New Claude", "https://claude.dev/blog/new-claude/", "")]))
        third = self.call("refresh")["snapshot"]
        self.assertEqual(len(third["stories"]), 4)
        self.assertIn(engineering, third["stories"])
        self.assertTrue(third["feeds"][0]["error"])
        self.assertIsNone(third["feeds"][1]["error"])
        self.assertEqual(third["feeds"][0]["last_success"], second["feeds"][0]["last_success"])
        self.assertEqual(self.requests[4][1]["If-None-Match"], '"engineering-next"')
        self.assertEqual(self.requests[5][1]["If-None-Match"], '"claude"')
        self.now += 3600
        self.routes["/engineering"] = self.routes["/claude.xml"] = (304, {}, b"")
        cached = self.call("refresh")["snapshot"]
        self.assertEqual(cached["stories"], third["stories"])
        self.assertTrue(all(feed["error"] is None for feed in cached["feeds"]))

    def test_rss_atom_deduplicate_preserving_sources_and_plain_text(self):
        self.routes["/rss"] = (200, {}, rss([
            ("<b>Readable headline</b>", self.origin + "/article?utm_source=rss#top",
             "<p>Safe excerpt.</p><script>steal()</script><img src='http://localhost/secret'>")]))
        self.sources.append({"id": "atom", "name": "Atom Fixture", "url": self.origin + "/atom", "enabled": True})
        self.routes["/atom"] = (200, {}, atom(self.origin + "/article"))
        snapshot = self.call("refresh")["snapshot"]
        self.assertEqual(len(snapshot["stories"]), 1)
        story = snapshot["stories"][0]
        self.assertEqual(story["title"], "Readable headline")
        self.assertEqual(story["url"], self.origin + "/article")
        self.assertEqual({source["id"] for source in story["sources"]}, {"rss", "atom"})
        self.assertEqual(story["published_at"], 1_700_000_000)
        self.assertNotIn("excerpt", story)
        self.assertNotIn("text", story)
        self.assertEqual([path for path, _ in self.requests], ["/rss", "/atom"])

    def test_conditional_fetch_due_schedule_and_snapshot_are_cache_only(self):
        payload = self.routes["/rss"][2]

        def conditional(headers):
            if headers.get("If-None-Match") == '"fixture-v1"':
                return 304, {}, b""
            return 200, {"ETag": '"fixture-v1"', "Last-Modified": "Tue, 14 Nov 2023 22:13:20 GMT"}, payload

        self.routes["/rss"] = conditional
        initial = self.call("refresh")["snapshot"]
        self.now += 50
        self.assertEqual(self.call("snapshot")["snapshot"]["stories"], initial["stories"])
        self.call("refresh")
        self.assertEqual(len(self.requests), 1)
        self.now += 300
        refreshed = self.call("refresh")["snapshot"]
        self.assertEqual(refreshed["stories"], initial["stories"])
        self.assertEqual(self.requests[-1][1]["If-None-Match"], '"fixture-v1"')
        self.assertEqual(self.requests[-1][1]["If-Modified-Since"], "Tue, 14 Nov 2023 22:13:20 GMT")
        self.assertEqual(refreshed["feeds"][0]["last_success"], self.now)
        self.assertEqual(refreshed["feeds"][0]["next_refresh"], self.now + 300)
        self.call("refresh", force=True)
        self.assertEqual(len(self.requests), 3)

    def test_feed_failures_preserve_cached_stories_and_last_success(self):
        first = self.call("refresh")["snapshot"]
        for route in [(503, {}, b"Unavailable"), (200, {}, b"<html>not a feed</html>"),
                      (200, {}, b"<!DOCTYPE rss [<!ENTITY x 'bad'>]><rss version='2.0'/>"),
                      (200, {}, "<!DOCTYPE rss [<!ENTITY x 'bad'>]><rss version='2.0'/>".encode("utf-16"))]:
            with self.subTest(route=route):
                self.routes["/rss"] = route
                self.now += 400
                snapshot = self.call("refresh")["snapshot"]
                self.assertEqual(snapshot["stories"], first["stories"])
                self.assertEqual(snapshot["feeds"][0]["last_success"], first["feeds"][0]["last_success"])
                self.assertTrue(snapshot["feeds"][0]["error"])

    def test_invalid_not_modified_without_cache_is_failure(self):
        self.routes["/rss"] = (304, {}, b"")
        snapshot = self.call("refresh")["snapshot"]
        self.assertEqual(snapshot["stories"], [])
        self.assertIsNone(snapshot["feeds"][0]["last_success"])
        self.assertIn("without a cached feed", snapshot["feeds"][0]["error"])

    def test_reader_cache_migration_preserves_headlines_and_sources(self):
        self.sources.append(self.hn_source())
        self.hn_route([self.hn_hit(1, url=self.origin + "/article")])
        before = self.call("refresh")["snapshot"]
        story = before["stories"][0]
        with closing(sqlite3.connect(self.db)) as database:
            database.execute("ALTER TABLE stories ADD COLUMN is_read INTEGER NOT NULL DEFAULT 0")
            database.execute("ALTER TABLE stories ADD COLUMN excerpt TEXT NOT NULL DEFAULT ''")
            database.execute("UPDATE stories SET is_read=1, excerpt='Old reader excerpt'")
            database.execute("""CREATE TABLE articles (
                story_id INTEGER PRIMARY KEY REFERENCES stories(id) ON DELETE CASCADE,
                text TEXT NOT NULL, author TEXT, status TEXT NOT NULL, error TEXT,
                fetched_at REAL NOT NULL, accessed_at REAL NOT NULL)""")
            database.execute("INSERT INTO articles VALUES(?,? ,NULL,'full',NULL,?,?)",
                             (story["id"], "Old cached body", self.now, self.now))
            memberships = database.execute("SELECT * FROM story_sources ORDER BY source_id").fetchall()
            feeds = database.execute("SELECT * FROM feeds ORDER BY id").fetchall()
            sequence = database.execute("SELECT seq FROM sqlite_sequence WHERE name='stories'").fetchone()
            database.commit()
        snapshot = self.call("snapshot")["snapshot"]
        self.assertEqual(snapshot, before)
        self.assertEqual(self.call("snapshot")["snapshot"], before)
        with closing(sqlite3.connect(self.db)) as database:
            columns = {row[1] for row in database.execute("PRAGMA table_info(stories)")}
            self.assertNotIn("is_read", columns)
            self.assertNotIn("excerpt", columns)
            self.assertIsNone(database.execute("SELECT name FROM sqlite_master WHERE name='articles'").fetchone())
            self.assertEqual(database.execute("SELECT * FROM story_sources ORDER BY source_id").fetchall(), memberships)
            self.assertEqual(database.execute("SELECT * FROM feeds ORDER BY id").fetchall(), feeds)
            self.assertEqual(database.execute("SELECT seq FROM sqlite_sequence WHERE name='stories'").fetchone(), sequence)
        self.assertEqual(len(self.requests), 2)

    def test_article_action_is_rejected_without_fetching_or_changing_cache(self):
        story = self.story()
        result = worker.execute({"action": "article", "db": self.db, "sources": self.sources, "id": story["id"]},
                                fetcher=self.fetcher, clock=lambda: self.now)
        self.assertEqual(result, {"ok": False, "error": "Unknown News action"})
        self.assertEqual(self.call("snapshot")["snapshot"]["stories"], [story])
        self.assertEqual([path for path, _ in self.requests], ["/rss"])

    def test_feed_content_is_ignored_while_headline_and_guid_are_preserved(self):
        body = rss([("Feed article", self.origin + "/article", "Short excerpt")])
        body = body.replace(b"<rss version='2.0'>",
                            b"<rss version='2.0' xmlns:content='http://purl.org/rss/1.0/modules/content/'>")
        body = body.replace(b"</item>", b"<guid>stable-publisher-id</guid><content:encoded><![CDATA["
                            b"<p>The publisher supplied the complete article in its feed.</p>"
                            b"<script>untrusted()</script>]]></content:encoded></item>")
        self.routes["/rss"] = (200, {}, body)
        story = self.story()
        self.assertEqual(story["title"], "Feed article")
        self.assertNotIn("text", story)
        self.assertNotIn("excerpt", story)
        self.assertEqual(story["sources"][0]["guid"], "stable-publisher-id")
        self.assertEqual([path for path, _ in self.requests], ["/rss"])

    def test_unsafe_feed_links_are_ignored(self):
        self.routes["/rss"] = (200, {}, rss([
            ("Script", "javascript:alert(1)", "bad"), ("File", "file:///etc/passwd", "bad"),
            ("Credentials", "https://user:secret@publisher.example/story", "bad"),
            ("Relative", "/article#fragment", "good")]))
        stories = self.call("refresh")["snapshot"]["stories"]
        self.assertEqual(len(stories), 1)
        self.assertEqual(stories[0]["url"], self.origin + "/article")

    def test_default_network_rejects_local_addresses_even_with_request_override(self):
        result = worker.execute({"action": "refresh", "db": self.db, "sources": self.sources, "allow_private": True},
                                clock=lambda: self.now)
        self.assertTrue(result["ok"])
        self.assertIn("Private or local", result["snapshot"]["feeds"][0]["error"])
        self.assertEqual(self.requests, [])

    def test_redirect_target_revalidated_without_requesting_private_destination(self):
        fixture_port = self.server.server_port

        class FixtureOriginOnly(worker.HTTPFetcher):
            def addresses(self, host, port):
                # Only this exact test fixture origin is exempt; all redirects use production checks.
                if host == "127.0.0.1" and port == fixture_port:
                    return ["127.0.0.1"]
                return super().addresses(host, port)

        self.routes["/redirect"] = (302, {"Location": "http://127.0.0.1:1/secret"}, b"")
        with self.assertRaisesRegex(worker.NewsError, "Private or local"):
            FixtureOriginOnly()(self.origin + "/redirect", {}, 1024)
        self.assertEqual([path for path, _ in self.requests], ["/redirect"])

    def test_dns_rejects_any_nonpublic_answer_and_pins_public_answers(self):
        for address in ["127.0.0.1", "10.0.0.1", "169.254.169.254", "::1", "fc00::1", "::ffff:127.0.0.1", "224.0.0.1"]:
            with self.subTest(address=address):
                resolver = lambda *args, address=address, **kwargs: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("8.8.8.8", 80)),
                                                                       (socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 80))]
                with self.assertRaises(worker.NewsError):
                    worker.HTTPFetcher(resolver=resolver).addresses("publisher.example", 80)
        calls = []

        def resolver(host, port, **kwargs):
            calls.append(host)
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("8.8.8.8", port))]

        with patch.object(worker.http.client, "HTTPConnection") as connection:
            response = connection.return_value.getresponse.return_value
            response.status = 200
            response.getheaders.return_value = []
            response.read.return_value = b"fixture"
            worker.HTTPFetcher(resolver=resolver)("http://publisher.example/story", {}, 1024)
            connection.assert_called_once_with("8.8.8.8", 80, timeout=5)
            self.assertEqual(connection.return_value.request.call_args.kwargs["headers"]["Host"], "publisher.example")
        self.assertEqual(calls, ["publisher.example"])

    def test_response_size_encoding_and_redirect_bounds(self):
        self.routes["/large"] = (200, {}, b"a" * 33)
        self.routes["/unknown-size"] = (200, {"Content-Length": ""}, b"b" * 33)
        self.routes["/compressed"] = (200, {"Content-Encoding": "gzip"}, b"compressed")
        self.routes["/loop"] = (302, {"Location": "/loop"}, b"")
        for path in ["/large", "/unknown-size", "/compressed", "/loop"]:
            with self.subTest(path=path), self.assertRaises(worker.NewsError):
                self.fetcher(self.origin + path, {}, 32)
        self.assertEqual(sum(path == "/loop" for path, _ in self.requests), 4)

    def test_disabled_sources_never_fetch_or_appear_in_story_results(self):
        self.story()
        self.sources[0]["enabled"] = False
        snapshot = self.call("refresh", force=True)["snapshot"]
        self.assertEqual(snapshot["stories"], [])
        self.assertEqual(len(self.requests), 1)
        self.sources[0]["enabled"] = True
        self.assertEqual(len(self.call("snapshot")["snapshot"]["stories"]), 1)

    def test_ingestion_snapshot_and_persistent_story_limits(self):
        self.routes["/rss"] = (200, {}, rss([(f"Story {i}", self.origin + f"/story/{i}", "x" * 3000) for i in range(6)]))
        with patch.object(worker, "MAX_FEED_ENTRIES", 5), patch.object(worker, "MAX_STORIES", 3), patch.object(worker, "MAX_SNAPSHOT", 2):
            snapshot = self.call("refresh")["snapshot"]
        self.assertEqual(len(snapshot["stories"]), 2)
        with closing(sqlite3.connect(self.db)) as database:
            self.assertEqual(database.execute("SELECT count(*) FROM stories").fetchone()[0], 3)
            self.assertEqual(database.execute("SELECT count(*) FROM story_sources").fetchone()[0], 3)
            self.assertEqual(database.execute("SELECT seq FROM sqlite_sequence WHERE name='stories'").fetchone()[0], 5)

    def test_deadline_interrupts_work_and_restores_alarm_handler(self):
        previous = worker.signal.getsignal(worker.signal.SIGALRM)
        with self.assertRaisesRegex(worker.NewsError, "timed out"):
            with worker.deadline(30):
                worker.signal.raise_signal(worker.signal.SIGALRM)
        self.assertEqual(worker.signal.getsignal(worker.signal.SIGALRM), previous)
        self.assertEqual(worker.signal.getitimer(worker.signal.ITIMER_REAL)[0], 0)

    def test_socket_timeout_retains_cache_and_reports_source_failure(self):
        previous = self.call("refresh")["snapshot"]
        self.now += 400
        with patch.object(worker.http.client, "HTTPConnection") as connection:
            connection.return_value.getresponse.side_effect = socket.timeout("Fixture socket timeout")
            snapshot = self.call("refresh")["snapshot"]
        self.assertEqual(snapshot["stories"], previous["stories"])
        self.assertEqual(snapshot["feeds"][0]["last_success"], previous["feeds"][0]["last_success"])
        self.assertIn("timeout", snapshot["feeds"][0]["error"])

    def test_protocol_errors_and_single_json_stdout(self):
        for request in [{"action": "unknown"}, {"action": "snapshot", "db": "relative.sqlite3"},
                        {"action": "article", "db": self.db, "sources": self.sources, "id": "missing"}]:
            result = worker.execute(request, fetcher=self.fetcher)
            self.assertFalse(result["ok"])
            self.assertTrue(result["error"])
        for payload in [b"not json", b"x" * (worker.MAX_REQUEST + 1)]:
            output = io.StringIO()
            with patch.object(worker.sys, "stdin", io.TextIOWrapper(io.BytesIO(payload))), redirect_stdout(output):
                worker.main()
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertFalse(worker.json.loads(output.getvalue())["ok"])


if __name__ == "__main__":
    unittest.main()
