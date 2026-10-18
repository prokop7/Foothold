-- Foothold AI chat hook (optional). Copy this file to
--   Saved Games\DCS\Scripts\Hooks\FootholdAI_Chat.lua
-- On the machine that hosts the mission, chat lines that start with "wm " or
-- "wingman " are written to Saved Games\DCS\Missions\Saves\FootholdAI\chat_inbox.lua,
-- where the mission reads them as plain-language wingman orders.
-- The file holds data only (a Lua table of strings and numbers); the mission
-- loads it in an empty sandbox. The chat line itself is not changed.

local PREFIXES = { 'wm ', 'wingman ' }
local KEEP = 20

local folder = lfs.writedir() .. 'Missions\\Saves\\FootholdAI\\'
local inbox = { seq = 0, items = {} }

local function save()
	pcall(lfs.mkdir, lfs.writedir() .. 'Missions\\Saves')
	pcall(lfs.mkdir, folder)
	local parts = { 'return { items = {\n' }
	for _, item in ipairs(inbox.items) do
		parts[#parts + 1] = string.format('\t{ seq = %d, name = %q, text = %q },\n', item.seq, item.name, item.text)
	end
	parts[#parts + 1] = '} }\n'
	local f = io.open(folder .. 'chat_inbox.lua', 'w')
	if f then
		f:write(table.concat(parts))
		f:close()
	end
end

local function wanted(text)
	local lower = text:lower()
	for _, prefix in ipairs(PREFIXES) do
		if lower:sub(1, #prefix) == prefix then return true end
	end
	return false
end

local handler = {}

function handler.onPlayerTrySendChat(playerID, msg, all)
	local ok, err = pcall(function()
		local text = tostring(msg or ''):gsub('[%c]', ' '):sub(1, 300)
		if not wanted(text) then return end
		local info = net.get_player_info(playerID) or {}
		-- seq continues from the clock so a restarted server never reuses numbers
		inbox.seq = math.max(inbox.seq + 1, math.floor(os.time()))
		table.insert(inbox.items, { seq = inbox.seq, name = tostring(info.name or ''), text = text })
		while #inbox.items > KEEP do table.remove(inbox.items, 1) end
		save()
	end)
	if not ok then log.write('FootholdAI', log.ERROR, 'chat hook: ' .. tostring(err)) end
	return msg
end

DCS.setUserCallbacks(handler)
log.write('FootholdAI', log.INFO, 'chat hook loaded')
