--!nonstrict
-- Agent discovery and layout navigation are window APIs. Send snapshots to
-- each block on the corresponding host. Inspect only the selected agent.
local BLOCK = "tern-software-factory.agents"
local REFRESH_MS, LIMITS_REFRESH_MS = 1000, 60000
-- Tern disables a window timer until reload once one call runs past 50 ms,
-- which would stop every block. A timer call stops taking steps after
-- SLICE_MS; a single step that takes SLOW_MS is logged.
local SLICE_MS, SLOW_MS = 20, 25
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
-- Per pane: chat steps with the time each first appeared, the latest summary,
-- and the directory of the newest file the agent changed.
local logs, tasks, paths = {}, {}, {}
-- Per pane: subagents of the agent's running task cards, and the state and last
-- message its latest transcript read covered.
local subagents, signatures = {}, {}
local summarizing = false
-- The current refresh: short named steps, run in order across timer calls (see `refresh`).
local queue = {}

local function step(name, run)
	return { name = name, run = run }
end

local function text(value, fallback)
	return if type(value) == "string" and value ~= "" then value else (fallback or "")
end

-- What an agent that is not working can change: its state and last message.
local function signature(agent)
	return text(agent.state) .. "\0" .. text(agent.last_message)
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

-- First sight (or after a reload): look further back once, so the path
-- does not fall back to the cwd just because the last edit is older.
local function seed(cx, pane, cwd, home)
	local ok, history = pcall(function() return cx.agents:transcript(pane, { last = 200 }) end)
	if ok and type(history) == "table" then paths[pane] = tracking.changed(history, cwd, home) end
end

-- Record chat steps the first time they appear, and the directory of the newest
-- changed file; the window keeps no transcript. `covered` is the agent's signature at the read.
local function track(cx, pane, cwd, home, covered)
	local ok, messages = pcall(function() return cx.agents:transcript(pane, { last = 12 }) end)
	if not ok or type(messages) ~= "table" then return end
	signatures[pane] = covered
	paths[pane] = tracking.changed(messages, cwd, home) or paths[pane]
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

-- Tern's window API keeps only the low 44 bits of a pane id, and
-- `cx.session:event` and `cx.session:pane` fail for a shortened id, so
-- snapshots and details travel through `tern.kv`, keyed by those low 44 bits:
-- the block's host half (which sees the full id) computes the same key with
-- host.luau's `key`. Entries carry `seq` so a block applies each one once.
-- Keys of the blocks this window has written entries for.
local seq, written = 0, {}

local function key(pane)
	return string.format("%.0f", pane % 2^44)
end

local function write(kind, block_key, value)
	seq += 1
	value.seq = seq
	tern.kv.set(kind .. ":" .. block_key, value)
	written[block_key] = true
end

-- The open Software Factory block with this key.
local function find_block(cx, block_key)
	for _, pane in cx.session:panes() do
		if is_factory(pane) and key(pane.pane) == block_key then return pane end
	end
	return nil
end

-- Sends one block the agents on its host.
local function deliver(block, agents, hosts, usage_now)
	local rows = {}
	for _, agent in agents do
		if hosts[block.pane] ~= nil and hosts[agent.pane] == hosts[block.pane] then
			table.insert(rows, agent)
		end
	end
	write("snapshot", key(block.pane), { agents = tern.json.array(rows), usage = usage_now })
end

