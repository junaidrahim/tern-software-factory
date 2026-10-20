"""Offline fixtures for the official Anthropic engineering index's Flight data."""
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "anthropic_feed", Path(__file__).resolve().parents[1] / "news" / "anthropic.py"
)
anthropic = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(anthropic)

BASE_URL = "https://www.anthropic.com/engineering"


def article(slug="redesigning-source-control", title=" Redesigning source control at Anthropic", date="2026-10-13"):
    return {
        "_type": "engineeringArticle",
        "title": title,
        "publishedOn": date,
        "slug": {"_type": "slug", "current": slug},
        "subjects": [{"_type": "tag", "label": "Developer Tools"}],
    }


def flight_script(data):
    # JSON string inside the push transports newline-delimited Flight records.
    payload = json.dumps([1, data], ensure_ascii=False).replace("<", "\\u003c")
    return '<script nonce="publisher-nonce">self.__next_f.push(' + payload + ')</script>'


def index_page(articles, *, visible="", other_sections=None, split_at=None):
    record = ["$", "$L17", None, {
        "children": [["$", "$L18", None, {
            "siteSettings": {"headerNavigation": [{"title": "News", "url": "/news"}]},
            "page": {"sections": [
                {"_type": "articleList", "articles": articles},
                {"_type": "cta", "heading": "Build the \u2028future of safe AI"},
                *(other_sections or []),
            ]},
        }]],
    }]
    flight = '1:"$Sreact.fragment"\n4:I[339756,[],"default"]\n6:' + json.dumps(record, ensure_ascii=False) + '\n'
    chunks = [flight] if split_at is None else [flight[:split_at], flight[split_at:]]
    return ("<!doctype html><html><head><meta charset='utf-8'></head><body>"
            + visible + '<script>(self.__next_f=self.__next_f||[]).push([0])</script>'
            + "".join(flight_script(chunk) for chunk in chunks) + "</body></html>").encode()


def timestamp(value):
    return int(datetime.fromisoformat(value).replace(tzinfo=timezone.utc).timestamp())


