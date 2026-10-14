local definition, route, tick, focused, opened, notice
local warnings, events = {}, {}
local now = 1000
local function node(kind, props, children) return { k = kind, p = props or {}, c = children } end
local tern = {
	now = function() return now end,
	on = function(name, handler) events[name] = handler end,
	ui = {
		node = node,
		span = function(value, tone) return { t = value, s = tone } end,
		text = function(value) return node("text", { text = value }) end,
		badge = function(value, tone) return node("badge", { text = value, tone = tone }) end,
		md = function(value) return node("md", { text = value }) end,
	},
	json = { array = function(value) return value end },
	block = { define = function(_, value) definition = value end },
	route = { link = function(value) route = value end },
	timer = function(_, callback) tick = callback end,
	log = { warn = function(...) table.insert(warnings, {...}) end, debug = function() end },
}
local tracking = (function()
-- TRACKING_SOURCE
end)()
local require = function() return tracking end
do
-- HOST_SOURCE
end
do
-- WINDOW_SOURCE
end

local block = { pane = 100, kind = "plugin", block = "tern-software-factory.agents", tab = 10 }
local localAgent = { pane = 200, title = "Investigate a failure", tab = 20 }
local idleAgent = { pane = 300, title = "", tab = 10 }
local remoteAgent = { pane = 400, title = "Remote task", tab = 30 }
local exitedAgent = { pane = 500, title = "Finished", tab = 20 }
local shell = { pane = 600, kind = "terminal", program = "codex", title = "Shell agent", tab = 10 }
local panes = { block, localAgent, idleAgent, remoteAgent, exitedAgent, shell }
local agents = {
	{ pane = 400, state = "working", cwd = "/remote" },
	{ pane = 300, state = "idle", cwd = "/code/website", command = "omp" },
	{ pane = 500, state = "exited", cwd = "/code" },
	{ pane = 200, state = "waiting_input", cwd = "/code/backend", model = "Test model", delivery_error = "Prompt could not be sent" },
}
local blockCx = { pane = 100, rows = 30, open = function(_, url) opened = url end }
local state = definition.init(blockCx)
local cx = {
	session = {
		panes = function() return panes end,
		pane = function(_, id)
			for _, pane in panes do if pane.pane == id then return pane end end
		end,
		tabs = function() return { { id = 10, session = 1 }, { id = 20, session = 2 }, { id = 30, session = 3 } } end,
		event = function(_, pane, event)
			assert(pane == 100)
			definition.event(state, event, blockCx)
		end,
	},
	sessions = { list = function() return { { id = 1, name = "Main" }, { id = 2, name = "Backend" }, { id = 3, name = "Remote" } } end },
	hosts = { list = function() return { { id = 1, panes = { 100, 200, 300, 500, 600 } }, { id = 2, panes = { 400 } } } end },
	agents = {
		list = function() return agents end,
		transcript = function(_, pane, opts)
			assert(pane == 200 and opts.last == 32, "Only read the selected agent with a bounded history")
			return {
				{role = "user", text = "Fix the failure"},
				{role = "assistant", text = "Fixed the parser.", tools = {
					{name = "edit", title = "Edit", status = "done", target = "parser.luau"},
					{name = "bash", title = "Run tests", status = "running"},
				}},
			}
		end,
	},
	layout = { focus = function(_, pane) focused = pane end },
	toast = function(_, _, message) notice = message end,
}
local function key(name) definition.key(state, { name = name }, blockCx) end
local function open_route() route({ pane = 100, url = opened }, cx) end

