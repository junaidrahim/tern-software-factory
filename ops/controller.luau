--!nonstrict
-- One read-only worker per host; the host's existing poll drives the minute timer.
local REFRESH_MS = 60000
local subscribers = {}
local shared = { loading = false }
local active, pending, next_refresh = false, false, 0
local start

local function notify()
	for _, cx in subscribers do pcall(function() cx:render() end) end
end

local function brief(value)
	return string.sub(tostring(value):gsub("[%z\1-\8\11\12\14-\31]", ""), 1, 800)
end

local function uv_command()
	local home = tern.getenv("HOME")
	local local_uv = home and (home .. "/.local/bin/uv")
	return if local_uv and tern.fs.exists(local_uv) then local_uv else "uv"
end

local function object(value)
	return type(value) == "table" and value ~= tern.json.null
end

start = function()
	if active or next(subscribers) == nil then return end
	active, shared.loading = true, true
	local function finish(result, failure)
		active, shared.loading = false, false
		local answer
		if not failure and result and result.status == 0 and not result.timed_out then
			local ok, decoded = pcall(tern.json.decode, result.stdout)
			if ok and object(decoded) then answer = decoded
			else failure = "Agent ops worker returned invalid JSON." end
		else
			failure = failure or (if result and result.timed_out then "Agent ops request timed out."
				else "Agent ops worker failed: " .. brief(result and result.stderr or "unknown error"))
		end
		if answer and answer.ok == true and object(answer.snapshot)
			and object(answer.snapshot.models) and object(answer.snapshot.commands)
			and object(answer.snapshot.summary) and object(answer.snapshot.warnings) then
			shared.snapshot = answer.snapshot
			shared.received_at = tern.now()
			shared.error, shared.setup = nil, false
		else
			shared.error = brief(failure or (answer and answer.error) or "Agent ops worker returned no snapshot.")
			shared.setup = answer ~= nil and answer.setup == true
		end
		next_refresh = tern.now() + REFRESH_MS
		notify()
		if pending then
			pending = false
			start()
		end
	end
	local ok, problem = pcall(function()
		tern.process.run({ uv_command(), "run", "--script", tern.plugin.dir .. "/ops/worker.py" }, {
			stdin = tern.json.encode({ action = "snapshot" }), timeout_ms = 20000,
		}, function(result) finish(result) end)
	end)
	if not ok then finish(nil, "Cannot start Agent ops worker. Install uv on this host: " .. brief(problem)) end
	notify()
end

local function attach(cx)
	subscribers[cx.pane] = cx
	if not shared.snapshot or tern.now() >= next_refresh then start() end
end

local function detach(pane)
	subscribers[pane] = nil
	if next(subscribers) == nil then pending = false end
end

local function refresh()
	if next(subscribers) == nil then return end
	if active then pending = true else start() end
end

local function tick()
	if next(subscribers) ~= nil and tern.now() >= next_refresh then start() end
end

return { attach = attach, detach = detach, tick = tick, refresh = refresh, get = function() return shared end }
