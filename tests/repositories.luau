-- The repository root folder and scan, against deterministic worker replies.
local function node(kind, props, children)
	return { k = kind, p = if props and next(props) then props else nil, c = children }
end
local requests, opened, frames, decoded = {}, {}, {}, {}
local fail_start, fail_render, local_uv = false, false, true
local preferences, fail_read, fail_write = {}, false, false
local tern = {
	plugin = { dir = "/plugin" },
	getenv = function(name) return if name == "HOME" then "/host/home" else nil end,
	fs = { exists = function(path) return local_uv and path == "/host/home/.local/bin/uv" end },
	kv = {
		get = function(key) if fail_read then error("Storage unavailable") end; return preferences[key] end,
		set = function(key, value) if fail_write then error("Storage unavailable") end; preferences[key] = value end,
	},
	json = { null = {}, encode = function(value) return value.root end,
		decode = function(value) return assert(decoded[value], "Invalid JSON") end },
	ui = { node = node, text = function(text) return node("text", { text = text }) end,
		span = function(text, tone) return { t = text, s = tone } end,
		badge = function(text, tone) return node("badge", { text = text, tone = tone }) end },
	process = { run = function(argv, options, callback)
		if fail_start then error("Cannot spawn") end
		table.insert(requests, { argv = argv, options = options, done = callback })
	end },
}
local section = (function()
-- REPOSITORIES_SECTION_SOURCE
end)()
local cx = { pane = 2^44 + 42, open = function(_, url) table.insert(opened, url) end,
	frame = function(_, frame) table.insert(frames, frame) end,
	render = function() if fail_render then error("Pane closed") end end }
local function state(saved) return { repositories = section.init(saved) } end
local function action(state, act) return section.event(state, { ev = "action", act = act }, cx) end
local function edit(state, name, extra)
	local event = extra or {}
	event.name = name
	assert(section.capture_key(state, event, cx))
end
local function root(state, value)
	action(state, "repositories-root")
	edit(state, "a", { meta = true })
	edit(state, "paste", { text = value })
	edit(state, "enter")
end
local function reply(index, value)
	local token = "reply:" .. index
	decoded[token] = value
	requests[index].done({ status = 0, stdout = token })
end
local function repository(path, worktrees)
	return { path = path, name = path:match("([^/]+)$"), worktrees = worktrees or {} }
end
local function worktree(path, missing)
	return { path = path, branch = "feature/test", detached = false, locked = false, missing = missing or false }
end
local function find(root, role)
	if root.p and root.p.role == role then return root end
	for _, child in root.c or {} do local found = find(child, role); if found then return found end end
