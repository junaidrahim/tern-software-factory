-- Native Models UI tested against normalized snapshots, never live credentials.
local function node(kind, props, children)
	return { k = kind, p = if props and next(props) then props else nil, c = children }
end
local tern = {
	json = { null = {} },
	ui = {
		node = node, span = function(t, s) return { t = t, s = s } end,
		text = function(t) return node("text", { text = t }) end,
		badge = function(t, tone) return node("badge", { text = t, tone = tone }) end,
	},
}
local data = {
	snapshot = { models = {}, fetched_at = 1700000000, index_version = "4.3" },
	loading = false, setup = false, key_path = "/private/plugin-data/artificial-analysis-api-key",
}
local attached, refreshed, opened, frames = 0, 0, {}, {}
local saves, renders = {}, 0
local controller = {
	get = function() return data end,
	attach = function() attached += 1 end,
	refresh = function() refreshed += 1 end,
	save_key = function(value, callback) table.insert(saves, { value = value, callback = callback }) end,
}
local page = (function()
local require = function(path) assert(path == "./controller"); return controller end
-- MODELS_PAGE_SOURCE
end)()
local cx = {
	pane = 1, cols = 70, rows = 30,
	open = function(_, url) table.insert(opened, url) end,
	frame = function(_, frame) table.insert(frames, frame) end,
	render = function() renders += 1 end,
}
local function model(id, name, creator)
	return { id = id, slug = "model-" .. id, name = name, creator = "Creator " .. creator, creator_id = creator,
		url = "https://artificialanalysis.ai/models/model-" .. id }
end
local a, b, c, d, e = model("a", "Alpha", "A"), model("b", "Beta", "B"), model("c", "Gamma", "A"), model("d", "Delta", "A"), model("e", "Epsilon", "B")
a.intelligence, b.intelligence, c.intelligence, d.intelligence, e.intelligence = 0, 50, tern.json.null, -1, 50
a.coding, b.coding, c.coding, d.coding = 10, 0, 20, tern.json.null
a.agentic, b.agentic, c.agentic, d.agentic = -2, 0, tern.json.null, 10
a.speed, b.speed, c.speed, d.speed = 0, tern.json.null, 200, 100
a.input_price, b.input_price, c.input_price, d.input_price = 0, 2, tern.json.null, 1
a.output_price, b.output_price, c.output_price, d.output_price, e.output_price = 10, 0, tern.json.null, 5, 10
data.snapshot.models = { a, b, c, d, e }
local state = { models = page.init(nil) }
local function find(root, key)
	if root.p and root.p.key == key then return root end
	for _, child in root.c or {} do
		local found = find(child, key)
		if found then return found end
	end
end
local function render() return page.view(state, cx) end
local function rows() return find(render().main, "grid").c[2].c end
local function order()
	local ids = {}
	for _, row in rows() do table.insert(ids, row.p.key) end
	return table.concat(ids, ",")
end
local function sort(value)
	page.event(state, { ev = "select", id = "main.models.sort", item = value }, cx)
end
local function text(root)
	local parts = {}
	if root.p and root.p.text then
		if type(root.p.text) == "string" then table.insert(parts, root.p.text)
		else for _, span in root.p.text do table.insert(parts, span.t) end end
	end
	for _, child in root.c or {} do table.insert(parts, text(child)) end
	return table.concat(parts, "\n")
