--!nonstrict
-- Claude and Codex usage limits, as `omp usage --json` reports them for every
-- account omp is signed in to. The window half runs omp; the block renders.
local ui = tern.ui
local SERVICES = { anthropic = "Claude", ["openai-codex"] = "Codex" }
local ORDER = { "anthropic", "openai-codex" }

local function str(value)
	return if type(value) == "string" then value else ""
end

local function num(value)
	return if type(value) == "number" and value == value then value else nil
end

local function fields(value)
	return if type(value) == "table" then value else {}
end

local function rank(provider)
	for i, id in ORDER do if id == provider then return i end end
	return #ORDER + 1
end

-- Times become offsets from omp's `generatedAt`, so the block needs no wall clock.
local function parse(text)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" then return nil, "omp returned unreadable usage" end
	local now = num(data.generatedAt)
	local accounts = {}
	for _, report in fields(data.reports) do
		local service = SERVICES[str(report.provider)]
		if service then
			local meta = fields(report.metadata)
			local account = {
				provider = report.provider, service = service,
				account = if str(meta.email) ~= "" then meta.email else str(meta.accountId),
				plan = if str(meta.planType) ~= "" then meta.planType else str(meta.orgName),
				fetched_ago_ms = if now and num(report.fetchedAt) then math.max(0, now - report.fetchedAt) else nil,
				resets = num(fields(report.resetCredits).availableCount),
				limits = tern.json.array(),
			}
			for _, limit in fields(report.limits) do
				local amount, window = fields(limit.amount), fields(limit.window)
				table.insert(account.limits, {
					label = if str(limit.label) ~= "" then limit.label else str(window.label),
					fraction = num(amount.usedFraction),
					used = num(amount.used), limit = num(amount.limit), unit = str(amount.unit),
					resets_in_ms = if now and num(window.resetsAt) then math.max(0, window.resetsAt - now) else nil,
				})
			end
			table.insert(accounts, account)
		end
	end
	-- Accounts with limits first, so each service leads with its meters.
	table.sort(accounts, function(a, b)
		if a.provider ~= b.provider then return rank(a.provider) < rank(b.provider) end
		if (#a.limits > 0) ~= (#b.limits > 0) then return #a.limits > 0 end
		return a.account < b.account
	end)
	return { accounts = tern.json.array(accounts) }
end

local function span_time(ms)
	local minutes = math.floor(ms / 60000)
	if minutes < 1 then return "under a minute" end
	if minutes < 60 then return string.format("%dm", minutes) end
	if minutes < 1440 then return string.format("%dh %02dm", minutes // 60, minutes % 60) end
	return string.format("%dd %dh", minutes // 1440, minutes % 1440 // 60)
end

local function amount(limit)
	if limit.unit == "percent" and limit.used then return string.format("%.0f%% used", limit.used) end
	if limit.unit == "usd" and limit.used and limit.limit then
		return string.format("$%.2f of $%.2f", limit.used, limit.limit)
	end
	if limit.used and limit.limit then
		return string.format("%.0f of %.0f", limit.used, limit.limit) .. (if limit.unit ~= "" then " " .. limit.unit else "")
	end
	if limit.fraction then return string.format("%.0f%% used", limit.fraction * 100) end
	return "Not reported"
end

-- Narrow panes drop account details and reset times before the meters.
local COLUMNS = {
	{ id = "service", head = "Service" },
	{ id = "account", head = "Account", grow = 1, priority = -2 },
	{ id = "window", head = "Limit" },
	{ id = "meter", head = "Used", grow = 1 },
	{ id = "amount", head = "Amount", align = "end" },
	{ id = "resets", head = "Resets", align = "end", priority = -1 },
}

-- The Limits section of the Software Factory block.
local function section(usage)
	local children = {}
	if not usage or (not usage.data and not usage.error) then
		return ui.node("col", { key = "limits", role = "factory-limits" }, { ui.text({ ui.span("Reading Claude and Codex limits from omp…", "muted") }) })
	end
	local age = usage.age_ms or 0
	local rows, newest = {}, nil
	local seen = {}
	for _, account in if usage.data then usage.data.accounts else {} do
		seen[account.provider] = true
		if account.fetched_ago_ms then
			local ago = account.fetched_ago_ms + age
			newest = if newest then math.min(newest, ago) else ago
		end
		local who = account.account
		if account.plan ~= "" then who ..= " · " .. account.plan end
		if account.resets and account.resets > 0 then
			who ..= " · " .. string.format("%.0f", account.resets) .. (if account.resets == 1 then " reset" else " resets") .. " saved"
		end
		if #account.limits == 0 then
			table.insert(rows, {
				{ ui.span(account.service, "strong") }, { ui.span(who, "muted") },
				{ ui.span("No limits reported", "muted") }, {}, {}, {},
			})
		end
		for i, limit in account.limits do
			local resets = if limit.resets_in_ms then "in " .. span_time(math.max(0, limit.resets_in_ms - age)) else "—"
			table.insert(rows, {
				if i == 1 then { ui.span(account.service, "strong") } else {},
				if i == 1 then { ui.span(who, "muted") } else {},
				{ ui.span(limit.label) },
				if limit.fraction then ui.meter_cell(math.min(1, math.max(0, limit.fraction)), { 0.75, 0.9 }) else {},
				{ ui.span(amount(limit)) },
				{ ui.span(resets, "muted") },
			})
		end
	end
	for _, provider in ORDER do
		if usage.data and not seen[provider] then
			table.insert(rows, {
				{ ui.span(SERVICES[provider], "strong") }, { ui.span("Not signed in to omp", "muted") }, {}, {}, {}, {},
			})
		end
	end
	table.insert(children, ui.node("row", { role = "factory-limits-heading" }, {
		ui.text({ ui.span("Limits", "bold") }),
		ui.text({ ui.span(if newest and newest < 60000 then "Updated just now"
			elseif newest then "Updated " .. span_time(newest) .. " ago" else "Claude and Codex", "muted") }),
	}))
	if #rows > 0 then table.insert(children, ui.table(COLUMNS, rows)) end
	if usage.error then table.insert(children, ui.text({ ui.span(usage.error, "error") })) end
	return ui.node("col", { key = "limits", role = "factory-limits" }, children)
end

return { parse = parse, section = section }
