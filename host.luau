--!nonstrict
-- The window half supplies agent snapshots and handles pane navigation.
local ui = tern.ui
local limits = require("./limits")
local LIST = "main.directory.agents"
local statuses = {
	working = { label = "Working", tone = "accent" },
	waiting_input = { label = "Waiting for you", tone = "warning" },
	idle = { label = "Idle", tone = "muted" },
	failed = { label = "Failed", tone = "error" },
}

local function item_id(pane, sub)
	local id = LIST .. ".p" .. string.format("%.0f", pane)
	return if sub then id .. ".s" .. sub.key else id
end

-- Rows in display order: each agent, then the subagents of its running tasks.
local function entries(state)
	local list = {}
	for _, agent in state.agents do
		table.insert(list, { agent = agent })
		for _, sub in agent.subagents or {} do table.insert(list, { agent = agent, sub = sub }) end
	end
	return list
end

local function selected_index(list, state)
	for i, entry in list do
		if entry.agent.pane == state.selected and (entry.sub and entry.sub.key) == state.sub then return i end
	end
	return 1
end

local function select_entry(state, entry)
	state.selected = if entry then entry.agent.pane else nil
	state.sub = if entry and entry.sub then entry.sub.key else nil
end

local function open_selected(state, cx)
	if state.selected then
		cx:open("tern-software-factory://pane/" .. string.format("%.0f", state.selected))
	end
end

local function inspect_selected(state, cx)
	if state.details and state.details.pane ~= state.selected then state.details = nil end
	if state.selected then
		cx:open("tern-software-factory://inspect/" .. string.format("%.0f", state.selected))
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

-- Where an agent works, as sent by the window; "—" before its cwd is known.
local function work_path(agent)
	local path = plain(agent.path or "")
	return if path ~= "" then path else "—"
end

