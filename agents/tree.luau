--!nonstrict
-- Groups agents under the repository checkout (main or linked worktree) whose
-- directory holds their working directory.

local function trim(path)
	return if #path > 1 then (path:gsub("/+$", "")) else path
end

local function name_of(path)
	return path:match("([^/]+)/*$") or path
end

-- `path` with the home directory `home` shown as `~`.
local function tilde(path, home)
	if type(path) ~= "string" or type(home) ~= "string" or home == "" then return path end
	home = trim(home)
	if home == "/" then return path end
	if path == home then return "~" end
	return if path:sub(1, #home + 1) == home .. "/" then "~" .. path:sub(#home + 1) else path
end

-- A repository's checkouts: the main one first, then its linked worktrees.
local function checkouts(repo)
	local list = { { path = trim(repo.path), name = repo.name, branch = repo.branch, detached = repo.detached, main = true } }
	for _, worktree in repo.worktrees or {} do
		table.insert(list, { path = trim(worktree.path), name = name_of(worktree.path), branch = worktree.branch,
			detached = worktree.detached, missing = worktree.missing, main = false })
	end
	return list
end

-- What the Worktree column says for a checkout.
local function describe(checkout)
	local branch = if checkout.detached then "detached" elseif type(checkout.branch) == "string" then checkout.branch else ""
	local where = if checkout.main then "main checkout" else checkout.name
	return if branch ~= "" then where .. " · " .. branch else where
end

-- Groups in display order: repositories with agents, then agents outside every
-- repository (`other`), then repositories without agents. Each group lists its
-- agents as `{agent, checkout}` in the order given; the deepest checkout that
-- holds an agent's cwd wins, so a worktree inside its repository claims its agents.
-- Checkouts are found by walking up from each cwd, not by scanning every checkout.
local function group(repos, agents)
	local groups, owners = {}, {}
	for _, repo in repos do
		local entry = { repo = repo, checkouts = checkouts(repo), agents = {} }
		table.insert(groups, entry)
		-- A directory listed twice belongs to the first repository listing it.
		for _, checkout in entry.checkouts do
			if not owners[checkout.path] then owners[checkout.path] = { checkout = checkout, entry = entry } end
		end
	end
	local other = { other = true, checkouts = {}, agents = {} }
	for _, agent in agents do
		local dir = trim(if type(agent.cwd) == "string" then agent.cwd else "")
		local owner
		while dir and dir ~= "" do
			owner = owners[dir]
			if owner or dir == "/" then break end
			local parent = dir:match("^(.*)/[^/]*$")
			dir = if parent == "" then "/" else parent
		end
		if owner then
			table.insert(owner.entry.agents, { agent = agent, checkout = owner.checkout })
		else
			table.insert(other.agents, { agent = agent })
		end
	end
	local result, quiet = {}, {}
	for _, entry in groups do table.insert(if #entry.agents > 0 then result else quiet, entry) end
	if #other.agents > 0 then table.insert(result, other) end
	for _, entry in quiet do table.insert(result, entry) end
	return result
end

return { group = group, describe = describe, tilde = tilde }
