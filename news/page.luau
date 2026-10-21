--!nonstrict
local ui = tern.ui
local controller = require("./controller")
local sources = require("./sources")
local ROOT = "main.news"
local LIST = ROOT .. ".grid.headlines"
local QUERY = ROOT .. ".query"

-- Item cells must each stay a single span; Tern splits private-use icons out.
local function plain(value)
	return (value:gsub("\xEE[\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xEF[\x80-\xA3][\x80-\xBF]", "")
		:gsub("\xF3[\xB0-\xBF][\x80-\xBF][\x80-\xBF]", "")
		:gsub("\xF4[\x80-\x8F][\x80-\xBF][\x80-\xBF]", "")
		:gsub("[%c]", " "))
end

local function source_names(story)
	local names = {}
	for _, source in story.sources do table.insert(names, plain(source.name)) end
	return table.concat(names, ", ")
end

local function age(now, at)
	if not at or at <= 0 then return "—" end
	local seconds = math.max(0, now - at)
	if seconds < 60 then return "now" end
	if seconds < 3600 then return tostring(math.floor(seconds / 60)) .. "m" end
	if seconds < 86400 then return tostring(math.floor(seconds / 3600)) .. "h" end
	return tostring(math.floor(seconds / 86400)) .. "d"
end

local function now(data)
	return data.snapshot.now + (if data.received_at then math.max(0, tern.now() - data.received_at) / 1000 else 0)
end

local function item_id(id)
	return LIST .. ".s" .. id
end

local function button(key, label, action)
	return ui.node("el", { key = key, tag = "button", role = "factory-news-button", actions = { click = action } }, { ui.text(label) })
end

local function source_tabs()
	local tabs, groups = {}, { all = {} }
	for _, source in sources do
		if source.enabled ~= false then
			local id = source.tab or source.id
			if not groups[id] then
				groups[id] = {}
				table.insert(tabs, { id = id, label = source.tab_name or source.name })
			end
			groups[id][source.id] = true
			groups.all[source.id] = true
		end
	end
	table.sort(tabs, function(a, b) return a.label:lower() < b.label:lower() end)
	table.insert(tabs, 1, { id = "all", label = "All sources" })
	return tabs, groups
end

local function hn_source(story)
	for _, source in story.sources do
		if source.id == "hn" then return source end
	end
end

local function hn_order(snapshot)
	local order, timestamps, positions = {}, {}, {}
	for index, story in snapshot.stories do
		local source = hn_source(story)
		if source then
			table.insert(order, story.id)
			timestamps[story.id] = source.published_at or story.published_at
			positions[story.id] = index
		end
	end
	table.sort(order, function(a, b)
		if timestamps[a] ~= timestamps[b] then return timestamps[a] > timestamps[b] end
		return positions[a] < positions[b]
	end)
	return order
end

local function adopt(news, snapshot)
	news.order, news.records, news.pending = {}, {}, 0
	news.hn_order, news.updated = hn_order(snapshot), false
	for _, story in snapshot.stories do
		table.insert(news.order, story.id)
		news.records[story.id] = story
	end
	news.seeded = #news.order > 0
end

-- Snapshot changes update metadata, never insert or reorder headlines under the
-- pointer. Existing rows remain until the user adopts the new edition.
local function sync(news, data)
	if news.version == data.version then return end
	news.version = data.version
	if not news.seeded then
		adopt(news, data.snapshot)
		return
	end
	local pending = 0
	for _, story in data.snapshot.stories do
		if news.records[story.id] then news.records[story.id] = story else pending += 1 end
	end
	news.pending = pending
	local weekly = hn_order(data.snapshot)
	news.updated = #weekly ~= #news.hn_order
	for index, id in weekly do
		if news.hn_order[index] ~= id then news.updated = true; break end
	end
end

local function visible(news)
	local rows = {}
	local query = news.query:lower():match("^%s*(.-)%s*$")
	local clock = now(controller.get())
	local cutoff = clock - 7 * 86400
	local windows = {}
	for _, source in sources do
		if source.window_days then windows[source.id] = source.window_days * 86400 end
	end
	local _, groups = source_tabs()
	local members = groups[news.source] or {}
	for _, id in (if news.source == "hn" then news.hn_order else news.order) do
		local story = news.records[id]
		local matches_source, eligible = false, {}
		for _, source in story.sources do
			local window = windows[source.id]
			local published = source.published_at
			if not window or (type(published) == "number" and published >= clock - window and published <= clock) then
				table.insert(eligible, source)
				if members[source.id] and (news.source ~= "hn" or not published or published >= cutoff) then
					matches_source = true
				end
			end
		end
		local visible_story = story
		if #eligible ~= #story.sources then
			visible_story = table.clone(story)
			visible_story.sources = eligible
		end
		if matches_source
			and (query == "" or (story.title .. " " .. source_names(visible_story)):lower():find(query, 1, true)) then
			table.insert(rows, visible_story)
		end
	end
	return rows
