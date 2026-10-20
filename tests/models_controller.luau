-- Deterministic execution of the real shared controller, with only its host boundary faked.
local now, jobs, payloads, responses = 0, {}, {}, {}
local encoded_requests = {}
local rendered = { [1] = 0, [2] = 0 }
local fail_start = false
local tern = {
	plugin = { dir = "/plugin", data = "/data" },
	now = function() return now end,
	getenv = function() return nil end,
	fs = { exists = function() return false end },
	json = {
		encode = function(value)
			table.insert(encoded_requests, value)
			table.insert(payloads, table.clone(value))
			return tostring(#payloads)
		end,
		decode = function(value) return assert(responses[value]) end,
	},
	process = { run = function(argv, opts, callback)
		if fail_start then error("private-credential-from-host") end
		table.insert(jobs, { argv = argv, request = payloads[tonumber(opts.stdin)], done = callback })
	end },
}
local function make_controller()
	return (function()
-- MODELS_CONTROLLER_SOURCE
	end)()
end
local controller = make_controller()
local one = { pane = 1, render = function() rendered[1] += 1 end }
local two = { pane = 2, render = function() rendered[2] += 1 end }
local old = { models = { { id = "cached" } }, fetched_at = 1000, index_version = "4.1" }
local newer = { models = { { id = "fresh" } }, fetched_at = 2000, index_version = "4.1" }
local function complete(index, answer)
	local token = tostring(index)
	responses[token] = answer or { ok = true, snapshot = newer, setup = false, refresh_after_seconds = 21600 }
	jobs[index].done({ status = 0, stdout = token, stderr = "", timed_out = false })
end
assert(#jobs == 0 and #controller.get().snapshot.models == 0, "Import is lazy and has an honest empty snapshot")
assert(controller.get().key_path == "/data/artificial-analysis-api-key")
controller.attach(one)
controller.attach(two)
assert(#jobs == 1 and jobs[1].request.action == "snapshot", "Panes share one initial cache read")
assert(jobs[1].request.cache == "/data/models/cache.json")
assert(jobs[1].request.key_path == controller.get().key_path)
assert(#jobs[1].argv == 4 and jobs[1].argv[4] == "/plugin/models/worker.py", "Credentials are never process arguments")
complete(1, { ok = true, snapshot = old, setup = false, refresh_after_seconds = 3600 })
assert(#jobs == 2 and jobs[2].request.action == "refresh" and not jobs[2].request.force)
assert(controller.get().snapshot == old and controller.get().loading)
controller.refresh()
controller.refresh()
assert(#jobs == 2, "Manual refreshes cannot overlap an automatic worker")
complete(2)
assert(#jobs == 3 and jobs[3].request.force, "Manual request upgrades to exactly one forced follow-on pass")
controller.refresh()
complete(3)
assert(#jobs == 3, "Repeated manual refresh during a forced pass is deduplicated")
assert(not controller.get().loading and not controller.get().error)
assert(rendered[1] > 0 and rendered[2] > 0, "Both panes receive completion renders")
controller.refresh()
complete(4, { ok = false, snapshot = newer, error = "API key rejected. Replace the key, then Refresh.", setup = true,
	refresh_after_seconds = 21600 })
assert(controller.get().snapshot == newer and controller.get().setup and controller.get().error)
controller.refresh()
complete(5)
assert(not controller.get().setup and not controller.get().error, "A corrected key clears setup state on Refresh")
controller.refresh()
jobs[6].done({ status = 1, stdout = "", stderr = "private-credential-from-host", timed_out = false })
assert(controller.get().snapshot == newer and controller.get().error)
assert(not string.find(controller.get().error, "private-credential", 1, true), "Process stderr never reaches UI state")
controller.refresh()
jobs[7].done({ status = 0, stdout = "invalid-json", stderr = "", timed_out = false })
assert(controller.get().snapshot == newer and controller.get().error == "Models worker returned invalid JSON.")
controller.refresh()
complete(8, { ok = true, snapshot = newer, setup = false, refresh_after_seconds = 600 })
now = 599999
controller.tick()
assert(#jobs == 8, "Fresh cached snapshots set the remaining refresh delay")
now = 600000
controller.tick()
assert(#jobs == 9 and not jobs[9].request.force)
controller.tick()
assert(#jobs == 9, "Ticks do not overlap workers")
controller.detach(1)
local one_renders = rendered[1]
complete(9)
assert(rendered[1] == one_renders, "Detached panes receive no render notifications")
controller.detach(2)
now += 21600000
controller.tick()
assert(#jobs == 9, "No subscribers means no periodic workers")
controller.attach(one)
assert(#jobs == 10, "Reopening rechecks persisted freshness and credentials")
complete(10)
controller.detach(1)

-- Closing during the first cache read must not lose the initial refresh forever.
local reopened = make_controller()
reopened.attach(one)
assert(#jobs == 11 and jobs[11].request.action == "snapshot")
reopened.detach(1)
complete(11, { ok = false, snapshot = { models = {} }, setup = true, error = "Add an API key." })
assert(#jobs == 11)
reopened.attach(one)
assert(#jobs == 12 and jobs[12].request.action == "refresh")
complete(12)
reopened.detach(1)

fail_start = true
local unavailable = make_controller()
unavailable.attach(one)
assert(not unavailable.get().loading and unavailable.get().error)
assert(not string.find(unavailable.get().error, "private-credential", 1, true), "Thrown launch exceptions are sanitized")
unavailable.detach(1)
fail_start = false

local function saved(index)
	complete(index, { ok = true, key_saved = true, snapshot = newer, setup = false, refresh_after_seconds = 21600 })
end
local credential = "private-ui-test-key"
local saving = make_controller()
saving.attach(one)
complete(#jobs)
complete(#jobs)
local before = #jobs
local callbacks = {}
saving.save_key(credential, function(ok, message)
	table.insert(callbacks, { ok = ok, message = message, job_count = #jobs })
end)
assert(#jobs == before + 1 and jobs[#jobs].request.action == "save_key")
assert(jobs[#jobs].request.api_key == credential, "Credential is transported only in worker stdin")
assert(jobs[#jobs].request.cache == "/data/models/cache.json")
assert(jobs[#jobs].request.key_path == "/data/artificial-analysis-api-key")
assert(not string.find(table.concat(jobs[#jobs].argv, " "), credential, 1, true))
assert(encoded_requests[#encoded_requests].api_key == nil, "The encoded request releases its key immediately")
assert(saving.get().api_key == nil and saving.get().key_saved == nil, "Shared UI state never retains a credential")
assert(#callbacks == 0, "Saving waits for the worker's local persistence result")
saved(before + 1)
assert(#callbacks == 1 and callbacks[1].ok and callbacks[1].message == nil)
assert(callbacks[1].job_count == before + 1, "Success closes the dialog before starting refresh")
assert(#jobs == before + 2 and jobs[#jobs].request.action == "refresh" and jobs[#jobs].request.force)
assert(jobs[#jobs].request.api_key == nil, "Refresh reads the key from the secure file")
complete(before + 2, { ok = false, snapshot = newer, setup = true, error = "API key rejected." })
assert(#callbacks == 1 and callbacks[1].ok, "API failure cannot undo a successful local-save callback")
saved(before + 1)
assert(#callbacks == 1 and #jobs == before + 2, "A duplicate process callback has no effect")

before = #jobs
saving.save_key(credential, function(ok, message) table.insert(callbacks, { ok = ok, message = message }) end)
complete(before + 1, { ok = false, key_saved = false, snapshot = newer, setup = false, error = "Could not save the key." })
assert(#jobs == before + 1 and #callbacks == 2 and not callbacks[2].ok)
assert(callbacks[2].message == "Could not save the key.", "Failed persistence never schedules refresh")
saving.save_key(credential, function(ok, message) table.insert(callbacks, { ok = ok, message = message }) end)
complete(before + 2)
assert(#jobs == before + 2 and not callbacks[3].ok, "An ordinary successful response does not prove key persistence")
saving.save_key(credential, function(ok, message) table.insert(callbacks, { ok = ok, message = message }) end)
jobs[before + 3].done({ status = 1, stderr = credential, stdout = credential })
assert(not callbacks[4].ok and not string.find(callbacks[4].message, credential, 1, true))
assert(#jobs == before + 3, "Failed worker saves never refresh")
fail_start = true
saving.save_key(credential, function(ok, message) table.insert(callbacks, { ok = ok, message = message }) end)
assert(not callbacks[5].ok and not string.find(callbacks[5].message, "private-credential", 1, true))
assert(encoded_requests[#encoded_requests].api_key == nil, "Launch failure also releases the request key")
fail_start = false

-- A save behind an active forced refresh still requires a new forced pass.
before = #jobs
local order = {}
saving.refresh()
saving.save_key("first-key", function(ok) assert(ok); table.insert(order, "first") end)
saving.save_key("second-key", function(ok) assert(ok); table.insert(order, "second"); error("ignored callback") end)
saving.refresh()
assert(#jobs == before + 1)
complete(before + 1)
assert(jobs[#jobs].request.action == "save_key" and jobs[#jobs].request.api_key == "first-key")
saved(before + 2)
assert(#order == 1 and order[1] == "first")
assert(jobs[#jobs].request.action == "save_key" and jobs[#jobs].request.api_key == "second-key")
saved(before + 3)
assert(#order == 2 and order[2] == "second", "Every save receives its own callback in FIFO order")
assert(#jobs == before + 4 and jobs[#jobs].request.action == "refresh" and jobs[#jobs].request.force)
complete(before + 4)
assert(#jobs == before + 4, "Refreshes after queued saves coalesce without losing the final key")

-- Closing the pane drops periodic work, never accepted credential writes.
before = #jobs
saving.refresh()
saving.save_key("third-key", function(ok) assert(ok); table.insert(order, "third") end)
saving.save_key("fourth-key", function(ok) assert(ok); table.insert(order, "fourth") end)
saving.detach(1)
complete(before + 1)
assert(jobs[#jobs].request.api_key == "third-key")
saved(before + 2)
assert(jobs[#jobs].request.api_key == "fourth-key")
saved(before + 3)
assert(order[3] == "third" and order[4] == "fourth", "Detaching never silently drops a save")
assert(#jobs == before + 4 and jobs[#jobs].request.action == "refresh" and jobs[#jobs].request.force)
complete(before + 4)
assert(not saving.get().loading)
print("PASS: Models shared controller, credential save ordering, cache failures, forced refresh and pane lifecycle")
