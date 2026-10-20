--!nonstrict
-- One serialized worker per host; panes share data, never their selection.
local subscribers = {}
local shared = { root = "", repos = {}, warnings = {}, loading = false, loaded = false, version = 0 }
local configured_root, generation, active, pending = nil, 0, nil, false
local pump

local function notify()
	for _, cx in subscribers do pcall(function() cx:render() end) end
end

local function brief(value)
	return string.sub(tostring(value):gsub("[%z\1-\8\11\12\14-\31]", ""), 1, 800)
end

local function read_root()
	local ok, root = pcall(tern.kv.get, "repositories:root")
	local problem
	if not ok or (root ~= nil and type(root) ~= "string") then
		root, problem = "", "Cannot read the saved repository root. Set Root folder on Agents, then Refresh."
	end
	root = root or ""
	local changed = configured_root ~= root
	if changed then
		configured_root = root
		generation += 1
		shared.root, shared.repos, shared.warnings = root, {}, {}
		shared.loaded, shared.loading, shared.setup, shared.error = false, false, false, nil
		shared.version += 1
		pending = root ~= ""
	end
	if problem then shared.error = problem end
	return changed, problem
end

pump = function()
	if active or not pending or next(subscribers) == nil then return end
	pending = false
	local job = { root = configured_root, generation = generation }
	active, shared.loading = job, true
	local finished = false
	local function finish(result, failure)
		if finished then return end
		finished, active = true, nil
		if job.generation == generation then
			shared.loading = false
			local answer
			if not failure and result and result.status == 0 and not result.timed_out then
				local ok, decoded = pcall(tern.json.decode, result.stdout)
				if ok and type(decoded) == "table" then answer = decoded
				else failure = "GitHub worker returned invalid JSON. Try Refresh." end
			else
				failure = failure or (if result and result.timed_out then "GitHub request timed out. Try Refresh."
					else "GitHub worker failed. Check that uv, Python 3.11 or newer, and gh are installed on this host.")
			end
			if answer and answer.ok == true and type(answer.repos) == "table" then
				local previous = {}
				for _, repo in shared.repos do previous[repo.id] = repo end
				for _, repo in answer.repos do
					if repo.error and previous[repo.id] then
						repo.prs = previous[repo.id].prs
						repo.stale = true
					end
				end
				shared.repos = answer.repos
				shared.root = if type(answer.root) == "string" then answer.root else job.root
				shared.warnings = if type(answer.warnings) == "table" then answer.warnings else {}
				shared.loaded, shared.error, shared.setup = true, nil, false
				shared.version += 1
			else
				shared.error = brief(failure or (answer and answer.error) or "GitHub worker returned no repository data.")
				shared.setup = answer and answer.setup == true or false
				if answer and type(answer.warnings) == "table" then shared.warnings = answer.warnings end
			end
		end
		notify()
		pump()
	end
	local ok = pcall(function()
		local home = tern.getenv("HOME")
		local local_uv = home and (home .. "/.local/bin/uv")
		local uv = if local_uv and tern.fs.exists(local_uv) then local_uv else "uv"
		tern.process.run({ uv, "run", "--script", tern.plugin.dir .. "/github/worker.py" }, {
			stdin = tern.json.encode({ root = job.root }), timeout_ms = 120000,
		}, function(result) finish(result) end)
	end)
	if not ok then finish(nil, "Cannot start GitHub worker. Install uv and Python 3.11 or newer on this host, then Refresh.") end
	notify()
end

return {
	get = function() return shared end,
	attach = function(cx)
		subscribers[cx.pane] = cx
		local changed = read_root()
		if changed then notify() end
		pump()
	end,
	detach = function(pane) subscribers[pane] = nil end,
	refresh = function()
		local _, problem = read_root()
		if not problem and configured_root ~= "" and not (active and active.generation == generation) then pending = true end
		pump()
		notify()
	end,
}
