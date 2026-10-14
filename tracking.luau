--!nonstrict
-- Bounded, read-only activity from Tern's omp transcript API.
local function text(value, limit)
	if type(value) ~= "string" then return "" end
	if #value <= limit then return value end
	local stop = limit + 1
	while stop > 1 and string.byte(value, stop) >= 128 and string.byte(value, stop) < 192 do stop -= 1 end
	return string.sub(value, 1, stop - 1) .. "…"
end

local function read(cx, agent, finished)
	local result = {
		pane = agent.pane, model = text(agent.model, 200),
		delivery_error = text(agent.delivery_error, 1000),
		response = "", response_source = "transcript",
	}
	if finished then
		result.last_turn = finished.result
		result.finished_seconds = math.max(0, math.floor((tern.now() - finished.at) / 1000))
	end
	local ok, messages = pcall(function() return cx.agents:transcript(agent.pane, { last = 32 }) end)
	if not ok or type(messages) ~= "table" then
		result.transcript_error = true
		messages = {}
	end
	result.has_transcript = #messages > 0
	-- Work backwards to the most recent assistant text.
	for i = #messages, 1, -1 do
		local message = messages[i]
		if message.role == "assistant" and result.response == "" then result.response = text(message.text, 6000) end
	end
	-- Native non-omp agents may only provide a pane update. Do not label that
	-- fallback as a structured assistant response, or include it over omp data.
	if not result.has_transcript then
		result.response = text(agent.last_message, 6000)
		result.response_source = "pane"
	end
	return result
end

local function preview(value)
	-- Keep row snapshots small, even when the pane's latest output is very long.
	local line = text(value, 1200)
	line = line:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
	line = line:gsub("%*%*(.-)%*%*", "%1"):gsub("`", ""):gsub("^#+%s*", ""):gsub("%s+", " ")
	line = line:match("^%s*(.-)%s*$") or ""
	return text(line, 240)
end

local function number(value)
	return if type(value) == "number" and value == value then value else nil
end

local function fields(value)
	return if type(value) == "table" then value else {}
end

local function subagent(node, card_ms)
	local props, stats, tool = node.p, fields(node.p.stats), fields(node.p.tool)
	return {
		id = node.id,
		-- A stable item key; TSP ids contain dots.
		key = (string.gsub(node.id, "[^%w]", "_")),
		name = if text(props.name, 120) ~= "" then text(props.name, 120) else node.id,
		agent = text(props.agent, 80), model = text(props.model, 120),
		status = text(props.status, 40), thinking = text(props.thinking, 40),
		task = text(props.task, 1200),
		tool = text(tool.name, 80), intent = text(tool.intent, 240), tool_ms = number(tool.age),
		-- A running agent reports no duration of its own; its task card has run as long.
		elapsed_ms = number(stats.took) or card_ms,
		tokens = number(stats.tokens), cost = number(stats.cost), requests = number(stats.requests),
		tools = number(stats.tools), context = text(stats.contextLabel, 40),
	}
end

-- omp renders each task call as an `omp.tool.task` card with one `agent` node
-- per subagent. Read only running cards, one level deep, with node budgets.
local function subagents(cx, pane)
	local result = {}
	local ok, tree = pcall(function() return cx.session:surface(pane, { depth = 1, nodes = 5000, max_chars = 64 }) end)
	if not ok or type(tree) ~= "table" or type(tree.surface) ~= "table" or tree.surface.role ~= "omp.session" then
		return result
	end
	for _, node in fields(fields(tree.main).c) do
		local props = fields(node.p)
		if props.role == "omp.tool.task" and props.status == "running" and type(node.id) == "string" then
			local read, card = pcall(function()
				return cx.session:surface(pane, { root = node.id, depth = 1, nodes = 256, max_chars = 1200 })
			end)
			for _, child in if read and type(card) == "table" then fields(fields(card.main).c) else {} do
				if child.k == "agent" and type(child.id) == "string" and type(child.p) == "table" then
					table.insert(result, subagent(child, number(props.age)))
				end
			end
		end
	end
	-- omp reorders agents within a card as they update; keep rows still.
	table.sort(result, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.id < b.id
	end)
	return result
end

local function squash(value, limit)
	return text((string.gsub(text(value, limit * 4), "%s+", " "):match("^%s*(.-)%s*$")) or "", limit)
end

-- One line per chat step, keyed so the window can tell when each first appeared.
-- Tool titles that only repeat the tool name add nothing; commands do.
local function activity(messages)
	local entries = {}
	for _, message in messages do
		local body = squash(message.text, 240)
		if message.role == "user" and body ~= "" then
			table.insert(entries, { key = "u:" .. #message.text .. ":" .. body, line = "User asked: " .. body })
		elseif message.role == "assistant" and body ~= "" then
			table.insert(entries, { key = "a:" .. #message.text .. ":" .. body, line = "Agent said: " .. body })
		end
		for i, tool in if type(message.tools) == "table" then message.tools else {} do
			local name = text(tool.name, 40)
			local title = squash(tool.title, 120)
			local detail = squash(if type(tool.command) == "string" then tool.command else tool.target, 160)
			local line = name
			if title ~= "" and string.lower(title) ~= string.lower(name) then line ..= ": " .. title end
			if detail ~= "" then line ..= " — " .. detail end
			if tool.status == "error" then line ..= " (failed)" end
			local key = if type(tool.key) == "string" then tool.key else "t:" .. name .. ":" .. i .. ":" .. line
			table.insert(entries, { key = key, line = line })
		end
	end
	return entries
end

-- The model sees at most the newest 3,500 characters, oldest line first.
local function digest(lines)
	local kept, size = {}, 0
	for i = #lines, 1, -1 do
		size += #lines[i] + 1
		if size > 3500 then break end
		table.insert(kept, 1, lines[i])
	end
	return "Recent activity of a coding agent, oldest first:\n" .. table.concat(kept, "\n")
end

-- First line of the model's reply, without quotes or markdown emphasis.
local function sentence(output)
	local line = string.match(text(output, 4000), "[^\n]*%S[^\n]*") or ""
	line = line:gsub("[*_`]", ""):gsub("^%s*[\"'“]", ""):gsub("[\"'”]%s*$", "")
	return squash(line, 200)
end

return {
	read = read, preview = preview, subagents = subagents,
	activity = activity, digest = digest, sentence = sentence,
}