end
page.enter(state, cx)
assert(attached == 1 and state.models.sort == "intelligence")
assert(order() == "mb,me,ma,md,mc", "Default intelligence is numeric descending; zero and negatives are real, null is last")
assert(state.models.selected == "b")
sort("coding")
assert(order() == "mc,ma,mb,md,me", "Coding is descending with stable missing-value ties")
assert(state.models.selected == "b", "Sorting preserves visible selection")
sort("agentic")
assert(order() == "md,mb,ma,mc,me", "Agentic is descending without clamping negative values")
sort("speed")
assert(order() == "mc,md,ma,mb,me", "Speed is descending, with null and absent values last")
sort("input_price")
assert(order() == "ma,md,mb,mc,me", "Input price is ascending, zero first and missing always last")
assert(rows()[1].p.label[6].t == "$0", "Free pricing displays zero rather than unavailable")
sort("output_price")
assert(order() == "mb,md,ma,me,mc", "Output price has independent ascending ordering and stable numeric ties")
assert(rows()[5].p.label[7].t == "—", "JSON null displays unavailable, not zero")
assert(state.models.selected == "b")
sort("not-a-sort")
assert(state.models.sort == "output_price", "Unknown sort actions do not corrupt state")
state.models.query, state.models.cursor = "creator b", 9
assert(order() == "mb,me" and state.models.selected == "b", "Searching creators preserves visible selection")
state.models.query, state.models.cursor = "creator a", 9
assert(order() == "md,ma,mc" and state.models.selected == "d", "Hidden selection reconciles to the first visible search result")
state.models.query, state.models.cursor = "  ALPHA  ", 9
assert(order() == "ma", "Query is trimmed and case-insensitive")
state.models.query, state.models.cursor = "creator b", 9
assert(order() == "mb,me", "Query includes creator names")
state.models.query, state.models.cursor = "model-e", 7
assert(order() == "me", "Model slugs are searchable")
state.models.query, state.models.cursor = "", 0
sort("intelligence")
assert(order() == "mb,me,ma,md,mc")
print("PASS: Models numeric sorts, missing values, stable ties and search")

