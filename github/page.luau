--!nonstrict
local ui = tern.ui
local controller = require("./controller")
local LIST = "main.github.tree"
local ITEM = LIST .. "."

-- Keep each native list cell one span, including titles containing Nerd Font icons.
local function plain(value)
	return (tostring(value or ""):gsub("\xEE[\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xEF[\x80-\xA3][\x80-\xBF]", "")
		:gsub("\xF3[\xB0-\xBF][\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xF4[\x80-\x8F][\x80-\xBF][\x80-\xBF]", "")
		:gsub("[%c]", " "))
end

-- Hex escapes make native item IDs unambiguous even for names containing dots.
local function row_key(repo)
	return "r" .. repo.id:gsub("[^%w-]", function(char) return string.format("_%02x", string.byte(char)) end)
end

-- Repositories start collapsed; `expanded` holds the repository row keys this pane unfolded.
local function entries(data, expanded)
	local rows = {}
	for _, repo in data.repos do
		local id = row_key(repo)
		table.insert(rows, { id = id, repo = repo })
		if expanded[id] then
			for _, pr in repo.prs do table.insert(rows, { id = id .. ".pr" .. tostring(pr.number), repo = repo, pr = pr }) end
			if type(repo.cursor) == "string" then table.insert(rows, { id = id .. ".more", repo = repo, more = true }) end
		end
	end
	return rows
end

local function total(repo)
	return if type(repo.total) == "number" then repo.total else #repo.prs
end

local function selected_index(github, rows)
	local selected = github.selected
	for i, row in rows do if row.id == selected then return i end end
	-- A PR or load-more row folded away falls back to its repository row.
	local parent = type(selected) == "string" and selected:match("^([^.]+)%.")
	if parent then for i, row in rows do if row.id == parent then return i end end end
	return 1
end

-- Without rows (not loaded yet) the saved selection is kept for when they arrive.
local function reconcile(github, rows)
	if #rows == 0 then return nil end
	local index = selected_index(github, rows)
	github.selected = rows[index].id
	return index
end

local function toggle(github, row)
	if #row.repo.prs == 0 then return end
	github.expanded[row.id] = if github.expanded[row.id] then nil else true
end

local function open(row, cx)
	if not row then return end
	local url = if row.pr then row.pr.url else row.repo.url
	-- Only original github.com repository/PR pages may leave the plugin.
	if type(url) ~= "string" then return end
	if row.pr then
		if url:match("^https://github%.com/[%w_.-]+/[%w_.-]+/pull/%d+$") then cx:open(url) end
	elseif url:match("^https://github%.com/[%w_.-]+/[%w_.-]+$") then cx:open(url) end
end

local function message(key, role, value, tone)
	local node = ui.text({ ui.span(value, tone) })
	node.p = node.p or {}
	node.p.key, node.p.role = key, role
	return node
end

local function activate(github, row, cx)
	if row.more then controller.more(row.repo.id)
	elseif row.pr then open(row, cx)
	else toggle(github, row) end
end

