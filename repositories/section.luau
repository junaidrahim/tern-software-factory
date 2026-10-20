--!nonstrict
local ui = tern.ui
local LIST = "main.repositories.tree"
local INPUT = "layer.repository-root.body.root"
local ROOT_SETTING = "repositories:root"

local function shared_root(saved)
	local ok, root = pcall(tern.kv.get, ROOT_SETTING)
	if not ok then return nil, "Cannot read the saved repository root. Try again." end
	if root == nil then
		root = if type(saved) == "table" and type(saved.root) == "string" then saved.root else ""
		if root ~= "" and not pcall(tern.kv.set, ROOT_SETTING, root) then
			return nil, "Cannot migrate the repository root. Save it again using Root folder."
		end
	end
	if type(root) ~= "string" then return nil, "The saved repository root is invalid. Set it using Root folder." end
	return root
end

local function set_root(repositories, root)
	if root ~= repositories.root then
		repositories.root, repositories.repos, repositories.warnings, repositories.selected = root, {}, {}, nil
		repositories.generation += 1
		repositories.error, repositories.loading = nil, root ~= ""
	end
	repositories.configured_root = root
end

local function encode(value)
	return (value:gsub("[^A-Za-z0-9_.~%-]", function(byte) return string.format("%%%02X", string.byte(byte)) end))
end

local function rows(repositories)
	local result = {}
	for _, repo in repositories.repos do
		table.insert(result, { path = repo.path, name = repo.name, branch = repo.branch, detached = repo.detached, missing = repo.missing, locked = repo.locked })
		for _, worktree in repo.worktrees do
			table.insert(result, { path = worktree.path, name = worktree.path:match("([^/]+)/*$") or worktree.path,
				branch = worktree.branch, detached = worktree.detached, locked = worktree.locked, missing = worktree.missing, child = true })
		end
	end
	return result
end

local function item_id(path) return LIST .. ".p" .. encode(path) end

local function selected_index(repositories, list)
	for index, row in list do if row.path == repositories.selected then return index end end
	return 1
end

local function notify(cx) pcall(function() cx:render() end) end
local scan
scan = function(repositories, cx)
	if repositories.root == "" or repositories.active then return end
	local job = { root = repositories.root, generation = repositories.generation }
	repositories.active, repositories.loading, repositories.error = job, true, nil
	local finished = false
	local function finish(result, failure)
		if finished then return end
		finished = true
		repositories.active = nil
		if job.generation ~= repositories.generation then
			scan(repositories, cx)
			notify(cx)
			return
		end
		repositories.loading = false
		local ok, problem = pcall(function()
			if failure then error(failure, 0) end
			if type(result) ~= "table" then error("Repository worker returned no result.", 0) end
			if result.timed_out then error("Repository scan timed out after 120 seconds. Try a smaller root folder.", 0) end
			if result.status ~= 0 then error("Repository worker failed. Check that uv, Python 3.11 or newer, and Git are available on this host.", 0) end
			local decoded, answer = pcall(tern.json.decode, result.stdout)
			if not decoded or type(answer) ~= "table" then error("Repository worker returned invalid JSON.", 0) end
			if answer.ok ~= true then error(if type(answer.error) == "string" then answer.error else "Repository scan failed.", 0) end
			if type(answer.root) ~= "string" or answer.root:sub(1, 1) ~= "/" or type(answer.repos) ~= "table" then
				error("Repository worker returned an invalid repository list.", 0)
			end
			for _, repo in answer.repos do
				if type(repo) ~= "table" or type(repo.path) ~= "string" or repo.path:sub(1, 1) ~= "/" or type(repo.name) ~= "string" or type(repo.worktrees) ~= "table" then
					error("Repository worker returned an invalid repository.", 0)
				end
				for _, worktree in repo.worktrees do
					if type(worktree) ~= "table" or type(worktree.path) ~= "string" or worktree.path:sub(1, 1) ~= "/" or type(worktree.branch) ~= "string" then
						error("Repository worker returned an invalid worktree.", 0)
					end
				end
			end
			local warnings = {}
			if type(answer.warnings) == "table" then
				for _, warning in answer.warnings do if type(warning) == "string" then table.insert(warnings, warning) end end
			end
			repositories.root, repositories.repos, repositories.warnings = answer.root, answer.repos, warnings
			local list = rows(repositories)
			local selected = list[selected_index(repositories, list)]
			repositories.selected = if selected then selected.path else nil
		end)
		if not ok then repositories.error = tostring(problem) end
		notify(cx)
	end
	local ok = pcall(function()
		local home = tern.getenv("HOME")
		local local_uv = home and (home .. "/.local/bin/uv")
		local uv = if local_uv and tern.fs.exists(local_uv) then local_uv else "uv"
		tern.process.run({ uv, "run", "--script", tern.plugin.dir .. "/repositories/worker.py" }, {
			stdin = tern.json.encode({ root = job.root }), timeout_ms = 120000,
		}, function(result) finish(result) end)
	end)
	if not ok then finish(nil, "Cannot start repository worker. Install uv and Python 3.11 or newer on this host.") end
end