b.slug, b.url = "glm-4.5", "https://artificialanalysis.ai/models/glm-4.5"
page.key(state, { name = "home" }, cx)
assert(page.key(state, { name = "enter" }, cx))
assert(opened[1] == b.url and #opened == 1)
page.key(state, { name = "o" }, cx)
assert(opened[2] == b.url and #opened == 2, "Enter and o open the AA model page directly")
page.event(state, { ev = "activate", id = "main.models.grid.models", item = "main.models.grid.models.ma" }, cx)
assert(opened[3] == a.url and state.models.selected == "a", "Row activation opens that row")
page.key(state, { name = "end" }, cx)
assert(state.models.selected == "c")
page.key(state, { name = "up" }, cx)
assert(state.models.selected == "d")
page.key(state, { name = "k" }, cx)
assert(state.models.selected == "a")
page.key(state, { name = "j" }, cx)
assert(state.models.selected == "d")
page.key(state, { name = "down" }, cx)
assert(state.models.selected == "c")
page.key(state, { name = "page_up" }, cx)
assert(state.models.selected == "b")
page.key(state, { name = "page_down" }, cx)
assert(state.models.selected == "c")
page.key(state, { name = "r" }, cx)
page.event(state, { ev = "action", act = "models-refresh" }, cx)
assert(refreshed == 2)
page.key(state, { name = "s" }, cx)
assert(state.models.sort == "coding")
page.key(state, { name = "/" }, cx)
assert(page.capture_key(state, { name = "paste", text = "Aé😀" }, cx))
local input = find(render().main, "query")
assert(input.p.cursor == 4, "Native cursor uses UTF-16, not UTF-8 bytes or codepoints")
page.capture_key(state, { name = "backspace" }, cx)
assert(state.models.query == "Aé", "Deletion never splits a supplementary Unicode character")
page.capture_key(state, { name = "left" }, cx)
page.capture_key(state, { name = "x", text = "x" }, cx)
assert(state.models.query == "Axé")
page.capture_key(state, { name = "home", shift = true }, cx)
input = find(render().main, "query")
assert(input.p.cursor == 0 and input.p.anchor == 2)
page.capture_key(state, { name = "delete" }, cx)
assert(state.models.query == "é", "Shift-selected deletion preserves UTF-8 boundaries")
page.capture_key(state, { name = "a", meta = true }, cx)
page.capture_key(state, { name = "paste", text = "beta" }, cx)
assert(page.capture_key(state, { name = "enter" }, cx))
assert(not state.models.editing and #opened == 3 and order() == "mb", "Enter finishing search never opens a model")
sort("input_price")
assert(order() == "mb")
local saved = page.save(state)
local restored = page.init(saved)
assert(restored.query == "beta" and restored.sort == "input_price" and restored.selected == "b")
assert(page.init({ provider = "A" }).provider == nil and saved.provider == nil, "Retired creator filters cannot constrain search or persist")
assert(saved.cursor == nil and saved.editing == nil and saved.key_path == nil, "Only non-secret user choices are persisted")
local footer = render().dock
local attribution = find(footer, "attribution")
assert(footer.k == "row" and #footer.c == 2, "Footer only contains compact shortcuts and source attribution")
assert(attribution.p.tag == "a" and attribution.p.actions.click == "models-attribution")
assert(not find(render().main, "attribution"), "Attribution is a footer link, not a header button")
page.key(state, { name = "escape" }, cx)
assert(state.models.query == "")
page.event(state, { ev = "action", act = "models-attribution" }, cx)
assert(opened[4] == "https://artificialanalysis.ai")
print("PASS: Models direct links, navigation, UTF-16-safe editing, persistence and attribution")

data.error, data.setup = "Authentication failed; cached data retained.", true
assert(#rows() == 5, "Cached rows remain usable during authentication errors")
assert(text(render().main):find(data.error, 1, true))
state = { models = page.init({ selected = "b", sort = "invalid", query = tern.json.null }) }
data.snapshot = { models = {}, fetched_at = tern.json.null, index_version = tern.json.null }
data.error = nil
assert(#rows() == 0 and state.models.sort == "intelligence", "Setup has no fabricated rows and malformed saved values are ignored")
assert(find(render().main, "create-key"), "Setup offers a link to create a key")
assert(find(render().main, "credentials"), "Setup can open the credential dialog without cached models")
assert(not page.key(state, { name = "enter" }, cx) and #opened == 4, "Setup cannot open a fake model")
page.event(state, { ev = "action", act = "models-create-key" }, cx)
assert(opened[5] == "https://artificialanalysis.ai/api-key-management-redirect")
data.snapshot = { models = { b }, fetched_at = 951782400, index_version = "4.3" }
data.setup = false
assert(order() == "mb" and state.models.selected == "b", "Restored selection survives the empty initial cache state")
print("PASS: Models honest setup, cached failures and no-key behavior")

local function action(value)
	page.event(state, { ev = "action", act = value }, cx)
end
local function credential_input()
	return find(render().layer, "api-key")
end
local function absent(value, secret)
	if type(value) == "string" then return not value:find(secret, 1, true) end
	if type(value) == "table" then
		for key, item in value do
			if not absent(key, secret) or not absent(item, secret) then return false end
		end
	end
	return true
end
local function paste(value, modifiers)
	local key = modifiers or {}
	key.name, key.text = "paste", value
	assert(page.capture_key(state, key, cx))
end
local function finish_save(index, ok, failure)
	local callback = saves[index].callback
	saves[index].callback, saves[index].value = nil, nil
	callback(ok, failure)
end
local header_key = find(render().main, "credentials")
assert(header_key.p.tag == "button" and header_key.p.title and header_key.p.aria)
assert(#header_key.c == 1 and header_key.c[1].k == "icon" and header_key.c[1].p.name == "key")
local before = page.save(state)
action("models-key-open")
local dialog = find(render().layer, "credentials")
assert(dialog and dialog.k == "overlay" and dialog.p.modal and credential_input().p.text == "")
assert(frames[#frames][1][2] == "layer.credentials.body.api-key", "Opening focuses the masked input")
local secret = "fake-test-key-not-a-live-credential"
paste(secret, { meta = true })
assert(credential_input().p.text == string.rep("*", #secret))
assert(credential_input().p.cursor == #secret and absent(render(), secret) and absent(page.save(state), secret))
assert(page.save(state).credentials == nil, "Credential buffers and modal state are never persisted")
for _, name in { "down", "up", "page_down", "tab" } do
	assert(page.capture_key(state, { name = name }, cx))
end
page.event(state, { ev = "select", id = "main.models.sort", item = "speed" }, cx)
page.event(state, { ev = "activate", id = "main.models.grid.models", item = "main.models.grid.models.mb" }, cx)
assert(state.models.query == before.query and state.models.sort == before.sort
	and state.models.selected == before.selected and #opened == 5)
assert(page.capture_key(state, { name = "a", ctrl = true }, cx))
assert(credential_input().p.anchor == 0 and credential_input().p.cursor == #secret)
paste("abcde")
page.capture_key(state, { name = "left" }, cx)
page.capture_key(state, { name = "backspace" }, cx)
page.capture_key(state, { name = "delete" }, cx)
page.capture_key(state, { name = "home" }, cx)
page.capture_key(state, { name = "right", shift = true }, cx)
page.capture_key(state, { name = "delete" }, cx)
page.capture_key(state, { name = "end" }, cx)
page.capture_key(state, { name = "x", text = "x" }, cx)
assert(credential_input().p.text == "***" and credential_input().p.cursor == 3)
action("models-key-save")
assert(#saves == 1 and saves[1].value == "bcx", "Credential editing honors movement, selection and deletion")
assert(credential_input().p.text == "" and credential_input().p.disabled)
assert(absent(state, secret) and find(render().layer, "save").p.disabled, "Submission immediately clears the transient buffer")
page.capture_key(state, { name = "enter" }, cx)
action("models-key-save")
paste("ignored-during-save")
assert(#saves == 1 and credential_input().p.text == "", "Saving cannot submit twice or accept more secret text")
finish_save(1, false, "Private storage is unavailable.")
assert(find(render().layer, "credentials") and not credential_input().p.disabled)
assert(text(render().layer):find("Private storage is unavailable.", 1, true), "Save errors are visible in the dialog")
assert(frames[#frames][1][2] == "layer.credentials.body.api-key" and renders == 1)
paste(secret)
local attempt = state.models.credentials
page.capture_key(state, { name = "enter" }, cx)
assert(#saves == 2 and saves[2].value == secret and attempt.query == "")
assert(absent(render(), secret) and absent(page.save(state), secret))
finish_save(2, true)
assert(not find(render().layer, "credentials") and state.models.credentials == nil and renders == 2)
assert(frames[#frames][1][2] == tern.json.null)
assert(state.models.query == before.query and state.models.sort == before.sort and state.models.selected == before.selected)

action("models-key-open")
assert(credential_input().p.text == "", "Reopening never prefills an existing credential")
action("models-key-save")
assert(#saves == 2 and state.models.credentials.error and credential_input().p.text == "", "Empty input stays open and is not saved")
paste("invalid key")
action("models-key-save")
assert(#saves == 2 and state.models.credentials.error and credential_input().p.text == "")
paste(secret)
local cancelled = state.models.credentials
action("models-key-cancel")
assert(cancelled.query == "" and not find(render().layer, "credentials") and #saves == 2)
action("models-key-open")
paste(secret)
cancelled = state.models.credentials
assert(page.capture_key(state, { name = "escape" }, cx))
assert(cancelled.query == "" and state.models.credentials == nil and #saves == 2)
action("models-key-open")
paste(secret)
page.capture_key(state, { name = "a", meta = true }, cx)
paste("  replacement-key  ", { ctrl = true })
action("models-key-save")
assert(saves[3].value == "replacement-key", "Outer whitespace is trimmed before secure save")
action("models-key-cancel")
action("models-key-open")
local reopened = state.models.credentials
finish_save(3, true)
assert(state.models.credentials == reopened and credential_input().p.text == "", "An older save cannot close a reopened dialog")
action("models-key-cancel")
assert(not page.capture_key(state, { name = "left" }, cx), "Page navigation is restored after the dialog closes")
assert(absent(page.save(state), secret) and absent(render(), secret))
print("PASS: Models masked credentials, secure-save handoff, editing, modal capture, errors and cancellation")