end
local s = state(nil)
section.enter(s, cx)
assert(#requests == 0 and s.repositories.root == "", "Unset roots never scan HOME")
assert(not section.capture_key(s, { name = "left" }, cx), "Page arrows remain available outside the modal")
local buttons = section.buttons(s)
assert(buttons[1].p.actions.click == "repositories-root" and buttons[2].p.disabled, "Refresh waits for a root folder")

-- Native input caret and selection use UTF-16 while edits preserve UTF-8.
action(s, "repositories-root")
assert(frames[#frames][1][2] == "layer.repository-root.body.root")
edit(s, "paste", { text = "Aé😀" })
local input = find(section.layer(s), "factory-repositories-root-input")
assert(input.p.text == "Aé😀" and input.p.cursor == 4)
edit(s, "left", { shift = true })
input = find(section.layer(s), "factory-repositories-root-input")
assert(input.p.cursor == 2 and input.p.anchor == 4)
edit(s, "delete")
assert(s.repositories.editor.text == "Aé")
edit(s, "home")
edit(s, "delete")
assert(s.repositories.editor.text == "é")
edit(s, "end")
edit(s, "backspace")
assert(s.repositories.editor.text == "")
edit(s, "paste", { text = "~/Code" })
section.event(s, { ev = "edit", id = "layer.repository-root.body.root", text = "untrusted native edit" }, cx)
assert(s.repositories.editor.text == "~/Code", "Raw native edit events cannot mutate the input")
edit(s, "escape")
assert(s.repositories.editor == nil and s.repositories.root == "" and #requests == 0, "Cancel discards edits")
root(s, "~/Code")
assert(s.repositories.root == "~/Code" and s.repositories.loading and #requests == 1)
assert(requests[1].argv[1] == "/host/home/.local/bin/uv" and requests[1].argv[4] == "/plugin/repositories/worker.py")
assert(requests[1].options.timeout_ms == 120000 and requests[1].options.stdin == "~/Code")
action(s, "repositories-refresh")
section.enter(s, cx)
assert(#requests == 1, "Repeated enter and refresh do not duplicate an active scan")
local special = "/host/Code/My repo%#é😀"
local linked = "/outside/work tree"
local missing = "/outside/gone"
reply(1, { ok = true, root = "/host/Code", repos = { repository(special, { worktree(linked), worktree(missing, true) }) }, warnings = { "Skipped unreadable folder" } })
assert(not s.repositories.loading and s.repositories.root == "/host/Code" and s.repositories.repos[1].path == special)
assert(#s.repositories.repos[1].worktrees == 2 and s.repositories.warnings[1] == "Skipped unreadable folder")
assert(not section.event(s, { ev = "select", id = "main.tree.rows", item = "x" }, cx), "Other events pass through")
print("PASS: Repository setup, native editing and scanning")

-- A root change clears previous data immediately and queues behind the active process.
action(s, "repositories-refresh")
local old_job = #requests
root(s, "/new")
assert(#s.repositories.repos == 0 and s.repositories.loading)
root(s, "/newest")
assert(#requests == old_job, "Root changes coalesce behind the single in-flight process")
reply(old_job, { ok = true, root = "/host/Code", repos = { repository("/old/stale") } })
assert(#requests == old_job + 1 and requests[#requests].options.stdin == "/newest")
assert(s.repositories.root == "/newest" and #s.repositories.repos == 0, "Old root completion cannot restore stale data")
requests[old_job].done({ status = 1 })
assert(s.repositories.loading, "Duplicate old callbacks cannot settle the replacement scan")
reply(#requests, { ok = true, root = "/newest", repos = { repository("/newest/repo") } })
assert(s.repositories.repos[1].path == "/newest/repo")
action(s, "repositories-refresh")
reply(#requests, { ok = false, root = "/newest", repos = {}, error = "Permission denied" })
assert(#s.repositories.repos == 1 and s.repositories.error == "Permission denied", "Same-root failures retain last good data")
action(s, "repositories-refresh")
requests[#requests].done({ status = 0, stdout = "invalid" })
assert(not s.repositories.loading and s.repositories.error:find("invalid JSON", 1, true) and #s.repositories.repos == 1)
action(s, "repositories-refresh")
reply(#requests, { ok = true, root = "/newest", repos = { { path = 3 } } })
assert(not s.repositories.loading and #s.repositories.repos == 1 and s.repositories.error:find("invalid repository", 1, true))
action(s, "repositories-refresh")
requests[#requests].done({ status = 1, timed_out = true })
assert(s.repositories.error:find("timed out", 1, true) and #s.repositories.repos == 1)
action(s, "repositories-refresh")
fail_render = true
reply(#requests, { ok = true, root = "/newest", repos = {} })
fail_render = false
assert(not s.repositories.loading and #s.repositories.repos == 0 and s.repositories.error == nil,
	"Closed-pane render exceptions cannot strand the callback")
local_uv, fail_start = false, true
action(s, "repositories-refresh")
assert(not s.repositories.loading and s.repositories.error:find("Cannot start", 1, true))
fail_start = false
action(s, "repositories-refresh")
assert(requests[#requests].argv[1] == "uv", "PATH uv is used when host-local uv is absent")
local clearing_job = #requests
root(s, "")
assert(s.repositories.root == "" and not s.repositories.loading and #s.repositories.repos == 0)
reply(clearing_job, { ok = true, root = "/newest", repos = { repository("/newest/old") } })
assert(#requests == clearing_job and #s.repositories.repos == 0 and s.repositories.root == "", "Clearing during scan neither restores results nor starts another worker")
root(s, "/bad-root")
reply(#requests, { ok = false, root = "/bad-root", repos = {}, error = "Not a directory" })
assert(s.repositories.error == "Not a directory" and #s.repositories.repos == 0)
print("PASS: Repository scan serialization, stale callbacks, failures, clearing and empty states")

-- A host preference outlives individual block state, including explicit clearing.
local fresh = state(nil)
assert(fresh.repositories.root == "/bad-root", "New blocks inherit the last saved root")
root(fresh, "")
assert(state(nil).repositories.root == "")
assert(state({ root = "/obsolete" }).repositories.root == "",
	"An explicitly cleared shared root cannot be resurrected by an old block")
preferences = {}
local migrated = state({ root = "/existing/root" })
assert(migrated.repositories.root == "/existing/root" and state(nil).repositories.root == "/existing/root",
	"A legacy block migrates its root so newly created blocks inherit it")
assert(state({ root = "/another/legacy-root" }).repositories.root == "/existing/root",
	"Other old blocks cannot overwrite the chosen host preference")
local peer = state(nil)
root(migrated, "/replacement")
section.enter(peer, cx)
assert(peer.repositories.root == "/replacement", "Existing blocks adopt the shared root on page entry")
local before_failure = #requests
fail_write = true
root(peer, "/not-saved")
assert(peer.repositories.root == "/replacement" and peer.repositories.editor.error and #requests == before_failure)
assert(state(nil).repositories.root == "/replacement", "A failed save cannot change what new blocks inherit")
fail_write = false
edit(peer, "escape")
fail_read = true
local unreadable = state({ root = "/stale" })
assert(unreadable.repositories.error and unreadable.repositories.root == "",
	"A storage read failure must not overwrite the persisted preference with legacy state")
fail_read = false
assert(state(nil).repositories.root == "/replacement")
print("PASS: repository roots persist across blocks, migrate once, clear explicitly, and survive storage failures")
