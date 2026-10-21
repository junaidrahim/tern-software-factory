--!nonstrict
-- Stable ids retain source history when a feed's display name or URL changes.
-- Tabs group enabled feeds and sort alphabetically by their display names.
return {
	{ id = "anthropic-engineering", name = "Anthropic Engineering", kind = "anthropic_engineering", url = "https://www.anthropic.com/engineering", tab = "anthropic", tab_name = "Anthropic", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "claude-dev", name = "claude.dev", url = "https://claude.dev/rss.xml", tab = "anthropic", tab_name = "Anthropic", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "hn", name = "Hacker News", kind = "hn_weekly", url = "https://hn.algolia.com/api/v1/search", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "huggingface", name = "Hugging Face", url = "https://huggingface.co/blog/feed.xml", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "lobsters", name = "Lobsters", url = "https://lobste.rs/rss", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "openai-engineering", name = "OpenAI", url = "https://openai.com/news/rss.xml", category = "Engineering", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "pvldb", name = "PVLDB", url = "https://db.cs.cmu.edu/files/rss/pvldb-rss.xml", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "simonwillison", name = "Simon Willison", url = "https://simonwillison.net/atom/everything/", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "techcrunch", name = "TechCrunch", url = "https://techcrunch.com/feed/", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "verge", name = "The Verge", url = "https://www.theverge.com/rss/index.xml", window_days = 7, enabled = true, interval_seconds = 3600 },
	{ id = "arxiv-cs", name = "arXiv CS", kind = "arxiv_weekly", url = "https://export.arxiv.org/api/query", window_days = 7, enabled = true, interval_seconds = 3600 },
}
