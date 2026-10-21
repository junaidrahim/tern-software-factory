-- Execute the real controller/section; fake only Tern's process, clock, and native UI boundary.
local now, jobs, requests, answers = 0, {}, {}, {}
local rendered = { [1] = 0, [2] = 0 }
local fail_start, local_uv = false, true
local function node(kind, props, children)
	return { k = kind, p = props or {}, c = children }
end
local tern = {
	plugin = { dir = "/plugin" },
	now = function() return now end,
	getenv = function(name) return if name == "HOME" then "/host/home" else nil end,
	fs = { exists = function(path) return local_uv and path == "/host/home/.local/bin/uv" end },
	json = {
		null = newproxy(),
		encode = function(value) table.insert(requests, value); return tostring(#requests) end,
		decode = function(value) return assert(answers[value], "invalid JSON") end,
	},
	process = { run = function(argv, opts, done)
		if fail_start then error("uv not found") end
		table.insert(jobs, { argv = argv, opts = opts, request = requests[tonumber(opts.stdin)], done = done })
	end },
	ui = {
		node = function(kind, props, children)
			assert(kind ~= "text", "Native text must go through ui.text")
			return node(kind, props, children)
		end,
		span = function(value, tone) return { t = value, s = tone } end,
		text = function(value) return node("text", { text = value }) end,
		table = function(columns, rows) return node("table", { cols = columns, rows = rows }) end,
	},
}
local function make_controller()
	return (function()
-- OPS_CONTROLLER_SOURCE
	end)()
end
local controller = make_controller()
local function make_section()
	return (function()
	local require = function() return controller end
-- OPS_SECTION_SOURCE
	end)()
end
local section = make_section()
local one = { pane = 1, render = function() rendered[1] += 1 end }
local two = { pane = 2, render = function() rendered[2] += 1 end }
local null = tern.json.null
local snapshot = {
	generated_at = 1700000000,
	models = {
		{ model_key = "provider/fast", tokens_per_second = 22.543, ttft_ms = 1498.4,
			avg_output_tokens = 1024.4, effective_samples = 209.375, updated_at = 1699999999 },
		{ model_key = "provider/missing", tokens_per_second = null, ttft_ms = null,
			avg_output_tokens = null, effective_samples = null, updated_at = null },
		{ model_key = "provider/zero", tokens_per_second = 0, ttft_ms = 0,
			avg_output_tokens = 0, effective_samples = 0, updated_at = null },
	},
	commands = { { name = "review", count = 10, last_used_at = 1699999998 }, { name = "plan", count = 3, last_used_at = null } },
	summary = { measured_models = 2, effective_samples = null, command_uses = 21 }, warnings = {},
}
local function complete(index, answer)
	answers[tostring(index)] = answer or { ok = true, snapshot = snapshot }
	jobs[index].done({ status = 0, stdout = tostring(index), stderr = "", timed_out = false })
end
local function text(root)
	local parts = {}
	local function visit(n)
		if n.k == "text" then
			if type(n.p.text) == "string" then table.insert(parts, n.p.text)
			else for _, span in n.p.text do table.insert(parts, span.t) end end
		end
		for _, child in n.c or {} do visit(child) end
	end
	visit(root)
	return table.concat(parts, " ")
end
local function contains(root, value) return string.find(text(root), value, 1, true) ~= nil end
local function model_table(root)
	for _, child in root.c do if child.k == "table" then return child.p end end
	return nil
end

assert(#jobs == 0 and not controller.get().snapshot, "Import is lazy, not a fabricated zero snapshot")
controller.refresh(); controller.tick()
assert(#jobs == 0, "No subscribers means no workers, even for refresh")
controller.attach(one); controller.attach(two); controller.attach(one)
assert(#jobs == 1 and controller.get().loading, "Panes share the same initial in-flight read")
assert(jobs[1].argv[1] == "/host/home/.local/bin/uv" and jobs[1].argv[4] == "/plugin/ops/worker.py")
assert(jobs[1].opts.timeout_ms >= 15000 and jobs[1].opts.timeout_ms <= 30000)
assert(jobs[1].request.action == "snapshot" and next(jobs[1].request, "action") == nil,
	"The host worker receives no configurable database path or sensitive inputs")
assert(not model_table(section.section()) and contains(section.section(), "Reading"), "Loading is not an empty dataset")
controller.refresh(); controller.refresh(); controller.tick()
assert(#jobs == 1, "Refreshes serialize while the initial read is active")
complete(1)
assert(#jobs == 2 and controller.get().snapshot == snapshot and controller.get().loading,
	"Repeated manual refreshes coalesce into one subsequent read")
complete(2)
assert(#jobs == 2 and not controller.get().loading and rendered[1] > 0 and rendered[2] > 0)
local root = section.section()
local grid = model_table(root)
assert(grid.rows[1][2][1].t == "22.5" and grid.rows[1][3][1].t == "1.50 s"
	and grid.rows[1][4][1].t == "1024" and grid.rows[1][5][1].t == "209.4", "Rates preserve rolling precision and convert TTFT to seconds")
for i = 2, 5 do assert(grid.rows[2][i][1].t == "—", "JSON null is an unavailable measurement, not zero") end
assert(grid.rows[3][2][1].t == "0.0" and grid.rows[3][3][1].t == "0 ms" and grid.rows[3][4][1].t == "0",
	"Measured zero is distinct from missing data")
assert(grid.cols[4].priority < (grid.cols[2].priority or 0) and grid.cols[5].priority < (grid.cols[3].priority or 0),
	"Narrow tables drop output and sample columns before speed and latency")
assert(contains(root, "21") and contains(root, "review") and contains(root, "×10")
	and contains(root, "—"), "Summary uses the all-command total, not the top command list, and preserves null totals")
assert(contains(root, "Rolling performance") and not contains(root, "Recorded history"),
	"Older snapshots keep performance without inventing history")
snapshot.activity = {
	available = true, partial = false, sessions = 1234, subagents = 0, responses = 98765,
	tokens = { total = 1234567, input = 1000000, output = 234567, cache_read = null, cache_write = 0 },
	warnings = {},
}
root = section.section()
local history_node = root.c[2]
local history_metrics = history_node.c[3]
for index, expected in { "1,234", "0", "98,765", "1,234,567", "1,000,000", "234,567", "—", "0" } do
	assert(history_metrics.c[index].p.text[2].t == expected, "History uses grouped exact counts and distinguishes zero from null")
end
snapshot.activity.partial = true
snapshot.activity.warnings = { "Some responses have no recorded usage" }
snapshot.activity.tokens.input = null
root = section.section()
assert(contains(root, "Partial coverage") and contains(root, "Some responses have no recorded usage")
	and contains(root, "1,234,567") and model_table(root), "Partial history keeps useful counters and performance")
snapshot.activity.available = false
snapshot.activity.partial = false
snapshot.activity.warnings = { "Session history cannot be read" }
root = section.section()
assert(contains(root, "Recorded history unavailable") and contains(root, "Session history cannot be read")
	and not contains(root.c[2], "1,234") and model_table(root), "Unavailable history never presents zero or stale counters and preserves performance")
snapshot.activity.available = true
snapshot.activity.sessions = 0
snapshot.activity.subagents = 0
snapshot.activity.responses = 0
snapshot.activity.tokens = { total = 0, input = 0, output = 0, cache_read = 0, cache_write = 0 }
snapshot.activity.warnings = {}
root = section.section()
for _, item in root.c[2].c[3].c do
	assert(item.p.text[2].t == "0", "Truly empty retained history displays genuine zero")
end
snapshot.activity.sessions = -1
snapshot.activity.subagents = 1.5
snapshot.activity.responses = math.huge
snapshot.activity.tokens.total = 0 / 0
root = section.section()
for index = 1, 4 do
	assert(root.c[2].c[3].c[index].p.text[2].t == "—", "Invalid history counters are unavailable, not rounded or infinite")
end
local saved_summary, saved_models, saved_commands = snapshot.summary, snapshot.models, snapshot.commands
snapshot.summary, snapshot.models, snapshot.commands = null, null, null
snapshot.activity.sessions = 1234
root = section.section()
assert(contains(root, "1,234") and not model_table(root) and not contains(root, "No model performance"),
	"History remains usable when the database performance summary is unavailable")
snapshot.summary, snapshot.models, snapshot.commands = saved_summary, saved_models, saved_commands
snapshot.activity = nil
now = 59999; controller.tick()
assert(#jobs == 2, "No early minute refresh")
now = 60000; controller.tick(); controller.tick()
assert(#jobs == 3, "The host poll starts exactly one minute refresh")
complete(3, { ok = false, error = "Database busy" })
assert(controller.get().snapshot == snapshot and contains(section.section(), "Stale snapshot")
	and contains(section.section(), "Database busy"), "Failures retain the last measured values with an explicit stale warning")
controller.refresh(); controller.refresh(); controller.refresh()
assert(#jobs == 4, "Manual retries remain serialized")
controller.detach(1)
local renders_before = rendered[1]
complete(4)
assert(#jobs == 5 and rendered[1] == renders_before and not controller.get().error,
	"Closed subscribers are not rendered and recovery clears the error")
controller.refresh()
controller.detach(2)
local two_before = rendered[2]
complete(5)
assert(#jobs == 5 and rendered[2] == two_before, "Detaching the final pane drops queued work even during an in-flight read")
now += 60000; controller.tick(); controller.refresh()
assert(#jobs == 5, "Detached hosts do not refresh")
controller.attach(one)
assert(#jobs == 6, "Reopening an expired cache refreshes immediately")
local_uv = false
complete(6)
controller.detach(1); controller.attach(one)
assert(#jobs == 6, "Reopening a fresh cache does not need another worker")
controller.refresh()
assert(jobs[7].argv[1] == "uv", "Hosts without local uv use PATH")
jobs[7].done({ status = 0, stdout = "not-json" })
assert(controller.get().snapshot == snapshot and contains(section.section(), "invalid JSON"))
controller.refresh()
complete(8, { ok = true, snapshot = null })
assert(controller.get().error and controller.get().snapshot == snapshot, "A null snapshot cannot overwrite valid data")
controller.refresh()
jobs[9].done({ status = 0, stdout = "", timed_out = true })
assert(contains(section.section(), "timed out") and not controller.get().loading)
controller.refresh()
jobs[10].done({ status = 2, stderr = "cannot open database" })
assert(contains(section.section(), "cannot open database"))
fail_start = true
controller.refresh()
assert(not controller.get().loading and contains(section.section(), "Install uv"), "Synchronous launch failures settle the request")
fail_start = false
controller.refresh(); complete(11)
assert(not controller.get().error and not contains(section.section(), "Stale snapshot"), "A later success clears stale errors")
now += 120000
assert(contains(section.section(), "Stale snapshot"), "An old snapshot is explicit even before the next host poll")

-- Missing database, truly empty database, and partial schemas are different states.
controller = make_controller()
section = make_section()
controller.attach(one)
complete(12, { ok = false, error = "Agent database not found", setup = true })
root = section.section()
assert(not model_table(root) and contains(root, "not found") and contains(root, "Run omp")
	and not contains(root, "No model performance"), "Setup is not disguised as an empty database")
controller.refresh()
local empty = { generated_at = 1700000001, models = {}, commands = {}, warnings = {},
	summary = { measured_models = 0, effective_samples = 0, command_uses = 0 } }
complete(13, { ok = true, snapshot = empty })
root = section.section()
assert(not controller.get().setup and not controller.get().error and not model_table(root)
	and contains(root, "No model performance") and contains(root, "No command usage"), "A genuine empty database has explicit empty states")
controller.refresh()
local partial = { generated_at = 1700000002, models = {}, commands = snapshot.commands,
	summary = { measured_models = null, effective_samples = null, command_uses = 21 }, warnings = { "model_perf is unavailable" } }
complete(14, { ok = true, snapshot = partial })
root = section.section()
assert(contains(root, "model_perf is unavailable") and contains(root, "review") and contains(root, "—")
	and not contains(root, "No model performance"), "Partial schema preserves available commands and marks model totals unavailable")
controller.refresh()
local invalid = { generated_at = 1700000003, models = {
	{ model_key = "invalid", tokens_per_second = math.huge, ttft_ms = -1, avg_output_tokens = 0 / 0, effective_samples = null },
	{ model_key = "fast", tokens_per_second = 0.15, ttft_ms = 25.4, avg_output_tokens = 1, effective_samples = 1 },
}, commands = {}, summary = { measured_models = 1, effective_samples = null, command_uses = null }, warnings = {} }
complete(15, { ok = true, snapshot = invalid })
grid = model_table(section.section())
for i = 2, 5 do assert(grid.rows[1][i][1].t == "—", "Invalid numeric measurements are never formatted as valid rates") end
assert(grid.rows[2][3][1].t == "25 ms", "Subsecond latency stays legible in milliseconds")
assert(section.key({}, { name = "enter" }) == false and section.key({}, { name = "r", meta = true }) == false,
	"Unrelated and modified keys remain unhandled")
local before = #jobs
section.event({}, { ev = "activate", act = "ops-refresh" })
assert(#jobs == before, "Only the refresh action triggers the button handler")
section.event({}, { ev = "action", act = "ops-refresh" })
assert(#jobs == before + 1)
complete(#jobs)
assert(section.key({}, { name = "r" }) and #jobs == before + 2, "Unmodified r refreshes ops")
print("PASS: Agent ops lazy shared lifecycle, serialized minute refresh, detach/reopen, errors and stale cache")
print("PASS: Agent ops measured values, null/zero/empty/partial schema, responsive priorities and refresh actions")
