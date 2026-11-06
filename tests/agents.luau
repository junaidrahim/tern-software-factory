-- The Agents page, its repository grouping and its Carly requests, against
-- deterministic Tern stubs.
local function node(kind, props, children) return { k = kind, p = props or {}, c = children } end
local store, toasts, opened, inspected, focusedLinks = {}, {}, {}, {}, {}
local exports = {}
local tern = {
	getenv = function(name) return if name == "HOME" then "/code" else nil end,
	json = { null = newproxy() },
	kv = { get = function(key) return store[key] end, set = function(key, value) store[key] = value end },
	ui = {
		node = node,
		span = function(t, s) return { t = t, s = s } end,
		text = function(spans) return node("text", { text = spans }) end,
		badge = function(t, tone) return node("badge", { text = t, tone = tone }) end,
		kv = function(items) return node("kv", { items = items }) end,
	},
	carly = { export = function(name, spec, fn) exports[name] = { spec = spec, fn = fn } end },
}
local tree = (function()
-- AGENTS_TREE_SOURCE
end)()
local page = (function()
local require = function() return tree end
-- AGENTS_PAGE_SOURCE
end)()
local carly = (function()
-- AGENTS_CARLY_SOURCE
end)()

-- Grouping: the deepest checkout holding an agent's cwd wins; a sibling with a shared
-- name prefix is not inside; agents outside every repository come after busy repositories.
local repos = {
	{ path = "/code/app", name = "app", branch = "main", worktrees = {
		{ path = "/code/app/.claude/worktrees/fix", branch = "fix/login" },
		{ path = "/wt/app-feature", branch = "feature/x" },
	} },
	{ path = "/code/app2", name = "app2", branch = "main", worktrees = {} },
	{ path = "/code/quiet", name = "quiet", branch = "trunk", worktrees = {} },
}
local agents = {
	{ pane = 1, cwd = "/code/app/src", state = "working", session = "Main", title = "Refactor" },
	{ pane = 2, cwd = "/code/app/.claude/worktrees/fix/", state = "idle", session = "Fixes", title = "Fix login",
		subagents = { { key = "43_A", name = "Alpha", agent = "task", status = "running" } } },
	{ pane = 3, cwd = "/code/app2", state = "waiting_input", session = "Main", title = "Release" },
	{ pane = 4, cwd = "/tmp", state = "idle", session = "Scratch", title = "Notes" },
	{ pane = 5, cwd = "/wt/app-feature/lib", state = "idle", session = "Main", title = "Feature" },
}
assert(tree.tilde("/Users/me/Code", "/Users/me/") == "~/Code" and tree.tilde("/Users/me", "/Users/me") == "~"
	and tree.tilde("/Users/meow/x", "/Users/me") == "/Users/meow/x" and tree.tilde("/tmp", nil) == "/tmp",
	"Only the home directory itself and paths under it read as ~")
local groups = tree.group(repos, agents)
assert(#groups == 4 and groups[1].repo.name == "app" and groups[2].repo.name == "app2" and groups[3].other
	and groups[4].repo.name == "quiet", "Busy repositories, then other agents, then quiet repositories")
