local definition, route, tick, windowTick, hostTick, tickDelay, focused, opened, notice, panes, cx
local warnings, events = {}, {}
local now = 1000
-- omp runs (usage reports and task summaries): each holds its argv and the callback that delivers its result.
local runs, summaries, decoded, files = {}, {}, {}, {}
local gitRuns = {}
local newsRuns, modelRuns, githubRuns, encoded = {}, {}, {}, {}
local opsRuns = {}
-- `tern.kv` stores JSON, so values are copies.
local store = {}
local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for k, v in value do result[k] = copy(v) end
	return result
end
local function node(kind, props, children)
	return { k = kind, p = if props and next(props) then props else nil, c = children }
end
local tern = {
	plugin = { dir = "/plugin", data = "/data" },
	now = function() return now end,
	on = function(name, handler) events[name] = handler end,
	ui = {
		node = node,
		span = function(value, tone) return { t = value, s = tone } end,
		text = function(value) return node("text", { text = value }) end,
		badge = function(value, tone) return node("badge", { text = value, tone = tone }) end,
		md = function(value) return node("md", { text = value }) end,
		table = function(cols, rows) return node("table", { cols = cols, rows = rows }) end,
		meter_cell = function(value, thresholds) return { meter = { value = value, thresholds = thresholds } } end,
	},
	json = {
		null = {},
		array = function(value) return value or {} end,
		encode = function(value)
			table.insert(encoded, value)
			return "encoded:" .. tostring(#encoded)
		end,
		decode = function(text) return assert(decoded[text], "Invalid JSON") end,
	},
	getenv = function(name) return if name == "HOME" then "/Users/test" else nil end,
	fs = { exists = function(path) return files[path] == true end },
	process = { run = function(argv, opts, callback)
		if argv[#argv] == "/plugin/ops/worker.py" then
			table.insert(opsRuns, { argv = argv, opts = opts, done = callback })
			return
		end
		if argv[#argv] == "/plugin/news/worker.py" then
			table.insert(newsRuns, { argv = argv, opts = opts, done = callback })
			return
		end
		if argv[#argv] == "/plugin/models/worker.py" then
			table.insert(modelRuns, { argv = argv, opts = opts, done = callback })
			return
		end
		if argv[#argv] == "/plugin/github/worker.py" then
			table.insert(githubRuns, { argv = argv, opts = opts, done = callback })
			return
		end
		if argv[1] == "git" then
			table.insert(gitRuns, { argv = argv, done = callback })
			return
		end
		table.insert(if argv[2] == "usage" then runs else summaries, { argv = argv, opts = opts, done = callback })
	end },
	block = { define = function(_, value) definition = value end },
	route = { link = function(value) route = value end },
	timer = function(ms, callback) windowTick, tickDelay = callback, ms end,
	log = { warn = function(...) table.insert(warnings, {...}) end, debug = function() end },
	kv = { get = function(key) return copy(store[key]) end, set = function(key, value) store[key] = copy(value) end },
	pane = { list = function() return panes end },
}
local tracking = (function()
-- TRACKING_SOURCE
end)()
local limits = (function()
-- LIMITS_SOURCE
end)()
local opsController = (function()
-- OPS_CONTROLLER_SOURCE
end)()
local opsSection = (function()
local require = function() return opsController end
-- OPS_SECTION_SOURCE
end)()
local newsSources = (function()
-- NEWS_SOURCES_SOURCE
end)()
local newsController = (function()
local require = function() return newsSources end
-- NEWS_CONTROLLER_SOURCE
end)()
local newsPage = (function()
local require = function(path) return if path == "./controller" then newsController else newsSources end
-- NEWS_PAGE_SOURCE
end)()
local modelsController = (function()
-- MODELS_CONTROLLER_SOURCE
end)()
local modelsPage = (function()
local require = function() return modelsController end
-- MODELS_PAGE_SOURCE
end)()
local githubController = (function()
-- GITHUB_CONTROLLER_SOURCE
end)()
local githubPage = (function()
local require = function() return githubController end
-- GITHUB_PAGE_SOURCE
end)()
local repositoriesSection = (function()
-- REPOSITORIES_SECTION_SOURCE
end)()
local require = function(path)
	if path == "./limits" then return limits end
	if path == "./ops/controller" then return opsController end
	if path == "./ops/section" then return opsSection end
	if path == "./news/page" then return newsPage end
	if path == "./news/controller" then return newsController end
	if path == "./models/page" then return modelsPage end
	if path == "./models/controller" then return modelsController end
	if path == "./github/page" then return githubPage end
	if path == "./github/controller" then return githubController end
	if path == "./repositories/section" then return repositoriesSection end
	return tracking
end
do
local tern = setmetatable({ timer = function(_, callback) hostTick = callback end }, { __index = tern })
-- HOST_SOURCE
end
do
-- WINDOW_SOURCE
end

local block = { pane = 100, kind = "plugin", block = "tern-software-factory.agents", tab = 10 }
local localAgent = { pane = 200, title = "Investigate a failure", tab = 20 }
local idleAgent = { pane = 300, title = "", tab = 10 }
local remoteAgent = { pane = 400, title = "Remote task", tab = 30 }
local exitedAgent = { pane = 500, title = "Finished", tab = 20 }
local shell = { pane = 600, kind = "terminal", program = "codex", title = "Shell agent", tab = 10 }
panes = { block, localAgent, idleAgent, remoteAgent, exitedAgent, shell }
local agents = {
	{ pane = 400, state = "working", cwd = "/remote" },
	{ pane = 300, state = "idle", cwd = "/code/website", command = "omp" },
	{ pane = 500, state = "exited", cwd = "/code" },
	{ pane = 200, state = "waiting_input", cwd = "/code/backend", model = "Test model", delivery_error = "Prompt could not be sent" },
}
local function blockContext(pane, onOpen)
	return { pane = pane, rows = 30, render = function() end, frame = function() end, open = function(_, url) onOpen(url) end }
end
local blockCx = blockContext(100, function(url) opened = url end)
local state = definition.init(blockCx)
cx = {
	session = {
		panes = function() return panes end,
		tabs = function() return { { id = 10, session = 1 }, { id = 20, session = 2 }, { id = 30, session = 3 } } end,
	},
	sessions = { list = function() return { { id = 1, name = "Main" }, { id = 2, name = "Backend" }, { id = 3, name = "Remote" } } end },
	hosts = { list = function() return { { id = 1, panes = { 100, 200, 300, 500, 600 } }, { id = 2, panes = { 400 } } } end },
	agents = {
		list = function() return agents end,
		transcript = function(_, pane, opts)
			assert(opts.last <= 200, "Read a bounded history")
			if pane ~= 200 then return {} end
			return {
				{role = "user", text = "Fix the failure"},
				{role = "assistant", text = "Fixed the parser.", tools = {
					{name = "edit", title = "Edit", status = "done", target = "src/parser.luau:12"},
					{name = "bash", title = "Run tests", status = "running"},
				}},
			}
		end,
	},
	layout = { focus = function(_, pane) focused = pane end },
	toast = function(_, _, message) notice = message end,
}
-- One refresh: the window half's timer call, then the host half's poll.
tick = function(c)
	local window = windowTick
	window(c)
	local host = hostTick
	host()
end
local function key(name) definition.key(state, { name = name }, blockCx) end
-- Tern reports the focused pane, not the block, as the pane of a block's link. Details
-- arrive at the host's next poll.
local function open_route() route({ pane = 200, url = opened }, cx); hostTick() end

assert(not state.loaded)
assert(definition.key(state, { name = "enter" }, blockCx) == false)
tick(cx)
assert(#warnings == 0)
assert(#state.agents == 2, "Include all sessions on this host, excluding remote and exited agents")
assert(state.agents[1].session == "Backend" and state.agents[2].session == "Main")
assert(state.agents[2].title == "omp", "Untitled panes need a useful fallback")
assert(state.selected == 200)
key("enter"); open_route()
assert(focused == 200, "Enter must route to the selected pane, even in another session")
key("down")
assert(state.selected == 300)
agents[2].state = "working"
localAgent.title = "\u{f418} Renamed task"
tick(cx)
assert(state.selected == 300, "Refreshing status or titles must preserve selection")
local view = definition.view(state, blockCx)
local function list(v) return v.main.c[4].c[2] end
local function page(id)
	definition.event(state, { ev = "select", id = "main.pages", item = id }, blockCx)
end
local selectedBefore = state.selected
assert(#opsRuns == 0, "Agent ops does not run before Limits is opened")
page("limits")
assert(state.page == "limits" and definition.view(state, blockCx).dock == nil)
assert(definition.key(state, { name = "enter" }, blockCx) == false,
	"Limits must not activate a hidden agent")
assert(#opsRuns == 1, "Opening Limits lazily loads host Agent ops")
local quotaRunsBeforeOps = #runs
assert(definition.key(state, { name = "r", ctrl = true }, blockCx) == false)
assert(definition.key(state, { name = "r" }, blockCx) == true)
assert(#opsRuns == 1 and state.selected == selectedBefore and #runs == quotaRunsBeforeOps,
	"Limits r coalesces ops refresh without activating agents or rerunning quota")
decoded.ops = { ok = true, snapshot = {
	generated_at = 1000,
	models = { { model_key = "provider/model", tokens_per_second = 24.5, ttft_ms = 1500,
		avg_output_tokens = 210, effective_samples = 12.5, updated_at = 999 } },
	commands = { { name = "review", count = 7, last_used_at = 998 } },
	summary = { measured_models = 1, effective_samples = 12.5, command_uses = 7 }, warnings = {},
} }
opsRuns[1].done({ status = 0, stdout = "ops" })
assert(#opsRuns == 2, "Queued manual refresh follows the active snapshot")
opsRuns[2].done({ status = 0, stdout = "ops" })
definition.event(state, { ev = "action", act = "ops-refresh" }, blockCx)
assert(#opsRuns == 3 and #runs == quotaRunsBeforeOps, "The Limits refresh button refreshes ops only")
opsRuns[3].done({ status = 0, stdout = "ops" })
local limitsView = definition.view(state, blockCx)
assert(limitsView.main.c[2].p.role == "factory-limits" and limitsView.main.c[3].p.role == "factory-ops",
	"Agent ops appends below quota without moving the existing quota path")
definition.event(state, { ev = "activate", id = "main.directory.agents", item = "main.directory.agents.p200" }, blockCx)
assert(state.selected == selectedBefore, "Inactive page events cannot change agent selection")
page("missing")
assert(state.page == "limits", "Unknown tabs do not replace the active page")
local restored = definition.init(blockContext(999, function() end), {}, definition.save(state))
assert(restored.page == "limits", "The selected page survives reload")
local fallback = definition.init(blockContext(998, function() end), {}, { page = "removed" })
assert(fallback.page == "agents", "Removed saved pages fall back to Agents")
key("right")
assert(state.page == "news", "The next tab opens News")
key("right")
assert(state.page == "models", "The next tab opens Models")
assert(definition.key(state, { name = "enter" }, blockCx) == false,
	"Empty Models must not activate a hidden agent")
key("right")
assert(state.page == "github", "GitHub is appended after Models")
assert(definition.key(state, { name = "enter" }, blockCx) == false,
	"Empty GitHub must not activate a hidden agent")
store["repositories:root"] = "/code"
definition.event(state, { ev = "action", act = "github-refresh" }, blockCx)
assert(#githubRuns == 1 and encoded[tonumber(githubRuns[1].opts.stdin:match("%d+$"))].root == "/code")
decoded.githubAuth = { ok = false, root = "/code", repos = {}, error = "Run gh auth login on this host.", setup = true }
githubRuns[1].done({ status = 0, stdout = "githubAuth", stderr = "" })
assert(githubController.get().setup and githubController.get().error == decoded.githubAuth.error)
local githubSaved = definition.save(state)
assert(githubSaved.page == "github" and githubSaved.pages.github.root == nil)
local githubRestored = definition.init(blockContext(997, function() end), {}, githubSaved)
assert(githubRestored.page == "github" and #githubRuns == 1, "Saved GitHub reuses the host snapshot without an automatic retry")
definition.event(state, { ev = "activate", id = "main.directory.agents", item = "main.directory.agents.p200" }, blockCx)
assert(state.selected == selectedBefore, "GitHub ignores inactive agent row events")
store["repositories:root"] = nil
key("right")
assert(state.page == "agents" and state.selected == selectedBefore, "Tab cycling preserves agent selection")
key("left")
assert(state.page == "github", "Previous tab wraps to the appended GitHub page")
page("agents")
key("tab")
assert(state.repositories.section == "repositories" and state.page == "agents")
key("down")
assert(state.selected == selectedBefore, "Repository navigation cannot change the agent selection")
page("limits")
key("tab")
assert(state.repositories.section == "repositories", "Repository section shortcuts are inactive on other pages")
page("agents")
definition.event(state, { ev = "action", act = "repositories-root" }, blockCx)
key("right")
assert(state.page == "agents" and state.repositories.editor ~= nil, "Root editor captures arrows before page navigation")
key("escape")
assert(state.repositories.editor == nil)
key("tab")
assert(state.repositories.section == "agents")
key("left")
assert(state.page == "github", "Page arrows resume after the root editor closes")
page("agents")
assert(#list(view).c == 2 and list(view).p.selected == "main.directory.agents.p300")
assert(list(view).c[1].p.tone == "error", "Prompt delivery failures need an attention indicator")
local first = list(view).c[1].p.label
assert(first[3].t == "Prompt could not be sent", "Delivery errors replace the task")
assert(state.agents[1].work_dir == "/code/backend/src",
	"A relative edit target resolves against the agent's cwd, without its line suffix")
assert(state.agents[2].work_dir == "/code/website",
	"An agent that changed nothing works in its cwd")
assert(list(view).c[2].p.label[3].t == "omp", "The session title stands in until a summary arrives")
assert(first[2].t == "—", "An unresolved repository must not show the cwd's name")
for _, run in gitRuns do
	run.done({ status = if run.argv[3] == "/code/backend" then 0 else 128,
		stdout = "/code/\n", timed_out = false })
end
view = definition.view(state, blockCx)
assert(list(view).c[1].p.label[2].t == "code", "Project uses the repository root, not the cwd basename")
assert(list(view).c[2].p.label[2].t == "—", "A directory outside Git has no project")
assert(string.find(list(view).c[1].p.title, "Session: Renamed task", 1, true), "Icon glyphs must not reach row text")
definition.event(state, { ev = "select", id = "main.directory.agents", item = "main.directory.agents.p200" }, blockCx)
assert(state.selected == 200)
definition.event(state, { ev = "activate", id = "main.directory.agents", item = "main.directory.agents.p300" }, blockCx)
open_route()
assert(focused == 300, "Double-click must open the clicked agent")
agents[2].state = "exited"
focused = nil
key("enter"); open_route()
assert(focused == nil and notice, "An exited selection must never focus a stale pane")
tick(cx)
assert(#state.agents == 1 and state.selected == 200)
assert(route({ pane = 100, url = "https://example.com" }, cx) == nil)
route({ pane = 100, url = "tern-software-factory://pane/100/400" }, cx)
assert(focused == nil, "Navigation must stay on the block's host")
route({ pane = 100, url = "tern-software-factory://pane/999/300" }, cx)
assert(focused == nil, "A link must name an open Software Factory block")
agents = {}
tick(cx)
assert(state.loaded and #state.agents == 0 and state.selected == nil)
assert(definition.key(state, { name = "down" }, blockCx) == false)
definition.view(state, blockCx)

-- Native omp activity, completion events and null metadata.
agents = {{ pane = 200, state = "working", cwd = "/code/backend", model = "Test model" }}
agents[1].last_message = "**Fixed** `parser_case`.\nTests passing."
tick(cx)
open_route()
assert(state.agents[1].preview == "Fixed parser_case. Tests passing.")
assert(state.details.response == "Fixed the parser.")
assert(state.agents[1].model == "Test model")
definition.view(state, blockCx)
local old = state.details
-- A delayed reply for a previous selection must not overwrite its new detail.
route({ pane = 100, url = "tern-software-factory://inspect/100/300" }, cx); hostTick()
assert(state.details == old)
events.agent_finished({pane = 200, result = "failed"}, cx)
now = 6000
tick(cx); open_route()
assert(state.details.last_turn == "failed" and state.details.finished_seconds == 5)
assert(state.agents[1].last_turn == "failed" and state.agents[1].finished_seconds == 5)
agents[1].state = "idle"
tick(cx)
view = definition.view(state, blockCx)
assert(list(view).c[1].p.tone == "error", "Failed turns must stand out in the row")
agents[1].state = "working"
tick(cx)
view = definition.view(state, blockCx)
assert(list(view).c[1].p.tone == "accent", "A new working turn must use the working signal")
-- Repeated requests inside a second share one transcript read.
cx.agents.transcript = function() error("Not ready") end
open_route()
assert(not state.details.transcript_error)
now += 1000
tick(cx); open_route()
assert(state.details.transcript_error and #state.agents == 1, "A transcript error must not break discovery")
definition.view(state, blockCx)
local null = newproxy()
local bounded = tracking.read({agents = {transcript = function()
	return {{role = "assistant", text = string.rep("é", 4000)}}
end}}, {pane = 200, model = null, delivery_error = null}, nil)
assert(bounded.model == "" and utf8.len(bounded.response) ~= nil)
assert(#bounded.response <= 6003)
assert(tracking.preview(null) == "" and tracking.preview(" \n\t ") == "")
assert(utf8.len(tracking.preview(string.rep("é", 1000))) ~= nil)
assert(#tracking.preview(string.rep("x", 10000)) <= 243)
local fallback = tracking.read({agents = {transcript = function() return {} end}}, {pane = 200, last_message = "Pane output"}, nil)
assert(fallback.response == "Pane output" and fallback.response_source == "pane" and not fallback.has_transcript)
-- An omp pane discovered through the native API is accepted without a command.
localAgent.kind = "agent"
agents[1].command = null
tick(cx)
assert(#state.agents == 1 and state.agents[1].pane == 200, "Native discovery includes omp launched in a shell")
route({pane = 100, url = "tern-software-factory://pane/100/600"}, cx)
assert(focused == nil, "Ordinary shell agents must not be included or navigable")
assert(route({url = "tern-software-factory://inspect/100/200"}, cx).handled)
cx.agents.transcript = function() return {} end

-- Subagents of running omp task cards appear as compact rows under their agent.
local cards = {
	{ id = "40", k = "tool", p = { role = "omp.tool.task", status = "done" } },
	{ id = "43", k = "tool", p = { role = "omp.tool.task", status = "running", age = 95000 } },
}
local agentNodes = {
	{ id = "43.0", k = "text", p = { role = "omp.tool.context" } },
	{ id = "43.Zed", k = "agent", p = { name = "Zed", agent = "sonic", model = "openai-codex/gpt-6.1-sol", status = "done",
		stats = { tokens = 20644, took = 103483 } } },
	{ id = "43.Alpha", k = "agent", p = { name = "Alpha", agent = "task", model = "anthropic/opus", status = "running",
		stats = { tokens = 1500, contextLabel = null }, tool = { name = "bash", intent = "Running tests", age = 4000 }, task = "Fix it" } },
}
cx.session.surface = function(_, pane, opts)
	if opts.root == nil then return { surface = { role = "omp.session" }, main = { id = "main", c = cards } } end
	assert(pane == 200 and opts.root == "43", "Read only running task cards")
	return { surface = { role = "omp.session" }, main = { id = "43", c = agentNodes } }
end
tick(cx)
local subs = state.agents[1].subagents
assert(#subs == 2 and subs[1].name == "Alpha" and subs[2].name == "Zed", "Subagent order must not follow omp's update order")
assert(subs[1].elapsed_ms == 95000 and subs[2].elapsed_ms == 103483, "Running subagents take their task card's age")
view = definition.view(state, blockCx)
local rows = list(view).c
assert(#rows == 3 and rows[2].p.role == "factory-subagent" and rows[3].p.role == "factory-subagent")
assert(rows[2].p.label[2].t == "Alpha" and rows[2].p.label[3].t == "bash · Running tests", "Show the running tool")
assert(rows[3].p.label[3].t == "No activity yet" and rows[3].p.detail[2].t == "Done")
assert(string.find(rows[1].p.detail[3].t, "1 subagent", 1, true), "The agent row counts running subagents")
key("down")
assert(state.selected == 200 and state.sub == "43_Alpha", "Subagent rows are selectable")
view = definition.view(state, blockCx)
assert(list(view).p.selected == "main.directory.agents.p200.s43_Alpha")
local activityPanel
for _, child in view.main.c do
	if child.p and child.p.role == "factory-activity" then activityPanel = child end
end
assert(activityPanel.c[1].c[1].p.text[1].t == "Alpha", "The activity panel shows the selected subagent")
focused = nil
key("enter"); open_route()
assert(focused == 200, "Enter on a subagent goes to its agent's pane")
definition.event(state, { ev = "select", id = "main.directory.agents", item = "main.directory.agents.p200.s43_Zed" }, blockCx)
assert(state.selected == 200 and state.sub == "43_Zed")
cards[2].p.status = "done"
tick(cx)
assert(#state.agents[1].subagents == 0 and state.selected == 200 and state.sub == nil,
	"A finished task removes its subagents and keeps the agent selected")
cx.session.surface = function() return { surface = { role = "shell" }, main = { id = "main", c = { cards[2] } } } end
cards[2].p.status = "running"
tick(cx)
assert(#state.agents[1].subagents == 0, "Only omp surfaces are read for subagents")
cx.session.surface = function() error("Surface unavailable") end
tick(cx)
assert(#state.agents == 1 and #warnings == 0, "A surface error must not break discovery")

-- Path: the directory of the newest file the agent changed, kept after it leaves the transcript window.
local changes = { { role = "assistant", text = "", tools = {
	{ name = "write", status = "done", targetKind = "path", target = "docs/a.md", href = "file:///code/backend/docs/a.md" },
	{ name = "edit", status = "done", targetKind = "path", target = "../shared/x.lua:3" },
	{ name = "edit", status = "error", targetKind = "path", target = "broken/y.lua" },
	{ name = "write", status = "done", targetKind = "text", target = "query=\"notes\"" },
	{ name = "read", status = "done", targetKind = "path", target = "other/z.lua", href = "file:///code/backend/other/z.lua" },
} } }
cx.agents.transcript = function() return changes end
tick(cx)
assert(state.agents[1].path == "/code/shared/",
	"The newest successful file change wins; reads, failed edits and non-file writes do not count")
changes = { { role = "assistant", text = "", tools = {
	{ name = "edit", status = "done", targetKind = "path", target = "n.md:1", href = "file:///Users/test/My%20notes/n.md" },
} } }
tick(cx)
assert(state.agents[1].path == "~/My notes/" and state.agents[1].work_dir == "/Users/test/My notes",
	"A path outside the cwd is shown from home")
changes = { { role = "assistant", text = "", tools = { { name = "write", status = "done", targetKind = "path",
	target = "tern-software-factory/tests/fixtures/deep/case.luau" } } } }
tick(cx)
local deep = list(definition.view(state, blockCx)).c[1].p
assert(state.agents[1].path == "tern-software-factory/tests/fixtures/deep/"
	and string.find(deep.title, "Path: /code/backend/tern-software-factory/tests/fixtures/deep", 1, true),
	"A long path appears in full in the tooltip")
changes = { { role = "assistant", text = "", tools = { { name = "ast_edit", status = "done", targetKind = "path", target = "lib/**/*.luau" } } } }
tick(cx)
assert(state.agents[1].path == "lib/", "A glob names its fixed directory")
changes = {}
for i = 1, 12 do table.insert(changes, { role = if i % 2 == 1 then "user" else "assistant", text = "Step " .. i, tools = {} }) end
tick(cx)
assert(state.agents[1].path == "lib/",
	"The path stays after the change scrolls out of the transcript window")
-- A newly seen agent (or one seen again after a reload) looks further back once for its last change.
table.insert(agents, { pane = 300, state = "idle", cwd = "/code/website" })
cx.agents.transcript = function(_, pane, opts)
	if pane == 300 and opts.last == 200 then
		return { { role = "assistant", text = "", tools = { { name = "edit", status = "done", targetKind = "path", target = "site/index.html" } } } }
	end
	return if pane == 300 then { { role = "user", text = "Thanks", tools = {} } } else {}
end
tick(cx); tick(cx)
assert(state.agents[2].pane == 300 and state.agents[2].path == "site/", "The path survives a reload")
table.remove(agents, 2)
cx.agents.transcript = function() return {} end

-- Claude and Codex limits refresh on their own page.
assert(#runs == 1 and table.concat(runs[1].argv, " ") == "omp usage --json", "One omp usage run at a time")
page("limits")
decoded.usage = { generatedAt = 1000000, reports = {
	{ provider = "openai-codex", fetchedAt = 880000, limits = {}, metadata = { email = "a@work", planType = "ent" } },
	{ provider = "openai-codex", fetchedAt = 760000, resetCredits = { availableCount = 3 },
		metadata = { email = "z@home", planType = "prolite" }, limits = {
			{ label = "7 days", window = { resetsAt = 1000000 + 136 * 3600000 },
				amount = { used = 7, limit = 100, usedFraction = 0.07, unit = "percent" } },
		} },
	{ provider = "anthropic", fetchedAt = 1000000, metadata = { email = "c@work" }, limits = {
		{ label = "Claude Extra Usage", amount = { used = 161.77, limit = 450, usedFraction = 0.3595, unit = "usd" } },
		{ label = "5 hours", window = { resetsAt = 1000000 + 90 * 60000 }, amount = { used = 95, unit = "percent", usedFraction = 0.95 } },
	} },
	{ provider = "google", metadata = {}, limits = {} },
} }
runs[1].done({ status = 0, stdout = "usage", stderr = "", timed_out = false })
now += 30000
tick(cx)
view = definition.view(state, blockCx)
local section = view.main.c[2]
local limitRows = section.c[2].p.rows
assert(#limitRows == 4, "Claude, then Codex accounts with limits first; other providers are left out")
assert(limitRows[1][1][1].t == "Claude" and limitRows[1][3][1].t == "Claude Extra Usage" and limitRows[1][5][1].t == "$161.77 of $450.00")
assert(limitRows[2][1][1] == nil and limitRows[2][4].meter.value == 0.95 and limitRows[2][5][1].t == "95% used")
assert(limitRows[2][6][1].t == "in 1h 29m", "Reset times count down from omp's report")
assert(limitRows[3][2][1].t == "z@home · prolite · 3 resets saved" and limitRows[3][6][1].t == "in 5d 15h")
assert(limitRows[4][3][1].t == "No limits reported")
assert(section.c[1].c[2].p.text[1].t == "Updated just now")
assert(#runs == 1, "Limits refresh at most once a minute")
now += 30000
tick(cx)
assert(#runs == 2)
runs[2].done({ status = 1, stdout = "", stderr = "no credentials\ndetails", timed_out = false })
tick(cx)
section = definition.view(state, blockCx).main.c[2]
assert(#section.c[2].p.rows == 4 and section.c[3].p.text[1].t == "omp usage failed: no credentials",
	"A failed refresh keeps the last limits and says why")
files["/Users/test/Library/Application Support/Tern/omp/bin/omp"] = true
now += 60000
tick(cx)
assert(runs[3].argv[1] == "/Users/test/Library/Application Support/Tern/omp/bin/omp", "Prefer the omp Tern installs")
decoded.codex = { generatedAt = 1, reports = { decoded.usage.reports[2] } }
runs[3].done({ status = 0, stdout = "codex", stderr = "", timed_out = false })
tick(cx)
limitRows = definition.view(state, blockCx).main.c[2].c[2].p.rows
assert(limitRows[#limitRows][1][1].t == "Claude" and limitRows[#limitRows][2][1].t == "Not signed in to omp")
assert(#warnings == 0)
page("agents")

-- Agent task: a one-sentence summary of recent activity, from a fast model, one run at a time.
assert(#summaries == 1, "One summary at a time")
local argv = summaries[1].argv
assert(argv[2] == "-p" and table.find(argv, "@smol") and table.find(argv, "--no-tools") and table.find(argv, "--no-session"),
	"Summaries use the fast model without tools or a saved session")
local prompt = argv[#argv]
assert(string.find(prompt, "User asked: Fix the failure", 1, true) and string.find(prompt, "edit — src/parser.luau:12", 1, true)
	and string.find(prompt, "bash: Run tests", 1, true), "The prompt lists the agent's recent steps")
-- That run's agent left and came back since; its reply is dropped and the agent summarized afresh.
local messages = {
	{ role = "user", text = "Fix the failure" },
	{ role = "assistant", text = "", tools = { { key = "k1", name = "bash", title = "Run tests", status = "error" } } },
}
cx.agents.transcript = function() return messages end
summaries[1].done({ status = 0, stdout = "Stale.", stderr = "", timed_out = false })
tick(cx)
assert(#summaries == 2 and state.agents[1].task == nil)
assert(string.find(summaries[2].argv[#summaries[2].argv], "bash: Run tests (failed)", 1, true))
summaries[2].done({ status = 0, stdout = "\n\"Fixes the **parser** failure and reruns the tests.\"\nExtra line.", stderr = "", timed_out = false })
tick(cx)
assert(state.agents[1].task == "Fixes the parser failure and reruns the tests.", "Keep the first sentence, without quotes or markdown")
now += 200000
tick(cx)
assert(#summaries == 2, "No new activity, no new summary")
messages = { { role = "assistant", text = "", tools = { { key = "k9", name = "bash", command = "make deploy" } } } }
tick(cx)
assert(#summaries == 3)
prompt = summaries[3].argv[#summaries[3].argv]
assert(string.find(prompt, "make deploy", 1, true) and not string.find(prompt, "Fix the failure", 1, true),
	"Summaries cover the last three minutes")
summaries[3].done({ status = 1, stdout = "", stderr = "rate limited", timed_out = false })
tick(cx)
assert(state.agents[1].task == "Fixes the parser failure and reruns the tests.", "A failed summary keeps the last one")
now += 1000
table.insert(messages, { role = "assistant", text = "Deployed.", tools = {} })
tick(cx)
assert(#summaries == 3, "At most one summary a minute per agent")
now += 60000
tick(cx)
assert(#summaries == 4)
summaries[4].done({ status = 0, stdout = "Deploys the parser fix.", stderr = "", timed_out = false })
tick(cx)
assert(state.agents[1].task == "Deploys the parser fix.")
cx.agents.transcript = function() return {} end
-- A Software Factory block whose program exited must not stop updates to a live one.
table.insert(panes, 1, { pane = 700, kind = "plugin", block = "tern-software-factory.agents", tab = 10 })
agents[1].state = "idle"
tick(cx)
assert(state.agents[1].state == "idle" and #warnings == 0, "Live blocks still update beside an exited one")
table.remove(panes, 1)
-- Tern disables a window timer until reload once one call runs past 50 ms, which froze
-- every open block. Slow reads spread over timer calls, and each block gets its snapshot.
-- Tern's window API also shortens pane ids above 2^44: the window sees this block as 800,
-- while the block's real id (its host cx.pane) is 2^44 + 800.
local second = { pane = 800, kind = "plugin", block = "tern-software-factory.agents", tab = 10 }
local secondCx = blockContext(2^44 + 800, function() end)
local secondState = definition.init(secondCx)
table.insert(panes, second)
local listPanes = tern.pane.list
tern.pane.list = function() return { block, { pane = 2^44 + 800 } } end
local listHosts, readSurface = cx.hosts.list, cx.session.surface
cx.hosts.list = function() return { { id = 1, panes = { 100, 200, 300, 500, 600, 800 } }, { id = 2, panes = { 400 } } } end
cx.agents.transcript = function() now += 30; return {} end
cx.session.surface = function() now += 30; error("Surface unavailable") end
agents[1].state = "working"
local calls = 0
repeat
	local started = now
	tick(cx)
	calls += 1
	assert(now - started < 50, "No timer call may run past Tern's 50 ms budget")
until tickDelay == 1000
assert(calls > 1 and state.agents[1].state == "working" and secondState.agents[1].state == "working",
	"Every open block refreshes, including one whose id Tern shortens")
local slow = {}
for _, warning in warnings do slow[warning[1]] = true end
assert(slow["Slow refresh step: transcript 200 took 30 ms"] and slow["Slow refresh step: subagents 200 took 30 ms"],
	"A step that nears the budget is logged by name")
table.clear(warnings)
assert(store["snapshot:800"] ~= nil, "A block's entries are keyed by the low 44 bits of its id")
-- A closed block's entries leave the store, and so do those of a block whose program exited.
table.remove(panes)
tern.pane.list = listPanes
cx.agents.transcript, cx.session.surface = function() return {} end, readSurface
tick(cx)
assert(store["snapshot:800"] == nil and store["snapshot:700"] == nil and store["snapshot:100"] ~= nil,
	"Only open blocks keep entries")
cx.hosts.list = listHosts

-- Reads follow change: an agent that is not working is read again only when its state or
-- last message changes, and only working agents have their subagents read.
local reads, surfaces = 0, 0
cx.agents.transcript = function() reads += 1; return {} end
cx.session.surface = function() surfaces += 1; return { surface = { role = "omp.session" }, main = { id = "main", c = {} } } end
agents[1].state, agents[1].last_message = "idle", "Done."
tick(cx)
assert(reads == 1 and surfaces == 0, "A changed idle agent is read once, without its subagents")
tick(cx); tick(cx)
assert(reads == 1, "An unchanged idle agent is not read again")
open_route()
local panelAge = state.details.finished_seconds
now += 5000
open_route()
assert(reads == 2 and state.details.finished_seconds == panelAge + 5,
	"An idle agent's panel is read once until it changes, and its turn age still advances")
agents[1].last_message = "Done again."
tick(cx)
assert(reads == 3, "A new last message is read")
agents[1].state = "working"
tick(cx); tick(cx)
assert(reads == 5 and surfaces == 2, "A working agent is read every refresh")
cx.session.surface = readSurface
cx.agents.transcript = function() return {} end

-- Large lists retain every row and use stable, exact ids above 32 bits.
agents, panes = {}, { block }
local localPanes = { 100 }
for i = 1, 250 do
	local id = 8589934592 + i
	table.insert(agents, { pane = id, state = "idle", cwd = "/code/project" })
	table.insert(panes, { pane = id, title = "Agent " .. i, tab = 10 })
	table.insert(localPanes, id)
end
cx.hosts.list = function() return { { id = 1, kind = "local", panes = localPanes } } end
tick(cx)
key("end")
view = definition.view(state, blockCx)
assert(#list(view).c == 250 and list(view).p.selected == "main.directory.agents.p8589934842")
key("enter"); open_route()
assert(focused == 8589934842)
key("home"); key("page_down")
assert(state.selected == 8589934603)
cx.agents.list = function() error("Host disconnected") end
local callback = windowTick
windowTick = nil
callback(cx)
assert(windowTick ~= nil and #warnings == 1, "A failed refresh must still schedule its successor")
print("PASS: native discovery, host scope, cross-session navigation, selection, exits, empty and 250 agents")
print("PASS: omp activity, working paths, subagents, Claude and Codex limits, completion, cache, null metadata, bounded Unicode text and stale detail replies")
