--!nonstrict
-- The window half supplies agent snapshots and handles pane navigation.
local ui = tern.ui
local LIST = "main.directory.agents"
local statuses = {
	working = { label = "Working", tone = "accent" },
	waiting_input = { label = "Waiting for you", tone = "warning" },
	idle = { label = "Idle", tone = "muted" },
	failed = { label = "Failed", tone = "error" },
}

local function item_id(pane)
	return LIST .. ".p" .. string.format("%.0f", pane)
end

local function selected_index(state)
	for i, agent in state.agents do
		if agent.pane == state.selected then return i end
	end
	return 1
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

local function activity(state, agent)
	local detail = state.details
	local status = row_status(agent)
	local header = { ui.text({ ui.span(agent.title, "bold") }), ui.badge(status.label, status.tone) }
	if agent.model and agent.model ~= "" then table.insert(header, ui.badge(agent.model, "muted")) end
	local children = { ui.node("row", { role = "factory-detail-heading" }, header) }
	if agent.delivery_error and agent.delivery_error ~= "" then
		table.insert(children, ui.text({ ui.span("Prompt delivery failed: " .. agent.delivery_error, "error") }))
	end
	if not detail or detail.pane ~= agent.pane then
		table.insert(children, ui.text({ ui.span("Loading activity…", "muted") }))
	elseif detail.unavailable then
		table.insert(children, ui.text({ ui.span("This agent is no longer available.", "muted") }))
	else
		if detail.last_turn then
			local failed = detail.last_turn == "failed"
			table.insert(children, ui.text({ ui.span(
				(if failed then "Last turn failed" else "Last turn completed") .. " · " .. age(detail.finished_seconds),
				if failed then "error" else "muted"
			) }))
		end
		if detail.request ~= "" then
			table.insert(children, ui.node("col", { key = "request", role = "factory-request" }, {
				ui.text({ ui.span("Latest request", "muted") }), ui.text(detail.request),
			}))
		end
		local response = detail.response
		table.insert(children, ui.node("col", { key = "response", role = "factory-response" }, {
			ui.text({ ui.span(if detail.response_source == "pane" then "Latest pane update" else "Latest response", "muted") }),
			if response ~= "" then ui.md(response) else ui.text({ ui.span("No response yet.", "muted") }),
		}))
		if detail.transcript_error then
			table.insert(children, ui.text({ ui.span("Activity is temporarily unavailable. Retrying…", "muted") }))
		elseif not detail.has_transcript then
			table.insert(children, ui.text({ ui.span("Structured activity is available when omp publishes its chat to Tern.", "muted") }))
		end
	end
	return ui.node("col", { key = "activity", role = "factory-activity" }, children)
end