assert(#groups[1].agents == 3 and #groups[2].agents == 1, "/code/app2 is not inside /code/app")
assert(tree.describe(groups[1].agents[1].checkout) == "main checkout · main")
assert(tree.describe(groups[1].agents[2].checkout) == "fix · fix/login", "A worktree inside its repository claims its agents")
assert(tree.describe(groups[1].agents[3].checkout) == "app-feature · feature/x")

-- The page, with the Agents page's helpers stubbed.
local statuses = {
	working = { label = "Working", tone = "accent" }, waiting_input = { label = "Waiting for you", tone = "warning" },
	idle = { label = "Idle", tone = "muted" }, failed = { label = "Failed", tone = "error" },
}
local h = {
	plain = function(value) return value end,
	statuses = statuses,
	row_status = function(agent) local s = statuses[agent.state]; return { label = s.label, tone = s.tone, note = "note" } end,
	agent_task = function(agent) return agent.title end,
	running_subagents = function(agent) return #(agent.subagents or {}) end,
	sub_status = function() return { label = "Running", tone = "accent" } end,
	sub_doing = function() return "bash" end,
	sub_summary = function() return "1.0K tok" end,
	panel = function(title, status, meta, body) return node("panel", { title = title, status = status, meta = meta }, body) end,
	section = function(key, label, content) return node("section", { key = key, label = label }, { content }) end,
	note = function(text) return node("note", { text = text }) end,
	activity = function(_, agent) return node("activity", { pane = agent.pane }) end,
	sub_activity = function(_, agent, sub) return node("sub-activity", { pane = agent.pane, sub = sub.key }) end,
	select_entry = function(state, entry) state.selected, state.sub = entry.agent.pane, entry.sub and entry.sub.key end,
	inspect_selected = function(state) table.insert(inspected, state.selected) end,
	open_selected = function(state) table.insert(focusedLinks, state.selected) end,
	block_key = function(pane) return string.format("%.0f", pane % 2^44) end,
	repositories = {
		enter = function() end, scan = function(state) state.repositories.scanned = (state.repositories.scanned or 0) + 1 end,
		buttons = function() return { node("button", { key = "root-folder" }) } end,
		layer = function() return node("col", { role = "root-layer" }) end,
		event = function(_, event) return event.ev == "action" and event.act == "repositories-root" end,
		capture_key = function() return false end,
	},
}
local Page = page.create(h)
local cx = { pane = 2^44 + 7, open = function(_, url) table.insert(opened, url) end,
	toast = function(_, level, text) table.insert(toasts, { level, text }) end }
local state = { agents = agents, loaded = true, repositories = { root = "/code", repos = repos, loading = false, warnings = { "Skipped x" } } }
state.tree = Page.init(nil)
local function key(name) return Page.key(state, { name = name }, cx) end
local function rows() return Page.view(state, cx).main.c[3].c[2] end
local function labels()
	local result = {}
	for _, item in rows().c do table.insert(result, item.p.key) end
	return table.concat(result, " ")
end

Page.enter(state, cx)
assert(labels() == "r%2Fcode%2Fapp a1 a2 a2.s43_A a5 r%2Fcode%2Fapp2 a3 other a4 r%2Fcode%2Fquiet",
	"Repositories, then their agents and subagents, in tree order")
local view = Page.view(state, cx)
local repoRow = rows().c[1].p
assert(repoRow.role == "factory-tree-repo" and repoRow.label[1].t == "▾ app" and repoRow.label[3].t == "2 worktrees"
	and repoRow.detail[1].t == "1 working · 2 idle")
local agentRow = rows().c[3].p
assert(agentRow.label[1].t == "Fix login" and agentRow.label[2].t == "fix · fix/login" and agentRow.label[3].t == "Fixes",
	"An agent row shows its task, worktree and session")
assert(rows().c[10].p.role == "factory-tree-repo-quiet" and rows().c[10].p.detail[1].t == "No agents")
assert(view.main.c[4].k == "panel" and view.main.c[4].p.title == "app", "A repository row shows its repository panel")
assert(view.main.c[4].p.meta[1] == "~/app" and view.main.c[2].c[1].p.text[1].t == "By repository under ~"
	and view.dock.c[1].p.text[1].t == "~/app", "Paths under the home directory read as ~")
assert(view.main.c[2].c[2].p.text[1].t == "Skipped x", "Scan warnings show under the subtitle")
assert(view.main.c[1].c[#view.main.c[1].c].p.key == "root-folder" and view.layer.p.role == "root-layer",
	"The root folder buttons and dialog live on Agents")
assert(Page.id == "agents" and Page.label == "Agents" and Page.state == "tree")
assert(rows().c[9].p.label[2].t == "/tmp", "A path outside the home directory stays whole")

-- Moving onto an agent selects it for the activity panel; Enter goes to its pane.
key("down"); key("down")
assert(state.selected == 2 and inspected[#inspected] == 2 and Page.view(state, cx).main.c[4].p.pane == 2)
key("enter")
assert(focusedLinks[#focusedLinks] == 2, "Enter on an agent goes to its pane")
key("down")
assert(state.selected == 2 and state.sub == "43_A" and Page.view(state, cx).main.c[4].k == "sub-activity")

-- Enter on a repository folds it; the cursor stays on the repository.
key("home"); key("enter")
assert(labels() == "r%2Fcode%2Fapp r%2Fcode%2Fapp2 a3 other a4 r%2Fcode%2Fquiet" and rows().c[1].p.label[1].t == "▸ app")
local saved = Page.save(state)
local restored = Page.init(saved)
assert(restored.folded["r%2Fcode%2Fapp"] == true and restored.cursor == "r%2Fcode%2Fapp", "Folds and the cursor are saved")
key("enter")
key("down"); key("down")
assert(state.tree.cursor == "a2")
-- An agent that leaves gives the cursor back to its repository.
table.remove(agents, 2)
assert(Page.view(state, cx).main.c[3].c[2].p.selected == "main.tree.rows.r%2Fcode%2Fapp")
-- Clicking a row selects it; double-clicking a repository opens a terminal block at its
-- path, and double-clicking an agent goes to its pane.
Page.event(state, { ev = "select", id = "main.tree.rows", item = "main.tree.rows.a3" }, cx)
assert(state.selected == 3)
Page.event(state, { ev = "activate", id = "main.tree.rows", item = "main.tree.rows.r%2Fcode%2Fapp2" }, cx)
assert(opened[#opened] == "tern-software-factory://repo-block/" .. string.format("%.0f", 2^44 + 7) .. "/%2Fcode%2Fapp2"
	and not state.tree.folded["r%2Fcode%2Fapp2"], "Double-clicking a repository opens a terminal there")
Page.event(state, { ev = "activate", id = "main.tree.rows", item = "main.tree.rows.a3" }, cx)
assert(focusedLinks[#focusedLinks] == 3)
-- Cmd+Enter on a repository opens a new session there; on an agent it does nothing. r rescans.
Page.event(state, { ev = "select", id = "main.tree.rows", item = "main.tree.rows.r%2Fcode%2Fapp2" }, cx)
Page.key(state, { name = "enter", meta = true }, cx)
assert(opened[#opened] == "tern-software-factory://repo-session/" .. string.format("%.0f", 2^44 + 7) .. "/%2Fcode%2Fapp2")
Page.event(state, { ev = "select", id = "main.tree.rows", item = "main.tree.rows.a3" }, cx)
local launches = #opened
Page.key(state, { name = "enter", meta = true }, cx)
assert(#opened == launches, "Cmd+Enter on an agent starts no session")
key("r")
assert(state.repositories.scanned == 1)
Page.event(state, { ev = "action", act = "repositories-root" }, cx)
assert(#opened == launches, "Root folder actions go to the repositories section")

-- Asking Carly from an agent row saves its repository's request and names the block by its full id.
Page.event(state, { ev = "select", id = "main.tree.rows", item = "main.tree.rows.a5" }, cx)
key("c")
assert(opened[#opened] == "tern-software-factory://carly/" .. string.format("%.0f", 2^44 + 7))
local request = store["carly:7"]
assert(request.repo.path == "/code/app" and #request.worktrees == 3 and request.worktrees[1].main
	and request.agents[2].worktree == "/wt/app-feature" and request.agents[2].session == "Main")
-- Other agents have no repository to start in.
Page.event(state, { ev = "select", id = "main.tree.rows", item = "main.tree.rows.a4" }, cx)
local before = #opened
key("c")
assert(#opened == before and toasts[#toasts][2] == "Choose a repository")
-- With no root folder, the page says where to set one.
local rootless = { agents = {}, loaded = true, repositories = { root = "", repos = {}, loading = false, warnings = {} }, tree = Page.init(nil) }
assert(Page.view(rootless, cx).main.c[2].c[1].p.text[1].t:find("Choose a root folder", 1, true))

-- The window: the link prompts, then asks Carly with the repository's context and the
-- sessions that have panes in its checkouts.
local route = function(request, cx, ...) return carly.route(request, cx, ...) end
local blocks = { { pane = 7, block = "tern-software-factory.agents" } }
local function find_block(_, block_key)
	for _, block in blocks do if string.format("%.0f", block.pane % 2^44) == block_key then return block end end
end
local function blockKey(pane) return string.format("%.0f", pane % 2^44) end
local pending, asked = nil, nil
local windowCx
windowCx = {
	sessions = {
		list = function() return { { id = 1, name = "Main" }, { id = 2, name = "Fixes" }, { id = 3, name = "Scratch" } } end,
		switch = function(_, session) windowCx.current = session end,
		current = function() return { name = windowCx.current or "Main" } end,
	},
	session = {
		tabs = function() return { { id = 10, session = 1 }, { id = 20, session = 2 }, { id = 30, session = 3 } } end,
		panes = function()
			return {
				{ pane = 1, tab = 10, cwd = "/code/app/src" }, { pane = 6, tab = 10, cwd = "/code/app" },
				{ pane = 2, tab = 20, cwd = "/code/app/.claude/worktrees/fix" }, { pane = 4, tab = 30, cwd = "/tmp" },
				{ pane = 8, tab = 30, cwd = "/code/app2" },
			}
		end,
	},
	agents = {
		list = function() return { { pane = 1, state = "working" }, { pane = 2, state = "idle" } } end,
		start = function(_, opts) windowCx.started = opts; return 99 end,
	},
	prompt = function(_, opts)
		windowCx.prompted = opts
		return { next = function(_, fn) pending = fn end }
	end,
	toast = function(_, level, text) table.insert(toasts, { level, text }) end,
	ask_carly = function(_, text) asked = text end,
}
assert(route({ url = "https://example.com" }, windowCx, find_block, blockKey) == nil)
assert(route({ url = "tern-software-factory://carly/" .. string.format("%.0f", 2^44 + 7) }, windowCx, find_block, blockKey).handled)
assert(windowCx.prompted.placeholder == "Ask Carly to start an agent in app…" and store["carly:7"] == nil,
	"The request is read once")
pending("   ", nil, windowCx)
assert(asked == nil, "A blank request asks nothing")
pending("Add a dark mode toggle", nil, windowCx)
assert(asked:sub(1, 22) == "Add a dark mode toggle")
assert(asked:find("- /code/app/.claude/worktrees/fix (fix · fix/login)", 1, true), "Carly gets the checkouts")
assert(asked:find("- \"Main\": 2 panes, 1 agent", 1, true) and asked:find("- \"Fixes\": 1 pane, 1 agent", 1, true)
	and not asked:find("Scratch", 1, true), "Carly gets only the sessions with panes in the repository")
assert(asked:find("start_agent(cwd, prompt, session)", 1, true))
-- A link from a closed block, or a request that is gone, asks nothing.
pending = nil
assert(route({ url = "tern-software-factory://carly/999" }, windowCx, find_block, blockKey).handled and pending == nil)
route({ url = "tern-software-factory://carly/7" }, windowCx, find_block, blockKey)
assert(pending == nil and toasts[#toasts][2] == "Cannot ask Carly")

-- Carly's export: an omitted session shifts cx forward; a named one is switched to first.
carly.register()
local start = exports.start_agent.fn
local result = start("/code/app", "Fix the build", windowCx, {})
assert(windowCx.started.cwd == "/code/app" and windowCx.started.prompt == "Fix the build" and windowCx.started.how == "tab"
	and result.pane == 99 and windowCx.current == nil, "Without a session the agent starts in the current one")
result = start("/wt/app-feature", "Ship it", "Fixes", windowCx, {})
assert(windowCx.current == "Fixes" and result.session == "Fixes" and windowCx.started.cwd == "/wt/app-feature")
result = start("/code/app", "Again", tern.json.null, windowCx, {})
assert(result.session == "Fixes", "A JSON null session keeps the current session")
assert(not pcall(start, "relative/dir", "Go", windowCx, {}), "cwd must be absolute")
assert(not pcall(start, "/code/app", "  ", windowCx, {}), "An empty prompt is refused")
print("PASS: Agents repository tree, worktree column, folding, selection, root folder, sessions, Carly requests and start_agent")