-- The input is edited through keys, not native edit events. Byte-boundary
-- cursor state is converted to UTF-16 for Tern's native selection props.
local function utf16(text, bytes)
	local units = 0
	for _, cp in utf8.codes(text:sub(1, bytes)) do units += if cp > 0xFFFF then 2 else 1 end
	return units
end
local function previous(text, cursor)
	return if cursor > 0 then (utf8.offset(text, -1, cursor + 1) or 1) - 1 else 0
end
local function following(text, cursor)
	return if cursor < #text then (utf8.offset(text, 2, cursor + 1) or (#text + 1)) - 1 else #text
end
local function replace(editor, text, from, to)
	local start = from or math.min(editor.cursor, editor.anchor or editor.cursor)
	local finish = to or math.max(editor.cursor, editor.anchor or editor.cursor)
	text = text:gsub("[%c]", " ")
	editor.text = editor.text:sub(1, start) .. text .. editor.text:sub(finish + 1)
	editor.cursor, editor.anchor = start + #text, nil
end
local function close(repositories, cx)
	repositories.editor = nil
	cx:frame({ { "focus", tern.json.null } })
end
local function save_root(repositories, cx)
	local root = repositories.editor.text
	if not pcall(tern.kv.set, ROOT_SETTING, root) then
		repositories.editor.error = "Cannot save the repository root. Check host storage permissions and try again."
		return
	end
	set_root(repositories, root)
	close(repositories, cx)
	scan(repositories, cx)