local function view(state)
	local github, data = state.github, controller.get()
	local visible, rows, count = entries(data, github.expanded), {}, 0
	local index = reconcile(github, visible)
	-- Forget folds of repositories a completed load no longer lists, so saved state stays bounded.
	local present = data.loaded and {}
	for _, entry in visible do
		local repo, pr = entry.repo, entry.pr
		local name = plain(repo.name)
		if pr then
			local number, title = tostring(pr.number), plain(pr.title)
			local branches = plain(pr.head) .. " → " .. plain(pr.base)
			local author = "@" .. plain(pr.author)
			local status = if pr.draft then "Draft" else "Open"
			table.insert(rows, ui.node("item", {
				key = entry.id, role = "factory-github-pr",
				label = { ui.span("↳ #" .. number, "muted"), ui.span(title, "strong"),
					ui.span(author .. " · " .. status .. " · " .. branches, "muted") },
				title = name .. " #" .. number .. "\n" .. title .. "\n" .. author .. " · " .. status
					.. "\n" .. branches .. "\nUpdated: " .. plain(pr.updated_at) .. "\n" .. plain(pr.url),
				aria = name .. ", pull request " .. number .. ", " .. title .. ", " .. author .. ", " .. status .. ", " .. branches,
			}))
		elseif entry.more then
			local shown = tostring(#repo.prs) .. " of " .. tostring(total(repo)) .. " shown"
			local status = if controller.loading_more(repo.id) then "Loading more…"
				elseif repo.page_error then "Error: " .. plain(repo.page_error) .. " · Enter to retry"
				else "Load more"
			table.insert(rows, ui.node("item", {
				key = entry.id, role = "factory-github-more", tone = if repo.page_error then "error" else nil,
				label = { ui.span("↳ " .. status, if repo.page_error then "error" else "strong"), ui.span(shown, "muted") },
				title = name .. "\n" .. shown, aria = name .. ", " .. status .. ", " .. shown,
			}))
		else
			if present then present[entry.id] = true end
			local open_count = total(repo)
			count += open_count
			local expanded = github.expanded[entry.id]
			local marker = if #repo.prs == 0 then "◦ " elseif expanded then "▾ " else "▸ "
			local status = if repo.error then "Error: " .. plain(repo.error) .. (if repo.stale then " · Showing last loaded PRs" else "")
				elseif open_count == 0 then "No open PRs" else tostring(open_count) .. " open PR" .. (if open_count == 1 then "" else "s")
			table.insert(rows, ui.node("item", {
				key = entry.id, role = "factory-github-repository", tone = if repo.error then "error" else nil,
				label = { ui.span(marker .. name, "strong"), ui.span(status, if repo.error then "error" else "muted") },
				title = name .. "\n" .. plain(repo.path) .. "\n" .. status .. "\n" .. plain(repo.url),
				aria = name .. ", " .. status .. (if #repo.prs == 0 then "" elseif expanded then ", expanded" else ", collapsed"),
			}))
		end
	end
	if present then
		for id in github.expanded do if not present[id] then github.expanded[id] = nil end end
	end
	local children = {
		ui.node("row", { key = "heading", role = "factory-github-actions" }, {
			ui.text({ ui.span("GitHub", "strong") }),
			ui.badge(tostring(#data.repos) .. " repositories · " .. tostring(count) .. " PRs", "muted"),
			ui.node("el", { key = "refresh", tag = "button", role = "factory-github-button", actions = { click = "github-refresh" } }, {
				ui.text(if data.loading then "Refreshing…" else "Refresh"),
			}),
		}),
		message("root", "factory-github-root", if data.root == ""
			then "Set Root folder on Agents to show GitHub repositories from that same folder." else data.root, "muted"),
	}
	if data.error then
		table.insert(children, message("error", "factory-github-error", data.error, "error"))
	end
	if #data.warnings > 0 then
		table.insert(children, message("warnings", "factory-github-warning", table.concat(data.warnings, "\n"), "warning"))
	end
	local empty = if data.root == "" then "No root folder configured."
		elseif data.loading then "Loading repositories and open pull requests…"
		elseif data.error then "GitHub data unavailable. Resolve the error above, then Refresh."
		elseif data.loaded then "No GitHub repositories found in this root folder."
		else "Refresh to load GitHub repositories."
	table.insert(children, ui.node("list", {
		key = "tree", role = "factory-github-tree", selected = if index then ITEM .. github.selected else nil,
		empty = { ui.span(empty, "muted") }, max = 1,
	}, rows))
	return {
		main = ui.node("col", {}, { ui.node("col", { key = "github", role = "factory-github" }, children) }),
		dock = ui.node("col", { role = "factory-github-footer" }, {
			ui.text({ ui.span("↑ ↓ / j k Select · Enter Expand repository, open PR or load more · o Open on GitHub · r Refresh", "muted") }),
		}),
	}
end

return {
	init = function(saved)
		saved = if type(saved) == "table" then saved else {}
		local expanded = {}
		for id, value in if type(saved.expanded) == "table" then saved.expanded else {} do
			if type(id) == "string" and value == true then expanded[id] = true end
		end
		return { selected = if type(saved.selected) == "string" then saved.selected else nil, expanded = expanded }
	end,
	enter = function(_, cx) controller.attach(cx) end,
	save = function(state) return { selected = state.github.selected, expanded = state.github.expanded } end,
	view = view,
	key = function(state, key, cx)
		if key.ctrl or key.alt or key.meta then return false end
		if key.name == "r" then controller.refresh(); return true end
		local rows = entries(controller.get(), state.github.expanded)
		local index = reconcile(state.github, rows)
		if not index then return false end
		if key.name == "enter" then activate(state.github, rows[index], cx); return true
		elseif key.name == "o" then open(rows[index], cx); return true
		elseif key.name == "down" or key.name == "j" then index = math.min(#rows, index + 1)
		elseif key.name == "up" or key.name == "k" then index = math.max(1, index - 1)
		elseif key.name == "home" then index = 1
		elseif key.name == "end" then index = #rows
		elseif key.name == "page_down" then index = math.min(#rows, index + 10)
		elseif key.name == "page_up" then index = math.max(1, index - 10)
		else return false end
		state.github.selected = rows[index].id
		return true
	end,
	event = function(state, event, cx)
		if event.ev == "action" and event.act == "github-refresh" then controller.refresh(); return end
		if (event.ev == "select" or event.ev == "activate") and event.id == LIST
			and type(event.item) == "string" and string.sub(event.item, 1, #ITEM) == ITEM then
			local id = string.sub(event.item, #ITEM + 1)
			for _, row in entries(controller.get(), state.github.expanded) do
				if row.id == id then
					state.github.selected = row.id
					if event.ev == "activate" then activate(state.github, row, cx) end
					return
				end
			end
		end
	end,
}
