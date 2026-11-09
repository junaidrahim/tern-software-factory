--!nonstrict
-- One serialized refresh worker per host; per-repository page requests run beside it.
-- Panes share data, never their selection.
local subscribers = {}
local shared = { root = "", repos = {}, warnings = {}, loading = false, loaded = false }
local configured_root, generation, active, pending = nil, 0, nil, false
-- Repository id -> true while its next PR page is loading. Every refresh result and root change
-- replaces this table, so a page answer whose table is no longer current is stale.
local paging = {}
local pump

local function worker(request, done)
	local home = tern.getenv("HOME")
	local local_uv = home and (home .. "/.local/bin/uv")
	local uv = if local_uv and tern.fs.exists(local_uv) then local_uv else "uv"
	tern.process.run({ uv, "run", "--script", tern.plugin.dir .. "/github/worker.py" }, {
		stdin = tern.json.encode(request), timeout_ms = 120000,
	}, done)
end

local function decode(result)
	if result and result.status == 0 and not result.timed_out then
		local ok, decoded = pcall(tern.json.decode, result.stdout)
		if ok and type(decoded) == "table" then return decoded end
		return nil, "GitHub worker returned invalid JSON. Try Refresh."
	end
	return nil, if result and result.timed_out then "GitHub request timed out. Try Refresh."
		else "GitHub worker failed. Check that uv, Python 3.11 or newer, and gh are installed on this host."
end

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
		paging = {}
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
			if not failure then answer, failure = decode(result) end
			if answer and answer.ok == true and type(answer.repos) == "table" then
				local previous = {}
				for _, repo in shared.repos do previous[repo.id] = repo end
				for _, repo in answer.repos do
					if repo.error and previous[repo.id] then
						local old = previous[repo.id]
						repo.prs, repo.total, repo.cursor = old.prs, old.total, old.cursor
						repo.stale = true
					end
				end
				shared.repos, paging = answer.repos, {}
				shared.root = if type(answer.root) == "string" then answer.root else job.root
				shared.warnings = if type(answer.warnings) == "table" then answer.warnings else {}
				shared.loaded, shared.error, shared.setup = true, nil, false
			else
				shared.error = brief(failure or (answer and answer.error) or "GitHub worker returned no repository data.")
				shared.setup = answer and answer.setup == true or false
				if answer and type(answer.warnings) == "table" then shared.warnings = answer.warnings end
			end
		end
		notify()
		pump()
	end
	local ok = pcall(worker, { root = job.root }, function(result) finish(result) end)
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
	-- Append the next page of one repository's open PRs; stale answers are dropped.
	more = function(id)
		local target
		for _, repo in shared.repos do if repo.id == id then target = repo end end
		if not target or type(target.cursor) ~= "string" or paging[id] then return end
		local after, flags = target.cursor, paging
		flags[id] = true
		target.page_error = nil
		local finished = false
		local function finish(result, failure)
			if finished then return end
			finished, flags[id] = true, nil
			-- A refresh or root change replaced this repository row and its cursor.
			if flags ~= paging then return end
			local answer
			if not failure then answer, failure = decode(result) end
			if answer and answer.ok == true and type(answer.prs) == "table" then
				local seen = {}
				for _, pr in target.prs do seen[pr.number] = true end
				for _, pr in answer.prs do
					if not seen[pr.number] then seen[pr.number] = true; table.insert(target.prs, pr) end
				end
				target.cursor = if type(answer.cursor) == "string" then answer.cursor else nil
				if type(answer.total) == "number" then target.total = answer.total end
			else
				target.page_error = brief(failure or (answer and answer.error) or "GitHub worker returned no pull request page.")
			end
			notify()
		end
		local ok = pcall(worker, { repo = id, after = after }, function(result) finish(result) end)
		if not ok then finish(nil, "Cannot start GitHub worker. Install uv and Python 3.11 or newer on this host, then Refresh.") end
		notify()
	end,
	loading_more = function(id) return paging[id] == true end,
}