-- Discovery: find the blocks and live agents, then queue each agent's reads,
-- the snapshot, and each block's delivery as separate steps.
local function publish(cx)
	local panes, blocks = {}, {}
	for _, pane in cx.session:panes() do
		panes[pane.pane] = pane
		if is_factory(pane) then table.insert(blocks, pane) end
	end
	-- Entries of closed blocks leave the store, including blocks whose program exited.
	local open = {}
	for _, block in blocks do open[key(block.pane)] = true end
	for block_key in written do
		if not open[block_key] then
			written[block_key] = nil
			tern.kv.set("snapshot:" .. block_key, nil)
			tern.kv.set("details:" .. block_key, nil)
		end
	end
	-- omp runs only while a Software Factory block is open.
	if #blocks == 0 then return end
	local limits_snapshot = usage_snapshot()
	local hosts = hosts_by_pane(cx)
	local sessions, tabs = {}, {}
	for _, session in cx.sessions:list() do sessions[session.id] = session.name end
	for _, tab in cx.session:tabs() do tabs[tab.id] = sessions[tab.session] or "Session" end
	local live, seen = {}, {}
	local home = tern.getenv("HOME")
	for _, agent in cx.agents:list() do
		local pane = panes[agent.pane]
		if agent.state ~= "exited" and pane then
			seen[agent.pane] = true
			table.insert(live, { agent = agent, pane = pane })
		end
	end
	for id in details do if not seen[id] then details[id] = nil end end
	for id in finished do if not seen[id] then finished[id] = nil end end
	for id in logs do if not seen[id] then logs[id], tasks[id] = nil, nil end end
	for id in paths do if not seen[id] then paths[id] = nil end end
	for id in subagents do if not seen[id] then subagents[id] = nil end end
	for id in signatures do if not seen[id] then signatures[id] = nil end end
	for _, entry in live do
		local agent = entry.agent
		local id, cwd, label = agent.pane, text(agent.cwd), string.format("%.0f", agent.pane)
		-- An agent that is not working changes nothing until its state or last message does.
		local current = signature(agent)
		if agent.state == "working" or signatures[id] ~= current then
			if not logs[id] and not paths[id] then
				table.insert(queue, step("seed " .. label, function(step_cx) seed(step_cx, id, cwd, home) end))
			end
			table.insert(queue, step("transcript " .. label, function(step_cx) track(step_cx, id, cwd, home, current) end))
		end
		-- Subagents run only during a turn. Each running task card is its own step,
		-- taken next; the last one replaces the agent's subagents.
		if agent.state == "working" then
			table.insert(queue, step("subagents " .. label, function(step_cx)
				local cards = tracking.task_cards(step_cx, id)
				if not cards or #cards == 0 then
					subagents[id] = nil
					return
				end
				local found, steps = {}, {}
				for _, card in cards do
					table.insert(steps, step("task card " .. label .. "/" .. card.id, function(card_cx)
						for _, sub in tracking.card_agents(card_cx, id, card) do table.insert(found, sub) end
					end))
				end
				table.insert(steps, step("subagents " .. label .. " sorted", function()
					subagents[id] = tracking.sort_subagents(found)
				end))
				for i, next_step in steps do table.insert(queue, i, next_step) end
			end))
		else
			subagents[id] = nil
		end
	end
	table.insert(queue, step("snapshot", function()
		refresh_tasks()
		local agents = {}
		for _, entry in live do
			local agent, pane = entry.agent, entry.pane
			local last_turn = finished[agent.pane]
			local cwd = text(agent.cwd)
			-- Where the agent works: its newest change, else its cwd.
			local work_dir = paths[agent.pane] or tracking.absolute(cwd, nil, home)
			table.insert(agents, {
				pane = agent.pane,
				title = text(pane.title, text(agent.command, "Agent " .. string.format("%.0f", agent.pane))),
				task = if tasks[agent.pane] then tasks[agent.pane].text else nil,
				cwd = cwd,
				work_dir = work_dir or "",
				path = if work_dir then tracking.where(work_dir, cwd, home) else "",
				model = text(agent.model),
				delivery_error = text(agent.delivery_error),
				preview = tracking.preview(agent.last_message),
				last_turn = if last_turn then last_turn.result else nil,
				finished_seconds = if last_turn then math.max(0, math.floor((tern.now() - last_turn.at) / 1000)) else nil,
				state = agent.state,
				session = tabs[pane.tab] or "Session",
				subagents = tern.json.array(subagents[agent.pane] or {}),
			})
		end
		-- Pane order is stable while titles and agent states change.
		table.sort(agents, function(a, b) return a.pane < b.pane end)
		for _, block in blocks do
			table.insert(queue, step("deliver " .. string.format("%.0f", block.pane), function()
				deliver(block, agents, hosts, limits_snapshot)
			end))
		end
	end))
end

tern.on("agent_finished", function(event)
	if event.result == "done" or event.result == "failed" then
		finished[event.pane] = { result = event.result, at = tern.now() }
	else
		finished[event.pane] = nil
	end
	details[event.pane] = nil
end)

