--!nonstrict
-- The repository root folder (saved per host) and the scan of its repositories
-- and worktrees. The Agents page shows the result as its repository tree.
local ui = tern.ui
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
		repositories.root, repositories.repos, repositories.warnings = root, {}, {}
		repositories.generation += 1
		repositories.error, repositories.loading = nil, root ~= ""
	end
	repositories.configured_root = root
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

local function button(key, label, action, disabled)
	return ui.node("el", { key = key, tag = "button", role = "factory-repositories-button", aria = label,
		disabled = disabled, actions = { click = action } }, { ui.text(label) })
end

-- The root folder dialog, while it is open.
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

-- Root folder and Refresh buttons; `repositories-root` and `repositories-refresh`
-- actions reach `event`.
local function buttons(state)
	local repositories = state.repositories
	return {
		button("root-folder", "Root folder", "repositories-root"),
		button("refresh", "Refresh", "repositories-refresh", repositories.loading or repositories.root == ""),
	}
end

-- Handles the dialog's and the buttons' actions; true when it took the event.
local function event(state, event, cx)
	local repositories = state.repositories
	if repositories.editor then
		if event.ev == "action" and event.act == "repositories-root-save" then save_root(repositories, cx)
		elseif event.ev == "action" and event.act == "repositories-root-cancel" then close(repositories, cx) end
		return true
	end
	if event.ev == "action" and event.act == "repositories-root" then open_editor(repositories, cx); return true end
	if event.ev == "action" and event.act == "repositories-refresh" then scan(repositories, cx); return true end
	return false
end

return {
	init = function(saved)
		local root, problem = shared_root(saved)
		return { root = root or "", configured_root = root or "", error = problem, repos = {}, warnings = {}, generation = 0, loading = false }
	end,
	-- Picks up a root saved by another block, then rescans.
	enter = function(state, cx)
		local root, problem = shared_root()
		if problem then state.repositories.error = problem; return end
		if root ~= state.repositories.configured_root then set_root(state.repositories, root) end
		scan(state.repositories, cx)
		if state.repositories.editor then cx:frame({ { "focus", INPUT } }) end
	end,
	scan = function(state, cx) scan(state.repositories, cx) end,
	capture_key = function(state, key, cx)
		return if state.repositories.editor then edit_key(state.repositories, key, cx) else false
	end,
	layer = layer, buttons = buttons, event = event,
}