tern.block.define("agents", {
	init = function()
		return { agents = {}, selected = nil, loaded = false }
	end,
	title = function() return "Software Factory" end,
	view = function(state, cx)
		local rows = {}
		local counts = { working = 0, waiting_input = 0, idle = 0, failed = 0 }
		for _, agent in state.agents do
			local status = row_status(agent)
			local category = if status.tone == "error" then "failed" else agent.state
			if counts[category] then counts[category] += 1 end
			local session = plain(agent.session)
			local title = plain(agent.title)
			if title == "" then title = "Agent " .. string.format("%.0f", agent.pane) end
			local model = plain(agent.model or "")
			if model == "" then model = "Model not reported" end
			local preview = plain(if agent.delivery_error and agent.delivery_error ~= "" then agent.delivery_error else agent.preview or "")
			if preview == "" then preview = "No update yet" end
			local cwd = plain(agent.cwd)
			local path = if cwd ~= "" then cwd else "—"
			local project = cwd:match("([^/\\]+)[/\\]*$") or path
			table.insert(rows, ui.node("item", {
				key = "p" .. string.format("%.0f", agent.pane),
				label = {
					ui.span(session, "muted"), ui.span(title, "strong"),
					ui.span(model, "muted"), ui.span(preview, "muted"),
				},
				detail = { ui.span("●", status.tone), ui.span(status.label, status.tone), ui.span(status.note, "muted") },
				value = { ui.span(project, "strong"), ui.span(path, "muted") },
				tone = status.tone,
				title = session .. "\n" .. title .. "\n" .. model .. "\n" .. status.label .. " · " .. status.note .. "\n" .. preview .. "\n" .. cwd,
				aria = session .. ", " .. title .. ", " .. status.label .. ", " .. model .. ", " .. preview .. ", " .. path,
			}))
		end
		local selected = state.agents[selected_index(state)]
		local heading = {
			ui.text({ ui.span("Agents", "bold") }),
			ui.badge(if state.loaded then tostring(#rows) else "…", "muted"),
		}
		for _, name in { "working", "waiting_input", "failed", "idle" } do
			if counts[name] > 0 then table.insert(heading, ui.badge(tostring(counts[name]) .. " " .. statuses[name].label, statuses[name].tone)) end
		end
		return {
			main = ui.node("col", { role = "factory-agents" }, {
				ui.node("row", { role = "factory-heading" }, heading),
				ui.text({ ui.span("Across all sessions on this host", "muted") }),
				ui.node("col", { key = "directory", role = "factory-grid" }, {
					ui.node("row", { role = "factory-columns" }, {
						ui.node("row", { role = "factory-identifiers" }, { ui.text("Tern session"), ui.text("Agent session") }),
						ui.text("Status"), ui.text("Path"),
					}),
					ui.node("list", {
						key = "agents",
						selected = if state.selected then item_id(state.selected) else nil,
						empty = { ui.span(if state.loaded then "No agents are running on this host." else "Loading agents…", "muted") },
						max = 0.35,
					}, rows),
				}),
				if selected then activity(state, selected) else ui.text({ ui.span("Open an omp agent block to see its activity here.", "muted") }),
			}),
			dock = ui.node("col", { role = "factory-footer" }, {
				ui.text({ ui.span(if selected then selected.cwd else "Open an agent in Tern to see it here.", "muted") }),
				ui.text({ ui.span("↑ ↓", "bold"), ui.span("  Select     ", "muted"), ui.span("Enter", "bold"), ui.span("  Go to pane", "muted") }),
			}),
		}
	end,
	key = function(state, key, cx)
		if key.ctrl or key.alt or key.meta then return false end
		local count = #state.agents
		if count == 0 then return false end
		local index = selected_index(state)
		if key.name == "down" or key.name == "j" then index = math.min(count, index + 1)
		elseif key.name == "up" or key.name == "k" then index = math.max(1, index - 1)
		elseif key.name == "home" then index = 1
		elseif key.name == "end" then index = count
		elseif key.name == "page_down" then index = math.min(count, index + 10)
		elseif key.name == "page_up" then index = math.max(1, index - 10)
		elseif key.name == "enter" then open_selected(state, cx); return true
		else return false end
		state.selected = state.agents[index].pane
		inspect_selected(state, cx)
		return true
	end,
	event = function(state, event, cx)
		if event.ev == "action" and event.act == "factory_snapshot" then
			local previous = selected_index(state)
			state.agents = event.agents or {}
			state.loaded = true
			local found = false
			for _, agent in state.agents do if agent.pane == state.selected then found = true; break end end
			if not found then
				local nextAgent = state.agents[math.min(previous, #state.agents)]
				state.selected = if nextAgent then nextAgent.pane else nil
			end
			inspect_selected(state, cx)
		elseif event.ev == "action" and event.act == "factory_details" then
			if event.details and event.details.pane == state.selected then state.details = event.details end
		elseif (event.ev == "select" or event.ev == "activate") and event.id == LIST then
			for _, agent in state.agents do
				if item_id(agent.pane) == event.item then
					state.selected = agent.pane
					inspect_selected(state, cx)
					if event.ev == "activate" then open_selected(state, cx) end
					return
				end
			end
		end
	end,
})