assert(not state.loaded)
assert(definition.key(state, { name = "enter" }, blockCx) == false)
tick(cx)
assert(#warnings == 0)
assert(#state.agents == 2, "Include all sessions on this host, excluding remote and exited agents")
assert(state.agents[1].session == "Backend" and state.agents[2].session == "Main")
assert(state.agents[2].title == "omp", "Untitled panes need a useful fallback")
assert(state.selected == 200)
key("enter"); open_route()
assert(focused == 200, "Enter must route to the selected pane, even in another session")
key("down")
assert(state.selected == 300)
agents[2].state = "working"
localAgent.title = "\u{f418} Renamed task"
tick(cx)
assert(state.selected == 300, "Refreshing status or titles must preserve selection")
local view = definition.view(state, blockCx)
assert(#view.main.c[3].c[2].c == 2 and view.main.c[3].c[2].p.selected == "main.directory.agents.p300")
assert(view.main.c[3].c[2].c[1].p.tone == "error", "Prompt delivery failures need an attention indicator")
assert(view.main.c[3].c[2].c[1].p.label[3].t == "Test model", "Show the model in the row")
assert(view.main.c[3].c[2].c[1].p.label[2].t == "Renamed task", "Icon glyphs must not split the agent session cell")
definition.event(state, { ev = "select", id = "main.directory.agents", item = "main.directory.agents.p200" }, blockCx)
assert(state.selected == 200)
definition.event(state, { ev = "activate", id = "main.directory.agents", item = "main.directory.agents.p300" }, blockCx)
open_route()
assert(focused == 300, "Double-click must open the clicked agent")
agents[2].state = "exited"
focused = nil
key("enter"); open_route()
assert(focused == nil and notice, "An exited selection must never focus a stale pane")
assert(#state.agents == 1 and state.selected == 200)
assert(route({ pane = 100, url = "https://example.com" }, cx) == nil)
route({ pane = 100, url = "tern-software-factory://pane/400" }, cx)
assert(focused == nil, "Navigation must stay on the block's host")
route({ pane = 200, url = "tern-software-factory://pane/300" }, cx)
assert(focused == nil, "Other panes cannot invoke this block's route")
agents = {}
tick(cx)
assert(state.loaded and #state.agents == 0 and state.selected == nil)
assert(definition.key(state, { name = "down" }, blockCx) == false)
definition.view(state, blockCx)

-- Native omp activity, completion events and null metadata.
agents = {{ pane = 200, state = "working", cwd = "/code/backend", model = "Test model" }}
agents[1].last_message = "**Fixed** `parser_case`.\nTests passing."
tick(cx)
open_route()
assert(state.agents[1].preview == "Fixed parser_case. Tests passing.")
assert(state.details.request == "Fix the failure")
assert(state.details.response == "Fixed the parser.")
assert(state.agents[1].model == "Test model")
definition.view(state, blockCx)
local old = state.details
-- A delayed reply for a previous selection must not overwrite its new detail.
definition.event(state, { ev = "action", act = "factory_details", details = {pane = 999} }, blockCx)
assert(state.details == old)
events.agent_finished({pane = 200, result = "failed"}, cx)
now = 6000
tick(cx); open_route()
assert(state.details.last_turn == "failed" and state.details.finished_seconds == 5)
assert(state.agents[1].last_turn == "failed" and state.agents[1].finished_seconds == 5)
agents[1].state = "idle"
tick(cx)
view = definition.view(state, blockCx)
assert(view.main.c[3].c[2].c[1].p.tone == "error", "Failed turns must stand out in the row")
agents[1].state = "working"
tick(cx)
view = definition.view(state, blockCx)
assert(view.main.c[3].c[2].c[1].p.tone == "accent", "A new working turn must use the working signal")
-- Repeated requests inside a second share one transcript read.
cx.agents.transcript = function() error("Not ready") end
open_route()
assert(not state.details.transcript_error)
now += 1000
tick(cx); open_route()
assert(state.details.transcript_error and #state.agents == 1, "A transcript error must not break discovery")
definition.view(state, blockCx)
local null = newproxy()
local bounded = tracking.read({agents = {transcript = function()
	return {{role = "assistant", text = string.rep("é", 4000)}}
end}}, {pane = 200, model = null, delivery_error = null}, nil)
assert(bounded.model == "" and utf8.len(bounded.response) ~= nil)
assert(#bounded.response <= 6003)
assert(tracking.preview(null) == "" and tracking.preview(" \n\t ") == "")
assert(utf8.len(tracking.preview(string.rep("é", 1000))) ~= nil)
assert(#tracking.preview(string.rep("x", 10000)) <= 243)
local fallback = tracking.read({agents = {transcript = function() return {} end}}, {pane = 200, last_message = "Pane output"}, nil)
assert(fallback.response == "Pane output" and fallback.response_source == "pane" and not fallback.has_transcript)
-- An omp pane discovered through the native API is accepted without a command.
localAgent.kind = "agent"
agents[1].command = null
tick(cx)
assert(#state.agents == 1 and state.agents[1].pane == 200, "Native discovery includes omp launched in a shell")
route({pane = 100, url = "tern-software-factory://pane/600"}, cx)
assert(focused == nil, "Ordinary shell agents must not be included or navigable")
assert(route({url = "tern-software-factory://inspect/200"}, cx).handled)
cx.agents.transcript = function() return {} end

-- Large lists retain every row and use stable, exact ids above 32 bits.
agents, panes = {}, { block }
local localPanes = { 100 }
for i = 1, 250 do
	local id = 8589934592 + i
	table.insert(agents, { pane = id, state = "idle", cwd = "/code/project" })
	table.insert(panes, { pane = id, title = "Agent " .. i, tab = 10 })
	table.insert(localPanes, id)
end
cx.hosts.list = function() return { { id = 1, kind = "local", panes = localPanes } } end
tick(cx)
key("end")
view = definition.view(state, blockCx)
assert(#view.main.c[3].c[2].c == 250 and view.main.c[3].c[2].p.selected == "main.directory.agents.p8589934842")
key("enter"); open_route()
assert(focused == 8589934842)
key("home"); key("page_down")
assert(state.selected == 8589934603)
cx.agents.list = function() error("Host disconnected") end
local callback = tick
tick = nil
callback(cx)
assert(tick ~= nil and #warnings == 1, "A failed refresh must still schedule its successor")
print("PASS: native discovery, host scope, cross-session navigation, selection, exits, empty and 250 agents")
print("PASS: omp activity, completion, cache, null metadata, bounded Unicode text and stale detail replies")
