--!nonstrict
local ui = tern.ui
local controller = require("./controller")
local LIST = "main.github.tree"

-- Keep each native list cell one span, including titles containing Nerd Font icons.
local function plain(value)
	return (tostring(value or ""):gsub("\xEE[\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xEF[\x80-\xA3][\x80-\xBF]", "")
		:gsub("\xF3[\xB0-\xBF][\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xF4[\x80-\x8F][\x80-\xBF][\x80-\xBF]", "")
		:gsub("[%c]", " "))
end

local function row_key(repo, pr)
	-- Hex escapes make native item IDs unambiguous even for names containing dots.
	local id = repo.id:gsub("[^%w-]", function(char) return string.format("_%02x", string.byte(char)) end)
	return "r" .. id .. (if pr then ".pr" .. tostring(pr.number) else "")
end

local function entries(data)
	local rows = {}
	for _, repo in data.repos do
		table.insert(rows, { id = row_key(repo), repo = repo })
		for _, pr in repo.prs do table.insert(rows, { id = row_key(repo, pr), repo = repo, pr = pr }) end
	end
	return rows
end

local function selected_index(github, rows)
	for i, row in rows do if row.id == github.selected then return i end end
	return 1
end

local function reconcile(github, rows)
	local index = selected_index(github, rows)
	github.selected = rows[index] and rows[index].id
	return index
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

local function view(state)
	local github, data = state.github, controller.get()
	local visible, rows, count = entries(data), {}, 0
	reconcile(github, visible)
	for _, entry in visible do
		local repo, pr = entry.repo, entry.pr
		if pr then
			count += 1
			local branches = plain(pr.head) .. " → " .. plain(pr.base)
			local author = "@" .. plain(pr.author)
			local status = if pr.draft then "Draft" else "Open"
			table.insert(rows, ui.node("item", {
				key = entry.id, role = "factory-github-pr",
				label = { ui.span("↳ #" .. tostring(pr.number), "muted"), ui.span(plain(pr.title), "strong"),
					ui.span(author .. " · " .. status .. " · " .. branches, "muted") },
				title = repo.name .. " #" .. tostring(pr.number) .. "\n" .. plain(pr.title) .. "\n" .. author .. " · " .. status
					.. "\n" .. branches .. "\nUpdated: " .. plain(pr.updated_at) .. "\n" .. plain(pr.url),
				aria = repo.name .. ", pull request " .. tostring(pr.number) .. ", " .. plain(pr.title) .. ", " .. author .. ", " .. status .. ", " .. branches,
			}))
		else
			local status = if repo.error then "Error: " .. plain(repo.error) .. (if repo.stale then " · Showing last loaded PRs" else "")
				elseif #repo.prs == 0 then "No open PRs" else tostring(#repo.prs) .. " open PR" .. (if #repo.prs == 1 then "" else "s")
			table.insert(rows, ui.node("item", {
				key = entry.id, role = "factory-github-repository", tone = if repo.error then "error" else nil,
				label = { ui.span(plain(repo.name), "strong"), ui.span(status, if repo.error then "error" else "muted") },
				title = plain(repo.name) .. "\n" .. plain(repo.path) .. "\n" .. status .. "\n" .. plain(repo.url),
				aria = plain(repo.name) .. ", " .. status,
			}))
		end
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
		key = "tree", role = "factory-github-tree", selected = if github.selected then LIST .. "." .. github.selected else nil,
		empty = { ui.span(empty, "muted") }, max = 1,
	}, rows))
	return {
		main = ui.node("col", {}, { ui.node("col", { key = "github", role = "factory-github" }, children) }),
		dock = ui.node("col", { role = "factory-github-footer" }, {
			ui.text({ ui.span("↑ ↓ / j k Select · Enter / o Open on GitHub · r Refresh", "muted") }),
		}),
	}
end

return {
	init = function(saved)
		return { selected = if type(saved) == "table" and type(saved.selected) == "string" then saved.selected else nil }
	end,
	enter = function(_, cx) controller.attach(cx) end,
	save = function(state) return { selected = state.github.selected } end,
	view = view,
	key = function(state, key, cx)
		if key.ctrl or key.alt or key.meta then return false end
		if key.name == "r" then controller.refresh(); return true end
		local rows = entries(controller.get())
		local index = reconcile(state.github, rows)
		if #rows == 0 then return false end
		if key.name == "enter" or key.name == "o" then open(rows[index], cx); return true
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
		if (event.ev == "select" or event.ev == "activate") and event.id == LIST then
			for _, row in entries(controller.get()) do
				if LIST .. "." .. row.id == event.item then
					state.github.selected = row.id
					if event.ev == "activate" then open(row, cx) end
					return
				end
			end
		end
	end,
}