class AnthropicFeedTests(unittest.TestCase):
    def test_featured_article_and_dated_list_use_structured_publication_dates(self):
        featured = article()
        older = article("contextual-retrieval", "Introducing Contextual Retrieval", "2024-09-19")
        body = index_page([featured, older], visible='''
            <header><a href="/news">News</a><a href="/engineering">Engineering</a></header>
            <main><h1>Engineering at Anthropic</h1>
              <a href="/engineering/redesigning-source-control"><h2>Featured story</h2></a>
              <a href="/engineering/redesigning-source-control">Read more</a>
              <a href="/engineering/contextual-retrieval"><h3>Older story</h3><span>Sep 19, 2024</span></a>
            </main><footer><a href="/research">Research</a></footer>
        ''')
        self.assertEqual(anthropic.parse_engineering(body, BASE_URL), [
            {"url": BASE_URL + "/redesigning-source-control", "title": "Redesigning source control at Anthropic",
             "published_at": timestamp("2026-10-13")},
            {"url": BASE_URL + "/contextual-retrieval", "title": "Introducing Contextual Retrieval",
             "published_at": timestamp("2024-09-19")},
        ])

    def test_layout_and_visible_date_variations_do_not_change_articles(self):
        for visible in [
            '<h1>Engineering</h1><h2>Featured</h2><time datetime="2026-10-13">Oct 13, 2026</time>',
            '<div><h4>Engineering at Anthropic</h4><p>13 October 2026</p></div>',
            '<header>New navigation</header><main><h2>No visible publication date</h2></main>',
        ]:
            with self.subTest(visible=visible):
                result = anthropic.parse_engineering(index_page([article()], visible=visible), BASE_URL + "/")
                self.assertEqual(result[0]["url"], BASE_URL + "/redesigning-source-control")
                self.assertEqual(result[0]["published_at"], timestamp("2026-10-13"))

    def test_duplicate_featured_records_are_deduplicated(self):
        featured = article()
        result = anthropic.parse_engineering(index_page([featured], other_sections=[
            {"_type": "featuredArticle", "article": featured},
        ]), BASE_URL)
        self.assertEqual(len(result), 1)

    def test_news_research_and_footer_links_are_excluded(self):
        news = {**article("company-news"), "_type": "newsArticle"}
        research = {**article("research-study"), "_type": "researchArticle"}
        body = index_page([article(), news, research], other_sections=[{
            "_type": "navigation", "title": "Footer", "url": "/engineering/not-an-article",
        }])
        result = anthropic.parse_engineering(body, BASE_URL)
        self.assertEqual([item["url"] for item in result], [BASE_URL + "/redesigning-source-control"])

    def test_unicode_entities_and_literal_line_separator_survive_flight_decoding(self):
        title = "  Claude’s tools &amp; agents — \u2028building &quot;reliably&quot;  "
        body = index_page([article("AI-resistant-technical-evaluations", title)])
        result = anthropic.parse_engineering(body, BASE_URL)
        self.assertEqual(result[0]["title"], 'Claude’s tools & agents — building "reliably"')
        self.assertEqual(result[0]["url"], BASE_URL + "/AI-resistant-technical-evaluations")

    def test_flight_json_split_across_script_elements(self):
        result = anthropic.parse_engineering(index_page([article()], split_at=170), BASE_URL)
        self.assertEqual(result[0]["title"], "Redesigning source control at Anthropic")

    def test_multiple_pushes_and_script_attribute_variations(self):
        data = 'a:' + json.dumps({"articles": [article()]}) + '\n'
        prefix, suffix = data[:40], data[40:]
        body = ('<SCRIPT type="text/javascript">self.__next_f.push( ' + json.dumps([1, prefix])
                + ' );\nself.__next_f.push(' + json.dumps([1, suffix]) + ');</SCRIPT>').encode()
        result = anthropic.parse_engineering(body, BASE_URL)
        self.assertEqual(len(result), 1)

    def test_iso_timestamp_offsets_preserve_the_publication_instant(self):
        for date, expected in [
            ("2026-10-13T14:30:00Z", "2026-10-13T14:30:00"),
            ("2026-10-13T14:30:00+02:00", "2026-10-13T12:30:00"),
        ]:
            with self.subTest(date=date):
                result = anthropic.parse_engineering(index_page([article(date=date)]), BASE_URL)
                self.assertEqual(result[0]["published_at"], timestamp(expected))

    def test_missing_and_invalid_dates_fail_even_alongside_a_valid_article(self):
        for date in [None, "", "not a date", "2026-02-30", "Oct 13, 2026", 1800000000]:
            with self.subTest(date=date):
                body = index_page([article(), article("invalid-date", date=date)])
                with self.assertRaisesRegex(ValueError, "publication date"):
                    anthropic.parse_engineering(body, BASE_URL)

    def test_invalid_article_identity_is_rejected(self):
        for changes in [
            {"title": "  "}, {"title": None}, {"slug": None},
            {"slug": {"current": "../news/story"}},
            {"slug": {"current": "https://unrelated.example/story"}},
        ]:
            with self.subTest(changes=changes):
                with self.assertRaises(ValueError):
                    anthropic.parse_engineering(index_page([{**article(), **changes}]), BASE_URL)

    def test_conflicting_duplicate_metadata_is_not_silently_overwritten(self):
        body = index_page([article(), article(date="2026-10-14")])
        with self.assertRaisesRegex(ValueError, "conflicting metadata"):
            anthropic.parse_engineering(body, BASE_URL)

    def test_unusable_html_has_explicit_parse_failure(self):
        bodies = [
            b"", b"<html><h1>Access denied</h1></html>",
            b'<a href="/engineering/story">A link without metadata</a>',
            index_page([]),
            index_page([{**article(), "_type": "newsArticle"}]),
            b'<script>self.__next_f.push([1,"broken)',
            b'<script>self.__next_f.push([1,"broken)</script>',
            flight_script('6:{"articles":[').encode(),
            b"<html>\xff</html>",
        ]
        for body in bodies:
            with self.subTest(body=body[:100]):
                with self.assertRaises(ValueError):
                    anthropic.parse_engineering(body, BASE_URL)

    def test_javascript_is_never_executed(self):
        body = b'<script>self.__next_f.push(fetch("https://unrelated.example/"))</script>'
        with self.assertRaisesRegex(ValueError, "Malformed"):
            anthropic.parse_engineering(body, BASE_URL)


if __name__ == "__main__":
    unittest.main()
