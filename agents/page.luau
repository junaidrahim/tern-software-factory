--!nonstrict
-- The Agents page: repositories as a tree, each with the agents working in it
-- and the worktree each one uses. `c` asks Carly to start an agent in the
-- selected repository (window.luau hands the request to agents/carly.luau).
local tree = require("./tree")
local ui = tern.ui
local LIST = "main.tree.rows"

local function encode(value)
	return (value:gsub("[^A-Za-z0-9_.~%-]", function(byte) return string.format("%%%02X", string.byte(byte)) end))
end

local function plural(count, word)
	return tostring(count) .. " " .. word .. (if count == 1 then "" else "s")
end

-- `h` lends host.luau's helpers: plain, statuses, row_status, agent_task,
-- running_subagents, sub_status, sub_doing, sub_summary, panel, section, note,
-- activity, sub_activity, select_entry, inspect_selected, open_selected,
-- block_key and the repositories section (root folder and scan).
local function create(h)
	-- Paths read from this host's home directory as `~`; Carly and routes get them whole.
	local home = tern.getenv("HOME")
	local function show(path) return tree.tilde(path, home) end

	-- Rows in display order: each group, then (unless folded) its agents and their subagents.
	local function entries(state)
		local list = {}
		local folded = state.tree.folded
		for _, group in tree.group(state.repositories.repos, state.agents) do
			local group_id = if group.other then "other" else "r" .. encode(group.repo.path)
			table.insert(list, { id = group_id, group_id = group_id, kind = "group", group = group })
			if not folded[group_id] then
				for _, member in group.agents do
					local agent = member.agent
					local id = "a" .. string.format("%.0f", agent.pane)
					table.insert(list, { id = id, group_id = group_id, kind = "agent", group = group, agent = agent, checkout = member.checkout })
					for _, sub in agent.subagents or {} do
						table.insert(list, { id = id .. ".s" .. sub.key, group_id = group_id, kind = "sub", group = group,
							agent = agent, sub = sub, checkout = member.checkout })
					end
				end
			end
		end
		return list
	end

	-- The cursor's row; a row that left (or was folded away) falls back to its group.
	local function current(state, list)
		local page = state.tree
		for index, entry in list do if entry.id == page.cursor then return index end end
		for index, entry in list do if entry.id == page.cursor_group then return index end end
		return 1
	end

	-- Moves the cursor; an agent row also becomes the Agents page's selection, so
	-- its activity loads and Enter goes to its pane.
	local function select(state, entry, cx)
		local page = state.tree
		page.cursor = if entry then entry.id else nil
		page.cursor_group = if entry then entry.group_id else nil
		if entry and entry.agent then
			h.select_entry(state, { agent = entry.agent, sub = entry.sub })
			h.inspect_selected(state, cx)
		end
	end

	local function toggle(state, entry)
		if #entry.group.agents == 0 then return end
		local folded = state.tree.folded
		folded[entry.group_id] = if folded[entry.group_id] then nil else true
	end

	local function counts_of(agents)
		local counts = { working = 0, waiting_input = 0, idle = 0, failed = 0 }
		for _, agent in agents do
			local category = if h.row_status(agent).tone == "error" then "failed" else agent.state
			if counts[category] then counts[category] += 1 end
		end
		return counts
	end

	local function members(group)
		local agents = {}
		for _, member in group.agents do table.insert(agents, member.agent) end
		return agents
	end

	local function summary(group)
		if #group.agents == 0 then return "No agents" end
		local counts, parts = counts_of(members(group)), {}
		for _, name in { "working", "waiting_input", "failed", "idle" } do
			if counts[name] > 0 then table.insert(parts, tostring(counts[name]) .. " " .. string.lower(h.statuses[name].label)) end
		end
		return table.concat(parts, " · ")
	end

	local function group_row(state, entry)
		local group = entry.group
		local marker = if #group.agents == 0 then "◦ " elseif state.tree.folded[entry.group_id] then "▸ " else "▾ "
		local name = if group.other then "Other agents" else h.plain(group.repo.name)
		local where = if group.other then "Outside the repositories root" else tree.describe(group.checkouts[1])
		local worktrees = if group.other or #group.checkouts == 1 then "" else plural(#group.checkouts - 1, "worktree")
		local text = summary(group)
		local path = if group.other then "" else show(group.repo.path)
		return ui.node("item", {
			key = entry.id,
			role = if #group.agents == 0 then "factory-tree-repo-quiet" else "factory-tree-repo",
			label = { ui.span(marker .. name, "strong"), ui.span(where, "muted"), ui.span(worktrees, "muted") },
			detail = { ui.span(text, "muted") },
			title = name .. (if path ~= "" then "\n" .. path else "") .. "\n" .. text,
			aria = "Repository " .. name .. ", " .. where .. ", " .. text,
		})
	end

	local function agent_row(entry)
		local agent = entry.agent
		local status = h.row_status(agent)
		local running = h.running_subagents(agent)
		local note = if running > 0 then status.note .. " · " .. plural(running, "subagent") else status.note
		-- Delivery errors replace the task; they need attention first.
		local doing = if agent.delivery_error and agent.delivery_error ~= "" then h.plain(agent.delivery_error) else h.agent_task(agent)
		local worktree = if entry.checkout then tree.describe(entry.checkout) else show(h.plain(agent.cwd or ""))
		local session = h.plain(agent.session or "")
		if session == "" then session = "—" end
		return ui.node("item", {
			key = entry.id,
			role = "factory-tree-agent",
			-- An untoned span renders as a bare text node, which cannot ellipsize.
			label = { ui.span(doing, "task"), ui.span(worktree, "dir"), ui.span(session, "muted") },
			detail = { ui.span("●", status.tone), ui.span(status.label, status.tone), ui.span(note, "muted") },
			tone = status.tone,
			title = doing .. "\nWorktree: " .. worktree .. "\nSession: " .. session .. "\n" .. status.label .. " · " .. note
				.. "\nWorking directory: " .. show(h.plain(agent.cwd or "")),
			aria = doing .. ", " .. worktree .. ", " .. session .. ", " .. status.label .. ", " .. note,
		})
	end

	local function sub_row(entry)
		local sub = entry.sub
		local status = h.sub_status(sub)
		local name, kind = h.plain(sub.name), h.plain(sub.agent)
		local doing, stats = h.sub_doing(sub), h.sub_summary(sub, false)
		return ui.node("item", {
			key = entry.id,
			role = "factory-tree-sub",
			label = { ui.span("↳ " .. name .. (if kind ~= "" then " · " .. kind else ""), "muted"), ui.span(doing, "muted"), ui.span(stats, "muted") },
			detail = { ui.span("●", status.tone), ui.span(status.label, status.tone) },
			tone = status.tone,
			title = name .. "\n" .. kind .. "\n" .. status.label .. "\n" .. doing .. "\n" .. h.sub_summary(sub, true),
			aria = "Subagent " .. name .. ", " .. status.label .. ", " .. doing,
		})
	end

	-- The detail panel of a group row: its checkouts with their agents, and where they run.
	local function group_panel(state, entry)
		local group = entry.group
		if group.other then
			return h.panel("Other agents", { label = summary(group), tone = "muted" }, {},
				{ h.note("These agents work outside every repository under " .. show(state.repositories.root) .. ".") })
		end
		local repo = group.repo
		local per_checkout, sessions, order = {}, {}, {}
		for _, member in group.agents do
			per_checkout[member.checkout.path] = (per_checkout[member.checkout.path] or 0) + 1
			local session = h.plain(member.agent.session or "")
			if session ~= "" then
				if not sessions[session] then sessions[session] = 0; table.insert(order, session) end
				sessions[session] += 1
			end
		end
		local checkouts = {}
		for _, checkout in group.checkouts do
			local count = per_checkout[checkout.path] or 0
			table.insert(checkouts, { { ui.span(tree.describe(checkout), if checkout.missing then "warning" else "strong") },
				{ ui.span((if count > 0 then plural(count, "agent") .. " · " else "") .. show(checkout.path), "muted") } })
		end
		local body = { h.section("worktrees", "Worktrees", ui.kv(checkouts)) }
		if #order > 0 then
			local rows = {}
			for _, session in order do table.insert(rows, { { ui.span(session, "strong") }, { ui.span(plural(sessions[session], "agent"), "muted") } }) end
			table.insert(body, h.section("sessions", "Tern sessions", ui.kv(rows)))
		end
		table.insert(body, h.note("Press c to ask Carly to start an agent in this repository."))
		return h.panel(h.plain(repo.name), { label = summary(group), tone = "muted" }, { show(repo.path) }, body)
	end

	-- Saves the repository's checkouts and agents for the window, then asks it to
	-- prompt for the request and hand it to Carly.
	local function ask_carly(entry, cx)
		local group = entry and entry.group
		if not group or group.other then
			cx:toast("info", "Choose a repository", "Carly starts agents in a repository; select one first.")
			return
		end
		local worktrees, agents = {}, {}
		for _, checkout in group.checkouts do
			table.insert(worktrees, { path = checkout.path, label = tree.describe(checkout), main = checkout.main, missing = checkout.missing == true })
		end
		for _, member in group.agents do
			table.insert(agents, { task = h.agent_task(member.agent), state = member.agent.state,
				session = h.plain(member.agent.session or ""), worktree = member.checkout.path })
		end
		local ok = pcall(tern.kv.set, "carly:" .. h.block_key(cx.pane),
			{ repo = { name = group.repo.name, path = group.repo.path }, worktrees = worktrees, agents = agents })
		if not ok then
			cx:toast("error", "Cannot ask Carly", "Cannot save the request. Try again.")
			return
		end
		-- The window finds the block, and its request, by the block's full id.
		cx:open("tern-software-factory://carly/" .. string.format("%.0f", cx.pane))
	end

	local function button(key, label, action, disabled)
		return ui.node("el", { key = key, tag = "button", role = "factory-tree-button", aria = label,
			disabled = disabled, actions = { click = action } }, { ui.text(label) })
	end

	local function open(state, entry, cx)
		if entry.kind == "group" then
			toggle(state, entry)
		else
			select(state, entry, cx)
			h.open_selected(state, cx)
		end
	end

	-- A repository's terminal block beside this block, or a new session there
	-- (window.luau's `repo-block` and `repo-session` routes).
	local function launch(entry, cx, session)
		cx:open("tern-software-factory://" .. (if session then "repo-session/" else "repo-block/")
			.. string.format("%.0f", cx.pane) .. "/" .. encode(entry.group.repo.path))
	end

	-- Double-click: a repository opens a terminal block at its path; other rows act like Enter.
	local function activate(state, entry, cx)
		if entry.kind == "group" and not entry.group.other then launch(entry, cx, false) else open(state, entry, cx) end
	end

	return {
		id = "agents",
		label = "Agents",
		-- The page's own state lives in `state.tree`; `state.agents` is the agent list.
		state = "tree",
		init = function(saved)
			saved = if type(saved) == "table" then saved else {}
			local folded = {}
			for id, value in if type(saved.folded) == "table" then saved.folded else {} do
				if type(id) == "string" and value == true then folded[id] = true end
			end
			return { folded = folded, cursor = if type(saved.cursor) == "string" then saved.cursor else nil }
		end,
		save = function(state)
			return { folded = state.tree.folded, cursor = state.tree.cursor }
		end,
		enter = function(state, cx)
			h.repositories.enter(state, cx)
			local list = entries(state)
			if #list > 0 then select(state, list[current(state, list)], cx) end
		end,
		capture_key = h.repositories.capture_key,
		view = function(state, cx)
			local repositories = state.repositories
			local list = entries(state)
			local entry = list[current(state, list)]
			local rows = {}
			for _, item in list do
				table.insert(rows, if item.kind == "group" then group_row(state, item) elseif item.kind == "agent" then agent_row(item) else sub_row(item))
			end
			local heading = {
				ui.text({ ui.span("Agents", "bold") }),
				ui.badge(if state.loaded then tostring(#state.agents) else "…", "muted"),
			}
			local counts = counts_of(state.agents)
			for _, name in { "working", "waiting_input", "failed", "idle" } do
				if counts[name] > 0 then table.insert(heading, ui.badge(tostring(counts[name]) .. " " .. h.statuses[name].label, h.statuses[name].tone)) end
			end
			table.insert(heading, button("carly", "Ask Carly", "agents-carly", not entry or entry.group.other == true))
			for _, node in h.repositories.buttons(state) do table.insert(heading, node) end
			local subtitle, tone = "By repository under " .. show(repositories.root), "muted"
			if repositories.root == "" then
				subtitle = "Choose a root folder on this host to group agents by repository."
			elseif repositories.error then
				subtitle, tone = repositories.error, "error"
			elseif repositories.loading then
				subtitle = "Scanning repositories under " .. show(repositories.root) .. "…"
			end
			local messages = { ui.text({ ui.span(subtitle, tone) }) }
			for _, warning in repositories.warnings do table.insert(messages, ui.text({ ui.span(warning, "warning") })) end
			local detail = if not entry then h.note(if state.loaded then "No agents or repositories to show yet." else "Loading agents…")
				elseif entry.kind == "group" then group_panel(state, entry)
				elseif entry.kind == "sub" then h.sub_activity(state, entry.agent, entry.sub)
				else h.activity(state, entry.agent)
			local where = show(if not entry then repositories.root
				elseif entry.agent then h.plain(entry.agent.cwd or "")
				elseif entry.group.other then repositories.root
				else entry.group.repo.path)
			return {
				main = ui.node("col", {}, {
					ui.node("row", { role = "factory-heading" }, heading),
					ui.node("col", { role = "factory-tree-status" }, messages),
					ui.node("col", { key = "tree", role = "factory-tree" }, {
						ui.node("row", { role = "factory-tree-columns" }, {
							ui.text("Agent task"), ui.text("Worktree"), ui.text("Session"), ui.text("Status"),
						}),
						ui.node("list", {
							key = "rows",
							selected = if entry then LIST .. "." .. entry.id else nil,
							empty = { ui.span(if state.loaded then "No agents are running on this host." else "Loading agents…", "muted") },
							max = 0.45,
						}, rows),
					}),
					detail,
				}),
				layer = h.repositories.layer(state),
				dock = ui.node("col", { role = "factory-footer" }, {
					ui.text({ ui.span(where, "muted") }),
					ui.text({ ui.span("↑ ↓ Select · Enter Go to pane or fold · Double-click repository Terminal · Cmd+Enter New session · c Ask Carly · r Rescan", "muted") }),
				}),
			}
		end,
		key = function(state, key, cx)
			local list = entries(state)
			local index = current(state, list)
			local entry = list[index]
			if key.name == "enter" and key.meta and not key.ctrl and not key.alt then
				if entry and entry.kind == "group" and not entry.group.other then launch(entry, cx, true) end
				return true
			end
			if key.ctrl or key.alt or key.meta then return false end
			if key.name == "r" then h.repositories.scan(state, cx); return true end
			if not entry then return false end
			if key.name == "enter" or key.name == "space" then open(state, entry, cx); return true end
			if key.name == "c" then ask_carly(entry, cx); return true end
			if key.name == "down" or key.name == "j" then index = math.min(#list, index + 1)
			elseif key.name == "up" or key.name == "k" then index = math.max(1, index - 1)
			elseif key.name == "home" then index = 1
			elseif key.name == "end" then index = #list
			elseif key.name == "page_down" then index = math.min(#list, index + 10)
			elseif key.name == "page_up" then index = math.max(1, index - 10)
			else return false end
			select(state, list[index], cx)
			return true
		end,
		event = function(state, event, cx)
			if h.repositories.event(state, event, cx) then return end
			if event.ev == "action" and event.act == "agents-carly" then
				local list = entries(state)
				ask_carly(list[current(state, list)], cx)
			elseif (event.ev == "select" or event.ev == "activate") and event.id == LIST then
				for _, entry in entries(state) do
					if LIST .. "." .. entry.id == event.item then
						select(state, entry, cx)
						if event.ev == "activate" then activate(state, entry, cx) end
						return
					end
				end
			end
		end,
	}
end

return { create = create }
