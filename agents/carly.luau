--!nonstrict
-- Window half of the Agents page's Carly requests: a `carly/<block>` link
-- asks for the request in Tern's prompt and hands it to Carly with the
-- repository's worktrees, agents and sessions; `start_agent` is the export
-- Carly starts the agent with.
local PLUGIN = "tern-software-factory"

local function inside(path, dir)
	return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

-- Sessions with a pane in one of `dirs`, in pane order, with pane and agent counts.
local function sessions_in(cx, dirs)
	local names, tab_session, agents = {}, {}, {}
	for _, session in cx.sessions:list() do names[session.id] = session.name end
	for _, tab in cx.session:tabs() do tab_session[tab.id] = tab.session end
	for _, agent in cx.agents:list() do
		if agent.state ~= "exited" then agents[agent.pane] = true end
	end
	local found, order = {}, {}
	for _, pane in cx.session:panes() do
		local session = if pane.tab then tab_session[pane.tab] else nil
		local cwd = if type(pane.cwd) == "string" then pane.cwd else ""
		local held = false
		for _, dir in dirs do
			if cwd ~= "" and inside(cwd, dir) then held = true; break end
		end
		if held and session ~= nil then
			local entry = found[session]
			if not entry then
				entry = { name = names[session] or "Session", panes = 0, agents = 0 }
				found[session] = entry
				table.insert(order, entry)
			end
			entry.panes += 1
			if agents[pane.pane] then entry.agents += 1 end
		end
	end
	return order
end

local function count(n, word)
	return tostring(n) .. " " .. word .. (if n == 1 then "" else "s")
end

-- What Carly receives: the user's request, then the repository context and how
-- to start the agent.
local function message(text, request, sessions)
	local lines = { text, "", "Context from Software Factory's Agents page:" }
	table.insert(lines, "Repository: " .. request.repo.name .. " at " .. request.repo.path)
	table.insert(lines, "Checkouts (use one as the agent's cwd):")
	for _, worktree in request.worktrees or {} do
		table.insert(lines, "- " .. worktree.path .. " (" .. worktree.label .. ")" .. (if worktree.missing then " [directory missing]" else ""))
	end
	if request.agents and #request.agents > 0 then
		table.insert(lines, "Agents already working in it:")
		for _, agent in request.agents do
			table.insert(lines, "- " .. agent.task .. " [" .. agent.state .. "] in " .. agent.worktree
				.. (if agent.session ~= "" then ", session \"" .. agent.session .. "\"" else ""))
		end
	end
	if #sessions > 0 then
		table.insert(lines, "Tern sessions with panes in this repository:")
		for _, session in sessions do
			table.insert(lines, "- \"" .. session.name .. "\": " .. count(session.panes, "pane") .. ", " .. count(session.agents, "agent"))
		end
	else
		table.insert(lines, "No Tern session has a pane in this repository yet.")
	end
	table.insert(lines, "To start an agent, call await(plugins[\"" .. PLUGIN .. "\"].start_agent(cwd, prompt, session)) with one of the "
		.. "checkouts above as cwd and the session's name (nil keeps the current session). Pick the checkout and session "
		.. "that fit the request, and ask me first if that is unclear. Write the agent's prompt as a complete task.")
	return table.concat(lines, "\n")
end

-- Handles `tern-software-factory://carly/<block id>`; nil for other links.
-- `find_block` and `key` are window.luau's block lookup by key.
local function route(request, cx, find_block, key)
	local block_id = string.match(request.url, "^tern%-software%-factory://carly/(%d+)$")
	if not block_id then return nil end
	local block_key = key(tonumber(block_id))
	if not find_block(cx, block_key) then return { handled = true } end
	local ok, data = pcall(tern.kv.get, "carly:" .. block_key)
	if not ok or type(data) ~= "table" or type(data.repo) ~= "table" then
		cx:toast("error", "Cannot ask Carly", "The repository request is no longer available. Try again.")
		return { handled = true }
	end
	pcall(tern.kv.set, "carly:" .. block_key, nil)
	local dirs = {}
	for _, worktree in data.worktrees or {} do table.insert(dirs, worktree.path) end
	local sessions = sessions_in(cx, dirs)
	cx:prompt({ placeholder = "Ask Carly to start an agent in " .. data.repo.name .. "…", action = "ask Carly" })
		:next(function(text, _, prompt_cx)
			if type(text) ~= "string" or not text:find("%S") then return end
			prompt_cx:ask_carly(message(text, data, sessions))
		end)
	return { handled = true }
end

-- Registers `start_agent` for Carly. Exports receive their positional arguments,
-- then cx and the call, so an omitted `session` shifts cx forward.
local function register()
	if not (tern.carly and tern.carly.export) then return end
	tern.carly.export("start_agent", {
		sig = "start_agent(cwd: string, prompt: string, session: string?) -> { pane: number, session: string }",
		doc = "Starts an omp agent in a new tab, working in `cwd` (a repository checkout or worktree directory) "
			.. "with `prompt` as its first message. `session` is the exact name of the Tern session to start it in; "
			.. "nil keeps the current session. Software Factory's Agents page sends you a repository's checkouts "
			.. "and sessions when the user asks for an agent there.",
	}, function(...)
		local args = table.pack(...)
		local cx = args[args.n - 1]
		local cwd, prompt = args[1], args[2]
		local session = if args.n >= 5 and args[3] ~= tern.json.null then args[3] else nil
		if type(cwd) ~= "string" or not (cwd:sub(1, 1) == "/" or cwd:sub(1, 1) == "~") then
			error("cwd must be an absolute directory")
		end
		if type(prompt) ~= "string" or not prompt:find("%S") then error("prompt must not be empty") end
		if session ~= nil and type(session) ~= "string" then error("session must be a session name") end
		if session then cx.sessions:switch(session) end
		local pane = cx.agents:start({ prompt = prompt, cwd = cwd, how = "tab" })
		return { pane = pane, session = cx.sessions:current().name }
	end)
end

return { route = route, register = register, message = message, sessions_in = sessions_in }
