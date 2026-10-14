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
		request = "", response = "", response_source = "transcript",
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
	-- Work backwards to find the most recent request and response.
	for i = #messages, 1, -1 do
		local message = messages[i]
		if message.role == "user" and result.request == "" then result.request = text(message.text, 1200) end
		if message.role == "assistant" then
			if result.response == "" then result.response = text(message.text, 6000) end
		end
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

return { read = read, preview = preview }