-- The Path column fits about 24 monospace characters. Tern's text-overflow
-- ellipsis cuts the end, so a longer path drops leading directories instead:
-- `…/fixtures/deep/`. A single long directory name still ellipsizes.
local PATH_CHARS = 24
local function width(value) return utf8.len(value) or #value end
local function path_tail(path)
	if width(path) <= PATH_CHARS then return path end
	local segments = {}
	for segment in string.gmatch(path, "[^/]+") do table.insert(segments, segment) end
	local kept = segments[#segments] .. "/"
	for i = #segments - 1, 1, -1 do
		local longer = segments[i] .. "/" .. kept
		if width("…/" .. longer) > PATH_CHARS then break end
		kept = longer
	end
	return "…/" .. kept
end

local function sub_row(agent, sub)
	local status = sub_status(sub)
	local kind = plain(sub.agent)
	local name, doing, summary = plain(sub.name), sub_doing(sub), sub_summary(sub, false)
	return ui.node("item", {
		key = "p" .. string.format("%.0f", agent.pane) .. ".s" .. sub.key,
		role = "factory-subagent",
		-- The Path cell repeats the parent's path, muted, to keep columns aligned.
		label = {
			ui.span("↳ " .. (if kind ~= "" then kind else "subagent"), "muted"),
			ui.span(name, "strong"), ui.span(path_tail(work_path(agent)), "muted"), ui.span(doing, "muted"), ui.span(summary, "muted"),
		},
		detail = { ui.span("●", status.tone), ui.span(status.label, status.tone) },
		tone = status.tone,
		title = name .. "\n" .. kind .. " · " .. plain(sub.model) .. "\n" .. status.label .. "\n" .. doing .. "\n" .. sub_summary(sub, true),
		aria = "Subagent " .. name .. ", " .. status.label .. ", " .. doing .. ", " .. summary,
	})
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

local function project_of(cwd)
	local path = plain(cwd)
	return path:match("([^/\\]+)[/\\]*$") or (if path ~= "" then path else "—")
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
	local meta = { plain(agent.session), project_of(agent.cwd) }
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

local function sub_activity(agent, sub)
	local meta = { "Subagent of " .. project_of(agent.cwd) }
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

tern.block.define("agents", {
	init = function()
		return { agents = {}, selected = nil, loaded = false }
	end,
	title = function() return "Software Factory" end,
	view = function(state, cx)
		local rows = {}
		local counts = { working = 0, waiting_input = 0, idle = 0, failed = 0 }
		local subagents = 0
		for _, agent in state.agents do
			local status = row_status(agent)
			local category = if status.tone == "error" then "failed" else agent.state
			if counts[category] then counts[category] += 1 end
			local running = running_subagents(agent)
			subagents += running
			local note = if running > 0 then status.note .. " · " .. tostring(running) .. (if running == 1 then " subagent" else " subagents") else status.note
			local session = plain(agent.session)
			local title = plain(agent.title)
			local task = agent_task(agent)
			local model = plain(agent.model or "")
			if model == "" then model = "Model not reported" end
			local cwd = plain(agent.cwd)
			local project = project_of(agent.cwd)
			local path = work_path(agent)
			local work_dir = plain(agent.work_dir or "")
			-- Delivery errors replace the task; they need attention first.
			local doing = if agent.delivery_error and agent.delivery_error ~= "" then plain(agent.delivery_error) else task
			table.insert(rows, ui.node("item", {
				key = "p" .. string.format("%.0f", agent.pane),
				-- An untoned span renders as a bare text node, which cannot ellipsize.
				label = { ui.span(session, "muted"), ui.span(project, "strong"), ui.span(path_tail(path), "dir"), ui.span(doing, "task") },
				detail = { ui.span("●", status.tone), ui.span(status.label, status.tone), ui.span(note, "muted") },
				tone = status.tone,
				title = session .. "\n" .. project .. "\n" .. doing .. "\nSession: " .. title .. "\n" .. model
					.. "\n" .. status.label .. " · " .. note .. "\nPath: " .. (if work_dir ~= "" then work_dir else path)
					.. "\nWorking directory: " .. cwd,
				aria = session .. ", " .. project .. ", " .. path .. ", " .. doing .. ", " .. status.label .. ", " .. note .. ", " .. model,
			}))
			for _, sub in agent.subagents or {} do table.insert(rows, sub_row(agent, sub)) end
		end
		local list = entries(state)
		local entry = list[selected_index(list, state)]
		local selected = entry and entry.agent
		local heading = {
			ui.text({ ui.span("Agents", "bold") }),
			ui.badge(if state.loaded then tostring(#state.agents) else "…", "muted"),
		}
		for _, name in { "working", "waiting_input", "failed", "idle" } do
			if counts[name] > 0 then table.insert(heading, ui.badge(tostring(counts[name]) .. " " .. statuses[name].label, statuses[name].tone)) end
		end
		if subagents > 0 then
			table.insert(heading, ui.badge(tostring(subagents) .. (if subagents == 1 then " subagent" else " subagents"), "accent"))
		end
		return {
			main = ui.node("col", { role = "factory-agents" }, {
				ui.node("row", { role = "factory-heading" }, heading),
				ui.text({ ui.span("Across all sessions on this host", "muted") }),
				ui.node("col", { key = "directory", role = "factory-grid" }, {
					ui.node("row", { role = "factory-columns" }, {
						ui.node("row", { role = "factory-identifiers" }, {
							ui.text("Tern session"), ui.text("Project"), ui.text("Path"), ui.text("Agent task"),
						}),
						ui.text("Status"),
					}),
					ui.node("list", {
						key = "agents",
						selected = if entry then item_id(entry.agent.pane, entry.sub) else nil,
						empty = { ui.span(if state.loaded then "No agents are running on this host." else "Loading agents…", "muted") },
						max = 0.35,
					}, rows),
				}),
				if entry and entry.sub then sub_activity(entry.agent, entry.sub)
					elseif selected then activity(state, selected)
					else ui.text({ ui.span("Open an omp agent block to see its activity here.", "muted") }),
				limits.section(state.usage),
			}),
			dock = ui.node("col", { role = "factory-footer" }, {
				ui.text({ ui.span(if selected then selected.cwd else "Open an agent in Tern to see it here.", "muted") }),
				ui.text({ ui.span("↑ ↓", "bold"), ui.span("  Select     ", "muted"), ui.span("Enter", "bold"), ui.span("  Go to pane", "muted") }),
			}),
		}
	end,
	key = function(state, key, cx)
		if key.ctrl or key.alt or key.meta then return false end
		local list = entries(state)
		local count = #list
		if count == 0 then return false end
		local index = selected_index(list, state)
		if key.name == "down" or key.name == "j" then index = math.min(count, index + 1)
		elseif key.name == "up" or key.name == "k" then index = math.max(1, index - 1)
		elseif key.name == "home" then index = 1
		elseif key.name == "end" then index = count
		elseif key.name == "page_down" then index = math.min(count, index + 10)
		elseif key.name == "page_up" then index = math.max(1, index - 10)
		elseif key.name == "enter" then open_selected(state, cx); return true
		else return false end
		select_entry(state, list[index])
		inspect_selected(state, cx)
		return true
	end,
	event = function(state, event, cx)
		if event.ev == "action" and event.act == "factory_snapshot" then
			local previous = selected_index(entries(state), state)
			state.agents = event.agents or {}
			state.usage = event.usage
			state.loaded = true
			local list = entries(state)
			local agent_found, entry_found = false, false
			for _, entry in list do
				if entry.agent.pane == state.selected then
					agent_found = true
					if (entry.sub and entry.sub.key) == state.sub then entry_found = true end
				end
			end
			-- A finished task drops its subagents; keep the selection on their agent.
			if not agent_found then
				select_entry(state, list[math.min(previous, #list)])
			elseif not entry_found then
				state.sub = nil
			end
			inspect_selected(state, cx)
		elseif event.ev == "action" and event.act == "factory_details" then
			if event.details and event.details.pane == state.selected then state.details = event.details end
		elseif (event.ev == "select" or event.ev == "activate") and event.id == LIST then
			for _, entry in entries(state) do
				if item_id(entry.agent.pane, entry.sub) == event.item then
					select_entry(state, entry)
					inspect_selected(state, cx)
					if event.ev == "activate" then open_selected(state, cx) end
					return
				end
			end
		end
	end,
})