end
local function open_editor(repositories, cx)
	repositories.section = "repositories"
	repositories.editor = { text = repositories.root, cursor = #repositories.root }
	cx:frame({ { "focus", INPUT } })
end
local function edit_key(repositories, key, cx)
	local editor = repositories.editor
	if key.name == "escape" then close(repositories, cx)
	elseif key.name == "enter" then save_root(repositories, cx)
	elseif key.name == "tab" then cx:frame({ { "focus", INPUT } })
	elseif (key.meta or key.ctrl) and key.name == "a" then editor.anchor, editor.cursor = 0, #editor.text
	elseif key.name == "left" or key.name == "right" or key.name == "home" or key.name == "end" then
		local cursor = editor.cursor
		if key.shift then editor.anchor = editor.anchor or cursor end
		if key.name == "home" or (key.name == "left" and key.meta) then cursor = 0
		elseif key.name == "end" or (key.name == "right" and key.meta) then cursor = #editor.text
		elseif not key.shift and editor.anchor then cursor = if key.name == "left" then math.min(cursor, editor.anchor) else math.max(cursor, editor.anchor)
		elseif key.name == "left" then cursor = previous(editor.text, cursor)
		else cursor = following(editor.text, cursor) end
		editor.cursor = cursor
		if not key.shift then editor.anchor = nil end
	elseif key.name == "backspace" or key.name == "delete" then
		if editor.anchor and editor.anchor ~= editor.cursor then replace(editor, "")
		elseif key.name == "backspace" then replace(editor, "", previous(editor.text, editor.cursor), editor.cursor)
		else replace(editor, "", editor.cursor, following(editor.text, editor.cursor)) end
	elseif key.text and (key.name == "paste" or (not key.ctrl and not key.meta)) then replace(editor, key.text) end
	return true
end

local function launch(repositories, row, cx, session)
	if not row then return end
	if row.missing then repositories.error = "This worktree directory is missing: " .. row.path; return end
	cx:open("tern-software-factory://" .. (if session then "repo-session/" else "repo-block/")
		.. string.format("%.0f", cx.pane % 2^44) .. "/" .. encode(row.path))
end

local function button(key, label, action, disabled)
	return ui.node("el", { key = key, tag = "button", role = "factory-repositories-button", aria = label,
		disabled = disabled, actions = { click = action } }, { ui.text(label) })
end
local function view(state)
	local repositories = state.repositories
	local list, items = rows(repositories), {}
	for _, row in list do
		local branch = if row.detached then "detached" elseif row.branch and row.branch ~= "" then row.branch else ""
		local status = branch .. (if row.locked then " · locked" else "") .. (if row.missing then " · missing" else "")
		table.insert(items, ui.node("item", { key = "p" .. encode(row.path),
			role = if row.child then "factory-repository-worktree" else "factory-repository",
			label = { ui.span((if row.child then "↳ " else "") .. row.name, "strong"), ui.span(row.path, "muted") },
			detail = { ui.span(status, if row.missing then "warning" else "muted") },
			title = row.path .. "\n" .. status, aria = row.name .. ", " .. row.path .. ", " .. status,
		}))
	end
	local children = {
		ui.node("row", { role = "factory-repositories-heading" }, {
			ui.text({ ui.span("Repositories", "bold") }),
			ui.badge(if repositories.section == "repositories" then "Keyboard active" else tostring(#repositories.repos), "muted"),
			button("root-folder", "Root folder", "repositories-root"),
			button("refresh", "Refresh", "repositories-refresh", repositories.loading or repositories.root == ""),
		}),
		ui.text({ ui.span(if repositories.root == "" then "Choose a root folder on this host to discover repositories and linked worktrees." else repositories.root, "muted") }),
	}
	local messages = {}
	if repositories.loading then table.insert(messages, ui.text({ ui.span("Scanning repositories…", "muted") })) end
	if repositories.error then table.insert(messages, ui.text({ ui.span(repositories.error, "error") })) end
	for _, warning in repositories.warnings do table.insert(messages, ui.text({ ui.span(warning, "warning") })) end
	if #messages > 0 then table.insert(children, ui.node("col", { role = "factory-repositories-status" }, messages)) end
	table.insert(children, ui.node("list", { key = "tree", role = "factory-repositories-tree",
		selected = if repositories.selected then item_id(repositories.selected) else nil, max = 0.3,
		empty = { ui.span(if repositories.root == "" then "No root folder configured."
			elseif repositories.loading then "Discovering repositories…"
			elseif repositories.error then "No repository data available for this root."
			else "No Git repositories found in this root folder.", "muted") },
	}, items))
	return ui.node("col", { key = "repositories", role = "factory-repositories" }, children)
end
local function layer(state)
	local editor = state.repositories.editor
	if not editor then return ui.node("col", {}, {}) end
	return ui.node("col", {}, {
		ui.node("overlay", { key = "repository-root", head = "Repository root folder", modal = true, size = "md", anchor = "center" }, {
			ui.node("col", { key = "body", role = "factory-repositories-dialog" }, {
				ui.text({ ui.span(editor.error or "Saved for all blocks on this host. Use an absolute path or ~/…; leave empty to clear.",
					if editor.error then "error" else "muted") }),
				ui.node("input", { key = "root", role = "factory-repositories-root-input", text = editor.text,
					cursor = utf16(editor.text, editor.cursor), anchor = if editor.anchor then utf16(editor.text, editor.anchor) else nil,
					placeholder = "~/Code", aria = "Repository root folder" }),
				ui.node("row", { role = "factory-repositories-actions" }, {
					button("save", "Save", "repositories-root-save"), button("cancel", "Cancel", "repositories-root-cancel"),
				}),
			}),
		}),
	})
end

local function key(state, key, cx)
	local repositories = state.repositories
	if repositories.editor then return edit_key(repositories, key, cx) end
	if key.name == "tab" and not key.ctrl and not key.alt and not key.meta then
		repositories.section = if repositories.section == "agents" then "repositories" else "agents"
		return true
	end
	if repositories.section ~= "repositories" then return false end
	local list = rows(repositories)
	local index = selected_index(repositories, list)
	if key.name == "enter" and key.meta and not key.ctrl and not key.alt then launch(repositories, list[index], cx, true); return true end
	if key.ctrl or key.alt or key.meta then return false end
	if key.name == "r" then scan(repositories, cx); return true end
	if key.name == "enter" then launch(repositories, list[index], cx, false); return true end
	if #list == 0 then return false end
	if key.name == "down" or key.name == "j" then index = math.min(#list, index + 1)
	elseif key.name == "up" or key.name == "k" then index = math.max(1, index - 1)
	elseif key.name == "home" then index = 1
	elseif key.name == "end" then index = #list
	elseif key.name == "page_down" then index = math.min(#list, index + 10)
	elseif key.name == "page_up" then index = math.max(1, index - 10)
	else return false end
	repositories.selected = list[index].path
	return true
end
local function event(state, event, cx)
	local repositories = state.repositories
	if repositories.editor then
		if event.ev == "action" and event.act == "repositories-root-save" then save_root(repositories, cx)
		elseif event.ev == "action" and event.act == "repositories-root-cancel" then close(repositories, cx) end
		return true
	end
	if event.ev == "action" then
		if event.act == "repositories-root" then open_editor(repositories, cx); return true
		elseif event.act == "repositories-refresh" then repositories.section = "repositories"; scan(repositories, cx); return true end
	elseif (event.ev == "select" or event.ev == "activate") and event.id == LIST then
		for _, row in rows(repositories) do
			if item_id(row.path) == event.item then
				repositories.section, repositories.selected = "repositories", row.path
				if event.ev == "activate" then launch(repositories, row, cx, false) end
				break
			end
		end
		return true
	end
	return false
end

return {
	init = function(saved)
		saved = if type(saved) == "table" then saved else {}
		local root, problem = shared_root(saved)
		return { root = root or "", configured_root = root or "", error = problem, repos = {}, warnings = {}, generation = 0,
			selected = if type(saved.selected) == "string" then saved.selected else nil,
			section = if saved.section == "repositories" then "repositories" else "agents", loading = false }
	end,
	save = function(state)
		local repositories = state.repositories
		return { selected = repositories.selected, section = repositories.section }
	end,
	enter = function(state, cx)
		local root, problem = shared_root()
		if problem then state.repositories.error = problem; return end
		if root ~= state.repositories.configured_root then set_root(state.repositories, root) end
		scan(state.repositories, cx)
		if state.repositories.editor then cx:frame({ { "focus", INPUT } }) end
	end,
	capture_key = function(state, key, cx)
		return if state.repositories.editor then edit_key(state.repositories, key, cx) else false
	end,
	view = view, layer = layer, key = key, event = event,
}
