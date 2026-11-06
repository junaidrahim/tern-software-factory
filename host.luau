--!nonstrict
-- The window half supplies agent snapshots and details through `tern.kv`
-- (see window.luau) and handles pane navigation.
local ui = tern.ui
local limits = require("./limits")
local ops = require("./ops/section")
local ops_controller = require("./ops/controller")
local news = require("./news/page")
local news_controller = require("./news/controller")
local models = require("./models/page")
local models_controller = require("./models/controller")
local github = require("./github/page")
local github_controller = require("./github/controller")
local repositories = require("./repositories/section")
local agents = require("./agents/page")
-- A block without its first agent list polls the store every LOADING_MS.
local REFRESH_MS, LOADING_MS = 1000, 200

-- A block's key in `tern.kv` and in links: its pane id's low 44 bits, the part
-- Tern's window API keeps (see window.luau's `key`).
local function key(pane)
	return string.format("%.0f", pane % 2^44)
end
local statuses = {
	working = { label = "Working", tone = "accent" },
	waiting_input = { label = "Waiting for you", tone = "warning" },
	idle = { label = "Idle", tone = "muted" },
	failed = { label = "Failed", tone = "error" },
}

local function select_entry(state, entry)
	state.selected = if entry then entry.agent.pane else nil
	state.sub = if entry and entry.sub then entry.sub.key else nil
end

-- Agent rows carry the window's pane ids, which Tern shortens to their low 44
-- bits; the window needs the full id to focus such a pane (window.luau's
-- `focus`). This host's pane list has it.
local function full_id(pane)
	for _, info in tern.pane.list() do
		if info.pane % 2^44 == pane then return info.pane end
	end
	return pane
end

-- Tern reports the focused pane, not the block, as a link's pane, so links
-- name the block.
local function open_selected(state, cx)
	if state.selected then
		cx:open("tern-software-factory://pane/" .. key(cx.pane) .. "/" .. string.format("%.0f", full_id(state.selected)))
	end
end

local function inspect_selected(state, cx)
	if state.details and state.details.pane ~= state.selected then state.details = nil end
	if state.selected then
		cx:open("tern-software-factory://inspect/" .. key(cx.pane) .. "/" .. string.format("%.0f", state.selected))
	end
end

local function age(seconds)
	if seconds < 60 then return tostring(seconds) .. "s ago" end
	if seconds < 3600 then return tostring(math.floor(seconds / 60)) .. "m ago" end
	return tostring(math.floor(seconds / 3600)) .. "h ago"
end

-- Tern renders a Private Use Area glyph (Nerd Font icons, such as omp's title
-- prefix) as a separate icon span. Row cells are laid out by span position, so
-- an extra span shifts every later cell. Row text omits these glyphs.
local function plain(value)
	local stripped = value
		:gsub("\xEE[\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xEF[\x80-\xA3][\x80-\xBF]", "")
		:gsub("\xF3[\xB0-\xBF][\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xF4[\x80-\x8F][\x80-\xBF][\x80-\xBF]", "")
	return (stripped:gsub("^%s+", ""):gsub("%s+$", ""))
end

local sub_statuses = {
	running = { label = "Running", tone = "accent" },
	done = { label = "Done", tone = "success" },
	failed = { label = "Failed", tone = "error" },
	aborted = { label = "Stopped", tone = "muted" },
	pending = { label = "Queued", tone = "muted" },
}

local function sub_status(sub)
	local status = sub_statuses[sub.status]
	if status then return status end
	local label = if sub.status ~= "" then sub.status:sub(1, 1):upper() .. sub.status:sub(2) else "Unknown"
	return { label = label, tone = "muted" }
end