end

local function selected_index(news, rows)
	for i, story in rows do if story.id == news.selected then return i end end
	return 1
end

local function reconcile(news, rows)
	if not news.seeded then return end
	local story = rows[selected_index(news, rows)]
	news.selected = if story then story.id else nil
end

local function focus(news, cx, editing)
	news.editing = editing
	cx:frame({ { "focus", if editing then QUERY else tern.json.null } })
end

local function open_original(news, cx)
	local story = news.records[news.selected]
	if story and type(story.url) == "string" and story.url:lower():match("^https?://[^%s]+$") then cx:open(story.url) end
end

-- Luau strings use bytes; input cursor/anchor props use UTF-16. Keep byte
-- boundaries internally so typing, pasted Unicode and deletion never split UTF-8.
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

local function replace_selection(news, text, from, to)
	local start = math.min(news.cursor, news.anchor or news.cursor)
	local finish = math.max(news.cursor, news.anchor or news.cursor)
	start, finish = from or start, to or finish
	text = text:gsub("[%c]", " ")
	news.query = news.query:sub(1, start) .. text .. news.query:sub(finish + 1)
	news.cursor, news.anchor = start + #text, nil
end

local function search_key(news, key, cx)
	if key.name == "escape" or key.name == "enter" or key.name == "tab" then
		focus(news, cx, false)
	elseif (key.meta or key.ctrl) and key.name == "a" then
		news.anchor, news.cursor = 0, #news.query
	elseif key.name == "left" or key.name == "right" or key.name == "home" or key.name == "end" then
		local cursor = news.cursor
		if key.shift then news.anchor = news.anchor or cursor end
		if key.name == "home" or (key.name == "left" and key.meta) then cursor = 0
		elseif key.name == "end" or (key.name == "right" and key.meta) then cursor = #news.query
		elseif not key.shift and news.anchor then
			cursor = if key.name == "left" then math.min(cursor, news.anchor) else math.max(cursor, news.anchor)
		elseif key.name == "left" then cursor = previous(news.query, cursor)
		else cursor = following(news.query, cursor) end
		news.cursor = cursor
		if not key.shift then news.anchor = nil end
	elseif key.name == "backspace" or key.name == "delete" then
		if news.anchor and news.anchor ~= news.cursor then replace_selection(news, "")
		elseif key.name == "backspace" then replace_selection(news, "", previous(news.query, news.cursor), news.cursor)
		else replace_selection(news, "", news.cursor, following(news.query, news.cursor)) end
	elseif key.text and not key.ctrl and not key.meta then
		replace_selection(news, key.text)
	end
	-- Search owns all keys until Escape/Enter, including global page arrows.
	return true
end


