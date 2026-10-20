-- Deterministic host-worker boundary; actual process/network smoke runs separately.
local now, jobs, payloads = 0, {}, {}
local rendered = { [1] = 0, [2] = 0 }
local responses = {}
local function node(kind, props, children)
	return { k = kind, p = if props and next(props) then props else nil, c = children }
end
local tern = {
	plugin = { dir = "/plugin", data = "/data" },
	now = function() return now end,
	getenv = function() return nil end,
	fs = { exists = function() return false end },
	json = {
		null = {},
		encode = function(value) table.insert(payloads, value); return tostring(#payloads) end,
		decode = function(value) return assert(responses[value]) end,
		array = function(value) return value or {} end,
	},
	process = { run = function(_, opts, callback)
		table.insert(jobs, { request = payloads[tonumber(opts.stdin)], done = callback })
	end },
	ui = {
		node = node, span = function(t, s) return { t = t, s = s } end,
		text = function(t) return node("text", { text = t }) end,
		badge = function(t, tone) return node("badge", { text = t, tone = tone }) end,
		md = function(t) return node("md", { text = t }) end,
	},
}
local sources = (function()
-- NEWS_SOURCES_SOURCE
end)()
local controller = (function()
local require = function() return sources end
-- NEWS_CONTROLLER_SOURCE
end)()
local page = (function()
local require = function(path) return if path == "./controller" then controller else sources end
-- NEWS_PAGE_SOURCE
end)()
local function context(id)
	return { pane = id, cols = 70, rows = 30, render = function() rendered[id] += 1 end, open = function() end }
end
local one, two = context(1), context(2)
local function story(id, title)
	return { id = id, title = title or id, url = "https://example.com/" .. id, sources = { { id = "hn", name = "Hacker News" } },
		published_at = 1000, first_seen_at = 1000 }
end
local function complete(index, stories)
	local token = tostring(index)
	responses[token] = { ok = true, snapshot = { stories = stories, feeds = {}, now = 2000 } }
	jobs[index].done({ status = 0, stdout = token, stderr = "", timed_out = false })
end
controller.attach(one)
controller.attach(two)
assert(#jobs == 1, "Blocks share the initial cache load instead of overlapping workers")
complete(1, { story("old") })
assert(#jobs == 2 and jobs[2].request.action == "refresh")
complete(2, { story("new"), story("old") })
local old = story("old")
assert(rendered[1] > 0 and rendered[2] > 0, "Every subscriber sees completed work")
local before = controller.get().snapshot
controller.refresh()
jobs[3].done({ status = 1, stdout = "", stderr = "offline", timed_out = false })
assert(controller.get().snapshot == before and string.find(controller.get().error, "offline", 1, true),
	"A worker failure keeps cached headlines and exposes the error")
now = 3599999
controller.tick()
assert(#jobs == 3, "Automatic refresh waits for a full hour")
controller.detach(1); controller.detach(2)
now = 3600000
controller.tick()
assert(#jobs == 3, "Closed blocks stop periodic refresh")
controller.attach(one)
controller.tick()
assert(#jobs == 4, "Reopening resumes refresh")
complete(4, { story("new"), old })
print("PASS: shared News worker lifecycle, cached failures, and reopen")

local state = { news = page.init({ reader = "new", selected = "new" }) }
one.frame = function() end
page.enter(state, one)
local function headlines()
	local root = page.view(state, one).main.c[1]
	for _, child in root.c do
		if child.p and child.p.key == "grid" then return child.c[2].c end
	end
	error("No headline list")
end
assert(#headlines() == 2 and state.news.selected == "new")
controller.refresh()
complete(5, { story("hot"), story("new"), old })
assert(#headlines() == 2 and state.news.selected == "new" and state.news.pending == 1,
	"Background arrivals do not reorder or replace the selected headline")
page.key(state, { name = "n" }, one)
assert(#headlines() == 3 and state.news.selected == "new",
	"Adopting new stories preserves an existing selection")
local original, opened = nil, 0
one.open = function(_, url) original, opened = url, opened + 1 end
assert(page.key(state, { name = "enter" }, one))
assert(original == story("new").url and opened == 1 and state.news.selected == "new" and #headlines() == 3,
	"Enter opens the selected link directly and leaves the headline list in place")
assert(#jobs == 5, "Opening a link does not fetch article content")
page.event(state, { ev = "activate", id = "main.news.grid.headlines", item = "main.news.grid.headlines.sold" }, one)
assert(original == old.url and opened == 2 and state.news.selected == "old",
	"Activating a row opens that row's link")
page.key(state, { name = "o" }, one)
assert(original == old.url and opened == 3, "The open shortcut matches Enter")
page.key(state, { name = "/" }, one)
assert(page.capture_key(state, { name = "paste", text = "Aé界" }, one))
page.capture_key(state, { name = "backspace" }, one)
assert(state.news.query == "Aé", "Deleting a pasted Unicode character preserves valid UTF-8")
page.capture_key(state, { name = "left" }, one)
page.capture_key(state, { name = "x", text = "x" }, one)
assert(state.news.query == "Axé", "Search arrows edit the caret instead of switching pages")
page.capture_key(state, { name = "a", ctrl = true }, one)
page.capture_key(state, { name = "paste", text = "hot" }, one)
page.capture_key(state, { name = "enter" }, one)
assert(#headlines() == 1 and not state.news.editing)
assert(opened == 3, "Finishing search with Enter does not open a link")
local saved = page.init(page.save(state))
assert(saved.query == "hot" and saved.selected == "hot",
	"Search, filter and selection survive page persistence")
print("PASS: stable News editions, direct links, search input, and saved filters")

local function ranked_story(id, rank, published)
	local value = story(id)
	value.sources[1].rank = rank
	value.sources[1].published_at = published or 1000
	return value
end
controller.refresh()
complete(6, { ranked_story("newer", 2), ranked_story("top", 1) })
state = { news = page.init({ source = "hn" }) }
page.enter(state, one)
assert(headlines()[1].p.key == "stop" and headlines()[2].p.key == "snewer",
	"Hacker News orders by weekly rank rather than publication date")
page.event(state, { ev = "select", id = "main.news.sources", item = "all" }, one)
assert(headlines()[1].p.key == "snewer", "All sources keeps newest-first snapshot order")
page.event(state, { ev = "select", id = "main.news.sources", item = "hn" }, one)
controller.refresh()
complete(7, { ranked_story("newer", 1), ranked_story("top", 2) })
assert(headlines()[1].p.key == "stop" and state.news.updated,
	"Changed weekly ranks wait for adoption even without new story IDs")
page.key(state, { name = "n" }, one)
assert(headlines()[1].p.key == "snewer" and not state.news.updated,
	"Adopting the weekly edition applies new ranks")
now += 7 * 86400 * 1000
assert(#headlines() == 0, "An open Hacker News tab hides submissions older than a week")
print("PASS: weekly Hacker News ranking, stable editions, combined order and expiry")

local function source_story(id, source_id, source_name, url)
	local value = story(id)
	value.sources = { { id = source_id, name = source_name, published_at = value.published_at } }
	value.url = url
	return value
end
local engineering = source_story("engineering", "anthropic-engineering", "Anthropic Engineering",
	"https://www.anthropic.com/engineering/source-control")
local claude = source_story("claude", "claude-dev", "claude.dev", "https://claude.dev/blog/code-review/")
local openai = source_story("openai", "openai-engineering", "OpenAI Engineering", "https://openai.com/index/storage")
controller.refresh()
complete(8, { claude, openai, engineering, ranked_story("hn", 1) })
state = { news = page.init({ source = "anthropic" }) }
page.enter(state, one)
assert(#headlines() == 2 and headlines()[1].p.key == "sclaude" and headlines()[2].p.key == "sengineering",
	"One Anthropic tab includes both configured feed memberships in newest-first order")
assert(headlines()[1].p.label[2].t == "claude.dev" and headlines()[2].p.label[2].t == "Anthropic Engineering",
	"Grouped stories retain their actual feed labels")
page.key(state, { name = "enter" }, one)
assert(original == claude.url, "Enter opens the selected claude.dev article, not the grouped source")
page.key(state, { name = "down" }, one)
page.key(state, { name = "enter" }, one)
assert(original == engineering.url, "Engineering stories open their original Anthropic URLs")
assert(page.init(page.save(state)).source == "anthropic", "The grouped tab survives saved-state validation")
assert(page.init({ source = "claude-dev" }).source == "all"
	and page.init({ source = "anthropic-engineering" }).source == "all",
	"Constituent feed IDs cannot create extra tabs through saved state")
local function tabs()
	for _, child in page.view(state, one).main.c[1].c do
		if child.p and child.p.key == "sources" then return child.p.items end
	end
	error("No source tabs")
end
local expected_tabs = {
	{ "all", "All sources" }, { "anthropic", "Anthropic" }, { "hn", "Hacker News" },
	{ "huggingface", "Hugging Face" }, { "lobsters", "Lobsters" }, { "openai-engineering", "OpenAI Engineering" },
	{ "pvldb", "PVLDB" }, { "simonwillison", "Simon Willison" }, { "techcrunch", "TechCrunch" }, { "verge", "The Verge" },
}
assert(#sources == 10 and #tabs() == #expected_tabs)
for index, tab in tabs() do
	assert(tab.id == expected_tabs[index][1] and tab.label == expected_tabs[index][2],
		"All sources stays first and grouped tabs sort alphabetically")
end
page.event(state, { ev = "select", id = "main.news.sources", item = "all" }, one)
assert(#headlines() == 4 and headlines()[1].p.key == "sclaude" and headlines()[2].p.key == "sopenai",
	"All sources preserves the snapshot order across grouped feeds")
for index = 2, #expected_tabs do
	page.key(state, { name = "s" }, one)
	assert(state.news.source == expected_tabs[index][1], "Source cycling visits each tab once in rendered order")
end
page.key(state, { name = "s" }, one)
assert(state.news.source == "all", "Source cycling wraps to All sources")
page.event(state, { ev = "select", id = "main.news.sources", item = "anthropic" }, one)
page.event(state, { ev = "select", id = "main.news.sources", item = "claude-dev" }, one)
assert(state.news.source == "anthropic", "Tab events reject constituent feed IDs")
page.event(state, { ev = "select", id = "main.news.sources", item = "openai-engineering" }, one)
assert(#headlines() == 1 and headlines()[1].p.key == "sopenai", "OpenAI Engineering has its own source selection")
local engineering_config, claude_config
for _, source in sources do
	if source.id == "anthropic-engineering" then engineering_config = source end
	if source.id == "claude-dev" then claude_config = source end
end
engineering_config.enabled = false
state = { news = page.init({ source = "anthropic" }) }
page.enter(state, one)
assert(state.news.source == "anthropic" and #headlines() == 1 and headlines()[1].p.key == "sclaude",
	"A grouped tab remains available when only claude.dev is enabled")
engineering_config.enabled, claude_config.enabled = true, false
assert(#headlines() == 1 and headlines()[1].p.key == "sengineering",
	"Group matching excludes disabled constituent feeds independently")
engineering_config.enabled = false
assert(page.init({ source = "anthropic" }).source == "all" and #tabs() == #expected_tabs - 1,
	"A group without enabled sources is neither selectable nor restored")
engineering_config.enabled, claude_config.enabled = true, true
print("PASS: grouped Anthropic sources, original URLs, sorted tabs, saved state, cycling, and availability")

-- An adopted edition must expire without waiting for another worker response.
local boundary = source_story("boundary", "claude-dev", "claude.dev", claude.url)
boundary.sources[1].published_at = 2000 - 90 * 86400
local shared = source_story("shared", "anthropic-engineering", "Anthropic Engineering", engineering.url)
shared.sources[1].published_at = boundary.sources[1].published_at - 1
table.insert(shared.sources, { id = "verge", name = "The Verge" })
local future = source_story("future", "openai-engineering", "OpenAI Engineering", openai.url)
future.sources[1].published_at = 2001
local undated = source_story("undated", "claude-dev", "claude.dev", claude.url)
undated.sources[1].published_at = nil
controller.refresh()
complete(9, { boundary, shared, future, undated })
state = { news = page.init({ source = "anthropic" }) }
page.enter(state, one)
assert(#headlines() == 1 and headlines()[1].p.key == "sboundary",
	"Anthropic includes the exact ninety-day boundary, not older, future, or undated memberships")
page.event(state, { ev = "select", id = "main.news.sources", item = "all" }, one)
assert(#headlines() == 2 and headlines()[2].p.label[2].t == "The Verge",
	"An old Anthropic membership does not hide an unrelated feed or retain stale attribution")
now += 2000
assert(#headlines() == 2 and headlines()[1].p.key == "sshared" and headlines()[2].p.key == "sfuture",
	"Cached editions expire at the rolling boundary and admit published OpenAI stories")
page.event(state, { ev = "select", id = "main.news.sources", item = "anthropic" }, one)
assert(#headlines() == 0, "Expired constituent feeds also leave the grouped tab")
assert(shared.sources[1].name == "Anthropic Engineering", "View filtering never mutates the shared cached edition")
print("PASS: ninety-day grouped feeds expire in cached editions without hiding unrelated attribution")
