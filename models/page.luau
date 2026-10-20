--!nonstrict
local ui = tern.ui
local controller = require("./controller")
local ROOT = "main.models"
local LIST = ROOT .. ".grid.models"
local QUERY = ROOT .. ".query"
local CREDENTIAL = "layer.credentials.body.api-key"
local SITE = "https://artificialanalysis.ai"
local SORTS = {
	{ id = "intelligence", label = "Intelligence ↓" },
	{ id = "coding", label = "Coding ↓" },
	{ id = "agentic", label = "Agentic ↓" },
	{ id = "speed", label = "Tokens/s ↓" },
	{ id = "input_price", label = "Input $ ↑" },
	{ id = "output_price", label = "Output $ ↑" },
}

-- One span per cell: private-use icons would be split into extra native spans.
local function plain(value)
	if type(value) ~= "string" then return "—" end
	return (value:gsub("\xEE[\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xEF[\x80-\xA3][\x80-\xBF]", "")
		:gsub("\xF3[\xB0-\xBF][\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xF4[\x80-\x8F][\x80-\xBF][\x80-\xBF]", "")
		:gsub("[%c]", " "))
end

local function numeric(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function metric(value, price)
	if not numeric(value) then return "—" end
	return if price then "$" .. string.format("%.6g", value) else string.format("%.1f", value)
end

local function item_id(id)
	return LIST .. ".m" .. id
end

local function button(key, label, action)
	return ui.node("el", { key = key, tag = "button", role = "factory-models-button", actions = { click = action } }, { ui.text(label) })
end

local function visible(models, snapshot)
	local rows, ranks = {}, {}
	local query = models.query:lower():match("^%s*(.-)%s*$")
	for index, model in snapshot.models do
		if query == "" or (plain(model.name) .. " " .. plain(model.creator) .. " " .. plain(model.slug)):lower():find(query, 1, true) then
			table.insert(rows, model)
			ranks[model.id] = index
		end
	end
	local ascending = models.sort == "input_price" or models.sort == "output_price"
	table.sort(rows, function(a, b)
		local av, bv = a[models.sort], b[models.sort]
		local an, bn = numeric(av), numeric(bv)
		if an ~= bn then return an end
		if an and av ~= bv then return if ascending then av < bv else av > bv end
		return ranks[a.id] < ranks[b.id]
	end)
	return rows
end

local function selected_index(models, rows)
	for index, model in rows do if model.id == models.selected then return index end end
	return 1
end

local function reconcile(models, rows, snapshot)
	-- Keep restored selection while the initial cache load is still pending.
	if #snapshot.models == 0 then return end
	local model = rows[selected_index(models, rows)]
	models.selected = if model then model.id else nil
end

local function focus(models, cx, editing)
	models.editing = editing
	cx:frame({ { "focus", if editing then QUERY else tern.json.null } })
end

local function open_model(model, cx)
	if model and type(model.slug) == "string" and model.slug:match("^[%w][%w_.~%-]*$") then
		cx:open(SITE .. "/models/" .. model.slug)
	end
end

-- Cursor/anchor state uses byte boundaries; native input props use UTF-16.
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

local function replace_selection(models, text, from, to, raw)
	local start = math.min(models.cursor, models.anchor or models.cursor)
	local finish = math.max(models.cursor, models.anchor or models.cursor)
	start, finish = from or start, to or finish
	if not raw then text = text:gsub("[%c]", " ") end
	models.query = models.query:sub(1, start) .. text .. models.query:sub(finish + 1)
	models.cursor, models.anchor = start + #text, nil
end

local function edit_key(models, key, raw)
	if (key.meta or key.ctrl) and key.name == "a" then
		models.anchor, models.cursor = 0, #models.query
	elseif key.name == "left" or key.name == "right" or key.name == "home" or key.name == "end" then
		local cursor = models.cursor
		if key.shift then models.anchor = models.anchor or cursor end
		if key.name == "home" or (key.name == "left" and key.meta) then cursor = 0
		elseif key.name == "end" or (key.name == "right" and key.meta) then cursor = #models.query
		elseif not key.shift and models.anchor then
			cursor = if key.name == "left" then math.min(cursor, models.anchor) else math.max(cursor, models.anchor)
		elseif key.name == "left" then cursor = previous(models.query, cursor)
		else cursor = following(models.query, cursor) end
		models.cursor = cursor
		if not key.shift then models.anchor = nil end
	elseif key.name == "backspace" or key.name == "delete" then
		if models.anchor and models.anchor ~= models.cursor then replace_selection(models, "")
		elseif key.name == "backspace" then replace_selection(models, "", previous(models.query, models.cursor), models.cursor)
		else replace_selection(models, "", models.cursor, following(models.query, models.cursor)) end
	elseif key.text and (key.name == "paste" or (not key.ctrl and not key.meta)) then
		replace_selection(models, key.text, nil, nil, raw)
	end
	return true
end

local function search_key(models, key, cx)
	if key.name == "escape" or key.name == "enter" or key.name == "tab" then
		focus(models, cx, false)
		return true
	end
	return edit_key(models, key, false)
end

local function close_credentials(models, cx)
	local credentials = models.credentials
	if credentials then credentials.query, credentials.cursor, credentials.anchor = "", 0, nil end
	models.credentials = nil
	focus(models, cx, false)
end

local function open_credentials(models, cx)
	if models.credentials then return end
	models.editing = false
	models.credentials = { query = "", cursor = 0, saving = false }
	cx:frame({ { "focus", CREDENTIAL } })
end

local function save_credentials(models, cx)
	local credentials = models.credentials
	if not credentials or credentials.saving then return end
	local value = credentials.query:match("^%s*(.-)%s*$")
	credentials.query, credentials.cursor, credentials.anchor = "", 0, nil
	if value == "" then
		credentials.error = "Enter an Artificial Analysis API key."
	elseif #value > 4096 or value:find("[^!-~]") then
		credentials.error = "Use an ASCII API key without spaces, up to 4096 characters."
	else
		credentials.saving, credentials.error = true, nil
		controller.save_key(value, function(ok, failure)
			-- A cancelled or replaced dialog must not be changed by an older save.
			if models.credentials ~= credentials then return end
			if ok then close_credentials(models, cx)
			else
				credentials.saving = false
				credentials.error = if type(failure) == "string" then failure else "Could not save the API key. Try again."
				cx:frame({ { "focus", CREDENTIAL } })
			end
			cx:render()
		end)
	end
	value = nil
	if credentials.error then cx:frame({ { "focus", CREDENTIAL } }) end
end

local function credential_key(models, key, cx)
	if key.name == "escape" then close_credentials(models, cx)
	elseif key.name == "enter" then save_credentials(models, cx)
	elseif not models.credentials.saving then
		if key.name == "tab" then cx:frame({ { "focus", CREDENTIAL } })
		else edit_key(models.credentials, key, true) end
	end
	return true
end

local function credential_view(credentials)
	local body = {
		ui.text("Enter your Artificial Analysis API key. It is saved privately on this host."),
		ui.node("input", { key = "api-key", role = "factory-models-key-input",
			text = string.rep("*", #credentials.query), cursor = credentials.cursor, anchor = credentials.anchor,
			placeholder = "API key", aria = "Artificial Analysis API key", disabled = credentials.saving }),
	}
	if credentials.error then table.insert(body, ui.text({ ui.span(credentials.error, "error") })) end
	table.insert(body, ui.node("row", { key = "actions", role = "factory-models-dialog-actions" }, {
		ui.node("el", { key = "save", tag = "button", role = "factory-models-button",
			disabled = credentials.saving, actions = { click = "models-key-save" } },
			{ ui.text(if credentials.saving then "Saving…" else "Save") }),
		button("cancel", "Cancel", "models-key-cancel"),
	}))
	return ui.node("overlay", { key = "credentials", head = "Artificial Analysis API key", modal = true, size = "md", anchor = "center" }, {
		ui.node("col", { key = "body", role = "factory-models-credentials" }, body),
	})
end

local function view(state)
	local models, data = state.models, controller.get()
	local snapshot = data.snapshot
	local records = visible(models, snapshot)
	reconcile(models, records, snapshot)
	local rows = {}
	for _, model in records do
		table.insert(rows, ui.node("item", {
			key = "m" .. model.id,
			label = { ui.span(plain(model.name), "strong"), ui.span(metric(model.intelligence), "muted"),
				ui.span(metric(model.coding), "muted"), ui.span(metric(model.agentic), "muted"),
				ui.span(metric(model.speed), "muted"), ui.span(metric(model.input_price, true), "muted"), ui.span(metric(model.output_price, true), "muted") },
			title = plain(model.name) .. "\nCreator: " .. plain(model.creator),
			aria = plain(model.name) .. ", " .. plain(model.creator),
		}))
	end
	local empty = if data.loading then "Loading models…"
		elseif data.setup then "No model data yet. Configure your free Artificial Analysis API key, then Refresh."
		elseif #snapshot.models == 0 then "No model data available. Refresh to fetch Artificial Analysis benchmarks."
		else "No models match this search."
	local children = {
		ui.node("row", { key = "heading", role = "factory-models-actions" }, {
			ui.text({ ui.span("Models", "strong") }), ui.badge(tostring(#records) .. " models", "muted"),
			button("refresh", if data.loading then "Refreshing…" else "Refresh", "models-refresh"),
			ui.node("el", { key = "credentials", tag = "button", role = "factory-models-button",
				title = "Artificial Analysis API key", aria = "Artificial Analysis API key",
				actions = { click = "models-key-open" } }, { ui.node("icon", { name = "key" }) }),
		}),
		ui.node("tabs", { key = "sort", role = "factory-models-tabs", items = SORTS, active = models.sort, aria = "Sort models; scores and speed descending, prices ascending" }),
		ui.node("input", { key = "query", role = "factory-models-search", text = models.query, cursor = utf16(models.query, models.cursor),
			anchor = if models.anchor then utf16(models.query, models.anchor) else nil, placeholder = "Search models or creators (/)", aria = "Search models or creators" }),
	}
	if data.setup then
		table.insert(children, ui.node("col", { key = "setup", role = "factory-models-notice" }, {
			ui.text("Use the key icon to securely save your free Artificial Analysis API key."),
			button("create-key", "Create API key", "models-create-key"),
		}))
	end
	if type(data.error) == "string" and data.error ~= "" then
		table.insert(children, ui.node("col", { key = "error", role = "factory-models-notice" }, { ui.text({ ui.span(data.error, "error") }) }))
	end
	table.insert(children, ui.node("col", { key = "grid", role = "factory-models-grid" }, {
		ui.node("row", { key = "columns", role = "factory-models-columns" }, {
			ui.text("Model"), ui.text("Intelligence"), ui.text("Coding"), ui.text("Agentic"), ui.text("Tokens/s"), ui.text("Input $/1M"), ui.text("Output $/1M"),
		}),
		ui.node("list", { key = "models", selected = if models.selected then item_id(models.selected) else nil, empty = { ui.span(empty, "muted") }, max = 1 }, rows),
	}))
	local footer = {
		ui.text({ ui.span(if models.editing then "Enter / Esc Finish · Ctrl/Cmd+A Select all"
			else "↑ ↓ Select · Enter Open · / Search · s Sort · r Refresh", "muted") }),
		ui.node("el", { key = "attribution", tag = "a", role = "factory-models-attribution",
			title = SITE, aria = "Data: Artificial Analysis", actions = { click = "models-attribution" } },
			{ ui.text("Data: Artificial Analysis") }),
	}
	return {
		main = ui.node("col", {}, { ui.node("col", { key = "models", role = "factory-models" }, children) }),
		dock = ui.node("row", { role = "factory-models-footer" }, footer),
		layer = ui.node("col", {}, if models.credentials then { credential_view(models.credentials) } else {}),
	}
end

local function cycle(items, current)
	for index, item in items do if item.id == current then return items[index % #items + 1].id end end
	return items[1].id
end

local function key(state, key, cx)
	local models, data = state.models, controller.get()
	if models.credentials then return credential_key(models, key, cx) end
	if models.editing then return search_key(models, key, cx) end
	if key.ctrl or key.alt or key.meta then return false end
	if key.name == "/" then focus(models, cx, true); return true
	elseif key.name == "r" then controller.refresh(); return true
	elseif key.name == "s" then models.sort = cycle(SORTS, models.sort); return true
	elseif key.name == "escape" and models.query ~= "" then models.query, models.cursor, models.anchor = "", 0, nil; return true end
	local rows = visible(models, data.snapshot)
	reconcile(models, rows, data.snapshot)
	if #rows == 0 then return false end
	local index = selected_index(models, rows)
	if key.name == "enter" or key.name == "o" then open_model(rows[index], cx); return true
	elseif key.name == "down" or key.name == "j" then index = math.min(#rows, index + 1)
	elseif key.name == "up" or key.name == "k" then index = math.max(1, index - 1)
	elseif key.name == "home" then index = 1
	elseif key.name == "end" then index = #rows
	elseif key.name == "page_down" then index = math.min(#rows, index + 10)
	elseif key.name == "page_up" then index = math.max(1, index - 10)
	else return false end
	models.selected = rows[index].id
	return true
end

local function event(state, event, cx)
	local models, data = state.models, controller.get()
	if models.credentials then
		if event.ev == "action" and event.act == "models-key-save" then save_credentials(models, cx)
		elseif event.ev == "action" and event.act == "models-key-cancel" then close_credentials(models, cx) end
		return
	end
	if event.ev == "focus" and event.id == QUERY then focus(models, cx, true); return end
	if event.ev == "select" and event.id == ROOT .. ".sort" then
		for _, item in SORTS do
			if item.id == event.item then
				models.sort = item.id
				break
			end
		end
		focus(models, cx, false)
	elseif (event.ev == "select" or event.ev == "activate") and event.id == LIST then
		for _, model in visible(models, data.snapshot) do
			if item_id(model.id) == event.item then
				models.selected = model.id
				focus(models, cx, false)
				if event.ev == "activate" then open_model(model, cx) end
				break
			end
		end
	elseif event.ev == "action" then
		if event.act == "models-refresh" then controller.refresh()
		elseif event.act == "models-key-open" then open_credentials(models, cx)
		elseif event.act == "models-attribution" then cx:open(SITE)
		elseif event.act == "models-create-key" then cx:open(SITE .. "/api-key-management-redirect") end
	end
end

return {
	init = function(saved)
		saved = if type(saved) == "table" then saved else {}
		local query = if type(saved.query) == "string" then saved.query:gsub("[%c]", " ") else ""
		local sort = "intelligence"
		for _, item in SORTS do if item.id == saved.sort then sort = item.id end end
		return {
			query = query, cursor = #query, sort = sort,
			selected = if type(saved.selected) == "string" then saved.selected else nil, editing = false,
		}
	end,
	enter = function(state, cx)
		controller.attach(cx)
		if state.models.credentials then cx:frame({ { "focus", CREDENTIAL } })
		elseif state.models.editing then focus(state.models, cx, true) end
	end,
	save = function(state)
		local models = state.models
		return { query = models.query, sort = models.sort, selected = models.selected }
	end,
	capture_key = function(state, key, cx)
		if state.models.credentials then return credential_key(state.models, key, cx) end
		return if state.models.editing then search_key(state.models, key, cx) else false
	end,
	view = view, key = key, event = event,
}