local function view(state)
	local news, data = state.news, controller.get()
	sync(news, data)
	local stories = visible(news)
	reconcile(news, stories)
	local rows = {}
	for _, story in stories do
		local names = source_names(story)
		local weekly = if news.source == "hn" then hn_source(story) else nil
		local published = if weekly and weekly.published_at then weekly.published_at else story.published_at
		table.insert(rows, ui.node("item", {
			key = "s" .. story.id,
			label = { ui.span(age(now(data), published), "muted"), ui.span(names, "muted"), ui.span(plain(story.title), "strong") },
			title = story.title .. "\n" .. names,
			aria = story.title .. ", " .. names,
		}))
	end
	local tabs = source_tabs()
	local actions = {
		ui.text({ ui.span("News", "strong") }), ui.badge(tostring(#stories) .. " stories", "muted"),
		button("refresh", if data.refreshing then "Refreshing…" else "Refresh", "news-refresh"),
	}
	if news.pending > 0 or news.updated then
		table.insert(actions, button("new", if news.pending > 0 then tostring(news.pending) .. " new stories · Show" else "Updated stories · Show", "news-adopt"))
	end
	local empty = if data.loading then "Loading cached headlines…" elseif data.refreshing and not news.seeded then "Fetching headlines…"
		elseif not news.seeded then "No headlines yet. Refresh to fetch your sources." else "No headlines match these filters."
	local children = {
		ui.node("row", { key = "heading", role = "factory-news-actions" }, actions),
		ui.node("tabs", { key = "sources", role = "factory-news-sources", items = tabs, active = news.source, aria = "Filter by source" }),
		ui.node("input", { key = "query", role = "factory-news-search", text = news.query, cursor = utf16(news.query, news.cursor), anchor = if news.anchor then utf16(news.query, news.anchor) else nil, placeholder = "Search headlines or sources (/)", aria = "Search headlines or sources" }),
		ui.node("col", { key = "grid", role = "factory-news-grid" }, {
			ui.node("row", { key = "columns", role = "factory-news-columns" }, { ui.text("Time"), ui.text("Source"), ui.text("Headline") }),
			ui.node("list", { key = "headlines", selected = if news.selected then item_id(news.selected) else nil, empty = { ui.span(empty, "muted") }, max = 1 }, rows),
		}),
	}
	if data.error then table.insert(children, ui.node("text", { key = "error", role = "factory-news-notice", text = { ui.span(data.error, "error") } })) end
	return {
		main = ui.node("col", {}, { ui.node("col", { key = "news", role = "factory-news" }, children) }),
		dock = ui.node("col", { role = "factory-news-footer" }, {
			ui.text({ ui.span(if news.editing then "Type to filter · Enter / Esc finish · Ctrl/Cmd+A select all" else "↑ ↓ / j k Select · Enter Open · / Search · s Source · r Refresh · n New · o Open", "muted") }),
		}),
	}
end

local function key(state, key, cx)
	local news, data = state.news, controller.get()
	if news.editing then return search_key(news, key, cx) end
	if key.ctrl or key.alt or key.meta then return false end
	sync(news, data)
	if key.name == "/" then focus(news, cx, true); return true
	elseif key.name == "r" then controller.refresh(); return true
	elseif key.name == "n" then adopt(news, data.snapshot); return true
	elseif key.name == "s" then
		local tabs = source_tabs()
		for i, tab in tabs do if tab.id == news.source then news.source = tabs[i % #tabs + 1].id; break end end
		return true
	elseif key.name == "escape" and news.query ~= "" then news.query, news.cursor, news.anchor = "", 0, nil; return true end
	local rows = visible(news)
	reconcile(news, rows)
	if #rows == 0 then return false end
	local index = selected_index(news, rows)
	if key.name == "enter" or key.name == "o" then open_original(news, cx); return true
	elseif key.name == "down" or key.name == "j" then index = math.min(#rows, index + 1)
	elseif key.name == "up" or key.name == "k" then index = math.max(1, index - 1)
	elseif key.name == "home" then index = 1
	elseif key.name == "end" then index = #rows
	elseif key.name == "page_down" then index = math.min(#rows, index + 10)
	elseif key.name == "page_up" then index = math.max(1, index - 10)
	else return false end
	news.selected = rows[index].id
	return true
end

local function event(state, event, cx)
	local news, data = state.news, controller.get()
	sync(news, data)
	if event.ev == "focus" and event.id == QUERY then focus(news, cx, true); return end
	if event.ev == "select" and event.id == ROOT .. ".sources" then
		local _, groups = source_tabs()
		if groups[event.item] then news.source = event.item end
		focus(news, cx, false)
	elseif (event.ev == "select" or event.ev == "activate") and event.id == LIST then
		for _, story in visible(news) do
			if item_id(story.id) == event.item then
				news.selected = story.id
				focus(news, cx, false)
				if event.ev == "activate" then open_original(news, cx) end
				break
			end
		end
	elseif event.ev == "action" then
		if event.act == "news-refresh" then controller.refresh()
		elseif event.act == "news-adopt" then adopt(news, data.snapshot) end
	end
end

return {
	init = function(saved)
		saved = if type(saved) == "table" then saved else {}
		local query = if type(saved.query) == "string" then saved.query:gsub("[%c]", " ") else ""
		local source = "all"
		local _, groups = source_tabs()
		if groups[saved.source] then source = saved.source end
		return {
			query = query, cursor = #query, source = source,
			selected = if type(saved.selected) == "string" then saved.selected else nil,
			order = {}, hn_order = {}, records = {}, pending = 0, updated = false, seeded = false, version = -1, editing = false,
		}
	end,
	enter = function(state, cx)
		controller.attach(cx)
		local news, data = state.news, controller.get()
		sync(news, data)
		if news.editing then focus(news, cx, true) end
	end,
	save = function(state)
		local news = state.news
		return { query = news.query, source = news.source, selected = news.selected }
	end,
	capture_key = function(state, key, cx)
		return if state.news.editing then search_key(state.news, key, cx) else false
	end,
	view = view, key = key, event = event,
}
