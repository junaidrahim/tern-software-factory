--!nonstrict
-- Agent discovery and layout navigation are window APIs. Send snapshots to
-- each block on the corresponding host. Inspect only the selected agent.
local BLOCK = "tern-software-factory.agents"
local LIMITS_REFRESH_MS = 60000
-- Agent task: a one-sentence summary of the last few minutes of activity,
-- refreshed at most once a minute per agent, and only after new activity.
local TASK_WINDOW_MS, TASK_REFRESH_MS = 180000, 60000
local TASK_PROMPT = "You summarize what a coding agent has been doing. Reply with one plain sentence of at most "
	.. "16 words, present tense, starting with a verb, about the task rather than individual tools. No quotes or preamble."
local tracking = require("./tracking")
local limits = require("./limits")
local finished, details = {}, {}
-- The latest `omp usage` result: data survives a failed refresh, with its error.
local usage = { data = nil, error = nil, at = nil, attempted = nil, running = false }
-- Per pane: chat steps with the time each first appeared, and the latest summary.
local logs, tasks = {}, {}
local summarizing = false

local function text(value, fallback)
	return if type(value) == "string" and value ~= "" then value else (fallback or "")
end

-- Prefer the omp that Tern installs; otherwise rely on PATH.
local function omp_command()
	local home = tern.getenv("HOME")
	local bundled = if home then home .. "/Library/Application Support/Tern/omp/bin/omp" else nil
	if bundled and tern.fs.exists(bundled) then return bundled end
	return "omp"
end

local function refresh_usage()
	usage.running, usage.attempted = true, tern.now()
	local function fail(message)
		usage.running, usage.error = false, message
	end
	local ok, err = pcall(function()
		tern.process.run({ omp_command(), "usage", "--json" }, { timeout_ms = 30000 }, function(result)
			if result.timed_out then return fail("omp usage timed out. Retrying in a minute.") end
			if result.status ~= 0 then
				local line = string.match(result.stderr or "", "[^\n]+") or ("exit " .. tostring(result.status))
				return fail("omp usage failed: " .. line)
			end
			local data, problem = limits.parse(result.stdout)
			if not data then return fail(problem) end
			usage.running, usage.data, usage.error, usage.at = false, data, nil, tern.now()
		end)
	end)
	if not ok then fail("Cannot run omp: " .. tostring(err)) end
end

-- Refreshes at most once a minute; omp also caches provider reports.
local function usage_snapshot()
	if not usage.running and (not usage.attempted or tern.now() - usage.attempted >= LIMITS_REFRESH_MS) then
		refresh_usage()
	end
	return {
		data = usage.data, error = usage.error,
		age_ms = if usage.at then tern.now() - usage.at else 0,
	}
end

-- Record chat steps the first time they appear; the window keeps no transcript.
local function track(cx, pane)
	local ok, messages = pcall(function() return cx.agents:transcript(pane, { last = 12 }) end)
	if not ok or type(messages) ~= "table" then return end
	local log = logs[pane] or { seen = {}, entries = {} }
	logs[pane] = log
	for _, entry in tracking.activity(messages) do
		if not log.seen[entry.key] then
			log.seen[entry.key] = true
			table.insert(log.entries, { key = entry.key, line = entry.line, at = tern.now() })
		end
	end
	while #log.entries > 40 do
		log.seen[log.entries[1].key] = nil
		table.remove(log.entries, 1)
	end
end

