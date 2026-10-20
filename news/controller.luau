--!nonstrict
-- One worker queue/cache per host VM; blocks share data, not their selection.
local sources = require("./sources")
local refresh_ms = 3600000
for _, source in sources do
	if source.enabled ~= false then
		refresh_ms = math.min(refresh_ms, math.max(60000, (source.interval_seconds or 3600) * 1000))
	end
end
local subscribers, queue = {}, {}
local shared = {
	snapshot = { stories = {}, feeds = {}, now = 0 }, version = 0,
	loading = false, refreshing = false,
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

local function brief(value)
	return string.sub(tostring(value):gsub("[%z\1-\8\11\12\14-\31]", ""), 1, 800)
end

local function enqueue(job)
	if active and active.action == job.action then
		-- A manual refresh during an automatic one still gets a forced pass.
		if not (job.force and not active.force) then return end
	end
	for _, pending in queue do
		if pending.action == job.action then
			pending.force = pending.force or job.force
			return
		end
	end
	table.insert(queue, job)
	pump()
end

pump = function()
	if active or #queue == 0 or next(subscribers) == nil then return end
	local job = table.remove(queue, 1)
	active = job
	shared.loading = job.action == "snapshot"
	shared.refreshing = job.action == "refresh"
	local request = {
		action = job.action, force = job.force,
		db = tern.plugin.data .. "/news.sqlite3", sources = sources,
	}
	local function finish(result, failure)
		active = nil
		shared.loading, shared.refreshing = false, false
		local answer
		if not failure and result and result.status == 0 and not result.timed_out then
			local ok, decoded = pcall(tern.json.decode, result.stdout)
			if ok and type(decoded) == "table" then answer = decoded
			else failure = "News worker returned invalid JSON." end
		else
			failure = failure or (if result and result.timed_out then "News request timed out."
				else "News worker failed: " .. brief(result and result.stderr or "unknown error"))
		end
		if answer and answer.ok and type(answer.snapshot) == "table" then
			shared.snapshot = answer.snapshot
			shared.received_at = tern.now()
			shared.version += 1
			shared.error = nil
		else
			shared.error = brief(failure or (answer and answer.error) or "News worker returned no snapshot.")
		end
		if job.action == "refresh" then next_refresh = tern.now() + refresh_ms end
		notify()
		pump()
	end
	local ok, problem = pcall(function()
		tern.process.run({ uv_command(), "run", "--script", tern.plugin.dir .. "/news/worker.py" }, {
			stdin = tern.json.encode(request), timeout_ms = 120000,
		}, function(result) finish(result) end)
	end)
	if not ok then finish(nil, "Cannot start News worker. Install uv on this host: " .. brief(problem)) end
	notify()
end

local function attach(cx)
	subscribers[cx.pane] = cx
	if not started then
		started = true
		next_refresh = tern.now() + refresh_ms
		enqueue({ action = "snapshot" })
		enqueue({ action = "refresh" })
	else
		pump()
	end
end

local function detach(pane)
	subscribers[pane] = nil
	if next(subscribers) == nil then queue = {} end
end

local function tick()
	if not started or next(subscribers) == nil then return end
	if tern.now() >= next_refresh then
		next_refresh = tern.now() + refresh_ms
		enqueue({ action = "refresh" })
	end
end

return {
	attach = attach, detach = detach, tick = tick, get = function() return shared end,
	refresh = function() enqueue({ action = "refresh", force = true }) end,
}
