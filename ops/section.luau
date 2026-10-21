--!nonstrict
local ui = tern.ui
local controller = require("./controller")

local function number(value)
	return if type(value) == "number" and value == value and value >= 0 and value < math.huge then value else nil
end

local function fields(value)
	return if type(value) == "table" and value ~= tern.json.null then value else {}
end

local function plain(value)
	return if type(value) == "string" then value:gsub("[%c]", " ") else "—"
end

local function metric(value, decimals)
	local n = number(value)
	return if n then string.format("%." .. tostring(decimals) .. "f", n) else "—"
end

local function count(value)
	local n = number(value)
	if not n or n % 1 ~= 0 then return "—" end
	local grouped = string.format("%.0f", n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return grouped:gsub("^,", "")
end

local function history(activity)
	local tokens = fields(activity.tokens)
	local children = {
		ui.text({ ui.span("Recorded history", "strong") }),
		ui.text({ ui.span("All retained sessions on this host", "muted") }),
	}
	if activity.available ~= true then
		table.insert(children, ui.text({ ui.span("Recorded history unavailable", "warning") }))
	elseif activity.partial == true then
		table.insert(children, ui.text({ ui.span("Partial coverage · recorded totals may be incomplete", "warning") }))
	end
	local metrics = {}
	for _, item in {
		{ "Sessions", activity.sessions }, { "Subagent runs", activity.subagents },
		{ "Responses", activity.responses }, { "Total tokens", tokens.total },
		{ "Input", tokens.input }, { "Output", tokens.output },
		{ "Cache read", tokens.cache_read }, { "Cache write", tokens.cache_write },
	} do
		table.insert(metrics, ui.text({
			ui.span(item[1] .. " ", "muted"),
			ui.span(if activity.available == true then count(item[2]) else "—", "strong"),
		}))
	end
	table.insert(children, ui.node("row", { role = "factory-ops-history-metrics" }, metrics))
	for _, warning in fields(activity.warnings) do
		table.insert(children, ui.text({ ui.span(plain(warning), "warning") }))
	end
	return ui.node("col", { role = "factory-ops-history" }, children)
end

local function latency(value)
	local n = number(value)
	if not n then return "—" end
	return if n < 1000 then string.format("%.0f ms", n) else string.format("%.2f s", n / 1000)
end

local COLUMNS = {
	{ id = "model", head = "Model" },
	{ id = "speed", head = "tok/s", align = "end" },
	{ id = "ttft", head = "First token", align = "end" },
	{ id = "output", head = "Avg output", align = "end", priority = -1 },
	{ id = "samples", head = "Effective samples", align = "end", priority = -2 },
}

local function section()
	local data = controller.get()
	local children = {
		ui.node("row", { role = "factory-ops-heading" }, {
			ui.text({ ui.span("Agent ops", "bold") }),
			ui.node("el", { key = "refresh", tag = "button", role = "factory-ops-button",
				aria = "Refresh Agent ops", actions = { click = "ops-refresh" } }, {
				ui.text(if data.loading then "Refreshing…" else "Refresh"),
			}),
		}),
	}
	local snapshot = data.snapshot
	if snapshot then
		if type(snapshot.activity) == "table" and snapshot.activity ~= tern.json.null then
			table.insert(children, history(snapshot.activity))
		end
		table.insert(children, ui.node("row", { role = "factory-ops-subheading" }, {
			ui.text({ ui.span("Rolling performance", "strong") }),
			ui.text({ ui.span("Decaying weighted estimates", "muted") }),
		}))
		local summary = fields(snapshot.summary)
		table.insert(children, ui.node("row", { role = "factory-ops-summary" }, {
			ui.text({ ui.span(metric(summary.measured_models, 0), "strong"), ui.span(" measured models", "muted") }),
			ui.text({ ui.span(metric(summary.effective_samples, 1), "strong"), ui.span(" effective samples", "muted") }),
			ui.text({ ui.span(metric(summary.command_uses, 0), "strong"), ui.span(" recorded command uses", "muted") }),
		}))
		local rows = {}
		for _, model in fields(snapshot.models) do
			table.insert(rows, {
				{ ui.span(plain(model.model_key), "strong") },
				{ ui.span(metric(model.tokens_per_second, 1)) },
				{ ui.span(latency(model.ttft_ms)) },
				{ ui.span(metric(model.avg_output_tokens, 0)) },
				{ ui.span(metric(model.effective_samples, 1), "muted") },
			})
		end
		if #rows > 0 then table.insert(children, ui.table(COLUMNS, rows))
		elseif number(summary.measured_models) ~= nil then
			table.insert(children, ui.text({ ui.span("No model performance measurements recorded yet.", "muted") }))
		end
		local commands = fields(snapshot.commands)
		if #commands > 0 then
			local spans = { ui.span("Recorded commands: ", "muted") }
			for i, command in commands do
				if i > 1 then table.insert(spans, ui.span(" · ", "muted")) end
				table.insert(spans, ui.span(plain(command.name)))
				table.insert(spans, ui.span(" ×" .. metric(command.count, 0), "muted"))
			end
			local line = ui.text(spans)
			line.p = line.p or {}
			line.p.role = "factory-ops-commands"
			table.insert(children, line)
		elseif number(summary.command_uses) ~= nil then
			table.insert(children, ui.text({ ui.span("No command usage recorded yet.", "muted") }))
		end
		for _, warning in fields(snapshot.warnings) do
			table.insert(children, ui.text({ ui.span(plain(warning), "warning") }))
		end
		local age = if data.received_at then math.max(0, tern.now() - data.received_at) else 0
		if not data.error and age >= 120000 then
			table.insert(children, ui.text({ ui.span("Stale snapshot · updated " .. tostring(math.floor(age / 60000)) .. "m ago", "warning") }))
		end
	elseif not data.error then
		table.insert(children, ui.text({ ui.span("Reading Agent ops from this host…", "muted") }))
	end
	if data.error then
		table.insert(children, ui.text({ ui.span((if snapshot then "Stale snapshot · " else "") .. plain(data.error), "error") }))
		if data.setup then
			table.insert(children, ui.text({ ui.span("Run omp on this host to create ~/.omp/agent/agent.db, then Refresh.", "muted") }))
		end
	end
	return ui.node("col", { key = "ops", role = "factory-ops" }, children)
end

local function key(_, key)
	if key.name == "r" and not key.ctrl and not key.alt and not key.meta then
		controller.refresh()
		return true
	end
	return false
end

local function event(_, event)
	if event.ev == "action" and event.act == "ops-refresh" then controller.refresh() end
end

return { section = section, enter = function(_, cx) controller.attach(cx) end, key = key, event = event }
