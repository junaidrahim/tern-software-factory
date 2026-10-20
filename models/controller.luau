--!nonstrict
-- Shared host-VM worker queue; pane-specific filters stay in page state.
local refresh_ms = 6 * 3600000
local subscribers, queue = {}, {}
local shared = {
	snapshot = { models = {}, fetched_at = nil, index_version = nil },
	loading = false, refreshing = false, error = nil, setup = false,
	key_path = tern.plugin.data .. "/artificial-analysis-api-key", version = 0,
}
local started, active, next_refresh = false, nil, 0
local pump

local function notify()
	for _, cx in subscribers do pcall(function() cx:render() end) end
end

local function uv_command()
	local home = tern.getenv("HOME")
	local local_uv = home and (home .. "/.local/bin/uv")
	return if local_uv and tern.fs.exists(local_uv) then local_uv else "uv"
end

local function enqueue(job, deferred)
	-- Saves are ordered barriers: never coalesce one, or satisfy its refresh
	-- with a request that ran before the new credential was persisted.
	if job.action ~= "save_key" then
		local barrier = false
		for index = #queue, 1, -1 do
			local pending = queue[index]
			if pending.action == "save_key" then barrier = true; break end
			if pending.action == job.action then
				pending.force = pending.force or job.force
				pending.after_save = pending.after_save or job.after_save
				return
			end
		end
		if not barrier and active and active.action == job.action then
			if not (job.force and not active.force) then return end
		end
	end
	table.insert(queue, job)
	if not deferred then pump() end
end

pump = function()
	if active or #queue == 0 then return end
	if next(subscribers) == nil and queue[1].action ~= "save_key" and not queue[1].after_save then return end
	local job = table.remove(queue, 1)
	active = job
	shared.loading = true
	shared.refreshing = job.action == "refresh"
	local request = {
		action = job.action, force = job.force, api_key = job.api_key,
		cache = tern.plugin.data .. "/models/cache.json", key_path = shared.key_path,
	}
	job.api_key = nil
	local finished = false
	local function finish(result, failure)
		if finished then return end
		finished = true
		active = nil
		shared.loading, shared.refreshing = false, false
		local answer
		if not failure and result and result.status == 0 and not result.timed_out then
			local ok, decoded = pcall(tern.json.decode, result.stdout)
			if ok and type(decoded) == "table" then answer = decoded
			else failure = "Models worker returned invalid JSON." end
		else
			-- Never expose process stderr or thrown exceptions: they can contain credentials.
			failure = failure or (if result and result.timed_out then "Models request timed out. Cached models remain available."
				else "Models worker failed. Check that uv and Python 3.11 or newer are available on this host.")
		end
		if answer and type(answer.snapshot) == "table" and type(answer.snapshot.models) == "table" then
			shared.snapshot = answer.snapshot
			shared.version += 1
			shared.setup = answer.setup == true
			shared.error = if type(answer.error) == "string" then answer.error else nil
			shared.received_at = tern.now()
		else
			shared.error = failure or "Models worker returned no snapshot."
		end
		local delay = if answer and type(answer.refresh_after_seconds) == "number"
			then math.max(60, answer.refresh_after_seconds) * 1000 else refresh_ms
		next_refresh = tern.now() + delay
		if job.action == "save_key" then
			local saved = answer ~= nil and answer.key_saved == true
			if saved then
				enqueue({ action = "refresh", force = true, after_save = true }, true)
			end
			local callback = job.callback
			job.callback = nil
			if callback then
				pcall(callback, saved, if saved then nil else shared.error or "Artificial Analysis API key was not saved.")
			end
		end
		notify()
		pump()
	end
	local ok = pcall(function()
		local input = tern.json.encode(request)
		request.api_key = nil
		tern.process.run({ uv_command(), "run", "--script", tern.plugin.dir .. "/models/worker.py" }, {
			stdin = input, timeout_ms = 120000,
		}, function(result) finish(result) end)
	end)
	request.api_key = nil
	if not ok then finish(nil, "Cannot start Models worker. Install uv and Python 3.11 or newer on this host.") end
	notify()
end

local function attach(cx)
	local was_empty = next(subscribers) == nil
	subscribers[cx.pane] = cx
	if not started then
		started = true
		next_refresh = tern.now() + refresh_ms
		enqueue({ action = "snapshot" })
		enqueue({ action = "refresh" })
	else
		pump()
		if was_empty or tern.now() >= next_refresh then
			next_refresh = tern.now() + refresh_ms
			enqueue({ action = "refresh" })
		end
	end
end

local function detach(pane)
	subscribers[pane] = nil
	if next(subscribers) == nil then
		for index = #queue, 1, -1 do
			if queue[index].action ~= "save_key" and not queue[index].after_save then table.remove(queue, index) end
		end
		pump()
	end
end

local function tick()
	if not started or next(subscribers) == nil or tern.now() < next_refresh then return end
	next_refresh = tern.now() + refresh_ms
	enqueue({ action = "refresh" })
end

return {
	attach = attach, detach = detach, tick = tick, get = function() return shared end,
	refresh = function() enqueue({ action = "refresh", force = true }) end,
	save_key = function(value, callback) enqueue({ action = "save_key", api_key = value, callback = callback }) end,
}