local function duration(ms)
	local seconds = math.floor(ms / 1000)
	if seconds < 60 then return tostring(seconds) .. "s" end
	if seconds < 3600 then return string.format("%dm %02ds", seconds // 60, seconds % 60) end
	return string.format("%dh %02dm", seconds // 3600, seconds % 3600 // 60)
end

local function tokens(count)
	if count >= 1e6 then return string.format("%.1fM", count / 1e6) end
	if count >= 1e3 then return string.format("%.1fK", count / 1e3) end
	return string.format("%.0f", count)
end

local function short_model(model)
	return model:match("([^/]+)$") or model
end

-- One compact line: what the subagent is doing, or its assignment.
local function sub_doing(sub)
	if sub.status == "running" and sub.tool ~= "" then
		return plain(sub.tool .. (if sub.intent ~= "" then " · " .. sub.intent else ""))
	end
	local task = plain(sub.task)
	return if task ~= "" then task else "No activity yet"
end

local function sub_summary(sub, full)
	local parts = {}
	if not full and sub.model ~= "" then table.insert(parts, plain(short_model(sub.model))) end
	if sub.tokens then table.insert(parts, tokens(sub.tokens) .. (if full then " tokens" else " tok")) end
	if full and sub.context ~= "" then table.insert(parts, sub.context .. " context") end
	if full and sub.cost then table.insert(parts, string.format("$%.2f", sub.cost)) end
	if full and sub.requests then table.insert(parts, string.format("%.0f requests", sub.requests)) end
	if full and sub.tools then table.insert(parts, string.format("%.0f tools", sub.tools)) end
	if sub.elapsed_ms then table.insert(parts, duration(sub.elapsed_ms)) end
	return table.concat(parts, " · ")
end

local function running_subagents(agent)
	local count = 0
	for _, sub in agent.subagents or {} do
		if sub.status == "running" then count += 1 end
	end
	return count
end

-- The summary of recent activity; the omp session title until the first one arrives.
local function agent_task(agent)
	local task = plain(agent.task or "")
	if task ~= "" then return task end
	local title = plain(agent.title)
	return if title ~= "" then title else "Agent " .. string.format("%.0f", agent.pane)
end

local function row_status(agent)
	if agent.delivery_error and agent.delivery_error ~= "" then
		return { label = "Delivery failed", tone = "error", note = "Needs attention" }
	end
	if agent.state == "idle" and agent.last_turn == "failed" then
		return { label = "Failed", tone = "error", note = "Turn failed " .. age(agent.finished_seconds or 0) }
	end
	local status = statuses[agent.state] or { label = "Unknown", tone = "muted" }
	local note = if agent.state == "working" then "In progress"
		elseif agent.state == "waiting_input" then "Input requested"
		elseif agent.state == "idle" and agent.last_turn == "done" then "Completed " .. age(agent.finished_seconds or 0)
		elseif agent.state == "idle" then "Ready for work" else "State unavailable"
	return { label = status.label, tone = status.tone, note = note }
end

local function project_of(state, cwd)
	local repo = state.projects[cwd]
	return if repo and repo.name then plain(repo.name) else "—"
end

-- Resolve on the block's host, not the desktop, so remote paths stay remote.
-- Cache per working directory and refresh once a minute without blocking polling.
local function refresh_projects(state, cx)
	local active = {}
	for _, agent in state.agents do
		local cwd = agent.cwd
		if cwd == "" then continue end
		active[cwd] = true
		local repo = state.projects[cwd]
		if repo and (repo.running or tern.now() - repo.at < 60000) then continue end
		if not repo then
			repo = {}
			state.projects[cwd] = repo
		end
		repo.running, repo.at = true, tern.now()
		local ok = pcall(function()
			tern.process.run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, { timeout_ms = 5000 }, function(result)
				local root = if result.status == 0 and not result.timed_out
					then string.gsub(result.stdout, "[\r\n]+$", "") else ""
				repo.name = root:match("([^/]+)/*$")
				repo.running = false
				cx:render()
			end)
		end)
		if not ok then repo.name, repo.running = nil, false end
	end
	for cwd in state.projects do
		if not active[cwd] then state.projects[cwd] = nil end
	end
end

-- Panels share one shape: heading and status, one muted line of context,
-- then a single labelled section.
local function panel(title, status, meta, body)
	local children = {
		ui.node("row", { role = "factory-detail-heading" }, { ui.text({ ui.span(title, "bold") }), ui.badge(status.label, status.tone) }),
	}
	if #meta > 0 then
		table.insert(children, ui.node("row", { role = "factory-detail-meta" }, { ui.text({ ui.span(table.concat(meta, " · "), "muted") }) }))
	end
	for _, node in body do table.insert(children, node) end
	return ui.node("col", { key = "activity", role = "factory-activity" }, children)
end

local function section(key, label, content)
	return ui.node("col", { key = key, role = "factory-section" }, { ui.text({ ui.span(label, "muted") }), content })
end

local function note(text, tone)
	return ui.text({ ui.span(text, tone or "muted") })
end

local function activity(state, agent)
	local detail = state.details
	local ready = detail and detail.pane == agent.pane and not detail.unavailable
	local meta = { plain(agent.session), project_of(state, agent.cwd) }
	local path = plain(agent.path or "")
	if path ~= "" and path ~= "./" then table.insert(meta, path) end
	if agent.model and agent.model ~= "" then table.insert(meta, short_model(agent.model)) end
	if ready and detail.last_turn == "done" then table.insert(meta, "Turn completed " .. age(detail.finished_seconds)) end
	local body = {}
	if agent.delivery_error and agent.delivery_error ~= "" then
		table.insert(body, note("Prompt delivery failed: " .. agent.delivery_error, "error"))
	end
	if not detail or detail.pane ~= agent.pane then
		table.insert(body, note("Loading activity…"))
	elseif detail.unavailable then
		table.insert(body, note("This agent is no longer available."))
	else
		if detail.last_turn == "failed" then table.insert(body, note("Last turn failed " .. age(detail.finished_seconds), "error")) end
		local response = detail.response
		table.insert(body, section("response", if detail.response_source == "pane" then "Latest pane update" else "Latest response",
			if response ~= "" then ui.md(response) else note("No response yet.")))
		if detail.transcript_error then
			table.insert(body, note("Activity is temporarily unavailable. Retrying…"))
		elseif not detail.has_transcript then
			table.insert(body, note("Structured activity is available when omp publishes its chat to Tern."))
		end
	end
	local title = plain(agent.title)
	if title ~= "" and title ~= agent_task(agent) then table.insert(meta, "Session: " .. title) end
	return panel(agent_task(agent), row_status(agent), meta, body)
end

local function sub_activity(state, agent, sub)
	local meta = { "Subagent of " .. project_of(state, agent.cwd) }
	if sub.agent ~= "" then table.insert(meta, sub.agent) end
	if sub.model ~= "" then table.insert(meta, short_model(sub.model)) end
	if sub.thinking ~= "" then table.insert(meta, (sub.thinking:gsub("^thinking", ""):lower()) .. " thinking") end
	local body = {}
	if sub.status == "running" and sub.tool ~= "" then
		local line = { ui.span("Running ", "muted"), ui.span(sub.tool, "bold") }
		if sub.intent ~= "" then table.insert(line, ui.span(" · " .. sub.intent)) end
		if sub.tool_ms then table.insert(line, ui.span(" · " .. duration(sub.tool_ms), "muted")) end
		table.insert(body, ui.text(line))
	end
	local stats = sub_summary(sub, true)
	if stats ~= "" then table.insert(body, note(stats)) end
	if sub.task ~= "" then table.insert(body, section("assignment", "Assignment", ui.text(sub.task))) end
	return panel(plain(sub.name), sub_status(sub), meta, body)
end

-- Entries time events on the window's clock and carry that clock as `clock`
-- when written; `shift` moves such a time onto this half's clock.
local function shift(data)
	return if type(data.clock) == "number" then tern.now() - data.clock else 0
end

-- Ages shown in the view, refreshed each poll: an entry is written only when it changes.
local function age(state)
	local now = tern.now()
	local function seconds(at) return if at then math.max(0, math.floor((now - at) / 1000)) else nil end
	for _, agent in state.agents do agent.finished_seconds = seconds(agent.finished_here) end
	if state.usage then state.usage.age_ms = if state.usage.at_here then now - state.usage.at_here else 0 end
	if state.details then state.details.finished_seconds = seconds(state.details.finished_here) end
end

local function apply_snapshot(state, data, cx)
	local offset = shift(data)
	state.agents = data.agents or {}
	for _, agent in state.agents do
		if agent.finished_at then agent.finished_here = agent.finished_at + offset end
	end
	state.usage = data.usage
	if state.usage and state.usage.at then state.usage.at_here = state.usage.at + offset end
	state.loaded = true
	local agent_found, sub_found = false, false
	for _, agent in state.agents do
		if agent.pane == state.selected then
			agent_found = true
			for _, sub in agent.subagents or {} do
				if sub.key == state.sub then sub_found = true end
			end
		end
	end
	-- The Agents page's cursor falls back to the repository of an agent that left;
	-- a finished task drops its subagents, leaving their agent selected.
	if not agent_found then
		select_entry(state, nil)
	elseif state.sub and not sub_found then
		state.sub = nil
	end
	if state.page == "agents" then inspect_selected(state, cx) end
end

-- Per open block: its state and cx, and the `seq` of the snapshot and details it applied.
local blocks = {}
-- The pending poll, rescheduled sooner when a block opens.
local next_poll, poll

local function schedule(ms)
	if next_poll then next_poll:cancel() end
	next_poll = tern.timer(ms, poll)
end

function poll()
	local open, loading = {}, false
	for _, pane in tern.pane.list() do open[pane.pane] = true end
	for pane, block in blocks do
		local id = key(pane)
		if not open[pane] then
			blocks[pane] = nil
			news_controller.detach(pane)
			models_controller.detach(pane)
			github_controller.detach(pane)
			ops_controller.detach(pane)
			pcall(tern.kv.set, "snapshot:" .. id, nil)
			pcall(tern.kv.set, "details:" .. id, nil)
			continue
		end
		local ok, snapshot, details = pcall(function() return tern.kv.get("snapshot:" .. id), tern.kv.get("details:" .. id) end)
		local changed = false
		if ok and type(snapshot) == "table" and snapshot.seq ~= block.snapshot then
			block.snapshot, changed = snapshot.seq, true
			apply_snapshot(block.state, snapshot, block.cx)
		end
		if ok and type(details) == "table" and details.seq ~= block.details then
			block.details = details.seq
			-- A late reply for a previous selection must not replace the current one.
			if type(details.details) == "table" and details.details.pane == block.state.selected then
				local value = details.details
				if value.finished_at then value.finished_here = value.finished_at + shift(details) end
				block.state.details, changed = value, true
			end
		end
		refresh_projects(block.state, block.cx)
		if block.state.loaded then
			-- Ages advance without a new entry.
			age(block.state)
			changed = true
		else
			loading = true
		end
		if changed then pcall(function() block.cx:render() end) end
	end
	news_controller.tick()
	models_controller.tick()
	ops_controller.tick()
	schedule(if loading then LOADING_MS else REFRESH_MS)
end

local agents_page = agents.create({
	plain = plain, statuses = statuses, row_status = row_status, agent_task = agent_task,
	running_subagents = running_subagents, sub_status = sub_status, sub_doing = sub_doing, sub_summary = sub_summary,
	panel = panel, section = section, note = note, activity = activity, sub_activity = sub_activity,
	select_entry = select_entry, inspect_selected = inspect_selected, open_selected = open_selected,
	block_key = key, repositories = repositories,
})

-- Register pages here. Each supplies a view and optional key/event handlers.
-- Views return region containers; the shell adds navigation to main. A page's
-- `init` result lives in `state[page.state or page.id]`.
local pages = {
	agents_page,
	{
		id = "limits", label = "Limits", enter = ops.enter, key = ops.key, event = ops.event,
		view = function(state)
			return { main = ui.node("col", {}, { limits.section(state.usage), ops.section() }) }
		end,
	},
	{
		id = "news", label = "News", init = news.init, save = news.save, enter = news.enter,
		view = news.view, key = news.key, event = news.event, capture_key = news.capture_key,
	},
	{
		id = "models", label = "Models", init = models.init, save = models.save, enter = models.enter,
		view = models.view, key = models.key, event = models.event, capture_key = models.capture_key,
	},
	{
		id = "github", label = "GitHub", init = github.init, save = github.save, enter = github.enter,
		view = github.view, key = github.key, event = github.event,
	},
}
local page_by_id, tabs = {}, {}
for _, page in pages do
	page_by_id[page.id] = page
	table.insert(tabs, { id = page.id, label = page.label })
end

local function select_page(state, id, cx)
	if not page_by_id[id] or state.page == id then return end
	state.page = id
	if id == "agents" then inspect_selected(state, cx) end
	local page = page_by_id[id]
	if page.enter then page.enter(state, cx) end
end

tern.block.define("agents", {
	init = function(cx, _, saved)
		local page = if type(saved) == "table" and page_by_id[saved.page] then saved.page else pages[1].id
		local state = { page = page, agents = {}, projects = {}, selected = nil, loaded = false }
		local saved_pages = if type(saved) == "table" and type(saved.pages) == "table" then saved.pages else {}
		-- The repository root and scan, shown by Agents.
		state.repositories = repositories.init(saved_pages.agents)
		for _, entry in pages do
			if entry.init then
				state[entry.state or entry.id] = entry.init(saved_pages[entry.id])
			end
		end
		blocks[cx.pane] = { state = state, cx = cx }
		schedule(LOADING_MS)
		if page_by_id[page].enter then page_by_id[page].enter(state, cx) end
		return state
	end,
	save = function(state)
		local saved_pages = {}
		for _, page in pages do
			if page.save then saved_pages[page.id] = page.save(state) end
		end
		return { page = state.page, pages = saved_pages }
	end,
	title = function() return "Software Factory" end,
	view = function(state, cx)
		local view = page_by_id[state.page].view(state, cx)
		view.main.p = view.main.p or {}
		view.main.c = view.main.c or {}
		view.main.p.role = "factory-pages"
		table.insert(view.main.c, 1, ui.node("tabs", {
			key = "pages", role = "factory-tabs", items = tabs, active = state.page,
		}))
		return view
	end,
	key = function(state, key, cx)
		local page = page_by_id[state.page]
		if page.capture_key and page.capture_key(state, key, cx) then return true end
		if not key.ctrl and not key.alt and not key.meta and (key.name == "left" or key.name == "right") then
			for i, page in pages do
				if page.id == state.page then
					local delta = if key.name == "right" then 1 else -1
					select_page(state, pages[(i - 1 + delta) % #pages + 1].id, cx)
					return true
				end
			end
		end
		return if page.key then page.key(state, key, cx) else false
	end,
	event = function(state, event, cx)
		if event.ev == "select" and event.id == "main.pages" then
			select_page(state, event.item, cx)
			return
		end
		local page = page_by_id[state.page]
		if page.event then page.event(state, event, cx) end
	end,
})

schedule(0)
