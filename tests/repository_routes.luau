-- Exercise URI decoding and cross-host session boundaries against the real route.
local route
local tern = {
	on = function() end,
	route = { link = function(handler) route = handler end },
	timer = function() end,
}
local require = function() return {} end
do
-- WINDOW_SOURCE
end

local block = { pane = 100, kind = "plugin", block = "tern-software-factory.agents", tab = 10 }
local panes = { block, { pane = 200, kind = "terminal", tab = 20 } }
local hosts = { { id = 1, panes = { 200 } }, { id = 2, panes = { 100 } } }
local sessions = { { id = 1, host = 1, cwd = "/local" }, { id = 2, host = 2, cwd = "/remote" } }
local currentHost, focused, nextPane, notices = 1, 200, 300, {}
local cx = {
	session = { panes = function() return panes end },
	hosts = {
		list = function() return hosts end,
		current = function() return hosts[currentHost] end,
		switch = function(_, host) currentHost = host end,
	},
	sessions = {
		create = function(_, opts)
			local session = { id = #sessions + 1, host = currentHost, cwd = opts.cwd }
			table.insert(sessions, session)
			return session
		end,
	},
	layout = {
		split = function(_, target, _, launch)
			for _, host in hosts do
				for _, pane in host.panes do
					if pane == target then
						nextPane += 1
						table.insert(panes, { pane = nextPane, cwd = launch.cwd, host = host.id, beside = target })
						table.insert(host.panes, nextPane)
						return nextPane
					end
				end
			end
			return nil
		end,
		focus = function(_, pane) focused = pane end,
	},
	toast = function(_, _, message, detail) table.insert(notices, { message, detail }) end,
}
local function open(action, encoded, blockKey)
	return route({ pane = 200, url = "tern-software-factory://" .. action .. "/" .. (blockKey or "100") .. "/" .. encoded }, cx)
end

-- The focused pane is local but this block lives on the remote host. Spaces,
-- UTF-8, literal %2F, URL fragments and shell punctuation remain directory bytes.
local encoded = "%2Fremote%2Fteam%20%E9%9B%AA%2Fwork%252Ftree%23%3B%24"
local path = "/remote/team 雪/work%2Ftree#;$"
assert(open("repo-block", encoded).handled)
assert(panes[#panes].cwd == path and panes[#panes].host == 2 and panes[#panes].beside == 100)
assert(focused == panes[#panes].pane and #sessions == 2 and currentHost == 1)
assert(open("repo-session", encoded).handled)
assert(#sessions == 3 and sessions[3].host == 2 and sessions[3].cwd == path)
assert(#notices == 0)

local count = #panes
for _, invalid in { "relative", "%2Ftmp%00evil", "%2Ftmp%2", "%2Ftmp%GG" } do
	assert(open("repo-block", invalid).handled)
	assert(#panes == count, "Invalid routes must never launch a shell in a fallback directory")
end
assert(#notices == 4)
assert(open("repo-session", "%2Ftmp", "999").handled)
assert(#sessions == 3, "A link from a closed block cannot create a session")
assert(open("repo-other", "%2Ftmp") == nil)
hosts[2].panes = {}
assert(open("repo-session", encoded).handled)
assert(#sessions == 3 and #notices == 5, "Disconnected remote paths must not open on the local host")
print("PASS: repository routes preserve special paths and launch on the originating host")
