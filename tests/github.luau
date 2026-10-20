-- Execute the real controller and page against a deterministic host boundary.
local jobs, requests, responses, store, renders, opened = {}, {}, {}, {}, {}, {}
local fail_start, fail_root, local_uv = false, false, true
local function node(kind, props, children) return { k = kind, p = props or {}, c = children or {} } end
local tern = {
	plugin = { dir = "/plugin" },
	getenv = function() return "/Users/test" end,
	fs = { exists = function() return local_uv end },
	kv = { get = function(key)
		assert(key == "repositories:root", "GitHub must use the existing host-wide root only")
		if fail_root then error("storage unavailable") end
		return store[key]
	end },
	json = {
		encode = function(value) table.insert(requests, value); return tostring(#requests) end,
		decode = function(value) return assert(responses[value], "invalid JSON") end,
	},
	process = { run = function(argv, opts, done)
		if fail_start then error("private process diagnostic") end
		table.insert(jobs, { argv = argv, opts = opts, request = requests[tonumber(opts.stdin)], done = done })
	end },
	ui = {
		node = node,
		span = function(text, tone) return { t = text, s = tone } end,
		text = function(text) return node("text", { text = text }) end,
		badge = function(text, tone) return node("badge", { text = text, tone = tone }) end,
	},
}
local function make_controller()
	return (function()
-- GITHUB_CONTROLLER_SOURCE
	end)()
end
local controller = make_controller()
local page = (function()
	local require = function() return controller end
-- GITHUB_PAGE_SOURCE
end)()
local function context(pane)
	return { pane = pane, render = function() renders[pane] = (renders[pane] or 0) + 1 end,
		open = function(_, url) table.insert(opened, url) end }
end
local one, two = context(1), context(2)
local function finish(index, answer)
	local token = tostring(index) .. ":" .. tostring(#responses)
	responses[token] = answer
	jobs[index].done({ status = 0, stdout = token, stderr = "", timed_out = false })
end
local function fixture()
	return {
		{ id = "owner/alpha", name = "owner/alpha", url = "https://github.com/owner/alpha", path = "/code/项目 alpha", prs = {
			{ number = 12, title = "Improve parser", author = "alice", draft = true, head = "feature/parser", base = "main",
				updated_at = "2026-10-19T12:00:00Z", url = "https://github.com/owner/alpha/pull/12" },
			{ number = 4, title = "Fix tests", author = "bob", draft = false, head = "tests", base = "main",
				updated_at = "2026-10-18T12:00:00Z", url = "https://github.com/owner/alpha/pull/4" },
		} },
		{ id = "owner/empty", name = "owner/empty", url = "https://github.com/owner/empty", path = "/code/empty", prs = {} },
	}
end
local function answer(repos, root) return { ok = true, root = root or "/Users/test/Code", repos = repos or fixture(), warnings = {} } end
local function role(tree, name)
	if tree.p.role == name then return tree end
	for _, child in tree.c do
		local found = role(child, name)
		if found then return found end
	end
end
local state = { github = page.init({ selected = "missing", root = "/ignored" }) }
assert(#jobs == 0 and #controller.get().repos == 0)
page.enter(state, one)
assert(#jobs == 0 and controller.get().root == "", "Missing root never starts a worker")
assert(role(page.view(state).main, "factory-github-root").p.text[1].t:find("Agents", 1, true))
assert(not page.key(state, { name = "enter" }, one))
store["repositories:root"] = "~/Code"
page.enter(state, one)
page.enter(state, two)
assert(#jobs == 1 and jobs[1].request.root == "~/Code", "Panes share a single initial request")
assert(jobs[1].argv[1] == "/Users/test/.local/bin/uv" and jobs[1].argv[4] == "/plugin/github/worker.py")
assert(jobs[1].opts.timeout_ms == 120000)
controller.refresh()
controller.refresh()
assert(#jobs == 1, "Refresh cannot overlap or duplicate an active request")
finish(1, answer())
assert(controller.get().root == "/Users/test/Code" and controller.get().loaded and not controller.get().loading)
page.enter(state, two)
assert(#jobs == 1, "Canonical worker root must not invalidate the configured ~/ root on re-entry")
assert(role(page.view(state).main, "factory-github-actions").c[3].p.actions.click == "github-refresh")
assert(renders[1] > 0 and renders[2] > 0)
local tree = role(page.view(state).main, "factory-github-tree")
assert(#tree.c == 4 and tree.p.max == 1)
assert(tree.c[1].p.role == "factory-github-repository" and tree.c[2].p.role == "factory-github-pr")
assert(tree.c[3].p.role == "factory-github-pr" and tree.c[4].p.role == "factory-github-repository")
assert(tree.c[2].p.label[1].t == "↳ #12" and tree.c[2].p.label[2].t == "Improve parser")
assert(tree.c[2].p.label[3].t:find("@alice · Draft · feature/parser → main", 1, true))
assert(tree.c[4].p.label[2].t == "No open PRs")
assert(tree.c[2].p.title:find("2026-10-19T12:00:00Z", 1, true))
assert(tree.p.selected == "main.github.tree." .. tree.c[1].p.key)
page.key(state, { name = "enter" }, one)
assert(opened[#opened] == "https://github.com/owner/alpha")
page.key(state, { name = "j" }, one)
page.key(state, { name = "o" }, one)
assert(opened[#opened] == "https://github.com/owner/alpha/pull/12")
page.key(state, { name = "end" }, one)
assert(state.github.selected == tree.c[4].p.key)
page.key(state, { name = "page_up" }, one)
assert(state.github.selected == tree.c[1].p.key)
page.key(state, { name = "page_down" }, one)
assert(state.github.selected == tree.c[4].p.key)
page.key(state, { name = "k" }, one)
assert(state.github.selected == tree.c[3].p.key)
page.key(state, { name = "home" }, one)
assert(not page.key(state, { name = "left" }, one) and not page.key(state, { name = "right" }, one))
local before_open = #opened
page.event(state, { ev = "select", id = "main.github.tree", item = "main.github.tree." .. tree.c[3].p.key }, one)
assert(#opened == before_open and state.github.selected == tree.c[3].p.key, "A click selects without opening")
page.event(state, { ev = "activate", id = "main.github.tree", item = "main.github.tree." .. tree.c[3].p.key }, one)
assert(opened[#opened] == "https://github.com/owner/alpha/pull/4")
local saved = page.save(state)
assert(saved.selected == state.github.selected and saved.root == nil and saved.repos == nil)
assert(page.init(saved).selected == saved.selected)
local independent = { github = page.init() }
page.view(independent)
assert(independent.github.selected ~= state.github.selected, "Panes share records but keep independent selection")

page.event(state, { ev = "action", act = "github-refresh" }, one)
local partial = fixture()
partial[1].prs, partial[1].error = {}, "Rate limit exceeded. Try later."
partial[2].prs = { table.clone(fixture()[1].prs[1]) }
partial[2].prs[1].url = "https://github.com/owner/empty/pull/12"
finish(2, answer(partial))
assert(#controller.get().repos[1].prs == 2 and controller.get().repos[1].stale)
assert(#controller.get().repos[2].prs == 1, "One repo failure must not discard other repositories' loaded PRs")
tree = role(page.view(state).main, "factory-github-tree")
assert(tree.c[1].p.tone == "error" and tree.c[1].p.label[2].t:find("Rate limit", 1, true))
assert(tree.c[1].p.label[2].t:find("last loaded", 1, true))
local retained = controller.get().repos
page.key(state, { name = "r" }, one)
finish(3, { ok = false, setup = true, error = "Run gh auth login on this host.", repos = {} })
assert(controller.get().repos == retained and controller.get().setup)
assert(role(page.view(state).main, "factory-github-error").p.text[1].t:find("gh auth login", 1, true))
controller.refresh()
finish(4, answer())
assert(not controller.get().error and not controller.get().setup and not controller.get().repos[1].stale)

controller.refresh()
store["repositories:root"] = "/different root/项目"
page.enter(state, two)
assert(#controller.get().repos == 0 and not controller.get().loaded, "Changing root clears old rows immediately")
assert(#role(page.view(state).main, "factory-github-tree").c == 0)
assert(#jobs == 5, "A new root waits for the current process to finish")
finish(5, answer())
assert(#jobs == 6 and jobs[6].request.root == "/different root/项目")
assert(#controller.get().repos == 0 and controller.get().loading, "Stale completion cannot resurrect the previous root")
finish(6, answer({}, "/different root/项目"))
assert(controller.get().loaded and #controller.get().repos == 0)
controller.refresh()
store["repositories:root"] = ""
controller.refresh()
assert(controller.get().root == "" and #controller.get().repos == 0)
finish(7, answer())
assert(#jobs == 7 and #controller.get().repos == 0 and not controller.get().loading, "Clearing root also invalidates in-flight results")

store["repositories:root"] = "/code"
controller.refresh()
local unsafe = fixture()
unsafe[1].url = "https://github.com.evil.test/owner/alpha"
unsafe[1].prs[1].url = "javascript:alert(1)"
finish(8, answer(unsafe, "/code"))
page.key(state, { name = "home" }, one)
before_open = #opened
page.key(state, { name = "enter" }, one)
page.key(state, { name = "down" }, one)
page.key(state, { name = "enter" }, one)
assert(#opened == before_open, "Neither repository nor PR actions open untrusted URLs")
controller.refresh()
controller.detach(1)
local before_render = renders[1]
controller.attach({ pane = 3, render = function() error("closed renderer") end })
finish(9, answer())
assert(renders[1] == before_render, "Closed blocks receive no completion render")
controller.detach(2)
controller.detach(3)
controller.refresh()
assert(#jobs == 9, "No subscribers means no worker")
controller.attach(two)
assert(#jobs == 10, "An explicit refresh queued with no panes starts on reattach")
jobs[10].done({ status = 1, stderr = "private process diagnostic" })
assert(controller.get().error and not controller.get().error:find("private process", 1, true))
controller.refresh()
jobs[11].done({ status = 0, stdout = "invalid" })
assert(controller.get().error:find("invalid JSON", 1, true))
controller.refresh()
jobs[12].done({ status = 0, timed_out = true })
assert(controller.get().error:find("timed out", 1, true))
local job_count = #jobs
jobs[12].done({ status = 0, stdout = "invalid" })
assert(#jobs == job_count and controller.get().error:find("timed out", 1, true), "Duplicate callbacks have no effect")

local_uv = false
local fallback = make_controller()
fallback.attach(one)
assert(jobs[#jobs].argv[1] == "uv", "PATH is the fallback when ~/.local/bin/uv is absent")
finish(#jobs, answer())
fail_start = true
local unavailable = make_controller()
unavailable.attach(one)
assert(not unavailable.get().loading and unavailable.get().error:find("Install uv", 1, true))
assert(not unavailable.get().error:find("private", 1, true))
fail_start = false
fail_root = true
local unreadable = make_controller()
job_count = #jobs
unreadable.attach(one)
assert(#jobs == job_count and unreadable.get().error:find("saved repository root", 1, true))
print("github: controller lifecycle, root generations, retained data, safe actions, and nested rows passed")