local function repository_path(encoded)
	-- Decode once: a literal percent in a directory name must survive the route.
	if encoded:gsub("%%%x%x", ""):find("%", 1, true) then return nil end
	local path = encoded:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
	if path:find("\0", 1, true) then return nil end
	if path:sub(1, 1) ~= "/" and not path:match("^%a:[/\\]") then return nil end
	return path
end

local function open_repository(request, cx)
	local action, block_key, encoded = request.url:match("^tern%-software%-factory://(repo%-[a-z]+)/(%d+)/(.*)$")
	if action ~= "repo-block" and action ~= "repo-session" then return nil end
	local block, path = find_block(cx, block_key), repository_path(encoded)
	if not block then return { handled = true } end
	if not path then
		cx:toast("error", "Cannot open repository", "Invalid directory path.")
		return { handled = true }
	end
	local ok, problem = pcall(function()
		if action == "repo-block" then
			local pane = cx.layout:split(block.pane, "right", { cwd = path })
			if not pane then error("The Software Factory block is no longer available.") end
			cx.layout:focus(pane)
		else
			-- Session creation uses the current host, which need not be this block's.
			local host = hosts_by_pane(cx)[block.pane]
			if host == nil then error("The repository's host is no longer connected.") end
			if cx.hosts:current().id ~= host then cx.hosts:switch(host) end
			cx.sessions:create({ cwd = path })
		end
	end)
	if not ok then cx:toast("error", "Cannot open repository", tostring(problem)) end
	return { handled = true }
end

-- Links name the block they come from: Tern reports the focused pane, not the
-- block, as a link's pane when the block opens it.
tern.route.link(function(request, cx)
	local repository = open_repository(request, cx)
	if repository then return repository end
	local action, block_key, id = string.match(request.url, "^tern%-software%-factory://([a-z]+)/(%d+)/(%d+)$")
	if not id or (action ~= "pane" and action ~= "inspect") then return nil end
	local block = find_block(cx, block_key)
	if not block then return { handled = true } end
	local target = tonumber(id)
	local hosts = hosts_by_pane(cx)
	if hosts[block.pane] ~= nil and hosts[target] == hosts[block.pane] then
		for _, agent in cx.agents:list() do
			if agent.pane == target and agent.state ~= "exited" then
				if action == "pane" then
					cx.layout:focus(target)
				else
					-- The panel of an agent that is not working changes with its state or last message.
					local cached, now, current = details[target], tern.now(), signature(agent)
					if not cached or cached.signature ~= current or (agent.state == "working" and now - cached.at >= 1000) then
						cached = { at = now, signature = current, value = tracking.read(cx, agent, finished[target]) }
						details[target] = cached
					end
					local last_turn = finished[target]
					if last_turn then cached.value.finished_seconds = math.max(0, math.floor((now - last_turn.at) / 1000)) end
					write("details", block_key, { details = cached.value })
				end
				return { handled = true }
			end
		end

	end
	if action == "pane" then
		-- The next refresh drops its row.
		cx:toast("info", "This agent is no longer running")
	else
		write("details", block_key, { details = { pane = target, unavailable = true } })
	end
	return { handled = true }
end)

-- Each timer call takes steps until SLICE_MS has passed and continues in the
-- next call; a new refresh starts REFRESH_MS after the last step. A step that
-- alone nears Tern's budget is logged by name.
local function refresh(cx)
	if #queue == 0 then queue = { step("discovery", publish) } end
	local start = tern.now()
	repeat
		local next_step = table.remove(queue, 1)
		local began = tern.now()
		local ok, err = pcall(next_step.run, cx)
		local took = tern.now() - began
		if not ok then tern.log.warn("Cannot refresh agents:", next_step.name, err) end
		if took >= SLOW_MS then tern.log.warn(string.format("Slow refresh step: %s took %.0f ms", next_step.name, took)) end
	until #queue == 0 or tern.now() - start >= SLICE_MS
	-- Always reschedule, including after a transient host disconnect.
	tern.timer(if #queue > 0 then 0 else REFRESH_MS, refresh)
end

-- Start at load as well as after reload, without retaining a window context.
tern.timer(0, refresh)
