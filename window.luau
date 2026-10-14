--!nonstrict
-- Agent discovery and layout navigation are window APIs. Send snapshots to
-- each block on the corresponding host. Inspect only the selected agent.
local BLOCK = "tern-software-factory.agents"
local tracking = require("./tracking")
local finished, details = {}, {}

local function text(value, fallback)
	return if type(value) == "string" and value ~= "" then value else (fallback or "")
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
	if #blocks == 0 then return end
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
				cwd = text(agent.cwd),
				model = text(agent.model),
				delivery_error = text(agent.delivery_error),
				preview = tracking.preview(agent.last_message),
				last_turn = if last_turn then last_turn.result else nil,
				finished_seconds = if last_turn then math.max(0, math.floor((tern.now() - last_turn.at) / 1000)) else nil,
				state = agent.state,
				session = tabs[pane.tab] or "Session",
			})
		end
	end
	for id in details do if not seen[id] then details[id] = nil end end
	for id in finished do if not seen[id] then finished[id] = nil end end
	-- Pane order is stable while titles and agent states change.
	table.sort(agents, function(a, b) return a.pane < b.pane end)
	for _, block in blocks do
		local rows = {}
		for _, agent in agents do
			if hosts[block.pane] ~= nil and hosts[agent.pane] == hosts[block.pane] then
				table.insert(rows, agent)
			end
		end
		cx.session:event(block.pane, { ev = "action", act = "factory_snapshot", agents = tern.json.array(rows) })
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