local function summarize(pane)
	local log, now = logs[pane], tern.now()
	local lines = {}
	for _, entry in log.entries do
		if now - entry.at <= TASK_WINDOW_MS then table.insert(lines, entry.line) end
	end
	-- Quiet for a while: summarize the latest steps instead.
	if #lines == 0 then
		for i = math.max(1, #log.entries - 5), #log.entries do table.insert(lines, log.entries[i].line) end
	end
	local task = tasks[pane] or {}
	tasks[pane] = task
	task.at, task.covered = now, log.entries[#log.entries].at
	summarizing = true
	local argv = {
		omp_command(), "-p", "--model", "@smol", "--thinking", "off", "--no-tools", "--no-session",
		"--no-skills", "--no-rules", "--no-extensions", "--no-lsp", "--no-title",
		"--system-prompt", TASK_PROMPT, tracking.digest(lines),
	}
	local ok = pcall(tern.process.run, argv, { timeout_ms = 45000 }, function(result)
		summarizing = false
		local line = if result.status == 0 and not result.timed_out then tracking.sentence(result.stdout) else ""
		if line ~= "" then task.text = line end
	end)
	if not ok then summarizing = false end
end

-- One summary at a time, for the agent whose summary is most out of date.
local function refresh_tasks()
	if summarizing then return end
	local now, best, best_age = tern.now(), nil, nil
	for pane, log in logs do
		local newest = log.entries[#log.entries]
		local task = tasks[pane]
		if newest and (not task or (newest.at > task.covered and now - task.at >= TASK_REFRESH_MS)) then
			local age = if task then now - task.at else math.huge
			if not best_age or age > best_age then best, best_age = pane, age end
		end
	end
	if best then summarize(best) end
end

local function is_factory(pane)
	return pane.block == BLOCK or pane.block == "plugin." .. BLOCK
end

local function hosts_by_pane(cx)
	local hosts = {}
	for _, host in cx.hosts:list() do
		for _, pane in host.panes do hosts[pane] = host.id end
	end
	return hosts
end

local function publish(cx)
	local panes, blocks = {}, {}
	for _, pane in cx.session:panes() do
		panes[pane.pane] = pane
		if is_factory(pane) then table.insert(blocks, pane) end
	end
	-- omp runs only while a Software Factory block is open.
	if #blocks == 0 then return end
	local limits_snapshot = usage_snapshot()
	local hosts = hosts_by_pane(cx)
	local sessions, tabs = {}, {}
	for _, session in cx.sessions:list() do sessions[session.id] = session.name end
	for _, tab in cx.session:tabs() do tabs[tab.id] = sessions[tab.session] or "Session" end
	local agents, seen = {}, {}
	for _, agent in cx.agents:list() do
		local pane = panes[agent.pane]
		if agent.state ~= "exited" and pane then
			seen[agent.pane] = true
			local last_turn = finished[agent.pane]
			table.insert(agents, {
				pane = agent.pane,
				title = text(pane.title, text(agent.command, "Agent " .. string.format("%.0f", agent.pane))),
				task = if tasks[agent.pane] then tasks[agent.pane].text else nil,
				cwd = text(agent.cwd),
				model = text(agent.model),
				delivery_error = text(agent.delivery_error),
				preview = tracking.preview(agent.last_message),
				last_turn = if last_turn then last_turn.result else nil,
				finished_seconds = if last_turn then math.max(0, math.floor((tern.now() - last_turn.at) / 1000)) else nil,
				state = agent.state,
				session = tabs[pane.tab] or "Session",
				subagents = tern.json.array(tracking.subagents(cx, agent.pane)),
			})
			track(cx, agent.pane)
		end
	end
	for id in details do if not seen[id] then details[id] = nil end end
	for id in finished do if not seen[id] then finished[id] = nil end end
	for id in logs do if not seen[id] then logs[id], tasks[id] = nil, nil end end
	refresh_tasks()
	-- Pane order is stable while titles and agent states change.
	table.sort(agents, function(a, b) return a.pane < b.pane end)
	for _, block in blocks do
		local rows = {}
		for _, agent in agents do
			if hosts[block.pane] ~= nil and hosts[agent.pane] == hosts[block.pane] then
				table.insert(rows, agent)
			end
		end
		-- An exited block keeps its pane; it must not starve the others.
		pcall(function()
			cx.session:event(block.pane, {
				ev = "action", act = "factory_snapshot", agents = tern.json.array(rows), usage = limits_snapshot,
			})
		end)
	end
end

tern.on("agent_finished", function(event)
	if event.result == "done" or event.result == "failed" then
		finished[event.pane] = { result = event.result, at = tern.now() }
	else
		finished[event.pane] = nil
	end
	details[event.pane] = nil
end)

tern.route.link(function(request, cx)
	local action, id = string.match(request.url, "^tern%-software%-factory://([a-z]+)/(%d+)$")
	if not id or (action ~= "pane" and action ~= "inspect") then return nil end
	local source = if request.pane then cx.session:pane(request.pane) else nil
	if not source or not is_factory(source) then return { handled = true } end
	local target = tonumber(id)
	local hosts = hosts_by_pane(cx)
	if hosts[request.pane] ~= nil and hosts[target] == hosts[request.pane] then
		for _, agent in cx.agents:list() do
			if agent.pane == target and agent.state ~= "exited" then
				if action == "pane" then
					cx.layout:focus(target)
				else
					local cached, now = details[target], tern.now()
					if not cached or now - cached.at >= 1000 then
						cached = { at = now, value = tracking.read(cx, agent, finished[target]) }
						details[target] = cached
					end
					cx.session:event(request.pane, { ev = "action", act = "factory_details", details = cached.value })
				end
				return { handled = true }
			end
		end

	end
	if action == "pane" then
		cx:toast("info", "This agent is no longer running")
		publish(cx)
	else
		cx.session:event(request.pane, { ev = "action", act = "factory_details", details = { pane = target, unavailable = true } })
	end
	return { handled = true }
end)

local function schedule(delay)
	tern.timer(delay, function(cx)
		-- Always reschedule, including after a transient host disconnect.
		local ok, err = pcall(publish, cx)
		if not ok then tern.log.warn("Cannot refresh agents:", err) end
		schedule(1000)
	end)
end

-- Start at load as well as after reload, without retaining a window context.
schedule(0)
